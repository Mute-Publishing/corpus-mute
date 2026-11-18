#!/usr/bin/env bash
# Print label + statement properties of one item via the public EntityData URL.
# Usage: server-check-item.sh Q4 [domain]
ID="${1:?item id}"
DOMAIN="${2:-corpus.metamute.org}"
curl -s "https://$DOMAIN/wiki/Special:EntityData/$ID.json" | python3 -c '
import sys, json
d = json.load(sys.stdin)["entities"]
e = next(iter(d.values()))
print(e["id"], "|", e["labels"]["en"]["value"], "|", e["descriptions"]["en"]["value"])
for pid, cl in sorted(e["claims"].items(), key=lambda x: int(x[0][1:])):
    v = cl[0]["mainsnak"]["datavalue"]["value"]
    print(" ", pid, "=", v if not isinstance(v, dict) else v.get("id", v))
'
