<#
.SYNOPSIS
    KubeCon AKS capture-the-flag lab: readiness gate life cycle action (LCA).

.DESCRIPTION
    Runs the readiness gate against the environment that prepare-lab-environment.ps1 built in this VM,
    and then removes the cloud subscription's service principal from the VM, because the attendee gets
    the VM next: it deletes the prepare LCA's Azure CLI profile, and clears the PowerShell event logs,
    which hold the prepare LCA's text with the secret that Skillable put in it. It removes them even if
    the gate fails. It changes nothing else, and it has no secure tokens, so a lab developer can save it.

      Action: Execute Script in Virtual Machine      Language: PowerShell
      Event: Running Preinstance Assigned To User    Blocking: Yes    Timeout: 20 minutes    Retries: 0
      Error action: Notify user, with a message such as
        "Your lab environment isn't ready. Ask a proctor for another lab."

    Results: C:\ProgramData\kubecon-ctf-lca (state-verify.json and the newest verify-*.log), and a copy
    of the log in .lab\skillable in the lab folder. skillable\lca\LCA-RUNBOOK.md has the details.
#>
$ErrorActionPreference = 'Stop'
$config = 'C:\ProgramData\kubecon-ctf-lca\config.json'
$pwsh = 'C:\Program Files\PowerShell\7\pwsh.exe'
if (-not (Test-Path -LiteralPath $config)) { throw 'KubeCon CTF readiness gate failed. The prepare life cycle action has not run in this VM.' }
$worker = Join-Path (Get-Content -LiteralPath $config -Raw | ConvertFrom-Json).LabRoot 'skillable\lca\Invoke-CtfLabSetup.ps1'
$saved = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
& $pwsh -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $worker -Mode Verify -ConfigPath $config -LaunchedAt (Get-Date).ToString('o') | Out-Null
$code = $LASTEXITCODE
$ErrorActionPreference = $saved
$state = Get-Content -LiteralPath 'C:\ProgramData\kubecon-ctf-lca\state-verify.json' -Raw -ErrorAction SilentlyContinue | ConvertFrom-Json
$end = "Summary for troubleshooting: $($state.setupLog)"
if ($code -ne 0 -or -not $state -or $state.status -eq 'Failed') { throw "KubeCon CTF readiness gate failed. $($state.message) $end" }
Write-Output "KubeCon CTF readiness gate passed. $($state.message) $end"
