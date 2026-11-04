<#
.SYNOPSIS
    Try the Kubernetes-only challenges without Azure, on a local kind cluster.

.DESCRIPTION
    Applies the challenges that need no Azure services (C1, A1, A2, A3, A5, A6) to a local kind cluster with
    the same PowerShell module the Azure deployment uses, each with its fault in place, and resets them when
    you run it again. Check your work with scoring/verify.ps1. C2, C3, C4 and A4 need Azure. A1 behaves
    differently on AKS Automatic, so try it on Azure too.

    -StateDir applies another folder of challenges, with the same layout as begin-challenge.

.EXAMPLE
    kind create cluster --name ctf
    ./tests/kind/apply-local.ps1 ; ./scoring/verify.ps1 -Context kind-ctf -Quick   # expect NOT PASSED
#>
#Requires -Version 7.4
[CmdletBinding()]
param(
    [ValidateSet('begin', 'end')][string]$State = 'begin',
    [string[]]$Challenges = @('c1', 'a1', 'a2', 'a3', 'a5', 'a6'),
    [string]$Context = 'kind-ctf',
    # A folder with challenges/<id>-*/manifests. Default: begin-challenge in this repository.
    [string]$StateDir
)
$ErrorActionPreference = 'Stop'
$repoRoot = Resolve-Path (Join-Path $PSScriptRoot '../..')
Import-Module (Join-Path $repoRoot 'shared/azure-cli-powershell/CtfLab.psm1') -Force

Initialize-CtfLab -State $State -RepoRoot $repoRoot -ResourceGroup 'local' -Challenges $Challenges -Reset ($State -eq 'begin') -StateDir $StateDir
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
