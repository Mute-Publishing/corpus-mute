#!/usr/bin/env python3
"""
wikidata_match.py - match the Mute issues in xml/mute-issues.xml to existing
Wikidata items and prepare a QuickStatements V1 file for HUMAN review.

Nothing is written to Wikidata by this script. Standard library only.

Why not SPARQL: WDQS currently answers 429 ("1 req / min"), and the search index
does not return reliable haswbstatement results for P1433. So candidates are
found with a few full-text searches, then every candidate is fetched and
checked (label parsed for volume/number, statements P1433/P361/P31).

Status per issue:
  matched    label vol/no equal AND item is linked to Mute Magazine (Q6943763)
  candidate  label vol/no equal but no link to Mute Magazine (check by hand)
  unmatched  nothing found -> a CREATE block is written to the QuickStatements file

Outputs (mute-er-model/output/):
  wikidata_match_report.csv, wikidata_quickstatements.txt  (REVIEW before upload)
"""

from __future__ import annotations

import csv
import json
import re
import time
import urllib.error
import urllib.parse
import urllib.request
import xml.etree.ElementTree as ET
from collections import Counter
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
XML_PATH = ROOT / "xml" / "mute-issues.xml"
OUT_DIR = ROOT / "output"
UA = {"User-Agent": "corpus-mute-match/0.1 (Mute Publishing; research)"}
WD_API = "https://www.wikidata.org/w/api.php"

Q_MUTE = "Q6943763"
Q_ISSUE = "Q28869365"
Q_ENGLISH = "Q1860"

SEARCHES = ["Mute Magazine Vol", "Mute Vol", "Mute Vol. No.", "Mute magazine issue",
            "Mute issue 1994", "Mute magazine Vol 2"]

LABEL_RE = re.compile(r"Vol\.?\s*(\d+)\s*,?\s*No\.?\s*(\d+)", re.I)


def api(params: dict) -> dict:
    url = f"{WD_API}?{urllib.parse.urlencode({**params, 'format': 'json', 'formatversion': 2})}"
    for attempt in range(5):
        try:
            with urllib.request.urlopen(urllib.request.Request(url, headers=UA), timeout=60) as r:
                time.sleep(1.0)
                return json.load(r)
        except urllib.error.HTTPError as exc:
            if exc.code == 429 and attempt < 4:
                time.sleep(10 * (attempt + 1))
                continue
            raise
    raise RuntimeError("unreachable")


def item_ids(entity: dict, pid: str) -> list[str]:
    out = []
    for c in entity.get("claims", {}).get(pid, []):
        v = c["mainsnak"].get("datavalue", {}).get("value")
        if isinstance(v, dict) and "id" in v:
            out.append(v["id"])
    return out


def norm(s: str) -> str:
    return s.strip().lstrip("0") or "0"


def find_candidates() -> list[dict]:
    qids: list[str] = []
    for s in SEARCHES:
        res = api({"action": "query", "list": "search", "srsearch": s, "srlimit": 100, "srnamespace": 0})
        qids += [h["title"] for h in res["query"]["search"]]
    qids = sorted(set(qids))
    out = []
    for i in range(0, len(qids), 50):
        ents = api({"action": "wbgetentities", "ids": "|".join(qids[i:i + 50]),
                    "props": "labels|claims", "languages": "en"})["entities"]
        for qid, e in ents.items():
            label = e.get("labels", {}).get("en", {}).get("value", "")
            m = LABEL_RE.search(label)
            if not m or "mute" not in label.lower():
                continue
            linked = Q_MUTE in item_ids(e, "P1433") + item_ids(e, "P361")
            out.append({"qid": qid, "label": label, "vol": m.group(1), "no": m.group(2),
                        "linked": linked, "is_issue": Q_ISSUE in item_ids(e, "P31")})
    return out


def qs_create(d: dict) -> list[str]:
    t = "\t"
    year, month = d["publication_date"].split("-")
    lines = ["CREATE",
             f'LAST{t}Len{t}"{d["label"]}"',
             f'LAST{t}Den{t}"issue of Mute magazine, {d["publication_date"]}"',
             f"LAST{t}P31{t}{Q_ISSUE}",
             f"LAST{t}P1433{t}{Q_MUTE}",
             f"LAST{t}P361{t}{Q_MUTE}",
             f'LAST{t}P478{t}"{d["volume"]}"',
             f'LAST{t}P433{t}"{d["number"]}"',
             f"LAST{t}P577{t}+{year}-{month}-00T00:00:00Z/10",
             f"LAST{t}P407{t}{Q_ENGLISH}",
             f'LAST{t}P953{t}"{d["source_url"]}"']
    if d.get("title"):
        lines.append(f'LAST{t}P1476{t}en:"{d["title"].replace(chr(34), chr(39))}"')
    if d.get("isbn13"):
        lines.append(f'LAST{t}P212{t}"{d["isbn13"]}"')
    return lines


def main() -> None:
    issues = [{c.tag: (c.text or "").strip() for c in i}
              for i in ET.parse(XML_PATH).getroot().findall("issue")]
    cands = find_candidates()
    print(f"{len(cands)} candidate Wikidata item(s) with a Mute Vol/No label:")
    for c in cands:
        print(f"  {c['qid']:12} Vol {c['vol']} No {c['no']:3} linked={c['linked']} issue={c['is_issue']}  {c['label']}")

    rows, qs = [], []
    for d in issues:
        hit = next((c for c in cands if norm(c["vol"]) == norm(d["volume"])
                    and norm(c["no"]) == norm(d["number"])), None)
        if hit:
            status = "matched" if hit["linked"] else "candidate"
            note = "" if hit["is_issue"] else "item is not instance of issue (Q28869365)"
            rows.append({"local_id": d["local_id"], "label": d["label"], "status": status,
                         "wikidata_qid": hit["qid"], "wikidata_label": hit["label"], "note": note})
        else:
            rows.append({"local_id": d["local_id"], "label": d["label"], "status": "unmatched",
                         "wikidata_qid": "", "wikidata_label": "", "note": ""})
            qs.extend(qs_create(d))

    OUT_DIR.mkdir(exist_ok=True)
    with open(OUT_DIR / "wikidata_match_report.csv", "w", newline="", encoding="utf-8") as f:
        w = csv.DictWriter(f, fieldnames=list(rows[0]))
        w.writeheader()
        w.writerows(rows)
    (OUT_DIR / "wikidata_quickstatements.txt").write_text("\n".join(qs) + "\n", encoding="utf-8")
    print(dict(Counter(r["status"] for r in rows)))
    print("Wrote output/wikidata_match_report.csv and output/wikidata_quickstatements.txt (REVIEW before upload)")


if __name__ == "__main__":
    main()
