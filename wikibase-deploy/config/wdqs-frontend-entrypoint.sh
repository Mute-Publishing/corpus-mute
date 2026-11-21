#!/bin/sh
# Custom entrypoint for wdqs-frontend that adds a URL shortener proxy.
# Mounted at /entrypoint.sh in the container by docker-compose.override.*.yml.
set -e

# Original entrypoint logic (from wikibase/wdqs-frontend:2 image):
cp /config/wdqs-frontend-config.json /usr/share/nginx/html/custom-config.json

envsubst < /templates/nginx-default.conf.template > /etc/nginx/conf.d/default.conf

# Append the URL shortener proxy location INSIDE the server block.
# Insert before the closing } of the server block.
sed -i '/^}$/i\
    # URL shortener proxy (TinyURL) - avoids CORS/CSP issues.\
    location /shorten {\
        resolver 8.8.8.8 1.1.1.1 valid=300s;\
        resolver_timeout 10s;\
        set $tinyurl_url "http://tinyurl.com/api-create.php?url=$arg_url";\
        proxy_pass $tinyurl_url;\
        proxy_set_header Host tinyurl.com;\
        proxy_set_header Connection "";\
        proxy_http_version 1.1;\
        proxy_hide_header X-Frame-Options;\
        proxy_hide_header Content-Security-Policy;\
        add_header Access-Control-Allow-Origin *;\
        add_header Content-Type text/plain;\
    }\
    # Disable caching for patched JS files so browser picks up changes immediately.\
    location ~* /wikibase/(init|embedInit)\\.mjs$ {\
        root /usr/share/nginx/html;\
        add_header Cache-Control "no-cache, no-store, must-revalidate";\
        add_header Pragma no-cache;\
        add_header Expires 0;\
    }' /etc/nginx/conf.d/default.conf

exec "$@"