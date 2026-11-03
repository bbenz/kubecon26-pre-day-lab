<#
.SYNOPSIS
    Post demo results to the event leaderboard, to try the projector view before the event.

.DESCRIPTION
    Records results for -Players demo players (IDs demo-01, demo-02, ...) with random progress, through the
    same reporting code as scoring/verify.ps1 and the same create-only token as the lab VMs. Remove them
    afterwards - that needs your own Entra sign-in with Storage Blob Data Contributor (the token can't delete):
        az storage blob delete-batch --account-name <account> --source <container> --pattern 'results/demo-*' --auth-mode login

.EXAMPLE
    ./tests/leaderboard/simulate-players.ps1 -Players 15
#>
#Requires -Version 7.4
[CmdletBinding()]
param(
    [ValidateRange(1, 99)][int]$Players = 12,
    [string[]]$Challenges = @('c1', 'c2', 'c3', 'c4', 'a1', 'a2', 'a3', 'a4', 'a5', 'a6'),
    # Default: .lab/leaderboard/submit-url.txt (written by leaderboard/setup.*).
    [string]$SubmitUrl,
    [int]$Seed = 2026
)
$ErrorActionPreference = 'Stop'
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
if (-not $SubmitUrl) { $SubmitUrl = (Get-Content -Raw (Join-Path $repoRoot '.lab/leaderboard/submit-url.txt')).Trim() }
. (Join-Path $repoRoot 'scoring/lib/Leaderboard.ps1')

$names = 'Alex P.', 'Sam R.', 'Jordan K.', 'Taylor M.', 'Morgan L.', 'Casey D.', 'Riley S.', 'Jamie F.', 'Avery N.', 'Quinn B.',
    'Rowan T.', 'Skyler W.', 'Emerson H.', 'Finley J.', 'Harper C.', 'Kai O.', 'Logan V.', 'Parker G.', 'Reese Y.', 'Sage E.'
$ids = @($Challenges | ForEach-Object { $_ -split '[,\s]+' } | Where-Object { $_ } | ForEach-Object { $_.ToLowerInvariant() })
$random = [Random]::new($Seed)
$saved = @{ Url = $env:CTF_LEADERBOARD_URL; Id = $env:CTF_PLAYER_ID; Name = $env:CTF_PLAYER_NAME }
try {
    $env:CTF_LEADERBOARD_URL = $SubmitUrl
    for ($i = 1; $i -le $Players; $i++) {
        $env:CTF_PLAYER_ID = 'demo-{0:d2}' -f $i
        $env:CTF_PLAYER_NAME = $names[($i - 1) % $names.Count]
        Initialize-Leaderboard -Disabled $false -Quick $false
        $solved = $random.Next(0, $ids.Count + 1)
        for ($j = 0; $j -lt [Math]::Min($solved + 1, $ids.Count); $j++) {
            if ($j -lt $solved) { Send-LeaderboardResult $ids[$j] $true 6 6 }
            else { $total = 6 + $random.Next(0, 4); Send-LeaderboardResult $ids[$j] $false $random.Next(1, $total) $total }
        }
    }
}
finally {
    $env:CTF_LEADERBOARD_URL = $saved.Url; $env:CTF_PLAYER_ID = $saved.Id; $env:CTF_PLAYER_NAME = $saved.Name
}
