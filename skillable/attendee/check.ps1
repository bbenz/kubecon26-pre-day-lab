<#
.SYNOPSIS
    Checks your work on the KubeCon AKS capture-the-flag lab's challenges.

.DESCRIPTION
    Runs each challenge's checks against your cluster, and shows PASS or FAIL for each success criterion, then
    PASSED or NOT PASSED for the challenge. A challenge that passes is a captured flag. Every challenge starts
    NOT PASSED, because its fault is in place.

    A check takes a minute or two, because some checks watch the application for 60 seconds. C3 can wait
    several minutes for a new node. Run az login first: kubectl uses your Azure CLI sign-in.

    If your event has a leaderboard, each check records your result there, with your first name and last
    initial. -NoReport keeps a run off the leaderboard. Runs with -Quick are never recorded.

.EXAMPLE
    C:\lab-resources\check.ps1 c1

.EXAMPLE
    C:\lab-resources\check.ps1 c1,a2 -Quick
#>
[CmdletBinding()]
param(
    # Challenge IDs, such as c1, or c1,a2. Default: every challenge in your cluster.
    [Parameter(Position = 0)]
    [string[]]$Challenges,
    # Shorter observation windows, for a quick look while you work. Never recorded on the leaderboard.
    [switch]$Quick,
    # Don't record this run on the event leaderboard.
    [switch]$NoReport
)
$ErrorActionPreference = 'Stop'

if ($PSVersionTable.PSVersion -lt [version]'7.4') {
    # Windows PowerShell: run this script again in PowerShell 7.
    $forward = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $PSCommandPath)
    if ($Challenges) { $forward += ($Challenges -join ',') }
    if ($Quick) { $forward += '-Quick' }
    if ($NoReport) { $forward += '-NoReport' }
    $pwsh = (Get-Command pwsh -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1).Source
    if (-not $pwsh) { $pwsh = Join-Path $env:ProgramFiles 'PowerShell\7\pwsh.exe' }
    & $pwsh @forward
    exit $LASTEXITCODE
}

$settingsFile = Join-Path $PSScriptRoot 'lab-settings.json'
if (-not (Test-Path -LiteralPath $settingsFile)) { throw "$settingsFile is missing, so the lab's setup didn't finish. Ask a proctor." }
$settings = Get-Content -LiteralPath $settingsFile -Raw | ConvertFrom-Json

$known = @(Get-ChildItem -LiteralPath (Join-Path $PSScriptRoot 'begin-challenge\challenges') -Directory | ForEach-Object { ($_.Name -split '-')[0] })
$ids = @($Challenges | ForEach-Object { $_ -split '[,\s]+' } | Where-Object { $_ } | ForEach-Object { $_.ToLowerInvariant() })
if ($ids -contains 'all') { $ids = @() }
foreach ($id in $ids) {
    if ($known -notcontains $id) { throw "There's no challenge '$id'. Use one of: $($known -join ', ')." }
}

& az account show --only-show-errors -o none 2>$null
if ($LASTEXITCODE -ne 0) { throw 'Sign in to the Azure CLI first: run az login, and select your lab account.' }

$verify = @{ Context = [string]$settings.clusterName }
if ($ids) { $verify.Challenges = $ids }
if ($Quick) { $verify.Quick = $true }
if ($NoReport) { $verify.NoReport = $true }
& (Join-Path $PSScriptRoot 'scoring\verify.ps1') @verify
exit $LASTEXITCODE
