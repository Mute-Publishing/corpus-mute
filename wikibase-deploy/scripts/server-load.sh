#!/usr/bin/env bash
# Run the Mute uploader ON THE SERVER so the admin password never leaves it.
# The password is read from wikibase-suite/.env into the environment of the
# python process only (never printed).
#
# Usage: server-load.sh bootstrap|import  [--dry]
#   LIMIT=1 server-load.sh import          # first issue only
set -euo pipefail

MODE="${1:?usage: server-load.sh bootstrap|import [--dry]}"
ENV_FILE=/opt/mute-wikibase/wikibase-suite/.env
[ -f "$ENV_FILE" ] || { echo "missing $ENV_FILE" >&2; exit 1; }

get() { grep -E "^$1=" "$ENV_FILE" | head -1 | cut -d= -f2-; }

export WB_TARGET=prod
export WB_API="https://$(get WIKIBASE_PUBLIC_HOST)/w/api.php"
export WB_USER="$(get MW_ADMIN_NAME)"
export WB_PASSWORD="$(get MW_ADMIN_PASS)"
[ "${2:-}" = "--dry" ] && export DRY_RUN=true

mkdir -p /opt/mute-wikibase/output
python3 --version
exec python3 /opt/mute-wikibase/etl/upload_to_wikibase.py "$MODE"
