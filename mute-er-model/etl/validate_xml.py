#!/usr/bin/env python3
"""
validate_xml.py - validate xml/mute-issues.xml against xml/mute-issues.dtd.

Needs lxml (no wheels for the workspace Python 3.16 alpha), so run it in a
container:

  docker run --rm -v "${PWD}:/w" -w /w python:3.12-slim sh -c \
    "pip install -q lxml && python mute-er-model/etl/validate_xml.py"
"""

import sys
from pathlib import Path

from lxml import etree

XML = Path(__file__).resolve().parent.parent / "xml" / "mute-issues.xml"


def main() -> int:
    parser = etree.XMLParser(dtd_validation=True, load_dtd=True)
    tree = etree.parse(str(XML), parser)
    ids = [i.get("id") for i in tree.getroot()]
    keys = [(i.findtext("volume"), i.findtext("number")) for i in tree.getroot()]
    tokens = [i.findtext("issn_issue_token") for i in tree.getroot()]
    print(f"DTD valid. issues={len(ids)} unique_ids={len(set(ids))} "
          f"unique_vol_no={len(set(keys))} unique_tokens={len(set(tokens))}")
    ok = len(ids) == 51 == len(set(ids)) == len(set(keys)) == len(set(tokens))
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
