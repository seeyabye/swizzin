#!/usr/bin/env bash
#
# Authelia removal for swizzin
#

echo_progress_start "Stopping Authelia"
systemctl stop -q authelia.service 2>/dev/null
systemctl disable -q authelia.service 2>/dev/null
echo_progress_done "Authelia stopped"

echo_progress_start "Removing Authelia files"
rm -f /etc/systemd/system/authelia.service
rm -f /usr/local/bin/authelia
rm -rf /etc/authelia
rm -rf /var/lib/authelia
rm -f /etc/nginx/conf.d/00-authelia-map.conf
rm -f /etc/nginx/apps/authelia.conf
systemctl daemon-reload
nginx -t 2>&1 | tail -1
systemctl reload nginx
echo_progress_done "files removed"

userdel authelia 2>/dev/null || true

rm -f /install/.authelia.lock
echo_success "Authelia removed"
echo_warn "Per-app auth_request edits (if applied in Phase 3) must be reverted manually"