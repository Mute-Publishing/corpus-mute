# Load the Mute data into the LOCAL Wikibase (mirror of server-load.sh for production).
# The admin password is read from wikibase-suite\.env into this process only (never printed).
#
#   .\scripts\local-load.ps1 -Mode bootstrap          # once: properties + class/series/language items
#   .\scripts\local-load.ps1 -Mode import             # issues; skips ones that already exist (safe to re-run)
#   .\scripts\local-load.ps1 -Mode pages              # Project:SPARQL/examples (Query UI Examples dialog)
#   .\scripts\local-load.ps1 -Mode all                # bootstrap (if needed) + import + pages
#   .\scripts\local-load.ps1 -Mode import -Dry        # print only
param(
    [ValidateSet("bootstrap", "import", "pages", "all")][string]$Mode = "all",
    [switch]$Dry,
    [string]$Python = "python"
)
$ErrorActionPreference = "Stop"
$deploy = Split-Path -Parent $PSScriptRoot
$repo = Split-Path -Parent $deploy
$envFile = Join-Path $deploy "wikibase-suite\.env"
if (-not (Test-Path $envFile)) { throw "Missing $envFile - run scripts\new-local-env.ps1 first." }

function Get-EnvValue([string]$name) {
    $line = Get-Content $envFile | Where-Object { $_ -match "^$name=" } | Select-Object -First 1
    if (-not $line) { return "" }
    return $line.Substring($name.Length + 1).Trim()
}

$container = "mute-wikibase-local-wikibase-1"
$uploader = Join-Path $repo "mute-er-model\etl\upload_to_wikibase.py"
$state = Join-Path $repo "mute-er-model\output\bootstrap.local.json"

$env:WB_TARGET = "local"
$env:WB_API = "http://localhost:8091/w/api.php"
$env:WB_USER = Get-EnvValue "MW_ADMIN_NAME"
$env:WB_PASSWORD = Get-EnvValue "MW_ADMIN_PASS"
if ($Dry) { $env:DRY_RUN = "true" } else { Remove-Item Env:\DRY_RUN -ErrorAction SilentlyContinue }

function Invoke-Uploader([string]$step) {
    & $Python $uploader $step
    if ($LASTEXITCODE -ne 0) { throw "uploader '$step' failed (exit $LASTEXITCODE)" }
}

function Load-Pages {
    $page = Join-Path $deploy "config\sparql-examples.wiki"
    docker cp $page "${container}:/tmp/page.wikitext"
    if ($LASTEXITCODE -ne 0) { throw "docker cp failed" }
    docker exec $container sh -c 'php /var/www/html/maintenance/run.php edit --user "$MW_ADMIN_NAME" --summary "Load Query UI examples from repo" "Project:SPARQL/examples" < /tmp/page.wikitext; rm -f /tmp/page.wikitext'
    if ($LASTEXITCODE -ne 0) { throw "page edit failed" }
}

try {
    if ($Mode -in "bootstrap", "all") {
        if ($Mode -eq "all" -and (Test-Path $state)) { Write-Host "bootstrap.local.json exists - skipping bootstrap" }
        else { Invoke-Uploader "bootstrap" }
    }
    if ($Mode -in "import", "all") { Invoke-Uploader "import" }
    if (($Mode -in "pages", "all") -and (-not $Dry)) { Load-Pages }
}
finally {
    Remove-Item Env:\WB_PASSWORD -ErrorAction SilentlyContinue
}
