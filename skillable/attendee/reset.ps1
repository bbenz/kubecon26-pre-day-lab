<#
.SYNOPSIS
    Resets a KubeCon AKS capture-the-flag lab challenge: deploys it again from the start, with its fault.

.DESCRIPTION
    Use it to start a challenge over. It deletes the challenge's namespace, and deploys the challenge again with
    begin-challenge\azure-cli-powershell\deploy.ps1, the script that built your lab. Your changes to that
    challenge are lost, and other challenges aren't touched. Some resets also reset Azure resources: C2 deletes
    your gateway and its public IP address, C3 deletes its node pool and nodes, A4 resets its federated identity
    credential, and A6 re-creates its disk and data. A reset takes 2 to 5 minutes.

    Run az login first: the reset runs as you, with your Azure CLI sign-in.

.EXAMPLE
    C:\lab-resources\reset.ps1 c1

.EXAMPLE
    C:\lab-resources\reset.ps1 c3 -Force
#>
[CmdletBinding()]
param(
    # The challenge to reset, such as c1. To reset several: c1,a2.
    [Parameter(Mandatory, Position = 0)]
    [string[]]$Challenges,
    # Don't ask for confirmation.
    [switch]$Force
)
$ErrorActionPreference = 'Stop'

if ($PSVersionTable.PSVersion -lt [version]'7.4') {
    # Windows PowerShell: run this script again in PowerShell 7.
    $forward = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $PSCommandPath, ($Challenges -join ','))
    if ($Force) { $forward += '-Force' }
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
if ($ids -contains 'all') { $ids = $known }
foreach ($id in $ids) {
    if ($known -notcontains $id) { throw "There's no challenge '$id'. Use one of: $($known -join ', ')." }
}
if (-not $ids) { throw 'Name the challenge to reset, such as: reset.ps1 c1' }
$list = $ids -join ', '

$account = (& az account show --only-show-errors -o json 2>$null) | Out-String
if ($LASTEXITCODE -ne 0 -or -not $account.Trim()) { throw 'Sign in to the Azure CLI first: run az login, and select your lab account.' }

if (-not $Force -and -not $PSCmdlet.ShouldContinue("Your changes to $list are lost. Other challenges aren't touched.", "Reset $list to the start, with its fault?")) {
    Write-Host 'Nothing was reset.'
    exit 0
}

if ($settings.subscriptionId -and ($account | ConvertFrom-Json).id -ne $settings.subscriptionId) {
    & az account set --subscription $settings.subscriptionId --only-show-errors
    if ($LASTEXITCODE -ne 0) { throw "Your Azure CLI sign-in can't use the lab's subscription. Run az login, and select your lab account." }
}

# deploy.ps1 runs in its own PowerShell process, so it changes nothing in this terminal.
$deploy = Join-Path $PSScriptRoot 'begin-challenge\azure-cli-powershell\deploy.ps1'
& (Get-Process -Id $PID).Path -NoProfile -ExecutionPolicy Bypass -File $deploy -ResourceGroup $settings.resourceGroup `
    -Location $settings.location -ClusterName $settings.clusterName -Challenges ($ids -join ',')
if ($LASTEXITCODE -ne 0) {
    Write-Host "The reset of $list didn't finish. Run the same command again. If it fails again, ask a proctor." -ForegroundColor Red
    exit 1
}
Write-Host ''
Write-Host "Reset done: $list starts again, with its fault." -ForegroundColor Green
