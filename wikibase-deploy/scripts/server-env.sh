#!/usr/bin/env bash
# Create /opt/mute-wikibase/wikibase-suite/.env for PRODUCTION with random
# passwords generated here on the server. Passwords are never printed.
# Refuses to overwrite an existing .env (changing .env after first start needs a
# WBS instance reset, which is destructive).
#
# Read the admin login later on the server with:
#   grep -E '^MW_ADMIN_(NAME|PASS)=' /opt/mute-wikibase/wikibase-suite/.env
set -euo pipefail

ENV_FILE=/opt/mute-wikibase/wikibase-suite/.env
DOMAIN="${1:-corpus.metamute.org}"
EMAIL="${2:-simon.worthington@tib.eu}"

if [ -e "$ENV_FILE" ]; then
  echo "exists, not overwriting: $ENV_FILE"; ls -l "$ENV_FILE"; exit 0
fi

gen() { openssl rand -base64 33 | tr -d '/+=\n' | cut -c1-28; }

umask 077
{
  echo "WIKIBASE_PUBLIC_HOST=$DOMAIN"
  echo "WDQS_PUBLIC_HOST=$DOMAIN"
  echo "MW_ADMIN_NAME=admin"
  echo "MW_ADMIN_EMAIL=$EMAIL"
  echo "MW_ADMIN_PASS=$(gen)"
  echo "DB_PASS=$(gen)"
  echo "DB_NAME=my_wiki"
  echo "DB_USER=sqluser"
  echo "METADATA_CALLBACK=true"
  echo "WIKIMEDIA_OAUTH_CONSUMER_TOKEN="
  echo "WIKIMEDIA_OAUTH_SECRET_TOKEN="
} > "$ENV_FILE"

echo "created $ENV_FILE (passwords hidden)"
ls -l "$ENV_FILE"
sed -E 's/(PASS)=.*/\1=<hidden>/' "$ENV_FILE"
