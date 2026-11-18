#!/usr/bin/env bash
# DESTRUCTIVE: removes the previous ClimateKG deployment from the server so the
# Mute Wikibase can be installed fresh. Requires --yes. Run only after a human
# has confirmed (see AGENTS-style rules: destructive actions need confirmation).
#
# Removes:
#   - ALL docker containers, images, volumes, networks, build cache
#   - /opt/wikibase (old ClimateKG repo clone, incl. its uncommitted edits)
#   - the host Nginx site config for the old domain
# Stops and disables (but does not uninstall):
#   - nginx and certbot.timer (Traefik must own ports 80/443)
# Leaves in place: /etc/letsencrypt (old certs), ufw rules, SSH config, users.
#
# Usage: ssh -i ~/.ssh/id_wikibase_sync root@<ip> 'bash -s -- --yes' < scripts/server-wipe.sh
set -euo pipefail

[ "${1:-}" = "--yes" ] || { echo "Refusing to run without --yes" >&2; exit 1; }
[ "$(hostname)" = "PROD-ClimateKG" ] || { echo "Unexpected hostname $(hostname); aborting" >&2; exit 1; }

echo "== start docker daemon (needed to remove its data cleanly)"
systemctl start docker
for i in $(seq 1 20); do docker info >/dev/null 2>&1 && break; sleep 2; done
docker info >/dev/null

echo "== before"; docker ps -a --format '{{.Names}}' | wc -l; docker volume ls -q | wc -l; df -h / | tail -1

echo "== remove containers, images, volumes, networks"
docker ps -aq | xargs -r docker rm -f
docker system prune -af --volumes
docker builder prune -af || true

echo "== stop host nginx + certbot timer"
systemctl disable --now nginx
systemctl disable --now certbot.timer 2>/dev/null || true
rm -f /etc/nginx/sites-enabled/wikibase /etc/nginx/sites-available/wikibase

echo "== remove old repo"
rm -rf /opt/wikibase

echo "== after"; docker ps -a | wc -l; docker volume ls -q | wc -l; df -h / | tail -1
ss -tlnp | grep -E ':(80|443)\b' || echo "ports 80/443 free"
