<#
.SYNOPSIS
    KubeCon AKS capture-the-flag lab - delete a BEGIN-state environment.

.DESCRIPTION
    Deletes the resource group created by deploy.ps1 (AKS cluster, Foundry account,
    Key Vault, identities), purges the soft-deleted Key Vault and Foundry account so
    the names can be reused, and removes the kubectl context.

.EXAMPLE
    ./cleanup.ps1                 # asks for confirmation
.EXAMPLE
    ./cleanup.ps1 -ResourceGroup my-rg -Confirm:$false
#>
#Requires -Version 7.4
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param(
    [string]$ResourceGroup = $(if ($env:RESOURCE_GROUP) { $env:RESOURCE_GROUP } else { 'rg-kubecon-ctf-begin-pwsh' }),
    [string]$ClusterName = $env:CLUSTER_NAME,
    # Start the deletion and return (skips purging soft-deleted resources).
    [switch]$NoWait
)
$ErrorActionPreference = 'Stop'
$repoRoot = Resolve-Path (Join-Path $PSScriptRoot '../..')
Import-Module (Join-Path $repoRoot 'shared/azure-cli-powershell/CtfLab.psm1') -Force

if ($PSCmdlet.ShouldProcess($ResourceGroup, 'Delete the lab resource group and everything in it')) {
    Remove-CtfLab -ResourceGroup $ResourceGroup -ClusterName $ClusterName -RepoRoot $repoRoot -NoWait:$NoWait -Confirm:$false
}