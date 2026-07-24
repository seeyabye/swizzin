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
  address: 'tcp://127.0.0.1:${AUTHELIA_PORT}'

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
    password:
      hashed: '${hash}'
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
echo_success "Authelia installed (portal at /auth/, MFA required)"
echo_info "Next: Phase 3 will integrate qBittorrent/ruTorrent/panel with Authelia auth_request"