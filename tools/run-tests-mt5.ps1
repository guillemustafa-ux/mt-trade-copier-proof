<#
.SYNOPSIS
  Runs Scripts\CopierProof\CopierCoreTests in MetaTrader 5 and saves its output.

.DESCRIPTION
  Starts terminal64.exe with a temporary startup configuration:
    [StartUp] Script=CopierProof\CopierCoreTests, Symbol, Period=H1, ShutdownTerminal=1
  The script places no orders and needs no trading account. The lines the
  script printed during this run are copied from <MT5 data>\MQL5\Logs\<date>.log
  to -OutFile. If the terminal has not closed itself after -TimeoutSec, its
  main window is closed (not killed) so the logs are flushed.

.EXAMPLE
  .\tools\run-tests-mt5.ps1 -Mt5Data "<MT5 data folder>" -Terminal "<...>\terminal64.exe" -OutFile docs\evidence\tests-mt5.txt
#>
param(
  [Parameter(Mandatory = $true)][string]$Mt5Data,
  [Parameter(Mandatory = $true)][string]$Terminal,
  [Parameter(Mandatory = $true)][string]$OutFile,
  [string]$Symbol = "EURUSD",
  [int]$TimeoutSec = 180
)
$ErrorActionPreference = "Stop"

$logDir = Join-Path $Mt5Data "MQL5\Logs"
$ini = Join-Path ([IO.Path]::GetTempPath()) ("cp-startup-" + [guid]::NewGuid().ToString("N") + ".ini")
$cfg = "[StartUp]`r`nScript=CopierProof\CopierCoreTests`r`nSymbol=$Symbol`r`nPeriod=H1`r`nShutdownTerminal=1`r`n"
[IO.File]::WriteAllText($ini, $cfg, (New-Object Text.UnicodeEncoding($false, $true)))

function Get-LogLines([string]$path) {
  if (-not (Test-Path -LiteralPath $path)) { return @() }
  $fs = New-Object IO.FileStream($path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
  try { $sr = New-Object IO.StreamReader($fs, $true); $text = $sr.ReadToEnd() } finally { $fs.Close() }
  return @($text.TrimEnd("`r", "`n") -split "`r?`n" | Where-Object { $_ -ne "" })
}

$logFile = Join-Path $logDir ((Get-Date).ToString("yyyyMMdd") + ".log")
$before  = (Get-LogLines $logFile).Count
$started = Get-Date

$proc = Start-Process -FilePath $Terminal -ArgumentList "/config:`"$ini`"" -PassThru
if (-not $proc.WaitForExit($TimeoutSec * 1000)) {
  Write-Output "terminal still running after $TimeoutSec s: closing its main window"
  $proc.CloseMainWindow() | Out-Null
  $proc.WaitForExit(60000) | Out-Null
}
Remove-Item -LiteralPath $ini -Force

$lines = Get-LogLines $logFile
$new   = @($lines | Select-Object -Skip $before | Where-Object { $_ -match "CopierCoreTests" })
$header = @(
  "# CopierCoreTests run in MetaTrader 5",
  ("# started (local time): " + $started.ToString("yyyy-MM-dd HH:mm:ss")),
  ("# source: MQL5\Logs\" + [IO.Path]::GetFileName($logFile) + " (lines printed by the script during this run)"),
  ""
)
New-Item -ItemType Directory -Force -Path (Split-Path -Parent $OutFile) | Out-Null
[IO.File]::WriteAllLines($OutFile, [string[]]($header + $new), (New-Object Text.UTF8Encoding($false)))
$summary = $new | Where-Object { $_ -match "passed, " } | Select-Object -Last 1
Write-Output ("exit code {0}; {1} lines; summary: {2}" -f $proc.ExitCode, $new.Count, $summary)
