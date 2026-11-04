#Requires -Version 5.1
<#
.SYNOPSIS
    Builds the KubeCon AKS capture-the-flag lab VM image for Skillable.

.DESCRIPTION
    Installs and configures the Windows 11 lab VM. Modeled on the LAB723 (Ignite 2026) image script.

       1. Windows settings: no notification, tip, OneDrive, Teams, widget, or Copilot pop-ups; no automatic
          Windows or Microsoft Store updates; never sleeps or locks; en-US keyboard
       2. Git for Windows (Git Bash runs the lab's bash scripts), signature-verified
       3. PowerShell 7 (the lab's PowerShell scripts need 7.4 or later), checksum-verified
       4. Azure CLI at the current release, with the aks-agent and k8s-extension extensions; login experience
          v2, telemetry, survey prompts, and automatic upgrade off
       5. kubectl, kubelogin, Helm, Inspektor Gadget (kubectl gadget), ingress2gateway, and the AKS-MCP server,
          from their official release locations, checksum-verified, in C:\Program Files\Kubernetes on the PATH
       6. Terraform (the lab repository's third deployment approach), checksum-verified, update checks off
       7. GitHub CLI, checksum-verified, update notices off
       8. AKS desktop, signature-verified, installed for all users
       9. Visual Studio Code with GitHub Copilot, Kubernetes, AKS, YAML, PowerShell, WSL, and Terraform
          extensions; lab-friendly settings; AKS-MCP configured as a user MCP server for Copilot agent mode
      10. Microsoft Edge policies: no first-run, sync, default-browser, or password prompts; starts on the
          Azure portal; a KubeCon CTF favorites folder
      11. WSL with Ubuntu, a default user with passwordless sudo and no first-run prompts, and the Azure CLI,
          kubectl, kubelogin, Helm, and jq inside Ubuntu. WSL 2 when the VM exposes virtualization, WSL 1
          otherwise. Turning on the Windows features needs one restart: restart, then run the script again.
      12. The lab repository cloned to C:\LabFiles\kubecon26-pre-day-lab, and shortcuts that open VS Code on
          it and Edge on the Azure portal at sign-in

    Each item prints "READY:" when it's installed and verified, and the run ends with a verification
    table. The script is safe to run again: it skips or reapplies finished items.

    Sign-ins, the kubeconfig, and the cluster change per launch, so they aren't part of the image: the
    prepare life cycle action (skillable\lca) sets them up at each launch.

    Run it in an elevated Windows PowerShell window while you're signed in as the user that the lab
    signs in automatically, so that per-user settings land in that profile.

.PARAMETER KubectlMinor
    Kubernetes minor version for kubectl. Keep it within one minor version of the lab cluster.

.PARAMETER RepoRef
    The branch or tag of the lab repository to clone. The prepare LCA moves it to its own RepoRef at launch.

.PARAMETER WslDistribution
    The WSL distribution to install, by its name in the official WSL distribution list.

.PARAMETER WslUser
    The default Linux user name. Defaults to the Windows user name in lowercase.

.PARAMETER Finalize
    Prepares the VM for the differencing disk commit: verifies the image; removes setup files, caches,
    history, and any credentials; and shuts down the VM.

.PARAMETER NoShutdown
    With -Finalize, skips the shutdown.

.PARAMETER Force
    Runs even when the elevated user differs from the signed-in user, or when -Finalize finds failed checks.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File C:\LabSetup\kubecon-ctf-vm-image-setup.ps1

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File C:\LabSetup\kubecon-ctf-vm-image-setup.ps1 -Finalize
#>
[CmdletBinding()]
param(
    [ValidatePattern('^\d+\.\d+$')]
    [string]$KubectlMinor = '1.36',
    [ValidatePattern('^[A-Za-z0-9][A-Za-z0-9._/-]*$')]
    [string]$RepoRef = 'main',
    [ValidatePattern('^[A-Za-z0-9][A-Za-z0-9._-]*$')]
    [string]$WslDistribution = 'Ubuntu-24.04',
    [ValidatePattern('^$|^[a-z_][a-z0-9_-]{0,31}$')]
    [string]$WslUser = '',
    [switch]$Finalize,
    [switch]$NoShutdown,
    [switch]$Force
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
[Net.ServicePointManager]::SecurityProtocol =
    [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

$LabName      = 'KubeCon CTF'
$RepoUrl      = 'https://github.com/bbenz/kubecon26-pre-day-lab'
$LabRoot      = 'C:\LabFiles\kubecon26-pre-day-lab'
$SetupDir     = 'C:\LabSetup'
$DownloadDir  = 'C:\LabSetup\downloads'
$StateDir     = 'C:\ProgramData\kubecon-ctf-image'
$K8sDir       = 'C:\Program Files\Kubernetes'
$TerraformDir = 'C:\Program Files\Terraform'
$WslRoot      = 'C:\WSL'
$WslExe       = Join-Path $env:SystemRoot 'System32\wsl.exe'
$TarExe       = Join-Path $env:SystemRoot 'System32\tar.exe'
$WslRestartFile = Join-Path $StateDir 'wsl-restart.json'   # The boot in which the script asked for a restart
$ServicingRestartKey = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending'
$GitExe       = 'C:\Program Files\Git\cmd\git.exe'
$PwshExe      = 'C:\Program Files\PowerShell\7\pwsh.exe'
$AzCmd        = 'C:\Program Files\Microsoft SDKs\Azure\CLI2\wbin\az.cmd'
$GhExe        = 'C:\Program Files\GitHub CLI\gh.exe'
$CodeExe      = 'C:\Program Files\Microsoft VS Code\Code.exe'
$CodeCmd      = 'C:\Program Files\Microsoft VS Code\bin\code.cmd'
$PortalUrl    = 'https://portal.azure.com'
$AzExtensions = 'aks-agent', 'k8s-extension'
$CodeExtensions = 'ms-kubernetes-tools.vscode-kubernetes-tools', 'ms-kubernetes-tools.vscode-aks-tools', 'redhat.vscode-yaml',
                  'ms-vscode.powershell', 'ms-vscode-remote.remote-wsl', 'hashicorp.terraform'
# GitHub Copilot Chat is built into VS Code 1.14x and later, which refuses to install the marketplace extension over
# it. Older releases get the extension.
$CopilotExtension = 'GitHub.copilot-chat'
# AKS-MCP publishes no checksums file and its binary isn't signed, so the version and SHA-256 are pinned here.
$AksMcpTag    = 'v0.0.22'
$AksMcpSha256 = 'D0274045FA525A983C1328D371A51B5CDFDE313F672CB59C15682AD5C37F67EA'
# Challenge C2's README pins ingress2gateway 1.2.0.
$Ingress2GatewayTag = 'v1.2.0'
$MinAzureCli  = [version]'2.86.0'   # The lab's deployment scripts need 2.86 or later
$MinPwsh      = [version]'7.4.0'
$TotalItems   = 12
$Versions     = [ordered]@{}
$RestartItems = New-Object System.Collections.Generic.List[string]
$InstallerExitCode = 0
$EnvironmentHive = [Microsoft.Win32.Registry]::LocalMachine
$EnvironmentKey  = 'SYSTEM\CurrentControlSet\Control\Session Manager\Environment'

function Write-Item([int]$Number, [string]$Name) {
    Write-Host ''
    Write-Host ('==> [{0}/{1}] {2}' -f $Number, $TotalItems, $Name) -ForegroundColor Cyan
}

function Write-Ready([string]$Text) {
    Write-Host ('READY: ' + $Text) -ForegroundColor Green
}

function Invoke-Native([scriptblock]$NativeCommand) {
    # Windows PowerShell 5.1 turns redirected stderr from native tools into terminating errors
    # when $ErrorActionPreference is Stop. Run native tools with Continue and check exit codes.
    $saved = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try { & $NativeCommand } finally { $ErrorActionPreference = $saved }
}

function Update-SessionPath {
    $env:Path = [Environment]::GetEnvironmentVariable('Path', 'Machine') + ';' +
                [Environment]::GetEnvironmentVariable('Path', 'User')
}

function Add-MachinePath([string]$Directory) {
    # Edit the registry value directly so that %SystemRoot%-style entries stay unexpanded.
    $key = $EnvironmentHive.OpenSubKey($EnvironmentKey, $true)
    try {
        $path = [string]$key.GetValue('Path', '', [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
        if (($path -split ';') -notcontains $Directory) {
            $key.SetValue('Path', $path.TrimEnd(';') + ';' + $Directory, [Microsoft.Win32.RegistryValueKind]::ExpandString)
        }
    } finally {
        $key.Close()
    }
    # Setting and clearing a variable broadcasts the change, so that new windows get the new PATH.
    [Environment]::SetEnvironmentVariable('KUBECON_CTF_PATH_REFRESH', '1', 'User')
    [Environment]::SetEnvironmentVariable('KUBECON_CTF_PATH_REFRESH', $null, 'User')
    Update-SessionPath
}

function Set-MachineEnvironment([string]$Name, [string]$Value) {
    [Environment]::SetEnvironmentVariable($Name, $Value, 'Machine')
    Set-Item -Path "env:$Name" -Value $Value
}

function Set-RegValue {
    param(
        [string]$Path,
        [string]$Name,
        $Value,
        [ValidateSet('DWord', 'String')][string]$Type = 'DWord',
        [switch]$BestEffort
    )
    try {
        if (-not (Test-Path -LiteralPath $Path)) { New-Item -Path $Path -Force | Out-Null }
        # Skip values that are already right: Windows protects some policy values (Dsh, for one) once they exist.
        $current = (Get-ItemProperty -LiteralPath $Path -Name $Name -ErrorAction SilentlyContinue).$Name
        if ($null -ne $current -and "$current" -eq "$Value") { return }
        New-ItemProperty -LiteralPath $Path -Name $Name -Value $Value -PropertyType $Type -Force | Out-Null
    } catch {
        if (-not $BestEffort) { throw "Couldn't set $Path\$Name. $($_.Exception.Message)" }
        Write-Host "  Skipped $Path\$Name. $($_.Exception.Message)" -ForegroundColor DarkYellow
    }
}

function Save-Download([string]$Uri, [string]$FileName) {
    New-Item -ItemType Directory -Path $DownloadDir -Force | Out-Null
    $target = Join-Path $DownloadDir $FileName
    for ($attempt = 1; ; $attempt++) {
        try {
            Invoke-WebRequest -Uri $Uri -OutFile $target -UseBasicParsing
            return $target
        } catch {
            if ($attempt -ge 3) { throw }
            Start-Sleep -Seconds (10 * $attempt)
        }
    }
}

function Invoke-Installer([string]$FilePath, [string]$Arguments, [int]$TimeoutMinutes = 30) {
    # Waits for the installer process only, so an app that an installer starts can't stall the script.
    $process = Start-Process -FilePath $FilePath -ArgumentList $Arguments -PassThru
    $null = $process.Handle   # Windows PowerShell keeps the exit code only if the handle is opened early.
    if (-not $process.WaitForExit($TimeoutMinutes * 60000)) {
        Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue
        $null = $process.WaitForExit(60000)
        throw "$(Split-Path $FilePath -Leaf) didn't finish within $TimeoutMinutes minutes, so it was stopped."
    }
    $script:InstallerExitCode = $process.ExitCode
    if ($process.ExitCode -ne 0 -and $process.ExitCode -ne 3010) {
        throw "$(Split-Path $FilePath -Leaf) exited with code $($process.ExitCode)."
    }
}

function Get-EdgePath {
    $appPath = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\msedge.exe'
    if (Test-Path $appPath) {
        $path = ((Get-ItemProperty $appPath).'(default)' -as [string]).Trim('"')
        if ($path -and (Test-Path $path)) { return $path }
    }
    foreach ($path in "${env:ProgramFiles(x86)}\Microsoft\Edge\Application\msedge.exe",
                      "$env:ProgramFiles\Microsoft\Edge\Application\msedge.exe") {
        if (Test-Path $path) { return $path }
    }
    return $null
}

function Get-RedirectTarget([string]$Uri) {
    $response = Invoke-WebRequest -Uri $Uri -Method Head -UseBasicParsing
    if ($response.BaseResponse.ResponseUri) { return $response.BaseResponse.ResponseUri.AbsoluteUri }
    return $response.BaseResponse.RequestMessage.RequestUri.AbsoluteUri
}

function Get-LatestGitHubTag([string]$Repository) {
    # Follows the releases/latest redirect, which isn't subject to GitHub API rate limits.
    $target = Get-RedirectTarget "https://github.com/$Repository/releases/latest"
    if ($target -notmatch '/releases/tag/([^/?#]+)$') { throw "Couldn't look up the latest $Repository release." }
    return [uri]::UnescapeDataString($Matches[1])
}

function Confirm-FileHash([string]$FilePath, [string]$ChecksumFile) {
    # A checksum file with one hash, such as kubectl.exe.sha256
    $expected = ((Get-Content -LiteralPath $ChecksumFile -Raw).Trim() -split '\s+')[0]
    $actual = (Get-FileHash -LiteralPath $FilePath -Algorithm SHA256).Hash
    if ($actual -ne $expected) {
        throw "Checksum mismatch for $(Split-Path $FilePath -Leaf): expected $expected, got $actual."
    }
}

function Confirm-ListedHash([string]$FilePath, [string]$ChecksumFile, [string]$Name) {
    # A checksums file that lists many files, one "<sha256>  <name>" (or "<sha256> *<name>") per line
    $expected = $null
    foreach ($line in Get-Content -LiteralPath $ChecksumFile) {
        if ($line -match ('^([0-9a-fA-F]{64})\s+\*?' + [regex]::Escape($Name) + '\s*$')) { $expected = $Matches[1] }
    }
    if (-not $expected) { throw "$Name isn't listed in $(Split-Path $ChecksumFile -Leaf)." }
    $actual = (Get-FileHash -LiteralPath $FilePath -Algorithm SHA256).Hash
    if ($actual -ne $expected) { throw "Checksum mismatch for ${Name}: expected $expected, got $actual." }
    Write-Host "  Verified $Name against the published checksums."
}

function Confirm-Signature([string]$FilePath, [string]$Signer) {
    $signature = Get-AuthenticodeSignature -LiteralPath $FilePath
    if ($signature.Status -ne 'Valid' -or $signature.SignerCertificate.Subject -notmatch $Signer) {
        throw ("Couldn't verify $(Split-Path $FilePath -Leaf): its signature is $($signature.Status) " +
               "($($signature.SignerCertificate.Subject)), not a valid signature by $Signer.")
    }
    Write-Host "  Verified $(Split-Path $FilePath -Leaf) by its signature ($($signature.SignerCertificate.Subject))."
}

function Save-GitHubAsset {
    # Downloads a release asset and verifies it against the SHA-256 digest that GitHub publishes. If the
    # GitHub API isn't available (for example, rate limits on a shared address), it falls back to the
    # file's Authenticode signature.
    param([string]$Repository, [string]$Tag, [string]$AssetName, [string]$Signer)
    $file = Save-Download -Uri "https://github.com/$Repository/releases/download/$Tag/$AssetName" -FileName $AssetName
    $actual = (Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash
    $expected = $null
    try {
        $release = Invoke-RestMethod -Uri "https://api.github.com/repos/$Repository/releases/tags/$Tag" -UseBasicParsing
        $digest = [string]($release.assets | Where-Object { $_.name -eq $AssetName } | Select-Object -First 1).digest
        if ($digest -match '^sha256:([0-9a-fA-F]{64})$') { $expected = $Matches[1] }
    } catch {
        Write-Host "  The GitHub API isn't available ($($_.Exception.Message)), so the signature is checked instead." -ForegroundColor DarkYellow
    }
    if ($expected) {
        if ($actual -ne $expected) { throw "Checksum mismatch for ${AssetName}: expected $expected, got $actual." }
        Write-Host "  Verified $AssetName against the GitHub release digest."
    } else {
        Confirm-Signature $file $Signer
    }
    return $file
}

function Get-VersionText([string]$Executable, [string[]]$Arguments) {
    # The first X.Y.Z that a tool prints (without a leading v), or '' if it isn't installed.
    if (-not (Test-Path -LiteralPath $Executable)) { return '' }
    $text = (Invoke-Native { & $Executable @Arguments 2>&1 } | Out-String)
    return ([regex]::Match($text, '\d+\.\d+\.\d+')).Value
}

function Get-AzureCliVersion {
    if (-not (Test-Path $AzCmd)) { return $null }
    try {
        return (Invoke-Native { & $AzCmd version --output json --only-show-errors } | Out-String | ConvertFrom-Json).'azure-cli'
    } catch {
        return $null
    }
}

function Get-AzExtensionVersion([string]$Name) {
    if (-not (Test-Path $AzCmd)) { return '' }
    return [string](Invoke-Native { & $AzCmd extension show --name $Name --query version --output tsv --only-show-errors 2>$null })
}

function Get-KubectlVersion([string]$Executable) {
    if (-not (Test-Path $Executable)) { return '' }
    return (Invoke-Native { & $Executable version --client --output=json } | Out-String | ConvertFrom-Json).clientVersion.gitVersion
}

function Get-TerraformVersion {
    $executable = Join-Path $TerraformDir 'terraform.exe'
    if (-not (Test-Path $executable)) { return '' }
    try {
        return [string](Invoke-Native { & $executable version -json } | Out-String | ConvertFrom-Json).terraform_version
    } catch {
        return ''
    }
}

function Get-PwshVersion {
    if (-not (Test-Path -LiteralPath $PwshExe)) { return $null }
    try { return [version](Invoke-Native { & $PwshExe -NoProfile -NonInteractive -Command '$PSVersionTable.PSVersion.ToString()' } | Select-Object -Last 1) }
    catch { return $null }
}

function Get-AksDesktopInstall {
    # electron-builder registers the app under Uninstall, per machine with /allusers.
    foreach ($root in 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall',
                      'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall',
                      'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall') {
        if (-not (Test-Path $root)) { continue }
        foreach ($key in Get-ChildItem -LiteralPath $root -ErrorAction SilentlyContinue) {
            $values = Get-ItemProperty -LiteralPath $key.PSPath -ErrorAction SilentlyContinue
            if ([string]$values.DisplayName -match 'AKS desktop') {
                # InstallLocation is empty for electron-builder installs; DisplayIcon points at the app.
                $location = ([string]$values.InstallLocation).Trim('"')
                if (-not $location -and $values.DisplayIcon) { $location = Split-Path -Parent ((([string]$values.DisplayIcon) -replace ',\d+$', '').Trim('"')) }
                return [pscustomobject]@{ Name = [string]$values.DisplayName; Version = [string]$values.DisplayVersion
                                          Location = $location; PerMachine = $root -like 'HKLM:*' }
            }
        }
    }
    return $null
}

function Invoke-Wsl([string[]]$Arguments) {
    # wsl.exe writes UTF-16 text unless WSL_UTF8 is set.
    $env:WSL_UTF8 = '1'
    $output = Invoke-Native { & $WslExe @Arguments 2>&1 }
    $code = $LASTEXITCODE
    $text = ((@($output) | ForEach-Object { "$_" }) -join "`n") -replace "`0", ''
    return [pscustomobject]@{ ExitCode = $code; Text = $text.Trim() }
}

function Get-WslPackageVersion {
    $executable = Join-Path $env:ProgramFiles 'WSL\wsl.exe'
    if (-not (Test-Path -LiteralPath $executable)) { return $null }
    if ((Get-Item -LiteralPath $executable).VersionInfo.ProductVersion -match '^(\d+\.\d+\.\d+)') { return [version]$Matches[1] }
    return $null
}

function Get-WslDistributions {
    if (-not (Get-WslPackageVersion)) { return @() }
    $result = Invoke-Wsl @('--list', '--quiet')
    if ($result.ExitCode -ne 0) { return @() }
    return @($result.Text -split "`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ })
}

function Get-WslRegistration([string]$Name) {
    # WSL registers distributions per Windows user, under HKCU.
    $lxss = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Lxss'
    if (-not (Test-Path $lxss)) { return $null }
    foreach ($key in Get-ChildItem -LiteralPath $lxss) {
        $values = Get-ItemProperty -LiteralPath $key.PSPath
        if ($values.DistributionName -eq $Name) { return $values }
    }
    return $null
}

function Get-WslLinuxUser {
    if ($WslUser) { return $WslUser }
    $name = $env:USERNAME.ToLowerInvariant() -replace '[^a-z0-9_-]', ''
    if ($name -notmatch '^[a-z_]' -or $name -in @('root', 'admin', 'ubuntu')) { $name = 'labuser' }
    if ($name.Length -gt 32) { $name = $name.Substring(0, 32) }
    return $name
}

function Get-WslDefaultUser([string]$Name) {
    $result = Invoke-Wsl @('-d', $Name, '--exec', 'whoami')
    if ($result.ExitCode -ne 0) { return '' }
    return (($result.Text -split "`n") | Select-Object -Last 1).Trim()
}

function Get-WslErrorCode([string]$Text) {
    # wsl.exe ends an error with a line such as "Error code: Wsl/Service/RegisterDistro/WSL_E_WSL1_NOT_SUPPORTED".
    if ($Text -match 'Error code:\s*(\S+)') { return $Matches[1] }
    return ($Text -replace '\s+', ' ').Trim()
}

function Get-BootTime {
    return (Get-CimInstance -ClassName Win32_OperatingSystem).LastBootUpTime.ToUniversalTime()
}

function Get-WslRestartRequest {
    # The boot in which the script last asked for a restart for WSL, and how many times it has asked.
    if (-not (Test-Path -LiteralPath $WslRestartFile)) { return }
    try {
        $saved = Get-Content -LiteralPath $WslRestartFile -Raw | ConvertFrom-Json
        $boot = [datetime]::ParseExact([string]$saved.boot, 'yyyyMMddHHmmss', [Globalization.CultureInfo]::InvariantCulture)
        $sameBoot = [Math]::Abs(((Get-BootTime) - $boot).TotalMinutes) -le 2
        return [pscustomobject]@{ Requests = [int]$saved.requests; SameBoot = $sameBoot }
    } catch {
        return
    }
}

function Request-WslRestart([string]$Reason, $Request) {
    # A repeat request in the same boot is the same request, so it isn't counted again.
    $requests = if (-not $Request) { 1 } elseif ($Request.SameBoot) { $Request.Requests } else { $Request.Requests + 1 }
    $marker = [ordered]@{ boot = (Get-BootTime).ToString('yyyyMMddHHmmss'); requests = $requests }
    [IO.File]::WriteAllText($WslRestartFile, (ConvertTo-Json -InputObject $marker), (New-Object Text.UTF8Encoding($false)))
    $RestartItems.Add('WSL')
    Write-Host "PENDING: $Reason Restart the VM, and then run the script again." -ForegroundColor Yellow
}

function Set-WindowsExperience {
    # Notifications, tips, suggestions, and "finish setting up your device" prompts
    Set-RegValue 'HKCU:\Software\Microsoft\Windows\CurrentVersion\PushNotifications' 'ToastEnabled' 0
    $cdm = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'
    foreach ($name in 'SubscribedContent-310093Enabled', 'SubscribedContent-338388Enabled',
                      'SubscribedContent-338389Enabled', 'SubscribedContent-353694Enabled',
                      'SubscribedContent-353696Enabled', 'SoftLandingEnabled',
                      'SystemPaneSuggestionsEnabled', 'SilentInstalledAppsEnabled') {
        Set-RegValue $cdm $name 0
    }
    Set-RegValue 'HKCU:\Software\Microsoft\Windows\CurrentVersion\UserProfileEngagement' 'ScoobeSystemSettingEnabled' 0
    Set-RegValue 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\CloudContent' 'DisableWindowsConsumerFeatures' 1
    Set-RegValue 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\CloudContent' 'DisableSoftLanding' 1

    # No automatic Windows Update or Microsoft Store downloads, and no forced restarts
    Set-RegValue 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU' 'NoAutoUpdate' 1
    Set-RegValue 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU' 'NoAutoRebootWithLoggedOnUsers' 1
    Set-RegValue 'HKLM:\SOFTWARE\Policies\Microsoft\WindowsStore' 'AutoDownload' 2

    # OneDrive, Teams (free), Chat, widgets, and Windows Copilot (GitHub Copilot in VS Code is separate)
    Set-RegValue 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\OneDrive' 'DisableFileSyncNGSC' 1
    foreach ($name in 'OneDrive', 'OneDriveSetup') {
        Remove-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run' -Name $name -ErrorAction SilentlyContinue
    }
    Set-RegValue 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Chat' 'ChatIcon' 3
    if (Get-AppxPackage -Name 'MSTeams' -ErrorAction SilentlyContinue) {
        Set-RegValue ('HKCU:\Software\Classes\Local Settings\Software\Microsoft\Windows\CurrentVersion\AppModel\' +
                      'SystemAppData\MSTeams_8wekyb3d8bbwe\TeamsTfwStartupTask') 'State' 1 -BestEffort
    }
    Set-RegValue 'HKLM:\SOFTWARE\Policies\Microsoft\Dsh' 'AllowNewsAndInterests' 0 -BestEffort
    Set-RegValue 'HKCU:\Software\Policies\Microsoft\Windows\WindowsCopilot' 'TurnOffWindowsCopilot' 1
    $advanced = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'
    Set-RegValue $advanced 'ShowCopilotButton' 0 -BestEffort
    Set-RegValue $advanced 'TaskbarMn' 0 -BestEffort
    Set-RegValue $advanced 'HideFileExt' 0 -BestEffort

    # Never sleep, turn off the display, hibernate, show a screen saver, or lock
    Invoke-Native {
        powercfg /change monitor-timeout-ac 0
        powercfg /change standby-timeout-ac 0
        powercfg /hibernate off
    } | Out-Null
    Set-RegValue 'HKCU:\Control Panel\Desktop' 'ScreenSaveActive' '0' -Type String
    Set-RegValue 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Personalization' 'NoLockScreen' 1

    # Windows 11 hides the netplwiz automatic sign-in checkbox while Windows Hello-only sign-in is on. Show it.
    Set-RegValue 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\PasswordLess\Device' 'DevicePasswordLessBuildVersion' 0

    # en-US keyboard, so that Skillable type text produces the exact characters
    $first = (Get-WinUserLanguageList)[0]
    if ($first.LanguageTag -ne 'en-US' -or $first.InputMethodTips -notcontains '0409:00000409') {
        Set-WinUserLanguageList -LanguageList (New-WinUserLanguageList -Language 'en-US') -Force
    }
    Set-WinDefaultInputMethodOverride -InputTip '0409:00000409'

    Write-Ready 'Windows settings: pop-ups suppressed, no automatic updates, never sleeps or locks, en-US keyboard'
}

function Install-Git {
    if (-not (Test-Path $GitExe)) {
        $tag = Get-LatestGitHubTag 'git-for-windows/git'
        if ($tag -notmatch '^v(\d+\.\d+\.\d+)\.windows\.(\d+)$') { throw "Couldn't look up the current Git for Windows release." }
        # Git-2.56.0-64-bit.exe for .windows.1, Git-2.56.0.4-64-bit.exe for .windows.4
        $name = if ($Matches[2] -eq '1') { "Git-$($Matches[1])-64-bit.exe" } else { "Git-$($Matches[1]).$($Matches[2])-64-bit.exe" }
        $installer = Save-Download -Uri "https://github.com/git-for-windows/git/releases/download/$tag/$name" -FileName $name
        Confirm-Signature $installer 'Johannes Schindelin'
        Invoke-Installer $installer '/VERYSILENT /NORESTART /NOCANCEL /SP- /SUPPRESSMSGBOXES /CLOSEAPPLICATIONS'
        if (-not (Test-Path $GitExe)) { throw "Git isn't at $GitExe after the install." }
    }
    Update-SessionPath
    Invoke-Native {
        & $GitExe config --system init.defaultBranch main
        & $GitExe config --system core.editor 'code --wait'
    } | Out-Null
    $Versions['git'] = ((Invoke-Native { & $GitExe --version }) -replace '^git version\s+', '')
    Write-Ready "Git $($Versions['git']) (Git Bash runs the lab's bash scripts)"
}

function Install-PowerShell7 {
    # The lab's PowerShell deployment and scoring scripts need PowerShell 7.4 or later.
    $tag = Get-LatestGitHubTag 'PowerShell/PowerShell'
    if ($tag -notmatch '^v(\d+\.\d+\.\d+)$') { throw "Couldn't look up the current PowerShell release." }
    $latest = [version]$Matches[1]
    $installed = Get-PwshVersion
    if (-not $installed -or $installed -lt $latest) {
        $msiName = "PowerShell-$latest-win-x64.msi"
        $base = "https://github.com/PowerShell/PowerShell/releases/download/$tag"
        $msi = Save-Download -Uri "$base/$msiName" -FileName $msiName
        Confirm-ListedHash $msi (Save-Download -Uri "$base/hashes.sha256" -FileName 'powershell-hashes.sha256') $msiName
        Invoke-Installer 'msiexec.exe' ("/i `"$msi`" /qn /norestart ADD_PATH=1 USE_MU=0 ENABLE_MU=0 " +
                                        'ADD_EXPLORER_CONTEXT_MENU_OPENPOWERSHELL=0 ENABLE_PSREMOTING=0')
    }
    # No update notices or telemetry
    Set-MachineEnvironment 'POWERSHELL_UPDATECHECK' 'Off'
    Set-MachineEnvironment 'POWERSHELL_TELEMETRY_OPTOUT' '1'
    Update-SessionPath
    $version = Get-PwshVersion
    if (-not $version -or $version -lt $MinPwsh) { throw "PowerShell 7 isn't working after the install (found '$version')." }
    $Versions['powershell'] = $version.ToString()
    Write-Ready "PowerShell $($Versions['powershell']) at $PwshExe, with update checks and telemetry off"
}

function Install-AzureCli {
    # The base image can include an older Azure CLI, so install or upgrade to the current release.
    $msiUrl = 'https://aka.ms/installazurecliwindowsx64'
    try { $msiUrl = Get-RedirectTarget $msiUrl } catch { }
    $latest = [regex]::Match($msiUrl, 'azure-cli-(\d+\.\d+\.\d+)').Groups[1].Value
    $installed = Get-AzureCliVersion
    $tooOld = $installed -and [version]$installed -lt $MinAzureCli
    if (-not $installed -or $tooOld -or ($latest -and [version]$installed -lt [version]$latest)) {
        if ($installed) { Write-Host "  Upgrading Azure CLI $installed to $(if ($latest) { $latest } else { 'the current release' })." }
        $msi = Save-Download -Uri $msiUrl -FileName 'azure-cli.msi'
        Confirm-Signature $msi 'Microsoft Corporation'
        Invoke-Installer 'msiexec.exe' "/i `"$msi`" /qn /norestart"
    } elseif (-not $latest) {
        Write-Host "  Couldn't look up the current Azure CLI release, so $installed stays." -ForegroundColor DarkYellow
    }
    Update-SessionPath
    Invoke-Native {
        & $AzCmd config set core.login_experience_v2=off core.enable_broker_on_windows=false core.collect_telemetry=false `
            core.survey_message=false auto-upgrade.enable=no --only-show-errors
    } | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "az config set failed with exit code $LASTEXITCODE." }
    $Versions['azureCli'] = Get-AzureCliVersion
    if (-not $Versions['azureCli']) { throw "Azure CLI isn't working after the install." }
    if ([version]$Versions['azureCli'] -lt $MinAzureCli) {
        throw "Azure CLI is $($Versions['azureCli']) after the install, older than $MinAzureCli, the minimum for this lab."
    }

    # Extensions, in the lab user's profile: aks-agent (az aks agent, the agentic CLI for AKS) and k8s-extension
    # (az k8s-extension, which manages the Inspektor Gadget cluster extension). aks-agent takes 5 to 10 minutes.
    foreach ($extension in $AzExtensions) {
        Write-Host "  az extension add --name $extension --upgrade"
        Invoke-Native { & $AzCmd extension add --name $extension --upgrade --yes --only-show-errors } | Out-Host
        if ($LASTEXITCODE -ne 0) { throw "az extension add --name $extension failed with exit code $LASTEXITCODE." }
        $Versions["az-$extension"] = Get-AzExtensionVersion $extension
    }
    Invoke-Native { & $AzCmd aks agent --help --only-show-errors } | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "az aks agent --help failed after the aks-agent extension was installed." }
    Write-Ready ("Azure CLI $($Versions['azureCli']) with aks-agent $($Versions['az-aks-agent']) and k8s-extension " +
                 "$($Versions['az-k8s-extension']) (browser sign-in; login experience v2, telemetry, survey prompts, automatic upgrade off)")
}

function Install-KubernetesTools {
    # From the official release locations, checked against the published checksums. This doesn't use
    # az aks install-cli, so the versions and checks are the same on every image.
    New-Item -ItemType Directory -Path $K8sDir -Force | Out-Null
    $kubectl = Join-Path $K8sDir 'kubectl.exe'
    $kubelogin = Join-Path $K8sDir 'kubelogin.exe'
    $helm = Join-Path $K8sDir 'helm.exe'
    $gadget = Join-Path $K8sDir 'kubectl-gadget.exe'
    $ingress2gateway = Join-Path $K8sDir 'ingress2gateway.exe'
    $aksMcp = Join-Path $K8sDir 'aks-mcp.exe'

    $kubectlVersion = (Invoke-WebRequest -Uri "https://dl.k8s.io/release/stable-$KubectlMinor.txt" -UseBasicParsing).Content.Trim()
    if ((Get-KubectlVersion $kubectl) -ne $kubectlVersion) {
        $url = "https://dl.k8s.io/release/$kubectlVersion/bin/windows/amd64/kubectl.exe"
        $file = Save-Download -Uri $url -FileName 'kubectl.exe'
        Confirm-FileHash $file (Save-Download -Uri "$url.sha256" -FileName 'kubectl.exe.sha256')
        Copy-Item -LiteralPath $file -Destination $kubectl -Force
    }

    $kubeloginTag = Get-LatestGitHubTag 'Azure/kubelogin'
    if ($kubeloginTag -notmatch '^v\d+\.\d+\.\d+$') { throw "Couldn't look up the current kubelogin release." }
    if ((Get-VersionText $kubelogin @('--version')) -ne $kubeloginTag.TrimStart('v')) {
        $url = "https://github.com/Azure/kubelogin/releases/download/$kubeloginTag/kubelogin-win-amd64.zip"
        $zip = Save-Download -Uri $url -FileName 'kubelogin-win-amd64.zip'
        Confirm-FileHash $zip (Save-Download -Uri "$url.sha256" -FileName 'kubelogin-win-amd64.zip.sha256')
        $extracted = Join-Path $DownloadDir 'kubelogin'
        Expand-Archive -LiteralPath $zip -DestinationPath $extracted -Force
        Copy-Item -LiteralPath (Join-Path $extracted 'bin\windows_amd64\kubelogin.exe') -Destination $kubelogin -Force
    }

    $helmTag = Get-LatestGitHubTag 'helm/helm'
    if ($helmTag -notmatch '^v\d+\.\d+\.\d+$') { throw "Couldn't look up the current Helm release." }
    if ((Get-VersionText $helm @('version', '--short')) -ne $helmTag.TrimStart('v')) {
        $zipName = "helm-$helmTag-windows-amd64.zip"
        $zip = Save-Download -Uri "https://get.helm.sh/$zipName" -FileName $zipName
        Confirm-FileHash $zip (Save-Download -Uri "https://get.helm.sh/$zipName.sha256sum" -FileName "$zipName.sha256sum")
        $extracted = Join-Path $DownloadDir 'helm'
        Expand-Archive -LiteralPath $zip -DestinationPath $extracted -Force
        Copy-Item -LiteralPath (Join-Path $extracted 'windows-amd64\helm.exe') -Destination $helm -Force
    }

    # Inspektor Gadget's kubectl plugin (kubectl gadget). The prepare LCA installs its cluster extension. Its version
    # command needs a cluster, so a marker file records the installed release.
    $gadgetTag = Get-LatestGitHubTag 'inspektor-gadget/inspektor-gadget'
    if ($gadgetTag -notmatch '^v\d+\.\d+\.\d+$') { throw "Couldn't look up the current Inspektor Gadget release." }
    $gadgetMarker = Join-Path $StateDir 'kubectl-gadget.version'
    $gadgetInstalled = if ((Test-Path -LiteralPath $gadget) -and (Test-Path -LiteralPath $gadgetMarker)) { (Get-Content -LiteralPath $gadgetMarker -Raw).Trim() } else { '' }
    if ($gadgetInstalled -ne $gadgetTag) {
        $base = "https://github.com/inspektor-gadget/inspektor-gadget/releases/download/$gadgetTag"
        $name = "kubectl-gadget-windows-amd64-$gadgetTag.tar.gz"
        $archive = Save-Download -Uri "$base/$name" -FileName $name
        Confirm-ListedHash $archive (Save-Download -Uri "$base/SHA256SUMS" -FileName 'inspektor-gadget-SHA256SUMS') $name
        $extracted = Join-Path $DownloadDir 'kubectl-gadget'
        New-Item -ItemType Directory -Path $extracted -Force | Out-Null
        Invoke-Native { & $TarExe -xzf $archive -C $extracted } | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "Couldn't extract $name." }
        Copy-Item -LiteralPath (Join-Path $extracted 'kubectl-gadget.exe') -Destination $gadget -Force
        [IO.File]::WriteAllText($gadgetMarker, $gadgetTag)
    }

    # ingress2gateway, which challenge C2 uses to translate the Ingress to the Gateway API
    if ((Get-VersionText $ingress2gateway @('version')) -ne $Ingress2GatewayTag.TrimStart('v')) {
        $base = "https://github.com/kubernetes-sigs/ingress2gateway/releases/download/$Ingress2GatewayTag"
        $zip = Save-Download -Uri "$base/ingress2gateway_Windows_x86_64.zip" -FileName 'ingress2gateway_Windows_x86_64.zip'
        Confirm-ListedHash $zip (Save-Download -Uri "$base/checksums.txt" -FileName 'ingress2gateway-checksums.txt') 'ingress2gateway_Windows_x86_64.zip'
        $extracted = Join-Path $DownloadDir 'ingress2gateway'
        Expand-Archive -LiteralPath $zip -DestinationPath $extracted -Force
        Copy-Item -LiteralPath (Join-Path $extracted 'ingress2gateway.exe') -Destination $ingress2gateway -Force
    }

    # The AKS-MCP server, which VS Code starts for GitHub Copilot (item 9)
    if (-not (Test-Path -LiteralPath $aksMcp) -or (Get-FileHash -LiteralPath $aksMcp -Algorithm SHA256).Hash -ne $AksMcpSha256) {
        $file = Save-Download -Uri "https://github.com/Azure/aks-mcp/releases/download/$AksMcpTag/aks-mcp-windows-amd64.exe" -FileName 'aks-mcp.exe'
        $actual = (Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash
        if ($actual -ne $AksMcpSha256) { throw "Checksum mismatch for aks-mcp $AksMcpTag`: expected $AksMcpSha256, got $actual." }
        Copy-Item -LiteralPath $file -Destination $aksMcp -Force
    }

    Add-MachinePath $K8sDir
    $resolved = (Get-Command kubectl -ErrorAction SilentlyContinue).Source
    if ($resolved -ne $kubectl) { Write-Host "  Another kubectl comes first on the PATH: $resolved" -ForegroundColor DarkYellow }
    $Versions['kubectl'] = Get-KubectlVersion $kubectl
    $Versions['kubelogin'] = Get-VersionText $kubelogin @('--version')
    $Versions['helm'] = Get-VersionText $helm @('version', '--short')
    $Versions['kubectl-gadget'] = if (Test-Path -LiteralPath $gadgetMarker) { (Get-Content -LiteralPath $gadgetMarker -Raw).Trim().TrimStart('v') } else { '' }
    $Versions['ingress2gateway'] = Get-VersionText $ingress2gateway @('version')
    $Versions['aks-mcp'] = Get-VersionText $aksMcp @('--version')
    $expected = [ordered]@{ kubectl = $kubectlVersion; kubelogin = $kubeloginTag.TrimStart('v'); helm = $helmTag.TrimStart('v')
                            'kubectl-gadget' = $gadgetTag.TrimStart('v'); ingress2gateway = $Ingress2GatewayTag.TrimStart('v'); 'aks-mcp' = $AksMcpTag.TrimStart('v') }
    $wrong = @($expected.Keys | Where-Object { $Versions[$_] -ne $expected[$_] } | ForEach-Object { "$_ '$($Versions[$_])' (expected $($expected[$_]))" })
    if ($wrong.Count -gt 0) { throw "Unexpected versions after the install: $($wrong -join ', ')." }
    Write-Ready ("kubectl $($Versions['kubectl']), kubelogin $($Versions['kubelogin']), Helm $($Versions['helm']), kubectl gadget " +
                 "$($Versions['kubectl-gadget']), ingress2gateway $($Versions['ingress2gateway']), and aks-mcp $($Versions['aks-mcp']) " +
                 "(checksums verified) in $K8sDir, on the system PATH")
}

function Install-Terraform {
    $release = Invoke-RestMethod -Uri 'https://api.releases.hashicorp.com/v1/releases/terraform/latest' -UseBasicParsing
    $latest = [string]$release.version
    if ($latest -notmatch '^\d+\.\d+\.\d+$') { throw "Couldn't look up the current Terraform release." }
    # No upgrade or security bulletin checks, so Terraform doesn't print upgrade notices during the lab.
    Set-MachineEnvironment 'CHECKPOINT_DISABLE' '1'
    if ((Get-TerraformVersion) -ne $latest) {
        $base = "https://releases.hashicorp.com/terraform/$latest"
        $zipName = "terraform_${latest}_windows_amd64.zip"
        $zip = Save-Download -Uri "$base/$zipName" -FileName $zipName
        Confirm-ListedHash $zip (Save-Download -Uri "$base/terraform_${latest}_SHA256SUMS" -FileName "terraform_${latest}_SHA256SUMS") $zipName
        $extracted = Join-Path $DownloadDir 'terraform'
        Expand-Archive -LiteralPath $zip -DestinationPath $extracted -Force
        New-Item -ItemType Directory -Path $TerraformDir -Force | Out-Null
        Copy-Item -LiteralPath (Join-Path $extracted 'terraform.exe') -Destination (Join-Path $TerraformDir 'terraform.exe') -Force
    }
    Add-MachinePath $TerraformDir
    $Versions['terraform'] = Get-TerraformVersion
    if ($Versions['terraform'] -ne $latest) { throw "Expected Terraform $latest, but found $($Versions['terraform'])." }
    Write-Ready "Terraform $($Versions['terraform']) (checksum verified) in $TerraformDir, with update checks off"
}

function Install-GitHubCli {
    $tag = Get-LatestGitHubTag 'cli/cli'
    if ($tag -notmatch '^v(\d+\.\d+\.\d+)$') { throw "Couldn't look up the current GitHub CLI release." }
    $latest = $Matches[1]
    if ((Get-VersionText $GhExe @('--version')) -ne $latest) {
        $base = "https://github.com/cli/cli/releases/download/$tag"
        $msiName = "gh_${latest}_windows_amd64.msi"
        $msi = Save-Download -Uri "$base/$msiName" -FileName $msiName
        Confirm-ListedHash $msi (Save-Download -Uri "$base/gh_${latest}_checksums.txt" -FileName 'gh-checksums.txt') $msiName
        Invoke-Installer 'msiexec.exe' "/i `"$msi`" /qn /norestart"
    }
    Set-MachineEnvironment 'GH_NO_UPDATE_NOTIFIER' '1'
    Update-SessionPath
    $Versions['gh'] = Get-VersionText $GhExe @('--version')
    if ($Versions['gh'] -ne $latest) { throw "Expected GitHub CLI $latest, but found '$($Versions['gh'])'." }
    Write-Ready "GitHub CLI $($Versions['gh']) (checksum verified), with update notices off"
}

function Install-AksDesktop {
    $tag = Get-LatestGitHubTag 'Azure/aks-desktop'
    if ($tag -notmatch '^v(\d+\.\d+\.\d+)$') { throw "Couldn't look up the current AKS desktop release." }
    $latest = $Matches[1]
    $installed = Get-AksDesktopInstall
    if (-not $installed -or $installed.Version -ne $latest) {
        $name = "aks-desktop-$latest-win-x64.exe"
        $installer = Save-Download -Uri "https://github.com/Azure/aks-desktop/releases/download/$tag/$name" -FileName $name
        Confirm-Signature $installer 'Microsoft Corporation'
        # electron-builder's assisted installer: /S is silent, and /allusers installs it for every user.
        Invoke-Installer $installer '/S /allusers' -TimeoutMinutes 15
        $installed = Get-AksDesktopInstall
    }
    if (-not $installed) { throw "AKS desktop isn't registered as installed after the install." }
    # The installer can start the app. Close it, so the image doesn't start with it open.
    if ($installed.Location) {
        Get-Process -ErrorAction SilentlyContinue | Where-Object { $_.Path -and $_.Path -like "$($installed.Location)*" } |
            Stop-Process -Force -ErrorAction SilentlyContinue
    }
    $Versions['aksDesktop'] = $installed.Version
    $scope = if ($installed.PerMachine) { 'for all users' } else { 'for the current user' }
    Write-Ready "AKS desktop $($installed.Version) (signature verified), installed $scope in $($installed.Location)"
}

function Get-CopilotChat {
    # "built in (<version>)", "extension <version>", or '' when VS Code has no GitHub Copilot Chat.
    if (-not (Test-Path -LiteralPath $CodeExe)) { return '' }
    $builtIn = Get-ChildItem -LiteralPath (Split-Path -Parent $CodeExe) -Directory -Recurse -Depth 4 -Filter 'copilot' -ErrorAction SilentlyContinue |
               Where-Object { $_.FullName -match '\\resources\\app\\extensions\\copilot$' } | Select-Object -First 1
    if ($builtIn) {
        $version = ''
        try { $version = [string](Get-Content -LiteralPath (Join-Path $builtIn.FullName 'package.json') -Raw | ConvertFrom-Json).version } catch { }
        return "built in ($version)"
    }
    $installed = @(Invoke-Native { & $CodeCmd --list-extensions --show-versions 2>$null }) | Where-Object { "$_" -match '^github\.copilot-chat@' } | Select-Object -First 1
    if ($installed) { return "extension $("$installed" -replace '^.*@', '')" }
    return ''
}

function Install-VSCode {
    if (-not (Test-Path $CodeExe)) {
        $installer = Save-Download -Uri 'https://update.code.visualstudio.com/latest/win32-x64/stable' -FileName 'vscode-setup-x64.exe'
        Confirm-Signature $installer 'Microsoft Corporation'
        Invoke-Installer $installer '/VERYSILENT /NORESTART /MERGETASKS=!runcode,addcontextmenufiles,addcontextmenufolders,associatewithfiles,addtopath'
    }
    Update-SessionPath
    # The WSL extension also keeps VS Code from suggesting it once WSL is installed.
    $extensionArgs = @(foreach ($extension in $CodeExtensions) { '--install-extension'; $extension })
    Invoke-Native { & $CodeCmd @extensionArgs --force } | Out-Host
    if ($LASTEXITCODE -ne 0) { throw "Installing the VS Code extensions failed with exit code $LASTEXITCODE." }
    if (-not (Get-CopilotChat)) {
        Invoke-Native { & $CodeCmd --install-extension $CopilotExtension --force } | Out-Host
    }
    $Versions['copilotChat'] = Get-CopilotChat
    if (-not $Versions['copilotChat']) { throw "VS Code has no GitHub Copilot Chat, and installing $CopilotExtension failed." }

    $userDir = Join-Path $env:APPDATA 'Code\User'
    New-Item -ItemType Directory -Path $userDir -Force | Out-Null
    $settingsPath = Join-Path $userDir 'settings.json'
    $settings = [ordered]@{}
    if (Test-Path -LiteralPath $settingsPath) {
        try {
            (Get-Content -LiteralPath $settingsPath -Raw | ConvertFrom-Json).PSObject.Properties | ForEach-Object { $settings[$_.Name] = $_.Value }
        } catch {
            Copy-Item -LiteralPath $settingsPath -Destination "$settingsPath.bak" -Force
        }
    }
    $desired = [ordered]@{
        'workbench.startupEditor'                          = 'none'
        'workbench.welcomePage.walkthroughs.openOnInstall' = $false
        'workbench.tips.enabled'                           = $false
        'update.mode'                                      = 'none'
        'update.showReleaseNotes'                          = $false
        'telemetry.telemetryLevel'                         = 'off'
        'redhat.telemetry.enabled'                         = $false
        'extensions.ignoreRecommendations'                 = $true
        'extensions.autoUpdate'                            = $false
        'extensions.autoCheckUpdates'                      = $false
        'security.workspace.trust.enabled'                 = $false
        'window.restoreWindows'                            = 'none'
        'files.autoSave'                                   = 'afterDelay'
        'editor.fontSize'                                  = 16
        'editor.minimap.enabled'                           = $false
        'terminal.integrated.fontSize'                     = 15
        'terminal.integrated.defaultProfile.windows'       = 'PowerShell'
        'terminal.integrated.enablePersistentSessions'     = $false
        'git.openRepositoryInParentFolders'                = 'never'
        'chat.mcp.access'                                  = 'all'
        'vs-kubernetes'                                    = [ordered]@{
            'vs-kubernetes.kubectl-path.windows'   = (Join-Path $K8sDir 'kubectl.exe')
            'vs-kubernetes.helm-path.windows'      = (Join-Path $K8sDir 'helm.exe')
            'vs-kubernetes.ignore-recommendations' = $true
            'checkForMinikubeUpgrade'              = $false
        }
    }
    foreach ($key in $desired.Keys) { $settings[$key] = $desired[$key] }
    [IO.File]::WriteAllText($settingsPath, (ConvertTo-Json -InputObject $settings -Depth 10), (New-Object Text.UTF8Encoding($false)))

    # AKS-MCP as a user-level MCP server, so GitHub Copilot's agent mode can use it in any folder. It runs as the
    # attendee, with their own az login and kubeconfig. readwrite lets Copilot apply fixes; the challenges need that.
    $mcpPath = Join-Path $userDir 'mcp.json'
    $mcp = [ordered]@{ servers = [ordered]@{} }
    if (Test-Path -LiteralPath $mcpPath) {
        try {
            $existing = Get-Content -LiteralPath $mcpPath -Raw | ConvertFrom-Json
            foreach ($p in $existing.PSObject.Properties) { if ($p.Name -ne 'servers') { $mcp[$p.Name] = $p.Value } }
            foreach ($p in $existing.servers.PSObject.Properties) { $mcp.servers[$p.Name] = $p.Value }
        } catch {
            Copy-Item -LiteralPath $mcpPath -Destination "$mcpPath.bak" -Force
        }
    }
    $mcp.servers['aks-mcp'] = [ordered]@{
        type    = 'stdio'
        command = (Join-Path $K8sDir 'aks-mcp.exe')
        args    = @('--access-level', 'readwrite', '--timeout', '600')
        env     = [ordered]@{ AKS_MCP_COLLECT_TELEMETRY = 'false' }
    }
    [IO.File]::WriteAllText($mcpPath, (ConvertTo-Json -InputObject $mcp -Depth 10), (New-Object Text.UTF8Encoding($false)))

    $Versions['vscode'] = (Invoke-Native { & $CodeCmd --version } | Select-Object -First 1)
    Write-Ready ("Visual Studio Code $($Versions['vscode']) with GitHub Copilot Chat ($($Versions['copilotChat'])) and the Kubernetes, AKS, " +
                 'YAML, PowerShell, WSL, and Terraform extensions; AKS-MCP in the user mcp.json; no welcome, update, telemetry, or workspace trust prompts')
}

function Set-EdgePolicies {
    $edge = 'HKLM:\SOFTWARE\Policies\Microsoft\Edge'
    $policies = [ordered]@{
        HideFirstRunExperience                        = 1
        AutoImportAtFirstRun                          = 4
        DefaultBrowserSettingEnabled                  = 0
        BrowserSignin                                 = 0
        SyncDisabled                                  = 1
        PasswordManagerEnabled                        = 0
        AutofillAddressEnabled                        = 0
        AutofillCreditCardEnabled                     = 0
        ShowRecommendationsEnabled                    = 0
        PromotionalTabsEnabled                        = 0
        SpotlightExperiencesAndRecommendationsEnabled = 0
        EdgeShoppingAssistantEnabled                  = 0
        ShowMicrosoftRewards                          = 0
        HubsSidebarEnabled                            = 0
        StartupBoostEnabled                           = 0
        BackgroundModeEnabled                         = 0
        FavoritesBarEnabled                           = 1
        RestoreOnStartup                              = 4
    }
    foreach ($name in $policies.Keys) { Set-RegValue $edge $name $policies[$name] }
    Set-RegValue "$edge\RestoreOnStartupURLs" '1' $PortalUrl -Type String
    $favorites = @(
        [ordered]@{ toplevel_name = $LabName },
        [ordered]@{ name = 'Azure portal'; url = $PortalUrl },
        [ordered]@{ name = 'Lab repository'; url = 'https://aka.ms/kubecon26-pre-day-lab' },
        [ordered]@{ name = 'AKS documentation'; url = 'https://learn.microsoft.com/azure/aks/' },
        [ordered]@{ name = 'Gateway API'; url = 'https://gateway-api.sigs.k8s.io/' }
    )
    Set-RegValue $edge 'ManagedFavorites' (ConvertTo-Json -InputObject $favorites -Compress) -Type String
    $edgeExe = Get-EdgePath
    $Versions['edge'] = if ($edgeExe) { (Get-Item -LiteralPath $edgeExe).VersionInfo.ProductVersion } else { 'not found' }
    Write-Ready ("Microsoft Edge $($Versions['edge']): no first-run, sync, default-browser, or password prompts; " +
                 "starts on the Azure portal; $LabName favorites folder")
}

# Runs as root inside the distribution: creates the default user with passwordless sudo and no login banners.
$WslUserSetup = @'
set -eu
user="$1"
if ! id -u "$user" >/dev/null 2>&1; then
    if getent passwd 1000 >/dev/null; then
        useradd --create-home --shell /bin/bash --groups sudo "$user"
    else
        useradd --create-home --shell /bin/bash --uid 1000 --groups sudo "$user"
    fi
fi
printf '%s ALL=(ALL) NOPASSWD:ALL\n' "$user" > "/etc/sudoers.d/90-$user"
chmod 0440 "/etc/sudoers.d/90-$user"
touch /etc/wsl.conf
if ! grep -q '^\[user\]' /etc/wsl.conf; then
    printf '\n[user]\ndefault=%s\n' "$user" >> /etc/wsl.conf
elif ! grep -q "^default=$user\$" /etc/wsl.conf; then
    sed -i "/^\[user\]/a default=$user" /etc/wsl.conf
fi
home="$(getent passwd "$user" | cut -d: -f6)"
touch "$home/.hushlogin" "$home/.sudo_as_admin_successful"
chown "$user:$user" "$home/.hushlogin" "$home/.sudo_as_admin_successful"
'@

# Runs as root inside the distribution: the Azure CLI (Microsoft's package repository), and kubectl, kubelogin,
# and Helm from their release locations, checked against their published checksums. The lab's bash scripts
# (deploy.sh, verify.sh) then run in WSL too. Git Bash runs them on Windows with the Windows tools.
$WslToolsSetup = @'
set -eu
kubectl_version="$1"; kubelogin_tag="$2"; helm_tag="$3"; user="$4"
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq --no-install-recommends ca-certificates curl jq git unzip gnupg lsb-release >/dev/null
# WSL appends the Windows PATH, where the Windows Azure CLI's wbin folder has an "az" script, so check the Linux paths.
if [ ! -x /usr/bin/az ]; then
    curl -fsSL https://aka.ms/InstallAzureCLIDeb -o /tmp/install-azure-cli.sh
    bash /tmp/install-azure-cli.sh >/dev/null
    rm -f /tmp/install-azure-cli.sh
fi
work="$(mktemp -d)"
cd "$work"
curl -fsSLO "https://dl.k8s.io/release/${kubectl_version}/bin/linux/amd64/kubectl"
echo "$(curl -fsSL "https://dl.k8s.io/release/${kubectl_version}/bin/linux/amd64/kubectl.sha256")  kubectl" | sha256sum --check --quiet
install -m 0755 kubectl /usr/local/bin/kubectl
curl -fsSLO "https://github.com/Azure/kubelogin/releases/download/${kubelogin_tag}/kubelogin-linux-amd64.zip"
curl -fsSLO "https://github.com/Azure/kubelogin/releases/download/${kubelogin_tag}/kubelogin-linux-amd64.zip.sha256"
echo "$(cut -d' ' -f1 kubelogin-linux-amd64.zip.sha256)  kubelogin-linux-amd64.zip" | sha256sum --check --quiet
unzip -q -o kubelogin-linux-amd64.zip
install -m 0755 bin/linux_amd64/kubelogin /usr/local/bin/kubelogin
helm_archive="helm-${helm_tag}-linux-amd64.tar.gz"
curl -fsSLO "https://get.helm.sh/${helm_archive}"
curl -fsSLO "https://get.helm.sh/${helm_archive}.sha256sum"
echo "$(cut -d' ' -f1 "${helm_archive}.sha256sum")  ${helm_archive}" | sha256sum --check --quiet
tar -xzf "$helm_archive"
install -m 0755 linux-amd64/helm /usr/local/bin/helm
cd /
rm -rf "$work"
sudo -u "$user" -H az config set core.login_experience_v2=off core.collect_telemetry=false core.survey_message=false auto-upgrade.enable=no --only-show-errors >/dev/null
echo "TOOLS: az $(az version --query '"azure-cli"' -o tsv 2>/dev/null) kubectl $(kubectl version --client -o json | jq -r .clientVersion.gitVersion) kubelogin $(kubelogin --version | grep -o 'v[0-9][0-9.]*' | head -n 1) helm $(helm version --short)"
'@

function Install-Wsl {
    # Windows features: WSL 2 needs Virtual Machine Platform, and the WSL 1 fallback needs the Linux subsystem.
    # Get-WindowsOptionalFeature reports a feature as Enabled as soon as it's turned on, but it works only after
    # Windows restarts. RestartNeeded, servicing's pending restart, and the restart marker show whether that's done.
    $request = Get-WslRestartRequest
    $pending = New-Object System.Collections.Generic.List[string]
    foreach ($feature in 'Microsoft-Windows-Subsystem-Linux', 'VirtualMachinePlatform') {
        if ((Get-WindowsOptionalFeature -Online -FeatureName $feature).State -ne 'Enabled') {
            $change = Enable-WindowsOptionalFeature -Online -FeatureName $feature -All -NoRestart -WarningAction SilentlyContinue
            if ($change.RestartNeeded -or (Get-WindowsOptionalFeature -Online -FeatureName $feature).State -ne 'Enabled') {
                $pending.Add($feature)
            }
        }
    }

    # The WSL package at the current release, verified against the digest that GitHub publishes
    $tag = Get-LatestGitHubTag 'microsoft/WSL'
    if ($tag -notmatch '^\d+\.\d+\.\d+$') { throw "Couldn't look up the current WSL release." }
    $installed = Get-WslPackageVersion
    if (-not $installed -or $installed -lt [version]$tag) {
        $msi = Save-GitHubAsset -Repository 'microsoft/WSL' -Tag $tag -AssetName "wsl.$tag.0.x64.msi" -Signer 'Microsoft Corporation'
        Invoke-Installer 'msiexec.exe' "/i `"$msi`" /qn /norestart" -TimeoutMinutes 20
        if ($InstallerExitCode -eq 3010) { $pending.Add('the WSL package') }
    }
    $Versions['wsl'] = [string](Get-WslPackageVersion)
    $registered = (Get-WslDistributions) -contains $WslDistribution
    $reason = ''
    if ($pending.Count -gt 0) {
        $reason = "WSL $($Versions['wsl']) is installed, but Windows must restart to finish setting up $($pending -join ', ')."
    } elseif (-not $registered -and $request -and $request.SameBoot) {
        $reason = "The last run asked for a restart to finish setting up WSL, and Windows hasn't restarted since."
    } elseif (-not $registered -and -not $request -and (Test-Path -LiteralPath $ServicingRestartKey)) {
        $reason = 'Windows has changes that finish only when it restarts, such as Windows features that were just turned on.'
    }
    if ($reason) {
        Request-WslRestart $reason $request
        return
    }

    # The distribution, from the official WSL distribution list. WSL registers distributions per Windows user.
    $linuxUser = Get-WslLinuxUser
    if (-not $registered) {
        $catalog = Invoke-RestMethod -UseBasicParsing -Uri 'https://raw.githubusercontent.com/microsoft/WSL/master/distributions/DistributionInfo.json'
        $entry = @($catalog.ModernDistributions.PSObject.Properties | ForEach-Object { $_.Value } |
                   Where-Object { $_.Name -eq $WslDistribution }) | Select-Object -First 1
        if (-not $entry -or -not $entry.Amd64Url.Url) { throw "The official WSL distribution list doesn't include $WslDistribution." }
        $url = [string]$entry.Amd64Url.Url
        $file = Save-Download -Uri $url -FileName (Split-Path $url -Leaf)
        $actual = (Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash
        if ($actual -ne $entry.Amd64Url.Sha256) {
            throw "Checksum mismatch for $(Split-Path $url -Leaf): expected $($entry.Amd64Url.Sha256), got $actual."
        }
        Write-Host "  Verified $(Split-Path $url -Leaf) against the WSL distribution list."
        $baseLocation = Join-Path $WslRoot $WslDistribution
        $errors = @{}
        foreach ($wslVersion in 2, 1) {
            # The distribution isn't registered, so anything in its folder is left over from a failed attempt.
            $location = $baseLocation
            Remove-Item -LiteralPath $location -Recurse -Force -ErrorAction SilentlyContinue
            if (Test-Path -LiteralPath $location) {
                $location = "$baseLocation-v$wslVersion"
                Remove-Item -LiteralPath $location -Recurse -Force -ErrorAction SilentlyContinue
            }
            New-Item -ItemType Directory -Path $location -Force | Out-Null
            $result = Invoke-Wsl @('--install', '--from-file', $file, '--name', $WslDistribution, '--location', $location,
                                   '--no-launch', '--version', "$wslVersion")
            if ($result.ExitCode -eq 0) {
                $result = Invoke-Wsl @('-d', $WslDistribution, '-u', 'root', '--exec', '/bin/true')
                if ($result.ExitCode -eq 0) { break }
            }
            $errors[$wslVersion] = $result.Text
            Invoke-Wsl @('--unregister', $WslDistribution) | Out-Null
            Invoke-Wsl @('--shutdown') | Out-Null
            if ($wslVersion -eq 2) {
                $code = Get-WslErrorCode $result.Text
                $hint = if ($code -match 'HCS_E_SERVICE_NOT_AVAILABLE') { "Virtual Machine Platform isn't active yet" }
                        else { 'WSL 2 needs nested virtualization turned on in the VM profile' }
                Write-Host "  WSL 2 can't run in this VM ($code). $hint. Trying WSL 1." -ForegroundColor DarkYellow
            }
        }
        if ($errors.ContainsKey(1)) {
            # WSL_E_WSL1_NOT_SUPPORTED: the Windows Subsystem for Linux feature isn't active yet. A restart activates
            # it. After two restarts, something else is wrong, so the script stops asking.
            if ($errors[1] -match 'WSL_E_WSL1_NOT_SUPPORTED' -and (-not $request -or $request.Requests -lt 2)) {
                Request-WslRestart ("The Windows Subsystem for Linux feature is turned on, but Windows hasn't activated it " +
                                    'yet (WSL_E_WSL1_NOT_SUPPORTED).') $request
                return
            }
            throw ("Couldn't install $WslDistribution with WSL 2 ($(Get-WslErrorCode $errors[2])) or WSL 1. " +
                   ($errors[1] -replace '\s+', ' ').Trim())
        }
    }
    Remove-Item -LiteralPath $WslRestartFile -Force -ErrorAction SilentlyContinue

    # Default user with passwordless sudo, so the distribution opens without first-run prompts
    New-Item -ItemType Directory -Path $SetupDir -Force | Out-Null
    $utf8 = New-Object Text.UTF8Encoding($false)
    $userFile = Join-Path $SetupDir 'wsl-user-setup.sh'
    $toolsFile = Join-Path $SetupDir 'wsl-tools-setup.sh'
    [IO.File]::WriteAllText($userFile, ($WslUserSetup -replace "`r`n", "`n"), $utf8)
    [IO.File]::WriteAllText($toolsFile, ($WslToolsSetup -replace "`r`n", "`n"), $utf8)
    $toLinux = { param($Path) '/mnt/' + $Path.Substring(0, 1).ToLowerInvariant() + ($Path.Substring(2) -replace '\\', '/') }
    $result = Invoke-Wsl @('-d', $WslDistribution, '-u', 'root', '--exec', 'bash', (& $toLinux $userFile), $linuxUser)
    if ($result.ExitCode -ne 0) { throw "Setting up the $linuxUser user in $WslDistribution failed. $($result.Text)" }
    Invoke-Wsl @('--terminate', $WslDistribution) | Out-Null
    $result = Invoke-Wsl @('--manage', $WslDistribution, '--set-default-user', $linuxUser)
    if ($result.ExitCode -ne 0) {
        Write-Host "  wsl --manage --set-default-user failed, so /etc/wsl.conf sets the default user. $($result.Text)" -ForegroundColor DarkYellow
    }
    $registration = Get-WslRegistration $WslDistribution
    if ($registration -and $null -ne $registration.RunOOBE) {
        Set-ItemProperty -LiteralPath $registration.PSPath -Name 'RunOOBE' -Value 0
    }
    Invoke-Wsl @('--set-default', $WslDistribution) | Out-Null
    $wslDefault = Get-WslDefaultUser $WslDistribution
    $sudo = Invoke-Wsl @('-d', $WslDistribution, '--exec', 'sudo', '-n', 'true')
    if ($wslDefault -ne $linuxUser -or $sudo.ExitCode -ne 0) {
        throw "$WslDistribution opens as '$wslDefault' instead of $linuxUser, or passwordless sudo failed ($($sudo.Text))."
    }

    # The Linux tools, at the same versions as the Windows ones where they're the same tool
    $kubectlVersion = Get-KubectlVersion (Join-Path $K8sDir 'kubectl.exe')
    $kubeloginTag = Get-LatestGitHubTag 'Azure/kubelogin'
    $helmTag = Get-LatestGitHubTag 'helm/helm'
    Write-Host "  Installing the Azure CLI, kubectl $kubectlVersion, kubelogin $kubeloginTag, Helm $helmTag, and jq in $WslDistribution (a few minutes)."
    $result = Invoke-Wsl @('-d', $WslDistribution, '-u', 'root', '--exec', 'bash', (& $toLinux $toolsFile), $kubectlVersion, $kubeloginTag, $helmTag, $linuxUser)
    $toolsLine = @($result.Text -split "`n" | Where-Object { $_ -match '^TOOLS:' }) | Select-Object -Last 1
    if ($result.ExitCode -ne 0 -or -not $toolsLine) { throw "Installing the Linux tools in $WslDistribution failed. $(($result.Text -split "`n" | Select-Object -Last 8) -join ' ')" }
    $Versions['wslTools'] = $toolsLine.Substring(7).Trim()
    $registration = Get-WslRegistration $WslDistribution
    $Versions['wslDistribution'] = "$WslDistribution on WSL $($registration.Version)"
    Write-Ready ("WSL $($Versions['wsl']) with $WslDistribution on WSL $($registration.Version): default user $linuxUser with " +
                 "passwordless sudo, no first-run prompts; $($Versions['wslTools'])")
}

function Set-LabFolderAndStartup {
    # The lab repository: the challenges' READMEs, the deployment and scoring scripts. The prepare LCA moves it to the
    # event's tag at each launch, so the image's copy only has to be recent.
    New-Item -ItemType Directory -Path (Split-Path -Parent $LabRoot) -Force | Out-Null
    $env:GIT_TERMINAL_PROMPT = '0'
    if (-not (Test-Path -LiteralPath (Join-Path $LabRoot '.git'))) {
        if ((Test-Path -LiteralPath $LabRoot) -and (Get-ChildItem -LiteralPath $LabRoot -Force | Select-Object -First 1)) {
            throw "$LabRoot exists, but it isn't a clone of the lab repository. Move it away, and run the script again."
        }
        Invoke-Native { & $GitExe clone --quiet $RepoUrl $LabRoot 2>&1 } | Out-Host
        if ($LASTEXITCODE -ne 0) { throw "git clone $RepoUrl failed." }
    }
    Invoke-Native { & $GitExe -C $LabRoot fetch --quiet --force $RepoUrl $RepoRef 2>&1 } | Out-Host
    if ($LASTEXITCODE -ne 0) { throw "git fetch of $RepoRef from $RepoUrl failed." }
    Invoke-Native { & $GitExe -C $LabRoot checkout --quiet --force -B lab FETCH_HEAD 2>&1 } | Out-Host
    if ($LASTEXITCODE -ne 0) { throw "git checkout of $RepoRef failed." }
    # The prepare LCA runs git here as SYSTEM, and the attendee as themselves: both must trust the folder.
    $safePath = $LabRoot -replace '\\', '/'
    $trusted = @(Invoke-Native { & $GitExe config --system --get-all safe.directory 2>$null })
    if ($trusted -notcontains $safePath) { Invoke-Native { & $GitExe config --system --add safe.directory $safePath } | Out-Null }
    # No deployment state in the image
    Remove-Item -LiteralPath (Join-Path $LabRoot '.lab') -Recurse -Force -ErrorAction SilentlyContinue
    $Versions['labRepository'] = "$RepoRef at $((Invoke-Native { & $GitExe -C $LabRoot rev-parse --short HEAD }) -join '')"

    # VS Code opens the lab folder at sign-in, and from the Start menu, because the image's VS Code doesn't restore
    # windows. Edge opens the Azure portal.
    $shell = New-Object -ComObject WScript.Shell
    $startup = [Environment]::GetFolderPath('Startup')
    $links = @((Join-Path $startup "$LabName - Visual Studio Code.lnk"))
    $startMenu = Join-Path $env:ProgramData 'Microsoft\Windows\Start Menu\Programs\Visual Studio Code\Visual Studio Code.lnk'
    if (Test-Path -LiteralPath $startMenu) { $links += $startMenu }
    foreach ($path in $links) {
        $link = $shell.CreateShortcut($path)
        $link.TargetPath = $CodeExe
        $link.Arguments = '"' + $LabRoot + '"'
        $link.WorkingDirectory = $LabRoot
        $link.Save()
    }
    $edgeExe = Get-EdgePath
    if ($edgeExe) {
        $edgeLink = $shell.CreateShortcut((Join-Path $startup "$LabName - Microsoft Edge.lnk"))
        $edgeLink.TargetPath = $edgeExe
        $edgeLink.Arguments = $PortalUrl
        $edgeLink.Save()
    }
    Write-Ready ("Lab repository in $LabRoot ($($Versions['labRepository'])), with shortcuts that open VS Code on it and Edge " +
                 'on the Azure portal at sign-in')
}

function Test-Image([switch]$Finalizing) {
    # When finalizing, automatic sign-in and the integration service are required, because the lab depends on them.
    $requiredForCommit = if ($Finalizing) { 'FAIL' } else { 'WARN' }
    $results = New-Object System.Collections.Generic.List[object]
    function Add-Check([string]$Item, [bool]$Passed, [string]$Detail, [string]$Severity = 'FAIL') {
        $results.Add([pscustomobject]@{ Item = $Item; Result = $(if ($Passed) { 'PASS' } else { $Severity }); Detail = $Detail })
    }
    function Test-OnPath([string]$Name, [string]$Expected) {
        $command = Get-Command $Name -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
        return ($command -and $command.Source -eq $Expected)
    }

    $au = Get-ItemProperty 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU' -ErrorAction SilentlyContinue
    $toast = Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\PushNotifications' -ErrorAction SilentlyContinue
    $keyboard = (Get-WinUserLanguageList)[0].LanguageTag
    Add-Check 'Windows settings' ($au.NoAutoUpdate -eq 1 -and $toast.ToastEnabled -eq 0 -and $keyboard -eq 'en-US') `
        "Automatic updates off: $($au.NoAutoUpdate -eq 1). Notifications off: $($toast.ToastEnabled -eq 0). Keyboard: $keyboard."

    $bash = 'C:\Program Files\Git\bin\bash.exe'
    Add-Check 'Git and Git Bash' ((Test-Path $GitExe) -and (Test-Path $bash)) "$(Invoke-Native { & $GitExe --version }). Git Bash: $(Test-Path $bash)."

    $pwshVersion = Get-PwshVersion
    Add-Check 'PowerShell 7' ($pwshVersion -and $pwshVersion -ge $MinPwsh -and (Test-OnPath 'pwsh' $PwshExe)) "Version $pwshVersion (minimum $MinPwsh) from $PwshExe."

    $azConfig = Join-Path $env:USERPROFILE '.azure\config'
    $azSettings = (Test-Path $azConfig) -and (Select-String -LiteralPath $azConfig -Pattern 'login_experience_v2\s*=\s*off' -Quiet) -and
                  (Select-String -LiteralPath $azConfig -Pattern 'enable_broker_on_windows\s*=\s*false' -Quiet)
    $azVersion = Get-AzureCliVersion
    $missingAz = @($AzExtensions | Where-Object { -not (Get-AzExtensionVersion $_) })
    Add-Check 'Azure CLI' ([bool]$azVersion -and [version]$azVersion -ge $MinAzureCli -and $azSettings -and $missingAz.Count -eq 0) `
        ("Version $azVersion (minimum $MinAzureCli). Lab settings in ~\.azure\config: $azSettings. " +
         $(if ($missingAz.Count) { "Missing extensions: $($missingAz -join ', ')." } else { "Extensions: $($AzExtensions -join ', ')." }))

    $k8sTools = 'kubectl', 'kubelogin', 'helm', 'kubectl-gadget', 'ingress2gateway', 'aks-mcp'
    $offPath = @($k8sTools | Where-Object { -not (Test-OnPath $_ (Join-Path $K8sDir "$_.exe")) })
    $kubectlVersion = Get-KubectlVersion (Join-Path $K8sDir 'kubectl.exe')
    Add-Check 'Kubernetes tools' ($offPath.Count -eq 0 -and $kubectlVersion -like "v$KubectlMinor.*") `
        ("kubectl $kubectlVersion. " + $(if ($offPath.Count) { "Missing or not first on the PATH: $($offPath -join ', ')." } else { "All of $($k8sTools -join ', ') in $K8sDir." }))

    $terraformVersion = Get-TerraformVersion
    $checkpointOff = [Environment]::GetEnvironmentVariable('CHECKPOINT_DISABLE', 'Machine') -eq '1'
    Add-Check 'Terraform' ([bool]$terraformVersion -and $checkpointOff -and (Test-OnPath 'terraform' (Join-Path $TerraformDir 'terraform.exe'))) `
        "Version $terraformVersion. Update checks off: $checkpointOff."

    $ghVersion = Get-VersionText $GhExe @('--version')
    Add-Check 'GitHub CLI' ([bool]$ghVersion -and (Test-OnPath 'gh' $GhExe)) "Version $ghVersion from $GhExe."

    $aksDesktop = Get-AksDesktopInstall
    Add-Check 'AKS desktop' ([bool]$aksDesktop) $(if ($aksDesktop) { "$($aksDesktop.Name) in $($aksDesktop.Location)." } else { 'Not installed.' })

    $extensions = if (Test-Path $CodeCmd) { @(Invoke-Native { & $CodeCmd --list-extensions }) } else { @() }
    $missingExtensions = @($CodeExtensions | Where-Object { $extensions -notcontains $_ })
    $settingsOk = $false
    $mcpOk = $false
    try { $settingsOk = ((Get-Content -LiteralPath (Join-Path $env:APPDATA 'Code\User\settings.json') -Raw | ConvertFrom-Json).'workbench.startupEditor' -eq 'none') } catch { }
    try { $mcpOk = ((Get-Content -LiteralPath (Join-Path $env:APPDATA 'Code\User\mcp.json') -Raw | ConvertFrom-Json).servers.'aks-mcp'.command -eq (Join-Path $K8sDir 'aks-mcp.exe')) } catch { }
    $copilot = Get-CopilotChat
    Add-Check 'Visual Studio Code' ((Test-Path $CodeExe) -and $missingExtensions.Count -eq 0 -and [bool]$copilot -and $settingsOk -and $mcpOk) `
        ($(if ($missingExtensions.Count) { "Missing extensions: $($missingExtensions -join ', '). " } else { "Extensions: $($extensions.Count) installed. " }) +
         "Copilot Chat: $(if ($copilot) { $copilot } else { 'missing' }). Lab settings: $settingsOk. AKS-MCP in mcp.json: $mcpOk.")

    $edgePolicy = Get-ItemProperty 'HKLM:\SOFTWARE\Policies\Microsoft\Edge' -ErrorAction SilentlyContinue
    Add-Check 'Microsoft Edge' ($edgePolicy.HideFirstRunExperience -eq 1 -and [bool]$edgePolicy.ManagedFavorites) 'First-run, startup page, and favorites policies'

    if ($RestartItems -contains 'WSL') {
        Add-Check 'WSL' $false 'Restart pending. Restart the VM, and then run the script again.'
    } else {
        $wslPackage = Get-WslPackageVersion
        $registration = Get-WslRegistration $WslDistribution
        $wslDefault = if ($wslPackage -and $registration) { Get-WslDefaultUser $WslDistribution } else { '' }
        $sudoOk = $wslDefault -and (Invoke-Wsl @('-d', $WslDistribution, '--exec', 'sudo', '-n', 'true')).ExitCode -eq 0
        $toolsOk = $wslDefault -and (Invoke-Wsl @('-d', $WslDistribution, '--exec', 'sh', '-c',
            'test -x /usr/bin/az && test -x /usr/local/bin/kubectl && test -x /usr/local/bin/kubelogin && test -x /usr/local/bin/helm')).ExitCode -eq 0
        $oobeOff = $registration -and ($null -eq $registration.RunOOBE -or $registration.RunOOBE -eq 0)
        Add-Check 'WSL' ([bool]$wslPackage -and $wslDefault -eq (Get-WslLinuxUser) -and [bool]$sudoOk -and [bool]$toolsOk -and [bool]$oobeOff) `
            ("Package $wslPackage. $WslDistribution registered: $([bool]$registration). Default user: $wslDefault. " +
             "Passwordless sudo: $([bool]$sudoOk). Linux tools: $([bool]$toolsOk). First-run prompts off: $([bool]$oobeOff).")
        if ($registration) {
            Add-Check 'WSL 2' ($registration.Version -eq 2) ("$WslDistribution runs on WSL $($registration.Version). For WSL 2, turn on " +
                'nested virtualization in the VM profile, run wsl --unregister, and run the script again.') 'WARN'
        }
    }

    $startup = [Environment]::GetFolderPath('Startup')
    $folderOk = (Test-Path (Join-Path $LabRoot 'begin-challenge\challenges')) -and (Test-Path (Join-Path $startup "$LabName - Visual Studio Code.lnk"))
    Add-Check 'Lab folder and startup' $folderOk "$LabRoot (the lab repository) and the startup shortcuts"

    $winlogon = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon'
    $autoSignIn = $winlogon.AutoAdminLogon -eq '1'
    Add-Check 'Automatic sign-in' $autoSignIn $(if ($autoSignIn) { "Signs in as $($winlogon.DefaultUserName)." } `
        else { 'Not configured. Run netplwiz and clear "Users must enter a user name and password to use this computer".' }) $requiredForCommit

    $service = Get-Service -ErrorAction SilentlyContinue | Where-Object {
        $_.Name -match 'VmIntegrationService|Skillable|LabOnDemand|LearnOnDemand' -or
        $_.DisplayName -match '^(Skillable )?Integration Service$|Skillable|Lab ?on ?Demand|Learn ?on ?Demand'
    } | Select-Object -First 1
    $listening = [bool](Get-NetTCPConnection -LocalPort 2724 -State Listen -ErrorAction SilentlyContinue)
    $serviceDetail = if ($service) { "$($service.DisplayName) ($($service.Name)): $($service.Status)." }
                     elseif ($listening) { 'Something is listening on port 2724, the integration service port.' }
                     else { 'Not detected. In the lab client, select Settings > Install Integration Tools, and then restart the VM.' }
    Add-Check 'Skillable integration service' ([bool]$service -or $listening) $serviceDetail $requiredForCommit

    $kubeconfig = Test-Path (Join-Path $env:USERPROFILE '.kube\config')
    $azSignedIn = $false
    if (Test-Path $AzCmd) {
        Invoke-Native { & $AzCmd account show --only-show-errors 2>$null } | Out-Null
        $azSignedIn = ($LASTEXITCODE -eq 0)
    }
    $ghSignedIn = Test-Path (Join-Path $env:APPDATA 'GitHub CLI\hosts.yml')
    Add-Check 'No credentials' (-not $kubeconfig -and -not $azSignedIn -and -not $ghSignedIn) `
        "kubeconfig present: $kubeconfig. Azure CLI signed in: $azSignedIn. GitHub CLI signed in: $ghSignedIn. -Finalize removes them." 'WARN'

    $results | Format-Table -AutoSize -Wrap | Out-String -Width 220 | Write-Host
    return (-not ($results | Where-Object { $_.Result -eq 'FAIL' }))
}

function Save-ImageManifest {
    $os = Get-CimInstance -ClassName Win32_OperatingSystem
    $manifest = [ordered]@{
        lab      = $LabName
        builtAt  = (Get-Date).ToString('o')
        builtBy  = $CurrentUser
        os       = "$($os.Caption) $($os.Version)"
        labRoot  = $LabRoot
        versions = $Versions
    }
    ConvertTo-Json -InputObject $manifest -Depth 5 | Set-Content -LiteralPath (Join-Path $StateDir 'image-manifest.json') -Encoding UTF8
}

function Invoke-Finalize {
    Write-Host '==> Verifying the image before finalizing' -ForegroundColor Cyan
    if (-not (Test-Image -Finalizing) -and -not $Force) {
        Write-Warning 'Fix the failed checks first, or run again with -Force.'
        return $false
    }
    Write-Host '==> Removing credentials, caches, history, and setup files' -ForegroundColor Cyan
    Get-Process -Name msedge, Code -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    $aksDesktop = Get-AksDesktopInstall
    if ($aksDesktop -and $aksDesktop.Location) {
        Get-Process -ErrorAction SilentlyContinue | Where-Object { $_.Path -and $_.Path -like "$($aksDesktop.Location)*" } |
            Stop-Process -Force -ErrorAction SilentlyContinue
    }
    if ((Get-WslDistributions) -contains $WslDistribution) {
        Invoke-Wsl @('-d', $WslDistribution, '-u', 'root', '--exec', 'sh', '-c',
                     'rm -f /root/.bash_history /home/*/.bash_history; rm -rf /home/*/.azure/msal_token_cache* /home/*/.azure/azureProfile.json /home/*/.kube') | Out-Null
    }
    if (Get-WslPackageVersion) { Invoke-Wsl @('--shutdown') | Out-Null }
    Start-Sleep -Seconds 3
    # Azure CLI: sign-ins go; the settings and extensions (aks-agent, k8s-extension) stay.
    if (Test-Path $AzCmd) { Invoke-Native { & $AzCmd account clear --only-show-errors 2>$null } | Out-Null }
    # GitHub CLI and VS Code's GitHub and Microsoft sign-ins (Copilot) in the Windows Credential Manager
    if (Test-Path $GhExe) { Invoke-Native { & $GhExe auth logout --hostname github.com 2>$null } | Out-Null }
    $targets = @(Invoke-Native { cmdkey.exe /list } | ForEach-Object { if ("$_" -match 'Target:\s*(?:\S+:target=)?(.+)$') { $Matches[1].Trim() } } |
                 Where-Object { $_ -match '(?i)vscode|github|^git:|gh:' })
    foreach ($target in $targets) { Invoke-Native { cmdkey.exe "/delete:$target" } | Out-Null }
    foreach ($path in (Join-Path $env:USERPROFILE '.kube'),
                      (Join-Path $env:APPDATA 'GitHub CLI\hosts.yml'),
                      (Join-Path $LabRoot '.lab'),
                      (Join-Path $env:LOCALAPPDATA 'Microsoft\Edge\User Data'),
                      (Join-Path $env:APPDATA 'Code\User\workspaceStorage'),
                      (Join-Path $env:APPDATA 'Code\User\History'),
                      (Join-Path $env:APPDATA 'Code\Backups'),
                      (Join-Path $env:APPDATA 'Microsoft\Windows\PowerShell\PSReadLine')) {
        Remove-Item -LiteralPath $path -Recurse -Force -ErrorAction SilentlyContinue
    }
    foreach ($temp in $env:TEMP, 'C:\Windows\Temp') {
        Get-ChildItem -LiteralPath $temp -Force -ErrorAction SilentlyContinue | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
    }
    Remove-Item -LiteralPath 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\RunMRU' -Recurse -Force -ErrorAction SilentlyContinue
    Clear-RecycleBin -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $DownloadDir -Recurse -Force -ErrorAction SilentlyContinue

    # Confirm the cleanup. -Force doesn't skip this, because a commit keeps whatever is left. The setup folder, which
    # holds this script, goes last, so that -Finalize can run again after a failure.
    $left = New-Object System.Collections.Generic.List[string]
    if (Test-Path $AzCmd) {
        Invoke-Native { & $AzCmd account show --only-show-errors 2>$null } | Out-Null
        if ($LASTEXITCODE -eq 0) { $left.Add('an Azure CLI sign-in') }
    }
    foreach ($path in (Join-Path $env:USERPROFILE '.kube'), (Join-Path $env:APPDATA 'GitHub CLI\hosts.yml'), (Join-Path $LabRoot '.lab')) {
        if (Test-Path -LiteralPath $path) { $left.Add($path) }
    }
    $credentials = @(Invoke-Native { cmdkey.exe /list } | Where-Object { "$_" -match '(?i)Target:.*(vscode|github|git:|gh:)' })
    if ($credentials.Count -gt 0) { $left.Add("$($credentials.Count) GitHub or VS Code credentials in the Credential Manager") }
    if ((Get-WslDistributions) -contains $WslDistribution) {
        # Marker lines, because Invoke-Wsl also returns wsl.exe's own warnings. No double quotes: Windows
        # PowerShell 5.1 doesn't escape them in native arguments.
        $history = Invoke-Wsl @('-d', $WslDistribution, '-u', 'root', '--exec', 'sh', '-c',
                                'for f in /root/.bash_history /home/*/.bash_history /home/*/.azure/msal_token_cache*; do [ -e $f ] && echo LEFT:$f; done; true')
        $files = @($history.Text -split "`n" | Where-Object { $_ -match '^LEFT:' } | ForEach-Object { $_.Substring(5).Trim() })
        if ($files.Count -gt 0) { $left.Add("Linux files ($($files -join ', '))") }
        Invoke-Wsl @('--shutdown') | Out-Null
    }
    if ($left.Count -gt 0) {
        Write-Host "FAILED: The cleanup left $($left -join '; '). Remove them, and then run -Finalize again." -ForegroundColor Red
        return $false
    }
    Remove-Item -LiteralPath $SetupDir -Recurse -Force -ErrorAction SilentlyContinue
    if (Test-Path -LiteralPath $SetupDir) {
        Write-Host "FAILED: Couldn't remove $SetupDir. Delete it, and then shut down the VM before you commit." -ForegroundColor Red
        return $false
    }
    Stop-Service -Name wuauserv -Force -ErrorAction SilentlyContinue
    Write-Ready 'Image finalized: no credentials, caches, history, or setup files'
    return $true
}

$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$CurrentUser = $identity.Name
if (-not ([Security.Principal.WindowsPrincipal]$identity).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'Run this script in an elevated Windows PowerShell window (Run as administrator).'
}
$consoleUser = (Get-CimInstance -ClassName Win32_ComputerSystem).UserName
if ($consoleUser -and $consoleUser -ne $CurrentUser -and -not $Force) {
    throw ("Windows is signed in as $consoleUser, but this script runs as $CurrentUser. Run it as the lab user " +
           'so that per-user settings land in that profile, or add -Force.')
}

New-Item -ItemType Directory -Path $StateDir -Force | Out-Null
Start-Transcript -Path (Join-Path $StateDir ('setup-{0:yyyyMMdd-HHmmss}.log' -f (Get-Date))) | Out-Null
$shutdown = $false
try {
    if ($Finalize) {
        $shutdown = (Invoke-Finalize) -and -not $NoShutdown
    } else {
        $items = [ordered]@{
            'Windows settings'                           = { Set-WindowsExperience }
            'Git'                                        = { Install-Git }
            'PowerShell 7'                               = { Install-PowerShell7 }
            'Azure CLI and extensions'                   = { Install-AzureCli }
            'Kubernetes tools'                           = { Install-KubernetesTools }
            'Terraform'                                  = { Install-Terraform }
            'GitHub CLI'                                 = { Install-GitHubCli }
            'AKS desktop'                                = { Install-AksDesktop }
            'Visual Studio Code, Copilot, and AKS-MCP'   = { Install-VSCode }
            'Microsoft Edge'                             = { Set-EdgePolicies }
            'WSL'                                        = { Install-Wsl }
            'Lab repository and startup shortcuts'       = { Set-LabFolderAndStartup }
        }
        $failed = New-Object System.Collections.Generic.List[string]
        $number = 0
        foreach ($name in $items.Keys) {
            $number++
            Write-Item $number $name
            try {
                & $items[$name]
            } catch {
                $failed.Add($name)
                $where = if ($_.InvocationInfo -and $_.InvocationInfo.ScriptLineNumber) {
                    " (line $($_.InvocationInfo.ScriptLineNumber): $(([string]$_.InvocationInfo.Line).Trim()))" } else { '' }
                Write-Host "FAILED: $name. $($_.Exception.Message)$where" -ForegroundColor Red
            }
        }
        Write-Host ''
        Write-Host '==> Verifying the image' -ForegroundColor Cyan
        $passed = Test-Image
        Save-ImageManifest
        if ($failed.Count -gt 0) {
            Write-Host "Not ready. Failed items: $($failed -join ', '). Fix the cause and run the script again." -ForegroundColor Red
        }
        if ($RestartItems.Count -gt 0) {
            Write-Host "RESTART REQUIRED to finish: $($RestartItems -join ', ')." -ForegroundColor Yellow
            Write-Host 'Restart the VM (Start > Power > Restart). Then open an elevated PowerShell window and run:'
            Write-Host "  powershell -ExecutionPolicy Bypass -File '$PSCommandPath'"
        } elseif ($passed -and $failed.Count -eq 0) {
            Write-Host 'ALL ITEMS READY.' -ForegroundColor Green
            Write-Host 'Next: resolve any WARN rows, and then run this command to finalize and shut down:'
            Write-Host "  powershell -ExecutionPolicy Bypass -File '$PSCommandPath' -Finalize"
        } elseif ($failed.Count -eq 0) {
            Write-Host 'Not ready. Fix the FAIL rows in the table, and then run the script again.' -ForegroundColor Red
        }
    }
} finally {
    Stop-Transcript | Out-Null
}
if ($shutdown) {
    Write-Host 'Shutting down. When the VM is off, commit your changes from the lab client.' -ForegroundColor Cyan
    Stop-Computer -Force
}
