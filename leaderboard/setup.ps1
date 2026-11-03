<#
.SYNOPSIS
    KubeCon AKS capture-the-flag lab - create (or refresh) the event leaderboard and the create-only token
    that lab VMs use to record results.

.DESCRIPTION
    Creates, in its own resource group:
      * a storage account with anonymous access and account keys disabled, HTTPS/TLS 1.2 only, and a
        lifecycle rule that deletes results -RetentionDays after they were recorded;
      * a container for the event's results;
      * "Storage Blob Data Contributor" on the account for you (to create the container, sign tokens and
        read the results for the leaderboard).
    Then it issues a create-only token (a user delegation SAS signed with your Microsoft Entra ID, valid for
    at most 7 days) and tests it. Re-run the script to issue a fresh token - for example the day before the
    event - and update the Skillable life cycle action with it.

    Written to .lab/leaderboard/ (ignored by git - never commit the token):
      settings.env                storage account and container (read by board.* and cleanup.*)
      submit-url.txt              the submit URL, token included
      skillable-lca-windows.ps1   Skillable life cycle action for a Windows lab VM, token included
      skillable-lca-linux.sh      the same for a Linux lab VM
    See leaderboard/README.md.

.EXAMPLE
    ./leaderboard/setup.ps1
.EXAMPLE
    ./leaderboard/setup.ps1 -ResourceGroup rg-ctf-leaderboard -Container kubecon-na-2026 -TokenHours 36
#>
#Requires -Version 7.4
[CmdletBinding()]
param(
    [string]$ResourceGroup = 'rg-kubecon-ctf-leaderboard',
    [string]$Location = 'westus3',
    # Default: ctflb + 8 hex characters derived from the subscription and resource group (globally unique).
    [string]$StorageAccount,
    # One container per event: 3-63 lowercase letters, digits and hyphens.
    [ValidatePattern('^[a-z0-9][a-z0-9-]{1,61}[a-z0-9]$')][string]$Container = 'ctf',
    # Token lifetime in hours (a user delegation SAS lasts at most 7 days).
    [ValidateRange(1, 168)][int]$TokenHours = 48,
    # Optional: only accept submissions from this IP address or range (a.b.c.d or a.b.c.d-e.f.g.h).
    [string]$AllowedIp,
    # Results are deleted automatically this many days after they were recorded.
    [ValidateRange(1, 365)][int]$RetentionDays = 14,
    # Also print the submit URL (it contains the token).
    [switch]$ShowToken
)
$ErrorActionPreference = 'Stop'
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$outDir = Join-Path $repoRoot '.lab/leaderboard'
$purpose = 'kubecon-ctf-leaderboard'

function Write-Step([string]$Message) { Write-Host ''; Write-Host "==> $Message" -ForegroundColor Cyan }
function Write-Info([string]$Message) { Write-Host "    $Message" }
function Write-Ok([string]$Message) { Write-Host '    ' -NoNewline; Write-Host 'OK' -ForegroundColor Green -NoNewline; Write-Host "  $Message" }
# az ...; throws with az's error output when it fails.
function Invoke-Az {
    $err = New-TemporaryFile
    try {
        $out = & az @args --only-show-errors 2>$err.FullName
        if ($LASTEXITCODE -ne 0) { throw "az $($args[0..2] -join ' ') failed:`n$((Get-Content -Raw $err.FullName) -replace '\s+$', '')" }
        return $out
    }
    finally { Remove-Item $err.FullName -ErrorAction SilentlyContinue }
}
# az ... -o none; $true when it succeeded.
function Test-Az { & az @args --only-show-errors -o none 2>$null | Out-Null; return ($LASTEXITCODE -eq 0) }

Write-Step 'Checking prerequisites'
if (-not (Get-Command az -ErrorAction SilentlyContinue)) { throw 'The Azure CLI (az) is required' }
if (-not (Test-Az account show)) { throw 'Not signed in to Azure. Run: az login' }
$subscriptionId = Invoke-Az account show --query id -o tsv
Write-Info "Subscription $(Invoke-Az account show --query name -o tsv) ($subscriptionId)"
if (-not $StorageAccount) {
    $hash = [Security.Cryptography.SHA1]::HashData([Text.Encoding]::UTF8.GetBytes("$subscriptionId/$ResourceGroup"))
    $StorageAccount = 'ctflb' + (($hash | ForEach-Object { $_.ToString('x2') }) -join '').Substring(0, 8)
}
if ($StorageAccount -notmatch '^[a-z0-9]{3,24}$') { throw "Storage account names are 3-24 lowercase letters and digits: $StorageAccount" }
if ((Invoke-Az account show --query user.type -o tsv) -eq 'user') {
    $principalId = Invoke-Az ad signed-in-user show --query id -o tsv; $principalType = 'User'
}
else {
    $principalId = Invoke-Az ad sp show --id (Invoke-Az account show --query user.name -o tsv) --query id -o tsv
    $principalType = 'ServicePrincipal'
}

Write-Step "Resource group $ResourceGroup"
Invoke-Az group create -n $ResourceGroup -l $Location --tags "purpose=$purpose" -o none | Out-Null
Write-Ok 'ready'

Write-Step "Storage account $StorageAccount (no anonymous access, no account keys, HTTPS/TLS 1.2 only)"
$secure = @('--allow-blob-public-access', 'false', '--allow-shared-key-access', 'false', '--min-tls-version', 'TLS1_2', '--https-only', 'true')
if (Test-Az storage account show -n $StorageAccount -g $ResourceGroup) {
    Invoke-Az storage account update -n $StorageAccount -g $ResourceGroup @secure -o none | Out-Null
    Write-Ok 'exists - security settings enforced'
}
else {
    try {
        Invoke-Az storage account create -n $StorageAccount -g $ResourceGroup -l $Location --sku Standard_LRS --kind StorageV2 `
            --tags "purpose=$purpose" @secure -o none | Out-Null
    }
    catch { throw "Could not create storage account $StorageAccount (names are global - pass -StorageAccount to choose another).`n$_" }
    Write-Ok 'created'
}
$accountId = Invoke-Az storage account show -n $StorageAccount -g $ResourceGroup --query id -o tsv
$policy = @{
    rules = @(@{
            enabled = $true; name = 'delete-results'; type = 'Lifecycle'
            definition = @{
                actions = @{ baseBlob = @{ delete = @{ daysAfterModificationGreaterThan = $RetentionDays } } }
                filters = @{ blobTypes = @('blockBlob') }
            }
        })
} | ConvertTo-Json -Depth 10
$policyFile = New-TemporaryFile
try {
    [IO.File]::WriteAllText($policyFile.FullName, $policy, [Text.UTF8Encoding]::new($false))
    Invoke-Az storage account management-policy create --account-name $StorageAccount -g $ResourceGroup --policy "@$($policyFile.FullName)" -o none | Out-Null
}
finally { Remove-Item $policyFile.FullName -ErrorAction SilentlyContinue }
Write-Ok "results are deleted automatically $RetentionDays days after they were recorded"

Write-Step 'Data access for you (Storage Blob Data Contributor on the storage account)'
$assigned = Invoke-Az role assignment list --assignee $principalId --role 'Storage Blob Data Contributor' --scope $accountId --query '[].id' -o tsv
if ($assigned) { Write-Ok 'already assigned' }
else {
    Invoke-Az role assignment create --assignee-object-id $principalId --assignee-principal-type $principalType `
        --role 'Storage Blob Data Contributor' --scope $accountId -o none | Out-Null
    Write-Ok 'assigned (it can take a few minutes to take effect)'
}

Write-Step "Container $Container"
$ready = $false
for ($i = 0; $i -lt 30 -and -not $ready; $i++) {
    if (Test-Az storage container create --account-name $StorageAccount -n $Container --auth-mode login) { $ready = $true }
    else { Start-Sleep -Seconds 10 }
}
if (-not $ready) { throw "Could not create container $Container - data access may still be propagating; re-run in a few minutes." }
Write-Ok 'ready'

Write-Step "Create-only token for the lab VMs (valid $TokenHours hours)"
$expiry = (Get-Date).ToUniversalTime().AddHours($TokenHours).ToString('yyyy-MM-ddTHH:mmZ')
$sasArgs = @('storage', 'container', 'generate-sas', '--account-name', $StorageAccount, '-n', $Container, '--permissions', 'c',
    '--expiry', $expiry, '--auth-mode', 'login', '--as-user', '--https-only', '-o', 'tsv')
if ($AllowedIp) { $sasArgs += @('--ip', $AllowedIp) }
$token = (Invoke-Az @sasArgs | Out-String).Trim()
if ($token -notmatch '(^|&)sig=') { throw 'Could not create the token' }
$submitUrl = 'https://{0}.blob.core.windows.net/{1}?{2}' -f $StorageAccount, $Container, $token
if ($AllowedIp) { Write-Info "Token test skipped: the token only accepts requests from $AllowedIp" }
else {
    $probe = 'https://{0}.blob.core.windows.net/{1}/health/setup-{2}.txt?{3}' -f $StorageAccount, $Container,
        (Get-Date).ToUniversalTime().ToString('yyyyMMddTHHmmssZ'), $token
    $status = 0
    for ($i = 0; $i -lt 18 -and $status -ne 201; $i++) {
        if ($i -gt 0) { Start-Sleep -Seconds 10 }
        $status = [int](Invoke-WebRequest -Method Put -Uri $probe -Headers @{ 'x-ms-blob-type' = 'BlockBlob' } -Body 'setup probe' `
                -SkipHttpErrorCheck -UseBasicParsing -TimeoutSec 15).StatusCode
    }
    if ($status -ne 201) { throw "The new token could not record a test entry (HTTP $status). Data access may still be propagating - re-run in a few minutes." }
    $read = [int](Invoke-WebRequest -Method Get -Uri $probe -SkipHttpErrorCheck -UseBasicParsing -TimeoutSec 15).StatusCode
    if ($read -ne 403) { throw "The token can read entries (HTTP $read) - expected a create-only token" }
    Write-Ok 'tested: it can record an entry and cannot read one'
}

Write-Step 'Writing .lab/leaderboard/ (ignored by git - never commit the token)'
New-Item -ItemType Directory -Force -Path $outDir | Out-Null
$utf8 = [Text.UTF8Encoding]::new($false)
$settings = @(
    '# Written by leaderboard/setup - read by leaderboard/board.* and leaderboard/cleanup.*'
    "LB_SUBSCRIPTION=$subscriptionId", "LB_RESOURCE_GROUP=$ResourceGroup", "LB_STORAGE_ACCOUNT=$StorageAccount"
    "LB_CONTAINER=$Container", "LB_TOKEN_EXPIRES=$expiry"
)
[IO.File]::WriteAllText((Join-Path $outDir 'settings.env'), ($settings -join "`n") + "`n", $utf8)
[IO.File]::WriteAllText((Join-Path $outDir 'submit-url.txt'), "$submitUrl`n", $utf8)
foreach ($t in @(@('lca-windows.ps1', 'skillable-lca-windows.ps1'), @('lca-linux.sh', 'skillable-lca-linux.sh'))) {
    $template = [IO.File]::ReadAllText((Join-Path $PSScriptRoot "skillable/$($t[0])"))
    [IO.File]::WriteAllText((Join-Path $outDir $t[1]), $template.Replace('__SUBMIT_URL__', $submitUrl), $utf8)
}
Write-Ok $outDir

Write-Step 'Leaderboard ready'
Write-Info "Storage account : $StorageAccount (resource group $ResourceGroup)"
Write-Info "Container       : $Container"
Write-Info "Token expires   : $expiry UTC - re-run this script to issue a new one"
Write-Info "Submit URL      : $(Join-Path $outDir 'submit-url.txt')"
if ($ShowToken) { Write-Info "                  $submitUrl" }
Write-Info ''
Write-Info 'Next:'
Write-Info "  Skillable   : add $(Join-Path $outDir 'skillable-lca-windows.ps1') as a life cycle action (leaderboard/README.md)"
Write-Info "  Try it      : ./leaderboard/join.ps1 -Name 'Your N.'   then   ./scoring/verify.ps1 -Challenges c1"
Write-Info '  Projector   : ./leaderboard/board.ps1'
Write-Info '  Kill switch : ./leaderboard/cleanup.ps1 -RevokeOnly    (invalidates every token at once)'
