#!/usr/bin/env bash
#
# qBitManage installer for swizzin
# qBitManage: automated tag/categorize/share-limit management for qBittorrent
#
# Multi-user: one qbitmanage@<user> instance per qBittorrent user. nginx routes
# /qbitmanage/ to the authenticated caller's own instance via a $remote_user map.
#

#shellcheck source=sources/functions/utils
. /etc/swizzin/sources/functions/utils
#shellcheck source=sources/functions/users
. /etc/swizzin/sources/functions/users

QBM_VERSION="4.10.0"
QBM_BIN="/usr/local/bin/qbit-manage"

echo_progress_start "Downloading qBitManage v${QBM_VERSION}"
case "$(_os_arch)" in
    "amd64") qbm_arch="linux-amd64" ;;
    "arm64") qbm_arch="linux-arm64" ;;
    *) echo_error "qBitManage does not support $(_os_arch)"; exit 1 ;;
esac
wget -O "/tmp/qbit-manage" "https://github.com/StuffAnThings/qbit_manage/releases/download/v${QBM_VERSION}/qbit-manage-${qbm_arch}" >> ${log} 2>&1 || {
    echo_error "Failed to download qBitManage binary"
    exit 1
}
chmod 755 "/tmp/qbit-manage"
mv "/tmp/qbit-manage" "${QBM_BIN}"
chown root:root "${QBM_BIN}"
echo_progress_done "qBitManage downloaded (shared binary at ${QBM_BIN})"

# Migrate: remove legacy single-user qbitmanage.service if present
if [[ -f /etc/systemd/system/qbitmanage.service ]]; then
    echo_progress_start "Migrating legacy single-user qbitmanage.service to per-user template"
    systemctl stop -q qbitmanage.service 2>/dev/null
    systemctl disable -q qbitmanage.service 2>/dev/null
    rm -f /etc/systemd/system/qbitmanage.service
    systemctl daemon-reload
    echo_progress_done "legacy service removed"
fi

echo_progress_start "Creating qbitmanage@ templated systemd service"
cat > /etc/systemd/system/qbitmanage@.service <<'QBMUNIT'
[Unit]
Description=qBitManage - qBittorrent automation for %i
After=network-online.target qbittorrent@%i.service
Wants=network-online.target

[Service]
Type=simple
User=%i
Group=%i
WorkingDirectory=/home/%i/.config/qbitmanage
Environment=QBIT_USER=%i
EnvironmentFile=/home/%i/.config/qbitmanage/qbitmanage.env
ExecStart=/usr/local/bin/qbit-manage --config-file config.yml --schedule 1440 --web-server --host 127.0.0.1 --port ${QBM_PORT} --base-url /qbitmanage
Restart=on-failure
RestartSec=5
UMask=0077

[Install]
WantedBy=multi-user.target
QBMUNIT
systemctl daemon-reload
echo_progress_done "templated service created"

echo_progress_start "Configuring per-user qBitManage instances"
users=($(_get_user_list))
installed=0
for username in "${users[@]}"; do
    qbt_conf="/home/${username}/.config/qBittorrent/qBittorrent.conf"
    qbt_port=$(grep 'WebUI\\Port' "${qbt_conf}" 2>/dev/null | head -1 | cut -d= -f2)
    if [[ -z "$qbt_port" ]]; then
        echo_warn "Skipping ${username} (no qBittorrent WebUI port found)"
        continue
    fi
    password="$(_get_user_password "${username}")"
    qbm_dir="/home/${username}/.config/qbitmanage"
    env_file="${qbm_dir}/qbitmanage.env"
    mkdir -p "${qbm_dir}"

    # Allocate or preserve web-ui port
    if [[ -f "${env_file}" ]] && grep -q '^QBM_PORT=' "${env_file}"; then
        qbm_port=$(grep '^QBM_PORT=' "${env_file}" | cut -d= -f2)
    else
        qbm_port="$(port 11700 11799)"
    fi

    cat > "${qbm_dir}/config.yml" << QBMCFG
qbt:
  host: "127.0.0.1:${qbt_port}"
  user: !ENV QBIT_USER
  pass: !ENV QBIT_PASS

settings:
  force_auto_tmm: False
  share_limits_tag: ~share_limit
  share_limits_min_seeding_time_tag: MinSeedTimeNotReached
  share_limits_min_num_seeds_tag: MinSeedsNotMet
  share_limits_last_active_tag: LastActiveLimitNotReached
  disable_qbt_default_share_limits: True

directory:
  root_dir: "/home/${username}/torrents/qbittorrent"
  remote_dir: "/home/${username}/torrents/qbittorrent"

cat:
  Radarr: "/home/${username}/torrents/qbittorrent/Radarr"
  Sonarr: "/home/${username}/torrents/qbittorrent/Sonarr"
  Books: "/home/${username}/torrents/qbittorrent/Books"
  Software: "/home/${username}/torrents/qbittorrent/Software"
  Others: "/home/${username}/torrents/qbittorrent/Others"

commands:
  dry_run: True
  recheck: False
  cat_update: False
  tag_update: False
  rem_unregistered: False
  tag_tracker_error: False
  rem_orphaned: False
  tag_nohardlinks: False
  share_limits: False
  skip_qb_version_check: False
  skip_cleanup: False
QBMCFG
    chown "${username}:${username}" "${qbm_dir}/config.yml"
    chmod 600 "${qbm_dir}/config.yml"

    cat > "${env_file}" << QBMENV
QBIT_PASS=${password}
QBM_PORT=${qbm_port}
QBMENV
    chown "${username}:${username}" "${env_file}"
    chmod 600 "${env_file}"

    chown -R "${username}:${username}" "${qbm_dir}"
    chmod 700 "${qbm_dir}"

    systemctl enable -q "qbitmanage@${username}"
    systemctl restart "qbitmanage@${username}"
    echo_info "  ${username}: qbt=${qbt_port} web=${qbm_port}"
    installed=$((installed+1))
done
echo_progress_done "configured ${installed} per-user instance(s)"

echo_progress_start "Configuring nginx"
bash /etc/swizzin/scripts/nginx/qbitmanage.sh
echo_progress_done "nginx configured"

touch /install/.qbitmanage.lock
echo_success "qBitManage installed (web-ui at /qbitmanage/, per-user routing, dry_run mode)"
echo_info "Edit ~/.config/qbitmanage/config.yml per user to enable commands"