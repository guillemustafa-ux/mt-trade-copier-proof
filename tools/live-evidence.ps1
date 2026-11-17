<#
.SYNOPSIS
  Turns one demo run (tools/live-run.ps1 -Mode A or B) into redacted evidence files.

.DESCRIPTION
  Reads, for the time window of the run (first to last line of the driver log):
    MT5 Experts log  <MT5 data>\MQL5\Logs\<yyyyMMdd>.log   (UTF-16)
    MT5 Journal      <MT5 data>\logs\<yyyyMMdd>.log
    MT4 Experts log  <MT4 data>\MQL4\Logs\<yyyyMMdd>.log
    MT4 Journal      <MT4 data>\logs\<yyyyMMdd>.log
  and the helper scripts' files saved by the driver (<WorkDir>\<Mode>\*.events,
  *.out, *.history). Writes UTF-8 files to -OutDir:
    mt5-experts.log, mt5-journal.log, mt4-experts.log, mt4-journal.log, driver.log
    agent-<mt4|mt5>.events.csv, agent-<mt4|mt5>.out, agent-<mt4|mt5>.history.csv
    scenario-<id>.log   every line of the five logs inside that scenario, merged by time
    delays.csv          master action (helper script) -> slave copier action, in ms
  Redaction: account numbers (taken from the journals' login lines) become
  <demo-mt4> / <demo-mt5>; IP addresses become <ip>; data folders and the user
  folder become <MT5 data>, <MT4 data>, <user home>. The script stops if an
  account number is still found in any output file.

.EXAMPLE
  .\tools\live-evidence.ps1 -Mode A -Mt5Data "<MT5 data>" -Mt4Data "<MT4 data>" -WorkDir "<scratch>\live" -OutDir docs\evidence\live\A
#>
param(
  [Parameter(Mandatory = $true)][ValidateSet("A", "B")][string]$Mode,
  [Parameter(Mandatory = $true)][string]$Mt5Data,
  [Parameter(Mandatory = $true)][string]$Mt4Data,
  [Parameter(Mandatory = $true)][string]$WorkDir,
  [Parameter(Mandatory = $true)][string]$OutDir,
  [string]$Date = (Get-Date).ToString("yyyyMMdd"),
  [string]$Run = ""     # suffix of a kept earlier run: driver-<Mode><Run>.log and <WorkDir>\<Mode><Run>
)
$ErrorActionPreference = "Stop"
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
$utf8 = New-Object Text.UTF8Encoding($false)

function Read-Log([string]$path) {
  if (-not (Test-Path -LiteralPath $path)) { return @() }
  $fs = New-Object IO.FileStream($path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
  try {
    $b0 = $fs.ReadByte(); $b1 = $fs.ReadByte(); [void]$fs.Seek(0, [IO.SeekOrigin]::Begin)
    $enc = if ($b0 -eq 0xFF -and $b1 -eq 0xFE) { [Text.Encoding]::Unicode } else { [Text.Encoding]::Default }
    $sr = New-Object IO.StreamReader($fs, $enc, $true); $text = $sr.ReadToEnd()
  } finally { $fs.Close() }
  return @($text -split "`r?`n" | Where-Object { $_ -ne "" })
}

function Get-Time([string]$line) {
  $m = [regex]::Match($line, "(\d\d):(\d\d):(\d\d)\.(\d\d\d)")
  if (-not $m.Success) { return -1 }
  return ((([int]$m.Groups[1].Value * 60 + [int]$m.Groups[2].Value) * 60 + [int]$m.Groups[3].Value) * 1000 + [int]$m.Groups[4].Value)
}

#--- account numbers: from the journals' login lines (never printed)
$logins = @{}
foreach ($pair in @(@("mt5", (Join-Path $Mt5Data "logs\$Date.log")), @("mt4", (Join-Path $Mt4Data "logs\$Date.log")))) {
  foreach ($l in (Read-Log $pair[1])) {
    $m = [regex]::Match($l, "'(\d{4,})': (authorized|login|order|deal|close|modify|delete|pending|buy|sell)")
    if ($m.Success) { $logins[$m.Groups[1].Value] = "<demo-" + $pair[0] + ">" }
  }
}
$userHome = [Environment]::GetFolderPath("UserProfile")
$tempDir = [IO.Path]::GetTempPath().TrimEnd([char]92)
function Redact([string]$s) {
  $s = $s.Replace($Mt5Data.TrimEnd([char]92), "<MT5 data>").Replace($Mt4Data.TrimEnd([char]92), "<MT4 data>")
  $s = $s.Replace($tempDir, "<temp>").Replace($userHome, "<user home>")
  foreach ($k in $logins.Keys) { $s = [regex]::Replace($s, "(?<!\d)" + $k + "(?!\d)", $logins[$k]) }
  $s = [regex]::Replace($s, "\b\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}\b", "<ip>")
  return $s
}

#--- run window from the driver log
$driver = @(Get-Content -LiteralPath (Join-Path $WorkDir "driver-$Mode$Run.log") -Encoding UTF8)
$t0 = (Get-Time $driver[0]) - 2000
$t1 = (Get-Time $driver[-1]) + 2000
function Test-InWindow([string]$line) { $t = Get-Time $line; return ($t -ge $t0 -and $t -le $t1) }

$sources = [ordered]@{
  "mt5-experts" = Join-Path $Mt5Data "MQL5\Logs\$Date.log"
  "mt5-journal" = Join-Path $Mt5Data "logs\$Date.log"
  "mt4-experts" = Join-Path $Mt4Data "MQL4\Logs\$Date.log"
  "mt4-journal" = Join-Path $Mt4Data "logs\$Date.log"
}
$all = New-Object System.Collections.ArrayList
foreach ($name in $sources.Keys) {
  $lines = @(Read-Log $sources[$name] | Where-Object { Test-InWindow $_ } | ForEach-Object { Redact $_ })
  [IO.File]::WriteAllLines((Join-Path $OutDir "$name.log"), [string[]]$lines, $utf8)
  foreach ($l in $lines) { [void]$all.Add([pscustomobject]@{ T = (Get-Time $l); Src = $name; Line = $l }) }
}
$driverRed = @($driver | ForEach-Object { Redact $_ })
[IO.File]::WriteAllLines((Join-Path $OutDir "driver.log"), [string[]]$driverRed, $utf8)
foreach ($l in $driverRed) { [void]$all.Add([pscustomobject]@{ T = (Get-Time $l); Src = "driver"; Line = $l }) }

#--- helper script files
foreach ($f in (Get-ChildItem -LiteralPath (Join-Path $WorkDir ($Mode + $Run)) -File -ErrorAction SilentlyContinue)) {
  $ext = $f.Extension.TrimStart(".")
  if ($ext -notin @("events", "out", "history")) { continue }
  $name = "agent-" + $f.BaseName + "." + $ext + $(if ($ext -eq "out") { "" } else { ".csv" })
  $text = Redact ([IO.File]::ReadAllText($f.FullName, [Text.Encoding]::Default))
  [IO.File]::WriteAllText((Join-Path $OutDir $name), $text, $utf8)
}

#--- per-scenario merged timelines
$sorted = @($all | Sort-Object T, Src)
$marks = @($driver | Where-Object { $_ -match "=== scenario (\w+) (start|end)" })
$scenarios = @()
foreach ($m in $marks) {
  $mm = [regex]::Match($m, "=== scenario (\w+) (start|end)")
  if ($mm.Groups[2].Value -eq "start") { $scenarios += [pscustomobject]@{ Id = $mm.Groups[1].Value; Start = (Get-Time $m); End = -1 } }
  else { ($scenarios | Where-Object { $_.Id -eq $mm.Groups[1].Value } | Select-Object -Last 1).End = (Get-Time $m) }
}
foreach ($s in $scenarios) {
  if ($s.End -lt 0) { $s.End = $t1 }
  $out = @("# Direction $Mode, scenario $($s.Id): every line of the driver, both Experts logs and both Journals, merged by local time", "")
  $out += @($sorted | Where-Object { $_.T -ge ($s.Start - 1000) -and $_.T -le ($s.End + 1000) } | ForEach-Object { "[{0}] {1}" -f $_.Src, $_.Line })
  [IO.File]::WriteAllLines((Join-Path $OutDir ("scenario-" + $s.Id + ".log")), [string[]]$out, $utf8)
}

#--- delays: master helper action -> slave copier action, same master ticket
$master = if ($Mode -eq "A") { "mt4" } else { "mt5" }
$slave  = if ($Mode -eq "A") { "mt5" } else { "mt4" }
$alias = @{}
$masterEvents = @()
foreach ($e in ($all | Where-Object { $_.Src -eq "$master-experts" -and $_.Line -match "\[LiveAgent\] (OPEN|CLOSE) done #(\d+)" } | Sort-Object T)) {
  $m = [regex]::Match($e.Line, "\[LiveAgent\] (OPEN|CLOSE) done #(\d+)")
  $ticket = $m.Groups[2].Value
  $id = if ($alias.ContainsKey($ticket)) { $alias[$ticket] } else { $ticket }
  $r = [regex]::Match($e.Line, "remainder #(\d+)")
  if ($r.Success -and $r.Groups[1].Value -ne "0") { $alias[$r.Groups[1].Value] = $id }
  $masterEvents += [pscustomobject]@{ T = $e.T; Kind = $m.Groups[1].Value; Id = $id; Line = $e.Line }
}
#--- a slave EA that started after the master action was stopped on purpose: not a copy delay
$slaveStarts = @($all | Where-Object { $_.Src -eq "$slave-experts" -and $_.Line -match "\[CopierProof\] slave reading" } | ForEach-Object { $_.T })
$rows = @("scenario;master_action;master_id;master_time;slave_action;slave_time;delay_ms;counted")
$delays = @()
foreach ($e in ($all | Where-Object { $_.Src -eq "$slave-experts" -and $_.Line -match "\[CopierProof\] (limit @|market|close slave|delete slave).* master #(\d+)" } | Sort-Object T)) {
  $m = [regex]::Match($e.Line, "\[CopierProof\] (limit @|market|close slave|delete slave).* master #(\d+)")
  $act = $m.Groups[1].Value.Replace(" @", "").Replace(" slave", "")
  $want = if ($act -in @("limit", "market")) { "OPEN" } else { "CLOSE" }
  $src = $masterEvents | Where-Object { $_.Id -eq $m.Groups[2].Value -and $_.Kind -eq $want -and $_.T -le $e.T } | Select-Object -Last 1
  if (-not $src) { continue }
  $reason = [regex]::Match($e.Line, "\(([^()]*)\)\s*$").Groups[1].Value
  $sc = ($scenarios | Where-Object { $src.T -ge $_.Start -and $src.T -le $_.End } | Select-Object -First 1).Id
  $d = $e.T - $src.T
  $restarted = @($slaveStarts | Where-Object { $_ -gt $src.T -and $_ -lt $e.T }).Count -gt 0
  if (-not $restarted) { $delays += $d }
  $fmt = { param($ms) "{0:00}:{1:00}:{2:00}.{3:000}" -f [math]::Floor($ms / 3600000), [math]::Floor(($ms % 3600000) / 60000), [math]::Floor(($ms % 60000) / 1000), ($ms % 1000) }
  $rows += ("{0};{1};{2};{3};{4};{5};{6};{7}" -f $sc, $want, $src.Id, (& $fmt $src.T), "$act ($reason)", (& $fmt $e.T), $d,
            $(if ($restarted) { "no: slave EA started after the master action" } else { "yes" }))
}
if ($delays.Count -gt 0) {
  $sortedD = @($delays | Sort-Object)
  $median = if ($sortedD.Count % 2) { $sortedD[[int][math]::Floor($sortedD.Count / 2)] } else { ($sortedD[$sortedD.Count / 2 - 1] + $sortedD[$sortedD.Count / 2]) / 2 }
  $rows += ("# counted: {0} pairs; min {1} ms; median {2} ms; max {3} ms" -f $sortedD.Count, $sortedD[0], $median, $sortedD[-1])
}
[IO.File]::WriteAllLines((Join-Path $OutDir "delays.csv"), [string[]]$rows, $utf8)

#--- no account number may remain
foreach ($f in (Get-ChildItem -LiteralPath $OutDir -File)) {
  $text = [IO.File]::ReadAllText($f.FullName)
  foreach ($k in $logins.Keys) { if ([regex]::IsMatch($text, "(?<!\d)" + $k + "(?!\d)")) { throw "account number left in $($f.Name)" } }
  if ($text -match [regex]::Escape($userHome)) { throw "user folder left in $($f.Name)" }
}
Write-Output ("{0}: {1} files, {2} account number(s) redacted, {3} scenario(s), delays: {4}" -f $Mode, (Get-ChildItem -LiteralPath $OutDir -File).Count, $logins.Count, $scenarios.Count, $rows[-1])
