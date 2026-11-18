#!/usr/bin/env bash
# Backup the Mute Wikibase: MariaDB dump + image/quickstatements volumes + config.
# Output: /var/backups/mute-wikibase/<timestamp>/ ; keeps the newest $KEEP sets.
# Off-server copy is a separate step (see documentation/deployment.md) - a backup
# that only lives on the same disk is not a backup.
#
# The dump is written INSIDE the mysql container with --result-file and copied out
# with docker cp (never shell-redirected: avoids encoding/truncation problems).
set -euo pipefail

ROOT=/opt/mute-wikibase
DEST_BASE=/var/backups/mute-wikibase
KEEP="${KEEP:-7}"
STAMP="$(date +%Y%m%d-%H%M%S)"
DEST="$DEST_BASE/$STAMP"
PROJECT=mute-wikibase-prod
ENV_FILE="$ROOT/wikibase-suite/.env"

get() { grep -E "^$1=" "$ENV_FILE" | head -1 | cut -d= -f2-; }
DB_NAME="$(get DB_NAME)"; DB_USER="$(get DB_USER)"; DB_PASS="$(get DB_PASS)"

mkdir -p "$DEST"; chmod 700 "$DEST_BASE" "$DEST"
MYSQL="${PROJECT}-mysql-1"

echo "[1/4] database dump"
docker exec -e MYSQL_PWD="$DB_PASS" "$MYSQL" \
  mariadb-dump --single-transaction --quick --default-character-set=utf8mb4 \
  -u "$DB_USER" --result-file=/tmp/backup.sql "$DB_NAME"
docker cp "$MYSQL:/tmp/backup.sql" "$DEST/my_wiki.sql"
docker exec "$MYSQL" rm -f /tmp/backup.sql
gzip -f "$DEST/my_wiki.sql"

echo "[2/4] volumes (images, quickstatements)"
for v in wikibase-image-data quickstatements-data; do
  docker run --rm -v "${PROJECT}_${v}:/data:ro" -v "$DEST:/out" alpine \
    tar czf "/out/${v}.tar.gz" -C /data .
done

echo "[3/4] config (no .env secrets in the clear: .env is copied with mode 600)"
tar czf "$DEST/config.tar.gz" -C "$ROOT" docker-compose.override.prod.yml config scripts etl xml
cp "$ENV_FILE" "$DEST/env.backup"; chmod 600 "$DEST/env.backup"

echo "[4/4] retention (keep $KEEP)"
ls -1dt "$DEST_BASE"/*/ | tail -n +$((KEEP + 1)) | xargs -r rm -rf

echo "done: $DEST"; ls -la "$DEST"; du -sh "$DEST"
