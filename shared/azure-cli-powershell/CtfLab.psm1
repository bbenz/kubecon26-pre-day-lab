# -----------------------------------------------------------------------------
# KubeCon AKS capture-the-flag lab - shared PowerShell module (Azure CLI).
# Imported by begin-challenge/azure-cli-powershell/*.ps1 and
# challenge-end-state/azure-cli-powershell/*.ps1. Requires PowerShell 7.2+.
# -----------------------------------------------------------------------------
#Requires -Version 7.2
Set-StrictMode -Version 3.0

$script:Ctf = $null

. (Join-Path $PSScriptRoot 'CtfLab.Common.ps1')
. (Join-Path $PSScriptRoot 'CtfLab.Azure.ps1')
. (Join-Path $PSScriptRoot 'CtfLab.Challenges.ps1')

Export-ModuleMember -Function @(
    'Initialize-CtfLab', 'Test-CtfPrerequisites', 'Get-CtfLabSettings',
    'New-CtfResourceGroup', 'Install-CtfCluster', 'Grant-CtfClusterAdmin', 'Get-CtfCredentials',
    'Enable-CtfGatewayApi', 'Install-CtfC4Azure', 'Install-CtfA4Azure',
    'Install-CtfChallenge', 'Write-CtfSummary', 'Remove-CtfLab'
)
