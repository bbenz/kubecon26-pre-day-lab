<#
.SYNOPSIS
    KubeCon AKS capture-the-flag lab: readiness gate life cycle action (LCA).

.DESCRIPTION
    Runs the readiness gate against the environment that prepare-lab-environment.ps1 built in this VM,
    and then removes the cloud subscription's service principal from the VM, because the attendee gets
    the VM next: it deletes the prepare LCA's Azure CLI profile, and clears the PowerShell event logs,
    which hold the prepare LCA's text with the secret that Skillable put in it. It removes them even if
    the gate fails, or if the prepare LCA stopped before its worker ran. It changes nothing else, and it
    has no secure tokens, so a lab developer can save it.

      Action: Execute Script in Virtual Machine      Language: PowerShell
      Event: Running Preinstance Assigned To User    Blocking: Yes    Timeout: 20 minutes    Retries: 0
      Error action: Notify user, with a message such as
        "Your lab environment isn't ready. Ask a proctor for another lab."

    Results: C:\ProgramData\kubecon-ctf-lca (state-verify.json and the newest verify-*.log), and a copy
    of the log in .lab\skillable in the lab repository. The lab team's LCA runbook has the details.
#>
$lca = 'C:\ProgramData\kubecon-ctf-lca'
$pwsh = 'C:\Program Files\PowerShell\7\pwsh.exe'
$config = Get-Content -LiteralPath (Join-Path $lca 'config.json') -Raw -ErrorAction SilentlyContinue | ConvertFrom-Json
$worker = if ($config.LabRoot) { Join-Path $config.LabRoot 'skillable\lca\Invoke-CtfLabSetup.ps1' } else { '' }
$state = $null
$code = 1
# Windows PowerShell 5.1 turns a native tool's stderr into errors when ErrorActionPreference is Stop.
$ErrorActionPreference = 'Continue'
if ($worker -and (Test-Path -LiteralPath $worker)) {
    & $pwsh -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $worker -Mode Verify -LaunchedAt (Get-Date).ToString('o') | Out-Null
    $code = $LASTEXITCODE
    $state = Get-Content -LiteralPath (Join-Path $lca 'state-verify.json') -Raw -ErrorAction SilentlyContinue | ConvertFrom-Json
}
$removed = $state -and @($state.checks | Where-Object { $_.check -eq 'Cloud credentials removed' -and $_.result -eq 'PASS' }).Count -gt 0
$keep = $config.RemoveCredentials -eq 'Never'
if (-not $removed -and -not $keep) {
    # The worker didn't run, or didn't finish: remove the service principal's profile and the PowerShell event logs here.
    Remove-Item -LiteralPath (Join-Path $lca 'azure-cli') -Recurse -Force -ErrorAction SilentlyContinue
    foreach ($log in 'Microsoft-Windows-PowerShell/Operational', 'PowerShellCore/Operational', 'Windows PowerShell') { & wevtutil.exe cl $log 2>$null }
}
if (-not $state) { throw 'KubeCon CTF readiness gate failed. The prepare life cycle action did not finish in this VM.' }
$end = "Summary for troubleshooting: $($state.setupLog)"
if ($code -ne 0 -or $state.status -eq 'Failed') { throw "KubeCon CTF readiness gate failed. $($state.message) $end" }
Write-Output "KubeCon CTF readiness gate passed. $($state.message) $end"
