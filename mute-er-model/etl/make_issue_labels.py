#!/usr/bin/env python3
"""
make_issue_labels.py - print labels (QR code, short URL, sort key, issue ISSN token) for the Mute issues.

Target stock: Avery J8159 / L7159 (A4, 24 labels of 63.5 x 33.9 mm, 3 columns x 8 rows).

What it does
  1. Reads the issues from the Wikibase query service (items with a Mute issue ID, P2),
     in publication order (P16 sort key), with their issue ISSN token (P9).
  2. Gets a short link for every issue page (https://<site>/wiki/Item:Qn) from the wiki's own
     UrlShortener extension (POST action=shortenurl). Existing links are reused (same URL ->
     same code). Creation is limited by the extension to 10 per 2 minutes per IP and admins
     cannot bypass that, so new links are created one every --pace seconds (default 13), about
     11 minutes for all 51. Results are cached in output/issue_short_links.csv, so an
     interrupted run resumes and a re-run makes no API calls for known issues.
  3. Builds the QR codes locally (segno, pure Python), so they do not count against the limit.
  4. Writes labels.html (A4 pages, one label per cell) and, if Edge or Chrome is found, labels.pdf.

On the label: the QR code encodes the FULL short URL (https://...), so phone cameras open it as a
link. The printed text has three lines: the short URL without the scheme on ONE line
(corpus.metamute.org/r/6), the issue sort key (P16, e.g. 1994-11-001-v01-n00.0) directly under it,
and the issue ISSN token (P9), e.g. "ISSN 1356-7748-01".

Print the PDF at 100% / "Actual size" (never "Fit to page"), single-sided, no margins scaling.
Print on plain paper first and hold it against a label sheet to the light.

Usage (from the repository root)
  .venv\\Scripts\\python.exe mute-er-model\\etl\\make_issue_labels.py --test-grid      # outlines only
  .venv\\Scripts\\python.exe mute-er-model\\etl\\make_issue_labels.py --dry-run        # list what would be created
  .venv\\Scripts\\python.exe mute-er-model\\etl\\make_issue_labels.py                  # create links, build labels
  ... --start-position 7     # first free label on a partly used sheet (1 = top left, 24 = bottom right)
  ... --offset-x 0.5 --offset-y -0.8   # nudge everything (mm) after a test print

Needs: pip install segno   (the rest is standard library)
"""

from __future__ import annotations

import argparse
import csv
import html
import json
import re
import shutil
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

try:
    import segno
except ImportError:  # pragma: no cover
    sys.exit("segno is missing. Install it with:  .venv\\Scripts\\python.exe -m pip install segno")

ROOT = Path(__file__).resolve().parents[2]
OUT_DIR_DEFAULT = ROOT / "mute-er-model" / "output"

# ---- Avery J8159 / L7159 geometry (mm) -------------------------------------------------------
# Label size 63.5 x 33.9 and 3 columns x 8 rows on A4 are given. The 2.5 mm column gap, the zero row
# gap and the margins are ASSUMED (sheet centred on the page) and were NOT checked against Avery's
# own template, whose site blocks automated access. They are therefore parameters: print
# --test-grid on plain paper, hold it over a label sheet and correct with --offset-x / --offset-y
# (or --left / --top).
PAGE_W, PAGE_H = 210.0, 297.0
LABEL_W, LABEL_H = 63.5, 33.9
COLS, ROWS = 3, 8
COL_GAP = 2.5
ROW_GAP = 0.0
LEFT_DEFAULT = (PAGE_W - (COLS * LABEL_W + (COLS - 1) * COL_GAP)) / 2  # centred: 7.25 mm
TOP_DEFAULT = (PAGE_H - (ROWS * LABEL_H + (ROWS - 1) * ROW_GAP)) / 2  # centred: 12.9 mm

SPARQL_PATH = "/query/proxy/sparql"
QUERY = """
SELECT ?issue ?token ?sortKey WHERE {
  ?issue wdt:P2 ?issueId ;
         wdt:P16 ?sortKey .
  OPTIONAL { ?issue wdt:P9 ?token }
}
ORDER BY ?sortKey
"""
UA = "corpus-mute-labels/1.0 (+https://github.com/Mute-Publishing/corpus-mute)"


# ---- data ------------------------------------------------------------------------------------
def http_json(req: urllib.request.Request, timeout: int = 60) -> dict:
    req.add_header("User-Agent", UA)
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        return json.loads(resp.read().decode("utf-8"))


def fetch_issues(site: str) -> list[dict]:
    url = site + SPARQL_PATH + "?" + urllib.parse.urlencode({"query": QUERY})
    req = urllib.request.Request(url, headers={"Accept": "application/sparql-results+json"})
    rows = http_json(req)["results"]["bindings"]
    issues = []
    for r in rows:
        qid = r["issue"]["value"].rsplit("/", 1)[-1]
        issues.append({"qid": qid, "token": r.get("token", {}).get("value", ""), "sort": r["sortKey"]["value"]})
    return issues


def item_url(site: str, qid: str) -> str:
    return f"{site}/wiki/Item:{qid}"


def load_cache(path: Path) -> dict[str, dict]:
    cache: dict[str, dict] = {}
    if path.exists():
        with path.open(newline="", encoding="utf-8") as fh:
            for row in csv.DictReader(fh):
                cache[row["qid"]] = row
    return cache


def save_cache(path: Path, cache: dict[str, dict]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    fields = ["qid", "item_url", "short_url"]
    tmp = path.with_suffix(".tmp")
    with tmp.open("w", newline="", encoding="utf-8") as fh:
        w = csv.DictWriter(fh, fieldnames=fields)
        w.writeheader()
        for qid in sorted(cache, key=lambda q: int(q[1:])):
            w.writerow({k: cache[qid][k] for k in fields})
    tmp.replace(path)


def shorten(site: str, url: str) -> str:
    """Create (or fetch) the short link for url. Retries when the extension rate-limits us."""
    data = urllib.parse.urlencode({"action": "shortenurl", "format": "json", "url": url}).encode()
    for attempt in range(1, 7):
        req = urllib.request.Request(site + "/w/api.php", data=data, method="POST")
        try:
            reply = http_json(req)
        except urllib.error.HTTPError as exc:
            if exc.code in (429, 503):
                reply = {"error": {"code": "ratelimited"}}
            else:
                raise
        if "shortenurl" in reply and reply["shortenurl"].get("shorturl"):
            return reply["shortenurl"]["shorturl"]
        code = reply.get("error", {}).get("code", "")
        if "ratelimit" in code or code == "ratelimited":
            wait = 30 * attempt
            print(f"  rate limited, waiting {wait}s (attempt {attempt}/6)")
            time.sleep(wait)
            continue
        raise RuntimeError(f"shortenurl failed for {url}: {json.dumps(reply)[:300]}")
    raise RuntimeError(f"still rate limited after retries for {url}")


# ---- label sheet ------------------------------------------------------------------------------
def qr_svg(text: str) -> str:
    # error level M, 4-module quiet zone included in the drawing
    q = segno.make(text, error="m", micro=False)
    return q.svg_inline(scale=1, border=4, dark="#000", light=None, omitsize=True)


def strip_scheme(url: str) -> str:
    return re.sub(r"^https?://", "", url)


def label_html(issue: dict | None, short_url: str | None) -> str:
    if issue is None or short_url is None:
        return '<div class="label"></div>'
    token = issue["token"]
    sort_key = issue.get("sort", "")
    sort_line = f'<div class="sortkey">{html.escape(sort_key)}</div>' if sort_key else ""
    issn = f'<div class="issn">ISSN {html.escape(token)}</div>' if token else ""
    return (
        '<div class="label">'
        f'<div class="qr">{qr_svg(short_url)}</div>'
        '<div class="txt">'
        f'<div class="url">{html.escape(strip_scheme(short_url))}</div>'
        f"{sort_line}"
        f"{issn}"
        "</div></div>"
    )


def build_html(items: list[tuple[dict, str] | None], args: argparse.Namespace) -> str:
    """items: one entry per label position; None leaves that label blank (used skip already-used labels)."""
    left = args.left + args.offset_x
    top = args.top + args.offset_y
    per_page = COLS * ROWS
    pages = []
    for start in range(0, len(items), per_page):
        chunk = items[start:start + per_page]
        cells = []
        for pos in range(per_page):
            entry = chunk[pos] if pos < len(chunk) else None
            cells.append(label_html(None, None) if entry is None else label_html(entry[0], entry[1]))
        pages.append('<section class="sheet">' + "".join(cells) + "</section>")
    outline_css = ".label{outline:0.2mm solid #888;}" if args.outline else ""
    return f"""<!DOCTYPE html>
<html lang="en"><head><meta charset="utf-8"><title>Mute issue labels (Avery J8159)</title>
<style>
@page {{ size: {PAGE_W}mm {PAGE_H}mm; margin: 0; }}
* {{ box-sizing: border-box; margin: 0; padding: 0; }}
html, body {{ background: #fff; }}
body {{ font-family: Arial, Helvetica, sans-serif; color: #000; -webkit-print-color-adjust: exact; print-color-adjust: exact; }}
.sheet {{ position: relative; width: {PAGE_W}mm; height: {PAGE_H}mm; overflow: hidden; page-break-after: always; break-after: page;
  padding: {top}mm 0 0 {left}mm; display: grid;
  grid-template-columns: repeat({COLS}, {LABEL_W}mm); grid-auto-rows: {LABEL_H}mm;
  column-gap: {COL_GAP}mm; row-gap: {ROW_GAP}mm; align-content: start; justify-content: start; }}
.sheet:last-child {{ page-break-after: auto; break-after: auto; }}
.label {{ position: relative; width: {LABEL_W}mm; height: {LABEL_H}mm; overflow: hidden;
  display: flex; align-items: center; padding: 0 2.5mm 0 3mm; gap: 2mm; }}
.qr {{ flex: 0 0 25mm; width: 25mm; height: 25mm; }}
.qr svg {{ width: 25mm; height: 25mm; display: block; shape-rendering: crispEdges; }}
.txt {{ flex: 1 1 auto; min-width: 0; line-height: 1.25; }}
.url {{ font-size: 7pt; font-weight: 700; white-space: nowrap; }}
.sortkey {{ font-size: 6pt; white-space: nowrap; font-variant-numeric: tabular-nums; margin-top: 0.6mm; }}
.issn {{ font-size: 7pt; white-space: nowrap; font-variant-numeric: tabular-nums; margin-top: 1.4mm; }}
{outline_css}
</style></head><body>
{"".join(pages)}
</body></html>
"""


def build_test_grid_html(args: argparse.Namespace) -> str:
    """A sheet of numbered outlines, no data, for checking the alignment on real label stock."""
    left = args.left + args.offset_x
    top = args.top + args.offset_y
    boxes = "".join(f'<div class="label" data-n="{n}"></div>' for n in range(1, COLS * ROWS + 1))
    return f"""<!DOCTYPE html>
<html lang="en"><head><meta charset="utf-8"><title>Avery J8159 test grid</title>
<style>
@page {{ size: {PAGE_W}mm {PAGE_H}mm; margin: 0; }}
* {{ box-sizing: border-box; margin: 0; padding: 0; }}
body {{ font-family: Arial, Helvetica, sans-serif; -webkit-print-color-adjust: exact; print-color-adjust: exact; }}
.sheet {{ position: relative; width: {PAGE_W}mm; height: {PAGE_H}mm; overflow: hidden; padding: {top}mm 0 0 {left}mm;
  display: grid; grid-template-columns: repeat({COLS}, {LABEL_W}mm); grid-auto-rows: {LABEL_H}mm;
  column-gap: {COL_GAP}mm; row-gap: {ROW_GAP}mm; align-content: start; justify-content: start; }}
.label {{ position: relative; outline: 0.25mm solid #000; display: flex; align-items: center; justify-content: center; font-size: 9pt; color: #555; }}
.label::before {{ content: attr(data-n); }}
.note {{ position: absolute; left: {left}mm; bottom: 3mm; font-size: 7pt; color: #555; }}
</style></head><body><section class="sheet">{boxes}
<div class="note">Test grid: {LABEL_W} x {LABEL_H} mm, {COLS} x {ROWS}, left {left:.2f} mm, top {top:.2f} mm. Print at 100% (Actual size), hold over a label sheet to the light.</div>
</section></body></html>
"""


def find_browser() -> str | None:
    candidates = [
        r"C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe",
        r"C:\Program Files\Microsoft\Edge\Application\msedge.exe",
        r"C:\Program Files\Google\Chrome\Application\chrome.exe",
        r"C:\Program Files (x86)\Google\Chrome\Application\chrome.exe",
    ]
    for c in candidates:
        if Path(c).exists():
            return c
    for name in ("msedge", "chrome", "google-chrome", "chromium"):
        found = shutil.which(name)
        if found:
            return found
    return None


def html_to_pdf(html_path: Path, pdf_path: Path) -> bool:
    browser = find_browser()
    if not browser:
        print("No Edge/Chrome found; open the HTML file and print it (A4, 100%, margins none).")
        return False
    if pdf_path.exists():
        pdf_path.unlink()
    cmd = [browser, "--headless=new", "--disable-gpu", "--no-pdf-header-footer",
           f"--print-to-pdf={pdf_path}", html_path.resolve().as_uri()]
    try:
        subprocess.run(cmd, check=False, capture_output=True, timeout=120)
    except subprocess.TimeoutExpired:
        print("Browser timed out while making the PDF.")
        return False
    return pdf_path.exists() and pdf_path.stat().st_size > 0


# ---- main -------------------------------------------------------------------------------------
def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--site", default="https://corpus.metamute.org", help="wiki base URL (default: production)")
    ap.add_argument("--out-dir", type=Path, default=OUT_DIR_DEFAULT)
    ap.add_argument("--expect", type=int, default=51, help="abort unless this many issues are found (0 = no check)")
    ap.add_argument("--pace", type=float, default=13.0, help="seconds between short-link creations (limit: 10 per 2 min)")
    ap.add_argument("--dry-run", action="store_true", help="list issues and missing short links, create nothing")
    ap.add_argument("--start-position", type=int, default=1, help="first label to use on sheet 1 (1..24), for part-used sheets")
    ap.add_argument("--test-grid", action="store_true", help="only write a numbered outline sheet to check alignment")
    ap.add_argument("--outline", action="store_true", help="draw label outlines (screen proof; do not print on real labels)")
    ap.add_argument("--left", type=float, default=LEFT_DEFAULT, help="left margin to first label, mm")
    ap.add_argument("--top", type=float, default=TOP_DEFAULT, help="top margin to first label, mm")
    ap.add_argument("--offset-x", type=float, default=0.0, help="shift all content right (+) / left (-), mm")
    ap.add_argument("--offset-y", type=float, default=0.0, help="shift all content down (+) / up (-), mm")
    ap.add_argument("--no-pdf", action="store_true", help="write the HTML only")
    args = ap.parse_args()
    args.site = args.site.rstrip("/")
    out = args.out_dir / "labels"
    out.mkdir(parents=True, exist_ok=True)

    if args.test_grid:
        p = out / "test-grid.html"
        p.write_text(build_test_grid_html(args), encoding="utf-8")
        print("wrote", p)
        if not args.no_pdf and html_to_pdf(p, out / "test-grid.pdf"):
            print("wrote", out / "test-grid.pdf")
        return 0

    if not 1 <= args.start_position <= COLS * ROWS:
        sys.exit(f"--start-position must be 1..{COLS * ROWS}")

    issues = fetch_issues(args.site)
    print(f"{len(issues)} issues from {args.site}")
    if args.expect and len(issues) != args.expect:
        sys.exit(f"expected {args.expect} issues, found {len(issues)}; check the site or pass --expect 0")
    no_token = [i["qid"] for i in issues if not i["token"]]
    if no_token:
        print("WARNING: no ISSN token (P9) for", ", ".join(no_token))
    tokens = [i["token"] for i in issues if i["token"]]
    if len(set(tokens)) != len(tokens):
        print("WARNING: duplicate ISSN tokens found")

    cache_path = args.out_dir / "issue_short_links.csv"
    cache = load_cache(cache_path)
    missing = [i for i in issues if i["qid"] not in cache or not cache[i["qid"]].get("short_url")]
    print(f"{len(issues) - len(missing)} short links cached, {len(missing)} to create")
    if args.dry_run:
        for i in missing:
            print("  would shorten", item_url(args.site, i["qid"]))
        return 0

    for n, i in enumerate(missing, 1):
        url = item_url(args.site, i["qid"])
        short = shorten(args.site, url)
        if not short.startswith(args.site + "/"):
            sys.exit(f"unexpected short URL host for {url}: {short}")
        cache[i["qid"]] = {"qid": i["qid"], "item_url": url, "short_url": short}
        save_cache(cache_path, cache)
        print(f"  [{n}/{len(missing)}] {i['qid']} -> {short}")
        if n < len(missing):
            time.sleep(args.pace)

    entries: list[tuple[dict, str] | None] = [None] * (args.start_position - 1)
    for i in issues:
        entries.append((i, cache[i["qid"]]["short_url"]))
    html_path = out / "labels.html"
    html_path.write_text(build_html(entries, args), encoding="utf-8")
    print("wrote", html_path, f"({len(issues)} labels, {-(-len(entries) // (COLS * ROWS))} sheets)")
    if not args.no_pdf:
        pdf_path = out / "labels.pdf"
        if html_to_pdf(html_path, pdf_path):
            print("wrote", pdf_path)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
