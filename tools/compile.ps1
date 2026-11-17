<#
.SYNOPSIS
  Compiles the deployed copier programs with MetaEditor and keeps the logs.

.DESCRIPTION
  Run tools\deploy.ps1 first. For each program, MetaEditor is called as
    MetaEditor64.exe /compile:"<file>" /log:"<log>"
  The log (UTF-16) is converted to UTF-8 into -OutDir, with the data folder
  path replaced by "<MT5 data>" or "<MT4 data>", and its "Result:" line is
  printed. MetaEditor's exit code is not used: it was 1 on clean builds here.

.EXAMPLE
  .\tools\compile.ps1 -Mt5Data "<MT5 data folder>" -Mt5Editor "<...>\MetaEditor64.exe" `
                      -Mt4Data "<MT4 data folder>" -Mt4Editor "<...>\metaeditor.exe"
#>
param(
  [string]$Mt5Data = "",
  [string]$Mt5Editor = "",
  [string]$Mt4Data = "",
  [string]$Mt4Editor = "",
  [string]$OutDir = ""
)
$ErrorActionPreference = "Stop"
$repo = Split-Path -Parent $PSScriptRoot
if ($OutDir -eq "") { $OutDir = Join-Path $repo "docs\evidence\compile" }
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null

function Invoke-Compile([string]$editor, [string]$source, [string]$mqlRoot, [string]$dataRoot, [string]$label) {
  $name = [IO.Path]::GetFileName($source)
  $tmp  = Join-Path ([IO.Path]::GetTempPath()) ("cp-compile-" + [guid]::NewGuid().ToString("N") + ".log")
  $argList = @("/compile:`"$source`"", "/log:`"$tmp`"", "/include:`"$mqlRoot`"")
  Start-Process -FilePath $editor -ArgumentList $argList -Wait | Out-Null
  $text = [IO.File]::ReadAllText($tmp)          # detects the UTF-16 BOM
  Remove-Item -LiteralPath $tmp -Force
  $text = $text.Replace($dataRoot.TrimEnd([char]92), $label)
  $out = Join-Path $OutDir ($name + ".log")
  [IO.File]::WriteAllText($out, $text, (New-Object Text.UTF8Encoding($false)))
  $result = ($text -split "`r?`n" | Where-Object { $_ -match "^Result:" } | Select-Object -Last 1)
  Write-Output ("{0}: {1}" -f $name, $result)
}

if ($Mt5Data -ne "") {
  $mql = Join-Path $Mt5Data "MQL5"
  $files = @(Get-ChildItem -LiteralPath (Join-Path $mql "Experts\CopierProof") -Filter *.mq5) +
           @(Get-ChildItem -LiteralPath (Join-Path $mql "Scripts\CopierProof") -Filter *.mq5)
  foreach ($f in $files) { Invoke-Compile $Mt5Editor $f.FullName $mql $Mt5Data "<MT5 data>" }
}
if ($Mt4Data -ne "") {
  $mql = Join-Path $Mt4Data "MQL4"
  $files = @(Get-ChildItem -LiteralPath (Join-Path $mql "Experts\CopierProof") -Filter *.mq4) +
           @(Get-ChildItem -LiteralPath (Join-Path $mql "Scripts\CopierProof") -Filter *.mq4)
  foreach ($f in $files) { Invoke-Compile $Mt4Editor $f.FullName $mql $Mt4Data "<MT4 data>" }
}
