#!/usr/bin/env bash
#
# nginx reverse proxy config for qBitManage (multi-user)
# Routes /qbitmanage/ to the authenticated caller's own instance via a
# $remote_user -> per-user-port map (conf.d/00-qbitmanage-map.conf).
#

#shellcheck source=sources/functions/users
. /etc/swizzin/sources/functions/users

# 1. http-level map: $remote_user -> per-user qbitmanage web port
{
    echo '# qBitManage: route authenticated user to their own qbitmanage instance'
    echo 'map $remote_user $qbm_port {'
    echo '    default "";'
    users=($(_get_user_list))
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

# 2. server-level: reverse proxy using the per-user port variable
cat > /etc/nginx/apps/qbitmanage.conf <<'QBM_NGINX'
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
QBM_NGINX

nginx -t 2>&1 | grep -vE 'ssl_stapling' | tail -2
systemctl reload nginx