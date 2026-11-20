# Sync the wiki CONTENT between LOCAL (localhost:8091) and PRODUCTION (corpus.metamute.org).
# Run by an operator when needed. Whole-database replace of the TARGET, in one direction:
#
#   .\scripts\sync-env.ps1 -Direction LocalToProd            # publish local content to the server
#   .\scripts\sync-env.ps1 -Direction ProdToLocal            # refresh local from the server
#   .\scripts\sync-env.ps1 -Direction LocalToProd -DryRun    # dump + compare counts only, change nothing
#
# What is copied: all wiki content (items, properties, wiki pages, revisions, logs, ...).
# What is NOT copied (each side keeps its own): user accounts and passwords, OAuth
# consumers (QuickStatements), caches, job queue, .env, uploaded files (image volume).
#
# Safety: the target is full-dumped first (local: backups\sync\, server:
# /var/backups/mute-wikibase/pre-sync-*.sql.gz); you must type SYNC to proceed; the
# restore aborts if the two sides' user tables differ. After the restore the target's
# search index is rebuilt and its SPARQL store (WDQS) is reset and reloads by itself
# (a minute or two; SPARQL results lag until then).
#
# Last-writer-wins: anything edited on the TARGET since the last sync is overwritten
# (recoverable from the safety backup). Do not edit both sides between syncs.
param(
    [Parameter(Mandatory)][ValidateSet("LocalToProd", "ProdToLocal")][string]$Direction,
    [switch]$DryRun,
    [string]$ProdHost = "178.105.222.174",
    [string]$ProdUser = "root",
    [string]$ProdKey = "$env:USERPROFILE\.ssh\id_wikibase_sync"
)
$ErrorActionPreference = "Stop"
$scripts = $PSScriptRoot
$deploy = Split-Path -Parent $scripts
$syncDir = Join-Path $deploy "backups\sync"
$stamp = Get-Date -Format "yyyyMMdd-HHmmss"
New-Item -ItemType Directory -Path $syncDir -Force | Out-Null

$LocalMysql = "mute-wikibase-local-mysql-1"
$LocalWb = "mute-wikibase-local-wikibase-1"
$LocalProject = "mute-wikibase-local"
$compose = @("-f", "wikibase-suite/docker-compose.yml", "-f", "docker-compose.override.local.yml", "--project-directory", "wikibase-suite")
$remoteRoot = "/opt/mute-wikibase"
$remoteArgs = @{ HostName = $ProdHost; User = $ProdUser; Key = $ProdKey }

function Step([string]$m) { Write-Host ""; Write-Host "=== $m ===" -ForegroundColor Cyan }
function Fail([string]$m) { Write-Host "[ERROR] $m" -ForegroundColor Red; exit 1 }

function Remote([string]$cmd, [int]$timeout = 120) {
    $text = (& "$scripts\remote.ps1" -Command $cmd -TimeoutSec $timeout @remoteArgs) -join "`n"
    if ($text -match "TIMEOUT after") { Fail "remote command timed out: $cmd`n$text" }
    return $text
}
function RemoteStep([string]$cmd, [string]$marker, [int]$timeout = 120) {
    $text = Remote $cmd $timeout
    Write-Host $text
    if ($text -notmatch [regex]::Escape("SYNC-OK: $marker")) { Fail "server step '$marker' did not report success." }
    return $text
}
function LocalDocker { & docker @args; if ($LASTEXITCODE -ne 0) { Fail "docker $($args -join ' ') failed" } }
function LocalCounts { (& docker exec $LocalMysql sh /tmp/sync-db.sh counts) -join "" }

# ---------------------------------------------------------------- pre-flight
Step "Pre-flight"
if (-not (Test-Path $ProdKey)) { Fail "SSH key not found: $ProdKey" }
$running = docker ps --format "{{.Names}}"
if ($running -notcontains $LocalMysql) { Fail "Local stack is not running (start it per README 'Local')." }
LocalDocker cp "$scripts\sync-db.sh" "${LocalMysql}:/tmp/sync-db.sh"

foreach ($f in "sync-db.sh", "server-sync.sh") {
    $o = & "$scripts\push.ps1" -Local "$scripts\$f" -Remote "$remoteRoot/scripts/$f" @remoteArgs
    if (($o -join "`n") -notmatch "pushed ") { Fail "push of $f failed:`n$o" }
}
$prodCounts = Remote "docker exec mute-wikibase-prod-mysql-1 true 2>&1 && bash $remoteRoot/scripts/server-sync.sh counts" 60
if ($prodCounts -notmatch "SYNC-OK: counts") {
    Fail ("Production database container is not reachable/running. If production is deliberately offline, start it first (README: 'Taking production offline and restarting it').`n" + $prodCounts)
}
Write-Host "local : $(LocalCounts)"
Write-Host "server: $(($prodCounts -split "`n" | Where-Object { $_ -match '^items=' }) -join '')"

if ($Direction -eq "LocalToProd") { $srcName = "LOCAL"; $dstName = "PRODUCTION" } else { $srcName = "PRODUCTION"; $dstName = "LOCAL" }

# ---------------------------------------------------------------- dump source
Step "1. Dump $srcName content"
$dumpFile = Join-Path $syncDir "$($srcName.ToLower())-$stamp.sql"
if ($Direction -eq "LocalToProd") {
    LocalDocker exec $LocalMysql sh /tmp/sync-db.sh dump /tmp/mute-sync.sql
    LocalDocker cp "${LocalMysql}:/tmp/mute-sync.sql" $dumpFile
    LocalDocker exec $LocalMysql rm -f /tmp/mute-sync.sql
} else {
    $null = RemoteStep "bash $remoteRoot/scripts/server-sync.sh dump" "dump" 180
    $o = & "$scripts\pull.ps1" -Remote "$remoteRoot/sync/outgoing.sql" -Local $dumpFile @remoteArgs
    Write-Host $o
    $null = Remote "rm -f $remoteRoot/sync/outgoing.sql" 30
}
if (-not (Test-Path $dumpFile) -or (Get-Item $dumpFile).Length -lt 100KB) { Fail "Dump missing or suspiciously small: $dumpFile" }
Write-Host "dump: $dumpFile ($([math]::Round((Get-Item $dumpFile).Length / 1KB)) KB)"

if ($DryRun) {
    Write-Host ""
    Write-Host "DRY RUN: nothing was changed on $dstName. Dump kept at $dumpFile." -ForegroundColor Yellow
    exit 0
}

# ---------------------------------------------------------------- confirm
Write-Host ""
Write-Host "This REPLACES all wiki content on $dstName with the content of $srcName." -ForegroundColor Yellow
Write-Host "Users, passwords and OAuth consumers on $dstName are kept. A safety backup is taken first."
$ans = Read-Host "Type SYNC to continue"
if ($ans -ne "SYNC") { Write-Host "Aborted - no changes made."; exit 0 }

# ---------------------------------------------------------------- restore
if ($Direction -eq "LocalToProd") {
    Step "2. Upload dump to the server"
    $o = & "$scripts\push.ps1" -Local $dumpFile -Remote "$remoteRoot/sync/incoming.sql" -TimeoutSec 300 @remoteArgs
    Write-Host $o
    Step "3. Restore on PRODUCTION (safety backup, restore, search reindex, SPARQL reset)"
    $null = RemoteStep "bash $remoteRoot/scripts/server-sync.sh restore" "restore" 900
} else {
    Step "2. Safety backup of LOCAL (full dump)"
    $safety = Join-Path $syncDir "local-pre-sync-$stamp.sql"
    LocalDocker exec $LocalMysql sh /tmp/sync-db.sh dump-full /tmp/pre-sync.sql
    LocalDocker cp "${LocalMysql}:/tmp/pre-sync.sql" $safety
    LocalDocker exec $LocalMysql rm -f /tmp/pre-sync.sql
    Write-Host "saved $safety"

    Step "3. Restore into LOCAL"
    LocalDocker cp $dumpFile "${LocalMysql}:/tmp/mute-sync.sql"
    LocalDocker exec $LocalMysql sh /tmp/sync-db.sh restore /tmp/mute-sync.sql
    LocalDocker exec $LocalMysql rm -f /tmp/mute-sync.sql

    Step "4. Rebuild recent changes + search index"
    LocalDocker exec $LocalWb php /var/www/html/maintenance/run.php rebuildrecentchanges
    LocalDocker exec $LocalWb php /var/www/html/maintenance/run.php /var/www/html/extensions/CirrusSearch/maintenance/ForceSearchIndex.php --skipLinks --indexOnSkip

    Step "5. Reset local SPARQL (WDQS)"
    Push-Location $deploy
    try {
        LocalDocker compose @compose stop wdqs-updater wdqs
        LocalDocker run --rm -v "${LocalProject}_wdqs-data:/d" alpine sh -c "rm -f /d/*.jnl"
        LocalDocker compose @compose up -d wdqs wdqs-updater
    } finally { Pop-Location }
}

# ---------------------------------------------------------------- verify
Step "Verify"
Write-Host "local : $(LocalCounts)"
$after = Remote "bash $remoteRoot/scripts/server-sync.sh counts" 60
Write-Host "server: $(($after -split "`n" | Where-Object { $_ -match '^items=' }) -join '')"
Write-Host ""
Write-Host "Sync $Direction complete. SPARQL on $dstName repopulates within a few minutes." -ForegroundColor Green
Write-Host "Dump kept at $dumpFile (gitignored). Delete old files in backups\sync\ when no longer needed."
