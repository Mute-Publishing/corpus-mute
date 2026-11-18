#!/usr/bin/env bash
# Run every sparql block of a wiki examples file against the live endpoint and
# print the row count and first rows. Usage: server-query-test.sh [file] [domain]
FILE="${1:-/opt/mute-wikibase/config/sparql-examples.wiki}"
DOMAIN="${2:-corpus.metamute.org}"
python3 - "$FILE" "$DOMAIN" <<'PY'
import json, re, sys, urllib.parse, urllib.request
path, domain = sys.argv[1], sys.argv[2]
text = open(path, encoding="utf-8").read()
blocks = re.findall(r'=== (.+?) ===\s*<syntaxhighlight lang="sparql">\n(.*?)</syntaxhighlight>', text, re.S)
for title, q in blocks:
    url = f"https://{domain}/query/proxy/sparql?" + urllib.parse.urlencode({"query": q})
    req = urllib.request.Request(url, headers={"Accept": "application/sparql-results+json"})
    try:
        d = json.load(urllib.request.urlopen(req, timeout=60))
    except Exception as e:  # noqa: BLE001
        body = getattr(e, "read", lambda: b"")().decode("utf-8", "replace")[:600]
        print(f"## {title}\n   FAILED: {e}\n{body}")
        continue
    cols = d["head"]["vars"]
    rows = d["results"]["bindings"]
    print(f"## {title}\n   rows={len(rows)} cols={cols}")
    for r in rows[:5] + rows[-2:]:
        print("  ", " | ".join(r.get(c, {}).get("value", "")[:38] for c in cols[:8]))
PY
