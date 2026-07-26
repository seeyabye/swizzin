#!/usr/bin/env bash
#
# nginx reverse proxy config for qBitManage (multi-user)
# Routes /qbitmanage/ to the authenticated caller's own instance via a
# username -> per-user-port map (conf.d/00-qbitmanage-map.conf).
#
# Conditional SSO (mirrors scripts/nginx/qbittorrent.sh):
#   - With Authelia (/install/.authelia.lock): auth_request /_authz +
#     auth_request_set $authelia_user, map keyed on $authelia_user.
#   - Without: auth_basic + map keyed on $remote_user.
#
# Workaround: qBitManage's documentation-viewer.js (v4.10) hardcodes the docs
# fetch as fetch('/api/docs?...'), ignoring --base-url. Behind a base-url of
# /qbitmanage that request hits the panel catch-all (location /) and 404s.
# Intercept /api/docs and redirect to the base-url-prefixed path so it reaches
# the user's own instance through the normal /qbitmanage/ auth + routing.
#

#shellcheck source=sources/functions/users
. /etc/swizzin/sources/functions/users

users=($(_get_user_list))

# 1. http-level map: username -> per-user qbitmanage web port.
# The key variable depends on the auth mode: auth_request populates
# $authelia_user (captured via auth_request_set), auth_basic populates
# $remote_user. Both map to the same per-user $qbm_port.
if [[ -f /install/.authelia.lock ]]; then
    map_key='$authelia_user'
else
    map_key='$remote_user'
fi

{
    echo '# qBitManage: route authenticated user to their own qbitmanage instance'
    echo "map ${map_key} \$qbm_port {"
    echo '    default "";'
    for username in "${users[@]}"; do
        env_file="/home/${username}/.config/qbitmanage/qbitmanage.env"
        if [[ -f "${env_file}" ]]; then
            qbm_port=$(grep '^QBM_PORT=' "${env_file}" 2>/dev/null | cut -d= -f2)
            if [[ -n "$qbm_port" ]]; then
                echo "    ${username} ${qbm_port};"
            fi
        fi
    done
    echo '}'
} > /etc/nginx/conf.d/00-qbitmanage-map.conf

# 2. server-level reverse proxy. Same per-user routing in both modes;
# only the auth layer differs. Both branches also redirect /api/docs to
# /qbitmanage/api/docs to work around the docs viewer base-url bug.
if [[ -f /install/.authelia.lock ]]; then
    cat > /etc/nginx/apps/qbitmanage.conf <<'QBM_SSO'
location = /api/docs {
    return 302 /qbitmanage/api/docs$is_args$args;
}

location /qbitmanage {
    return 301 /qbitmanage/;
}

location /qbitmanage/ {
    auth_request /_authz;
    auth_request_set $authelia_user $upstream_http_remote_user;
    auth_request_set $authelia_redirect $upstream_http_location;
    error_page 401 = @authelia_redirect;

    proxy_pass http://127.0.0.1:$qbm_port$request_uri;
    proxy_http_version 1.1;
    proxy_set_header Host $host;
    proxy_set_header X-Real-IP $remote_addr;
    proxy_set_header X-Forwarded-Proto $scheme;
    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Host $host;
}
QBM_SSO
else
    cat > /etc/nginx/apps/qbitmanage.conf <<'QBM_BASIC'
location = /api/docs {
    return 302 /qbitmanage/api/docs$is_args$args;
}

location /qbitmanage {
    return 301 /qbitmanage/;
}

location /qbitmanage/ {
    auth_basic "What's the password?";
    auth_basic_user_file /etc/htpasswd;
    proxy_pass http://127.0.0.1:$qbm_port$request_uri;
    proxy_http_version 1.1;
    proxy_set_header Host $host;
    proxy_set_header X-Real-IP $remote_addr;
    proxy_set_header X-Forwarded-Proto $scheme;
    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Host $host;
}
QBM_BASIC
fi

nginx -t 2>&1 | grep -vE 'ssl_stapling' | tail -2
systemctl reload nginx