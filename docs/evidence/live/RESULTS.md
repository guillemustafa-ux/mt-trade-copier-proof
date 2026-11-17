# Demo run, 2026-11-17

Both directions of the copier, on two **demo** accounts on one Windows PC. Every file named below is in this folder.

## Setup

| | Master side | Slave side |
|---|---|---|
| Direction A | MetaTrader 4 build 1492, `MasterMT4`, MetaQuotes-Demo account `<demo-mt4>` | MetaTrader 5 build 6323, `SlaveMT5`, MetaQuotes-Demo hedging account `<demo-mt5>` |
| Direction B | MetaTrader 5, `MasterMT5`, `<demo-mt5>` | MetaTrader 4, `SlaveMT4`, `<demo-mt4>` |

- Symbol `EURUSD` on both sides (same name, no suffix map needed), tick size 0.00001, minimum lot 0.01, lot step 0.01. Broker minimum distance for pending orders (stops level): 0 points on MetaTrader 5, **8 points on MetaTrader 4** (`driver.log`, `status:` lines).
- Lots 0.01, except the add-on: 0.02, so that it can be partly closed.
- The master's positions are opened and closed by a helper script (`tests/live/LiveAgentMT4.mq4`, `LiveAgentMT5.mq5`) on the master's chart, on command from `tools/live-run.ps1`. The copier EAs never trade the master. The same helper on the slave only records, and flattens the slave at the end.
- The helper checks that the account is a demo account before anything else (`demo=1` in every `status:` line of `driver.log`), and the four EAs check it again.
- Redacted by `tools/live-evidence.ps1`: account numbers (`<demo-mt4>`, `<demo-mt5>`), IP addresses (`<ip>`), folders (`<MT4 data>`, `<MT5 data>`, `<user home>`, and `<scratch>` for the folder of the temporary startup configurations), the terminals' start-up line with Windows version, CPU, memory, disk and time zone (`<system details>`), and access point names (`<access point>`).

Files per run: `driver.log` (the driver's own log), `mt4-experts.log`, `mt4-journal.log`, `mt5-experts.log`, `mt5-journal.log` (the terminals' logs for the run, UTF-16 converted to UTF-8), `scenario-<x>.log` (all five merged by time for one scenario), `agent-*.events.csv` (every change of each account's positions and orders), `agent-*.history.csv` (deal and order history exported by the helper), `delays.csv`.

Five runs, in this order (local time, first and last line of each `driver.log`):

| Folder | Direction | Time | EAs | Result |
|---|---|---|---|---|
| `A-run1/` | A | 15:11:50-15:16:45 | before the two fixes below | 7 of 8 scenarios; c not produced (driver bug) |
| `A-run2/` | A | 15:20:09-15:23:42 | before the two fixes below | 8 of 8 |
| `B-run1/` | B | 15:24:17-15:25:32 | before the two fixes below | a failed (copier bug, fixed); d passed; run stopped in e (helper bug, fixed) |
| `B/` | B | 15:28:53-15:33:37 | as committed | 8 of 8 |
| `A/` | A | 16:09:54-16:14:05 | as committed | 8 of 8 |

## Results

### Direction A: master MetaTrader 4 -> slave MetaTrader 5 (folder `A/`, committed EAs)

| Scenario | Expected | Observed | Result | Evidence |
|---|---|---|---|---|
| b. Master closes before the limit fills | Slave pending deleted, nothing opened | X = 200. Master buy 0.01 at 1.10125; slave buy limit at 1.09925 (200 ticks) placed 354 ms later. Master closed 3.8 s later; slave deleted the pending 548 ms after the master close; no slave order or position 5 s later. | Pass | `A/scenario-b.log`, `A/delays.csv`, `A/driver.log` |
| a. Initial entry | Limit X ticks better | X = 9 (master ask minus slave ask was -2 to 6 ticks over 10 s; the driver sets X to the largest gap rounded up, plus 3, minimum 3). Master buy at 1.10122; slave buy limit at 1.10113 = 9 ticks of 0.00001 better, placed 340 ms later; filled about 114 s later (`mt5-experts.log` lines 12 and 14). | Pass | `A/scenario-a.log`, `A/driver.log` |
| d. Add-on | Copied at market | Master add-on buy 0.02; slave market buy 0.02, 456 ms later. | Pass | `A/scenario-d.log` |
| e. Partial close | Same fraction, rounded down to the lot step | Master closed 0.01 of the 0.02 add-on (MetaTrader 4 gave the remainder a new ticket, `from #...`); slave closed 0.01 of its 0.02 copy, 383 ms later. Slave total 0.03 -> 0.02, unchanged 3 s later. MetaTrader 5 left the slave copy's comment empty after the partial close (`A/mt5-experts.log` line 19, `A/driver.log` line 49). | Pass | `A/scenario-e.log` |
| g. Slave restart with open copies | No duplicate order | Slave terminal closed and restarted: `2 link(s) loaded`; the same two tickets 20 s later; no order placed after the restart. | Pass | `A/scenario-g.log` |
| f. Master exit | Copies closed at the same time | Master closed both positions; slave closed both copies 471 ms and 544 ms after each master close. | Pass | `A/scenario-f.log`, `A/delays.csv` |
| h. Master stopped longer than 10 s | Slave freezes, one alert; master back: resumes, one alert | `MasterMT4` removed at 16:13:06.200. Slave `ALERT ... slave frozen` once, at 16:13:17.085; its pending limit unchanged while frozen. Master back: `ALERT ... slave resumed` once, at 16:13:38.081. Master close -> pending deleted 446 ms later. | Pass | `A/scenario-h.log`, `A/mt5-experts.log` |
| c. Limit price already reached | Sent at market | X = 0 (limit = the master's own price), buy and sell opened together: both copies sent at market with the reason `limit price already reached: market`, 438 ms and 474 ms later. | Pass | `A/scenario-c.log` |

No send failed in this run (no `FAILED` line in `A/mt5-experts.log`).

### Direction B: master MetaTrader 5 -> slave MetaTrader 4 (folder `B/`, committed EAs)

| Scenario | Expected | Observed | Result | Evidence |
|---|---|---|---|---|
| b. Master closes before the limit fills | Slave pending deleted, nothing opened | X = 200. Master buy at 1.10149; slave buy limit at 1.09949 placed 479 ms later; deleted 446 ms after the master close; nothing opened. | Pass | `B/scenario-b.log` |
| a. Initial entry | Limit X ticks better | X input = 3, broker minimum distance 8 points: limit moved to 1.10141, 8 ticks below the master's 1.10149 (`moved to the broker's minimum distance`). The first send, on the slave EA's first cycle 80 ms after the master's entry, returned error 130 and never reached the server: no Journal line for it (`B/mt4-experts.log` line 30 at 15:29:31.243, the same millisecond as that cycle's first line; the Journal goes from 15:29:30.738 to 15:29:33.070, `B/mt4-journal.log` lines 25-26). Cause not established. The slave sent it again after `InpRetrySeconds` (2 s) and it was accepted. Not counted in the delays (see Copy delay). Filled about 145 s later. | Pass, one refused send | `B/scenario-a.log`, `B/mt4-experts.log`, `B/mt4-journal.log` |
| d. Add-on | Copied at market | Slave market buy 0.02, 409 ms after the master's add-on. | Pass | `B/scenario-d.log` |
| e. Partial close | Same fraction, rounded down | Slave closed 0.01 of its 0.02 copy, 384 ms later. MetaTrader 4 gave the slave's remainder a new ticket (`from #...`); it stayed linked (restart in g, closed in f). | Pass | `B/scenario-e.log` |
| g. Slave restart with open copies | No duplicate order | `2 link(s) loaded`; same tickets, including the renumbered remainder, 20 s later; no order placed. | Pass | `B/scenario-g.log` |
| f. Master exit | Copies closed at the same time | 567 ms and 616 ms after each master close. | Pass | `B/scenario-f.log`, `B/delays.csv` |
| h. Master stopped longer than 10 s | One alert each way | `MasterMT5` removed at 15:32:41.390; `ALERT ... slave frozen` once, at 15:32:52.181; pending unchanged; master back at 15:33:11.143; `ALERT ... slave resumed` once, at 15:33:12.305. The limit itself was placed 6.4 s after the master's entry: three sends at the minimum distance returned error 130 without reaching the server (`B/mt4-experts.log` lines 63-65; no Journal line between 15:32:34.479 and 15:32:41.000, `B/mt4-journal.log` lines 49-50); the fourth, 2 s after the third, was accepted. Cause not established. | Pass; slow placement noted | `B/scenario-h.log`, `B/mt4-experts.log` |
| c. Limit price already reached | Sent at market | X = 0, buy and sell together: both at market, `limit price already reached: market`, 561 ms and 568 ms (the first is not counted below: the slave EA's first cycle came 28 ms after the master's buy). | Pass | `B/scenario-c.log` |

**Refused sends (error 130) in every run**, counted from the `FAILED` lines of the slave's Experts log: `A/` 0, `B/` 4 (1 in a, 3 in h, each followed by a retry 2 s later; the last retry of each was accepted), `A-run1/` and `A-run2/` 0, `B-run1/` 16 (all in a, none accepted). None of the 20 has a Journal line. A request the server rejects does leave one: `B-run1/mt4-journal.log` line 32, `closing at 1.10161 failed [Invalid parameters]` (the helper closing an order already closed).

### Earlier runs, kept as they happened

| Run | What happened | Cause | What changed |
|---|---|---|---|
| A, first run (`A-run1/`) | The copier did b, a, d, e, g, f, h as in the later runs. Scenario c was **not produced**: the driver waited for the MetaTrader 4 price to move, then restarted the slave, but the MetaTrader 5 quote was 1 tick above the buy limit, so both copies were placed as limits (correct behavior, scenario not exercised). The driver also logged false lines in a: `TIMEOUT after 30 s: slave copy of master #...` (`driver.log` line 33) and `a: no limit, the copy went at market` (line 35). The slave had placed a limit 483 ms after the master's entry (`mt5-experts.log` line 12); it filled at 15:12:58.243 (line 14), so after the false 30 s wait the driver saw only a position. | Driver: a single result has no `.Count` in Windows PowerShell 5.1, so the wait never saw the copy; the c trigger used the master's quotes. | Driver fixed; c redone with X = 0 and a buy and a sell opened together. |
| A, second run (`A-run2/`) | All eight scenarios passed, with the EAs from before the two fixes below. X = 7 with a logged gap of `0.0..3.0` ticks: the driver takes the gap rounded up, plus 3; the gap is logged to one decimal, and X = 7 means it was computed just above 3 (in floating point, (1.10200 - 1.10197) / 0.00001 = 3.0000000000197, which rounds up to 4). The individual samples were not logged. 13 counted delays: min 336 ms, median 478 ms, max 621 ms (`A-run2/delays.csv`). | It ran before the B fixes existed. | Re-run as `A/` with the committed EAs. |
| B, first run (`B-run1/`) | **a failed**: MetaTrader 4 refused the buy limit at 1.10160, 3 ticks below the master's entry of 1.10163, with error 130, 16 times from 15:24:56.728 to 15:25:26.056; no Journal line for any of them (`mt4-journal.log` lines 25-26); no copy. d passed (413 ms). Then the master helper's partial close failed and the driver stopped, flattening both accounts. | Copier: the MetaTrader 4 demo's stops level is 8 points, and the limit was 5 points below the MetaTrader 4 ask of 1.10165 read just before (`driver.log` line 29), inside that distance. Helper: `PositionClosePartial` returned false and sent nothing (no Journal line at 15:25:27.283, `mt5-journal.log` lines 31-32; the result still held the previous order's retcode 10009 and price, `driver.log` line 45). In `MQL5\Include\Trade\Trade.mqh` (build 6323), the `CTrade` constructor reads `ACCOUNT_MARGIN_MODE` once through `SetMarginMode()`, and `PositionClosePartial` returns false before sending when that mode is not hedging. The helper's `CTrade` is a global object, built when the script loaded, before the login line of the Journal (`mt5-journal.log` lines 9-10). That it read a non-hedging mode at that moment is an inference: the value was not logged. | Copier: a limit closer to the market than the broker's minimum distance is moved further away (still at least X ticks better), test `S1_LimitInsideTheBrokerMinimumDistanceMovesFurtherAway` and a mutant. `SlaveMT5` and the helper call `SetMarginMode()` again once logged in (no deterministic test; `SlaveMT5`'s partial close worked in `A-run2/` without it and in `A/` with it). |

## Copy delay

Each row of `delays.csv` pairs a master action, timed by the helper's `OPEN done` or `CLOSE done` line (written when the master's server confirmed it), with the slave EA's line for the copy (written when the slave's server confirmed it). Both come from the terminals' own logs on the same PC clock. A pair is not counted when the slave EA's first connected cycle (its `slave reading` line) came after the master action: the slave had just been restarted on purpose, so the pair measures its start-up, not a copy.

Two pairs are not counted, both in `B/`: scenario a, 2203 ms (it also contains one refused send and the 2 s wait before the retry), and scenario c, 561 ms.

Counted pairs of the runs with the committed EAs (`A/delays.csv`, `B/delays.csv`):

| | Pairs | Min | Median | Max |
|---|---|---|---|---|
| All copy actions | 24 | 340 ms | 480 ms | 6430 ms (B, h: three refused sends) |
| Exits only (close, partial close, delete) | 14 | 383 ms | 546 ms | 658 ms |
| Master exits in f (full close) | 4 | 471 ms | 555.5 ms | 616 ms |
| Direction A | 13 | 340 ms | 471 ms | 557 ms |
| Direction B | 11 | 384 ms | 568 ms | 6430 ms |

What the delay is made of: the master EA lists positions every 200 ms, the slave reads the file every 200 ms, and each order goes to the MetaQuotes demo server and back (the MetaTrader 5 journals of `A/` and `B/` show `done in` 240.9 to 317.4 ms for each of their 26 orders).

## Final state

Both accounts were left flat: `final-check.log`, taken after the last run (`A/`), starts each terminal with only the helper script and reads `demo=1`, `positions=0 orders=0` on both. `final-check-after-B.log` is the same check after `B/`.
