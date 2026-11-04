<#
.SYNOPSIS
    KubeCon AKS capture-the-flag lab - deploy the BEGIN state with the Azure CLI (PowerShell).

.DESCRIPTION
    Creates (or reuses) an AKS Automatic cluster plus the Azure services the selected
    challenges need, then deploys each challenge with its seeded fault.
    Run it again to reset challenges: it deletes the selected challenges and deploys them again with their faults.
    Challenge instructions: ../challenges/<id>-*/README.md

.EXAMPLE
    ./deploy.ps1                                  # all challenges in westus3
.EXAMPLE
    ./deploy.ps1 -Challenges c1,c3 -Location centralus
.EXAMPLE
    ./deploy.ps1 -ResourceGroup rg-my-ctf -ClusterName aks-my-ctf -Challenges c1   # reset C1 in an existing environment
#>
#Requires -Version 7.4
[CmdletBinding()]
param(
    # Challenge IDs (c1 c2 c3 c4 a1 a2 a3 a4 a5 a6) or 'all'.
    [string[]]$Challenges = $(if ($env:CHALLENGES) { $env:CHALLENGES } else { 'all' }),
    # Default: the resource group's region when it exists, otherwise westus3.
    [string]$Location = $env:LOCATION,
    [string]$ResourceGroup = $(if ($env:RESOURCE_GROUP) { $env:RESOURCE_GROUP } else { 'rg-kubecon-ctf-begin-pwsh' }),
    # Defaults to aks-<resource group without the rg- prefix>.
    [string]$ClusterName = $env:CLUSTER_NAME,
    # Re-apply without deleting the selected challenges first (default: delete and re-create them).
    [switch]$NoReset,
    # Do not create or update Azure resources; only (re)apply the challenges.
    [switch]$SkipInfra,
    # C4 model settings.
    [string]$ModelName = $(if ($env:AOAI_MODEL_NAME) { $env:AOAI_MODEL_NAME } else { 'gpt-6-luna' }),
    [string]$ModelVersion = $(if ($env:AOAI_MODEL_VERSION) { $env:AOAI_MODEL_VERSION } else { '2026-09-22' }),
    [string]$DeploymentName = $(if ($env:AOAI_DEPLOYMENT_NAME) { $env:AOAI_DEPLOYMENT_NAME } else { 'store-assistant' }),
    [int]$ModelCapacity = $(if ($env:AOAI_CAPACITY) { [int]$env:AOAI_CAPACITY } else { 50 }),
    [string]$AoaiLocation = $env:AOAI_LOCATION
)
$ErrorActionPreference = 'Stop'
$repoRoot = Resolve-Path (Join-Path $PSScriptRoot '../..')
Import-Module (Join-Path $repoRoot 'shared/azure-cli-powershell/CtfLab.psm1') -Force

# Re-running always starts the selected challenges again from a clean, broken state.
Initialize-CtfLab -State begin -RepoRoot $repoRoot -ResourceGroup $ResourceGroup -Challenges $Challenges `
    -Location $Location -ClusterName $ClusterName -Reset (-not $NoReset) -SkipInfra $SkipInfra.IsPresent `
    -ModelName $ModelName -ModelVersion $ModelVersion -DeploymentName $DeploymentName `
    -ModelCapacity $ModelCapacity -AoaiLocation $AoaiLocation
Test-CtfPrerequisites

# Shared platform
New-CtfResourceGroup
Grant-CtfClusterAdmin   # before the cluster exists, so RBAC has propagated when it is ready
Install-CtfCluster
Get-CtfCredentials

# Azure services needed by individual challenges
Enable-CtfAppRouting   # C2: application routing add-on - managed NGINX + Gateway API (approuting-istio)
Enable-CtfPrometheus   # A2: Managed Prometheus for the Grafana dashboards
Install-CtfC4Azure     # C4: Foundry model deployment + ai-service workload identity
Install-CtfA4Azure     # A4: Key Vault + identity; federated subject from challenges/a4-*/azure.env

# Kubernetes objects for each challenge
foreach ($id in (Get-CtfLabSettings).Challenges) { Install-CtfChallenge $id }

Write-CtfSummary
