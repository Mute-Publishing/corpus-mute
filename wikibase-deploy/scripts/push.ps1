# Upload one local file to the target server with scp, with a hard timeout and
# file-redirected output (the VS Code terminal capture can stall on scp/ssh).
#   .\scripts\push.ps1 -Local .\scripts\server-env.sh -Remote /opt/mute-wikibase/scripts/server-env.sh
# Line endings of *.sh files are normalised to LF on the server.
param(
    [Parameter(Mandatory)][string]$Local,
    [Parameter(Mandatory)][string]$Remote,
    [int]$TimeoutSec = 60,
    [string]$HostName = "178.105.222.174",
    [string]$User = "root",
    [string]$Key = "$env:USERPROFILE\.ssh\id_wikibase_sync"
)
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$in = Join-Path $env:TEMP "push.in.txt"; Set-Content -Path $in -Value "" -NoNewline
$out = Join-Path $env:TEMP "push.out.txt"; $err = Join-Path $env:TEMP "push.err.txt"
Remove-Item $out, $err -ErrorAction SilentlyContinue
$localFull = (Resolve-Path $Local).Path
$scpArgs = @("-i", $Key, "-o", "BatchMode=yes", "-o", "IdentitiesOnly=yes", "-o", "ConnectTimeout=10",
             "`"$localFull`"", "$User@${HostName}:$Remote")
$p = Start-Process -FilePath "scp" -ArgumentList $scpArgs -NoNewWindow -PassThru `
        -RedirectStandardOutput $out -RedirectStandardError $err -RedirectStandardInput $in
if (-not $p.WaitForExit($TimeoutSec * 1000)) { $p.Kill(); Write-Output "TIMEOUT after ${TimeoutSec}s"; exit 1 }
if (Test-Path $err) { Get-Content $err }
if ($p.ExitCode -ne 0) { Write-Output "scp exit code $($p.ExitCode)"; exit $p.ExitCode }
if ($Remote -like "*.sh") {
    & "$here\remote.ps1" -Command "sed -i 's/\r$//' $Remote && chmod 755 $Remote" -TimeoutSec 30 -HostName $HostName -User $User -Key $Key
}
Write-Output "pushed $Local -> $Remote"
