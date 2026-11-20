#!/usr/bin/env bash
# Server half of scripts/sync-env.ps1. Run on the PRODUCTION server.
#
#   server-sync.sh dump              content dump -> /opt/mute-wikibase/sync/outgoing.sql
#   server-sync.sh restore [FILE]    safety backup, restore FILE (default sync/incoming.sql),
#                                    then rebuild search index + reset SPARQL (WDQS)
#   server-sync.sh counts            items/properties/pages/revisions
#
# Prints "SYNC-OK: <step>" as its last line when a step succeeded; the Windows
# wrapper looks for that marker. Credentials stay inside the mysql container.
set -euo pipefail

ROOT=/opt/mute-wikibase
PROJECT=mute-wikibase-prod
MYSQL="${PROJECT}-mysql-1"
WB="${PROJECT}-wikibase-1"
SYNC_DIR="$ROOT/sync"
SAFETY_DIR=/var/backups/mute-wikibase
COMPOSE="docker compose -f $ROOT/wikibase-suite/docker-compose.yml -f $ROOT/docker-compose.override.prod.yml --project-directory $ROOT/wikibase-suite"

mkdir -p "$SYNC_DIR"; chmod 700 "$SYNC_DIR"
install_helper() { docker cp "$ROOT/scripts/sync-db.sh" "$MYSQL:/tmp/sync-db.sh"; }

case "${1:?usage: server-sync.sh dump|restore [FILE]|counts}" in
  dump)
    install_helper
    docker exec "$MYSQL" sh /tmp/sync-db.sh dump /tmp/mute-sync.sql
    docker cp "$MYSQL:/tmp/mute-sync.sql" "$SYNC_DIR/outgoing.sql"
    docker exec "$MYSQL" rm -f /tmp/mute-sync.sql
    chmod 600 "$SYNC_DIR/outgoing.sql"
    docker exec "$MYSQL" sh /tmp/sync-db.sh counts
    echo "SYNC-OK: dump"
    ;;
  counts)
    install_helper
    docker exec "$MYSQL" sh /tmp/sync-db.sh counts
    echo "SYNC-OK: counts"
    ;;
  restore)
    IN="${2:-$SYNC_DIR/incoming.sql}"
    [ -s "$IN" ] || { echo "missing $IN" >&2; exit 2; }
    install_helper

    echo "[1/5] safety backup of current production (full dump)"
    STAMP="$(date +%Y%m%d-%H%M%S)"
    docker exec "$MYSQL" sh /tmp/sync-db.sh dump-full /tmp/pre-sync.sql
    mkdir -p "$SAFETY_DIR"; chmod 700 "$SAFETY_DIR"
    docker cp "$MYSQL:/tmp/pre-sync.sql" "$SAFETY_DIR/pre-sync-$STAMP.sql"
    docker exec "$MYSQL" rm -f /tmp/pre-sync.sql
    gzip -f "$SAFETY_DIR/pre-sync-$STAMP.sql"; chmod 600 "$SAFETY_DIR/pre-sync-$STAMP.sql.gz"
    echo "      saved $SAFETY_DIR/pre-sync-$STAMP.sql.gz"

    echo "[2/5] restore"
    docker cp "$IN" "$MYSQL:/tmp/mute-sync.sql"
    docker exec "$MYSQL" sh /tmp/sync-db.sh restore /tmp/mute-sync.sql
    docker exec "$MYSQL" rm -f /tmp/mute-sync.sql

    echo "[3/5] rebuild recent changes"
    docker exec "$WB" php /var/www/html/maintenance/run.php rebuildrecentchanges | tail -n 1

    echo "[4/5] rebuild search index"
    docker exec "$WB" php /var/www/html/maintenance/run.php \
      /var/www/html/extensions/CirrusSearch/maintenance/ForceSearchIndex.php --skipLinks --indexOnSkip | tail -n 1

    echo "[5/5] reset SPARQL (WDQS) so it reloads from the restored data"
    $COMPOSE stop wdqs-updater wdqs
    docker run --rm -v "${PROJECT}_wdqs-data:/d" alpine sh -c 'rm -f /d/*.jnl'
    $COMPOSE up -d wdqs wdqs-updater
    rm -f "$IN"

    docker exec "$MYSQL" sh /tmp/sync-db.sh counts
    echo "SYNC-OK: restore"
    ;;
  *) echo "unknown command" >&2; exit 2 ;;
esac
