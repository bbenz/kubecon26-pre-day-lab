# -----------------------------------------------------------------------------
# KubeCon AKS capture-the-flag lab - PowerShell common helpers.
# Dot-sourced by CtfLab.psm1.
# -----------------------------------------------------------------------------

$script:AllChallenges = @('c1', 'c2', 'c3', 'c4', 'a1', 'a2', 'a3', 'a4', 'a5', 'a6')
$script:Namespaces = @{
    c1 = 'c1-store'; c2 = 'c2-storefront'; c3 = 'c3-processing'; c4 = 'c4-assistant'; a1 = 'a1-inventory'
    a2 = 'a2-checkout'; a3 = 'a3-maintenance'; a4 = 'a4-config'; a5 = 'a5-releases'; a6 = 'a6-records'
}
$script:AksAdminRole = 'Azure Kubernetes Service RBAC Cluster Admin'
$script:SecretName = 'lab-config'
$script:SecretValue = 'kubecon-ctf-a4: identity without secrets works'
$script:MinAzVersion = [version]'2.86.0'
# C4's Foundry account goes to the cluster's region when that region offers the model as Global Standard, and
# otherwise to the first of these that does: westus3, where the lab was tested, then eastus2 and swedencentral,
# which offer the most models. Some regions offer no OpenAI models at all (westcentralus, for one).
$script:AoaiFallbackLocations = @('westus3', 'eastus2', 'swedencentral')

function Write-CtfStep([string]$Message) { Write-Host ''; Write-Host "==> $Message" -ForegroundColor Cyan }
function Write-CtfInfo([string]$Message) { Write-Host "    $Message" }
function Write-CtfOk([string]$Message) { Write-Host '    ' -NoNewline; Write-Host 'OK' -ForegroundColor Green -NoNewline; Write-Host "  $Message" }
function Write-CtfWarn([string]$Message) { Write-Host "    WARNING: $Message" -ForegroundColor Yellow }

# The helpers below are simple functions: every argument (including "-n" style
# switches) is passed straight through to az / kubectl via $args.

# az ... -o tsv; returns '' on failure.
function Invoke-AzTsv {
    $out = & az @args --only-show-errors -o tsv 2>$null
    if ($LASTEXITCODE -ne 0) { return '' }
    return (($out | Out-String).Trim())
}

# az ... -o none; returns $true when the command succeeded.
function Test-AzCommand {
    & az @args --only-show-errors -o none 2>$null | Out-Null
    return ($LASTEXITCODE -eq 0)
}

# az ... ; throws with az's error output when the command fails.
function Invoke-AzCommand {
    $err = New-TemporaryFile
    try {
        $out = & az @args --only-show-errors 2>$err.FullName
        if ($LASTEXITCODE -ne 0) {
            throw "az $($args -join ' ') failed:`n$((Get-Content -Raw $err.FullName) -replace '\s+$', '')"
        }
        return $out
    }
    finally { Remove-Item $err.FullName -ErrorAction SilentlyContinue }
}

# Runs az aks create/update with the core (GA) Azure CLI implementation. The
# aks-preview extension, when installed, replaces az aks commands with preview
# versions; an empty AZURE_EXTENSION_DIR bypasses it for this command only.
function Invoke-AzCoreCommand {
    $saved = $env:AZURE_EXTENSION_DIR
    try {
        if ($script:Ctf.NoExtDir) { $env:AZURE_EXTENSION_DIR = $script:Ctf.NoExtDir }
        Invoke-AzCommand @args
    }
    finally { $env:AZURE_EXTENSION_DIR = $saved }
}

# kubectl against the lab cluster's context only.
function Invoke-Kubectl { & kubectl --context $script:Ctf.KubeContext @args }

# Runs az with a time limit; returns @{ ExitCode; StdOut; StdErr; TimedOut }.
# A request can hang on the network without ever returning (no response, no
# error - seen during the first Azure test runs), so the whole process tree is
# stopped when the limit is reached.
function Invoke-AzWithTimeout {
    param([int]$TimeoutSeconds, [string[]]$Arguments)
    $az = (Get-Command az -CommandType Application | Select-Object -First 1).Source
    $psi = [System.Diagnostics.ProcessStartInfo]::new($az)
    foreach ($a in $Arguments) { $psi.ArgumentList.Add($a) }
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.UseShellExecute = $false
    $p = [System.Diagnostics.Process]::Start($psi)
    try {
        $stdout = $p.StandardOutput.ReadToEndAsync()
        $stderr = $p.StandardError.ReadToEndAsync()
        if (-not $p.WaitForExit($TimeoutSeconds * 1000)) {
            $p.Kill($true)
            $p.WaitForExit()
            return @{ ExitCode = -1; StdOut = ''; StdErr = "timed out after $TimeoutSeconds seconds"; TimedOut = $true }
        }
        $p.WaitForExit()
        return @{ ExitCode = $p.ExitCode; StdOut = $stdout.Result; StdErr = $stderr.Result; TimedOut = $false }
    }
    finally { $p.Dispose() }
}

function Invoke-CtfRetry {
    param([int]$Attempts, [int]$DelaySeconds, [scriptblock]$Action)
    for ($i = 1; $i -le $Attempts; $i++) {
        try { if (& $Action) { return $true } } catch { if ($i -eq $Attempts) { throw } }
        if ($i -lt $Attempts) { Start-Sleep -Seconds $DelaySeconds }
    }
    return $false
}

function Get-CtfSha1Prefix([string]$Text, [int]$Length = 6) {
    $sha = [System.Security.Cryptography.SHA1]::Create()
    try {
        $bytes = $sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($Text))
        return (($bytes | ForEach-Object { $_.ToString('x2') }) -join '').Substring(0, $Length)
    }
    finally { $sha.Dispose() }
}

function Get-CtfChallengeDir([string]$Id) {
    $dir = Get-ChildItem -Directory -Path (Join-Path $script:Ctf.StateDir 'challenges') -Filter "$Id-*" | Select-Object -First 1
    if (-not $dir) { throw "Unknown challenge '$Id'. Valid IDs: $($script:AllChallenges -join ' ')" }
    return $dir.FullName
}

function Test-CtfSelected([string]$Id) { return $script:Ctf.Challenges -contains $Id }

function Initialize-CtfLab {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateSet('begin', 'end')][string]$State,
        [Parameter(Mandatory)][string]$RepoRoot,
        [Parameter(Mandatory)][string]$ResourceGroup,
        [string[]]$Challenges = @('all'),
        # Empty: the resource group's region when it exists, otherwise westus3 (resolved by Test-CtfPrerequisites).
        [string]$Location = '',
        [string]$ClusterName,
        [bool]$Reset = $false,
        [bool]$SkipInfra = $false,
        [string]$ModelName = 'gpt-6-luna',
        [string]$ModelVersion = '2026-09-22',
        [string]$DeploymentName = 'store-assistant',
        [int]$ModelCapacity = 50,
        # Empty: chosen when the Foundry account is created (Resolve-CtfAoaiLocation).
        [string]$AoaiLocation,
        # The folder with the state's challenges/<id>-*/manifests. Default: begin-challenge in the repository for the
        # begin state; another state (in another repository, for example) passes its own folder.
        [string]$StateDir
    )
    # The deployment name that C4's application starts with can't be the provisioned one.
    if ($DeploymentName -eq 'store-assistant-gpt41') { throw 'DeploymentName must not be store-assistant-gpt41 (the stale name challenge C4 starts with)' }
    if (-not $StateDir) {
        if ($State -ne 'begin') { throw "Pass -StateDir with the folder that has the $State state's challenges" }
        $StateDir = Join-Path $RepoRoot 'begin-challenge'
    }
    if (-not (Test-Path -LiteralPath (Join-Path $StateDir 'challenges'))) { throw "$StateDir has no challenges folder" }
    $location = ($Location -replace '\s', '').ToLowerInvariant()
    $script:Ctf = [ordered]@{
        State          = $State
        StateTitle     = if ($State -eq 'begin') { 'BEGIN state (challenges with their seeded faults)' } else { 'END state (challenges solved)' }
        RepoRoot       = (Resolve-Path $RepoRoot).Path
        StateDir       = (Resolve-Path -LiteralPath $StateDir).Path
        ResourceGroup  = $ResourceGroup
        ClusterName    = if ($ClusterName) { $ClusterName } else { 'aks-' + ($ResourceGroup -replace '^rg-', '') }
        Location       = $location
        AoaiLocation   = ($AoaiLocation -replace '\s', '').ToLowerInvariant()
        Reset          = $Reset
        SkipInfra      = $SkipInfra
        ModelName      = $ModelName
        ModelVersion   = $ModelVersion
        DeploymentName = $DeploymentName
        ModelCapacity  = $ModelCapacity
        Challenges     = @()
        NoExtDir       = $null
        Values         = @{}
    }
    $script:Ctf.KubeContext = $script:Ctf.ClusterName
    $ids = @($Challenges | ForEach-Object { $_ -split '[,\s]+' } | Where-Object { $_ } | ForEach-Object { $_.ToLowerInvariant() })
    if ($ids -contains 'all') { $ids = $script:AllChallenges }
    foreach ($id in $ids) { [void](Get-CtfChallengeDir $id) }
    if (-not $ids) { throw 'No challenges selected' }
    $script:Ctf.Challenges = @($script:AllChallenges | Where-Object { $ids -contains $_ })
}

function Get-CtfLabSettings { return $script:Ctf }

function Test-CtfPrerequisites {
    Write-CtfStep 'Checking prerequisites'
    foreach ($tool in 'az', 'kubectl', 'kubelogin') {
        if (-not (Get-Command $tool -ErrorAction SilentlyContinue)) {
            throw "'$tool' was not found on PATH. Install the Azure CLI, then run: az aks install-cli"
        }
    }
    if (-not (Test-AzCommand account show)) { throw 'Not signed in to Azure. Run: az login' }
    $azVersion = [version]((& az version -o json 2>$null | ConvertFrom-Json).'azure-cli')
    if ($azVersion -lt $script:MinAzVersion) { throw "Azure CLI $azVersion is too old; $($script:MinAzVersion) or later is required (az upgrade)" }
    $script:Ctf.SubscriptionId = Invoke-AzTsv account show --query id
    $script:Ctf.TenantId = Invoke-AzTsv account show --query tenantId
    Write-CtfInfo "Azure CLI $azVersion, subscription $(Invoke-AzTsv account show --query name) ($($script:Ctf.SubscriptionId))"
    if (Test-AzCommand extension show --name aks-preview) {
        $script:Ctf.NoExtDir = (New-Item -ItemType Directory -Path (Join-Path ([IO.Path]::GetTempPath()) "ctf-noext-$PID") -Force).FullName
        Write-CtfWarn 'aks-preview extension detected - az aks create/update will use the core (GA) Azure CLI commands'
    }
    # Without -Location, an existing resource group keeps its region: re-running a deployment (a challenge reset)
    # needs no options beyond the resource group and cluster.
    if (-not $script:Ctf.Location) {
        $groupLocation = Invoke-AzTsv group show -n $script:Ctf.ResourceGroup --query location
        $script:Ctf.Location = if ($groupLocation) { $groupLocation.ToLowerInvariant() } else { 'westus3' }
    }
    # Deterministic, globally unique names (same algorithm as the bash and Terraform deployments).
    $suffix = Get-CtfSha1Prefix "$($script:Ctf.SubscriptionId)/$($script:Ctf.ResourceGroup)"
    $script:Ctf.Suffix = $suffix
    $script:Ctf.AoaiAccount = "aoai-ctf-$suffix"
    $script:Ctf.KeyVaultName = "kv-ctf-$suffix"
    $script:Ctf.AiIdentityName = 'id-ctf-ai-service'
    $script:Ctf.ConfigIdentityName = 'id-ctf-config-reader'
    $script:Ctf.StorefrontDnsLabel = "ctf-store-$suffix"
    $script:Ctf.StorefrontHostname = "ctf-store-$suffix.$($script:Ctf.Location).cloudapp.azure.com"
    $script:Ctf.AmwName = "amw-ctf-$suffix"
    $script:Ctf.LawName = "law-ctf-$suffix"
    $script:Ctf.RenderDir = Join-Path $script:Ctf.RepoRoot ".lab/rendered/$($script:Ctf.ResourceGroup)"
    Write-CtfInfo "Resource group $($script:Ctf.ResourceGroup), cluster $($script:Ctf.ClusterName), region $($script:Ctf.Location)"
    Write-CtfInfo "Challenges ($($script:Ctf.State) state): $($script:Ctf.Challenges -join ' ')"
}
