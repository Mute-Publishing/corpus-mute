# Schema alignment: Issue (Phase 1)

Status: DRAFT v0.1, 2026-11-18.
Wikidata property IDs and datatypes were verified live on 2026-11-18.
All other schema terms are **proposed** and need expert review, especially CIDOC-CRM/FRBRoo.

## Field alignment

| ER attribute | Wikidata | schema.org | DCTERMS | PRISM | JATS | BIBFRAME | CIDOC-CRM / FRBRoo (proposed) |
|---|---|---|---|---|---|---|---|
| Issue (class) | `Q28869365` issue | `PublicationIssue` | `dcterms:BibliographicResource` | | `<issue>` context | `bf:Instance` | `F3 Manifestation Product Type` (issue as published); `F24 Publication Expression` |
| Series | `P1433` published in (`Q6943763`) | `isPartOf` (`Periodical`) | `dcterms:isPartOf` | `prism:publicationName` | `<journal-title>` | `bf:instanceOf` / `bf:hasSeries` | `F18 Serial Work` (the Mute series) |
| `label` / `title` | `P1476` title | `name` | `dcterms:title` | `dc:title` | `<issue-title>` | `bf:title` (`bf:Title`/`bf:mainTitle`) | `E35 Title` via `P102 has title` |
| `volume` | `P478` | `volumeNumber` (via `PublicationVolume`) | | `prism:volume` | `<volume>` | `bf:seriesEnumeration` | `E42 Identifier` via `P1 is identified by` |
| `number` | `P433` | `issueNumber` | | `prism:number` | `<issue>` | `bf:seriesEnumeration` | `E42 Identifier` via `P1` |
| `publication_date` | `P577` | `datePublished` | `dcterms:issued` | `prism:publicationDate` | `<pub-date>` | `bf:provisionActivity` / `bf:Publication` / `bf:date` | `F30 Publication Event` -> `P4 has time-span` (`E52 Time-Span`) |
| `issn_print` | `P236` | `issn` | `dcterms:identifier` | `prism:issn` | `<issn>` | `bf:identifiedBy` (`bf:Issn`) | `E42 Identifier` via `P1` |
| `issn_issue_token` | none | `identifier` | `dcterms:identifier` | `prism:issueIdentifier` | | `bf:identifiedBy` (`bf:Local`) | `E42 Identifier` via `P1` |
| `isbn13` | `P212` | `isbn` | `dcterms:identifier` | `prism:isbn` | `<isbn>` | `bf:identifiedBy` (`bf:Isbn`) | `E42 Identifier` via `P1` |
| `source_url` | `P953` | `url` | `dcterms:hasVersion` / `dcterms:source` | `prism:url` | `<self-uri>` | `bf:electronicLocator` | `E42 Identifier` / `D1`-style locator, to confirm |
| `language` | `P407` | `inLanguage` | `dcterms:language` | `dc:language` | `xml:lang` | `bf:language` | `P72 has language` (`E56 Language`) |
| `edition_note` | none | `bookEdition` | `dcterms:description` | `prism:edition` | | `bf:editionStatement` | `E62 String` note via `P3 has note` |
| `insert_note` | none | `description` | `dcterms:description` | | | `bf:note` | `P3 has note` |
| `wikidata_qid` | n/a | `sameAs` | `owl:sameAs` | | | `owl:sameAs` | `P130`-style / `owl:sameAs` |

## Notes

- CIDOC-CRM/FRBRoo modelling: the Mute **series** is an `F18 Serial Work`. An **issue** carries ISSN/ISBN and a publication date, so it sits on the manifestation side (`F3`/`F24`). Which of these the project wants is a policy decision for the cataloguers.
- Wikibase does not natively hold RDF classes. The Wikibase schema stores alignment as statements on property and class items using these Wikibase properties (created at bootstrap):
  - `Wikidata property` (url): link to the equivalent Wikidata property.
  - `equivalent class` (url): link to the equivalent class in other schemas.
- schema.org term check: `PublicationIssue`, `PublicationVolume`, `Periodical`, `issueNumber`, `volumeNumber`, `datePublished`, `isPartOf`, `issn`, `isbn`.
- PRISM terms use the PRISM 2.x/3.0 vocabulary (`prism:issueIdentifier`, `prism:volume`, `prism:number`, `prism:issn`, `prism:isbn`, `prism:publicationDate`, `prism:edition`).

## Next

1. Review with the cataloguing lead (CIDOC/FRBRoo choice).
2. Confirm the BIBFRAME modelling of per-issue enumeration.
3. Record the final terms in `etl/field_mapping.yml` under `wikibase_properties[*].equivalents`.
