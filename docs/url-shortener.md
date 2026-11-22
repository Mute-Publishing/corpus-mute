# Short URLs for the Wikibase Query Service (behind Traefik)

How to make the **"Short URL to this page"** button of the Wikibase Query Service UI work on your own Wikibase,
using MediaWiki's own `UrlShortener` extension. Written from the Corpus Mute deployment (Wikibase Suite, one public
host, Traefik routing by path) and verified there on 2026-11-21, locally and in production.

Tested with `wikibase/wikibase:8.3.0` (MediaWiki 1.46.2), `wikibase/wdqs-frontend:2` (2.2.x), UrlShortener `REL1_46`
(1.2.0), Traefik v3 as shipped in Wikibase Suite.

## The problem

The Query UI ships with one working shortener, `"urlShortener": "tinyurl"`. It asks `tinyurl.com` to shorten the link,
which has two problems:

- TinyURL (behind Cloudflare) answers **403 Forbidden** for long query URLs. A query with comments and several
  `OPTIONAL` blocks is a link of 1,000 to 2,000+ characters, so the button fails on exactly the queries people
  want to share. Short test queries work, which makes the failure look random.
- Every shared query is sent to a third party.

The stock UI has no setting for "use my own wiki". Its source (`UrlShortener.js` upstream) only knows three providers:
`tinyurl`, `wmf` (hard-wired to meta.wikimedia.org) and `wikibeta` (a Wikimedia test wiki). So the solution has two parts:

1. **MediaWiki side (native):** the `UrlShortener` extension, which provides `action=shortenurl` on the wiki API and
   redirects short links.
2. **Query UI side (small patch):** add a fourth provider, `local`, that calls that API on the same origin.

## What you get

```text
Query UI  --POST /w/api.php action=shortenurl-->  MediaWiki  --> https://example.org/r/3
browser   --GET  /r/3  -->  Traefik rewrites to /wiki/Special:UrlRedirector/3  -->  301 to the full query URL
```

No CORS (same origin), no third party, short links of the form `https://example.org/r/CODE`, and only your own host can
be shortened.

## Requirements

- A Wikibase whose query UI and wiki are served on the **same host** (path-based routing, as in Wikibase Suite with a
  single `WIKIBASE_PUBLIC_HOST`). If the UI is on another host, add CORS for `/w/api.php` or serve both on one host.
- `/w/api.php` reachable from the browser under the same origin as `/query/`.
- The MediaWiki branch of the extension must match your MediaWiki version (`REL1_46` for image 8.3.0). Check
  `Special:Version`.

## Step 1: install the MediaWiki extension

UrlShortener is not bundled in the `wikibase/wikibase` image. Wikibase Suite mounts `config/extensions/` into the
container, so clone it there (adjust the path for your setup):

```sh
git clone --depth 1 --branch REL1_46 \
  https://gerrit.wikimedia.org/r/mediawiki/extensions/UrlShortener \
  wikibase-suite/config/extensions/UrlShortener
```

Its QR-code dependency (`endroid/qr-code`) is already in the image's `vendor/`, so no `composer install` is needed.

## Step 2: configure MediaWiki

Put this where your other local settings live (for Wikibase Suite: a file included from
`config/LocalSettings.php`; here `wikibase-deploy/config/mute-local-settings.php`):

```php
wfLoadExtension( 'extensions/UrlShortener' );        # path relative to the container's extensions/ dir

$wgUrlShortenerTemplate = '/r/$1';                   # short links look like /r/CODE
# Omit '$' from the codes: some sites strip it from links. NEVER change this once links exist,
# every existing short link would point somewhere else.
$wgUrlShortenerIdSet = '23456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz';
$wgUrlShortenerUrlSizeLimit = 8000;                  # default 2000 is too small for long SPARQL queries

# Behind a reverse proxy: treat the Docker/private ranges as trusted proxies so MediaWiki takes the visitor's
# address from X-Forwarded-For. Without it every visitor looks like Traefik, and the extension's per-IP rate
# limit (10 per 2 minutes) would be shared by everyone.
$wgCdnServersNoPurge = array_merge( $wgCdnServersNoPurge ?? [], [ '172.16.0.0/12', '10.0.0.0/8', '192.168.0.0/16' ] );
```

Notes:

- The default `$wgUrlShortenerAllowedDomains` (`false`) restricts shortening to the host in `$wgServer`, plus
  `$wgCanonicalServer`'s non-standard port. That is what you want here. Only change it if you must shorten other hosts.
- Anonymous users may create short links (`urlshortener-create-url` is granted to `*` by default). Sysops can delete
  them at `Special:ManageShortUrls`. To restrict creation to logged-in users, remove the right from `*` in
  `$wgGroupPermissions`; the Query UI button then fails for anonymous visitors.
- I verified on production that the real client address reaches MediaWiki and that a forged `X-Forwarded-For` sent by a
  client is overwritten by Traefik. I did not test the setup without the `$wgCdnServersNoPurge` line.

## Step 3: create the table and reload PHP

```sh
docker exec <wikibase-container> php /var/www/html/maintenance/run.php update --quick
docker restart <wikibase-container> <jobrunner-container>      # PHP opcache keeps the old settings otherwise
```

`update --quick` prints `Creating urlshortcodes table...done.` once. It is safe to re-run.

## Step 4: route `/r/CODE` in Traefik

MediaWiki serves `/wiki/Special:UrlRedirector/CODE`. Apache in the image has no `/r/` rule, so without this step
every short link is a 404 even though the API works. Rewrite in Traefik (file provider, as in Wikibase Suite's
`traefik-dynamic.yml`):

```yaml
http:
  routers:
    shorturl-router:
      rule: 'PathPrefix(`/r/`)'
      service: wikibase            # your existing service pointing at the wikibase container
      priority: 85                 # must beat the catch-all PathPrefix(`/`) router (priority 1 here)
      middlewares: [ shorturl-rewrite ]
  middlewares:
    shorturl-rewrite:
      replacePathRegex:
        regex: '^/r/(.+)$'
        replacement: '/wiki/Special:UrlRedirector/$1'
```

- Give the router an **explicit `priority`**. With no priority Traefik orders by rule length, which is easy to get wrong
  when other routers use `PathPrefix`.
- The file provider watches the file, so Traefik needs no restart.
- If you configure Traefik with Docker labels instead, the same router and `replacepathregex` middleware apply (not
  tested here).
- With another front end: nginx `location ~ ^/r/(.+)$ { return 301 /wiki/Special:UrlRedirector/$1; }`, or the
  `RewriteRule` shipped in the extension's `redirect.htaccess`.

## Step 5: patch the Query UI

Both `wikibase/init.mjs` (main UI) and `wikibase/embedInit.mjs` (embedded results) of the `wdqs-frontend` image contain
the shortener. The script `wikibase-deploy/scripts/patch-wdqs-shortener.sh` makes two edits to each and **aborts if
it does not find exactly one of each**, so a future upstream change fails loudly instead of silently:

1. adds the provider `local:function(x){return this._getWikiShort(x,"")}`
2. turns the API URL `"https://"+server+"/w/api.php"` into `(server?"https://"+server:"")+"/w/api.php"`, so an empty
   server name means "same origin".

Generate the patched files from the image you actually run (the script only needs `sh` and `sed -E`; on Windows run it
in a container, as below):

```sh
mkdir -p config && cd config
docker create --name wdqs-extract wikibase/wdqs-frontend:2
docker cp wdqs-extract:/usr/share/nginx/html/wikibase/init.mjs      init.orig.mjs
docker cp wdqs-extract:/usr/share/nginx/html/wikibase/embedInit.mjs embedInit.orig.mjs
docker rm wdqs-extract
cp ../scripts/patch-wdqs-shortener.sh .

docker run --rm --entrypoint sh -v "$PWD:/w" -w /w wikibase/wdqs-frontend:2 -c '
  sed -i "s/\r$//" patch-wdqs-shortener.sh
  sh patch-wdqs-shortener.sh init.orig.mjs      init.mjs
  sh patch-wdqs-shortener.sh embedInit.orig.mjs embedInit.mjs'
```

Expected: `patched init.orig.mjs -> init.mjs` and the same for `embedInit`. (I ran exactly this against the unmodified
upstream files: init.mjs 186,505 to 186,563 bytes, embedInit.mjs 153,641 to 153,699 bytes.)

Mount the two files over the originals and switch the provider in the frontend config.

`docker-compose.override.yml`:

```yaml
  wdqs-frontend:
    volumes:
      - ../config/init.mjs:/usr/share/nginx/html/wikibase/init.mjs:ro
      - ../config/embedInit.mjs:/usr/share/nginx/html/wikibase/embedInit.mjs:ro
```

`wdqs-frontend-config.json` (the file the image's entrypoint copies to `custom-config.json`; Wikibase Suite generates it
under `config/`, so edit your copy and keep it out of version control only if it holds secrets, which it does not):

```json
"api": { "urlShortener": "local", ... }
```

Then recreate the container: `docker compose up -d --force-recreate wdqs-frontend`.

Optional, recommended: send `Cache-Control: no-cache` for the two patched `.mjs` files, otherwise browsers keep running
the old bundle after a change. See `config/wdqs-frontend-entrypoint.sh` for an `nginx` snippet appended by a custom
entrypoint. Hard-refresh once if you skip it.

**Upgrades:** re-run Step 5 whenever you pull a new `wdqs-frontend` image, because the mounted files replace the image's.
If the script aborts, upstream changed the shortener code. Compare with `UrlShortener.js` in
<https://github.com/wikimedia/wikidata-query-gui> and adapt the two substitutions.

## Verify

1. API, through the public URL (use your host; `-d` makes it a POST, which the module requires):

   ```sh
   curl -s -X POST https://example.org/w/api.php \
     --data-urlencode action=shortenurl --data-urlencode format=json \
     --data-urlencode "url=https://example.org/query/#SELECT%20*"
   # {"shortenurl":{"shorturl":"https://example.org/r/3","shorturlalt":"https://example.org/r/_y"}}
   ```

   `shorturlalt` is the second code the extension makes for each link (prefix `_`), kept to avoid unfortunate words
   in the main one.
2. `curl -sI https://example.org/r/3` returns `301` with a `Location:` of the full query. `/r/zzzz` returns `404`.
3. In a browser: open `/query/`, load an example or your own long query, click the link icon "Short URL to this page"
   and check the popover shows `https://example.org/r/N`. Open it in a new tab: the same query loads.
4. `curl -s https://example.org/query/custom-config.json` shows `"urlShortener": "local"`.

## Short links and QR codes for wiki pages and items

The same extension also gives short links and QR codes for any page of your own wiki, including Wikibase item and
property pages (`/wiki/Item:Q4`). Links to other hosts, such as wikidata.org, are refused (`urlshortener-error-disallowed-url`).

- **Special page (works in every skin):** `Special:UrlShortener`, optionally pre-filled with
  `Special:UrlShortener?url=https://example.org/wiki/Item:Q4`. Shows the short link, the alternative `/r/_xx` link and a
  downloadable QR code (SVG).
- **From the page itself:** the extension adds a "Get shortened URL" entry, which opens a popup with a Copy button, the
  alternative link and the QR code with a "Download QR code" button. Out of the box it appears only in the **Tools
  sidebar of Vector/Timeless/MonoBook** and in **Minerva's menu in mobile view**. With Minerva as the desktop skin (as on
  Corpus Mute) there is no entry at all, so add the hook below.
- **API:** add `qrcode=1` to the `action=shortenurl` call to get the QR code back as SVG text in `shortenurl.qrcode`.

```php
# Minerva, desktop view: same entry the extension adds in mobile view (the "..." page menu).
$wgHooks['SkinTemplateNavigation::Universal'][] = static function ( $sktemplate, &$links ): void {
	if ( $sktemplate->getSkinName() !== 'minerva' ||
		$sktemplate->getTitle()->isSpecial( 'UrlShortener' ) ||
		!$sktemplate->getAuthority()->isAllowed( 'urlshortener-create-url' )
	) {
		return;
	}
	$query = $sktemplate->getRequest()->getQueryValues();
	unset( $query['title'], $query['useskin'], $query['mobileaction'] );
	$fullUrl = $sktemplate->getTitle()->getFullURL( $query, false, PROTO_CANONICAL );
	$links['actions']['urlshortener'] = [
		'icon' => 'qrCode',
		'href' => \MediaWiki\SpecialPage\SpecialPage::getTitleFor( 'UrlShortener' )->getLocalURL( [ 'url' => $fullUrl ] ),
		'text' => $sktemplate->msg( 'urlshortener-toolbox' )->plain(),
	];
};

# QR codes always encode the short link (default: only URLs over 200 bytes are shortened first).
$wgUrlShortenerQrCodeShortenLimit = 0;
```

The extension's own JavaScript binds to the menu entry, so no extra script is needed. Reload PHP afterwards (restart the
wikibase container). The entry is not shown on `Special:` pages other than the main ones; use `Special:UrlShortener`
there.

QR code notes:

- Without `$wgUrlShortenerQrCodeShortenLimit = 0` a QR code for a URL under 200 bytes encodes that URL itself, forced to
  `http://`, so a scan costs an extra redirect to https. With `0` the code points to the short link, which is shorter
  (checked on Corpus Mute: the SVG shrank from 6,901 to 5,292 characters for the same item) and stays valid if the page
  URL scheme changes.
- The extension rate-limits creation to 10 per 2 minutes per IP, and admins cannot bypass it. For many QR codes (for
  example one per item) pace the calls, one every 13 seconds or more.

## Troubleshooting

| Symptom | Cause / fix |
| --- | --- |
| Popover says "URL shortening failed" | Open the browser network tab: the `POST /w/api.php` response says why. Common: table missing (run `update --quick`), URL longer than `$wgUrlShortenerUrlSizeLimit`, or `urlshortener-error-disallowed-url` because the URL host differs from `$wgServer`. |
| `API: Invalid action "shortenurl"` | Extension not loaded: wrong path in `wfLoadExtension`, or PHP not restarted (opcache). |
| API works, `/r/N` is a 404 | Step 4 missing, or the router priority is lower than the catch-all. |
| Popover still shows TinyURL behaviour | Browser cached `custom-config.json` or `init.mjs`: hard refresh; check the served config says `local`. |
| Everyone gets rate-limited together | `$wgCdnServersNoPurge` not set, so all visitors share Traefik's address. |
| `urlshortener-error-badports` locally | Local URL has a port other than 80/443 and does not match `$wgCanonicalServer`. Set `$wgServer` to `http://localhost:PORT` or `$wgUrlShortenerAllowArbitraryPorts = true`. |
| No "Get shortened URL" entry on pages | Desktop Minerva has none by default: add the hook in "Short links and QR codes" above (Vector shows it under Tools, mobile Minerva in the "..." menu). |
| Short links break after a database import | The `urlshortcodes` table holds absolute URLs of its own host. Do not copy it between environments (localhost links would land on production). Corpus Mute excludes it in `sync-db.sh`. |

## Where this lives in this repository

| Piece | File |
| --- | --- |
| MediaWiki settings | `wikibase-deploy/config/mute-local-settings.php` |
| Traefik route and rewrite | `wikibase-deploy/config/traefik-dynamic.yml` (`shorturl-router`, `shorturl-rewrite`) |
| UI provider selection | `wikibase-deploy/config/wdqs-frontend-config.local.json`, `...prod.json` |
| Patched UI bundles | `wikibase-deploy/config/init.mjs`, `embedInit.mjs` |
| Patch generator | `wikibase-deploy/scripts/patch-wdqs-shortener.sh` |
| Production roll-out | `wikibase-deploy/scripts/server-branding.sh` (clones the extension, runs `update --quick`) |
