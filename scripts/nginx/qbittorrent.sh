#!/bin/bash
# nginx setup for qbittorrent
#shellcheck source=sources/functions/utils
. /etc/swizzin/sources/functions/utils
users=($(_get_user_list))

if [[ ! -f /etc/nginx/apps/qbtindex.conf ]]; then
    cat > /etc/nginx/apps/qbtindex.conf << DIN
location /qbittorrent.downloads {
    alias /home/\$remote_user/torrents/qbittorrent;
    include /etc/nginx/snippets/fancyindex.conf;
    auth_basic "What's the password?";
    auth_basic_user_file /etc/htpasswd;

  location ~* \.php\$ {

  } 
}
DIN
fi

if [[ ! -f /etc/nginx/apps/qbittorrent.conf ]]; then
    if [[ -f /install/.authelia.lock ]]; then
        cat > /etc/nginx/apps/qbittorrent.conf << 'QBTN'
location /qbt {
    return 301 /qbittorrent/;
}

location /qbittorrent/ {
    auth_request /_authz;
    auth_request_set $authelia_user $upstream_http_remote_user;
    auth_request_set $authelia_redirect $upstream_http_location;
    error_page 401 = @authelia_redirect;

    proxy_pass              http://$qbt_tenant.qbittorrent;
    proxy_http_version      1.1;
    proxy_set_header        X-Forwarded-Host        $http_host;
    proxy_set_header        X-Forwarded-User        $authelia_user;
    http2_push_preload on;
    rewrite ^/qbittorrent/(.*) /$1 break;
    proxy_cookie_path / "/qbittorrent/; Secure";
}
QBTN
    else
        cat > /etc/nginx/apps/qbittorrent.conf << 'QBTN'
location /qbt {
    return 301 /qbittorrent/;
}

location /qbittorrent/ {
    proxy_pass              http://$remote_user.qbittorrent;
    proxy_http_version      1.1;
    proxy_set_header        X-Forwarded-Host        $http_host;
    http2_push_preload on; # Enable http2 push
    auth_basic "What's the password?";

    auth_basic_user_file /etc/htpasswd;
    rewrite ^/qbittorrent/(.*) /$1 break;
    proxy_cookie_path / "/qbittorrent/; Secure";
}
QBTN
    fi
fi

for user in ${users[@]}; do
    port=$(grep 'WebUI\\Port' /home/${user}/.config/qBittorrent/qBittorrent.conf | cut -d= -f2)
    cat > /etc/nginx/conf.d/${user}.qbittorrent.conf << QBTUC
upstream ${user}.qbittorrent {
  server 127.0.0.1:${port};
}
QBTUC
    if grep -q 'WebUI\\Address=\*' /home/${user}/.config/qBittorrent/qBittorrent.conf; then
        active=$(systemctl is-active qbittorrent@${user})
        if [[ $active == "active" ]]; then
            systemctl stop qbittorrent@${user} >> ${log} 2>&1
        fi
        sed -i 's|WebUI\\Address=.*|WebUI\\Address=127.0.0.1|g' /home/${user}/.config/qBittorrent/qBittorrent.conf
        if [[ $active == "active" ]]; then
            systemctl start qbittorrent@${user} >> ${log} 2>&1
        fi
    fi
done
