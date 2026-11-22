#!/bin/sh
# Patch the Wikibase Query Service UI (wikibase/wdqs-frontend image) so its URL shortener
# talks to THIS wiki's own MediaWiki UrlShortener extension instead of TinyURL / Wikimedia.
#
# It adds a provider named "local" (use  "urlShortener": "local"  in the frontend config) that
# POSTs  action=shortenurl  to the relative URL /w/api.php (same origin, so no CORS and no
# third party). Applies to the two bundles that contain the shortener: init.mjs and embedInit.mjs.
#
# Usage (the files come out of the image, see docs/url-shortener.md):
#   patch-wdqs-shortener.sh IN.mjs OUT.mjs
#
# The edit is a pair of regex substitutions on the minified bundle, tolerant of the variable names
# changing between builds. It aborts (non-zero) if either expected spot is not found exactly once,
# which is what you will see if a future wdqs-frontend release changes the code: re-read the
# UrlShortener source (wikibase/queryService/api/UrlShortener.js upstream) and adjust.
set -eu

[ $# -eq 2 ] || { echo "usage: $0 IN.mjs OUT.mjs" >&2; exit 2; }
IN=$1
OUT=$2

# 1. register the "local" provider next to the built-in ones:
#      wikibeta:function(X){return this._getWikiShort(X,"en.wikipedia.beta.wmflabs.org")}
#    -> same, followed by  ,local:function(X){return this._getWikiShort(X,"")}
# 2. let an empty server name mean "same origin":
#      url:"https://"+S+"/w/api.php"   ->   url:(S?"https://"+S:"")+"/w/api.php"
sed -E \
  -e 's#(wikibeta:function\(([A-Za-z_$]+)\)\{return this\._getWikiShort\(\2,"en\.wikipedia\.beta\.wmflabs\.org"\)\})#\1,local:function(\2){return this._getWikiShort(\2,"")}#' \
  -e 's#url:"https://"\+([A-Za-z_$]+)\+"/w/api\.php"#url:(\1?"https://"+\1:"")+"/w/api.php"#' \
  "$IN" > "$OUT"

n1=$(grep -o 'local:function' "$OUT" | wc -l)
n2=$(grep -o '"")+"/w/api.php"' "$OUT" | wc -l)
if [ "$n1" -ne 1 ] || [ "$n2" -ne 1 ]; then
  echo "ABORT: expected exactly one provider and one URL patch in $IN (got $n1 and $n2)." >&2
  echo "The upstream code probably changed; see the notes in this script." >&2
  rm -f "$OUT"
  exit 1
fi
echo "patched $IN -> $OUT"
