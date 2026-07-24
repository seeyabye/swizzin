#!/usr/bin/env bash
#
# nginx config for Authelia SSO (portal + auth_request endpoint + map + panel secret)
#

users=($(cut -d: -f1 < /etc/htpasswd))

# 1. http-level map: tenant routing (defense-in-depth)
cat > /etc/nginx/conf.d/00-authelia-map.conf << AUTHELIAMAP
# Authelia SSO: translate authenticated user into routing tenant
# \$authelia_user is set by auth_request_set in each app's nginx config
# Unknown/empty -> _deny (no matching upstream -> 502 fail-closed)
map \$authelia_user \$qbt_tenant {
    default "_deny";
$(for u in "${users[@]}"; do echo "    ${u} ${u};"; done)
}
AUTHELIAMAP

# 2. server-level: portal + auth-request endpoint + redirect
# Auth-secure directory for panel shared secret (root-only)
mkdir -p /etc/nginx/auth-secure

# Generate panel shared secret if not exists
if [[ ! -f /var/lib/swizzin-panel/panel-secret ]]; then
    mkdir -p /var/lib/swizzin-panel
    chown root:swizzin /var/lib/swizzin-panel
    chmod 750 /var/lib/swizzin-panel
    openssl rand -hex 32 > /var/lib/swizzin-panel/panel-secret
    chown swizzin:swizzin /var/lib/swizzin-panel/panel-secret
    chmod 400 /var/lib/swizzin-panel/panel-secret
fi

# Write the secret to a root-only nginx include
SECRET=$(cat /var/lib/swizzin-panel/panel-secret)
printf 'proxy_set_header X-Authelia-Secret "%s";\n' "$SECRET" > /etc/nginx/auth-secure/panel-secret.conf
chown root:root /etc/nginx/auth-secure/panel-secret.conf
chmod 600 /etc/nginx/auth-secure/panel-secret.conf

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
    proxy_set_header Authorization "";
    proxy_set_header X-Original-URL \$scheme://\$http_host\$request_uri;
    proxy_set_header X-Original-Method \$request_method;
    proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    proxy_set_header X-Real-IP \$remote_addr;
    proxy_set_header X-Forwarded-Proto \$scheme;
    proxy_set_header X-Forwarded-Host \$http_host;
}

location @authelia_redirect {
    return 302 \$authelia_redirect;
}
AUTHELIANGINX

nginx -t 2>&1 | grep -vE 'ssl_stapling' | tail -2
systemctl reload nginx