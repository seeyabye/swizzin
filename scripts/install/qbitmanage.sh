#!/usr/bin/env bash
#
# qBitManage installer for swizzin
# qBitManage: automated tag/categorize/share-limit management for qBittorrent
#

username="$(_get_master_username)"
password="$(_get_user_password "$username")"

#shellcheck source=sources/functions/utils
. /etc/swizzin/sources/functions/utils

QBM_VERSION="4.10.0"
QBM_DIR="/home/${username}/.config/qbitmanage"
QBM_BIN="/home/${username}/bin/qbit-manage"

echo_progress_start "Downloading qBitManage v${QBM_VERSION}"
mkdir -p "/home/${username}/bin"
case "$(_os_arch)" in
    "amd64") qbm_arch="linux-amd64" ;;
    "arm64") qbm_arch="linux-arm64" ;;
    *) echo_error "qBitManage does not support $(_os_arch)"; exit 1 ;;
esac
wget -O "/tmp/qbit-manage" "https://github.com/StuffAnThings/qbit_manage/releases/download/v${QBM_VERSION}/qbit-manage-${qbm_arch}" >> ${log} 2>&1 || {
    echo_error "Failed to download qBitManage binary"
    exit 1
}
chmod 700 "/tmp/qbit-manage"
mv "/tmp/qbit-manage" "${QBM_BIN}"
chown "${username}:${username}" "${QBM_BIN}"
echo_progress_done "qBitManage downloaded"

echo_progress_start "Configuring qBitManage"
mkdir -p "${QBM_DIR}"

# Get qBittorrent WebUI port from config
qbt_port=$(grep 'WebUI\\Port' "/home/${username}/.config/qBittorrent/qBittorrent.conf" 2>/dev/null | cut -d= -f2)
if [[ -z "$qbt_port" ]]; then
    echo_error "Could not find qBittorrent WebUI port. Is qBittorrent installed?"
    exit 1
fi

# Generate a random port for the qBitManage web-ui
qbm_port="$(port 10001 32001)"

cat > "${QBM_DIR}/config.yml" << QBMCFG
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
chown "${username}:${username}" "${QBM_DIR}/config.yml"
chmod 600 "${QBM_DIR}/config.yml"
echo_progress_done "qBitManage configured (dry_run=True, all commands disabled by default)"

echo_progress_start "Creating qBitManage systemd service"
cat > /etc/systemd/system/qbitmanage.service << QBMUNIT
[Unit]
Description=qBitManage - qBittorrent automation
After=network-online.target qbittorrent@${username}.service
Wants=network-online.target

[Service]
Type=simple
User=${username}
Group=${username}
WorkingDirectory=${QBM_DIR}
Environment=QBIT_USER=${username}
Environment=QBIT_PASS='${password}'
ExecStart=${QBM_BIN} --config-file config.yml --schedule 1440 --web-server --host 127.0.0.1 --port ${qbm_port} --base-url /qbitmanage
Restart=on-failure
RestartSec=5
UMask=0077

[Install]
WantedBy=multi-user.target
QBMUNIT
systemctl daemon-reload
echo_progress_done "systemd service created"

echo_progress_start "Configuring nginx"
bash /etc/swizzin/scripts/nginx/qbitmanage.sh "${qbm_port}"
echo_progress_done "nginx configured"

echo_progress_start "Starting qBitManage"
systemctl enable -q qbitmanage.service
systemctl start qbitmanage.service
echo_progress_done "qBitManage started"

touch /install/.qbitmanage.lock
echo_success "qBitManage installed (web-ui at /qbitmanage/, dry_run mode - edit config.yml to enable commands)"