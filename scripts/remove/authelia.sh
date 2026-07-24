#!/usr/bin/env bash
#
# Authelia removal for swizzin
# Transaction: back up → generate non-SSO → test → only then delete Authelia
#

#shellcheck source=sources/functions/utils
. /etc/swizzin/sources/functions/utils

# STEP 1: Back up existing app configs (before any changes)
echo_progress_start "Backing up app nginx configs"
for app in qbittorrent rutorrent panel; do
    if [[ -f /etc/nginx/apps/${app}.conf ]]; then
        cp /etc/nginx/apps/${app}.conf /etc/nginx/apps/${app}.conf.bak-sso-remove
    fi
done
echo_progress_done "backups created"

# STEP 2: Remove lock so templates generate non-SSO configs
rm -f /install/.authelia.lock

# STEP 3: Stage out map + authelia.conf (they reference variables that
# only exist in SSO app configs; removing them first prevents nginx -t failures)
if [[ -f /etc/nginx/conf.d/00-authelia-map.conf ]]; then
    mv /etc/nginx/conf.d/00-authelia-map.conf /etc/nginx/conf.d/00-authelia-map.conf.staged-remove
fi
if [[ -f /etc/nginx/apps/authelia.conf ]]; then
    mv /etc/nginx/apps/authelia.conf /etc/nginx/apps/authelia.conf.staged-remove
fi

# STEP 4: Regenerate app nginx configs (non-SSO branch, since no lock)
echo_progress_start "Regenerating app nginx configs (back to auth_basic)"
regen_failed=0
if [[ -f /etc/nginx/apps/qbittorrent.conf ]]; then
    rm -f /etc/nginx/apps/qbittorrent.conf
    if ! bash /etc/swizzin/scripts/nginx/qbittorrent.sh >> ${log} 2>&1; then
        echo_error "Failed to regenerate qbittorrent nginx config"
        regen_failed=1
    fi
fi
if [[ -f /etc/nginx/apps/rutorrent.conf ]]; then
    rm -f /etc/nginx/apps/rutorrent.conf
    if ! bash /etc/swizzin/scripts/nginx/rutorrent.sh >> ${log} 2>&1; then
        echo_error "Failed to regenerate rutorrent nginx config"
        regen_failed=1
    fi
fi
if [[ -f /etc/nginx/apps/panel.conf ]]; then
    rm -f /etc/nginx/apps/panel.conf
    if ! bash /etc/swizzin/scripts/nginx/panel.sh >> ${log} 2>&1; then
        echo_error "Failed to regenerate panel nginx config"
        regen_failed=1
    fi
fi
if [[ $regen_failed -eq 1 ]]; then
    echo_error "SSO config regeneration failed. Restoring configs, map, authelia.conf and lock. Authelia left running."
    for app in qbittorrent rutorrent panel; do
        cp /etc/nginx/apps/${app}.conf.bak-sso-remove /etc/nginx/apps/${app}.conf 2>/dev/null
    done
    [[ -f /etc/nginx/conf.d/00-authelia-map.conf.staged-remove ]] && mv /etc/nginx/conf.d/00-authelia-map.conf.staged-remove /etc/nginx/conf.d/00-authelia-map.conf
    [[ -f /etc/nginx/apps/authelia.conf.staged-remove ]] && mv /etc/nginx/apps/authelia.conf.staged-remove /etc/nginx/apps/authelia.conf
    touch /install/.authelia.lock
    exit 1
fi

# STEP 5: Test nginx config before committing
if ! nginx -t 2>&1; then
    echo_error "nginx config test failed. Restoring configs, map, authelia.conf and lock. Authelia left running."
    for app in qbittorrent rutorrent panel; do
        cp /etc/nginx/apps/${app}.conf.bak-sso-remove /etc/nginx/apps/${app}.conf 2>/dev/null
    done
    # Restore staged files
    [[ -f /etc/nginx/conf.d/00-authelia-map.conf.staged-remove ]] && mv /etc/nginx/conf.d/00-authelia-map.conf.staged-remove /etc/nginx/conf.d/00-authelia-map.conf
    [[ -f /etc/nginx/apps/authelia.conf.staged-remove ]] && mv /etc/nginx/apps/authelia.conf.staged-remove /etc/nginx/apps/authelia.conf
    touch /install/.authelia.lock
    exit 1
fi
if ! systemctl reload nginx; then
    echo_error "nginx reload failed. Restoring configs, map, authelia.conf and lock. Authelia left running."
    for app in qbittorrent rutorrent panel; do
        cp /etc/nginx/apps/${app}.conf.bak-sso-remove /etc/nginx/apps/${app}.conf 2>/dev/null
    done
    [[ -f /etc/nginx/conf.d/00-authelia-map.conf.staged-remove ]] && mv /etc/nginx/conf.d/00-authelia-map.conf.staged-remove /etc/nginx/conf.d/00-authelia-map.conf
    [[ -f /etc/nginx/apps/authelia.conf.staged-remove ]] && mv /etc/nginx/apps/authelia.conf.staged-remove /etc/nginx/apps/authelia.conf
    touch /install/.authelia.lock
    exit 1
fi
echo_progress_done "app nginx configs regenerated"
# Clean up staged files (no longer needed)
rm -f /etc/nginx/conf.d/00-authelia-map.conf.staged-remove
rm -f /etc/nginx/apps/authelia.conf.staged-remove

# STEP 6: Now safe to disable qBittorrent SSO and stop Authelia
echo_progress_start "Reverting qBittorrent SSO config"
if [[ -f /install/.qbittorrent.lock ]]; then
    qbt_users=($(_get_user_list))
    for qbt_user in "${qbt_users[@]}"; do
        QBT_CFG="/home/${qbt_user}/.config/qBittorrent/qBittorrent.conf"
        if [[ -f "$QBT_CFG" ]]; then
            systemctl stop qbittorrent@${qbt_user} 2>/dev/null
            sed -i 's/WebUI\\AuthSubnetWhitelistEnabled=true/WebUI\\AuthSubnetWhitelistEnabled=false/' "$QBT_CFG"
            sed -i 's/WebUI\\Address=*/WebUI\\Address=127.0.0.1/' "$QBT_CFG"
            systemctl start qbittorrent@${qbt_user}
        fi
    done
fi
echo_progress_done "qBittorrent SSO reverted"

echo_progress_start "Stopping Authelia"
systemctl stop -q authelia.service 2>/dev/null
systemctl disable -q authelia.service 2>/dev/null
echo_progress_done "Authelia stopped"

echo_progress_start "Removing Authelia files"
rm -f /etc/systemd/system/authelia.service
rm -f /usr/local/bin/authelia
rm -rf /etc/authelia
rm -rf /var/lib/authelia
rm -f /var/lib/swizzin-panel/panel-secret
rm -f /etc/nginx/conf.d/00-authelia-map.conf
rm -f /etc/nginx/apps/authelia.conf
rm -rf /etc/nginx/auth-secure
systemctl daemon-reload
# Final nginx test + reload after removing authelia configs
if ! nginx -t 2>&1; then
    echo_error "nginx config test failed after removing Authelia configs."
    echo_warn "Check /etc/nginx/apps/ for stale references."
else
    systemctl reload nginx
fi
echo_progress_done "files removed"

# Panel dashboard code is left in place (SSO fork falls back to auth_basic
# when nginx doesn't send X-Forwarded-User + X-Authelia-Secret headers,
# which it won't without authelia.conf). Reverting requires pip reinstall
# which is fragile and unnecessary. The fork code is safe without SSO.
echo_progress_start "Panel dashboard left in place (safe without SSO headers)"
echo_progress_done "no changes needed"

userdel authelia 2>/dev/null || true

echo_success "Authelia removed (SSO reverted, apps back to auth_basic)"