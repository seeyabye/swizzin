#!/usr/bin/env bash
#
# nginx config for Authelia SSO (portal + auth_request endpoint)
# The tenant-routing map is created in Phase 3 (when auth_request_set defines $authelia_user)
#

cat > /etc/nginx/apps/authelia.conf << AUTHELIANGINX
location /auth/ {
    proxy_pass http://127.0.0.1:9091;
    proxy_set_header Host \$host;
    proxy_set_header X-Real-IP \$remote_addr;
    proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto \$scheme;
    proxy_set_header X-Forwarded-Host \$host;
    client_body_buffer_size 128k;
}

location = /_authz {
    internal;
    proxy_pass http://127.0.0.1:9091/auth/api/authz/auth-request;
    proxy_pass_request_body off;
    proxy_set_header Content-Length "";
    proxy_set_header X-Original-URL \$scheme://\$http_host\$request_uri;
    proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    proxy_set_header X-Real-IP \$remote_addr;
    proxy_set_header X-Forwarded-Proto \$scheme;
    proxy_set_header X-Forwarded-Host \$http_host;
}

location @authelia_redirect {
    auth_request_set \$authelia_redirect \$upstream_http_location;
    return 302 \$authelia_redirect;
}
AUTHELIANGINX

nginx -t 2>&1 | grep -vE 'ssl_stapling' | tail -2
systemctl reload nginx