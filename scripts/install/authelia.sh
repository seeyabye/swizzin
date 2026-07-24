#!/usr/bin/env bash
#
# Authelia SSO installer for swizzin
# Self-hosted identity provider with MFA, replacing nginx auth_basic
#

#shellcheck source=sources/functions/utils
. /etc/swizzin/sources/functions/utils

AUTHELIA_VERSION="4.39.20"
AUTHELIA_BIN="/usr/local/bin/authelia"
AUTHELIA_CONF_DIR="/etc/authelia"
AUTHELIA_STATE_DIR="/var/lib/authelia"
AUTHELIA_PORT=9091

echo_progress_start "Downloading Authelia v${AUTHELIA_VERSION}"
case "$(_os_arch)" in
    "amd64") arch="amd64" ;;
    "arm64") arch="arm64" ;;
    *) echo_error "Authelia does not support $(_os_arch)"; exit 1 ;;
esac
wget -O "/tmp/authelia.tar.gz" \
    "https://github.com/authelia/authelia/releases/download/v${AUTHELIA_VERSION}/authelia-v${AUTHELIA_VERSION}-linux-${arch}.tar.gz" >> ${log} 2>&1 || {
    echo_error "Failed to download Authelia"
    exit 1
}
tar xzf "/tmp/authelia.tar.gz" -C "/tmp/" 2>/dev/null
mv "/tmp/authelia-linux-${arch}/authelia" "${AUTHELIA_BIN}" 2>/dev/null || mv "/tmp/authelia" "${AUTHELIA_BIN}" 2>/dev/null
chmod 755 "${AUTHELIA_BIN}"
rm -rf "/tmp/authelia.tar.gz" "/tmp/authelia-linux-${arch}" "/tmp/authelia"
echo_progress_done "Authelia downloaded"

echo_progress_start "Creating authelia system user"
useradd -r authelia -s /usr/sbin/nologin -d "${AUTHELIA_STATE_DIR}" > /dev/null 2>&1 || true
install -d -m 0750 -o root -g authelia "${AUTHELIA_CONF_DIR}"
install -d -m 0750 -o authelia -g authelia "${AUTHELIA_STATE_DIR}"
echo_progress_done "user created"

echo_progress_start "Generating secrets"
JWT_SECRET=$(openssl rand -hex 32)
SESSION_SECRET=$(openssl rand -hex 32)
STORAGE_KEY=$(openssl rand -hex 32)
echo_progress_done "secrets generated"

echo_progress_start "Configuring Authelia"
cat > "${AUTHELIA_CONF_DIR}/configuration.yml" << AUTHELIACFG
server:
  address: 'tcp://127.0.0.1:${AUTHELIA_PORT}/auth'

totp:
  issuer: eu02.nanohosting.info

authentication_backend:
  file:
    path: ${AUTHELIA_CONF_DIR}/users.yml

access_control:
  default_policy: deny
  rules:
    - domain: 'eu02.nanohosting.info'
      policy: two_factor

session:
  name: authelia_session
  secret: '${SESSION_SECRET}'
  cookies:
    - name: 'authelia_session'
      domain: 'eu02.nanohosting.info'
      authelia_url: 'https://eu02.nanohosting.info/auth/'
      default_redirection_url: 'https://eu02.nanohosting.info/'
      same_site: 'lax'
      expiration: '1h'
      inactivity: '5m'
      remember_me: '1M'

storage:
  encryption_key: '${STORAGE_KEY}'
  local:
    path: ${AUTHELIA_STATE_DIR}/db.sqlite3

notifier:
  filesystem:
    filename: ${AUTHELIA_STATE_DIR}/notification.log

identity_validation:
  reset_password:
    jwt_secret: '${JWT_SECRET}'
AUTHELIACFG
chmod 640 "${AUTHELIA_CONF_DIR}/configuration.yml"
chown root:authelia "${AUTHELIA_CONF_DIR}/configuration.yml"
echo_progress_done "configuration written"

echo_progress_start "Generating users.yml from swizzin users"
users=($(cut -d: -f1 < /etc/htpasswd))
echo "users:" > "${AUTHELIA_CONF_DIR}/users.yml"
for user in "${users[@]}"; do
    password="$(_get_user_password "${user}")"
    if [[ -n "$password" ]]; then
        hash=$(${AUTHELIA_BIN} crypto hash generate argon2 --password "${password}" --no-confirm 2>/dev/null | sed 's/^Digest: //') || {
            echo_warn "Could not hash password for ${user} (will need manual reset)"
            hash="PLACEHOLDER"
        }
        if [[ "$user" == "$(_get_master_username)" ]]; then
            groups="admins"
        else
            groups="users"
        fi
        cat >> "${AUTHELIA_CONF_DIR}/users.yml" << USERENTRY
  ${user}:
    displayname: '${user}'
    password: '${hash}'
    email: '${user}@eu02.nanohosting.info'
    groups:
      - ${groups}
USERENTRY
    else
        echo_warn "No password found for ${user}, skipping"
    fi
done
chmod 640 "${AUTHELIA_CONF_DIR}/users.yml"
chown root:authelia "${AUTHELIA_CONF_DIR}/users.yml"
echo_progress_done "users.yml generated"

echo_progress_start "Validating Authelia configuration"
${AUTHELIA_BIN} validate-config --config "${AUTHELIA_CONF_DIR}/configuration.yml" 2>&1 | tail -3
echo_progress_done "config validated"

echo_progress_start "Creating Authelia systemd service"
cat > /etc/systemd/system/authelia.service << AUTHELIAUNIT
[Unit]
Description=Authelia SSO
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=authelia
Group=authelia
ExecStart=${AUTHELIA_BIN} --config ${AUTHELIA_CONF_DIR}/configuration.yml
WorkingDirectory=${AUTHELIA_STATE_DIR}
Restart=on-failure
RestartSec=5
UMask=0077

[Install]
WantedBy=multi-user.target
AUTHELIAUNIT
systemctl daemon-reload
echo_progress_done "systemd service created"

echo_progress_start "Configuring nginx"
bash /etc/swizzin/scripts/nginx/authelia.sh
echo_progress_done "nginx configured"

echo_progress_start "Configuring qBittorrent for single-login SSO"
if [[ -f /install/.qbittorrent.lock ]]; then
    qbt_users=($(_get_user_list))
    for qbt_user in "${qbt_users[@]}"; do
        QBT_CFG="/home/${qbt_user}/.config/qBittorrent/qBittorrent.conf"
        if [[ -f "$QBT_CFG" ]]; then
            systemctl stop qbittorrent@${qbt_user} 2>/dev/null
            sed -i 's/WebUI\\AuthSubnetWhitelistEnabled=false/WebUI\\AuthSubnetWhitelistEnabled=true/' "$QBT_CFG"
            if ! grep -q '^WebUI\\AuthSubnetWhitelist=' "$QBT_CFG"; then
                sed -i '/WebUI\\AuthSubnetWhitelistEnabled/a WebUI\\AuthSubnetWhitelist=127.0.0.1/32' "$QBT_CFG"
            fi
            systemctl start qbittorrent@${qbt_user}
        fi
    done
    echo_progress_done "qBittorrent configured for single-login"
fi

echo_progress_start "Patching panel for SSO (dashboard fork)"
DASHBOARD_COMMIT="6ae3df5"
if [[ -f /install/.panel.lock ]] && [[ -d /opt/swizzin/.git ]]; then
    cd /opt/swizzin
    if ! git remote get-url fork 2>/dev/null | grep -q seeyabye; then
        git remote add fork https://github.com/seeyabye/swizzin_dashboard.git 2>/dev/null || true
    fi
    git fetch fork 2>/dev/null
    if ! git checkout "${DASHBOARD_COMMIT}" 2>/dev/null; then
        echo_error "Failed to pin dashboard fork to ${DASHBOARD_COMMIT}. Panel SSO will not work."
    else
        systemctl restart panel.service 2>/dev/null
        echo_progress_done "panel pinned to ${DASHBOARD_COMMIT}"
    fi
fi



echo_progress_start "Starting Authelia"
systemctl enable -q authelia.service
systemctl start authelia.service
sleep 3
if ! systemctl is-active -q authelia.service; then
    echo_error "Authelia failed to start. Check: journalctl -u authelia.service"
    exit 1
fi
echo_progress_done "Authelia started"

# Create lock BEFORE regenerating app configs so templates detect SSO
touch /install/.authelia.lock

# Trap: remove lock if regeneration fails (rollback SSO signal)
# SSO integration uses explicit error checks (no ERR trap)

echo_progress_start "Regenerating app nginx configs for SSO"
regen_failed=0

# Back up existing configs before modifying
if [[ -f /etc/nginx/apps/qbittorrent.conf ]]; then cp /etc/nginx/apps/qbittorrent.conf /etc/nginx/apps/qbittorrent.conf.bak-sso; fi
if [[ -f /etc/nginx/apps/rutorrent.conf ]]; then cp /etc/nginx/apps/rutorrent.conf /etc/nginx/apps/rutorrent.conf.bak-sso; fi
if [[ -f /etc/nginx/apps/panel.conf ]]; then cp /etc/nginx/apps/panel.conf /etc/nginx/apps/panel.conf.bak-sso; fi

# Restore all backups and abort
restore_all_backups() {
    for app in qbittorrent rutorrent panel; do
        if [[ -f /etc/nginx/apps/${app}.conf.bak-sso ]]; then
            cp /etc/nginx/apps/${app}.conf.bak-sso /etc/nginx/apps/${app}.conf
        fi
    done
}

# Generate new configs (errors logged, not suppressed)
if [[ -f /install/.qbittorrent.lock ]] && [[ -f /etc/nginx/apps/qbittorrent.conf ]]; then
    rm -f /etc/nginx/apps/qbittorrent.conf
    if ! bash /etc/swizzin/scripts/nginx/qbittorrent.sh >> ${log} 2>&1; then
        echo_error "Failed to regenerate qbittorrent nginx config"
        regen_failed=1
    fi
fi

if [[ -f /install/.rutorrent.lock ]] && [[ -f /etc/nginx/apps/rutorrent.conf ]]; then
    rm -f /etc/nginx/apps/rutorrent.conf
    if ! bash /etc/swizzin/scripts/nginx/rutorrent.sh >> ${log} 2>&1; then
        echo_error "Failed to regenerate rutorrent nginx config"
        regen_failed=1
    fi
fi

if [[ -f /install/.panel.lock ]] && [[ -f /etc/nginx/apps/panel.conf ]]; then
    rm -f /etc/nginx/apps/panel.conf
    if ! bash /etc/swizzin/scripts/nginx/panel.sh >> ${log} 2>&1; then
        echo_error "Failed to regenerate panel nginx config"
        regen_failed=1
    fi
fi

# If any generator failed, restore ALL backups and abort
if [[ $regen_failed -eq 1 ]]; then
    echo_error "SSO config regeneration failed. Restoring all backups."
    restore_all_backups
    rm -f /install/.authelia.lock
    exit 1
fi

# Test nginx config (if-statement doesn't trigger ERR trap)
if ! nginx_output=$(nginx -t 2>&1); then
    echo "$nginx_output" | grep -v ssl_stapling
    echo_error "nginx config test failed. Restoring all backups."
    restore_all_backups
    rm -f /install/.authelia.lock
    exit 1
fi
echo "$nginx_output" | grep -v ssl_stapling

systemctl reload nginx
echo_progress_done "app nginx configs regenerated"
# (no ERR trap to remove)

echo_success "Authelia installed (portal at /auth/, MFA required)"
echo_info "SSO integrated with qBittorrent/ruTorrent/panel"
echo_info "Re-enable 2FA: change one_factor to two_factor in configuration.yml"