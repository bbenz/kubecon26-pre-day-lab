<#
.SYNOPSIS
    Regenerates the Skillable paste-in bootstraps from the scripts in this folder.

.DESCRIPTION
    A bootstrap is a script, gzip-compressed and base64-encoded, in short PowerShell lines that you paste
    into an elevated PowerShell window in the lab VM (right-click, or Skillable's Type Clipboard Text). It
    recreates the script in C:\LabSetup, checks its SHA-256 hash, and runs it. A mistyped character fails
    the check, and nothing runs.

      vm-image\kubecon-ctf-vm-image-setup-bootstrap.txt
          vm-image\kubecon-ctf-vm-image-setup.ps1, as C:\LabSetup\kubecon-ctf-vm-image-setup.ps1
      lca\manual-begin-state-bootstrap.txt
          lca\prepare-lab-environment.ps1 with Manual = $true, as C:\LabSetup\kubecon-ctf-begin-state.ps1:
          builds the begin state by hand, as you (LCA-RUNBOOK.md, "Build the begin state by hand")

    Run this script in Windows PowerShell 5.1 or PowerShell 7 after every change to those scripts, and
    commit the bootstraps with them.
#>
[CmdletBinding()]
param(
    [int]$LineLength = 1000,
    [int]$LinesPerPart = 4
)
$ErrorActionPreference = 'Stop'

function New-Bootstrap([byte[]]$Bytes, [string]$Destination, [string]$Target, [string]$Title) {
    $sha = [Security.Cryptography.SHA256]::Create()
    $hash = [BitConverter]::ToString($sha.ComputeHash($Bytes)).Replace('-', '')
    $buffer = New-Object IO.MemoryStream
    $gzip = New-Object IO.Compression.GZipStream($buffer, [IO.Compression.CompressionLevel]::Optimal)
    $gzip.Write($Bytes, 0, $Bytes.Length)
    $gzip.Close()
    $encoded = [Convert]::ToBase64String($buffer.ToArray())
    $chunks = @(for ($i = 0; $i -lt $encoded.Length; $i += $LineLength) { $encoded.Substring($i, [Math]::Min($LineLength, $encoded.Length - $i)) })
    $parts = [Math]::Ceiling($chunks.Count / $LinesPerPart)
    $lines = New-Object System.Collections.Generic.List[string]
    for ($part = 0; $part -lt $parts; $part++) {
        $lines.Add("# $Title, part $($part + 1) of $parts")
        if ($part -eq 0) { $lines.Add("`$b=''") }
        $last = [Math]::Min(($part + 1) * $LinesPerPart, $chunks.Count) - 1
        foreach ($chunk in $chunks[($part * $LinesPerPart)..$last]) { $lines.Add("`$b+='$chunk'") }
    }
    $lines.Add('$ok=$false;try{$z=[IO.Compression.GZipStream]::new([IO.MemoryStream]::new([Convert]::FromBase64String($b)),' +
        '[IO.Compression.CompressionMode]::Decompress);$o=[IO.MemoryStream]::new();$z.CopyTo($o);$z.Close();' +
        'New-Item -ItemType Directory -Force -Path C:\LabSetup|Out-Null;$f=''' + $Target + ''';' +
        '[IO.File]::WriteAllBytes($f,$o.ToArray());if((Get-FileHash -LiteralPath $f).Hash -eq ''' + $hash + '''){$ok=$true}' +
        'else{Write-Host ''Hash mismatch: some text was mistyped. Paste the bootstrap again in a new window.'' -ForegroundColor Red}}' +
        'catch{Write-Host "Decode failed: $($_.Exception.Message) Paste the bootstrap again in a new window." -ForegroundColor Red}')
    $lines.Add('if($ok){Set-ExecutionPolicy Bypass -Scope Process -Force;& $f}')
    [IO.File]::WriteAllText($Destination, ($lines -join "`r`n") + "`r`n", (New-Object Text.UTF8Encoding($false)))
    Write-Host ("Wrote $Destination ($($lines.Count) lines, $parts parts). $Target SHA-256: $hash")
}

$image = Join-Path $PSScriptRoot 'vm-image\kubecon-ctf-vm-image-setup.ps1'
New-Bootstrap -Bytes ([IO.File]::ReadAllBytes($image)) -Destination (Join-Path $PSScriptRoot 'vm-image\kubecon-ctf-vm-image-setup-bootstrap.txt') `
    -Target 'C:\LabSetup\kubecon-ctf-vm-image-setup.ps1' -Title 'KubeCon CTF VM image setup bootstrap'

$lcaText = [IO.File]::ReadAllText((Join-Path $PSScriptRoot 'lca\prepare-lab-environment.ps1'))
$pattern = '(?m)^(\s*Manual\s*=\s*)\$false'
if ($lcaText -notmatch $pattern) { throw "Couldn't find the Manual = `$false setting in prepare-lab-environment.ps1." }
$manualText = [regex]::Replace($lcaText, $pattern, '${1}$true ')
New-Bootstrap -Bytes ((New-Object Text.UTF8Encoding($false)).GetBytes($manualText)) -Destination (Join-Path $PSScriptRoot 'lca\manual-begin-state-bootstrap.txt') `
    -Target 'C:\LabSetup\kubecon-ctf-begin-state.ps1' -Title 'KubeCon CTF manual begin state bootstrap'
