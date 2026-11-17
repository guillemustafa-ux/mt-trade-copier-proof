<#
.SYNOPSIS
  One-line mutants of CopierCore.mqh: each must make at least one test fail.

.DESCRIPTION
  For every mutant: copy the real core with one line changed into
  <MT5 data>\MQL5\Include\CopierProof, compile the test script, run it with
  tools\run-tests-mt5.ps1 and record the summary and the failing tests.
  The real core is copied back at the end (tools\deploy.ps1).
#>
param(
  [Parameter(Mandatory = $true)][string]$Mt5Data,
  [Parameter(Mandatory = $true)][string]$Editor,
  [Parameter(Mandatory = $true)][string]$Terminal,
  [Parameter(Mandatory = $true)][string]$OutFile
)
$ErrorActionPreference = "Stop"
$repo = Split-Path -Parent $PSScriptRoot
$core = [IO.File]::ReadAllText((Join-Path $repo "src\Include\CopierProof\CopierCore.mqh")).Replace("`r`n", "`n")
$target = Join-Path $Mt5Data "MQL5\Include\CopierProof\CopierCore.mqh"
$script = Join-Path $Mt5Data "MQL5\Scripts\CopierProof\CopierCoreTests.mq5"

$mutants = @(
  @("buy limit X ticks worse", "MathFloor((masterPrice - ticks * tickSize)", "MathFloor((masterPrice + ticks * tickSize)"),
  @("add-ons treated as initial entries", "return CP_ROLE_ADDON;", "return CP_ROLE_INITIAL;"),
  @("master exits ignored", "if(map[i].status == CP_ST_DONE || CP_FindMaster(snap, map[i].masterTicket) >= 0)", "if(true)"),
  @("partial close rounded up", "double desiredClosed = CP_FloorToStep(map[e].slaveLotsAtCopy * closedFraction, step);", "double desiredClosed = MathCeil(map[e].slaveLotsAtCopy * closedFraction / step - 1e-7) * step;"),
  @("no minimum-volume guard on partial close", "if(vol - closeNow < specs[s].volMin - CP_EPS)", "if(false)"),
  @("checksum not verified", "if(IntegerToString((long)CP_Checksum(candidate)) != tail)", "if(false)"),
  @("older snapshots accepted", "if(st.has && !CP_IsNewer(", "if(false && !CP_IsNewer("),
  @("stale snapshots acted on", "if(!CP_IsFresh(st.current.writeTime, now, cfg.staleSeconds))", "if(false)"),
  @("recovery ignores the magic number", "      if(items[i].magic != cfg.magic)`n         continue;`n      long master", "      long master"),
  @("no grace before a link is dropped", "else if(now - map[i].lastSeen > cfg.graceSeconds)", "else if(true)"),
  @("slave suffix not applied", "return base + CP_Trim(slaveSuffix);", "return base;"),
  @("lots below minimum not raised", "      v = volMin;", "      v = v * 1;"),
  @("MT4 alias resolved one level only", "ids[i] = (j >= 0) ? t.ids[j] : from;", "ids[i] = from;"),
  @("stale-master alert on every cycle", "if(cycleResult == CP_CYCLE_STALE && !frozen)", "if(cycleResult == CP_CYCLE_STALE)"),
  @("demo guard lets any account run", "   if(isDemo)`n      return `"`";", "   if(true)`n      return `"`";"),
  @("broker minimum distance ignored for buy limits", "if(limitPrice > highest + CP_EPS)", "if(false)")
)

$lines = @("# One-line mutants of src/Include/CopierProof/CopierCore.mqh, run in MetaTrader 5", "")
$survivors = 0
foreach ($m in $mutants) {
  $name = $m[0]; $find = $m[1]; $repl = $m[2]
  $first = $core.IndexOf($find)
  if ($first -lt 0 -or $core.IndexOf($find, $first + 1) -ge 0) { throw "mutant '$name': text not found exactly once" }
  [IO.File]::WriteAllText($target, $core.Replace($find, $repl))
  $log = Join-Path ([IO.Path]::GetTempPath()) ("cp-mutant-" + [guid]::NewGuid().ToString("N") + ".log")
  Start-Process -FilePath $Editor -ArgumentList "/compile:`"$script`"", "/log:`"$log`"", "/include:`"$(Join-Path $Mt5Data 'MQL5')`"" -Wait | Out-Null
  $compiled = ([IO.File]::ReadAllText($log) -split "`r?`n" | Where-Object { $_ -match "^Result:" }) -join ""
  Remove-Item -LiteralPath $log -Force
  $out = Join-Path ([IO.Path]::GetTempPath()) ("cp-mutant-" + [guid]::NewGuid().ToString("N") + ".txt")
  & (Join-Path $PSScriptRoot "run-tests-mt5.ps1") -Mt5Data $Mt5Data -Terminal $Terminal -OutFile $out | Out-Null
  $run = Get-Content -LiteralPath $out
  Remove-Item -LiteralPath $out -Force
  $summary = ($run | Where-Object { $_ -match "passed, " } | Select-Object -Last 1) -replace "^.*\t", ""
  $failed = @($run | Where-Object { $_ -match "\tFAIL " } | ForEach-Object { (($_ -split "\t")[-1] -replace "^FAIL ", "") -replace ":.*$", "" })
  if ($failed.Count -eq 0) { $survivors++ }
  $lines += "mutant: $name"
  $lines += "  change: '$($find -replace "`n", '\n')' -> '$($repl -replace "`n", '\n')'"
  $lines += "  compile: $compiled"
  $lines += "  result: $summary"
  $lines += "  failing: " + ($failed -join ", ")
  $lines += ""
  Write-Output ("{0}: {1}" -f $name, $summary)
}
$lines += "mutants: $($mutants.Count), survived: $survivors"
& (Join-Path $PSScriptRoot "deploy.ps1") -Mt5Data $Mt5Data | Out-Null
Start-Process -FilePath $Editor -ArgumentList "/compile:`"$script`"", "/include:`"$(Join-Path $Mt5Data 'MQL5')`"" -Wait | Out-Null
[IO.File]::WriteAllLines($OutFile, [string[]]$lines, (New-Object Text.UTF8Encoding($false)))
Write-Output "mutants: $($mutants.Count), survived: $survivors"
