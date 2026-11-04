<#
.SYNOPSIS
    KubeCon AKS capture-the-flag lab - show the live leaderboard (projector view).

.DESCRIPTION
    Reads the event's results with your Microsoft Entra sign-in - you need Storage Blob Data Reader (or
    Contributor) on the storage account; no token is involved - and writes board-data.js next to a copy of
    leaderboard.html every few seconds, then opens the page in your browser.
    Press F11 for full screen. Double-click a player to hide them, press U to show hidden players again.
    Stop with Ctrl+C. See leaderboard/README.md.

.EXAMPLE
    ./leaderboard/board.ps1                     # storage account, container and subscription from .lab/leaderboard/settings.env
.EXAMPLE
    ./leaderboard/board.ps1 -StorageAccount ctflb1a2b3c4d -Container ctf -Challenges c1,c2,a2,c4 -Title 'KubeCon NA 2026 - AKS CTF' -Start '2026-11-10 09:00'
#>
#Requires -Version 7.4
[CmdletBinding()]
param(
    [string]$StorageAccount,
    [string]$Container,
    # Subscription of the storage account (default: the one recorded by setup, else the Azure CLI default).
    # Needed when your Azure CLI default subscription is in another tenant.
    [string]$Subscription,
    # Challenges shown and scored, in column order.
    [string[]]$Challenges = @('c1', 'c2', 'c3', 'c4', 'a1', 'a2', 'a3', 'a4', 'a5', 'a6'),
    [string]$Title = 'KubeCon AKS Capture the Flag',
    [ValidateRange(5, 300)][int]$RefreshSeconds = 10,
    [ValidateRange(5, 200)][int]$MaxRows = 20,
    # Event start in local time (for example '2026-11-10 09:00'): capture times are shown as time since the start.
    [string]$Start,
    # Where the page and its data are written (default: .lab/leaderboard/board).
    [string]$OutDir,
    # Write the data once and exit.
    [switch]$Once,
    # Don't open the browser.
    [switch]$NoBrowser
)
$ErrorActionPreference = 'Stop'
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$settingsFile = Join-Path $repoRoot '.lab/leaderboard/settings.env'
function Get-Setting([string]$Key) {
    if (Test-Path $settingsFile) {
        foreach ($line in Get-Content $settingsFile) { if ($line -match "^$Key=(.*)$") { return $Matches[1].Trim() } }
    }
    return ''
}
if (-not $StorageAccount) { $StorageAccount = Get-Setting 'LB_STORAGE_ACCOUNT' }
if (-not $Container) { $Container = Get-Setting 'LB_CONTAINER' }
if (-not $Subscription) { $Subscription = Get-Setting 'LB_SUBSCRIPTION' }
if (-not $StorageAccount -or -not $Container) { throw 'Pass -StorageAccount and -Container (or run leaderboard/setup.ps1 on this machine first)' }
if (-not (Get-Command az -ErrorAction SilentlyContinue)) { throw 'The Azure CLI (az) is required' }
# The sign-in is for the storage account's tenant even when the Azure CLI default subscription is elsewhere.
$subscriptionArgs = if ($Subscription) { @('--subscription', $Subscription) } else { @() }
$ids = @($Challenges | ForEach-Object { $_ -split '[,\s]+' } | Where-Object { $_ } | ForEach-Object { $_.ToLowerInvariant() })
$bad = @($ids | Where-Object { $_ -notmatch '^[ac][0-9]$' })
if ($bad) { throw "Unknown challenge ID(s) in -Challenges: $($bad -join ', ')" }
$startIso = if ($Start) { ([datetime]::Parse($Start)).ToUniversalTime().ToString('o') } else { $null }
if (-not $OutDir) { $OutDir = Join-Path $repoRoot '.lab/leaderboard/board' }
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
$page = Join-Path $OutDir 'leaderboard.html'
Copy-Item (Join-Path $PSScriptRoot 'leaderboard.html') $page -Force
$dataFile = Join-Path $OutDir 'board-data.js'
$utf8 = [Text.UTF8Encoding]::new($false)
$script:entries = '[]'
$script:dataTime = $null

# Reads every result record (name, creation time, metadata) and rewrites board-data.js. Returns an error or $null.
function Update-Board {
    $problem = $null
    $err = New-TemporaryFile
    try {
        $raw = & az storage blob list --account-name $StorageAccount --container-name $Container --auth-mode login @subscriptionArgs `
            --prefix 'results/' --include m --num-results '*' --query '[].{n:name,t:properties.creationTime,m:metadata}' `
            -o json --only-show-errors 2>$err.FullName
        $text = ($raw | Out-String).Trim()
        if ($LASTEXITCODE -ne 0) { $problem = ((Get-Content -Raw $err.FullName) -replace '\s+', ' ').Trim() }
        elseif (-not ($text.StartsWith('[') -and $text.EndsWith(']'))) { $problem = 'unexpected output from az storage blob list' }
        else { $script:entries = $text; $script:dataTime = (Get-Date).ToUniversalTime().ToString('o') }
    }
    finally { Remove-Item $err.FullName -ErrorAction SilentlyContinue }
    $head = [ordered]@{
        generated = (Get-Date).ToUniversalTime().ToString('o'); dataTime = $script:dataTime; title = $Title
        challenges = $ids; refresh = $RefreshSeconds; maxRows = $MaxRows; start = $startIso; error = $problem
    } | ConvertTo-Json -Compress
    # az prints valid JSON; it is embedded as is (the page treats every value as untrusted text).
    $js = 'window.CTF_BOARD = ' + $head.Substring(0, $head.Length - 1) + ',"entries":' + $script:entries + "};`n"
    [IO.File]::WriteAllText("$dataFile.tmp", $js, $utf8)
    Move-Item -Force "$dataFile.tmp" $dataFile
    return $problem
}

Write-Host "Leaderboard: $StorageAccount/$Container -> $page"
$problem = Update-Board
if ($problem) {
    Write-Warning "Can't read results: $problem"
    Write-Warning 'You need an az login session with Storage Blob Data Reader (or Contributor) on the storage account.'
}
if (-not $NoBrowser) { Invoke-Item $page }
if ($Once) { return }
Write-Host "Refreshing every $RefreshSeconds seconds - press Ctrl+C to stop."
while ($true) {
    Start-Sleep -Seconds $RefreshSeconds
    $problem = Update-Board
    if ($problem) { Write-Warning "$(Get-Date -Format HH:mm:ss) can't read results: $problem" }
}
