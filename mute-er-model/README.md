# Mute ER Model: Issue ETL

This folder contains the first-pass ETL pipeline for normalizing issue metadata from the spreadsheet into a review-ready CSV before Wikidata upload drafting.

## Source

- Workbook: `mute-er-model/data.xlsx`
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
