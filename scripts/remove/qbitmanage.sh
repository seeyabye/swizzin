#!/usr/bin/env bash
#
# qBitManage removal for swizzin (multi-user)
#
# Per-user: pass a username as $1 to remove qBitManage for a single user only
# (stops their instance, deletes their config, and drops them from the nginx
# port map). The shared binary, the templated service, other users' instances,
# and the /install/.qbitmanage.lock are all left in place.
#
# With no argument, removes qBitManage entirely (all users + shared binary +
# template + nginx configs + lock).

#shellcheck source=sources/functions/utils
. /etc/swizzin/sources/functions/utils
#shellcheck source=sources/functions/users
. /etc/swizzin/sources/functions/users

# Target user(s): $1 = single user (per-user removal), else all users (full)
if [[ -n "${1:-}" ]]; then
    target_users=("$1")
    full_removal=false
else
    target_users=($(_get_user_list))
    full_removal=true
fi

echo_progress_start "Stopping qBitManage instance(s)"
for username in "${target_users[@]}"; do
    systemctl stop -q "qbitmanage@${username}" 2>/dev/null
    systemctl disable -q "qbitmanage@${username}" 2>/dev/null
done
# Legacy single-user service only matters on full removal
if [[ "${full_removal}" == true ]]; then
    systemctl stop -q qbitmanage.service 2>/dev/null
    systemctl disable -q qbitmanage.service 2>/dev/null
fi
echo_progress_done "qBitManage stopped"

echo_progress_start "Removing qBitManage files"
for username in "${target_users[@]}"; do
    rm -rf "/home/${username}/.config/qbitmanage"
    # legacy hyphenated home / alias from older installs
    rm -rf "/home/${username}/.config/qbit-manage"
    rm -f "/home/${username}/bin/qbit-manage"
done

if [[ "${full_removal}" == true ]]; then
    # Tear down shared/global pieces
    rm -f /etc/systemd/system/qbitmanage@.service
    rm -f /etc/systemd/system/qbitmanage.service
    rm -f /usr/local/bin/qbit-manage
    rm -f /etc/nginx/apps/qbitmanage.conf
    rm -f /etc/nginx/conf.d/00-qbitmanage-map.conf
    systemctl daemon-reload
    nginx -t 2>&1 | grep -vE 'ssl_stapling' | tail -1
    systemctl reload nginx
else
    # Per-user: keep shared pieces; regenerate the nginx map to drop this user
    bash /etc/swizzin/scripts/nginx/qbitmanage.sh
fi
echo_progress_done "files removed"

if [[ "${full_removal}" == true ]]; then
    rm -f /install/.qbitmanage.lock
    echo_success "qBitManage removed"
else
    echo_success "qBitManage removed for: ${target_users[*]}"
fi