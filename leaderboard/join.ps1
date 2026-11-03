<#
.SYNOPSIS
    KubeCon AKS capture-the-flag lab - register this machine for the event leaderboard (outside Skillable).

.DESCRIPTION
    Writes ~/.kubecon-ctf/leaderboard.env with the submit URL, a player ID and the name shown on the board;
    scoring/verify.* then records every result on the leaderboard. On Skillable lab VMs the life cycle
    action registers the lab instead (leaderboard/README.md).

.EXAMPLE
    ./leaderboard/join.ps1 -Name 'Brian B.'                     # submit URL from .lab/leaderboard/submit-url.txt
.EXAMPLE
    ./leaderboard/join.ps1 -Name 'Team Kube' -SubmitUrl 'https://<account>.blob.core.windows.net/ctf?<token>'
.EXAMPLE
    ./leaderboard/join.ps1 -Remove                              # stop recording results from this machine
#>
#Requires -Version 7.4
[CmdletBinding(DefaultParameterSetName = 'Join')]
param(
    # Name shown on the leaderboard: letters, digits, spaces and . ' - (24 characters at most).
    [Parameter(Mandatory, ParameterSetName = 'Join')][string]$Name,
    # Default: .lab/leaderboard/submit-url.txt (written by leaderboard/setup.*).
    [Parameter(ParameterSetName = 'Join')][string]$SubmitUrl,
    # Default: the ID already registered on this machine, or a new random one.
    [Parameter(ParameterSetName = 'Join')][ValidatePattern('^[A-Za-z0-9._-]{1,64}$')][string]$PlayerId,
    [Parameter(Mandatory, ParameterSetName = 'Remove')][switch]$Remove
)
$ErrorActionPreference = 'Stop'
$file = Join-Path $HOME '.kubecon-ctf/leaderboard.env'
if ($Remove) {
    if (Test-Path $file) { Remove-Item $file; Write-Host "Removed $file - results are no longer recorded from this machine." }
    else { Write-Host "Nothing to remove ($file not found)." }
    return
}
$clean = (($Name -replace "[^\p{L}\p{Nd} .'-]", '') -replace '\s+', ' ').Trim()
if ($clean.Length -gt 24) { $clean = $clean.Substring(0, 24).Trim() }
if (-not $clean) { throw 'The name must contain letters or digits' }
if (-not $SubmitUrl) {
    $saved = Join-Path $PSScriptRoot '../.lab/leaderboard/submit-url.txt'
    if (-not (Test-Path $saved)) { throw 'Pass -SubmitUrl (the organizer has it in .lab/leaderboard/submit-url.txt after running leaderboard/setup)' }
    $SubmitUrl = (Get-Content -Raw $saved).Trim()
}
if ($SubmitUrl -notmatch '^https://[a-z0-9]{3,24}\.blob\.core\.windows\.net/[a-z0-9-]{3,63}\?\S*sig=') {
    throw 'The submit URL must look like https://<account>.blob.core.windows.net/<container>?<token>'
}
if (-not $PlayerId -and (Test-Path $file)) {
    foreach ($line in Get-Content $file) { if ($line -match '^CTF_PLAYER_ID=(.+)$') { $PlayerId = $Matches[1].Trim() } }
}
if (-not $PlayerId) { $PlayerId = [guid]::NewGuid().ToString('N') }
New-Item -ItemType Directory -Force -Path (Split-Path $file) | Out-Null
$lines = @(
    '# KubeCon CTF leaderboard registration - written by leaderboard/join.ps1'
    "CTF_LEADERBOARD_URL=$SubmitUrl"
    "CTF_PLAYER_ID=$PlayerId"
    "CTF_PLAYER_NAME=$clean"
)
[IO.File]::WriteAllText($file, ($lines -join "`n") + "`n", [Text.UTF8Encoding]::new($false))
Write-Host "Registered as '$clean' (player ID $PlayerId) in $file"
Write-Host 'scoring/verify.* now records each result on the leaderboard (-NoReport / --no-report skips a run).'
