# Create wikibase-suite\.env for the LOCAL stack with random local-only passwords.
# Refuses to overwrite an existing .env. Values are never printed.
$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot
$target = Join-Path $root "wikibase-suite\.env"
if (Test-Path $target) { Write-Host "Exists, not overwriting: $target"; exit 0 }

function New-Pass {
    $chars = (48..57) + (65..90) + (97..122)
    -join ($chars | Get-Random -Count 24 | ForEach-Object { [char]$_ })
}

$text = Get-Content (Join-Path $root ".env.example") -Raw
$text = $text -replace 'MW_ADMIN_PASS=.*', ("MW_ADMIN_PASS=" + (New-Pass))
$text = $text -replace 'DB_PASS=.*', ("DB_PASS=" + (New-Pass))
[IO.File]::WriteAllText($target, $text, (New-Object System.Text.UTF8Encoding($false)))
Write-Host "Wrote $target (passwords hidden)"
