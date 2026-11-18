# Mute ER Model: Issue ETL

- Extract, Transform, Load (ETL) AKAK normalisation

This folder contains the first-pass ETL pipeline for normalizing issue metadata from the spreadsheet into a review-ready CSV before Wikidata upload drafting.

The process is 'bottom-up' first, which means sort the data we have and come up with a minimal set of fields, second is 'top-down' select a schema(s) and see what will be needed to satisfy the schemas needs.

## Source

- Workbook: `mute-er-model/input/data.xlsx`
- Sheet: `Sheet1`
- Expected source columns:
  - `Inventory number`
  - `Issue`
  - `URL`

## Outputs

Running the ETL script creates:

- `mute-er-model/output/issues_normalized.csv`
- `mute-er-model/output/issues_qa_report.csv`

## What the ETL does

- Parses issue strings into structured fields:
  - `volume`, `number`, `issue_title`
  - `publication_year`, `publication_month`, `publication_date_iso`
  - `issn_print`, `issn_issue_token`, `issue_identifier_local`
  - `isbn` when present
- Preserves ordering with separate sort keys:
  - `sort_key_chronological`
  - `sort_key_printed`
  - `sort_key_final`
- Excludes rows that are not issue records (for example entries without inventory number) and records them in the QA report.
- Adds QA columns for manual completion and checking.

## Run

1. Create and activate a virtual environment (if not already done).
2. Install dependency:

```powershell
.venv\Scripts\python.exe -m pip install openpyxl
```

3. Run ETL:

```powershell
.venv\Scripts\python.exe mute-er-model\etl\normalize_issues.py
```

## Manual QA workflow

Before preparing any Wikidata upload draft, manually review these fields in `issues_normalized.csv`:

- `issue_title`
- `volume`, `number`
- `publication_date_iso`
- `cover_url_or_reference`
- `language`

Use `issues_qa_report.csv` to review excluded rows and summary counts.

## TDM from Issue URLs

You can harvest article links from each issue page, then build article and contributor lists.

Script:

- `mute-er-model/etl/tdm_issue_articles.py`

Outputs:

- `mute-er-model/output/issue_article_links.csv`
- `mute-er-model/output/articles_catalog.csv`
- `mute-er-model/output/contributors_catalog.csv`
- `mute-er-model/output/tdm_crawl_report.csv`

### Pilot run for one issue only

```powershell
.venv\Scripts\python.exe mute-er-model\etl\tdm_issue_articles.py --limit 1 --suffix pilot1
```

Pilot output files:

- `mute-er-model/output/issue_article_links_pilot1.csv`
- `mute-er-model/output/articles_catalog_pilot1.csv`
- `mute-er-model/output/contributors_catalog_pilot1.csv`
- `mute-er-model/output/tdm_crawl_report_pilot1.csv`
