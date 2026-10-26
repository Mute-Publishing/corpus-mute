#!/usr/bin/env python3
"""Harvest article and contributor data from Mute issue pages."""

from __future__ import annotations

import argparse
import csv
import html
import re
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path
from typing import Any

USER_AGENT = "Mozilla/5.0 (compatible; CorpusMuteTDM/1.0)"
ARTICLE_PATH_TOKEN = "/editorial/articles/"

META_TAG_RE = re.compile(r"<meta\s+[^>]*>", re.IGNORECASE)
ATTR_RE = re.compile(r"([a-zA-Z_:][-a-zA-Z0-9_:.]*)\s*=\s*(['\"])(.*?)\2", re.DOTALL)
TITLE_RE = re.compile(r"<title[^>]*>(.*?)</title>", re.IGNORECASE | re.DOTALL)
H1_RE = re.compile(r"<h1[^>]*id=['\"]page-title['\"][^>]*>(.*?)</h1>", re.IGNORECASE | re.DOTALL)
TAG_RE = re.compile(r"<[^>]+>")
HREF_RE = re.compile(r"href\s*=\s*(['\"])(.*?)\1", re.IGNORECASE | re.DOTALL)


def clean_text(value: Any) -> str:
    if value is None:
        return ""
    return str(value).strip()


def strip_tags(value: str) -> str:
    no_tags = TAG_RE.sub(" ", value)
    no_tags = html.unescape(no_tags)
    return re.sub(r"\s+", " ", no_tags).strip()


def fetch_html(url: str, timeout: int) -> tuple[str, int, str]:
    req = urllib.request.Request(url, headers={"User-Agent": USER_AGENT})
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            content = resp.read().decode("utf-8", "ignore")
            return content, getattr(resp, "status", 200), "ok"
    except urllib.error.HTTPError as err:
        return "", err.code, f"http_error:{err.code}"
    except Exception as err:  # pragma: no cover - network/runtime dependent
        return "", 0, f"error:{type(err).__name__}"


def parse_meta(html_text: str) -> dict[str, str]:
    result: dict[str, str] = {}
    for tag in META_TAG_RE.findall(html_text):
        attrs = {k.lower(): v for k, _, v in ATTR_RE.findall(tag)}
        key = attrs.get("name") or attrs.get("property")
        value = attrs.get("content", "")
        if key:
            result[key.lower()] = html.unescape(value).strip()
    return result


def parse_article_links(issue_url: str, issue_html: str) -> list[str]:
    links: list[str] = []
    for _, href in HREF_RE.findall(issue_html):
        href = href.strip()
        if not href:
            continue
        absolute = urllib.parse.urljoin(issue_url, href)
        parsed = urllib.parse.urlparse(absolute)
        canonical = urllib.parse.urlunparse((parsed.scheme, parsed.netloc, parsed.path, "", "", ""))
        if ARTICLE_PATH_TOKEN not in canonical:
            continue
        if not canonical.endswith(".html"):
            continue
        if canonical not in links:
            links.append(canonical)
    return links


def parse_contributors(meta: dict[str, str], article_html: str) -> list[str]:
    raw = meta.get("dcterms.creator", "")

    if not raw:
        byline_match = re.search(r"<span[^>]*class=['\"][^'\"]*by[^'\"]*['\"][^>]*>(.*?)</span>", article_html, re.IGNORECASE | re.DOTALL)
        if byline_match:
            raw = strip_tags(byline_match.group(1))

    raw = re.sub(r"^by\s+", "", raw.strip(), flags=re.IGNORECASE)
    if not raw:
        return []

    parts = re.split(r"\s*(?:,|;|\band\b|&)\s*", raw)
    contributors = []
    for part in parts:
        name = re.sub(r"^by\s+", "", part.strip(), flags=re.IGNORECASE)
        token = re.sub(r"[^a-z0-9]+", "", name.lower())
        if token in {"", "amp", "and", "by"}:
            continue
        if name and name not in contributors:
            contributors.append(name)
    return contributors


def parse_article_record(article_url: str, article_html: str) -> dict[str, str]:
    meta = parse_meta(article_html)

    title = meta.get("og:title", "") or meta.get("dcterms.title", "")
    if not title:
        h1_match = H1_RE.search(article_html)
        if h1_match:
            title = strip_tags(h1_match.group(1))
    if not title:
        title_match = TITLE_RE.search(article_html)
        if title_match:
            title = strip_tags(title_match.group(1))

    contributors = parse_contributors(meta, article_html)

    return {
        "article_url": article_url,
        "article_title": title,
        "article_date_raw": meta.get("dcterms.date", ""),
        "article_language": meta.get("dcterms.language", ""),
        "contributors_raw": " | ".join(contributors),
    }


def write_csv(path: Path, rows: list[dict[str, Any]], fieldnames: list[str]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", encoding="utf-8", newline="") as handle:
        writer = csv.DictWriter(handle, fieldnames=fieldnames)
        writer.writeheader()
        writer.writerows(rows)


def main() -> None:
    parser = argparse.ArgumentParser(description="Harvest article and contributor metadata from issue URLs")
    parser.add_argument("--input", default="mute-er-model/output/issues_normalized.csv", help="Issue CSV input")
    parser.add_argument("--limit", type=int, default=0, help="Process only first N issues (0 = all)")
    parser.add_argument("--timeout", type=int, default=20, help="HTTP timeout in seconds")
    parser.add_argument("--suffix", default="", help="Optional filename suffix, e.g. pilot1")
    args = parser.parse_args()

    repo_root = Path(__file__).resolve().parents[2]
    input_path = repo_root / args.input
    output_dir = repo_root / "mute-er-model" / "output"

    suffix = f"_{args.suffix}" if args.suffix else ""
    links_path = output_dir / f"issue_article_links{suffix}.csv"
    articles_path = output_dir / f"articles_catalog{suffix}.csv"
    contributors_path = output_dir / f"contributors_catalog{suffix}.csv"
    report_path = output_dir / f"tdm_crawl_report{suffix}.csv"

    issue_rows: list[dict[str, str]] = []
    with input_path.open("r", encoding="utf-8", newline="") as handle:
        reader = csv.DictReader(handle)
        for row in reader:
            issue_rows.append(row)

    if args.limit > 0:
        issue_rows = issue_rows[: args.limit]

    issue_article_links: list[dict[str, Any]] = []
    crawl_report: list[dict[str, Any]] = []
    article_cache: dict[str, dict[str, str]] = {}

    for issue in issue_rows:
        inv = clean_text(issue.get("source_inventory_number"))
        issue_title = clean_text(issue.get("issue_title"))
        issue_url = clean_text(issue.get("source_url_html"))

        if not issue_url:
            crawl_report.append(
                {
                    "source_inventory_number": inv,
                    "issue_url": issue_url,
                    "issue_status": "missing_url",
                    "issue_http_code": "",
                    "article_links_found": 0,
                }
            )
            continue

        issue_html, issue_code, issue_status = fetch_html(issue_url, args.timeout)
        article_links = parse_article_links(issue_url, issue_html) if issue_status == "ok" else []

        crawl_report.append(
            {
                "source_inventory_number": inv,
                "issue_url": issue_url,
                "issue_status": issue_status,
                "issue_http_code": issue_code,
                "article_links_found": len(article_links),
            }
        )

        for article_url in article_links:
            issue_article_links.append(
                {
                    "source_inventory_number": inv,
                    "issue_title": issue_title,
                    "issue_url": issue_url,
                    "article_url": article_url,
                }
            )

            if article_url not in article_cache:
                article_html, article_code, article_status = fetch_html(article_url, args.timeout)
                parsed = parse_article_record(article_url, article_html) if article_status == "ok" else {
                    "article_url": article_url,
                    "article_title": "",
                    "article_date_raw": "",
                    "article_language": "",
                    "contributors_raw": "",
                }
                parsed["article_status"] = article_status
                parsed["article_http_code"] = str(article_code)
                article_cache[article_url] = parsed

    article_rows: list[dict[str, Any]] = []
    contributor_rows: list[dict[str, Any]] = []

    # Build reverse index of issue usage per article.
    issues_by_article: dict[str, list[str]] = {}
    for row in issue_article_links:
        article_url = row["article_url"]
        inv = row["source_inventory_number"]
        issues_by_article.setdefault(article_url, [])
        if inv not in issues_by_article[article_url]:
            issues_by_article[article_url].append(inv)

    for article_url, article in sorted(article_cache.items(), key=lambda item: item[0]):
        article_rows.append(
            {
                "article_url": article_url,
                "article_title": article.get("article_title", ""),
                "article_date_raw": article.get("article_date_raw", ""),
                "article_language": article.get("article_language", ""),
                "article_status": article.get("article_status", ""),
                "article_http_code": article.get("article_http_code", ""),
                "source_inventory_numbers": "|".join(issues_by_article.get(article_url, [])),
            }
        )

        contributors_raw = article.get("contributors_raw", "")
        if contributors_raw:
            for contributor in [x.strip() for x in contributors_raw.split("|") if x.strip()]:
                contributor_rows.append(
                    {
                        "contributor_name": contributor,
                        "article_url": article_url,
                        "article_title": article.get("article_title", ""),
                        "source_inventory_numbers": "|".join(issues_by_article.get(article_url, [])),
                    }
                )

    write_csv(
        links_path,
        issue_article_links,
        ["source_inventory_number", "issue_title", "issue_url", "article_url"],
    )
    write_csv(
        articles_path,
        article_rows,
        [
            "article_url",
            "article_title",
            "article_date_raw",
            "article_language",
            "article_status",
            "article_http_code",
            "source_inventory_numbers",
        ],
    )
    write_csv(
        contributors_path,
        contributor_rows,
        ["contributor_name", "article_url", "article_title", "source_inventory_numbers"],
    )
    write_csv(
        report_path,
        crawl_report,
        ["source_inventory_number", "issue_url", "issue_status", "issue_http_code", "article_links_found"],
    )

    print(f"Processed issues: {len(issue_rows)}")
    print(f"Issue->article links: {len(issue_article_links)}")
    print(f"Unique articles: {len(article_rows)}")
    print(f"Contributor rows: {len(contributor_rows)}")
    print(f"Wrote: {links_path}")
    print(f"Wrote: {articles_path}")
    print(f"Wrote: {contributors_path}")
    print(f"Wrote: {report_path}")


if __name__ == "__main__":
    main()
