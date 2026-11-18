#!/usr/bin/env python3
"""
upload_to_wikibase.py - load xml/mute-issues.xml into a Wikibase.

Standard library only (the workspace Python is 3.16 alpha without wheels), using
the MediaWiki Action API (login with a bot password or the admin account).

Two-step pattern (same idea as the ClimateKG authors uploader):

  bootstrap   Create the "Issue" class item and all properties, plus a
              "Wikidata equivalent" property. Writes the created IDs to
              mute-er-model/output/bootstrap.<target>.json  (gitignored).
  import      Read bootstrap.<target>.json, create one item per <issue>.
              Idempotent: an item is skipped if one already carries the same
              Mute local ID (looked up through the API search + claim check).

Environment variables
  WB_TARGET      local | prod                 (default: local)
  WB_API         MediaWiki API URL            (default by target)
  WB_USER        login name                   (default: admin)
  WB_PASSWORD    password                     (required; never printed)
  DRY_RUN        true -> print only
  LIMIT, OFFSET  process a slice of the issues

Usage
  $env:WB_PASSWORD = "..."          # type it yourself, do not paste into chat
  python mute-er-model/etl/upload_to_wikibase.py bootstrap
  python mute-er-model/etl/upload_to_wikibase.py import
"""

from __future__ import annotations

import http.cookiejar
import json
import os
import re
import sys
import time
import urllib.parse
import urllib.request
import xml.etree.ElementTree as ET
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
XML_PATH = ROOT / "xml" / "mute-issues.xml"
TARGET = os.getenv("WB_TARGET", "local")
STATE_PATH = ROOT / "output" / f"bootstrap.{TARGET}.json"
LOG_PATH = ROOT / "output" / f"upload_log.{TARGET}.json"

DEFAULT_API = {
    "local": "http://localhost:8091/w/api.php",
    "prod": "https://corpus.metamute.org/w/api.php",
}
API = os.getenv("WB_API", DEFAULT_API.get(TARGET, DEFAULT_API["local"]))
USER = os.getenv("WB_USER", "admin")
PASSWORD = os.getenv("WB_PASSWORD", "")
DRY_RUN = os.getenv("DRY_RUN", "false").lower() == "true"
LIMIT = int(os.getenv("LIMIT", "0"))
OFFSET = int(os.getenv("OFFSET", "0"))

# ---------------------------------------------------------------------------
# Schema: key -> (label, description, datatype, wikidata equivalent)
# Wikidata IDs verified live 2026-11-18.
# ---------------------------------------------------------------------------
PROPERTIES: dict[str, tuple[str, str, str, str]] = {
    "instance_of":      ("instance of", "Class this item is an instance of", "wikibase-item", "P31"),
    "local_id":         ("Mute issue ID", "Stable local identifier of a Mute issue (MI001...)", "external-id", ""),
    "series":           ("published in", "Series (periodical) the issue was published in", "wikibase-item", "P1433"),
    "title":            ("title", "Thematic title of the issue", "monolingualtext", "P1476"),
    "volume":           ("volume", "Volume number", "string", "P478"),
    "number":           ("issue number", "Issue number within the volume", "string", "P433"),
    "publication_date": ("publication date", "Date the issue was published (month precision)", "time", "P577"),
    "issn":             ("ISSN", "ISSN of the series", "external-id", "P236"),
    "issn_issue_token": ("issue ISSN token", "Per-issue ISSN-style token used by Mute (local convention)", "external-id", ""),
    "isbn13":           ("ISBN-13", "ISBN-13 of the issue (checksum valid only)", "external-id", "P212"),
    "isbn_raw":         ("ISBN as catalogued", "ISBN string as written in the source, not validated", "string", ""),
    "source_url":       ("described at URL", "Web page of the issue on metamute.org", "url", "P953"),
    "language":         ("language of work", "Language of the issue", "wikibase-item", "P407"),
    "edition_note":     ("edition note", "Edition statement, e.g. second edition", "string", ""),
    "insert_note":      ("insert note", "Inserts, CDs or booklets issued with the issue", "string", ""),
    "sort_key":         ("sort key", "Chronological + printed order key", "string", ""),
    "qa_status":        ("QA status", "Cataloguing review status (draft or reviewed)", "string", ""),
    "label_raw":        ("source issue string", "Original issue string from the source spreadsheet", "string", ""),
    "wikidata_equiv":   ("Wikidata equivalent", "URL of the equivalent Wikidata property or item", "url", ""),
    "wikidata_item":    ("Wikidata item", "URL of the matching Wikidata item for this entity", "url", ""),
}

# Items created at bootstrap: key -> (label, description, wikidata equivalent)
ITEMS: dict[str, tuple[str, str, str]] = {
    "class_issue":   ("Issue", "An issue of a periodical (Mute)", "http://www.wikidata.org/entity/Q28869365"),
    "series_mute":   ("Mute", "Mute magazine (periodical)", "http://www.wikidata.org/entity/Q6943763"),
    "lang_en":       ("English", "English language", "http://www.wikidata.org/entity/Q1860"),
}


# ---------------------------------------------------------------------------
# Minimal MediaWiki API client
# ---------------------------------------------------------------------------
class Api:
    def __init__(self, url: str) -> None:
        self.url = url
        self.opener = urllib.request.build_opener(
            urllib.request.HTTPCookieProcessor(http.cookiejar.CookieJar())
        )
        self.csrf = ""

    def call(self, params: dict, post: bool = False) -> dict:
        params = {**params, "format": "json"}
        data = urllib.parse.urlencode(params).encode()
        if post:
            req = urllib.request.Request(self.url, data=data)
        else:
            req = urllib.request.Request(f"{self.url}?{data.decode()}")
        req.add_header("User-Agent", "corpus-mute-uploader/0.1 (Mute Publishing)")
        with self.opener.open(req, timeout=60) as r:
            out = json.load(r)
        if "error" in out:
            raise RuntimeError(f"API error: {out['error']}")
        return out

    def login(self, user: str, password: str) -> None:
        tok = self.call({"action": "query", "meta": "tokens", "type": "login"})
        lt = tok["query"]["tokens"]["logintoken"]
        res = self.call(
            {"action": "login", "lgname": user, "lgpassword": password, "lgtoken": lt},
            post=True,
        )
        if res["login"]["result"] != "Success":
            raise RuntimeError(f"Login failed: {res['login'].get('reason', res['login']['result'])}")
        self.csrf = self.call({"action": "query", "meta": "tokens"})["query"]["tokens"]["csrftoken"]

    def edit_entity(self, data: dict, new: str | None = None) -> dict:
        params = {
            "action": "wbeditentity",
            "data": json.dumps(data, ensure_ascii=False),
            "token": self.csrf,
            "bot": "1",
        }
        if new:
            params["new"] = new
        for attempt in range(3):
            try:
                return self.call(params, post=True)
            except RuntimeError as exc:
                if "ratelimit" in str(exc).lower() and attempt < 2:
                    time.sleep(5)
                    continue
                raise
        raise RuntimeError("unreachable")


# ---------------------------------------------------------------------------
# Snak builders
# ---------------------------------------------------------------------------
def snak(pid: str, datatype: str, value) -> dict:
    base = {"snaktype": "value", "property": pid}
    if datatype in ("string", "external-id", "url"):
        base.update(datatype=datatype, datavalue={"value": value, "type": "string"})
    elif datatype == "wikibase-item":
        base.update(datatype=datatype, datavalue={
            "value": {"entity-type": "item", "numeric-id": int(value[1:]), "id": value},
            "type": "wikibase-entityid"})
    elif datatype == "monolingualtext":
        base.update(datatype=datatype, datavalue={
            "value": {"text": value[0], "language": value[1]}, "type": "monolingualtext"})
    elif datatype == "time":
        year, month = value.split("-")
        base.update(datatype=datatype, datavalue={
            "value": {"time": f"+{year}-{month}-00T00:00:00Z", "timezone": 0, "before": 0,
                      "after": 0, "precision": 10,
                      "calendarmodel": "http://www.wikidata.org/entity/Q1985727"},
            "type": "time"})
    else:
        raise ValueError(datatype)
    return base


def claim(pid: str, datatype: str, value) -> dict:
    return {"mainsnak": snak(pid, datatype, value), "type": "statement", "rank": "normal"}


# ---------------------------------------------------------------------------
# Bootstrap
# ---------------------------------------------------------------------------
def bootstrap(api: Api) -> None:
    if STATE_PATH.exists():
        sys.exit(f"{STATE_PATH} exists - bootstrap already done for '{TARGET}'. Delete it only if the wiki was reset.")
    state: dict = {"target": TARGET, "api": API, "properties": {}, "items": {}}

    # 1. Properties (labels/descriptions only first, so equivalence can refer to them)
    for key, (label, desc, dtype, _wd) in PROPERTIES.items():
        data = {"labels": {"en": {"language": "en", "value": label}},
                "descriptions": {"en": {"language": "en", "value": desc}},
                "datatype": dtype}
        if DRY_RUN:
            print(f"[dry] property {key}: {label} ({dtype})")
            state["properties"][key] = f"P_{key}"
            continue
        res = api.edit_entity(data, new="property")
        state["properties"][key] = res["entity"]["id"]
        print(f"property {key:18} {res['entity']['id']:6} {label}")

    # 2. Items
    for key, (label, desc, _wd) in ITEMS.items():
        data = {"labels": {"en": {"language": "en", "value": label}},
                "descriptions": {"en": {"language": "en", "value": desc}}}
        if DRY_RUN:
            print(f"[dry] item {key}: {label}")
            state["items"][key] = f"Q_{key}"
            continue
        res = api.edit_entity(data, new="item")
        state["items"][key] = res["entity"]["id"]
        print(f"item     {key:18} {res['entity']['id']:6} {label}")

    # 3. Alignment statements: property/item -> Wikidata equivalent URL
    if not DRY_RUN:
        eq = state["properties"]["wikidata_equiv"]
        for key, (_l, _d, _t, wd) in PROPERTIES.items():
            if wd:
                _add_claim(api, state["properties"][key],
                           claim(eq, "url", f"http://www.wikidata.org/entity/{wd}"))
        for key, (_l, _d, wd) in ITEMS.items():
            _add_claim(api, state["items"][key], claim(eq, "url", wd))

    if not DRY_RUN:
        STATE_PATH.parent.mkdir(parents=True, exist_ok=True)
        STATE_PATH.write_text(json.dumps(state, indent=2), encoding="utf-8")
        print(f"\nSaved {STATE_PATH}")


def _add_claim(api: Api, entity_id: str, cl: dict) -> None:
    api.call({"action": "wbeditentity", "id": entity_id,
              "data": json.dumps({"claims": [cl]}), "token": api.csrf, "bot": "1"}, post=True)


# ---------------------------------------------------------------------------
# Import
# ---------------------------------------------------------------------------
def parse_issues() -> list[dict]:
    root = ET.parse(XML_PATH).getroot()
    issues = []
    for i in root.findall("issue"):
        d = {c.tag: (c.text or "").strip() for c in i}
        d["title_lang"] = (i.find("title").get("lang", "en") if i.find("title") is not None else "en")
        issues.append(d)
    return issues


def existing_ids(api: Api, p_local: str) -> dict[str, str]:
    """Map local ID -> item ID for items already imported (via haswbstatement search)."""
    found: dict[str, str] = {}
    res = api.call({"action": "query", "list": "search", "srsearch": f"haswbstatement:{p_local}",
                    "srnamespace": 120, "srlimit": 100})
    for hit in res["query"]["search"]:
        ent = hit["title"].split(":")[-1]
        data = api.call({"action": "wbgetclaims", "entity": ent, "property": p_local})
        for c in data.get("claims", {}).get(p_local, []):
            found[c["mainsnak"]["datavalue"]["value"]] = ent
    return found


def item_data(d: dict, P: dict, I: dict) -> dict:
    desc = f"Mute magazine issue, {d['publication_date']}"
    claims = [claim(P["local_id"], "external-id", d["local_id"])]
    # "instance of" is added once the bootstrap has created that property;
    # until then the class link is held by the series + issue statements.
    if P.get("instance_of"):
        claims.append(claim(P["instance_of"], "wikibase-item", I["class_issue"]))
    claims.append(claim(P["series"], "wikibase-item", I["series_mute"]))
    if d.get("title"):
        claims.append(claim(P["title"], "monolingualtext", (d["title"], d["title_lang"])))
    claims.append(claim(P["volume"], "string", d["volume"]))
    claims.append(claim(P["number"], "string", d["number"]))
    claims.append(claim(P["publication_date"], "time", d["publication_date"]))
    claims.append(claim(P["issn"], "external-id", d["issn_print"]))
    claims.append(claim(P["issn_issue_token"], "external-id", d["issn_issue_token"]))
    if d.get("isbn13"):
        claims.append(claim(P["isbn13"], "external-id", d["isbn13"]))
    if d.get("isbn_raw"):
        claims.append(claim(P["isbn_raw"], "string", d["isbn_raw"]))
    claims.append(claim(P["source_url"], "url", d["source_url"]))
    claims.append(claim(P["language"], "wikibase-item", I["lang_en"]))
    for k in ("edition_note", "insert_note"):
        if d.get(k):
            claims.append(claim(P[k], "string", d[k]))
    claims.append(claim(P["sort_key"], "string", d["sort_key"]))
    claims.append(claim(P["qa_status"], "string", d["qa_status"]))
    claims.append(claim(P["label_raw"], "string", d["label_raw"]))
    return {
        "labels": {"en": {"language": "en", "value": d["label"]}},
        "descriptions": {"en": {"language": "en", "value": desc}},
        "claims": claims,
    }


def do_import(api: Api) -> None:
    if not STATE_PATH.exists():
        sys.exit(f"{STATE_PATH} missing - run 'bootstrap' first.")
    state = json.loads(STATE_PATH.read_text(encoding="utf-8"))
    P, I = state["properties"], state["items"]

    issues = parse_issues()
    if OFFSET:
        issues = issues[OFFSET:]
    if LIMIT:
        issues = issues[:LIMIT]
    print(f"{len(issues)} issues to process (target={TARGET}, api={API})")

    done = {} if DRY_RUN else existing_ids(api, P["local_id"])
    log, created, skipped, errors = [], 0, 0, 0
    for n, d in enumerate(issues, 1):
        if d["local_id"] in done:
            print(f"[{n}] {d['local_id']} exists as {done[d['local_id']]} - skipped")
            skipped += 1
            continue
        data = item_data(d, P, I)
        if DRY_RUN:
            print(f"[{n}] [dry] {d['local_id']} {d['label']} ({len(data['claims'])} claims)")
            continue
        try:
            res = api.edit_entity(data, new="item")
            qid = res["entity"]["id"]
            print(f"[{n}] {d['local_id']} -> {qid}  {d['label']}")
            log.append({"local_id": d["local_id"], "qid": qid})
            created += 1
        except Exception as exc:  # noqa: BLE001
            print(f"[{n}] {d['local_id']} ERROR {exc}")
            log.append({"local_id": d["local_id"], "error": str(exc)})
            errors += 1
    if not DRY_RUN:
        LOG_PATH.write_text(json.dumps(log, indent=2, ensure_ascii=False), encoding="utf-8")
    print(f"\nCreated {created}  skipped {skipped}  errors {errors}")


def main() -> int:
    if len(sys.argv) != 2 or sys.argv[1] not in ("bootstrap", "import"):
        print(__doc__)
        return 2
    api = Api(API)
    if not DRY_RUN:
        if not PASSWORD:
            sys.exit("WB_PASSWORD is not set (set it in your shell; never paste it into chat).")
        api.login(USER, PASSWORD)
    bootstrap(api) if sys.argv[1] == "bootstrap" else do_import(api)
    return 0


if __name__ == "__main__":
    sys.exit(main())
