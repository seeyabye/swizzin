#!/usr/bin/env bash
#
# nginx reverse proxy config for qBitManage
#

port="$1"

# If no port argument, try to read from the systemd unit
if [[ -z "$port" ]]; then
    port=$(grep -oP '(?<=--port )\d+' /etc/systemd/system/qbitmanage.service 2>/dev/null)
fi

if [[ -z "$port" ]]; then
    echo_error "Could not determine qBitManage port"
    exit 1
fi

cat > /etc/nginx/apps/qbitmanage.conf << QBMNGINX
location /qbitmanage {
    return 301 /qbitmanage/;
}

location /qbitmanage/ {
    proxy_pass http://127.0.0.1:${port}/qbitmanage/;
    proxy_http_version 1.1;
    proxy_set_header Host \$host;
    proxy_set_header X-Real-IP \$remote_addr;
    proxy_set_header X-Forwarded-Proto \$scheme;
    proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Host \$host;
    auth_basic "What's the password?";
    auth_basic_user_file /etc/htpasswd;
}
QBMNGINX

systemctl reload nginx