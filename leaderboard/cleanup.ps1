<#
.SYNOPSIS
    KubeCon AKS capture-the-flag lab - leaderboard kill switch and clean-up.

.DESCRIPTION
    -RevokeOnly: invalidates every token issued for the storage account at once - lab VMs can no longer record
    results, the leaderboard keeps showing what is there. Run leaderboard/setup.ps1 to issue a new token.
    Default: revokes the tokens, deletes the leaderboard's resource group (storage account and every result) and
    the local files in .lab/leaderboard/. Only resource groups created by leaderboard/setup are deleted.

.EXAMPLE
    ./leaderboard/cleanup.ps1 -RevokeOnly
.EXAMPLE
    ./leaderboard/cleanup.ps1                   # asks for confirmation
#>
#Requires -Version 7.4
[CmdletBinding()]
param(
    # Default: from .lab/leaderboard/settings.env.
    [string]$ResourceGroup,
    [string]$StorageAccount,
    # Subscription of the leaderboard (default: the one recorded by setup, else the Azure CLI default).
    [string]$Subscription,
    # Only invalidate the tokens; keep the leaderboard.
    [switch]$RevokeOnly,
    # Don't ask for confirmation.
    [switch]$Yes
)
$ErrorActionPreference = 'Stop'
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$outDir = Join-Path $repoRoot '.lab/leaderboard'
$settingsFile = Join-Path $outDir 'settings.env'
function Get-Setting([string]$Key) {
    if (Test-Path $settingsFile) {
        foreach ($line in Get-Content $settingsFile) { if ($line -match "^$Key=(.*)$") { return $Matches[1].Trim() } }
    }
    return ''
}
if (-not $ResourceGroup) { $ResourceGroup = Get-Setting 'LB_RESOURCE_GROUP' }
if (-not $StorageAccount) { $StorageAccount = Get-Setting 'LB_STORAGE_ACCOUNT' }
if (-not $Subscription) { $Subscription = Get-Setting 'LB_SUBSCRIPTION' }
if (-not $ResourceGroup -or -not $StorageAccount) { throw 'Pass -ResourceGroup and -StorageAccount (or run this where leaderboard/setup.ps1 ran)' }
# Act on the leaderboard's own subscription, whatever the Azure CLI default is.
$sub = if ($Subscription) { @('--subscription', $Subscription) } else { @() }
if ($Subscription) { Write-Host "Leaderboard subscription: $Subscription" }

Write-Host "Revoking every token issued for $StorageAccount ..."
& az storage account revoke-delegation-keys -n $StorageAccount -g $ResourceGroup @sub --only-show-errors -o none
$revoked = ($LASTEXITCODE -eq 0)
if ($revoked) { Write-Host 'OK - tokens revoked: lab VMs can no longer record results.' -ForegroundColor Green }
elseif ($RevokeOnly) { throw "Could not revoke the tokens for $StorageAccount" }
else { Write-Warning 'Could not revoke the tokens (continuing with the deletion)' }
if ($RevokeOnly) {
    Write-Host 'To accept results again: ./leaderboard/setup.ps1 (new token), then update the Skillable life cycle action.'
    return
}

$exists = (& az group exists -n $ResourceGroup @sub --only-show-errors 2>$null | Out-String).Trim()
if ($LASTEXITCODE -ne 0 -or $exists -notin 'true', 'false') {
    throw "Could not check resource group $ResourceGroup (sign-in or subscription problem?) - nothing was deleted"
}
if ($exists -eq 'false') { Write-Host "Resource group $ResourceGroup not found." }
else {
    $purpose = (& az group show -n $ResourceGroup @sub --query tags.purpose -o tsv --only-show-errors 2>$null | Out-String).Trim()
    if ($purpose -ne 'kubecon-ctf-leaderboard') { throw "Resource group $ResourceGroup was not created by leaderboard/setup (tag purpose=$purpose) - not deleting it" }
    if (-not $Yes) {
        $answer = Read-Host "Delete resource group $ResourceGroup with storage account $StorageAccount and every result? (yes/no)"
        if ($answer -notin 'y', 'yes') { Write-Host 'Cancelled.'; return }
    }
    Write-Host "Deleting resource group $ResourceGroup (a few minutes) ..."
    & az group delete -n $ResourceGroup @sub --yes --only-show-errors
    if ($LASTEXITCODE -ne 0) { throw "Could not delete resource group $ResourceGroup" }
    Write-Host 'OK - leaderboard deleted.' -ForegroundColor Green
}
foreach ($f in 'settings.env', 'submit-url.txt', 'skillable-lca-windows.ps1', 'skillable-lca-linux.sh', 'board') {
    Remove-Item -Recurse -Force -ErrorAction SilentlyContinue (Join-Path $outDir $f)
}
Write-Host "Removed the local files in $outDir."
