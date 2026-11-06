<#
.SYNOPSIS
    KubeCon AKS capture-the-flag lab: join the event's leaderboard from this machine.

.DESCRIPTION
    At an event with a leaderboard, scoring/verify.ps1 and verify.sh record each check that they run without -Quick
    on it. This script registers this machine:

      1. It gets the leaderboard's submit URL from the event's registration link (https://aka.ms/aksctfsecrets),
         which the event team points at a small text file. The file is only read, never run, and the URL must be
         an Azure Storage address with a token that can only add results, and hasn't expired.
      2. It tests the URL with one write, which the leaderboard doesn't show.
      3. It saves the URL with your player ID and the name that the leaderboard shows in
         ~/.kubecon-ctf/leaderboard.env, or in the file that CTF_LEADERBOARD_CONFIG names.

    In the hosted lab, the lab instructions pass your Skillable user ID and name. The leaderboard shows your first
    name and last initial. Without a name, the script asks for one. Run it with -Remove to leave.

    Exit codes: 0 joined (or removed), 1 couldn't join, 2 a parameter isn't valid, 3 no leaderboard is open.

.EXAMPLE
    ./scoring/join-leaderboard.ps1 -FirstName Brian -LastName Benz
.EXAMPLE
    ./scoring/join-leaderboard.ps1 -Name 'Team Kube'
.EXAMPLE
    ./scoring/join-leaderboard.ps1 -Remove
#>
#Requires -Version 7.4
[CmdletBinding(DefaultParameterSetName = 'Join')]
param(
    [Parameter(ParameterSetName = 'Join')][string]$FirstName,
    [Parameter(ParameterSetName = 'Join')][string]$LastName,
    # The name that the leaderboard shows, instead of the first name and last initial: letters, digits, spaces, and
    # . ' - (24 characters at most).
    [Parameter(ParameterSetName = 'Join')][string]$Name,
    # Keeps your results together when you relaunch the lab. Default: the ID already registered here, or a new one.
    [Parameter(ParameterSetName = 'Join')][string]$PlayerId,
    # The event's registration link.
    [Parameter(ParameterSetName = 'Join')][string]$From = 'https://aka.ms/aksctfsecrets',
    # The submit URL itself, instead of the registration link.
    [Parameter(ParameterSetName = 'Join')][string]$SubmitUrl,
    [Parameter(Mandatory, ParameterSetName = 'Remove')][switch]$Remove
)
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$file = if ($env:CTF_LEADERBOARD_CONFIG) { $env:CTF_LEADERBOARD_CONFIG } else { Join-Path $HOME '.kubecon-ctf/leaderboard.env' }

function Stop-Join([string]$Message, [int]$Code = 1) {
    Write-Host $Message -ForegroundColor $(if ($Code -eq 3) { 'Yellow' } else { 'Red' })
    exit $Code
}

# A value that a Skillable replacement token didn't fill in (@lab....) counts as missing.
function Test-Given([string]$Value) { return ($Value.Trim() -and $Value.Trim() -notmatch '^@\s*lab\.') }

function ConvertTo-BoardName([string]$Text) {
    $clean = (($Text -replace "[^\p{L}\p{Nd} .'-]", '') -replace '\s+', ' ').Trim()
    if ($clean.Length -gt 24) { $clean = $clean.Substring(0, 24).Trim() }
    return $clean
}

# The text at an address, after redirects such as the registration link's, and the final address.
function Get-WebText([string]$Uri) {
    $r = Invoke-WebRequest -Uri $Uri -UseBasicParsing -TimeoutSec 20 -SkipHttpErrorCheck
    $text = if ($r.Content -is [byte[]]) { [Text.Encoding]::UTF8.GetString($r.Content) } else { [string]$r.Content }
    return [pscustomobject]@{ Status = [int]$r.StatusCode; Text = $text; Final = [string]$r.BaseResponse.RequestMessage.RequestUri }
}

if ($Remove) {
    if (Test-Path -LiteralPath $file) { Remove-Item -LiteralPath $file; Write-Host "Left the leaderboard: removed $file. Your checks are no longer recorded." }
    else { Write-Host "This machine isn't registered for a leaderboard ($file doesn't exist)." }
    exit 0
}

# 1. The name that the leaderboard shows, and the player ID
if (-not (Test-Given $Name)) {
    $first = if (Test-Given $FirstName) { $FirstName.Trim() } else { '' }
    $initial = if (Test-Given $LastName) { $LastName.Trim() -replace '[^\p{L}]', '' } else { '' }
    $Name = if ($first -and $initial) { "$first $($initial.Substring(0, 1))." } else { $first }
}
$boardName = ConvertTo-BoardName $Name
if (-not $boardName) {
    try { $boardName = ConvertTo-BoardName (Read-Host 'Name to show on the leaderboard, such as your first name and last initial') }
    catch { Stop-Join 'Pass -Name, or -FirstName and -LastName.' 2 }
    if (-not $boardName) { Stop-Join 'The name must have letters or digits.' 2 }
}
$PlayerId = if (Test-Given $PlayerId) { $PlayerId.Trim() -replace '[^A-Za-z0-9._-]', '' } else { '' }
if (-not $PlayerId -and (Test-Path -LiteralPath $file)) {
    foreach ($line in Get-Content -LiteralPath $file) { if ($line -match '^CTF_PLAYER_ID=(.+)$') { $PlayerId = $Matches[1].Trim() } }
}
if (-not $PlayerId) { $PlayerId = [guid]::NewGuid().ToString('N') }
if ($PlayerId -notmatch '^[A-Za-z0-9._-]{1,64}$') { Stop-Join 'The player ID must be 1 to 64 letters, digits, and . _ -' 2 }

# 2. The submit URL, from the registration link
if (-not $SubmitUrl) {
    if ($From -notmatch '^https://') { Stop-Join "The registration link must start with https://: $From" 2 }
    try {
        $reg = Get-WebText $From
        # A link to a gist's page instead of its file: read the file.
        if ($reg.Text -notmatch '(?m)^CTF_LEADERBOARD_URL=' -and $reg.Final -match '^https://gist\.github\.com/[^/?#]+/[0-9a-fA-F]+/?$') {
            $reg = Get-WebText ($reg.Final.TrimEnd('/') + '/raw')
        }
        # GitHub caches a gist's file for up to 5 minutes: a unique query string reads the newest version.
        if ($reg.Final -match '^https://gist\.githubusercontent\.com/[^?#]+$') {
            $reg = Get-WebText "$($reg.Final)?nocache=$([guid]::NewGuid().ToString('N'))"
        }
    }
    catch { Stop-Join "Couldn't read the leaderboard's registration link, ${From}: $($_.Exception.Message) Check this machine's internet connection, or ask a proctor." }
    if ($reg.Text -notmatch '(?m)^CTF_LEADERBOARD_URL=(.*)$') {
        if ($reg.Final -match '^https://www\.bing\.com/.*[?&]shorturl=') { Stop-Join "The leaderboard's registration link, $From, isn't set up yet. Ask a proctor." 3 }
        Stop-Join "$From doesn't have the leaderboard's registration (HTTP $($reg.Status) from $($reg.Final)). Ask a proctor."
    }
    $SubmitUrl = $Matches[1].Trim()
    if (-not $SubmitUrl) { Stop-Join 'No leaderboard is open right now. Your checks work the same. If your proctor says that one is open, run this again in a few minutes.' 3 }
}

# 3. Only a create-only token for Azure Storage, that hasn't expired
if ($SubmitUrl -notmatch '^https://[a-z0-9]{3,24}\.blob\.core\.windows\.net/[a-z0-9-]{3,63}\?\S*sig=') {
    Stop-Join "The leaderboard's submit URL isn't an Azure Storage address with a token, so this machine isn't registered. Ask a proctor."
}
$query = @{}
foreach ($pair in ($SubmitUrl -split '\?', 2)[1] -split '&') {
    $key, $value = $pair -split '=', 2
    $query[$key] = [Uri]::UnescapeDataString([string]$value)
}
if ($query['sp'] -ne 'c') {
    Stop-Join "The leaderboard's token can do more than add results (permissions '$($query['sp'])'), so this machine isn't registered. Ask a proctor."
}
$expires = [DateTimeOffset]::MinValue
if ($query['se'] -and [DateTimeOffset]::TryParse($query['se'], [Globalization.CultureInfo]::InvariantCulture,
        [Globalization.DateTimeStyles]::AssumeUniversal, [ref]$expires) -and $expires -le [DateTimeOffset]::UtcNow) {
    Stop-Join "The leaderboard's token expired at $($expires.UtcDateTime.ToString('yyyy-MM-dd HH:mm')) UTC, so this machine isn't registered. Ask a proctor."
}

# 4. One test write, to health/, which the leaderboard doesn't show
$base, $token = $SubmitUrl -split '\?', 2
$probe = '{0}/health/join-{1}-{2}.txt?{3}' -f $base.TrimEnd('/'), $PlayerId, (Get-Date).ToUniversalTime().ToString('yyyyMMddTHHmmssZ'), $token
$status = 0; $code = ''
try {
    $r = Invoke-WebRequest -Method Put -Uri $probe -Headers @{ 'x-ms-blob-type' = 'BlockBlob' } -Body 'join' -ContentType 'text/plain' `
        -UseBasicParsing -TimeoutSec 15 -SkipHttpErrorCheck
    $status = [int]$r.StatusCode
    if ("$($r.Content)" -match '<Code>([^<]+)</Code>') { $code = " $($Matches[1])" }
}
catch { $code = " $($_.Exception.Message)" }
if ($status -ne 201) {
    Stop-Join "The leaderboard didn't accept a test entry (HTTP $status$code), so this machine isn't registered. Your checks work the same. Tell a proctor."
}

# 5. Save the registration, which scoring/verify.ps1 and verify.sh read
New-Item -ItemType Directory -Force -Path (Split-Path -Parent $file) | Out-Null
$lines = @(
    '# KubeCon CTF leaderboard registration - written by scoring/join-leaderboard.ps1'
    "CTF_LEADERBOARD_URL=$SubmitUrl"
    "CTF_PLAYER_ID=$PlayerId"
    "CTF_PLAYER_NAME=$boardName"
)
[IO.File]::WriteAllText($file, ($lines -join "`n") + "`n", [Text.UTF8Encoding]::new($false))
Write-Host "Joined the leaderboard as '$boardName'." -ForegroundColor Green
Write-Host 'Each check that you run without -Quick now records your result there. -NoReport keeps a check off it, and -Remove leaves.'
