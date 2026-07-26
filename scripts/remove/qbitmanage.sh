#!/usr/bin/env bash
#
# qBitManage removal for swizzin (multi-user)
# Stops and removes all qbitmanage@<user> instances + legacy single-user service.
#

#shellcheck source=sources/functions/users
. /etc/swizzin/sources/functions/users

echo_progress_start "Stopping qBitManage instances"
users=($(_get_user_list))
for username in "${users[@]}"; do
    systemctl stop -q "qbitmanage@${username}" 2>/dev/null
    systemctl disable -q "qbitmanage@${username}" 2>/dev/null
done
# Also stop legacy single-user service if present
systemctl stop -q qbitmanage.service 2>/dev/null
systemctl disable -q qbitmanage.service 2>/dev/null
echo_progress_done "qBitManage stopped"

echo_progress_start "Removing qBitManage files"
rm -f /etc/systemd/system/qbitmanage@.service
rm -f /etc/systemd/system/qbitmanage.service
rm -f /usr/local/bin/qbit-manage
for username in "${users[@]}"; do
    rm -rf "/home/${username}/.config/qbitmanage"
    rm -f "/home/${username}/bin/qbit-manage"
done
rm -f /etc/nginx/conf.d/00-qbitmanage-map.conf
rm -f /etc/nginx/apps/qbitmanage.conf
systemctl daemon-reload
nginx -t 2>&1 | grep -vE 'ssl_stapling' | tail -1
systemctl reload nginx
echo_progress_done "files removed"

rm -f /install/.qbitmanage.lock
echo_success "qBitManage removed"