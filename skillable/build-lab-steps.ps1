<#
.SYNOPSIS
    Writes the Skillable lab instructions, "skillable lab steps.md", from the challenges' README files, and checks
    that this repository has only what attendees may see.

.DESCRIPTION
    Each challenge's README.md is the source of its page in the lab instructions, so a change to a challenge is made
    once. The rest of the instructions come from lab-steps-template.md in this folder. For Skillable, the script turns
    the hints into collapsible sections, and the check and reset commands into type-text that runs the lab repository's
    own scripts on the lab VM (C:\LabFiles\kubecon26-pre-day-lab): scoring\verify.ps1, and
    begin-challenge\azure-cli-powershell\deploy.ps1 with the lab's resource group and cluster. It notes that the lab VM
    already has ingress2gateway.

    -Check writes nothing. It fails if "skillable lab steps.md" is out of date, or if the lab instructions or this
    repository have content for instructors only: solutions, the end state, evaluation notes, or the event
    leaderboard's setup. That content is in the instructors' repository. Run it before you commit.

.EXAMPLE
    ./skillable/build-lab-steps.ps1

.EXAMPLE
    ./skillable/build-lab-steps.ps1 -Check
#>
#Requires -Version 7.4
[CmdletBinding()]
param(
    # Check, and write nothing.
    [switch]$Check
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 3.0

$RepoRoot      = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$ChallengeRoot = Join-Path $RepoRoot 'begin-challenge\challenges'
$TemplatePath  = Join-Path $PSScriptRoot 'lab-steps-template.md'
$LabStepsPath  = Join-Path $PSScriptRoot 'skillable lab steps.md'
# The lab repository on the lab VM, and the Skillable tokens for the lab's resource group. The cluster name is the
# prepare LCA's ClusterName setting.
$LabFolder     = 'C:\LabFiles\kubecon26-pre-day-lab'
$ResourceGroup = '@lab.CloudResourceGroup(ResourceGroup1).Name'
$ClusterName   = 'aks-kubecon-ctf'
# Instructor-only content: never in the lab instructions or a challenge README.
$Words = [ordered]@{
    'mentions solutions'        = '(?i)\bsolution'
    'mentions a walkthrough'    = '(?i)\bwalk-?through'
    'mentions facilitators'     = '(?i)\bfacilitator'
    'mentions the end state'    = '(?i)\bend[- ]state\b'
    'has evaluation notes'      = '(?i)\bfeasib|\bevaluation notes\b|\bdesign target\b|\bproposed core\b|\bpilot\b'
    'mentions the seeded fault' = '(?i)\bseeded fault'
}
# Instructor-only files, and markers of instructor-only sections, anywhere in this repository.
$InstructorPaths = '(^|/)(SOLUTION|FEASIBILITY)\.md$|(^|/)challenge-end-state/|^leaderboard/|^docs/testing\.md$'
$InstructorMarkers = [ordered]@{
    'has a feasibility section'  = '(?im)^#{1,6}\s+Feasibility'
    'marks facilitator content'  = '(?i)facilitators only|\(facilitators\)|walkthrough to the end state|\(evaluation notes\)'
    'links to instructor files'  = '(?i)\]\([^)]*(SOLUTION|FEASIBILITY)\.md|\]\([^)]*(challenge-end-state|leaderboard/)'
}

function Read-Text([string]$Path) { return ([IO.File]::ReadAllText($Path) -replace "`r`n", "`n") }

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
        [pscustomobject]@{
            Id        = ($dir.Name -split '-')[0]
            Order     = $order
            Folder    = $dir.Name
            Readme    = $readme
            Title     = ($lines[0] -replace '^#\s+', '').Trim()
            Name      = $name
            Namespace = Get-TableValue $lines 'Namespace' $readme
            ShortTime = ((Get-TableValue $lines 'Suggested time' $readme) -split ',')[0].Trim()
        }
    }
    return @($list | Sort-Object Order)
}

function Get-CheckText([string]$Id) {
    return @('', 'Check your work:', '', "+++$LabFolder\scoring\verify.ps1 -Challenges $Id+++", '')
}

function Get-ResetText([string]$Id, [string]$Comment, [string[]]$Prose) {
    $command = "$LabFolder\begin-challenge\azure-cli-powershell\deploy.ps1 -ResourceGroup $ResourceGroup -ClusterName $ClusterName -Challenges $Id"
    $text = [Collections.Generic.List[string]]::new()
    $text.AddRange([string[]]@('', 'To start this challenge over, run the following command. Your changes to this challenge are lost.', '', "+++$command+++", ''))
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

# A challenge README.md as a page of the lab instructions.
function ConvertTo-LabStepsPage([object]$Challenge) {
    $lines = [Collections.Generic.List[string]]::new([string[]]((Read-Text $Challenge.Readme) -split "`n"))
    $out = [Collections.Generic.List[string]]::new()
    $section = ''
    $resetComment = ''
    $resetProse = [Collections.Generic.List[string]]::new()
    $toolNote = $false
    $closeSection = {
        if ($section -eq 'Success criteria') { $out.AddRange([string[]](Get-CheckText $Challenge.Id)) }
        if ($section -eq 'Reset') { $out.AddRange([string[]](Get-ResetText $Challenge.Id $resetComment $resetProse)) }
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
                if (-not $toolNote) {
                    $out.AddRange([string[]]@('', 'Your lab VM already has `ingress2gateway`. To check, run:', '', '+++ingress2gateway version+++', ''))
                    $toolNote = $true
                }
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
        if ($line -match '^Check your work\b') { continue }
        $out.Add($line)
    }
    . $closeSection
    return (Format-Lines (ConvertTo-SkillableHints $out $Challenge.Readme))
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

function Get-ChallengeTable([object[]]$Challenges) {
    $rows = [Collections.Generic.List[string]]::new()
    $rows.AddRange([string[]]@('| ID | Challenge | Namespace | Suggested time |', '|:--|:--|:--|:--|'))
    foreach ($c in $Challenges) { $rows.Add("| $($c.Id.ToUpperInvariant()) | $($c.Name) | $($c.Namespace) | $($c.ShortTime) |") }
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
    return ($lines[($start + 1)..($end - 1)] -join "`n").Trim()
}

function Set-Placeholder([string]$Text, [string]$Name, [string]$Value) {
    $pattern = "(?m)^<!-- @$([regex]::Escape($Name)) -->[ \t]*$"
    if ($Text -notmatch $pattern) { throw "The template has no '<!-- @$Name -->' line." }
    return [regex]::Replace($Text, $pattern, $Value.Replace('$', '$$'))
}

function New-LabSteps([object[]]$Challenges) {
    $text = [regex]::Replace((Read-Text $TemplatePath), '(?s)\A<!-- TEMPLATE:.*?-->\n', '')
    $pages = foreach ($c in $Challenges) { (ConvertTo-LabStepsPage $c) -join "`n" }
    $text = Set-Placeholder $text 'challenge-table' (Get-ChallengeTable $Challenges)
    $text = Set-Placeholder $text 'aks-automatic-tips' (Get-AksAutomaticTips)
    $text = Set-Placeholder $text 'challenges' ($pages -join "`n`n===`n`n")
    return ((Format-Lines ($text -split "`n")) -join "`n") + "`n"
}

function Find-Matches([string]$Text, [System.Collections.Specialized.OrderedDictionary]$Patterns) {
    foreach ($name in $Patterns.Keys) {
        $m = [regex]::Match($Text, $Patterns[$name])
        if ($m.Success) {
            $start = [Math]::Max(0, $m.Index - 30)
            $snippet = ($Text.Substring($start, [Math]::Min(80, $Text.Length - $start)) -replace '\s+', ' ').Trim()
            "$name ('$snippet')"
        }
    }
}

function Test-LabSteps([string]$Text, [object[]]$Challenges) {
    $problems = [Collections.Generic.List[string]]::new()
    foreach ($found in @(Find-Matches $Text $Words)) { $problems.Add("The lab steps: $found.") }
    foreach ($m in [regex]::Matches($Text, '\]\((?!https?://)([^)\s]+)\)')) { $problems.Add("The lab steps link to $($m.Groups[1].Value), which isn't a web address.") }
    if ($Text -match '<details|</summary>|<!-- @|<!-- TEMPLATE|lab-resources') { $problems.Add('The lab steps have a hint, a placeholder, or a folder that was not converted.') }
    foreach ($c in $Challenges) {
        foreach ($expected in "# $($c.Title)", "+++$LabFolder\scoring\verify.ps1 -Challenges $($c.Id)+++", "-ClusterName $ClusterName -Challenges $($c.Id)+++") {
            if (-not $Text.Contains($expected)) { $problems.Add("The lab steps have no '$expected'.") }
        }
    }
    return $problems
}

function Test-Repository([object[]]$Challenges) {
    $problems = [Collections.Generic.List[string]]::new()
    $files = if (Test-Path -LiteralPath (Join-Path $RepoRoot '.git')) { @(git -C $RepoRoot ls-files) }
             else { @(Get-ChildItem -LiteralPath $RepoRoot -Recurse -File | ForEach-Object { [IO.Path]::GetRelativePath($RepoRoot, $_.FullName) -replace '\\', '/' }) }
    foreach ($file in $files) {
        if ($file -match $InstructorPaths) { $problems.Add("$file is for instructors: it belongs in the instructors' repository."); continue }
        if ($file -notmatch '\.md$' -or $file -eq 'skillable/lab-steps-template.md' -or $file -eq 'skillable/skillable lab steps.md') { continue }
        $path = Join-Path $RepoRoot $file
        if (-not (Test-Path -LiteralPath $path)) { continue }
        foreach ($found in @(Find-Matches (Read-Text $path) $InstructorMarkers)) { $problems.Add("${file}: $found.") }
    }
    foreach ($c in $Challenges) {
        foreach ($found in @(Find-Matches (Read-Text $c.Readme) $Words)) { $problems.Add("$($c.Folder)/README.md: $found.") }
    }
    return $problems
}

$challenges = Get-Challenges
$text = New-LabSteps $challenges
$problems = [Collections.Generic.List[string]]::new()
foreach ($problem in @(Test-LabSteps $text $challenges)) { $problems.Add($problem) }
foreach ($problem in @(Test-Repository $challenges)) { $problems.Add($problem) }
if ($Check) {
    $current = if (Test-Path -LiteralPath $LabStepsPath) { Read-Text $LabStepsPath } else { '' }
    if ($current -ne $text) { $problems.Insert(0, 'skillable lab steps.md is out of date. Run ./skillable/build-lab-steps.ps1.') }
} elseif (-not @($problems | Where-Object { $_ -like 'The lab steps*' })) {
    [IO.File]::WriteAllText($LabStepsPath, $text, [Text.UTF8Encoding]::new($false))
    Write-Host "Wrote $LabStepsPath ($(($text -split "`n").Count) lines, $($challenges.Count) challenges)."
}
if ($problems.Count -gt 0) {
    foreach ($problem in $problems) { Write-Host "FAIL  $problem" -ForegroundColor Red }
    exit 1
}
Write-Host "PASS  The lab steps are up to date, and they and this repository have no instructor-only content ($($challenges.Count) challenges)." -ForegroundColor Green