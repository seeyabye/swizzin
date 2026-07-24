#!/usr/bin/env bash
#
# Authelia removal for swizzin
# Reverts SSO integration: regenerates app configs back to auth_basic
#

#shellcheck source=sources/functions/utils
. /etc/swizzin/sources/functions/utils

echo_progress_start "Stopping Authelia"
systemctl stop -q authelia.service 2>/dev/null
systemctl disable -q authelia.service 2>/dev/null
echo_progress_done "Authelia stopped"

echo_progress_start "Removing Authelia files"
rm -f /etc/systemd/system/authelia.service
rm -f /usr/local/bin/authelia
rm -rf /etc/authelia
rm -rf /var/lib/authelia
rm -rf /var/lib/swizzin-panel
rm -f /etc/nginx/conf.d/00-authelia-map.conf
rm -f /etc/nginx/apps/authelia.conf
rm -rf /etc/nginx/auth-secure
systemctl daemon-reload
echo_progress_done "files removed"

# Remove lock BEFORE regenerating configs so templates take non-SSO branch
rm -f /install/.authelia.lock

echo_progress_start "Reverting qBittorrent SSO config"
if [[ -f /install/.qbittorrent.lock ]]; then
    qbt_users=($(_get_user_list))
    for qbt_user in "${qbt_users[@]}"; do
        QBT_CFG="/home/${qbt_user}/.config/qBittorrent/qBittorrent.conf"
        if [[ -f "$QBT_CFG" ]]; then
            systemctl stop qbittorrent@${qbt_user} 2>/dev/null
            sed -i 's/WebUI\\AuthSubnetWhitelistEnabled=true/WebUI\\AuthSubnetWhitelistEnabled=false/' "$QBT_CFG"
            systemctl start qbittorrent@${qbt_user}
        fi
    done
fi
echo_progress_done "qBittorrent SSO reverted"

echo_progress_start "Regenerating app nginx configs (back to auth_basic)"
# Back up existing configs, regenerate (templates will use auth_basic since no authelia.lock)
if [[ -f /etc/nginx/apps/qbittorrent.conf ]]; then
    cp /etc/nginx/apps/qbittorrent.conf /etc/nginx/apps/qbittorrent.conf.bak-sso-remove
    rm -f /etc/nginx/apps/qbittorrent.conf
    bash /etc/swizzin/scripts/nginx/qbittorrent.sh >> ${log} 2>&1
fi
if [[ -f /etc/nginx/apps/rutorrent.conf ]]; then
    cp /etc/nginx/apps/rutorrent.conf /etc/nginx/apps/rutorrent.conf.bak-sso-remove
    rm -f /etc/nginx/apps/rutorrent.conf
    bash /etc/swizzin/scripts/nginx/rutorrent.sh >> ${log} 2>&1
fi
if [[ -f /etc/nginx/apps/panel.conf ]]; then
    cp /etc/nginx/apps/panel.conf /etc/nginx/apps/panel.conf.bak-sso-remove
    rm -f /etc/nginx/apps/panel.conf
    bash /etc/swizzin/scripts/nginx/panel.sh >> ${log} 2>&1
fi

if ! nginx -t 2>&1; then
    echo_error "nginx config test failed after SSO removal. Restoring backups."
    for app in qbittorrent rutorrent panel; do
        cp /etc/nginx/apps/${app}.conf.bak-sso-remove /etc/nginx/apps/${app}.conf 2>/dev/null
    done
    exit 1
fi
systemctl reload nginx
echo_progress_done "app nginx configs regenerated"

echo_progress_start "Reverting panel dashboard to upstream"
if [[ -f /install/.panel.lock ]] && [[ -d /opt/swizzin/.git ]]; then
    cd /opt/swizzin
    git remote remove fork 2>/dev/null || true
    git fetch origin 2>/dev/null
    git checkout master 2>/dev/null || true
    chown -R swizzin:swizzin /opt/swizzin
    systemctl restart panel.service 2>/dev/null
    cd -
fi
echo_progress_done "panel reverted to upstream"

userdel authelia 2>/dev/null || true

echo_success "Authelia removed (SSO reverted, apps back to auth_basic)"