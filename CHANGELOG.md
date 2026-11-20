# Changelog

## 2026-11-20

- Local stack upgraded from `wikibase/wikibase:8.2.1` to **8.3.0** (MediaWiki 1.46.2; PHP 8.3.37 security fixes, new
  `Special:OntologyPresets`, DB updates on every web start). `wdqs-frontend` 2.2.2 and `quickstatements` 1.2.4 came in
  via their floating tags. Pre-upgrade dump: `wikibase-deploy/backups/sync/local-pre-upgrade-8.3.0-*.sql`
  (gitignored). Verified: all containers healthy, counts unchanged (54 items, 20 properties, 76 pages), SPARQL 51,
  search, admin login, both Query UI examples. **Production still on 8.2.1** and the prod override is unchanged.

- Fixed the local Query UI failing every query with "Invalid URL": the persisted `wdqs-frontend-config.json` had an empty
  host (`http://:8091/...`). Regenerated; both examples now run in the UI (HTTP 200). The server's copy of that file
  has not been checked (production offline).

- Example queries (`wikibase-deploy/config/sparql-examples.wiki`) no longer hard-code `PREFIX wdt: <https://corpus.metamute.org/...>`.
  Both override files now pass `-DwikibaseConceptUri` to `wdqs`, so `wdt:` etc. are predefined per environment and the
  same examples run on localhost and on the server. Applied and verified locally (both examples return rows, page
  reloaded). **Production not yet changed** (offline): needs the updated prod override, a WDQS journal reset, and a
  reload of the examples page (`load-wiki-pages.sh`, or `sync-env.ps1`).

- Local Wikibase (`http://localhost:8091/`) loaded with the same data as production: schema P1-P20, Q1-Q3, 51 issues
  (Q4-Q54), `Project:SPARQL/examples`. New `wikibase-deploy/scripts/local-load.ps1`. SPARQL count verified (51).
- New operator sync between local and production: `scripts/sync-env.ps1 -Direction LocalToProd|ProdToLocal`
  (content-only DB replace, users/OAuth kept, safety backup, search reindex, WDQS reset). Tested locally (dump/restore
  round trip, search reindex, WDQS reset); not run against production, which is still offline.

## 2026-11-19

### Production taken offline (security incident, precaution)

- Following a security incident with no known harmful effects so far, `corpus.metamute.org` (`178.105.222.174`) was
  taken offline as a precaution.
- All 9 containers of the `mute-wikibase-prod` compose project were stopped (traefik, wikibase, wikibase-jobrunner,
  mysql, elasticsearch, wdqs, wdqs-updater, wdqs-frontend, quickstatements). Ports 80/443 have no listeners.
- The host `nginx` service was stopped and disabled (it was already inactive; no nginx container exists).
- No data, volumes, backups or config were deleted, so they are available for forensics and recovery.
- Containers use `restart: unless-stopped`, so they will not come back on reboot after a manual stop.
- The service stays offline until the incident is resolved. To restore it, follow
  "Taking production offline and restarting it" in `wikibase-deploy/README.md`.

### Follow-ups (not yet done)

- Rotate the `id_wikibase_sync` SSH key (passphrase-free, root access) and the Wikibase admin password.
- Consider restricting SSH (port 22) in the Hetzner firewall and disabling SSH password authentication.
- Copy the nightly backups off the server.

## 2026-11-18

- Production Wikibase Suite deployed at `https://corpus.metamute.org/` (see `wikibase-deploy/README.md`).
- Schema bootstrapped (P1-P20) and 51 issues loaded as Q4-Q54.
