<#
.SYNOPSIS
  Drives the demo run of the copier on one MetaTrader 4 and one MetaTrader 5
  demo account on this PC, and records it.

.DESCRIPTION
  Modes:
    probe  starts each terminal with only the helper script, logs the demo flag,
           symbol, quotes and the number of open items, then closes it
    A      master MetaTrader 4 -> slave MetaTrader 5
    B      master MetaTrader 5 -> slave MetaTrader 4

  Each terminal is started with a temporary startup configuration (written in
  -IniDir, outside the repository, and deleted when the terminal closes):
    MT5: [Experts] AllowLiveTrading=1, Enabled=1; [StartUp] Expert, ExpertParameters,
         Script=CopierProof\LiveAgentMT5, Symbol, Period=M1
    MT4: ExpertsEnable=true, ExpertsTrades=true, Expert, ExpertParameters,
         Script=CopierProof\LiveAgentMT4, Symbol, Period=M1
  The copier EA and the helper script (tests\live\LiveAgentMT*) share one M1 chart.
  The helper script opens and closes the master's own positions when this
  driver asks (the copier EAs never trade the master), records every change of
  positions and orders on both accounts, and exports the trade history.
  A terminal is closed by asking the helper script to close its chart (so the
  terminal's profile keeps no chart with a copier EA) and then CloseMainWindow.

  Scenarios (A and B):
    b  master closes before the slave's limit fills (slave X = 200 ticks)
    a  initial entry copied as a limit X ticks better (X measured from the two feeds)
    d  add-on copied at market
    e  partial close copied as the same fraction
    g  slave terminal restart with open copies: no duplicate order
    f  master exit: copies closed
    h  master stopped longer than the timeout: slave freezes, alerts, resumes
    c  limit price already reached when placed: sent at market (slave X = 0, buy and
       sell opened together, up to 3 attempts)

  Every account must be a demo account (checked by the helper script before
  anything else; the copier EAs check again). The driver stops if any open
  position or order is found on either account before it starts.

.EXAMPLE
  .\tools\live-run.ps1 -Mode A -Mt5Data "<MT5 data>" -Mt5Terminal "<...>\terminal64.exe" `
     -Mt4Data "<MT4 data>" -Mt4Terminal "<...>\terminal.exe" -WorkDir "<scratch>\live" -IniDir "<temp>"
#>
param(
  [Parameter(Mandatory = $true)][ValidateSet("probe", "A", "B")][string]$Mode,
  [Parameter(Mandatory = $true)][string]$Mt5Data,
  [Parameter(Mandatory = $true)][string]$Mt5Terminal,
  [Parameter(Mandatory = $true)][string]$Mt4Data,
  [Parameter(Mandatory = $true)][string]$Mt4Terminal,
  [Parameter(Mandatory = $true)][string]$WorkDir,
  [Parameter(Mandatory = $true)][string]$IniDir,
  [string]$Symbol = "EURUSD",
  [int]$FillTimeoutSec = 300
)
$ErrorActionPreference = "Stop"
[Threading.Thread]::CurrentThread.CurrentCulture = [Globalization.CultureInfo]::InvariantCulture   # 0.01, not 0,01, in the log
$copierRoot  = Join-Path $env:APPDATA "MetaQuotes\Terminal\Common\Files\CopierProof"
$commonLive  = Join-Path $copierRoot "live"
$copierMagic = 20261117
$agentMagic  = 7770001
New-Item -ItemType Directory -Force -Path $WorkDir, $IniDir, $commonLive | Out-Null
$logFile = Join-Path $WorkDir ("driver-" + $Mode + ".log")

$Terms = @{
  mt5 = @{ Name = "mt5"; Data = $Mt5Data; Exe = $Mt5Terminal; ProcName = "terminal64"; Mql = "MQL5"
           Agent = "CopierProof\LiveAgentMT5"; Master = "CopierProof\MasterMT5"; Slave = "CopierProof\SlaveMT5"
           Ini = $null; NextId = 0; Cmds = (New-Object System.Collections.ArrayList) }
  mt4 = @{ Name = "mt4"; Data = $Mt4Data; Exe = $Mt4Terminal; ProcName = "terminal"; Mql = "MQL4"
           Agent = "CopierProof\LiveAgentMT4"; Master = "CopierProof\MasterMT4"; Slave = "CopierProof\SlaveMT4"
           Ini = $null; NextId = 0; Cmds = (New-Object System.Collections.ArrayList) }
}

function Log([string]$msg) {
  $line = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss.fff") + "  " + $msg
  [IO.File]::AppendAllText($logFile, $line + "`r`n", (New-Object Text.UTF8Encoding($false)))
  Write-Host $line
}

function Read-Shared([string]$path) {
  if (-not (Test-Path -LiteralPath $path)) { return "" }
  for ($i = 0; $i -lt 10; $i++) {
    try {
      $fs = New-Object IO.FileStream($path, [IO.FileMode]::Open, [IO.FileAccess]::Read, ([IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete))
      try { $sr = New-Object IO.StreamReader($fs, [Text.Encoding]::Default); return $sr.ReadToEnd() } finally { $fs.Close() }
    } catch { Start-Sleep -Milliseconds 30 }
  }
  return ""
}

function Write-Cmds($t) {
  $path = Join-Path $commonLive ($t.Name + ".in")
  $tmp = $path + ".ps-tmp"
  [IO.File]::WriteAllText($tmp, (($t.Cmds -join "`n") + "`n"), [Text.Encoding]::ASCII)
  for ($i = 0; $i -lt 100; $i++) {
    try { Move-Item -LiteralPath $tmp -Destination $path -Force; return } catch { Start-Sleep -Milliseconds 20 }
  }
  throw "cannot write $path"
}

function ConvertFrom-Result([string]$line) {
  $f = $line.Split("|")
  $h = @{ Id = $f[0]; Status = $f[1]; Verb = $f[2]; Line = $line }
  for ($i = 3; $i -lt $f.Count; $i++) {
    $kv = $f[$i].Split("=", 2)
    if ($kv.Count -eq 2) { $h[$kv[0]] = $kv[1] } else { $h["text"] = $f[$i] }
  }
  return $h
}

function Send([string]$plat, [string]$verb, [string[]]$cmdArgs = @(), [int]$timeoutSec = 60) {
  $t = $Terms[$plat]
  $t.NextId++
  $id = $t.NextId
  $line = ((@([string]$id, $verb) + $cmdArgs + @("END")) -join "|")
  [void]$t.Cmds.Add($line)
  Write-Cmds $t
  Log ("{0} <- {1}" -f $plat, $line)
  $outPath = Join-Path $commonLive ($plat + ".out")
  $deadline = (Get-Date).AddSeconds($timeoutSec)
  while ((Get-Date) -lt $deadline) {
    $hit = (Read-Shared $outPath) -split "`r?`n" | Where-Object { $_ -like "$id|*" } | Select-Object -First 1
    if ($hit) {
      Log ("{0} -> {1}" -f $plat, $hit)
      return (ConvertFrom-Result $hit)
    }
    Start-Sleep -Milliseconds 50
  }
  throw "$plat command $id $verb got no answer in $timeoutSec s"
}

function Get-Status([string]$plat) {
  $h = @{}
  foreach ($kv in ((Read-Shared (Join-Path $commonLive ($plat + ".status"))).Trim() -split "\|")) {
    $p = $kv.Split("=", 2)
    if ($p.Count -eq 2) { $h[$p[0]] = $p[1] }
  }
  return $h
}

function Get-Items([string]$plat) {
  $items = @()
  foreach ($l in ((Read-Shared (Join-Path $commonLive ($plat + ".state"))) -split "`r?`n")) {
    if ($l -eq "") { continue }
    $f = $l.Split(";")
    $items += [pscustomobject]@{ Kind = $f[0]; Ticket = [long]$f[1]; Type = $f[2]; Symbol = $f[3]; Lots = [double]$f[4]
                                 Price = [double]$f[5]; Magic = [long]$f[6]; Comment = ($f[7..($f.Count - 1)] -join ";") }
  }
  return , $items
}

function Wait-Until([string]$what, [int]$timeoutSec, [scriptblock]$cond) {
  $deadline = (Get-Date).AddSeconds($timeoutSec)
  while ((Get-Date) -lt $deadline) {
    if (& $cond) { Log "ok: $what"; return $true }
    Start-Sleep -Milliseconds 100
  }
  Log "TIMEOUT after $timeoutSec s: $what"
  return $false
}

function Get-TermProcs([string]$plat) {
  $t = $Terms[$plat]
  return @(Get-Process -Name $t.ProcName -ErrorAction SilentlyContinue | Where-Object { $_.Path -eq $t.Exe })
}

#--- a chart with a copier EA left in a profile would start that EA on the next terminal start
function Assert-NoCopierCharts([string]$plat) {
  $t = $Terms[$plat]
  $dir = if ($plat -eq "mt5") { Join-Path $t.Data "MQL5\Profiles\Charts" } else { Join-Path $t.Data "profiles" }
  foreach ($f in (Get-ChildItem -LiteralPath $dir -Recurse -File -ErrorAction SilentlyContinue | Where-Object { $_.Extension -ieq ".chr" })) {
    if ([IO.File]::ReadAllText($f.FullName) -match "CopierProof") { throw "$plat profile chart $($f.Name) in $($f.Directory.Name) holds a CopierProof program" }
  }
}

function Write-Preset([string]$plat, [string]$name, [hashtable]$values) {
  $t = $Terms[$plat]
  $file = "CopierProof-$name.set"
  $dir = Join-Path $t.Data ($t.Mql + "\Presets")
  New-Item -ItemType Directory -Force -Path $dir | Out-Null
  $text = (($values.GetEnumerator() | Sort-Object Name | ForEach-Object { "{0}={1}" -f $_.Name, $_.Value }) -join "`r`n") + "`r`n"
  $enc = if ($plat -eq "mt5") { New-Object Text.UnicodeEncoding($false, $true) } else { [Text.Encoding]::ASCII }
  [IO.File]::WriteAllText((Join-Path $dir $file), $text, $enc)
  Log "$plat preset $file : $($text.Trim() -replace "`r`n", ', ')"
  return $file
}

function Start-Term([string]$plat, [string]$expert, [string]$preset) {
  $t = $Terms[$plat]
  if ((Get-TermProcs $plat).Count -gt 0) { throw "$plat terminal is already open" }
  Assert-NoCopierCharts $plat
  foreach ($ext in @("status", "in")) { Remove-Item -LiteralPath (Join-Path $commonLive "$plat.$ext") -ErrorAction SilentlyContinue }
  $t.Cmds.Clear()
  $ini = Join-Path $IniDir ("cp-live-" + $plat + "-" + [guid]::NewGuid().ToString("N").Substring(0, 8) + ".ini")
  if ($plat -eq "mt5") {
    $lines = @("[Experts]", "AllowLiveTrading=1", "AllowDllImport=0", "Enabled=1", "Account=0", "Profile=0", "[StartUp]")
    if ($expert) { $lines += @("Expert=$expert", "ExpertParameters=$preset") }
    $lines += @("Script=$($t.Agent)", "Symbol=$Symbol", "Period=M1")
    [IO.File]::WriteAllText($ini, (($lines -join "`r`n") + "`r`n"), (New-Object Text.UnicodeEncoding($false, $true)))
    $argList = "/config:`"$ini`""
  } else {
    $lines = @("ExpertsEnable=true", "ExpertsDllImport=false", "ExpertsExpImport=false", "ExpertsTrades=true", "Symbol=$Symbol", "Period=M1")
    if ($expert) { $lines += @("Expert=$expert", "ExpertParameters=$preset") }
    $lines += "Script=$($t.Agent)"
    [IO.File]::WriteAllText($ini, (($lines -join "`r`n") + "`r`n"), [Text.Encoding]::ASCII)
    $argList = "`"$ini`""
  }
  $t.Ini = $ini
  Log ("{0} start: expert={1} preset={2} ini={3}" -f $plat, $expert, $preset, [IO.Path]::GetFileName($ini))
  Start-Process -FilePath $t.Exe -ArgumentList $argList | Out-Null
  $ok = Wait-Until "$plat helper script connected" 180 { $s = Get-Status $plat; $s["connected"] -eq "1" -and $s.ContainsKey("demo") }
  if (-not $ok) { throw "$plat helper script did not report a connection in 180 s" }
  $s = Get-Status $plat
  if ($s["demo"] -ne "1") { throw "$plat account is NOT a demo account: run stopped" }
  Log ("{0} status: {1}" -f $plat, ((($s.GetEnumerator() | Where-Object { $_.Name -ne "tick" } | Sort-Object Name | ForEach-Object { "$($_.Name)=$($_.Value)" })) -join " "))
}

function Stop-Term([string]$plat) {
  $t = $Terms[$plat]
  try { Send $plat "QUIT" @() 20 | Out-Null } catch { Log "$plat QUIT not answered: $_" }
  Start-Sleep -Milliseconds 700
  foreach ($p in (Get-TermProcs $plat)) {
    [void]$p.CloseMainWindow()
    if (-not $p.WaitForExit(90000)) { throw "$plat terminal did not close in 90 s" }
  }
  if ($t.Ini) { Remove-Item -LiteralPath $t.Ini -ErrorAction SilentlyContinue; $t.Ini = $null }
  Log "$plat terminal closed"
  Assert-NoCopierCharts $plat
}

function Save-AgentFiles([string]$dest) {
  New-Item -ItemType Directory -Force -Path $dest | Out-Null
  foreach ($f in (Get-ChildItem -LiteralPath $commonLive -File)) {
    if ($f.Extension -in @(".events", ".out", ".history", ".state")) { Copy-Item -LiteralPath $f.FullName -Destination $dest -Force }
  }
}

function Clear-Live {
  Get-ChildItem -LiteralPath $commonLive -File | Remove-Item -Force
}

#==================================================================== probe
if ($Mode -eq "probe") {
  Clear-Live
  foreach ($plat in @("mt5", "mt4")) {
    Start-Term $plat "" ""
    Log ("{0} open items: {1}" -f $plat, (Get-Items $plat).Count)
    Send $plat "PING" | Out-Null
  }
  #--- both feeds for 60 s
  for ($i = 0; $i -lt 12; $i++) {
    $a = Get-Status "mt4"; $b = Get-Status "mt5"
    Log ("quotes: mt4 {0}/{1}  mt5 {2}/{3}  mt4-mt5 bid {4:N0} ticks" -f $a["bid"], $a["ask"], $b["bid"], $b["ask"], (([double]$a["bid"] - [double]$b["bid"]) / 0.00001))
    Start-Sleep -Seconds 5
  }
  foreach ($plat in @("mt5", "mt4")) { Stop-Term $plat }
  Save-AgentFiles (Join-Path $WorkDir "probe")
  Log "probe done"
  return
}

#==================================================================== direction A or B
$master = if ($Mode -eq "A") { "mt4" } else { "mt5" }
$slave  = if ($Mode -eq "A") { "mt5" } else { "mt4" }
$chan   = "live" + $Mode
$snap   = Join-Path $copierRoot ($chan + ".snap")

function Copies { return @((Get-Items $slave) | Where-Object { $_.Magic -eq $copierMagic }) }
function CopyOf([string]$masterTicket) { return @(Copies | Where-Object { $_.Comment -eq "CP:$masterTicket" }) }
function PosLots {
  $s = 0.0
  foreach ($i in (Copies)) { if ($i.Kind -eq "position") { $s += $i.Lots } }
  return [math]::Round($s, 2)
}
function Mark([string]$id, [string]$what) { Log ("=== scenario {0} {1}" -f $id, $what) }
function Must($r) { if ($r.Status -ne "OK") { throw "command failed: $($r.Line)" }; return $r }
function Format-Copies { return ((Copies | ForEach-Object { "{0} #{1} {2} {3} @{4} {5}" -f $_.Kind, $_.Ticket, $_.Type, $_.Lots, $_.Price, $_.Comment }) -join "; ") }

Log "run $Mode start: master=$master slave=$slave channel=$chan"
Clear-Live
Remove-Item -LiteralPath $snap -ErrorAction SilentlyContinue
$masterPreset = Write-Preset $master "$Mode-master" @{ InpChannel = $chan }
$bigPreset    = Write-Preset $slave "$Mode-slave-x200" @{ InpChannel = $chan; InpTicksBetter = 200 }
$failed = $null
$traded = $false
$runStart = Get-Date
try {
  Start-Term $master $Terms[$master].Master $masterPreset
  if ((Get-Items $master).Count -ne 0) { throw "master account has open positions or orders: run stopped, nothing touched" }
  Start-Term $slave $Terms[$slave].Slave $bigPreset
  if ((Get-Items $slave).Count -ne 0) { throw "slave account has open positions or orders: run stopped, nothing touched" }
  if (-not (Wait-Until "master snapshot written" 30 { (Test-Path -LiteralPath $snap) -and ((Get-Date) - (Get-Item -LiteralPath $snap).LastWriteTime).TotalSeconds -lt 3 })) { throw "master EA is not writing $chan.snap" }

  #--- the two feeds: master ask - slave ask, slave bid - master bid, in ticks
  Start-Sleep -Seconds 5
  $tick = [double](Get-Status $slave)["tick_size"]
  $askD = @(); $bidD = @()
  for ($i = 0; $i -lt 20; $i++) {
    $sm = Get-Status $master; $ss = Get-Status $slave
    $askD += ([double]$sm["ask"] - [double]$ss["ask"]) / $tick
    $bidD += ([double]$ss["bid"] - [double]$sm["bid"]) / $tick
    Start-Sleep -Milliseconds 500
  }
  $askMax = ($askD | Measure-Object -Maximum).Maximum; $askMin = ($askD | Measure-Object -Minimum).Minimum
  $bidMin = ($bidD | Measure-Object -Minimum).Minimum
  Log ("feeds over 10 s: master ask - slave ask = {0:N1}..{1:N1} ticks; slave bid - master bid min {2:N1} ticks; tick size {3}" -f $askMin, $askMax, $bidMin, $tick)
  #--- a terminal shows its last saved quotes for a moment after it connects: such a sample stops the run
  if ([math]::Abs($askMax) -gt 50 -or [math]::Abs($askMin) -gt 50 -or [math]::Abs($bidMin) -gt 50) { throw "feeds differ by more than 50 ticks: stale quotes?" }
  $X = [math]::Max(3, [int][math]::Ceiling($askMax) + 3)
  Log "X for scenarios a, d, e, g, f, h: $X ticks (c uses X = 0)"

  #--- b: master closes before the limit fills (X = 200 ticks)
  Mark "b" "start"
  $traded = $true
  $ob = Must (Send $master "OPEN" @("buy", "0.01", "b"))
  if (Wait-Until "slave limit for master #$($ob.ticket)" 30 { @(CopyOf $ob.ticket | Where-Object { $_.Kind -eq "order" }).Count -eq 1 }) {
    Log ("b: master open {0}, slave: {1}" -f $ob.price, (Format-Copies))
  }
  Start-Sleep -Seconds 3
  Must (Send $master "CLOSE" @($ob.ticket, "0")) | Out-Null
  [void](Wait-Until "slave pending deleted" 30 { @(Copies).Count -eq 0 })
  Start-Sleep -Seconds 5
  Log ("b: slave copies 5 s after: [{0}]" -f (Format-Copies))
  Mark "b" "end"

  #--- restart the slave with X ticks
  Stop-Term $slave
  $xPreset = Write-Preset $slave "$Mode-slave-x$X" @{ InpChannel = $chan; InpTicksBetter = $X }
  Start-Term $slave $Terms[$slave].Slave $xPreset

  #--- a: initial entry as a limit X ticks better
  Mark "a" "start"
  $oa = Must (Send $master "OPEN" @("buy", "0.01", "a"))
  [void](Wait-Until "slave copy of master #$($oa.ticket)" 30 { @(CopyOf $oa.ticket).Count -ge 1 })
  $ca = CopyOf $oa.ticket
  Log ("a: master open {0}, slave: {1}" -f $oa.price, (Format-Copies))
  if (@($ca | Where-Object { $_.Kind -eq "order" }).Count -gt 0) {
    $lim = ($ca | Where-Object { $_.Kind -eq "order" } | Select-Object -First 1).Price
    Log ("a: limit {0} = master {1} - {2:N1} ticks of {3}" -f $lim, $oa.price, (([double]$oa.price - $lim) / $tick), $tick)
    [void](Wait-Until "slave limit filled" $FillTimeoutSec { @(CopyOf $oa.ticket | Where-Object { $_.Kind -eq "order" }).Count -eq 0 -and @(CopyOf $oa.ticket | Where-Object { $_.Kind -eq "position" }).Count -eq 1 })
    Log ("a: slave after the wait: {0}" -f (Format-Copies))
  } elseif (@($ca).Count -gt 0) {
    Log "a: no limit, the copy went at market (limit price already reached)"
  } else {
    Log "a: NO copy on the slave after 30 s"
  }
  Mark "a" "end"

  #--- d: add-on at market
  Mark "d" "start"
  $od = Must (Send $master "OPEN" @("buy", "0.02", "d"))
  [void](Wait-Until "slave add-on 0.02 at market" 30 { @(CopyOf $od.ticket | Where-Object { $_.Kind -eq "position" -and [math]::Abs($_.Lots - 0.02) -lt 1e-6 }).Count -eq 1 })
  Log ("d: slave: {0}" -f (Format-Copies))
  Mark "d" "end"

  #--- e: partial close of the add-on, 0.01 of 0.02
  Mark "e" "start"
  $before = PosLots
  Must (Send $master "CLOSE" @($od.ticket, "0.01")) | Out-Null
  [void](Wait-Until "slave closed 0.01 (position lots $before -> $([math]::Round($before - 0.01, 2)))" 30 { [math]::Abs((PosLots) - ($before - 0.01)) -lt 1e-6 })
  Start-Sleep -Seconds 3
  Log ("e: slave 3 s after: position lots {0}; {1}" -f (PosLots), (Format-Copies))
  Mark "e" "end"

  #--- g: slave restart with open copies
  Mark "g" "start"
  $ticketsBefore = (@(Copies | ForEach-Object { $_.Ticket } | Sort-Object) -join ",")
  Log "g: slave tickets before restart: $ticketsBefore"
  Stop-Term $slave
  Start-Sleep -Seconds 5
  Start-Term $slave $Terms[$slave].Slave $xPreset
  Start-Sleep -Seconds 20
  $ticketsAfter = (@(Copies | ForEach-Object { $_.Ticket } | Sort-Object) -join ",")
  Log ("g: slave tickets 20 s after restart: {0} ({1})" -f $ticketsAfter, $(if ($ticketsAfter -eq $ticketsBefore) { "same" } else { "DIFFERENT" }))
  Mark "g" "end"

  #--- f: master exit
  Mark "f" "start"
  Must (Send $master "CLOSEALL" @([string]$agentMagic)) | Out-Null
  [void](Wait-Until "slave copies closed" 30 { @(Copies).Count -eq 0 })
  Mark "f" "end"

  #--- h: master stopped longer than the timeout
  Mark "h" "start"
  $oh = Must (Send $master "OPEN" @("buy", "0.01", "h"))
  [void](Wait-Until "slave copy of master #$($oh.ticket)" 30 { @(CopyOf $oh.ticket).Count -ge 1 })
  $copiesBefore = Format-Copies
  Stop-Term $master
  Log "h: master terminal stopped; waiting 25 s"
  Start-Sleep -Seconds 25
  $copiesDuring = Format-Copies
  Log ("h: slave copies while frozen: {0} ({1})" -f $copiesDuring, $(if ($copiesDuring -eq $copiesBefore) { "unchanged" } else { "CHANGED" }))
  Start-Term $master $Terms[$master].Master $masterPreset
  Start-Sleep -Seconds 10
  Must (Send $master "CLOSEALL" @([string]$agentMagic)) | Out-Null
  [void](Wait-Until "slave copies closed" 30 { @(Copies).Count -eq 0 })
  Mark "h" "end"

  #--- c: limit price already reached when placed. With X = 0 the buy limit is the
  #--- master's ask and the sell limit the master's bid, so unless the slave feed moved
  #--- away on both sides, one of the two is already reached when the slave places it.
  Mark "c" "start"
  Stop-Term $slave
  $zeroPreset = Write-Preset $slave "$Mode-slave-x0" @{ InpChannel = $chan; InpTicksBetter = 0 }
  Start-Term $slave $Terms[$slave].Slave $zeroPreset
  $seen = $false
  for ($attempt = 1; $attempt -le 3 -and -not $seen; $attempt++) {
    $ocb = Must (Send $master "OPEN" @("buy", "0.01", "cb$attempt"))
    $ocs = Must (Send $master "OPEN" @("sell", "0.01", "cs$attempt"))
    [void](Wait-Until "slave copies of both" 30 { (@(CopyOf $ocb.ticket).Count -ge 1) -and (@(CopyOf $ocs.ticket).Count -ge 1) })
    Start-Sleep -Seconds 2
    $events = (Read-Shared (Join-Path $commonLive ($slave + ".events"))) -split "`r?`n"
    $atMarket = @(foreach ($tk in @($ocb.ticket, $ocs.ticket)) {
        $mine = @($events | Where-Object { $_ -like "*;CP:$tk" })
        if (@($mine | Where-Object { $_ -match ";ADD;position;" }).Count -gt 0 -and @($mine | Where-Object { $_ -match ";ADD;order;" }).Count -eq 0) { $tk }
      })
    Log ("c attempt {0}: slave: {1}; placed at market (no limit order ever listed): {2}" -f $attempt, (Format-Copies), $(if ($atMarket.Count) { $atMarket -join "," } else { "none" }))
    $seen = $atMarket.Count -gt 0
    Must (Send $master "CLOSEALL" @([string]$agentMagic)) | Out-Null
    [void](Wait-Until "slave copies closed or deleted" 30 { @(Copies).Count -eq 0 })
  }
  Mark "c" "end"
} catch {
  $failed = $_.ToString()
  Log "RUN ERROR: $failed"
} finally {
  #--- leave both accounts flat (only what this run opened: the driver's magic on the
  #--- master, the copier's magic on the slave), export the history, close both terminals
  $notDemo = ($failed -and $failed -match "NOT a demo")
  foreach ($plat in @($master, $slave)) {
    if ($notDemo) { break }
    try {
      if ((Get-TermProcs $plat).Count -eq 0) {
        if (-not $traded) { continue }
        Start-Term $plat "" ""
      }
      $magic = if ($plat -eq $master) { $agentMagic } else { $copierMagic }
      #--- the master is flattened first: give the copier the chance to close its copies itself
      if ($traded -and $plat -eq $slave) { [void](Wait-Until "copier closed its copies" 15 { @(Copies).Count -eq 0 }) }
      if ($traded -and @((Get-Items $plat) | Where-Object { $_.Magic -eq $magic }).Count -gt 0) {
        Send $plat "FLAT" @([string]$magic) | Out-Null
      }
      Send $plat "EXPORT" @([string][int](((Get-Date) - $runStart).TotalSeconds + 300)) | Out-Null
      Log ("{0} final open items: {1}" -f $plat, (Get-Items $plat).Count)
    } catch { Log "$plat final step failed: $_" }
  }
  foreach ($plat in @($slave, $master)) {
    if ((Get-TermProcs $plat).Count -gt 0) { try { Stop-Term $plat } catch { Log "$plat stop failed: $_" } }
  }
  Save-AgentFiles (Join-Path $WorkDir $Mode)
  Log "run $Mode end"
}
if ($failed) { exit 1 }
