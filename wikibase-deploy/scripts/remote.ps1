# Run one command on the target server over SSH with a hard timeout; output goes
# to a file so the VS Code terminal capture can't stall on it.
#   .\scripts\remote.ps1 -Command "ls /opt" [-TimeoutSec 60]
# Uses the dedicated passphrase-free key id_wikibase_sync (see c:\wikibase\.ssh-setup.md).
param(
    [Parameter(Mandatory)][string]$Command,
    [int]$TimeoutSec = 60,
    [string]$HostName = "178.105.222.174",
    [string]$User = "root",
    [string]$Key = "$env:USERPROFILE\.ssh\id_wikibase_sync"
)
$out = Join-Path $env:TEMP "remote.out.txt"
$err = Join-Path $env:TEMP "remote.err.txt"
$in = Join-Path $env:TEMP "remote.in.txt"
Set-Content -Path $in -Value "" -NoNewline
Remove-Item $out, $err -ErrorAction SilentlyContinue
$args = @("-n", "-i", $Key, "-o", "BatchMode=yes", "-o", "IdentitiesOnly=yes", "-o", "ConnectTimeout=10",
          "-o", "ServerAliveInterval=5", "-o", "ServerAliveCountMax=3", "$User@$HostName", $Command)
$p = Start-Process -FilePath "ssh" -ArgumentList $args -NoNewWindow -PassThru `
        -RedirectStandardOutput $out -RedirectStandardError $err -RedirectStandardInput $in
if (-not $p.WaitForExit($TimeoutSec * 1000)) {
    $p.Kill()
    Write-Output "TIMEOUT after ${TimeoutSec}s"
}
if (Test-Path $out) { Get-Content $out }
if (Test-Path $err) { Get-Content $err | Where-Object { $_ -notmatch '^Warning: Permanently added' } }
