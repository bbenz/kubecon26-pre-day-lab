<#
.SYNOPSIS
    KubeCon AKS capture-the-flag lab: prepare life cycle action (LCA). Builds the attendee's begin
    state (the challenges with their seeded faults) as the cloud subscription's service principal.

.DESCRIPTION
    Paste this whole script into a Skillable life cycle action. The lab team's LCA runbook has the
    steps:

      Action: Execute Script in Virtual Machine    Language: PowerShell
      Event: First Displayable                     Blocking: Yes    Delay: 60 seconds
      Timeout: 60 minutes                          Retries: 2
      Error action: End lab (event), or Log (testing)

    It's short on purpose: the lab repository's tested scripts do the work. The VM image has a shallow
    clone of the repository in LabRoot, which attendees use. This script moves it to RepoRef, and runs
    its skillable\lca\Invoke-CtfLabSetup.ps1 as SYSTEM in a scheduled task, so that a Skillable timeout
    can't stop it, and a retry waits for the same run. The worker deploys the begin state with the
    repository's begin-challenge\azure-cli-powershell\deploy.ps1, gives the cloud portal user its roles,
    sets up the lab user's kubeconfig and Azure CLI, and runs the readiness gate. The readiness gate LCA
    removes the service principal from the VM before the attendee gets it.

    Manual = $true runs the same steps in this window as you, the cloud portal user, with your own
    Azure CLI sign-in, to test before a pool admin turns on the cloud credentials.
#>

# =============================================================================================
# CLOUD CREDENTIALS, for a cloud subscription pool admin, such as SkillableEventSupport.
# This script deploys the lab as the cloud subscription's service principal. To turn its
# credentials on, change only the four lines inside @{ } below:
#   1. Delete the # at the start of each line.
#   2. Delete the space between the @ and lab in each line.
#   3. Save the script.
# Until then, this action stops at once with a message that points here.
# =============================================================================================
$CloudSubscription = @{
    # TenantId       = '@ lab.CloudSubscription.TenantId'
    # SubscriptionId = '@ lab.CloudSubscription.Id'
    # ClientId       = '@ lab.CloudSubscription.AppId'
    # ClientSecret   = '@ lab.CloudSubscription.AppSecret'
}

# =============================================================================================
# Settings. Skillable replaces the @lab tokens. Change ResourceGroup1 and User1 to the names in
# your lab profile. Change settings before a pool admin turns on the credentials above: after
# that, only a pool admin can save this script.
# =============================================================================================
$Settings = [ordered]@{
    ResourceGroup     = '@lab.CloudResourceGroup(ResourceGroup1).Name'
    PortalUser        = '@lab.CloudPortalCredential(User1).Username'
    Location          = ''                    # Empty: the resource group's region (set its Override Region)
    ClusterName       = 'aks-kubecon-ctf'
    Challenges        = 'all'                 # Or a list, such as 'c1,c2,c3,c4'
    InspektorGadget   = $false                # $true: Inspektor Gadget AKS cluster extension (preview), optional in A1
    RepoUrl           = 'https://github.com/bbenz/kubecon26-pre-day-lab'
    RepoRef           = 'main'                # A branch or tag: a tag for the event, such as v1.0.0
    LabRoot           = 'C:\LabFiles\kubecon26-pre-day-lab'   # The lab repository on the VM (the image has it)
    RemoveCredentials = 'AfterGate'           # AfterGate, AfterPrepare (no readiness gate LCA), or Never (testing)
    GateFailsPrepare  = $false                # $true for the event: a failed readiness gate fails this action
    WaitMinutes       = 50                    # Keep it 10 below the Timeout. The worker keeps running after that.
    Manual            = $false                # $true: run by hand as yourself (see the LCA runbook)
}

# =============================================================================================
# Launcher
# =============================================================================================
$ErrorActionPreference = 'Stop'
$LaunchedAt = (Get-Date).ToString('o')
try { Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass -Force } catch { }
$LcaDir     = 'C:\ProgramData\kubecon-ctf-lca'
$ConfigPath = Join-Path $LcaDir 'config.json'
$StatePath  = Join-Path $LcaDir 'state-prepare.json'
$TaskName   = 'KubeCon CTF LCA worker'
$Pwsh       = 'C:\Program Files\PowerShell\7\pwsh.exe'
$Git        = 'C:\Program Files\Git\cmd\git.exe'
$AzPython   = 'C:\Program Files\Microsoft SDKs\Azure\CLI2\python.exe'
$Root       = [string]$Settings.LabRoot
$Worker     = Join-Path $Root 'skillable\lca\Invoke-CtfLabSetup.ps1'
$Manual     = [bool]$Settings.Manual

function Test-Value($Value) { $t = [string]$Value; return ($t.Length -gt 0 -and $t -notmatch '^@\s*lab\.') }

function Read-State {
    if (Test-Path -LiteralPath $StatePath) { try { return (Get-Content -LiteralPath $StatePath -Raw | ConvertFrom-Json) } catch { } }
    return $null
}

function Invoke-Native([string]$File, [string[]]$Arguments) {
    # Windows PowerShell 5.1 turns a native tool's stderr into errors when ErrorActionPreference is Stop.
    $saved = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try { $out = & $File @Arguments 2>&1 } finally { $ErrorActionPreference = $saved }
    return [pscustomobject]@{ Code = $LASTEXITCODE; Text = ((@($out) | ForEach-Object { "$_" }) -join "`n").Trim() }
}

function Get-LabUser {
    # The user that Skillable signs in automatically: the owner of Explorer. A manual run uses you.
    if ($Manual) { return [pscustomobject]@{ Name = $env:USERNAME; Profile = $env:USERPROFILE } }
    $owners = @(Get-CimInstance -ClassName Win32_Process -Filter "Name='explorer.exe'" | ForEach-Object {
        $o = Invoke-CimMethod -InputObject $_ -MethodName GetOwner
        if ($o.ReturnValue -eq 0) { $o.User } } | Select-Object -Unique)
    if ($owners.Count -ne 1) { throw "Expected one signed-in user, found $($owners.Count). Check automatic sign-in in the VM image." }
    $sid = (New-Object Security.Principal.NTAccount($owners[0])).Translate([Security.Principal.SecurityIdentifier]).Value
    $profilePath = [string](Get-CimInstance -ClassName Win32_UserProfile -Filter "SID='$sid'").LocalPath
    return [pscustomobject]@{ Name = [string]$owners[0]; Profile = $profilePath }
}

function Update-Repository {
    # The VM image has a shallow clone of the repository. Move it to RepoRef; if GitHub can't be reached, keep the image's
    # copy. As SYSTEM: trust the lab user's folder, never prompt for credentials, and give up on a stalled download.
    $env:GIT_TERMINAL_PROMPT = '0'
    $options = @('-c', 'safe.directory=*', '-c', 'credential.helper=', '-c', 'http.lowSpeedLimit=1000', '-c', 'http.lowSpeedTime=60')
    if (-not (Test-Path -LiteralPath (Join-Path $Root '.git'))) {
        $clone = Invoke-Native $Git ($options + @('clone', '--quiet', '--depth', '1', '--branch', $Settings.RepoRef, $Settings.RepoUrl, $Root))
        if ($clone.Code -ne 0) { throw "$Root has no copy of the lab repository, and git clone failed: $($clone.Text)" }
    }
    $base = $options + @('-C', $Root)
    $fetch = Invoke-Native $Git ($base + @('fetch', '--quiet', '--force', '--depth', '1', $Settings.RepoUrl, $Settings.RepoRef))
    $note = "at $($Settings.RepoRef)"
    if ($fetch.Code -eq 0) {
        $checkout = Invoke-Native $Git ($base + @('checkout', '--quiet', '--force', '-B', 'lab', 'FETCH_HEAD'))
        if ($checkout.Code -ne 0) { throw "git checkout of $($Settings.RepoRef) failed: $($checkout.Text)" }
    } else {
        $note = "WARNING: couldn't fetch $($Settings.RepoRef), so the image's copy is used ($($fetch.Text))"
    }
    return "$((Invoke-Native $Git ($base + @('rev-parse', '--short', 'HEAD'))).Text) $note"
}
function Get-CredentialProblem {
    $section = 'the CLOUD CREDENTIALS section at the top of this script'
    if ($CloudSubscription.Count -eq 0) {
        return "$section is still commented out. A cloud subscription pool admin must turn it on, as its comments describe"
    }
    $problems = @(foreach ($name in 'TenantId', 'SubscriptionId', 'ClientId', 'ClientSecret') {
        $value = [string]$CloudSubscription[$name]
        if (-not $CloudSubscription.ContainsKey($name)) { "the $name line is still commented out" }
        elseif ($value -match '^@\s+lab\.') { "the $name token still has a space after the @" }
        elseif ($value -match '^@\s*lab\.') { "the $name token wasn't replaced (does the lab profile have a cloud subscription pool?)" }
        elseif (-not $value) { "$name is empty" }
    })
    if ($problems.Count -gt 0) { return "in $section, $($problems -join '; ')" }
    return ''
}

function Initialize-ManualRun {
    $principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { throw 'Run this script in PowerShell as administrator.' }
    $show = Invoke-Native $AzPython @('-IBm', 'azure.cli', 'account', 'show', '-o', 'json', '--only-show-errors')
    if ($show.Code -ne 0) {
        Write-Host 'Sign in to the Azure CLI with your lab account (the cloud portal user and its Temporary Access Pass).'
        $null = Invoke-Native $AzPython @('-IBm', 'azure.cli', 'config', 'set', 'core.enable_broker_on_windows=false', 'core.login_experience_v2=off')
        & $AzPython -IBm azure.cli login --output none
        $show = Invoke-Native $AzPython @('-IBm', 'azure.cli', 'account', 'show', '-o', 'json', '--only-show-errors')
    }
    if ($show.Code -ne 0) { throw "The Azure CLI isn't signed in. Run az login with your lab account, and run this script again." }
    $account = $show.Text | ConvertFrom-Json
    if ($account.user.type -ne 'user') { throw "The Azure CLI is signed in as $($account.user.type) $($account.user.name). Run az login with your lab account." }
    if (-not (Test-Value $Settings.ResourceGroup)) {
        $groups = @(((Invoke-Native $AzPython @('-IBm', 'azure.cli', 'group', 'list', '--query', '[].name', '-o', 'tsv')).Text -split "`r?`n") | Where-Object { $_ })
        if ($groups.Count -eq 0) { throw "Your lab account can't see a resource group in subscription $($account.name)." }
        $Settings.ResourceGroup = $groups[0]
        if ($groups.Count -gt 1) {
            for ($i = 0; $i -lt $groups.Count; $i++) { Write-Host "  $($i + 1). $($groups[$i])" }
            $choice = 0
            if (-not [int]::TryParse((Read-Host 'Number of the lab resource group'), [ref]$choice) -or $choice -lt 1 -or $choice -gt $groups.Count) { throw 'No resource group was chosen.' }
            $Settings.ResourceGroup = $groups[$choice - 1]
        }
    }
    $Settings.TenantId = [string]$account.tenantId
    $Settings.SubscriptionId = [string]$account.id
    $Settings.PortalUser = [string]$account.user.name
    $Settings.RemoveCredentials = 'Never'
}

# 1. Credentials, or your own sign-in in a manual run
if (-not (Test-Path -LiteralPath $Pwsh)) { throw "$Pwsh is missing. Build the VM image with skillable\vm-image\kubecon-ctf-vm-image-setup.ps1." }
if ($Manual) {
    Initialize-ManualRun
} else {
    $problem = Get-CredentialProblem
    if ($problem) { throw "KubeCon CTF prepare can't start: $problem. The LCA runbook has the details." }
    foreach ($name in 'TenantId', 'SubscriptionId', 'ClientId', 'ClientSecret') { $Settings[$name] = [string]$CloudSubscription[$name] }
}

# 2. Start the worker, or wait for the one that's already running
New-Item -ItemType Directory -Path $LcaDir -Force | Out-Null
$acl = Invoke-Native 'icacls.exe' @($LcaDir, '/inheritance:r', '/grant:r', '*S-1-5-18:(OI)(CI)F', '*S-1-5-32-544:(OI)(CI)F')
if ($acl.Code -ne 0) { throw "Couldn't restrict access to $LcaDir, so no settings were saved. $($acl.Text)" }
$state = Read-State
$running = $state -and $state.status -eq 'Running' -and (Get-Process -Id ([int]$state.processId) -ErrorAction SilentlyContinue)
if ($running -and $Manual) { throw 'The prepare LCA is still running in this VM. Wait for it to finish, and run this script again.' }
if ($running) {
    Write-Output "The prepare worker started at $($state.startedAt) is still running, so this run waits for it."
} else {
    $repo = Update-Repository
    $labUser = Get-LabUser
    $config = [ordered]@{}
    foreach ($key in $Settings.Keys) { $config[$key] = $Settings[$key] }
    $config.LabUser = $labUser.Name
    $config.LabProfile = $labUser.Profile
    $config.RepoCommit = $repo
    $sha = [Security.Cryptography.SHA256]::Create()
    $plain = (($config.Keys | Where-Object { $_ -ne 'ClientSecret' } | ForEach-Object { "$_=$($config[$_])" }) -join ';')
    $config.Signature = [BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($plain))).Replace('-', '')
    if (-not $Manual -and $state -and $state.status -eq 'Succeeded' -and $state.signature -eq $config.Signature) {
        Write-Output "KubeCon CTF lab is already prepared with these settings ($repo). Summary for troubleshooting: $($state.setupLog)"
        return
    }
    [IO.File]::WriteAllText($ConfigPath, ($config | ConvertTo-Json -Depth 4), (New-Object Text.UTF8Encoding($false)))
    Remove-Item -LiteralPath $StatePath -Force -ErrorAction SilentlyContinue
    $workerArgs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $Worker, '-Mode', 'Prepare', '-ConfigPath', $ConfigPath, '-LaunchedAt', $LaunchedAt)
    if ($Manual) {
        Write-Host "KubeCon CTF begin state, by hand: resource group $($Settings.ResourceGroup), as $($Settings.PortalUser). Repository $repo."
        Write-Host 'It takes 20 to 30 minutes. Logs: C:\ProgramData\kubecon-ctf-lca'
        & $Pwsh @workerArgs
    } else {
        $action = New-ScheduledTaskAction -Execute $Pwsh -Argument (($workerArgs | ForEach-Object { if ($_ -match '\s') { "`"$_`"" } else { $_ } }) -join ' ')
        $principal = New-ScheduledTaskPrincipal -UserId 'NT AUTHORITY\SYSTEM' -LogonType ServiceAccount -RunLevel Highest
        $taskSettings = New-ScheduledTaskSettingsSet -ExecutionTimeLimit (New-TimeSpan -Hours 3) -MultipleInstances IgnoreNew -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
        Register-ScheduledTask -TaskName $TaskName -Action $action -Principal $principal -Settings $taskSettings -Force | Out-Null
        Start-ScheduledTask -TaskName $TaskName
        Write-Output "Started the prepare worker ($repo)."
    }
}
# 3. Wait for the result
$deadline = (Get-Date).AddMinutes([int]$Settings.WaitMinutes)
while (-not $Manual) {
    $state = Read-State
    $alive = $state -and (Get-Process -Id ([int]$state.processId) -ErrorAction SilentlyContinue)
    if ($state -and ($state.status -ne 'Running' -or -not $alive)) { break }
    if (-not $state -and (Get-ScheduledTask -TaskName $TaskName).State -ne 'Running' -and (Get-Date) -gt ([datetime]$LaunchedAt).AddMinutes(2)) {
        throw "The KubeCon CTF prepare worker stopped before it wrote its state. Last task result: $((Get-ScheduledTaskInfo -TaskName $TaskName).LastTaskResult)."
    }
    if ((Get-Date) -gt $deadline) {
        throw "KubeCon CTF prepare is still running after $($Settings.WaitMinutes) minutes. The worker keeps running, and a retry waits for it. Log: $($state.log)"
    }
    Start-Sleep -Seconds 15
}
$state = Read-State
if ($state -and $state.status -eq 'Running') { $state.status = 'Failed'; $state.message = 'The worker stopped unexpectedly.' }
$cleaned = Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json
if ($cleaned.ClientSecret) { $cleaned.ClientSecret = ''; [IO.File]::WriteAllText($ConfigPath, ($cleaned | ConvertTo-Json -Depth 4), (New-Object Text.UTF8Encoding($false))) }
$end = "Summary for troubleshooting: $($state.setupLog) Total elapsed time: $($state.elapsed)."
switch ([string]$state.status) {
    'Succeeded'  { Write-Output "KubeCon CTF lab is ready. $($state.message) $end" }
    'Incomplete' { Write-Output "KubeCon CTF prepare finished, but the environment isn't complete. $($state.message) $end" }
    default      { throw "KubeCon CTF prepare failed. $($state.message) $end" }
}
