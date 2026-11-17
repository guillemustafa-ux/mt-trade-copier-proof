<#
.SYNOPSIS
  Copies the copier sources into MetaTrader data folders.

.DESCRIPTION
  Writes only into CopierProof subfolders of the given data folders:
    <MT5 data>\MQL5\Include\CopierProof, \Experts\CopierProof, \Scripts\CopierProof
    <MT4 data>\MQL4\Include\CopierProof, \Experts\CopierProof, \Scripts\CopierProof
  Find a data folder in the terminal with File > Open Data Folder.

.EXAMPLE
  .\tools\deploy.ps1 -Mt5Data "$env:APPDATA\MetaQuotes\Terminal\<hash>" -Mt4Data "$env:APPDATA\MetaQuotes\Terminal\<hash>"
#>
param(
  [string]$Mt5Data = "",
  [string]$Mt4Data = ""
)
$ErrorActionPreference = "Stop"
$repo = Split-Path -Parent $PSScriptRoot

function Copy-Into([string]$dest, [string[]]$files) {
  New-Item -ItemType Directory -Force -Path $dest | Out-Null
  foreach ($f in $files) {
    Copy-Item -LiteralPath $f -Destination $dest -Force
    Write-Output ("copied {0} -> {1}" -f (Split-Path -Leaf $f), $dest)
  }
}

$includes = Get-ChildItem -LiteralPath (Join-Path $repo "src\Include\CopierProof") -Filter *.mqh | ForEach-Object { $_.FullName }
$tests    = @(Get-ChildItem -LiteralPath (Join-Path $repo "tests") -Filter *.mqh | ForEach-Object { $_.FullName })

if ($Mt5Data -ne "") {
  $mql = Join-Path $Mt5Data "MQL5"
  if (-not (Test-Path -LiteralPath $mql)) { throw "Not an MT5 data folder: $Mt5Data" }
  Copy-Into (Join-Path $mql "Include\CopierProof") $includes
  Copy-Into (Join-Path $mql "Experts\CopierProof") (Get-ChildItem -LiteralPath (Join-Path $repo "src\MQL5\Experts") -Filter *.mq5 | ForEach-Object { $_.FullName })
  Copy-Into (Join-Path $mql "Scripts\CopierProof") (@(Join-Path $repo "tests\CopierCoreTests.mq5") + $tests)
}
if ($Mt4Data -ne "") {
  $mql = Join-Path $Mt4Data "MQL4"
  if (-not (Test-Path -LiteralPath $mql)) { throw "Not an MT4 data folder: $Mt4Data" }
  Copy-Into (Join-Path $mql "Include\CopierProof") $includes
  Copy-Into (Join-Path $mql "Experts\CopierProof") (Get-ChildItem -LiteralPath (Join-Path $repo "src\MQL4\Experts") -Filter *.mq4 | ForEach-Object { $_.FullName })
  Copy-Into (Join-Path $mql "Scripts\CopierProof") (@(Join-Path $repo "tests\CopierCoreTests.mq4") + $tests)
}
