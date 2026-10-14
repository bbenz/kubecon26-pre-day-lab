<#
.SYNOPSIS
    KubeCon AKS capture-the-flag lab - scoring / verification (PowerShell).

.DESCRIPTION
    Checks each challenge against the success criteria from the lab design.
    Against a BEGIN-state deployment the checks fail (the fault is present); after the
    expected repair - or against an END-state deployment - they pass.
    Needs only kubectl (with access to the cluster). Exit code 0 when every selected
    challenge passes.

.EXAMPLE
    ./scoring/verify.ps1                                   # every challenge found in the current context
.EXAMPLE
    ./scoring/verify.ps1 -Context aks-kubecon-ctf-begin-pwsh -Challenges c1,a3
.EXAMPLE
    ./scoring/verify.ps1 -Quick                            # shorter observation windows
#>
#Requires -Version 7.4
[CmdletBinding()]
param(
    # kubectl context (default: current context).
    [string]$Context,
    # Challenge IDs (default: every challenge namespace found).
    [string[]]$Challenges,
    # Shorter waits and observation windows (less strict, for fast iteration).
    [switch]$Quick
)
$ErrorActionPreference = 'Continue'
Set-StrictMode -Version 3.0

if (-not (Get-Command kubectl -ErrorAction SilentlyContinue)) { Write-Error 'kubectl is required'; exit 2 }
if (-not $Context) { $Context = (& kubectl config current-context 2>$null | Out-String).Trim() }
if (-not $Context) { Write-Error 'No kubectl context; pass -Context'; exit 2 }

$script:Kctx = $Context
$script:ObserveSeconds = if ($Quick) { 15 } else { 60 }
$script:LongWait = if ($Quick) { 90 } else { 420 }
$script:RolloutTimeout = if ($Quick) { 45 } else { 240 }
$script:ChPass = 0
$script:ChFail = 0

# ---------- helpers shared by the check modules ----------
function k { & kubectl --context $script:Kctx @args }
# Captured output (stderr dropped) as a trimmed string.
function kj { ((& kubectl --context $script:Kctx @args 2>$null) | Out-String).Trim() }
# Parsed JSON for a kubectl get, or $null.
function kobj {
    $raw = (& kubectl --context $script:Kctx @args -o json 2>$null) | Out-String
    if ($LASTEXITCODE -ne 0 -or -not $raw.Trim()) { return $null }
    return ($raw | ConvertFrom-Json -Depth 50)
}
function Pass([string]$Message) { Write-Host '  ' -NoNewline; Write-Host 'PASS' -ForegroundColor Green -NoNewline; Write-Host "  $Message"; $script:ChPass++ }
function Fail([string]$Message) { Write-Host '  ' -NoNewline; Write-Host 'FAIL' -ForegroundColor Red -NoNewline; Write-Host "  $Message"; $script:ChFail++ }
function Detail([string]$Message) {
    if (-not $Message) { return }
    ($Message -split "`r?`n" | Where-Object { $_ } | Select-Object -First 8) | ForEach-Object { Write-Host "          $_" }
}
function Check([string]$Description, [scriptblock]$Test) {
    $ok = $false
    try { $ok = [bool](& $Test) } catch { $ok = $false }
    if ($ok) { Pass $Description } else { Fail $Description }
}
function Expect([string]$Description, [string]$Want, [string]$Got) {
    if ($Want -ceq $Got) { Pass $Description } else { Fail $Description; Detail "expected '$Want', got '$Got'" }
}
function Get-Prop($Object, [string]$Path) {
    # Safe nested property access: Get-Prop $obj 'spec.template.metadata.labels'
    $cur = $Object
    foreach ($part in $Path -split '\.') {
        if ($null -eq $cur) { return $null }
        $p = $cur.PSObject.Properties[$part]
        $cur = if ($p) { $p.Value } else { $null }
    }
    return $cur
}
function Test-Rollout([string]$Namespace, [string]$Deployment) {
    & kubectl --context $script:Kctx rollout status "deployment/$Deployment" -n $Namespace "--timeout=$($script:RolloutTimeout)s" *> $null
    return ($LASTEXITCODE -eq 0)
}
function Get-RestartCount([string]$Namespace, [string]$Selector) {
    $pods = kobj get pods -n $Namespace -l $Selector
    if (-not $pods) { return 0 }
    $sum = 0
    foreach ($p in $pods.items) { foreach ($cs in @(Get-Prop $p 'status.containerStatuses')) { if ($cs) { $sum += $cs.restartCount } } }
    return $sum
}
function Get-RunningPod([string]$Namespace, [string]$Selector) {
    return kj get pods -n $Namespace -l $Selector --field-selector=status.phase=Running -o 'jsonpath={.items[0].metadata.name}'
}
function Get-ServiceProxy([string]$Namespace, [string]$Service, [string]$Path) {
    return kj get --raw "/api/v1/namespaces/$Namespace/services/$Service/proxy$Path"
}
# Returns $true when the Job succeeded within the timeout, $false when it failed or timed out.
function Wait-K8sJob([string]$Namespace, [string]$Job, [int]$TimeoutSeconds) {
    for ($t = 0; $t -lt $TimeoutSeconds; $t += 5) {
        $st = kj get job $Job -n $Namespace -o 'jsonpath={.status.succeeded}|{.status.conditions[?(@.type=="Failed")].status}'
        if ($st -like '1|*') { return $true }
        if ($st -like '*|True') { return $false }
        Start-Sleep -Seconds 5
    }
    return $false
}

. (Join-Path $PSScriptRoot 'lib/VerifyCore.ps1')
. (Join-Path $PSScriptRoot 'lib/VerifyAlternates.ps1')

$all = [ordered]@{
    c1 = @('c1-store', "C1 The store won't start");             c2 = @('c2-storefront', 'C2 Healthy pods, broken storefront')
    c3 = @('c3-processing', 'C3 Capacity that never arrives');     c4 = @('c4-assistant', 'C4 The AI assistant is up, but not working')
    a1 = @('a1-inventory', 'A1 Where did DNS go?');                a2 = @('a2-checkout', 'A2 Fast yesterday, slow today')
    a3 = @('a3-maintenance', 'A3 Ready for maintenance?');         a4 = @('a4-config', 'A4 Identity without secrets')
    a5 = @('a5-releases', 'A5 Running is not ready');              a6 = @('a6-records', "A6 The data survived, the application didn't")
}

if (-not $Challenges) {
    $Challenges = @((kj get namespaces -l kubecon.lab/challenge -o 'jsonpath={range .items[*]}{.metadata.labels.kubecon\.lab/challenge}{" "}{end}') -split '\s+' | Where-Object { $_ })
    if (-not $Challenges) { Write-Error "No challenge namespaces found in context $Context"; exit 2 }
}
$selected = @($Challenges | ForEach-Object { $_ -split '[,\s]+' } | Where-Object { $_ } | ForEach-Object { $_.ToLowerInvariant() })

Write-Host "KubeCon AKS CTF - verification against context '$Context'" -ForegroundColor White
$summary = @()
$overall = 0
foreach ($id in $all.Keys) {
    if ($selected -notcontains $id) { continue }
    $script:ChPass = 0; $script:ChFail = 0
    Write-Host ''
    Write-Host "[$id] $($all[$id][1])" -ForegroundColor White
    & kubectl --context $Context get namespace $all[$id][0] *> $null
    if ($LASTEXITCODE -ne 0) { Fail "challenge namespace not found - is $id deployed in this context?" }
    else { & "Test-Challenge$($id.ToUpperInvariant())" }
    $result = if ($script:ChFail -eq 0) { 'PASSED' } else { $overall = 1; 'NOT PASSED' }
    $summary += ('  {0,-4} {1,-11} {2,2}/{3,-2} checks  {4}' -f $id, $result, $script:ChPass, ($script:ChPass + $script:ChFail), ($all[$id][1] -replace '^\S+\s', ''))
}
Write-Host ''
Write-Host 'Summary' -ForegroundColor White
$summary | ForEach-Object { Write-Host $_ }
exit $overall
