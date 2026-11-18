#!/usr/bin/env bash
# Count Mute issues three ways: MediaWiki search index, SPARQL, and a re-run of
# the importer (must create 0). Read-mostly; the re-run only skips existing items.
DOMAIN="${1:-corpus.metamute.org}"
STATE=/opt/mute-wikibase/output/bootstrap.prod.json
CLASS=$(python3 -c "import json;print(json.load(open('$STATE'))['items']['class_issue'])")
LOCALID=$(python3 -c "import json;print(json.load(open('$STATE'))['properties']['local_id'])")

echo "== SPARQL: items with a Mute issue ID ($LOCALID)"
curl -s -G "https://$DOMAIN/query/proxy/sparql" -H 'Accept: application/sparql-results+json' \
  --data-urlencode "query=PREFIX wdt: <https://$DOMAIN/prop/direct/> SELECT (COUNT(DISTINCT ?i) AS ?n) WHERE { ?i wdt:$LOCALID ?id }" \
  | python3 -c 'import sys,json; print(json.load(sys.stdin)["results"]["bindings"][0]["n"]["value"])'

echo "== SPARQL: issues per volume"
curl -s -G "https://$DOMAIN/query/proxy/sparql" -H 'Accept: application/sparql-results+json' \
  --data-urlencode "query=PREFIX wdt: <https://$DOMAIN/prop/direct/> SELECT ?v (COUNT(?i) AS ?n) WHERE { ?i wdt:$LOCALID ?id ; wdt:P5 ?v } GROUP BY ?v ORDER BY ?v" \
  | python3 -c 'import sys,json
for b in json.load(sys.stdin)["results"]["bindings"]: print(" vol", b["v"]["value"], "->", b["n"]["value"])'

echo "== importer re-run (expect created 0)"
bash /opt/mute-wikibase/scripts/server-load.sh import 2>&1 | tail -3
