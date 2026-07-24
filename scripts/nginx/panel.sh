#!/bin/bash
# QuickBox dashboard installer for Swizzin
# Author: liara
# Copyright (C) 2017 Swizzin
# Licensed under GNU General Public License v3.0 GPL-3 (in short)
#
#   You may copy, distribute and modify the software as long as you track
#   changes/dates in source files. Any modifications to our software
#   including (via compiler) GPL-licensed code must also be made available
#   under the GPL along with build & install instructions.
#

echo "HOST = '127.0.0.1'" >> /opt/swizzin/swizzin.cfg

if [[ -f /install/.authelia.lock ]]; then
    cat > /etc/nginx/apps/panel.conf << 'EON'
location / {
    auth_request /_authz;
    auth_request_set $authelia_user $upstream_http_remote_user;
    auth_request_set $authelia_redirect $upstream_http_location;
    error_page 401 = @authelia_redirect;

    proxy_set_header Host $host;
    proxy_set_header X-Real-IP $remote_addr;
    proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Host $host;
    proxy_set_header X-Forwarded-Proto $scheme;
    proxy_set_header X-Forwarded-User $authelia_user;
    include /etc/nginx/auth-secure/panel-secret.conf;
    proxy_set_header Origin "";
    proxy_set_header Authorization "";
    proxy_pass http://127.0.0.1:8333;
    proxy_http_version 1.1;
    proxy_set_header Upgrade $http_upgrade;
    proxy_set_header Connection "Upgrade";
}
EON
else
    cat > /etc/nginx/apps/panel.conf << 'EON'
location / {
  proxy_set_header Host $host;
  proxy_set_header X-Real-IP $remote_addr;
  proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
  proxy_set_header X-Forwarded-Host $host;
  proxy_set_header X-Forwarded-Proto $scheme;
  proxy_set_header Origin "";
  proxy_pass http://127.0.0.1:8333;
  proxy_http_version 1.1;
  proxy_set_header Upgrade $http_upgrade;
  proxy_set_header Connection "Upgrade";
}
EON
fi