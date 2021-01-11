#!/usr/bin/env bash

systemctl disable --now -q overseerr
rm /etc/systemd/system/overseerr.service

rm -rf /opt/overseerr

userdel overseerr >> "$log" 2>&1

if [ -f /install/.nginx.lock ]; then
    rm /etc/nginx/apps/overseerr.conf
    systemctl reload nginx
fi

rm /install/.overseerr.lock
