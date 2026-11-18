#!/usr/bin/env bash
DOMAIN="${1:-corpus.metamute.org}"
echo "== redirect target of Project:SPARQL/examples"
curl -s -o /dev/null -w '%{http_code} -> %{redirect_url}\n' "https://$DOMAIN/wiki/Project:SPARQL/examples"
echo "== final page status (follow redirects)"
curl -sL -o /dev/null -w '%{http_code} %{url_effective}\n' "https://$DOMAIN/wiki/Project:SPARQL/examples"
echo "== project namespace name"
curl -s "https://$DOMAIN/w/api.php?action=query&meta=siteinfo&siprop=namespaces&format=json" | python3 -c 'import sys,json; n=json.load(sys.stdin)["query"]["namespaces"]["4"]; print(n)'
echo "== query UI config"
docker exec mute-wikibase-prod-wdqs-frontend-1 cat /usr/share/nginx/html/custom-config.json 2>&1 | head -40
