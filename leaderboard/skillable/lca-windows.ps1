# -----------------------------------------------------------------------------
# Skillable life cycle action (Windows lab VM) - register the lab for the
# KubeCon CTF leaderboard, so scoring/verify.* records each result.
#
# Don't paste this template: paste .lab/leaderboard/skillable-lca-windows.ps1,
# which leaderboard/setup.* writes with the event's submit URL (create-only
# token) filled in. Lab profile > Life Cycle Actions > Add:
#   Event: Running   Action: Execute Script in Virtual Machine   Language: PowerShell
#   Blocking: No     Error action: Ignore (the lab works without the leaderboard)
# Skillable replaces the @lab tokens when the lab starts. The token expires
# (7 days at most): after re-running setup, paste the new copy into the lab
# profile. Runs on Windows PowerShell 5.1 and PowerShell 7.
# -----------------------------------------------------------------------------
$ErrorActionPreference = 'Stop'
$submitUrl = '__SUBMIT_URL__'
# The Skillable user ID keeps a player's flags when the lab is relaunched.
$playerId = @'
@lab.User.Id
'@
$firstName = @'
@lab.User.FirstName
'@
$lastName = @'
@lab.User.LastName
'@

$playerId = $playerId.Trim()
if ($playerId -like '@lab*' -or -not $playerId) { throw 'The @lab tokens were not replaced - run this as a Skillable life cycle action' }
$playerId = $playerId -replace '[^A-Za-z0-9._-]', ''
# Shown on the projected leaderboard: first name and last initial only (no e-mail address).
$name = (($firstName.Trim() -replace "[^\p{L}\p{Nd} .'-]", '') -replace '\s+', ' ').Trim()
$initial = $lastName.Trim() -replace '[^\p{L}]', ''
if ($initial) { $name = "$name $($initial.Substring(0, 1))." }
$name = $name.Trim()
if ($name.Length -gt 24) { $name = $name.Substring(0, 24).Trim() }
if (-not $name) { $name = "Player $playerId" }

$dir = Join-Path $env:ProgramData 'kubecon-ctf'
New-Item -ItemType Directory -Force -Path $dir | Out-Null
$lines = @(
    '# KubeCon CTF leaderboard registration - written by the Skillable life cycle action'
    "CTF_LEADERBOARD_URL=$submitUrl"
    "CTF_PLAYER_ID=$playerId"
    "CTF_PLAYER_NAME=$name"
)
[IO.File]::WriteAllText((Join-Path $dir 'leaderboard.env'), ($lines -join "`r`n") + "`r`n", (New-Object System.Text.UTF8Encoding $false))
Write-Output "Registered for the leaderboard as '$name'"
