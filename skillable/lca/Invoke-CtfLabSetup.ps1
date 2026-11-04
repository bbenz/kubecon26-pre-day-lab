<#
.SYNOPSIS
    KubeCon AKS capture-the-flag lab: the Skillable life cycle action (LCA) worker.

.DESCRIPTION
    Builds and checks one attendee's lab environment. Two short LCA scripts in this folder run it:

      prepare-lab-environment.ps1  First Displayable. Clones the lab repository at RepoRef into
                                   C:\ProgramData\kubecon-ctf-lca\repo, copies this script next to it, saves
                                   the settings and the cloud subscription's service principal to config.json,
                                   and runs this script with -Mode Prepare as SYSTEM, in a scheduled task.
      readiness-gate.ps1           Running Preinstance Assigned To User. Runs it with -Mode Verify.

    Prepare  Builds the attendee folder, C:\lab-resources, from the clone with
             skillable/build-attendee-content.ps1: the challenges' instructions without the solutions, and
             the scripts that check and reset them. Then it deletes the clone, so the VM never has the
             solutions. It signs in as the service principal in its own Azure CLI profile, registers the
             lab's resource providers, and deploys the BEGIN state of the selected challenges with the
             attendee folder's begin-challenge/azure-cli-powershell/deploy.ps1, the same script that people
             run by hand, and that the attendee's reset.ps1 runs. Then it gives the cloud portal user its
             roles, sets up the lab user's Azure CLI for browser sign-in, optionally installs the Inspektor
             Gadget cluster extension, and runs the readiness gate. deploy.ps1 writes the lab user's
             kubeconfig (KUBECONFIG points at it).
    Verify   Runs the readiness gate, and then removes the service principal from the VM: it deletes
             the service principal's Azure CLI profile, and clears the PowerShell event logs, which
             hold the prepare LCA's text with the secret.

    With Manual set in config.json (the prepare LCA's Manual setting), Prepare runs in the current
    window as the signed-in Azure CLI user instead of the service principal, for testing.

    Logs and state are in C:\ProgramData\kubecon-ctf-lca. A copy of each log, ending with a summary,
    goes to setup-logs in the attendee folder, where a proctor can open it in VS Code.
    LCA-RUNBOOK.md in this folder has the details.
#>
#Requires -Version 7.4
[CmdletBinding()]
param(
    [ValidateSet('Prepare', 'Verify')]
    [string]$Mode = 'Prepare',
    [string]$ConfigPath = 'C:\ProgramData\kubecon-ctf-lca\config.json',
    # When the LCA started (ISO 8601), for the total elapsed time
    [string]$LaunchedAt = ''
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$PSNativeCommandUseErrorActionPreference = $false

$Cfg = Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json
$Secret = [string]$Cfg.ClientSecret
if ($Secret) {
    # Keep the secret in memory only.
    $Cfg.ClientSecret = ''
    [IO.File]::WriteAllText($ConfigPath, (ConvertTo-Json -InputObject $Cfg -Depth 5), [Text.UTF8Encoding]::new($false))
}
$Manual       = [bool]$Cfg.Manual
$LcaDir       = Split-Path -Parent (Resolve-Path -LiteralPath $ConfigPath).Path
# The attendee folder, and the prepare LCA's clone of the lab repository that it's built from. The clone only
# exists until the Attendee files step: in Verify mode, the scripts come from the attendee folder.
$LabResources = if ([string]$Cfg.LabResources) { [string]$Cfg.LabResources } else { 'C:\lab-resources' }
$CloneDir     = [string]$Cfg.CloneDir
$HasClone     = [bool]$CloneDir -and (Test-Path -LiteralPath (Join-Path $CloneDir 'skillable\build-attendee-content.ps1'))
$CodeRoot     = if ($HasClone) { $CloneDir } else { $LabResources }
# Images built with an earlier version of the image setup script have a clone of the repository here.
$OldRepoClone = 'C:\LabFiles\kubecon26-pre-day-lab'
$RG           = [string]$Cfg.ResourceGroup
$Cluster      = [string]$Cfg.ClusterName
$LabAzureDir  = Join-Path $Cfg.LabProfile '.azure'
$Kubeconfig   = Join-Path $Cfg.LabProfile '.kube\config'
$AzureDir     = if ($Manual) { $LabAzureDir } else { Join-Path $LcaDir 'azure-cli' }
$AzPython     = 'C:\Program Files\Microsoft SDKs\Azure\CLI2\python.exe'
$K8sDir       = 'C:\Program Files\Kubernetes'
$KubectlExe   = Join-Path $K8sDir 'kubectl.exe'
$StatePath    = Join-Path $LcaDir "state-$($Mode.ToLowerInvariant()).json"
$Stamp        = Get-Date -Format 'yyyyMMdd-HHmmss'
$LogPath      = Join-Path $LcaDir "$($Mode.ToLowerInvariant())-$Stamp.log"
$CopyPath     = ''
$Steps        = [Collections.Generic.List[object]]::new()
$Checks       = [Collections.Generic.List[object]]::new()
$Lab          = [ordered]@{ resourceGroup = $RG; clusterName = $Cluster; portalUser = [string]$Cfg.PortalUser }
$Providers    = 'Microsoft.ContainerService', 'Microsoft.Compute', 'Microsoft.Network', 'Microsoft.ManagedIdentity',
                'Microsoft.PolicyInsights', 'Microsoft.CognitiveServices', 'Microsoft.KeyVault', 'Microsoft.Monitor',
                'Microsoft.Insights', 'Microsoft.OperationalInsights', 'Microsoft.AlertsManagement', 'Microsoft.Dashboard',
                'Microsoft.Storage', 'Microsoft.KubernetesConfiguration'
$EventLogs    = 'Microsoft-Windows-PowerShell/Operational', 'PowerShellCore/Operational', 'Windows PowerShell'
$Transient    = '(?i)InternalError|ServiceUnavailable|TooManyRequests|Timeout|connection (refused|reset)|Unable to connect|' +
                'unexpected EOF|i/o timeout|TLS handshake|failed calling webhook'
$CredentialsRemoved = $false
$RunStart = [DateTimeOffset]::Now
if ($LaunchedAt) { try { $RunStart = [DateTimeOffset]::Parse($LaunchedAt, [Globalization.CultureInfo]::InvariantCulture) } catch { } }

$env:AZURE_CONFIG_DIR = $AzureDir
$env:KUBECONFIG = $Kubeconfig
$env:AZURE_CORE_COLLECT_TELEMETRY = 'false'
$env:Path = [Environment]::GetEnvironmentVariable('Path', 'Machine') + ';' + [Environment]::GetEnvironmentVariable('Path', 'User')
# A failure here mustn't stop a readiness gate before it removes the credentials: Initialize-Context reports it.
$ModuleError = ''
$AllChallenges = @()
$Namespaces = @{}
try {
    Import-Module (Join-Path $CodeRoot 'shared\azure-cli-powershell\CtfLab.psm1') -Force
    $AllChallenges = & (Get-Module CtfLab) { $script:AllChallenges }
    $Namespaces = & (Get-Module CtfLab) { $script:Namespaces }
} catch {
    $ModuleError = "Can't load the lab's PowerShell module from ${CodeRoot}: $($_.Exception.Message)"
}
$Selected = @(([string]$Cfg.Challenges -split '[,\s]+') | Where-Object { $_ } | ForEach-Object { $_.ToLowerInvariant() })
if (-not $Selected -or $Selected -contains 'all') { $Selected = $AllChallenges }

# ---------------------------------------------------------------------------------------------
# Logging, state, and tools
# ---------------------------------------------------------------------------------------------
try {
    $copyDir = Join-Path $LabResources 'setup-logs'
    New-Item -ItemType Directory -Path $copyDir -Force | Out-Null
    $CopyPath = Join-Path $copyDir ('{0}-{1}.log' -f $(if ($Mode -eq 'Verify') { 'readiness-gate' } else { 'begin-state' }), $Stamp)
} catch { $CopyPath = '' }

function Write-Log([string]$Text) {
    $line = '{0:HH:mm:ss} {1}' -f (Get-Date), $Text
    [IO.File]::AppendAllText($LogPath, $line + "`r`n")
    if ($script:CopyPath) { try { [IO.File]::AppendAllText($script:CopyPath, $line + "`r`n") } catch { $script:CopyPath = '' } }
    if ($Manual) { Write-Host $line }
}

function Limit-Text([string]$Text, [int]$Max = 600) {
    $flat = ($Text -replace '\s+', ' ').Trim()
    if ($flat.Length -le $Max) { return $flat }
    return $flat.Substring(0, $Max) + ' ...'
}

function Test-Resolved($Value) { $t = [string]$Value; return ($t.Length -gt 0 -and $t -notmatch '^@\s*lab\.') }

function Format-Elapsed([TimeSpan]$Span) {
    $m = [int][Math]::Floor($Span.TotalMinutes)
    return ('{0} minute{1} {2} second{3}' -f $m, $(if ($m -eq 1) { '' } else { 's' }), $Span.Seconds, $(if ($Span.Seconds -eq 1) { '' } else { 's' }))
}

function Save-State([string]$Status, [string]$Message) {
    $state = [ordered]@{
        mode = $Mode; status = $Status; message = $Message; processId = $PID
        startedAt = $RunStart.ToString('o'); updatedAt = (Get-Date).ToString('o')
        elapsed = (Format-Elapsed ([DateTimeOffset]::Now - $RunStart)); log = $LogPath; setupLog = $CopyPath
        repoCommit = [string]$Cfg.RepoCommit; signature = [string]$Cfg.Signature; lab = $Lab; steps = $Steps; checks = $Checks
    }
    [IO.File]::WriteAllText($StatePath, (ConvertTo-Json -InputObject $state -Depth 6), [Text.UTF8Encoding]::new($false))
}

function Invoke-Step([string]$Name, [scriptblock]$Action, [switch]$Optional) {
    Write-Log "==> $Name"
    $started = Get-Date
    try {
        $detail = [string](& $Action | Select-Object -Last 1)
        $Steps.Add([pscustomobject]@{ step = $Name; result = 'READY'; seconds = [int]((Get-Date) - $started).TotalSeconds; detail = $detail })
        Write-Log "READY: $Name. $detail"
    } catch {
        $message = $_.Exception.Message
        $result = if ($Optional) { 'WARN' } else { 'FAIL' }
        $Steps.Add([pscustomobject]@{ step = $Name; result = $result; seconds = [int]((Get-Date) - $started).TotalSeconds; detail = $message })
        Write-Log "${result}: $Name. $message"
        if (-not $Optional) { throw "$Name failed. $message" }
    }
    Save-State 'Running' "Finished: $Name"
}

function Invoke-Az([string[]]$Arguments, [switch]$AllowFailure) {
    # Runs the Azure CLI's Python directly: faster than az.cmd, and no cmd.exe quoting rules.
    $errFile = [IO.Path]::GetTempFileName()
    try {
        $out = & $AzPython -IBm azure.cli @Arguments --only-show-errors 2>$errFile
        $code = $LASTEXITCODE
        $err = ([IO.File]::ReadAllText($errFile)).Trim()
    } finally { Remove-Item -LiteralPath $errFile -Force -ErrorAction SilentlyContinue }
    if ($code -ne 0 -and -not $AllowFailure) {
        throw "az $(($Arguments | Select-Object -First 3) -join ' ') failed (exit code $code). $(Limit-Text $err)"
    }
    return [pscustomobject]@{ ExitCode = $code; Out = ((@($out) -join "`n").Trim()); Err = $err }
}

function Get-AzValue([string[]]$Arguments) {
    $r = Invoke-Az ($Arguments + @('-o', 'tsv')) -AllowFailure
    if ($r.ExitCode -eq 0) { return $r.Out } else { return '' }
}

function Get-AzJson([string[]]$Arguments) {
    $r = Invoke-Az ($Arguments + @('-o', 'json')) -AllowFailure
    if ($r.ExitCode -eq 0 -and $r.Out) { return ($r.Out | ConvertFrom-Json -Depth 20) } else { return $null }
}

function Invoke-Kubectl([string[]]$Arguments, [switch]$AllowFailure) {
    # Errors from the cluster that usually pass, such as a slow Azure RBAC webhook, get two more tries.
    for ($try = 1; ; $try++) {
        $errFile = [IO.Path]::GetTempFileName()
        try {
            $out = & $KubectlExe @Arguments 2>$errFile
            $code = $LASTEXITCODE
            $err = ([IO.File]::ReadAllText($errFile)).Trim()
        } finally { Remove-Item -LiteralPath $errFile -Force -ErrorAction SilentlyContinue }
        if ($code -eq 0 -or $try -ge 3 -or $err -notmatch $Transient) { break }
        Write-Log "  kubectl $($Arguments[0]) failed on try $try of 3, retrying: $(Limit-Text $err 200)"
        Start-Sleep -Seconds (15 * $try)
    }
    if ($code -ne 0 -and -not $AllowFailure) { throw "kubectl $(($Arguments | Select-Object -First 2) -join ' ') failed. $(Limit-Text $err)" }
    return [pscustomobject]@{ ExitCode = $code; Out = ((@($out) -join "`n").Trim()); Err = $err }
}

function Get-KubeJson([string[]]$Arguments) {
    $r = Invoke-Kubectl ($Arguments + @('-o', 'json')) -AllowFailure
    if ($r.ExitCode -ne 0) { throw "kubectl $($Arguments -join ' ') failed. $(Limit-Text $r.Err 300)" }
    return ($r.Out | ConvertFrom-Json -Depth 50)
}

function Get-TokenObjectId {
    # The signed-in identity's object ID, from its own access token: no Microsoft Graph permission needed.
    $payload = ((Get-AzValue @('account', 'get-access-token', '--query', 'accessToken')) -split '\.')[1]
    if (-not $payload) { return '' }
    $payload = $payload.Replace('-', '+').Replace('_', '/')
    switch ($payload.Length % 4) { 2 { $payload += '==' } 3 { $payload += '=' } }
    return [string]([Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($payload)) | ConvertFrom-Json).oid
}

function Set-RoleAssignment([string]$PrincipalId, [string]$Type, [string]$Role, [string]$Scope) {
    for ($try = 1; ; $try++) {
        $r = Invoke-Az @('role', 'assignment', 'create', '--assignee-object-id', $PrincipalId, '--assignee-principal-type', $Type,
                         '--role', $Role, '--scope', $Scope, '-o', 'none') -AllowFailure
        if ($r.ExitCode -eq 0 -or $r.Err -match 'already exists|RoleAssignmentExists|Conflict') { return }
        if ($try -ge 6) { throw "Couldn't assign '$Role' on $Scope. $(Limit-Text $r.Err 300)" }
        Start-Sleep -Seconds 15
    }
}

function Test-RoleAssignment([string]$PrincipalId, [string]$Role, [string]$Scope) {
    $found = Get-AzValue @('role', 'assignment', 'list', '--scope', $Scope, '--include-inherited', '--fill-principal-name', 'false',
                           '--query', "length([?principalId=='$PrincipalId' && roleDefinitionName=='$Role'])")
    return ([int]("0$found") -gt 0)
}

# ---------------------------------------------------------------------------------------------
# Prepare steps
# ---------------------------------------------------------------------------------------------
function Initialize-Context {
    if ($ModuleError) { throw $ModuleError }
    foreach ($name in 'ResourceGroup', 'TenantId', 'SubscriptionId', 'ClusterName') {
        if (-not (Test-Resolved $Cfg.$name)) { throw "$name has no value. Check the prepare LCA's settings and its CLOUD CREDENTIALS section." }
    }
    if (-not $Manual -and -not (Test-Resolved $Cfg.ClientId)) { throw 'ClientId has no value. A pool admin turns on the CLOUD CREDENTIALS section.' }
    if ($Mode -eq 'Prepare' -and -not $Manual -and -not $Secret) { throw 'ClientSecret has no value. A pool admin turns on the CLOUD CREDENTIALS section.' }
    if ([string]$Cfg.RemoveCredentials -notin 'AfterGate', 'AfterPrepare', 'Never') {
        throw "RemoveCredentials is '$($Cfg.RemoveCredentials)'. Use AfterGate, AfterPrepare, or Never."
    }
    foreach ($tool in $AzPython, $KubectlExe, (Join-Path $K8sDir 'kubelogin.exe')) {
        if (-not (Test-Path -LiteralPath $tool)) { throw "$tool is missing. Build the VM image with skillable\vm-image\kubecon-ctf-vm-image-setup.ps1." }
    }
    if (-not (Test-Path -LiteralPath $Cfg.LabProfile)) { throw "The lab user's profile folder $($Cfg.LabProfile) doesn't exist." }
    New-Item -ItemType Directory -Path $AzureDir, (Split-Path -Parent $Kubeconfig) -Force | Out-Null
    $who = [Security.Principal.WindowsIdentity]::GetCurrent().Name
    $how = if ($Manual) { 'Manual run, with your own Azure CLI sign-in' } else { 'Life cycle action' }
    return "$how. Runs as $who. Lab user $($Cfg.LabUser) ($($Cfg.LabProfile)). Repository commit $($Cfg.RepoCommit)."
}

function Remove-RepositoryCopy {
    # Only the prepare LCA's own clone, in its protected folder: never a repository that someone works in.
    $removed = [Collections.Generic.List[string]]::new()
    if ($CloneDir -and $CloneDir.StartsWith("$LcaDir\", [StringComparison]::OrdinalIgnoreCase) -and (Test-Path -LiteralPath $CloneDir)) {
        Remove-Item -LiteralPath $CloneDir -Recurse -Force
        $removed.Add($CloneDir)
    }
    if (-not $Manual -and (Test-Path -LiteralPath (Join-Path $OldRepoClone 'begin-challenge'))) {
        Remove-Item -LiteralPath $OldRepoClone -Recurse -Force
        $removed.Add($OldRepoClone)
    }
    return $removed
}

function Install-AttendeeFiles {
    # What attendees need, without the solutions, from the clone; then the clone goes. A run without a clone, such
    # as a proctor's rerun of the copy of this script, uses the attendee folder that's already there.
    if ($HasClone) {
        & (Join-Path $CloneDir 'skillable\build-attendee-content.ps1') -Destination $LabResources 6>&1 | ForEach-Object { Write-Log "  | $_" }
        if (-not $Manual -and (Test-Resolved $Cfg.LabUser)) {
            # C:\ usually lets every signed-in user change new folders. Make sure the attendee can, for reset.ps1.
            $grant = & icacls.exe $LabResources /grant "$($Cfg.LabUser):(OI)(CI)M" /Q 2>&1
            if ($LASTEXITCODE -ne 0) { Write-Log "  Couldn't give $($Cfg.LabUser) Modify on ${LabResources}: $grant" }
        }
        $built = "Built $LabResources from the repository at $($Cfg.RepoCommit)"
    } elseif (Test-Path -LiteralPath (Join-Path $LabResources 'begin-challenge\azure-cli-powershell\deploy.ps1')) {
        $built = "Reused $LabResources (no clone of the repository in this run)"
    } else {
        throw "There's no clone of the lab repository in $CloneDir, and no attendee folder in $LabResources. Run the prepare LCA again."
    }
    $removed = @(Remove-RepositoryCopy)
    $note = if ($removed) { " Deleted $($removed -join ' and ')." } else { '' }
    return "$built, without the solutions.$note"
}

function Connect-Azure {
    if ($Manual) {
        $account = Get-AzJson @('account', 'show')
        if (-not $account -or $account.user.type -ne 'user') { throw 'Sign in to the Azure CLI with your lab account (az login), and run this again.' }
        Invoke-Az @('account', 'set', '--subscription', $Cfg.SubscriptionId) | Out-Null
        return "Signed in as $($account.user.name), your own Azure CLI sign-in, to subscription $($Cfg.SubscriptionId)"
    }
    # The worker's own profile: the lab user's profile never gets the service principal.
    Invoke-Az @('config', 'set', 'core.encrypt_token_cache=false', 'core.login_experience_v2=off', 'core.collect_telemetry=false',
                'core.survey_message=false', 'auto-upgrade.enable=no') | Out-Null
    $deadline = (Get-Date).AddMinutes(5)
    while ($true) {
        $r = Invoke-Az @('login', '--service-principal', '--username', $Cfg.ClientId, "--password=$Secret", '--tenant', $Cfg.TenantId,
                         '--allow-no-subscriptions', '-o', 'none') -AllowFailure
        if ($r.ExitCode -eq 0) { $r = Invoke-Az @('account', 'set', '--subscription', $Cfg.SubscriptionId) -AllowFailure }
        if ($r.ExitCode -eq 0) { break }
        if ((Get-Date) -gt $deadline) { throw "The service principal couldn't sign in and see the subscription within 5 minutes. Last error: $(Limit-Text $r.Err 300)" }
        Start-Sleep -Seconds 20
    }
    return "Signed in as the cloud subscription's service principal $($Cfg.ClientId) to subscription $($Cfg.SubscriptionId)"
}

function Initialize-ResourceGroup {
    $groupLocation = Get-AzValue @('group', 'show', '--name', $RG, '--query', 'location')
    if (-not $groupLocation) { throw "Can't read resource group $RG. Check the ResourceGroup token and the identity's role." }
    $script:Location = if (Test-Resolved $Cfg.Location) { ([string]$Cfg.Location -replace '\s', '').ToLowerInvariant() } else { $groupLocation }
    $Lab.location = $Location
    return "Resource group $RG in $groupLocation. The lab's resources go to $Location."
}

function Register-Providers {
    $states = @{}
    foreach ($p in @(Get-AzJson @('provider', 'list', '--query', '[].{n:namespace, s:registrationState}'))) { if ($p) { $states[$p.n] = $p.s } }
    if ($states.Count -eq 0) { throw "Can't read the subscription's resource providers, so the deployment finds out if one isn't registered." }
    $missing = @($Providers | Where-Object { $states[$_] -ne 'Registered' })
    foreach ($namespace in $missing) { Invoke-Az @('provider', 'register', '--namespace', $namespace) -AllowFailure | Out-Null }
    $deadline = (Get-Date).AddMinutes(10)
    $pending = $missing
    while ($pending.Count -gt 0 -and (Get-Date) -lt $deadline) {
        Start-Sleep -Seconds 15
        $pending = @($pending | Where-Object { (Get-AzValue @('provider', 'show', '--namespace', $_, '--query', 'registrationState')) -ne 'Registered' })
    }
    if ($pending.Count -gt 0) { throw "Not registered after 10 minutes: $($pending -join ', ')." }
    if ($missing.Count -gt 0) { return "Registered $($missing -join ', ')" }
    return 'The resource providers were already registered'
}

function Invoke-BeginState {
    # reset.ps1 in the attendee folder reads these settings, and deploys a challenge again with the same deploy.ps1.
    $settings = [ordered]@{
        resourceGroup = $RG; clusterName = $Cluster; location = $Location; subscriptionId = [string]$Cfg.SubscriptionId
        tenantId = [string]$Cfg.TenantId; portalUser = [string]$Cfg.PortalUser; repoCommit = [string]$Cfg.RepoCommit
    }
    [IO.File]::WriteAllText((Join-Path $LabResources 'lab-settings.json'), (ConvertTo-Json -InputObject $settings), [Text.UTF8Encoding]::new($false))
    $deploy = Join-Path $LabResources 'begin-challenge\azure-cli-powershell\deploy.ps1'
    $pwsh = (Get-Process -Id $PID).Path
    $arguments = @('-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', $deploy, '-ResourceGroup', $RG,
                   '-Location', $Location, '-ClusterName', $Cluster, '-Challenges', ($Selected -join ','))
    Write-Log "  deploy.ps1 -ResourceGroup $RG -Location $Location -ClusterName $Cluster -Challenges $($Selected -join ',')"
    & $pwsh @arguments 2>&1 | ForEach-Object { Write-Log "  | $_" }
    if ($LASTEXITCODE -ne 0) { throw "deploy.ps1 failed with exit code $LASTEXITCODE. The log lines above have its output." }
    return "Begin state deployed: cluster $Cluster, challenges $($Selected -join ' '). kubeconfig: $Kubeconfig"
}

function Resolve-PortalUser {
    if ($Manual) { return (Get-TokenObjectId) }
    $id = ''
    if (Test-Resolved $Cfg.PortalUser) { $id = Get-AzValue @('ad', 'user', 'show', '--id', $Cfg.PortalUser, '--query', 'id') }
    foreach ($inherited in @($false, $true)) {
        if ($id) { break }
        # Skillable gives the portal user a role on the resource group. A service principal without Microsoft Graph
        # permissions can't look the user up by name, so use the only user with a role there.
        $query = @('role', 'assignment', 'list', '--resource-group', $RG, '--fill-principal-name', 'false', '--query', "[?principalType=='User'].principalId")
        if ($inherited) { $query += '--include-inherited' }
        $users = @(Get-AzJson $query | Select-Object -Unique)
        if ($users.Count -eq 1) { $id = [string]$users[0] }
    }
    if (-not $id) { throw "Couldn't find the object ID of the portal user $($Cfg.PortalUser). Check PortalUser in the prepare LCA's settings." }
    return $id
}

function Grant-PortalUser {
    $id = Resolve-PortalUser
    $Lab.portalUserId = $id
    $rgId = Get-AzValue @('group', 'show', '--name', $RG, '--query', 'id')
    $roles = [Collections.Generic.List[object]]::new()
    # kubectl on AKS Automatic (local accounts are off; Owner or Contributor isn't enough), and the A2 Prometheus dashboards
    $roles.Add(@{ Role = 'Azure Kubernetes Service RBAC Cluster Admin'; Scope = $rgId })
    $roles.Add(@{ Role = 'Monitoring Data Reader'; Scope = $rgId })
    if ($Selected -contains 'a4') {
        # A4's fix updates a federated credential, in case the portal user's Skillable role doesn't allow it
        $identity = Get-AzValue @('identity', 'show', '--resource-group', $RG, '--name', 'id-ctf-config-reader', '--query', 'id')
        if ($identity) { $roles.Add(@{ Role = 'Managed Identity Contributor'; Scope = $identity }) }
    }
    foreach ($r in $roles) { Set-RoleAssignment $id 'User' $r.Role $r.Scope }
    return "Portal user $($Cfg.PortalUser) ($id): $(($roles | ForEach-Object { $_.Role }) -join ', ')"
}

function Set-AttendeeCli {
    if ($Manual) { return 'Manual run: your Azure CLI sign-in stays as it is' }
    # Browser sign-in reuses the attendee's Azure portal session in Edge. A service principal sign-in in the
    # lab user's profile is removed: the attendee must never get it.
    $saved = $env:AZURE_CONFIG_DIR
    $removed = ''
    try {
        $env:AZURE_CONFIG_DIR = $LabAzureDir
        Invoke-Az @('config', 'set', 'core.enable_broker_on_windows=false', 'core.login_experience_v2=off',
                    'core.collect_telemetry=false', 'core.survey_message=false', 'auto-upgrade.enable=no') | Out-Null
        $account = Get-AzJson @('account', 'show')
        if ($account -and $account.user.type -ne 'user') {
            Invoke-Az @('account', 'clear') | Out-Null
            $removed = " Removed a $($account.user.type) sign-in ($($account.user.name))."
        }
    } finally { $env:AZURE_CONFIG_DIR = $saved }
    return "The lab user's Azure CLI uses browser sign-in and isn't signed in.$removed The attendee runs az login."
}

function Install-InspektorGadget {
    # The AKS cluster extension (preview) is how Microsoft supports Inspektor Gadget on AKS. A1 offers it as optional
    # evidence. On AKS Automatic, its DaemonSet can't place pods on the AKS-managed hosted system nodes (an AKS policy
    # denies pinning workloads to them), and a full node leaves its pod Pending, so the DaemonSet never reports every
    # pod ready, and the extension can stay in Creating. Don't wait for that: wait for gadget pods on the lab's nodes.
    if (-not (Get-AzValue @('extension', 'show', '--name', 'k8s-extension', '--query', 'version'))) {
        Invoke-Az @('extension', 'add', '--name', 'k8s-extension', '--yes') | Out-Null
    }
    $common = @('--cluster-type', 'managedClusters', '--cluster-name', $Cluster, '--resource-group', $RG, '--name', 'inspektor-gadget')
    if (-not (Get-AzValue (@('k8s-extension', 'show') + $common + @('--query', 'provisioningState')))) {
        Invoke-Az (@('k8s-extension', 'create') + $common + @('--extension-type', 'microsoft.inspektorgadget', '--release-train', 'preview', '--no-wait', '-o', 'none')) | Out-Null
    }
    $deadline = (Get-Date).AddMinutes(4)
    while ($true) {
        $ds = Invoke-Kubectl @('get', 'daemonset', 'gadget', '--namespace', 'gadget', '-o', 'jsonpath={.status.numberReady}/{.status.desiredNumberScheduled}') -AllowFailure
        if ($ds.ExitCode -eq 0 -and $ds.Out -match '^([1-9]\d*)/') { break }
        if ((Get-Date) -gt $deadline) { throw "No Inspektor Gadget pod is ready after 4 minutes ($(if ($ds.Out) { $ds.Out } else { 'no DaemonSet yet' }))." }
        Start-Sleep -Seconds 20
    }
    return "Inspektor Gadget cluster extension requested; $($ds.Out) gadget pods ready (none run on AKS-managed hosted system nodes)"
}

# ---------------------------------------------------------------------------------------------
# Readiness gate, and removing the service principal from the VM
# ---------------------------------------------------------------------------------------------
function Add-Check([string]$Name, [bool]$Passed, [string]$Detail, [string]$Severity = 'FAIL') {
    $Checks.Add([pscustomobject]@{ check = $Name; result = $(if ($Passed) { 'PASS' } else { $Severity }); detail = $Detail })
}

function Find-SolutionContent {
    # The attendee mustn't find the solutions: no clone of the repository, SOLUTION.md, or end state.
    $found = [Collections.Generic.List[string]]::new()
    if ($CloneDir -and (Test-Path -LiteralPath $CloneDir)) { $found.Add($CloneDir) }
    foreach ($root in $LabResources, 'C:\LabFiles', $LcaDir) {
        if (-not (Test-Path -LiteralPath $root)) { continue }
        foreach ($item in Get-ChildItem -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue) {
            if (($item.PSIsContainer -and $item.Name -in 'challenge-end-state', '.git') -or (-not $item.PSIsContainer -and $item.Name -eq 'SOLUTION.md')) {
                $found.Add($item.FullName)
            }
        }
    }
    return $found
}

function Invoke-Check([string]$Name, [string]$Severity, [scriptblock]$Test) {
    try {
        $r = & $Test
        Add-Check $Name ([bool]$r.Ok) ([string]$r.Detail) $Severity
    } catch {
        Add-Check $Name $false $_.Exception.Message $Severity
    }
}

function Test-Readiness {
    Write-Log '==> Readiness gate'
    $rgId = Get-AzValue @('group', 'show', '--name', $RG, '--query', 'id')
    Invoke-Check 'Azure sign-in' 'FAIL' {
        $a = Get-AzJson @('account', 'show')
        @{ Ok = ($a -and $a.id -eq $Cfg.SubscriptionId)
           Detail = $(if ($a) { "$($a.user.type) $($a.user.name), subscription $($a.id)" } else { "The worker's Azure CLI profile isn't signed in" }) }
    }
    Invoke-Check 'Cluster' 'FAIL' {
        # AKS Automatic can be Updating for its own background operations, which doesn't stop the lab.
        $c = Get-AzJson @('aks', 'show', '--resource-group', $RG, '--name', $Cluster, '--query',
                          '{state:provisioningState, power:powerState.code, version:currentKubernetesVersion, sku:sku.name}')
        @{ Ok = ($c -and $c.state -notin 'Failed', 'Canceled', 'Deleting' -and $c.power -eq 'Running')
           Detail = $(if ($c) { "$Cluster ($($c.sku), Kubernetes $($c.version)): $($c.state), $($c.power)" } else { "$Cluster not found" }) }
    }
    Invoke-Check 'Nodes' 'FAIL' {
        $nodes = @((Get-KubeJson @('get', 'nodes')).items)
        $ready = @($nodes | Where-Object { @($_.status.conditions | Where-Object { $_.type -eq 'Ready' -and $_.status -eq 'True' }).Count -gt 0 })
        @{ Ok = ($ready.Count -ge 1); Detail = "$($ready.Count) of $($nodes.Count) nodes Ready" }
    }
    Invoke-Check 'Challenge namespaces' 'FAIL' {
        $names = @((Get-KubeJson @('get', 'namespaces')).items | ForEach-Object { $_.metadata.name })
        $missing = @($Selected | Where-Object { $names -notcontains $Namespaces[$_] } | ForEach-Object { $Namespaces[$_] })
        @{ Ok = ($missing.Count -eq 0); Detail = $(if ($missing) { "Missing: $($missing -join ', ')" } else { "All $($Selected.Count) challenge namespaces" }) }
    }
    Invoke-Check 'Challenge workloads' 'FAIL' {
        $pods = @((Get-KubeJson @('get', 'pods', '--all-namespaces')).items)
        $empty = @($Selected | Where-Object { $ns = $Namespaces[$_]; @($pods | Where-Object { $_.metadata.namespace -eq $ns }).Count -eq 0 } |
                   ForEach-Object { $Namespaces[$_] })
        @{ Ok = ($empty.Count -eq 0)
           Detail = $(if ($empty) { "No pods in: $($empty -join ', ')" } else { 'Every challenge namespace has pods (some fail on purpose: they are the challenges)' }) }
    }
    $portalId = [string]$Lab.portalUserId
    if ($Manual -and -not $portalId) { $portalId = Get-TokenObjectId }
    Invoke-Check 'Portal user access' 'FAIL' {
        @{ Ok = ($portalId -and (Test-RoleAssignment $portalId 'Azure Kubernetes Service RBAC Cluster Admin' $rgId))
           Detail = "Azure Kubernetes Service RBAC Cluster Admin on $RG for $($Cfg.PortalUser) ($portalId)" }
    }
    Invoke-Check 'Portal user monitoring access' 'WARN' {
        @{ Ok = ($portalId -and (Test-RoleAssignment $portalId 'Monitoring Data Reader' $rgId))
           Detail = "Monitoring Data Reader on $RG, for the A2 dashboards with Grafana" }
    }
    Invoke-Check 'kubeconfig' 'FAIL' {
        $exists = Test-Path -LiteralPath $Kubeconfig
        $context = if ($exists) { (Invoke-Kubectl @('config', 'current-context') -AllowFailure).Out } else { '' }
        $azurecli = $exists -and (Select-String -LiteralPath $Kubeconfig -Pattern 'azurecli' -Quiet)
        @{ Ok = ($context -eq $Cluster -and $azurecli); Detail = "$Kubeconfig, current context '$context', kubelogin azurecli mode: $azurecli" }
    }
    if (-not $Manual) {
        Invoke-Check 'Attendee Azure CLI' 'FAIL' {
            $saved = $env:AZURE_CONFIG_DIR
            try { $env:AZURE_CONFIG_DIR = $LabAzureDir; $a = Get-AzJson @('account', 'show') } finally { $env:AZURE_CONFIG_DIR = $saved }
            $config = Join-Path $LabAzureDir 'config'
            $browser = (Test-Path -LiteralPath $config) -and (Select-String -LiteralPath $config -Pattern 'enable_broker_on_windows\s*=\s*false' -Quiet)
            @{ Ok = (-not $a -and $browser); Detail = "Signed in: $(if ($a) { "$($a.user.type) $($a.user.name)" } else { 'no' }). Browser sign-in: $browser." }
        }
    }
    if ($Cfg.InspektorGadget) {
        Invoke-Check 'Inspektor Gadget' 'WARN' {
            $ds = Get-KubeJson @('get', 'daemonset', 'gadget', '--namespace', 'gadget')
            @{ Ok = ($ds.status.numberReady -ge 1)
               Detail = "DaemonSet gadget: $($ds.status.numberReady) of $($ds.status.desiredNumberScheduled) pods ready (none run on AKS-managed hosted system nodes)" }
        }
    }
    Invoke-Check 'Lab tools' 'WARN' {
        $tools = @((Join-Path $K8sDir 'kubectl.exe'), (Join-Path $K8sDir 'kubelogin.exe'), (Join-Path $K8sDir 'helm.exe'),
                   (Join-Path $K8sDir 'kubectl-gadget.exe'), (Join-Path $K8sDir 'aks-mcp.exe'), (Join-Path $K8sDir 'ingress2gateway.exe'),
                   'C:\Program Files\PowerShell\7\pwsh.exe', 'C:\Program Files\GitHub CLI\gh.exe', 'C:\Program Files\Git\bin\bash.exe',
                   'C:\Program Files\Microsoft VS Code\Code.exe', (Join-Path $LabAzureDir 'cliextensions\aks-agent'))
        $missing = @($tools | Where-Object { -not (Test-Path -LiteralPath $_) })
        $azVersion = [version](Get-AzJson @('version')).'azure-cli'
        @{ Ok = ($missing.Count -eq 0 -and $azVersion -ge [version]'2.86.0')
           Detail = "Azure CLI $azVersion. $(if ($missing) { "Missing: $($missing -join ', ')" } else { 'All lab tools are present.' })" }
    }
    Invoke-Check 'Attendee files' 'FAIL' {
        $required = @('README.md', 'check.ps1', 'reset.ps1', 'lab-settings.json', 'begin-challenge\azure-cli-powershell\deploy.ps1',
                      'scoring\verify.ps1', 'shared\azure-cli-powershell\CtfLab.psm1', ".lab\rendered\$RG") +
                    @($Selected | ForEach-Object { "begin-challenge\challenges\$_-*\README.md" })
        $missing = @($required | Where-Object { -not (Test-Path -Path (Join-Path $LabResources $_)) })
        @{ Ok = ($missing.Count -eq 0)
           Detail = $(if ($missing) { "Missing in ${LabResources}: $($missing -join ', ')" }
                      else { "$LabResources has the instructions of $($Selected.Count) challenges, check.ps1, and reset.ps1" }) }
    }
    Invoke-Check 'No solutions on the VM' 'FAIL' {
        $found = @(Find-SolutionContent)
        @{ Ok = ($found.Count -eq 0)
           Detail = $(if ($found) { "Found $($found.Count): $(($found | Select-Object -First 5) -join '; ')" }
                      else { "No repository clone, SOLUTION.md, or end state in $LabResources, C:\LabFiles, or $LcaDir" }) }
    }
    foreach ($c in $Checks) { Write-Log ('  {0,-5} {1,-30} {2}' -f $c.result, $c.check, $c.detail) }
    return @($Checks | Where-Object { $_.result -eq 'FAIL' }).Count
}

function Remove-CloudCredential {
    # The attendee gets the VM next. Delete the service principal's Azure CLI profile, and clear the PowerShell event
    # logs: Windows PowerShell logs the text of scripts that it finds suspicious (event 4104), such as the prepare LCA
    # with the secret that Skillable put in it, and any user can read those logs.
    $script:CredentialsRemoved = $true
    $left = [Collections.Generic.List[string]]::new()
    if (-not $Manual) {
        for ($i = 1; $i -le 3 -and (Test-Path -LiteralPath $AzureDir); $i++) {
            Remove-Item -LiteralPath $AzureDir -Recurse -Force -ErrorAction SilentlyContinue
            if (Test-Path -LiteralPath $AzureDir) { Start-Sleep -Seconds 2 }
        }
        if (Test-Path -LiteralPath $AzureDir) { $left.Add($AzureDir) }
    }
    foreach ($log in $EventLogs) {
        & wevtutil.exe gl $log *> $null
        if ($LASTEXITCODE -ne 0) { continue }
        & wevtutil.exe cl $log *> $null
        if ($LASTEXITCODE -ne 0) { $left.Add("the $log event log, which couldn't be cleared") }
    }
    if (Test-Resolved $Cfg.ClientId) {
        foreach ($log in $EventLogs) {
            $found = @(Get-WinEvent -LogName $log -ErrorAction SilentlyContinue | Where-Object { $_.ToXml() -match [regex]::Escape([string]$Cfg.ClientId) }).Count
            if ($found) { $left.Add("$found events in the $log event log with the service principal's application ID") }
        }
    }
    $detail = if ($left.Count -eq 0) { "Deleted $AzureDir and cleared the PowerShell event logs" }
              else { "Still in the VM: $($left -join '; '). Don't give this VM to an attendee." }
    Add-Check 'Cloud credentials removed' ($left.Count -eq 0) $detail
    Write-Log "Cloud credentials removed: $detail"
    return [int]($left.Count -gt 0)
}

function Test-RemoveCredentials([int]$Failures) {
    if ($Manual) { return $false }
    switch ([string]$Cfg.RemoveCredentials) {
        'AfterGate'    { return ($Mode -eq 'Verify') }
        'AfterPrepare' { return ($Mode -eq 'Verify' -or ($Failures -eq 0 -and @($Steps | Where-Object { $_.result -ne 'READY' }).Count -eq 0)) }
    }
    return $false
}

function Wait-ForPrepare {
    # The readiness gate waits up to 15 minutes for a prepare worker that's still running.
    $prepareState = Join-Path $LcaDir 'state-prepare.json'
    if (-not (Test-Path -LiteralPath $prepareState)) { throw 'The prepare LCA has not run in this VM.' }
    $deadline = (Get-Date).AddMinutes(15)
    while ($true) {
        $p = Get-Content -LiteralPath $prepareState -Raw | ConvertFrom-Json
        $running = $p.status -eq 'Running' -and (Get-Process -Id ([int]$p.processId) -ErrorAction SilentlyContinue)
        if (-not $running) { break }
        if ((Get-Date) -gt $deadline) { throw 'The prepare worker is still running after 15 minutes. Run the readiness gate again when it finishes.' }
        Start-Sleep -Seconds 20
    }
    foreach ($property in $p.lab.PSObject.Properties) { $Lab[$property.Name] = $property.Value }
    return "Prepare result: $($p.status). $($p.message)"
}

function Write-Summary([string]$Status, [string]$Message) {
    $lines = [Collections.Generic.List[string]]::new()
    $lines.Add('==================== Summary ====================')
    $lines.Add("Result: $Status. $Message")
    $lines.Add("Started $($RunStart.LocalDateTime.ToString('yyyy-MM-dd HH:mm:ss')), finished $((Get-Date).ToString('yyyy-MM-dd HH:mm:ss')). " +
               "Total elapsed time: $(Format-Elapsed ([DateTimeOffset]::Now - $RunStart)).")
    foreach ($s in @($Steps | Where-Object { $_.result -ne 'READY' })) { $lines.Add("Step $($s.result): $($s.step). $($s.detail)") }
    foreach ($c in @($Checks | Where-Object { $_.result -ne 'PASS' })) { $lines.Add("Check $($c.result): $($c.check). $($c.detail)") }
    $lines.Add("Full log: $LogPath")
    foreach ($line in $lines) { Write-Log $line }
}

# ---------------------------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------------------------
if ($Mode -eq 'Prepare' -and (Test-Path -LiteralPath $StatePath)) {
    $previous = Get-Content -LiteralPath $StatePath -Raw | ConvertFrom-Json
    if ($previous.status -eq 'Running' -and $previous.processId -ne $PID -and (Get-Process -Id ([int]$previous.processId) -ErrorAction SilentlyContinue)) {
        Write-Log 'Another prepare worker is already running, so this one exits.'
        exit 0
    }
}
$status = 'Failed'
$message = ''
try {
    Write-Log "KubeCon CTF lab LCA worker. Mode: $Mode. Resource group: $RG. Cluster: $Cluster."
    Save-State 'Running' 'Starting'
    if ($Mode -eq 'Prepare') {
        Invoke-Step 'Context' { Initialize-Context }
        Invoke-Step 'Attendee files' { Install-AttendeeFiles }
        Invoke-Step 'Azure sign-in' { Connect-Azure }
        Invoke-Step 'Resource group' { Initialize-ResourceGroup }
        Invoke-Step 'Resource providers' { Register-Providers } -Optional
        Invoke-Step 'Begin state (deploy.ps1)' { Invoke-BeginState }
        Invoke-Step 'Portal user access' { Grant-PortalUser } -Optional
        Invoke-Step 'Attendee Azure CLI' { Set-AttendeeCli } -Optional
        if ($Cfg.InspektorGadget) { Invoke-Step 'Inspektor Gadget' { Install-InspektorGadget } -Optional }
    } else {
        Invoke-Step 'Prepare result' { Wait-ForPrepare }
        Invoke-Step 'Context' { Initialize-Context }
        # The prepare worker deletes its clone. If a run stopped before that, delete it before the attendee gets the VM.
        Invoke-Step 'Repository clone' {
            $removed = @(Remove-RepositoryCopy)
            if ($removed) { "Deleted $($removed -join ' and ')" } else { 'No clone of the lab repository in the VM' }
        }
    }
    $failures = Test-Readiness
    if (Test-RemoveCredentials $failures) { $failures += Remove-CloudCredential }
    $warnings = @($Steps | Where-Object { $_.result -eq 'WARN' } | ForEach-Object { $_.step })
    $failedChecks = @($Checks | Where-Object { $_.result -eq 'FAIL' } | ForEach-Object { $_.check })
    $message = if ($failures -gt 0) { "Readiness gate: $failures failed ($($failedChecks -join ', '))." } else { 'Readiness gate passed.' }
    if ($warnings) { $message += " Steps with warnings: $($warnings -join ', ')." }
    $status = if ($failures -gt 0 -and ($Mode -eq 'Verify' -or $Cfg.GateFailsPrepare)) { 'Failed' }
              elseif ($failures -gt 0 -or $warnings) { 'Incomplete' } else { 'Succeeded' }
} catch {
    $status = 'Failed'
    $message = $_.Exception.Message
    Write-Log "STOPPED: $message"
} finally {
    # The VM must never keep the clone, which has the solutions, even if a step stopped early.
    try { Remove-RepositoryCopy | Out-Null } catch { Write-Log "Couldn't delete the repository clone. $($_.Exception.Message)" }
    # The attendee gets the VM next, so a readiness gate that stops early still removes the credentials.
    if ($Mode -eq 'Verify' -and -not $Manual -and -not $CredentialsRemoved -and [string]$Cfg.RemoveCredentials -ne 'Never') {
        try { Remove-CloudCredential | Out-Null } catch { Write-Log "Couldn't remove the cloud credentials. $($_.Exception.Message)" }
    }
    Save-State $status $message
    Write-Summary $status $message
}
if ($status -eq 'Failed') { exit 1 }
exit 0
