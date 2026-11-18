#!/usr/bin/env bash
# Load the repo-tracked wiki pages into the running PRODUCTION wiki (idempotent:
# re-saving unchanged text is a no-op). Run on the server.
#   config/sparql-examples.wiki -> Project:SPARQL/examples  (Query UI "Examples" dialog)
set -euo pipefail

ROOT=/opt/mute-wikibase
CONTAINER=mute-wikibase-prod-wikibase-1

load_page() {
  local file="$1" title="$2" summary="$3"
  docker cp "$ROOT/$file" "$CONTAINER:/tmp/page.wikitext"
  docker exec "$CONTAINER" sh -c \
    "php /var/www/html/maintenance/run.php edit --user \"\$MW_ADMIN_NAME\" --summary \"$summary\" \"$title\" < /tmp/page.wikitext; rm -f /tmp/page.wikitext"
}

load_page "config/sparql-examples.wiki" "Project:SPARQL/examples" "Load Query UI examples from repo"
