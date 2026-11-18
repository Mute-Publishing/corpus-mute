#!/usr/bin/env bash
# Start (or update) the Mute Wikibase production stack on the server.
# Non-destructive: uses `up -d`, never `down -v`.
set -euo pipefail
cd /opt/mute-wikibase

systemctl enable --now docker >/dev/null 2>&1 || true
test -f wikibase-suite/.env || { echo "missing wikibase-suite/.env - run server-env.sh first" >&2; exit 1; }

COMPOSE="docker compose -f wikibase-suite/docker-compose.yml -f docker-compose.override.prod.yml --project-directory wikibase-suite"

$COMPOSE config -q && echo "compose config OK"
$COMPOSE up -d 2>&1 | tail -25
$COMPOSE ps --format 'table {{.Service}}\t{{.Status}}'
