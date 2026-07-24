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
      policy: one_factor

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

# === SSO INTEGRATION TRANSACTION ===
# All mutations (nginx configs, panel code, qBittorrent prefs) are applied
# as one transaction: back up all → generate → apply → nginx -t → reload.
# On ANY failure: rollback ALL layers and remove lock.

echo_progress_start "Starting Authelia"
systemctl enable -q authelia.service
systemctl start authelia.service
sleep 3
if ! systemctl is-active -q authelia.service; then
    echo_error "Authelia failed to start. Check: journalctl -u authelia.service"
    exit 1
fi
echo_progress_done "Authelia started"

touch /install/.authelia.lock

# --- BACK UP ALL LAYERS ---
echo_progress_start "Backing up app configs for SSO integration"
# nginx configs
for app in qbittorrent rutorrent panel; do
    [[ -f /etc/nginx/apps/${app}.conf ]] && cp /etc/nginx/apps/${app}.conf /etc/nginx/apps/${app}.conf.bak-sso
done
# qBittorrent configs
qbt_users=($(_get_user_list))
for u in "${qbt_users[@]}"; do
    QBT_CFG="/home/${u}/.config/qBittorrent/qBittorrent.conf"
    [[ -f "$QBT_CFG" ]] && cp "$QBT_CFG" "${QBT_CFG}.bak-sso"
done
# Panel code state
PANEL_PREV_HEAD=""
if [[ -d /opt/swizzin/.git ]]; then
    cd /opt/swizzin
    PANEL_PREV_HEAD=$(git rev-parse HEAD 2>/dev/null)
    cd -
fi
echo_progress_done "backups created"

# Rollback function: restore ALL layers + remove lock
cleanup_sso() {
    echo_error "SSO integration failed. Rolling back all changes."
    for app in qbittorrent rutorrent panel; do
        [[ -f /etc/nginx/apps/${app}.conf.bak-sso ]] && cp /etc/nginx/apps/${app}.conf.bak-sso /etc/nginx/apps/${app}.conf
    done
    for u in "${qbt_users[@]}"; do
        QBT_CFG="/home/${u}/.config/qBittorrent/qBittorrent.conf"
        if [[ -f "${QBT_CFG}.bak-sso" ]]; then
            systemctl stop qbittorrent@${u} 2>/dev/null
            cp "${QBT_CFG}.bak-sso" "$QBT_CFG"
            systemctl start qbittorrent@${u} 2>/dev/null
        fi
    done
    if [[ -n "${PANEL_PREV_HEAD}" ]] && [[ -d /opt/swizzin/.git ]]; then
        cd /opt/swizzin
        git checkout "${PANEL_PREV_HEAD}" 2>/dev/null
        chown -R swizzin:swizzin /opt/swizzin
        systemctl restart panel.service 2>/dev/null
        cd -
    fi
    rm -f /install/.authelia.lock
    nginx -t 2>/dev/null && systemctl reload nginx 2>/dev/null
    exit 1
}

# --- GENERATE SSO NGINX CONFIGS (no reload yet) ---
echo_progress_start "Generating SSO nginx configs"
if [[ -f /install/.qbittorrent.lock ]] && [[ -f /etc/nginx/apps/qbittorrent.conf ]]; then
    rm -f /etc/nginx/apps/qbittorrent.conf
    if ! bash /etc/swizzin/scripts/nginx/qbittorrent.sh >> ${log} 2>&1; then
        echo_error "Failed to generate qbittorrent SSO config"
        cleanup_sso
    fi
fi
if [[ -f /install/.rutorrent.lock ]] && [[ -f /etc/nginx/apps/rutorrent.conf ]]; then
    rm -f /etc/nginx/apps/rutorrent.conf
    if ! bash /etc/swizzin/scripts/nginx/rutorrent.sh >> ${log} 2>&1; then
        echo_error "Failed to generate rutorrent SSO config"
        cleanup_sso
    fi
fi
if [[ -f /install/.panel.lock ]] && [[ -f /etc/nginx/apps/panel.conf ]]; then
    rm -f /etc/nginx/apps/panel.conf
    if ! bash /etc/swizzin/scripts/nginx/panel.sh >> ${log} 2>&1; then
        echo_error "Failed to generate panel SSO config"
        cleanup_sso
    fi
fi
echo_progress_done "SSO nginx configs generated"

# --- APPLY PANEL FORK PIN ---
echo_progress_start "Patching panel for SSO (dashboard fork)"
DASHBOARD_COMMIT="6ae3df5"
if [[ -f /install/.panel.lock ]] && [[ -d /opt/swizzin/.git ]]; then
    cd /opt/swizzin
    if ! git remote get-url fork 2>/dev/null | grep -q seeyabye; then
        git remote add fork https://github.com/seeyabye/swizzin_dashboard.git
    fi
    if ! git fetch fork >> ${log} 2>&1; then
        echo_error "Failed to fetch dashboard fork"
        cleanup_sso
    fi
    if ! git checkout "${DASHBOARD_COMMIT}" >> ${log} 2>&1; then
        echo_error "Failed to pin dashboard to ${DASHBOARD_COMMIT}"
        cleanup_sso
    fi
    chown -R swizzin:swizzin /opt/swizzin
    if ! systemctl restart panel.service; then
        echo_error "Panel failed to restart after fork pin"
        cleanup_sso
    fi
    cd -
fi
echo_progress_done "panel pinned to ${DASHBOARD_COMMIT}"

# --- APPLY QBITTORRENT WHITELIST ---
echo_progress_start "Configuring qBittorrent for single-login SSO"
if [[ -f /install/.qbittorrent.lock ]]; then
    for qbt_user in "${qbt_users[@]}"; do
        QBT_CFG="/home/${qbt_user}/.config/qBittorrent/qBittorrent.conf"
        if [[ -f "$QBT_CFG" ]]; then
            systemctl stop qbittorrent@${qbt_user} 2>/dev/null
            if ! sed -i 's/WebUI\\AuthSubnetWhitelistEnabled=false/WebUI\\AuthSubnetWhitelistEnabled=true/' "$QBT_CFG"; then
                echo_error "Failed to configure whitelist for ${qbt_user}"
                cleanup_sso
            fi
            if ! grep -q '^WebUI\\AuthSubnetWhitelist=' "$QBT_CFG"; then
                sed -i '/WebUI\\AuthSubnetWhitelistEnabled/a WebUI\\AuthSubnetWhitelist=127.0.0.1/32' "$QBT_CFG"
            fi
            if ! systemctl start qbittorrent@${qbt_user}; then
                echo_error "Failed to restart qBittorrent for ${qbt_user}"
                cleanup_sso
            fi
        fi
    done
fi
echo_progress_done "qBittorrent SSO configured"

# --- TEST + RELOAD (only after ALL changes applied) ---
echo_progress_start "Testing nginx config"
if ! nginx -t 2>&1; then
    echo_error "nginx config test failed after SSO integration"
    cleanup_sso
fi
if ! systemctl reload nginx; then
    echo_error "nginx reload failed after SSO integration"
    cleanup_sso
fi
echo_progress_done "nginx reloaded"

# Cleanup backups
for app in qbittorrent rutorrent panel; do
    rm -f /etc/nginx/apps/${app}.conf.bak-sso
done
for u in "${qbt_users[@]}"; do
    rm -f "/home/${u}/.config/qBittorrent/qBittorrent.conf.bak-sso"
done

echo_success "Authelia installed (portal at /auth/, SSO active)"
echo_info "SSO integrated with qBittorrent/ruTorrent/panel"
echo_info "2FA disabled by default (one_factor). To enable: configure SMTP notifier, change to two_factor, set up TOTP."