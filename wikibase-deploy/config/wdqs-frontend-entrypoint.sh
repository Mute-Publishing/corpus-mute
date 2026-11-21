#!/bin/sh
# Custom entrypoint for wdqs-frontend (no-cache headers for the patched JS).
# URL shortening is NOT done here: the patched init.mjs calls the wiki's own
# /w/api.php?action=shortenurl (MediaWiki UrlShortener extension) on the same origin.
# Mounted at /entrypoint.sh in the container by docker-compose.override.*.yml.
set -e

# Original entrypoint logic (from wikibase/wdqs-frontend:2 image):
cp /config/wdqs-frontend-config.json /usr/share/nginx/html/custom-config.json

envsubst < /templates/nginx-default.conf.template > /etc/nginx/conf.d/default.conf

# Append to the server block, before its closing }.
sed -i '/^}$/i\
    # Disable caching for patched JS files so browser picks up changes immediately.\
    location ~* /wikibase/(init|embedInit)\\.mjs$ {\
        root /usr/share/nginx/html;\
        add_header Cache-Control "no-cache, no-store, must-revalidate";\
        add_header Pragma no-cache;\
        add_header Expires 0;\
    }' /etc/nginx/conf.d/default.conf

exec "$@"