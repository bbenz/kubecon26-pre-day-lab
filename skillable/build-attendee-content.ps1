<#
.SYNOPSIS
    Builds what attendees get in the Skillable lab from this repository: the lab instructions, and the attendee
    folder on the lab VM (C:\lab-resources). Neither has the solutions.

.DESCRIPTION
    The repository stays the single source of truth. Each challenge's README.md is the attendee's instructions;
    its SOLUTION.md, the README's feasibility assessment, and challenge-end-state are for proctors. This script
    derives the attendee content from the same files, so a change to a challenge is made once:

      -LabSteps      Writes "skillable lab steps.md", for Skillable Studio, from attendee\lab-steps-template.md
                     and the challenges' README.md files.
      -Destination   Builds the attendee folder: each challenge's README.md, manifests, and settings; the scripts
                     that reset a challenge (deploy.ps1) and check it (verify.ps1); and attendee\README.md,
                     check.ps1, and reset.ps1. The prepare LCA runs it in each lab VM, with C:\lab-resources.
      -Check         Fails if "skillable lab steps.md" is out of date, or if the lab steps or an attendee folder
                     (built in a temporary folder) have solution content. Run it before you commit.

    From each README.md, it removes the facilitator rows of the header table and the feasibility assessment,
    points the check and reset commands at C:\lab-resources, and notes that the lab VM has ingress2gateway. For
    Skillable, it also turns the hints into collapsible sections. The other files in a challenge folder go to
    the attendee folder as they are, except SOLUTION.md, and the comments in *.env files.

.EXAMPLE
    ./skillable/build-attendee-content.ps1 -LabSteps

.EXAMPLE
    ./skillable/build-attendee-content.ps1 -Check

.EXAMPLE
    ./skillable/build-attendee-content.ps1 -Destination C:\lab-resources
#>
#Requires -Version 7.4
[CmdletBinding()]
param(
    # Write "skillable lab steps.md".
    [switch]$LabSteps,
    # Build the attendee folder here, such as C:\lab-resources. Existing attendee content is replaced, except setup-logs.
    [string]$Destination,
    # Check the lab steps and a freshly built attendee folder. The default when no other switch is given.
    [switch]$Check
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 3.0

$RepoRoot      = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$ChallengeRoot = Join-Path $RepoRoot 'begin-challenge\challenges'
$AttendeeSrc   = Join-Path $PSScriptRoot 'attendee'
$LabStepsPath  = Join-Path $PSScriptRoot 'skillable lab steps.md'
# Where the attendee folder is on the lab VM. The commands in the instructions use it.
$LabFolder     = 'C:\lab-resources'
# The repository's files that the attendee folder needs besides the challenge folders.
$RepoFiles = @(
    @{ Folder = 'begin-challenge\azure-cli-powershell'; Include = @('deploy.ps1') },
    @{ Folder = 'shared\azure-cli-powershell'; Include = @('*.ps1', '*.psm1') },
    @{ Folder = 'scoring'; Include = @('verify.ps1') },
    @{ Folder = 'scoring\lib'; Include = @('*.ps1') }
)
# What an attendee folder can hold. setup-logs (the LCA's logs) and .lab (deploy.ps1's rendered manifests) are kept.
$FolderEntries = 'README.md', 'check.ps1', 'reset.ps1', 'lab-settings.json', 'begin-challenge', 'shared', 'scoring', 'setup-logs', '.lab'
# Text that attendee documents must not have.
$Leaks = [ordered]@{
    'mentions solutions'          = '(?i)\bsolution'
    'mentions a walkthrough'      = '(?i)\bwalk-?through'
    'mentions facilitators'       = '(?i)\bfacilitator'
    'mentions the end state'      = '(?i)\bend[- ]state\b'
    'has evaluation notes'        = '(?i)\bfeasib|\bevaluation notes\b|\bdesign target\b|\bproposed core\b|\bpilot\b'
    'mentions the seeded fault'   = '(?i)\bseeded fault'
    'links to the lab repository' = '(?i)github\.com/[^/\s]+/kubecon26-pre-day-lab|aka\.ms/kubecon26'
}

function Read-Text([string]$Path) { return ([IO.File]::ReadAllText($Path) -replace "`r`n", "`n") }

function Write-Text([string]$Path, [string]$Text) {
    New-Item -ItemType Directory -Path (Split-Path -Parent $Path) -Force | Out-Null
    [IO.File]::WriteAllText($Path, $Text, [Text.UTF8Encoding]::new($false))
}

function Get-TableValue([string[]]$Lines, [string]$Row, [string]$Source) {
    foreach ($line in $Lines) {
        if ($line -match "^\|\s*\*\*$Row\*\*\s*\|\s*(.+?)\s*\|\s*$") { return $Matches[1] }
    }
    throw "$Source has no '$Row' row in its header table."
}

function Get-Challenges {
    $list = foreach ($dir in Get-ChildItem -LiteralPath $ChallengeRoot -Directory) {
        if ($dir.Name -notmatch '^([ca])(\d+)-') { throw "Unexpected folder $($dir.FullName): challenge folders start with c<number>- or a<number>-." }
        $order = $(if ($Matches[1] -eq 'c') { 0 } else { 100 }) + [int]$Matches[2]
        $readme = Join-Path $dir.FullName 'README.md'
        $lines = (Read-Text $readme) -split "`n"
        if ($lines[0] -notmatch '^#\s+([CA]\d+)\s+\S\s+(.+?)\s*$') { throw "$readme doesn't start with '# <ID> <separator> <title>'." }
        $name = $Matches[2]
        $time = Get-TableValue $lines 'Investigation time \(design target\)' $readme
        [pscustomobject]@{
            Id        = ($dir.Name -split '-')[0]
            Order     = $order
            Folder    = $dir.Name
            Dir       = $dir.FullName
            Readme    = $readme
            Title     = ($lines[0] -replace '^#\s+', '').Trim()
            Name      = $name
            Namespace = Get-TableValue $lines 'Namespace' $readme
            ShortTime = ($time -split ',')[0].Trim()
        }
    }
    return @($list | Sort-Object Order)
}

function Get-CheckText([string]$Id, [string]$Format) {
    $command = "$LabFolder\check.ps1 $Id"
    if ($Format -eq 'Skillable') { return @('', 'Check your work:', '', "+++$command+++", '') }
    return @('', 'Check your work in the VS Code terminal:', '', '```powershell', $command, '```', '')
}

function Get-ResetText([string]$Id, [string]$Format, [string]$Comment, [string[]]$Prose) {
    $command = "$LabFolder\reset.ps1 $Id"
    $text = [Collections.Generic.List[string]]::new()
    $text.AddRange([string[]]@('', 'To start this challenge over, run the following command, and confirm. Your changes to this challenge are lost.', ''))
    if ($Format -eq 'Skillable') { $text.Add("+++$command+++") } else { $text.AddRange([string[]]@('```powershell', $command, '```')) }
    $text.Add('')
    # The comment on the README's deploy.sh line says what else the reset does, without bash options.
    $note = ($Comment -replace '\s*\([^)]*--[^)]*\)', '').Trim().TrimEnd('.')
    $sentence = if (-not $note) { 'The reset re-creates the challenge with its fault.' }
                elseif ($note -match '^also\s') { "The reset re-creates the challenge with its fault, and $note." }
                else { "The reset $note." }
    $text.AddRange([string[]]@($sentence, ''))
    foreach ($line in $Prose) { $text.Add($line) }
    $text.Add('')
    return $text
}

function Get-ToolNote([string]$Format) {
    if ($Format -eq 'Skillable') { return @('', 'Your lab VM already has `ingress2gateway`. To check, run:', '', '+++ingress2gateway version+++', '') }
    return @('', 'The lab VM already has `ingress2gateway`: run `ingress2gateway version` to check.', '')
}

# A challenge README.md, without what only proctors may see. Format: Skillable (the lab steps) or Folder (the
# README.md in the attendee folder).
function ConvertTo-AttendeeMarkdown([object]$Challenge, [string]$Format) {
    $lines = [Collections.Generic.List[string]]::new([string[]]((Read-Text $Challenge.Readme) -split "`n"))
    $cut = $lines.FindIndex([Predicate[string]] { param($l) $l -match '^##\s+Feasibility' })
    if ($cut -ge 0) { $lines.RemoveRange($cut, $lines.Count - $cut) }
    while ($lines.Count -gt 0 -and ($lines[$lines.Count - 1] -match '^\s*$' -or $lines[$lines.Count - 1] -match '^---\s*$')) {
        $lines.RemoveAt($lines.Count - 1)
    }

    $out = [Collections.Generic.List[string]]::new()
    $section = ''
    $resetComment = ''
    $resetProse = [Collections.Generic.List[string]]::new()
    $toolNote = $false
    $closeSection = {
        if ($section -eq 'Success criteria') { $out.AddRange([string[]](Get-CheckText $Challenge.Id $Format)) }
        if ($section -eq 'Reset') { $out.AddRange([string[]](Get-ResetText $Challenge.Id $Format $resetComment $resetProse)) }
    }
    $i = 0
    while ($i -lt $lines.Count) {
        $line = $lines[$i]
        if ($line -match '^\s*```') {
            $end = $i + 1
            while ($end -lt $lines.Count -and $lines[$end] -notmatch '^\s*```\s*$') { $end++ }
            if ($end -ge $lines.Count) { throw "$($Challenge.Readme): the code block on line $($i + 1) isn't closed." }
            $block = [string[]]$lines.GetRange($i, $end - $i + 1)
            $body = ($block[1..($block.Count - 1)]) -join "`n"
            $i = $end + 1
            if ($body -match 'verify\.(sh|ps1)') { continue }
            if ($section -eq 'Reset') {
                if ($body -match '(?m)deploy\.sh[^\n#]*#\s*(.+)$') { $resetComment = $Matches[1].Trim() }
                continue
            }
            if ($body -match 'ingress2gateway/releases/download|brew install ingress2gateway') {
                if (-not $toolNote) { $out.AddRange([string[]](Get-ToolNote $Format)); $toolNote = $true }
                continue
            }
            $out.AddRange($block)
            continue
        }
        $i++
        if ($line -match '^##\s+(.+?)\s*$') {
            . $closeSection
            $section = $Matches[1]
            $out.Add($line)
            continue
        }
        if ($section -eq 'Reset') {
            if ($line.Trim()) { $resetProse.Add($line) }
            continue
        }
        if ($line -match '^\|\s*\*\*(Round|Walkthrough to the end state)\*\*\s*\|') { continue }
        if ($line -match '^Check your work\b') { continue }
        $out.Add(($line -replace '\*\*Investigation time \(design target\)\*\*', '**Suggested time**'))
    }
    . $closeSection
    $result = if ($Format -eq 'Skillable') { ConvertTo-SkillableHints $out $Challenge.Readme } else { $out }
    return (Format-Lines $result)
}

# <details><summary>Hint N - title</summary> ... </details> becomes a Skillable collapsible section.
function ConvertTo-SkillableHints([string[]]$Lines, [string]$Source) {
    $result = [Collections.Generic.List[string]]::new()
    $i = 0
    while ($i -lt $Lines.Count) {
        if ($Lines[$i] -notmatch '^<details>\s*<summary>(.+?)</summary>\s*$') {
            $result.Add($Lines[$i])
            $i++
            continue
        }
        $title = $Matches[1].Trim()
        $end = $i + 1
        while ($end -lt $Lines.Count -and $Lines[$end] -notmatch '^</details>\s*$') { $end++ }
        if ($end -ge $Lines.Count) { throw "${Source}: the hint '$title' isn't closed by a </details> line." }
        $body = [Collections.Generic.List[string]]::new()
        for ($j = $i + 1; $j -lt $end; $j++) { $body.Add($Lines[$j]) }
        while ($body.Count -gt 0 -and -not $body[0].Trim()) { $body.RemoveAt(0) }
        while ($body.Count -gt 0 -and -not $body[$body.Count - 1].Trim()) { $body.RemoveAt($body.Count - 1) }
        $result.AddRange([string[]]@("> [+Hint] $title", '>'))
        foreach ($line in $body) { $result.Add($(if ($line.Trim()) { "> $line" } else { '>' })) }
        $result.Add('')
        $i = $end + 1
    }
    return $result
}

# One blank line at most between blocks, outside code blocks; none at the start or the end.
function Format-Lines([string[]]$Lines) {
    $result = [Collections.Generic.List[string]]::new()
    $inCode = $false
    foreach ($line in $Lines) {
        if ($line -match '^\s*(>\s*)?```') { $inCode = -not $inCode }
        if (-not $inCode -and -not $line.Trim()) {
            if ($result.Count -eq 0 -or -not $result[$result.Count - 1].Trim()) { continue }
            $result.Add('')
            continue
        }
        $result.Add($line)
    }
    while ($result.Count -gt 0 -and -not $result[$result.Count - 1].Trim()) { $result.RemoveAt($result.Count - 1) }
    return $result
}

function Get-ChallengeTable([object[]]$Challenges, [bool]$Links) {
    $rows = [Collections.Generic.List[string]]::new()
    $rows.AddRange([string[]]@('| ID | Challenge | Namespace | Suggested time |', '|:--|:--|:--|:--|'))
    foreach ($c in $Challenges) {
        $name = if ($Links) { "[$($c.Name)](begin-challenge/challenges/$($c.Folder)/README.md)" } else { $c.Name }
        $rows.Add("| $($c.Id.ToUpperInvariant()) | $name | $($c.Namespace) | $($c.ShortTime) |")
    }
    return ($rows -join "`n")
}

# The AKS Automatic tips from begin-challenge\README.md.
function Get-AksAutomaticTips {
    $source = Join-Path $RepoRoot 'begin-challenge\README.md'
    $lines = (Read-Text $source) -split "`n"
    $start = [Array]::FindIndex($lines, [Predicate[string]] { param($l) $l -match '^###\s+Troubleshooting tips for AKS Automatic' })
    if ($start -lt 0) { throw "$source has no 'Troubleshooting tips for AKS Automatic' section." }
    $end = $start + 1
    while ($end -lt $lines.Count -and $lines[$end] -notmatch '^#{1,3}\s') { $end++ }
    $text = ($lines[($start + 1)..($end - 1)] -join "`n").Trim()
    return ($text -replace 'includes the tools its\s+walkthrough needs', 'includes the tools you need')
}

function Set-Placeholder([string]$Text, [string]$Name, [string]$Value) {
    $pattern = "(?m)^<!-- @$([regex]::Escape($Name)) -->[ \t]*$"
    if ($Text -notmatch $pattern) { throw "The template has no '<!-- @$Name -->' line." }
    return [regex]::Replace($Text, $pattern, $Value.Replace('$', '$$'))
}

function Remove-TemplateComment([string]$Text) { return [regex]::Replace($Text, '(?s)\A<!-- TEMPLATE:.*?-->\n', '') }

function New-LabSteps([object[]]$Challenges) {
    $text = Remove-TemplateComment (Read-Text (Join-Path $AttendeeSrc 'lab-steps-template.md'))
    $pages = foreach ($c in $Challenges) { (ConvertTo-AttendeeMarkdown $c 'Skillable') -join "`n" }
    $text = Set-Placeholder $text 'challenge-table' (Get-ChallengeTable $Challenges $false)
    $text = Set-Placeholder $text 'aks-automatic-tips' (Get-AksAutomaticTips)
    $text = Set-Placeholder $text 'challenges' ($pages -join "`n`n===`n`n")
    return ((Format-Lines ($text -split "`n")) -join "`n") + "`n"
}

function New-AttendeeReadme([object[]]$Challenges) {
    $text = Remove-TemplateComment (Read-Text (Join-Path $AttendeeSrc 'README.md'))
    $text = Set-Placeholder $text 'challenge-table' (Get-ChallengeTable $Challenges $true)
    $text = Set-Placeholder $text 'aks-automatic-tips' (Get-AksAutomaticTips)
    return ((Format-Lines ($text -split "`n")) -join "`n") + "`n"
}

function Find-Leaks([string]$Text) {
    foreach ($name in $Leaks.Keys) {
        $m = [regex]::Match($Text, $Leaks[$name])
        if ($m.Success) {
            $start = [Math]::Max(0, $m.Index - 30)
            $snippet = ($Text.Substring($start, [Math]::Min(80, $Text.Length - $start)) -replace '\s+', ' ').Trim()
            "$name ('$snippet')"
        }
    }
}

function Test-LabSteps([string]$Text, [object[]]$Challenges) {
    $problems = [Collections.Generic.List[string]]::new()
    foreach ($leak in @(Find-Leaks $Text)) { $problems.Add("The lab steps: $leak.") }
    foreach ($m in [regex]::Matches($Text, '\]\((?!https?://)([^)\s]+)\)')) { $problems.Add("The lab steps link to $($m.Groups[1].Value), which attendees don't have.") }
    if ($Text -match '<details|</summary>|<!-- @|<!-- TEMPLATE') { $problems.Add('The lab steps have a hint or a placeholder that was not converted.') }
    foreach ($c in $Challenges) {
        foreach ($expected in "# $($c.Title)", "+++$LabFolder\check.ps1 $($c.Id)+++", "+++$LabFolder\reset.ps1 $($c.Id)+++") {
            if (-not $Text.Contains($expected)) { $problems.Add("The lab steps have no '$expected'.") }
        }
    }
    return $problems
}

function Test-AttendeeFolder([string]$Path, [object[]]$Challenges) {
    $problems = [Collections.Generic.List[string]]::new()
    $expected = @('README.md', 'check.ps1', 'reset.ps1', 'begin-challenge\azure-cli-powershell\deploy.ps1', 'scoring\verify.ps1',
                  'shared\azure-cli-powershell\CtfLab.psm1')
    foreach ($c in $Challenges) { $expected += "begin-challenge\challenges\$($c.Folder)\README.md", "begin-challenge\challenges\$($c.Folder)\manifests" }
    foreach ($relative in $expected) { if (-not (Test-Path -LiteralPath (Join-Path $Path $relative))) { $problems.Add("$relative is missing.") } }
    foreach ($item in Get-ChildItem -LiteralPath $Path -Recurse -Force) {
        $relative = [IO.Path]::GetRelativePath($Path, $item.FullName)
        if ($relative -match '^(setup-logs|\.lab)(\\|$)') { continue }
        if ($item.PSIsContainer) {
            if ($item.Name -in 'challenge-end-state', '.git', 'terraform', 'docs', 'tests', 'leaderboard', 'skillable', 'azure-cli-bash') {
                $problems.Add("$relative isn't for attendees.")
            }
            continue
        }
        if ($item.Name -match '(?i)^solution') { $problems.Add("$relative is a solution.") }
        if ($item.Extension -eq '.md') {
            $text = Read-Text $item.FullName
            foreach ($leak in @(Find-Leaks $text)) { $problems.Add("${relative}: $leak.") }
            foreach ($m in [regex]::Matches($text, '\]\((?!https?://|#)([^)\s#]+)')) {
                if (-not (Test-Path -LiteralPath (Join-Path $item.DirectoryName $m.Groups[1].Value))) { $problems.Add("${relative} links to $($m.Groups[1].Value), which isn't there.") }
            }
        }
        if ($item.Extension -eq '.env' -and (Select-String -LiteralPath $item.FullName -Pattern '^\s*#' -Quiet)) { $problems.Add("$relative has comments.") }
    }
    return $problems
}

function Build-AttendeeFolder([string]$Path, [object[]]$Challenges) {
    $Path = [IO.Path]::GetFullPath($Path).TrimEnd('\')
    if ($Path -match '^[A-Za-z]:$') { throw "The attendee folder can't be a drive's root." }
    $inside = { param($a, $b) $a.Equals($b, 'OrdinalIgnoreCase') -or $a.StartsWith("$b\", 'OrdinalIgnoreCase') }
    if ((& $inside $Path $RepoRoot) -or (& $inside $RepoRoot $Path)) { throw "The attendee folder can't be in the repository, or contain it: $Path" }
    if (Test-Path -LiteralPath $Path) {
        # Never empty a folder that isn't an attendee folder.
        $other = @(Get-ChildItem -LiteralPath $Path -Force | Where-Object { $FolderEntries -notcontains $_.Name } | ForEach-Object { $_.Name })
        if ($other) { throw "$Path has files that an attendee folder doesn't have ($($other -join ', ')). Use an empty folder, or C:\lab-resources." }
        Get-ChildItem -LiteralPath $Path -Force | Where-Object { $_.Name -ne 'setup-logs' } | Remove-Item -Recurse -Force
    }
    New-Item -ItemType Directory -Path $Path -Force | Out-Null

    foreach ($spec in $RepoFiles) {
        $source = Join-Path $RepoRoot $spec.Folder
        $files = @(Get-ChildItem -LiteralPath $source -File | Where-Object { $name = $_.Name; @($spec.Include | Where-Object { $name -like $_ }).Count -gt 0 })
        if (-not $files) { throw "No $($spec.Include -join ', ') in $source." }
        New-Item -ItemType Directory -Path (Join-Path $Path $spec.Folder) -Force | Out-Null
        foreach ($file in $files) { Copy-Item -LiteralPath $file.FullName -Destination (Join-Path $Path (Join-Path $spec.Folder $file.Name)) }
    }
    foreach ($c in $Challenges) {
        $target = Join-Path $Path "begin-challenge\challenges\$($c.Folder)"
        foreach ($file in Get-ChildItem -LiteralPath $c.Dir -Recurse -File) {
            $relative = [IO.Path]::GetRelativePath($c.Dir, $file.FullName)
            $targetFile = Join-Path $target $relative
            if ($file.Name -eq 'SOLUTION.md') { continue }
            if ($relative -eq 'README.md') {
                Write-Text $targetFile (((ConvertTo-AttendeeMarkdown $c 'Folder') -join "`n") + "`n")
            } elseif ($file.Extension -eq '.env') {
                # Settings only: a comment can explain the challenge's problem.
                $settings = @((Read-Text $file.FullName) -split "`n" | Where-Object { $_ -match '^\s*[A-Za-z_][A-Za-z0-9_]*=' })
                Write-Text $targetFile (($settings -join "`n") + "`n")
            } else {
                New-Item -ItemType Directory -Path (Split-Path -Parent $targetFile) -Force | Out-Null
                Copy-Item -LiteralPath $file.FullName -Destination $targetFile
            }
        }
    }
    foreach ($attendeeScript in 'check.ps1', 'reset.ps1') {
        Copy-Item -LiteralPath (Join-Path $AttendeeSrc $attendeeScript) -Destination (Join-Path $Path $attendeeScript)
    }
    Write-Text (Join-Path $Path 'README.md') (New-AttendeeReadme $Challenges)
    return @(Test-AttendeeFolder $Path $Challenges)
}

if (-not ($LabSteps -or $Destination -or $Check)) { $Check = $true }
$challenges = Get-Challenges

if ($LabSteps) {
    $text = New-LabSteps $challenges
    $problems = @(Test-LabSteps $text $challenges)
    if ($problems) { throw "The lab steps weren't written: $($problems -join ' ')" }
    Write-Text $LabStepsPath $text
    Write-Host "Wrote $LabStepsPath ($(($text -split "`n").Count) lines, $($challenges.Count) challenges)."
}

if ($Destination) {
    $problems = @(Build-AttendeeFolder $Destination $challenges)
    if ($problems) { throw "The attendee folder $Destination has problems: $($problems -join ' ')" }
    $count = @(Get-ChildItem -LiteralPath $Destination -Recurse -File | Where-Object { $_.FullName -notmatch '\\(setup-logs|\.lab)\\' }).Count
    Write-Host "Built the attendee folder $Destination ($count files, $($challenges.Count) challenges, no solutions)."
}

if ($Check) {
    $problems = [Collections.Generic.List[string]]::new()
    $text = New-LabSteps $challenges
    $current = if (Test-Path -LiteralPath $LabStepsPath) { Read-Text $LabStepsPath } else { '' }
    if ($current -ne $text) { $problems.Add("skillable lab steps.md is out of date. Run ./skillable/build-attendee-content.ps1 -LabSteps.") }
    foreach ($problem in @(Test-LabSteps $text $challenges)) { $problems.Add($problem) }
    $temp = Join-Path ([IO.Path]::GetTempPath()) "ctf-attendee-check-$PID"
    try {
        foreach ($problem in @(Build-AttendeeFolder $temp $challenges)) { $problems.Add("Attendee folder: $problem") }
    } finally {
        Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue
    }
    if ($problems.Count -gt 0) {
        foreach ($problem in $problems) { Write-Host "FAIL  $problem" -ForegroundColor Red }
        exit 1
    }
    Write-Host "PASS  The lab steps are up to date, and the lab steps and the attendee folder have no solution content ($($challenges.Count) challenges)." -ForegroundColor Green
}
