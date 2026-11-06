<#
.SYNOPSIS
    KubeCon AKS capture-the-flag lab: removes the cloud subscription's service principal from the lab VM after the
    prepare life cycle action (LCA) ends.

.DESCRIPTION
    The prepare LCA (prepare-lab-environment.ps1) starts this script whenever it ends, however it ends, as SYSTEM,
    in the scheduled task "KubeCon CTF LCA cleanup". The worker (Invoke-CtfLabSetup.ps1) already removes the
    service principal at the end of its run, but the LCA's own PowerShell can write events until it exits, and an
    LCA can end without a worker run. So this script waits for the LCA's PowerShell to exit, and then:

      - clears the PowerShell event logs, which hold the LCA's text with the secret that Skillable put in it;
      - unless a prepare worker is running and needs them, deletes the service principal's Azure CLI profile and
        the secret in config.json, if they're still there;
      - checks that no event has the service principal's application ID, and adds a "Cloud credentials removed"
        line to the end of the setup log in the lab repository (.lab\skillable\begin-state-<time>.log), or to a log
        of its own there (cleanup-<time>.log) when no worker has run.

    It changes nothing else. In a manual run, or with RemoveCredentials set to Never, the LCA doesn't start it.
#>
#Requires -Version 7.4
[CmdletBinding()]
param(
    # The prepare LCA's PowerShell process, and its start time as a file time, so that a reused process ID doesn't count
    [int]$LauncherPid = 0,
    [long]$LauncherStart = 0,
    [string]$LcaDir = 'C:\ProgramData\kubecon-ctf-lca'
)
$ErrorActionPreference = 'Stop'
$StartedAt  = Get-Date
$EventLogs  = 'Microsoft-Windows-PowerShell/Operational', 'PowerShellCore/Operational', 'Windows PowerShell'
$AzureDir   = Join-Path $LcaDir 'azure-cli'
$ConfigPath = Join-Path $LcaDir 'config.json'
$StatePath  = Join-Path $LcaDir 'state-prepare.json'
$Stamp      = Get-Date -Format 'yyyyMMdd-HHmmss'
$LogPath    = Join-Path $LcaDir "cleanup-$Stamp.log"

function Read-Json([string]$Path) {
    try { if (Test-Path -LiteralPath $Path) { return (Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json) } } catch { }
    return $null
}

function Write-Log([string]$Text) {
    New-Item -ItemType Directory -Path $LcaDir -Force | Out-Null
    [IO.File]::AppendAllText($LogPath, ('{0:HH:mm:ss} {1}' -f (Get-Date), $Text) + "`r`n")
}

function Test-LauncherRunning {
    if (-not $LauncherPid) { return $false }
    $p = Get-Process -Id $LauncherPid -ErrorAction SilentlyContinue
    if (-not $p) { return $false }
    if (-not $LauncherStart) { return $true }
    try { return ($p.StartTime.ToFileTimeUtc() -eq $LauncherStart) } catch { return $true }
}

$cfg = Read-Json $ConfigPath
if ($cfg -and ($cfg.Manual -or [string]$cfg.RemoveCredentials -eq 'Never')) {
    Write-Log 'A manual run, or RemoveCredentials is Never: nothing to remove.'
    exit 0
}
Write-Log "KubeCon CTF LCA cleanup. Waits for the prepare LCA's process $LauncherPid to end."

# 1. Wait for the LCA's PowerShell to exit, so that its last events go too. An LCA that runs in another kind of process,
#    which doesn't end with it, gets a minute.
$launcher = if (Test-LauncherRunning) { Get-Process -Id $LauncherPid -ErrorAction SilentlyContinue } else { $null }
$minutes = if ($launcher -and $launcher.ProcessName -notin 'powershell', 'pwsh') { 1 } else { 15 }
$deadline = (Get-Date).AddMinutes($minutes)
while ((Test-LauncherRunning) -and (Get-Date) -lt $deadline) { Start-Sleep -Seconds 2 }
$waited = if (-not $LauncherPid) { 'no prepare LCA process to wait for' }
          elseif (Test-LauncherRunning) { "the prepare LCA's process $LauncherPid ($($launcher.ProcessName)) was still running after $minutes minute(s)" }
          else { "the prepare LCA's process $LauncherPid had ended" }

# 2. The service principal's Azure CLI profile and the secret in config.json, unless a prepare worker still needs them:
#    a running worker, or a new LCA attempt that wrote config.json after this script started
$left = [Collections.Generic.List[string]]::new()
$state = Read-Json $StatePath
$task = Get-ScheduledTask -TaskName 'KubeCon CTF LCA worker' -ErrorAction SilentlyContinue
$workerRunning = ($task -and [string]$task.State -eq 'Running') -or
                 ($state -and $state.status -eq 'Running' -and (Get-Process -Id ([int]$state.processId) -ErrorAction SilentlyContinue))
$newAttempt = (Test-Path -LiteralPath $ConfigPath) -and (Get-Item -LiteralPath $ConfigPath).LastWriteTime -gt $StartedAt
$kept = ''
if ($workerRunning -or $newAttempt) {
    $kept = ' A prepare worker is running and keeps the service principal''s Azure CLI profile: it deletes it when it ends.'
} else {
    for ($i = 1; $i -le 3 -and (Test-Path -LiteralPath $AzureDir); $i++) {
        Remove-Item -LiteralPath $AzureDir -Recurse -Force -ErrorAction SilentlyContinue
        if (Test-Path -LiteralPath $AzureDir) { Start-Sleep -Seconds 2 }
    }
    if (Test-Path -LiteralPath $AzureDir) { $left.Add($AzureDir) }
    $cfg = Read-Json $ConfigPath
    if ($cfg -and $cfg.ClientSecret) {
        $cfg.ClientSecret = ''
        [IO.File]::WriteAllText($ConfigPath, (ConvertTo-Json -InputObject $cfg -Depth 5), [Text.UTF8Encoding]::new($false))
    }
    if ((Read-Json $ConfigPath).ClientSecret) { $left.Add("the secret in $ConfigPath") }
}

# 3. The PowerShell event logs. Windows PowerShell logs the text of scripts that it finds suspicious (event 4104), such as
#    the prepare LCA with its secret, and any user can read those logs.
foreach ($log in $EventLogs) {
    & wevtutil.exe gl $log *> $null
    if ($LASTEXITCODE -ne 0) { continue }
    & wevtutil.exe cl $log *> $null
    if ($LASTEXITCODE -ne 0) { $left.Add("the $log event log, which couldn't be cleared") }
}
$cfg = Read-Json $ConfigPath
$clientId = if ($cfg) { [string]$cfg.ClientId } else { '' }
if ($clientId -and $clientId -notmatch '^@\s*lab\.') {
    foreach ($log in $EventLogs) {
        $found = @(Get-WinEvent -LogName $log -ErrorAction SilentlyContinue | Where-Object { $_.ToXml() -match [regex]::Escape($clientId) }).Count
        if ($found) { $left.Add("$found events in the $log event log with the service principal's application ID") }
    }
}

# 4. The result, at the end of the setup log in the lab repository, where an instructor can open it in VS Code
$result = if ($left.Count -eq 0) { 'PASS' } else { 'FAIL' }
$detail = if ($left.Count -gt 0) { "Still in the VM: $($left -join '; ') ($waited). Don't give this VM to an attendee." }
          elseif ($kept) { "Cleared the PowerShell event logs ($waited).$kept" }
          else { "Cleared the PowerShell event logs, and no service principal sign-in or secret is left in the VM ($waited)." }
$line = '{0:HH:mm:ss} {1}  Cloud credentials removed, after the prepare LCA ended: {2}' -f (Get-Date), $result, $detail
Write-Log "$result  Cloud credentials removed, after the prepare LCA ended: $detail"
$copy = if ($state -and $state.setupLog -and (Test-Path -LiteralPath $state.setupLog)) { [string]$state.setupLog } else { '' }
if (-not $copy) {
    try {
        $dir = Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) '.lab\skillable'
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        $copy = Join-Path $dir "cleanup-$Stamp.log"
    } catch { $copy = '' }
}
if ($copy) { try { [IO.File]::AppendAllText($copy, $line + "`r`n") } catch { } }
exit [int]($left.Count -gt 0)
