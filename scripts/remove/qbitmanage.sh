#!/usr/bin/env bash
#
# qBitManage removal for swizzin
#

username="$(cut -d: -f1 < /root/.master.info)"

echo_progress_start "Stopping qBitManage"
systemctl stop -q qbitmanage.service 2>/dev/null
systemctl disable -q qbitmanage.service 2>/dev/null
echo_progress_done "qBitManage stopped"

echo_progress_start "Removing qBitManage files"
rm -f /etc/systemd/system/qbitmanage.service
rm -f "/home/${username}/bin/qbit-manage"
rm -rf "/home/${username}/.config/qbitmanage"
rm -f /etc/nginx/apps/qbitmanage.conf
systemctl daemon-reload
systemctl reload nginx
echo_progress_done "files removed"

rm -f /install/.qbitmanage.lock
echo_success "qBitManage removed"