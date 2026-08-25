#!/usr/bin/env bash
#
# qBitManage installer for swizzin
# qBitManage: automated tag/categorize/share-limit management for qBittorrent
#
# Multi-user: one qbitmanage@<user> instance per qBittorrent user. nginx routes
# /qbitmanage/ to the authenticated caller's own instance via a $remote_user map.
#
# Per-user: pass a username as $1 to install for a single user only (used by
# `box adduser`). With no argument, installs/configures all users (used by
# `box install qbitmanage`).

#shellcheck source=sources/functions/utils
. /etc/swizzin/sources/functions/utils
#shellcheck source=sources/functions/users
. /etc/swizzin/sources/functions/users

QBM_VERSION="4.10.0"
QBM_BIN="/usr/local/bin/qbit-manage"

# Target user(s): $1 = single user (box adduser), else all users (box install)
if [[ -n "${1:-}" ]]; then
    target_users=("$1")
else
    target_users=($(_get_user_list))
fi

# --- Global setup (shared binary + templated service) ---
# On a full install (no $1) always (re)download the binary to refresh it; on a
# per-user install (box adduser) only download if the binary is missing (first
# ever), so adduser doesn't re-fetch on every new user.
if [[ -z "${1:-}" ]] || [[ ! -f "${QBM_BIN}" ]]; then
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
fi

# Migrate legacy single-user qbitmanage.service (full install only)
if [[ -z "${1:-}" ]] && [[ -f /etc/systemd/system/qbitmanage.service ]]; then
    echo_progress_start "Migrating legacy single-user qbitmanage.service to per-user template"
    systemctl stop -q qbitmanage.service 2>/dev/null
    systemctl disable -q qbitmanage.service 2>/dev/null
    rm -f /etc/systemd/system/qbitmanage.service
    systemctl daemon-reload
    echo_progress_done "legacy service removed"
fi

# (Re)create the templated service on full install, or if missing
if [[ -z "${1:-}" ]] || [[ ! -f /etc/systemd/system/qbitmanage@.service ]]; then
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
# Pin the config home (-cd / QBT_CONFIG_DIR) to the single folder so qBitManage's
# own default (~/.config/qbit-manage) never creates a second location for
# logs/.backups/web-configs. cwd/config-file stay relative for compat.
ExecStart=/usr/local/bin/qbit-manage --config-dir /home/%i/.config/qbitmanage --config-file config.yml --schedule 60 --web-server --host 127.0.0.1 --port ${QBM_PORT} --base-url /qbitmanage
Restart=on-failure
RestartSec=5
UMask=0077

[Install]
WantedBy=multi-user.target
QBMUNIT
    systemctl daemon-reload
    echo_progress_done "templated service created"
fi

# --- Per-user configuration ---
echo_progress_start "Configuring qBitManage instance(s)"
installed=0
for username in "${target_users[@]}"; do
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

    # Migrate a legacy hyphenated config home (~/.config/qbit-manage) left by
    # older installs (qBitManage defaults to ~/.config/qbit-manage; this fork
    # pins everything to the single folder via QBT_CONFIG_DIR/--config-dir).
    # Pull any real content over without clobbering, then remove the
    # hyphenated path (file or symlink). Fresh installs never hit this.
    legacy_dir="/home/${username}/.config/qbit-manage"
    if [[ -e "${legacy_dir}" ]] || [[ -L "${legacy_dir}" ]]; then
        if [[ ! -L "${legacy_dir}" ]]; then
            [[ -f "${legacy_dir}/config.yml" && ! -f "${qbm_dir}/config.yml" ]] && mv "${legacy_dir}/config.yml" "${qbm_dir}/config.yml"
            [[ -d "${legacy_dir}/logs" && ! -d "${qbm_dir}/logs" ]] && mv "${legacy_dir}/logs" "${qbm_dir}/logs"
            [[ -d "${legacy_dir}/.backups" && ! -d "${qbm_dir}/.backups" ]] && mv "${legacy_dir}/.backups" "${qbm_dir}/.backups"
        fi
        rm -rf "${legacy_dir}"
    fi

    # Preserve an existing web-ui port, else allocate one
    if [[ -f "${env_file}" ]] && grep -q '^QBM_PORT=' "${env_file}"; then
        qbm_port=$(grep '^QBM_PORT=' "${env_file}" | cut -d= -f2)
    else
        qbm_port="$(port 11700 11799)"
    fi

    # Write config.yml only if missing (write-once): a fresh install gets the
    # default template; a reinstall preserves the user's per-tracker config
    # (including one migrated from a legacy hyphenated home above).
    if [[ ! -f "${qbm_dir}/config.yml" ]]; then
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
    fi
    chown "${username}:${username}" "${qbm_dir}/config.yml"
    chmod 600 "${qbm_dir}/config.yml"

    cat > "${env_file}" << QBMENV
QBIT_PASS=${password}
QBM_PORT=${qbm_port}
QBT_CONFIG_DIR=${qbm_dir}
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
echo_progress_done "configured ${installed} instance(s)"

# --- nginx (regenerates the per-user port map, includes newly added users) ---
echo_progress_start "Configuring nginx"
bash /etc/swizzin/scripts/nginx/qbitmanage.sh
echo_progress_done "nginx configured"

touch /install/.qbitmanage.lock
echo_success "qBitManage installed (web-ui at /qbitmanage/, per-user routing, dry_run mode)"
echo_info "Edit ~/.config/qbitmanage/config.yml per user to enable commands"