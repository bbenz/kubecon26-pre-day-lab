# -----------------------------------------------------------------------------
# KubeCon AKS capture-the-flag lab - leaderboard reporting for scoring/verify.ps1.
#
# When this machine is registered for an event leaderboard (by the Skillable life cycle action or
# leaderboard/join.ps1), every challenge that verify.ps1 checks is recorded on the leaderboard: one
# small, write-once record per challenge and run, sent with a create-only token. Nothing happens on
# machines that aren't registered. See leaderboard/README.md.
#
# Registration (first match wins):
#   1. environment: CTF_LEADERBOARD_URL, CTF_PLAYER_ID, CTF_PLAYER_NAME
#   2. the file named by CTF_LEADERBOARD_CONFIG
#   3. ~/.kubecon-ctf/leaderboard.env                (leaderboard/join.ps1)
#   4. %ProgramData%\kubecon-ctf\leaderboard.env     (Skillable, Windows VM)
#      /etc/kubecon-ctf/leaderboard.env              (Skillable, Linux VM)
# -----------------------------------------------------------------------------

$script:Lb = $null

# Value of KEY=value in a registration file (the file is parsed, never executed).
function Get-LbConfigValue([string]$Path, [string]$Key) {
    foreach ($line in Get-Content -LiteralPath $Path -ErrorAction SilentlyContinue) {
        if ($line -match "^$Key=(.*)$") { return $Matches[1].Trim() }
    }
    return ''
}

function Initialize-Leaderboard([bool]$Disabled, [bool]$Quick) {
    $script:Lb = $null
    $url = [string]$env:CTF_LEADERBOARD_URL
    $id = [string]$env:CTF_PLAYER_ID
    $name = [string]$env:CTF_PLAYER_NAME
    if (-not $url) {
        $candidates = @($env:CTF_LEADERBOARD_CONFIG, (Join-Path $HOME '.kubecon-ctf/leaderboard.env'))
        if ($env:ProgramData) { $candidates += (Join-Path $env:ProgramData 'kubecon-ctf/leaderboard.env') }
        $candidates += '/etc/kubecon-ctf/leaderboard.env'
        $file = $candidates | Where-Object { $_ -and (Test-Path -LiteralPath $_ -PathType Leaf) } | Select-Object -First 1
        if (-not $file) { return }
        $url = Get-LbConfigValue $file 'CTF_LEADERBOARD_URL'
        if (-not $id) { $id = Get-LbConfigValue $file 'CTF_PLAYER_ID' }
        if (-not $name) { $name = Get-LbConfigValue $file 'CTF_PLAYER_NAME' }
    }
    if (-not $url) { return }    # this machine isn't registered for a leaderboard
    if ($Disabled) { Write-Host 'Leaderboard: not recording this run (-NoReport)'; return }
    if ($Quick) { Write-Host 'Leaderboard: -Quick runs are not recorded - run without -Quick to record your result'; return }
    if ($url -notmatch '^https://[^?]+\?.+') {
        Write-Warning 'Leaderboard: CTF_LEADERBOARD_URL must be https://<account>.blob.core.windows.net/<container>?<token> - not recording'
        return
    }
    if ($id -notmatch '^[A-Za-z0-9._-]{1,64}$') { Write-Warning 'Leaderboard: missing or invalid CTF_PLAYER_ID - not recording'; return }
    if (-not $name) { $name = "Player $($id.Substring([Math]::Max(0, $id.Length - 4)))" }
    if ($name.Length -gt 40) { $name = $name.Substring(0, 40) }
    $base, $token = $url -split '\?', 2
    $script:Lb = @{ Base = $base.TrimEnd('/'); Token = $token; Id = $id; Name = $name }
    Write-Host "Leaderboard: recording results for '$name' (-NoReport to skip)"
}

# Records one challenge result. Never fails the verification: problems are reported as a single line.
function Send-LeaderboardResult([string]$Challenge, [bool]$Passed, [int]$ChecksPassed, [int]$ChecksTotal) {
    if (-not $script:Lb) { return }
    $lb = $script:Lb
    $stamp = (Get-Date).ToUniversalTime().ToString('yyyyMMddTHHmmssZ')
    # Write-once: every run creates a new record; the token can't overwrite or delete anything.
    $blob = 'results/{0}/{1}/{2}-{3}.json' -f $lb.Id, $Challenge, $stamp, (Get-Random -Minimum 100000 -Maximum 999999)
    $uri = '{0}/{1}?{2}' -f $lb.Base, $blob, $lb.Token
    $passedText = if ($Passed) { 'true' } else { 'false' }
    $headers = @{
        'x-ms-blob-type'   = 'BlockBlob'
        'x-ms-meta-player' = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($lb.Name))
        'x-ms-meta-passed' = $passedText
        'x-ms-meta-checks' = "$ChecksPassed/$ChecksTotal"
    }
    $body = [ordered]@{
        player = $lb.Id; challenge = $Challenge; passed = $Passed; checks = "$ChecksPassed/$ChecksTotal"
        client_time = $stamp; verifier = 'pwsh'
    } | ConvertTo-Json -Compress
    $status = 0; $code = ''
    for ($try = 1; $try -le 3; $try++) {
        $code = ''
        try {
            $r = Invoke-WebRequest -Method Put -Uri $uri -Headers $headers -Body $body -ContentType 'application/json' `
                -TimeoutSec 15 -SkipHttpErrorCheck -UseBasicParsing
            $status = [int]$r.StatusCode
            if ("$($r.Content)" -match '<Code>([^<]+)</Code>') { $code = $Matches[1] }
        }
        catch { $status = 0; $code = $_.Exception.Message }
        if ($status -ne 0 -and $status -ne 408 -and $status -ne 429 -and $status -lt 500) { break }
        if ($try -lt 3) { Start-Sleep -Seconds (2 * $try) }
    }
    if ($status -eq 201) {
        if ($Passed) {
            Write-Host '  >> leaderboard:' -ForegroundColor Green -NoNewline
            Write-Host " flag recorded for $($lb.Name)"
        }
        else { Write-Host "  >> leaderboard: progress recorded for $($lb.Name) ($ChecksPassed/$ChecksTotal checks)" }
    }
    else {
        $detail = if ($code) { " $code" } else { '' }
        Write-Host "  >> leaderboard: not recorded (HTTP $status$detail) - your result above still stands; tell a proctor if this keeps happening" -ForegroundColor Red
    }
}
