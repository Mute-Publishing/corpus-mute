# Download one file from the production server with scp, with a hard timeout and
# file-redirected output (counterpart of push.ps1).
#   .\scripts\pull.ps1 -Remote /opt/mute-wikibase/sync/outgoing.sql -Local .\backups\sync\prod.sql
param(
    [Parameter(Mandatory)][string]$Remote,
    [Parameter(Mandatory)][string]$Local,
    [int]$TimeoutSec = 300,
    [string]$HostName = "178.105.222.174",
    [string]$User = "root",
    [string]$Key = "$env:USERPROFILE\.ssh\id_wikibase_sync"
)
$in = Join-Path $env:TEMP "pull.in.txt"; Set-Content -Path $in -Value "" -NoNewline
$out = Join-Path $env:TEMP "pull.out.txt"; $err = Join-Path $env:TEMP "pull.err.txt"
Remove-Item $out, $err -ErrorAction SilentlyContinue
$dir = Split-Path -Parent $Local
if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
$scpArgs = @("-i", $Key, "-o", "BatchMode=yes", "-o", "IdentitiesOnly=yes", "-o", "ConnectTimeout=10",
             "$User@${HostName}:$Remote", "`"$Local`"")
$p = Start-Process -FilePath "scp" -ArgumentList $scpArgs -NoNewWindow -PassThru `
        -RedirectStandardOutput $out -RedirectStandardError $err -RedirectStandardInput $in
if (-not $p.WaitForExit($TimeoutSec * 1000)) { $p.Kill(); Write-Output "TIMEOUT after ${TimeoutSec}s"; exit 1 }
if (Test-Path $err) { Get-Content $err }
if ($p.ExitCode -ne 0) { Write-Output "scp exit code $($p.ExitCode)"; exit $p.ExitCode }
Write-Output "pulled $Remote -> $Local"
