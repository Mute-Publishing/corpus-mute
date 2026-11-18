#!/usr/bin/env python3
"""
csv_to_xml.py
-------------
Reads output/issues_normalized.csv and writes xml/mute-issues.xml, which follows
xml/mute-issues.dtd. Standard library only.

Derivations (see Mute_ER_model.md):
  local_id     MI + zero padded source_inventory_number
  label        "Mute Vol {v}, No. {n} - {title}"
  isbn13       only when the ISBN is a checksum-valid ISBN-13 AND does not belong
               to an insert; otherwise the original goes to isbn_raw
  edition_note "(second edition)" style note from issue_label_raw
  insert_note  "Insert(s)..." text from issue_label_raw
  qa_status    draft while any qa_needs_* flag is yes

Usage:
  python mute-er-model/etl/csv_to_xml.py
"""

from __future__ import annotations

import csv
import re
import sys
from datetime import date
from pathlib import Path
from xml.sax.saxutils import escape

ROOT = Path(__file__).resolve().parent.parent
INPUT_CSV = ROOT / "output" / "issues_normalized.csv"
OUTPUT_XML = ROOT / "xml" / "mute-issues.xml"
DTD_NAME = "mute-issues.dtd"
VERSION = "0.1"


def isbn13_valid(digits: str) -> bool:
    if not re.fullmatch(r"\d{13}", digits):
        return False
    total = sum(int(d) * (1 if i % 2 == 0 else 3) for i, d in enumerate(digits[:12]))
    return (10 - total % 10) % 10 == int(digits[12])


def split_notes(label_raw: str) -> tuple[str, str]:
    """Return (edition_note, insert_note) parsed from the raw issue label."""
    edition = ""
    m = re.search(r"\((second edition)\)", label_raw, re.I)
    if m:
        edition = m.group(1)
    insert = ""
    m = re.search(r"\.\s+(Inserts?\s*[;:].*)$", label_raw)
    if m:
        insert = m.group(1).strip().rstrip(".").strip()
    return edition, insert


def build_label(volume: str, number: str, title: str) -> str:
    base = f"Mute Vol {volume}, No. {number}"
    return f"{base} - {title}" if title else base


def el(tag: str, text: str, attrs: str = "") -> str:
    return f"    <{tag}{attrs}>{escape(text)}</{tag}>"


def issue_xml(row: dict[str, str]) -> str:
    inv = int(row["source_inventory_number"])
    local_id = f"MI{inv:03d}"
    title = row["issue_title"].strip()
    edition, insert = split_notes(row["issue_label_raw"])

    isbn_raw = row["isbn"].strip()
    isbn13 = ""
    if isbn_raw:
        digits = re.sub(r"[^0-9]", "", isbn_raw)
        in_insert = bool(insert) and isbn_raw in insert
        if isbn13_valid(digits) and not in_insert:
            isbn13 = digits
            isbn_raw = ""  # clean value stored, raw not needed

    qa_flags = [v for k, v in row.items() if k.startswith("qa_needs_")]
    qa_status = "draft" if any(v.strip().lower() == "yes" for v in qa_flags) else "reviewed"

    lines = [f'  <issue id="{local_id}">']
    lines.append(el("local_id", local_id))
    lines.append(el("label", build_label(row["volume"], row["number"], title)))
    lines.append(el("series_title", row["series_title"]))
    if title:
        lines.append(el("title", title, ' lang="en"'))
    lines.append(el("volume", row["volume"]))
    lines.append(el("number", row["number"]))
    lines.append(el("publication_date", row["publication_date_iso"]))
    lines.append(el("issn_print", row["issn_print"]))
    lines.append(el("issn_issue_token", row["issn_issue_token"]))
    if isbn13:
        lines.append(el("isbn13", isbn13))
    if isbn_raw:
        lines.append(el("isbn_raw", isbn_raw))
    lines.append(el("source_url", row["source_url_html"]))
    lines.append(el("language", row["language"] or "en"))
    if edition:
        lines.append(el("edition_note", edition))
    if insert:
        lines.append(el("insert_note", insert))
    lines.append(el("sort_key", row["sort_key_final"]))
    lines.append(el("qa_status", qa_status))
    lines.append(el("label_raw", row["issue_label_raw"]))
    lines.append("  </issue>")
    return "\n".join(lines)


def main() -> int:
    with open(INPUT_CSV, newline="", encoding="utf-8-sig") as f:
        rows = list(csv.DictReader(f))
    rows.sort(key=lambda r: r["sort_key_final"])

    OUTPUT_XML.parent.mkdir(parents=True, exist_ok=True)
    parts = [
        '<?xml version="1.0" encoding="UTF-8"?>',
        f'<!DOCTYPE mute-issues SYSTEM "{DTD_NAME}">',
        f'<mute-issues version="{VERSION}" source="output/issues_normalized.csv" '
        f'generated="{date.today().isoformat()}">',
    ]
    parts.extend(issue_xml(r) for r in rows)
    parts.append("</mute-issues>")
    OUTPUT_XML.write_text("\n".join(parts) + "\n", encoding="utf-8")

    print(f"Wrote {OUTPUT_XML}  ({len(rows)} issues)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
