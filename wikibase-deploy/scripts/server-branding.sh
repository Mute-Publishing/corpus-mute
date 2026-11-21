#!/usr/bin/env bash
# Apply the Mute branding/skin settings on the PRODUCTION server (idempotent, non-destructive).
#   - installs MobileFrontend (branch must match the image's MediaWiki: 8.3.0 = 1.46) in config/extensions
#   - appends the mute-local-settings.php include to wikibase-suite/config/LocalSettings.php (once)
#   - recreates wikibase + jobrunner so the new mounts/settings load (up -d, never down -v)
# Files it relies on are pushed beforehand: config/mute-local-settings.php, config/Mute_logo_2011-.jpg,
# docker-compose.override.prod.yml.
set -euo pipefail
cd /opt/mute-wikibase

EXT=wikibase-suite/config/extensions/MobileFrontend
if [ -d "$EXT/.git" ] || [ -f "$EXT/extension.json" ]; then
  echo "MobileFrontend already present"
else
  git clone --depth 1 --branch REL1_46 https://gerrit.wikimedia.org/r/mediawiki/extensions/MobileFrontend "$EXT"
fi

LS=wikibase-suite/config/LocalSettings.php
if grep -q 'mute-local-settings.php' "$LS"; then
  echo "LocalSettings.php include already present"
else
  cp "$LS" "$LS.bak-$(date +%Y%m%d-%H%M%S)"
  cat >> "$LS" <<'PHP'

# Mute branding (site name + logo + skin + term languages), mounted by docker-compose.override.prod.yml.
if ( is_file( '/mute-local-settings.php' ) ) {
	require_once '/mute-local-settings.php';
}
PHP
  echo "LocalSettings.php include added"
fi

COMPOSE="docker compose -f wikibase-suite/docker-compose.yml -f docker-compose.override.prod.yml --project-directory wikibase-suite"
$COMPOSE config -q && echo "compose config OK"
$COMPOSE up -d wikibase wikibase-jobrunner 2>&1 | tail -10

echo "waiting for wikibase to be healthy..."
for i in $(seq 1 60); do
  s=$(docker inspect -f '{{.State.Health.Status}}' mute-wikibase-prod-wikibase-1 2>/dev/null || echo none)
  [ "$s" = healthy ] && { echo "wikibase healthy"; exit 0; }
  sleep 5
done
echo "wikibase NOT healthy after 5 min" >&2
docker logs --tail 30 mute-wikibase-prod-wikibase-1 >&2 || true
exit 1
