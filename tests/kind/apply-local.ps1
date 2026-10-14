<#
.SYNOPSIS
    Local smoke test (no Azure needed) with the PowerShell module.

.DESCRIPTION
    Applies the Kubernetes-only challenges to a local kind cluster with the same
    PowerShell module the Azure deployment uses, so the seeded faults, the fixes and
    scoring/verify.ps1 can be exercised quickly. C2, C3, C4 and A4 need Azure.

.EXAMPLE
    kind create cluster --name ctf
    ./tests/kind/apply-local.ps1 -State begin ; ./scoring/verify.ps1 -Context kind-ctf -Quick   # expect NOT PASSED
    ./tests/kind/apply-local.ps1 -State end   ; ./scoring/verify.ps1 -Context kind-ctf -Quick   # expect PASSED
#>
#Requires -Version 7.4
[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateSet('begin', 'end')][string]$State,
    [string[]]$Challenges = @('c1', 'a1', 'a2', 'a3', 'a5', 'a6'),
    [string]$Context = 'kind-ctf'
)
$ErrorActionPreference = 'Stop'
$repoRoot = Resolve-Path (Join-Path $PSScriptRoot '../..')
Import-Module (Join-Path $repoRoot 'shared/azure-cli-powershell/CtfLab.psm1') -Force

Initialize-CtfLab -State $State -RepoRoot $repoRoot -ResourceGroup 'local' -Challenges $Challenges -Reset ($State -eq 'begin')
$settings = Get-CtfLabSettings
$settings.KubeContext = $Context
$settings.StorefrontDnsLabel = 'ctf-store-local'
$settings.StorefrontHostname = 'store.local.test'
$settings.RenderDir = Join-Path $repoRoot ".lab/rendered/kind-$State-pwsh"

# kind has no Azure Disk CSI driver: alias the storage class that A6 uses.
@'
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: managed-csi
provisioner: rancher.io/local-path
volumeBindingMode: WaitForFirstConsumer
reclaimPolicy: Delete
'@ | kubectl --context $Context apply -f - | Out-Null

foreach ($id in $settings.Challenges) { Install-CtfChallenge $id }
Write-Host "Applied ($State): $($settings.Challenges -join ' ')  ->  ./scoring/verify.ps1 -Context $Context -Challenges $($settings.Challenges -join ',')"
