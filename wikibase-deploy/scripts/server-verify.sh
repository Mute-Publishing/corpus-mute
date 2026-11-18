#!/usr/bin/env bash
# Read-only health check of the Mute Wikibase production stack.
DOMAIN="${1:-corpus.metamute.org}"
echo "== containers"; docker ps --format '{{.Names}}\t{{.Status}}'
echo "== traefik cert log"; docker logs mute-wikibase-prod-traefik-1 2>&1 | grep -i -E 'acme|certificate|unable|error' | tail -5
echo "== https"
for u in /wiki/Main_Page /query/ /tools/quickstatements/ ; do
  printf '%-28s ' "$u"
  curl -s -o /dev/null -w '%{http_code} verify=%{ssl_verify_result}\n' "https://$DOMAIN$u"
done
printf '%-28s ' "sparql"
curl -s -o /dev/null -w '%{http_code}\n' -G "https://$DOMAIN/query/proxy/sparql" --data-urlencode 'query=SELECT * WHERE {?s ?p ?o} LIMIT 1'
printf '%-28s ' "http redirect"
curl -s -o /dev/null -w '%{http_code} -> %{redirect_url}\n' "http://$DOMAIN/"
echo "== cert"
echo | openssl s_client -servername "$DOMAIN" -connect "$DOMAIN:443" 2>/dev/null | openssl x509 -noout -issuer -dates -subject 2>&1
echo "== memory"; free -m | sed -n 1,3p
