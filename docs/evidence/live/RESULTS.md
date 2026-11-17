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
- Account numbers are replaced by `<demo-mt4>` and `<demo-mt5>`, IP addresses by `<ip>`, folders by `<MT4 data>`, `<MT5 data>`, `<user home>` (`tools/live-evidence.ps1`).

Files per run: `driver.log` (the driver's own log), `mt4-experts.log`, `mt4-journal.log`, `mt5-experts.log`, `mt5-journal.log` (the terminals' logs for the run, UTF-16 converted to UTF-8), `scenario-<x>.log` (all five merged by time for one scenario), `agent-*.events.csv` (every change of each account's positions and orders), `agent-*.history.csv` (deal and order history exported by the helper), `delays.csv`.

## Results

### Direction A: master MetaTrader 4 -> slave MetaTrader 5 (folder `A/`, second run)

| Scenario | Expected | Observed | Result | Evidence |
|---|---|---|---|---|
| b. Master closes before the limit fills | Slave pending deleted, nothing opened | X = 200. Master buy 0.01 at 1.10197; slave buy limit at 1.09997 (200 ticks) placed 374 ms later. Master closed 3 s later; slave deleted the pending 543 ms after the master close; no slave order or position 5 s later. | Pass | `A/scenario-b.log`, `A/delays.csv` |
| a. Initial entry | Limit X ticks better | X = 7 (master ask minus slave ask was 0 to 3 ticks over 10 s; the driver sets X 3 ticks above the largest gap, minimum 3). Master buy at 1.10199; slave buy limit at 1.10192 = 7 ticks of 0.00001 better, placed 511 ms later; filled about 74 s later. | Pass | `A/scenario-a.log`, `A/driver.log` |
| d. Add-on | Copied at market | Master add-on buy 0.02; slave market buy 0.02, 482 ms later. | Pass | `A/scenario-d.log` |
| e. Partial close | Same fraction, rounded down to the lot step | Master closed 0.01 of the 0.02 add-on (MetaTrader 4 renumbered the remainder); slave closed 0.01 of its 0.02 copy, 450 ms later. Slave total 0.03 -> 0.02, unchanged 3 s later. | Pass | `A/scenario-e.log` |
| g. Slave restart with open copies | No duplicate order | Slave terminal closed and restarted: `2 link(s) loaded`; the same two tickets 20 s later; no order placed after the restart. | Pass | `A/scenario-g.log` |
| f. Master exit | Copies closed at the same time | Master closed both positions; slave closed both copies 469 ms and 560 ms after each master close. | Pass | `A/scenario-f.log`, `A/delays.csv` |
| h. Master stopped longer than 10 s | Slave freezes, one alert; master back: resumes, one alert | `MasterMT4` removed at 15:22:44.031. Slave `ALERT ... slave frozen` once, at 15:22:54.031; its pending limit unchanged while frozen. Master back: `ALERT ... slave resumed` once, at 15:23:16.034. Master close -> pending deleted 604 ms later. | Pass | `A/scenario-h.log`, `A/mt5-experts.log` |
| c. Limit price already reached | Sent at market | X = 0 (limit = the master's own price), buy and sell opened together: both copies sent at market with the reason `limit price already reached: market`, 336 ms and 393 ms later. | Pass | `A/scenario-c.log` |

### Direction B: master MetaTrader 5 -> slave MetaTrader 4 (folder `B/`, second run, after the fix below)

| Scenario | Expected | Observed | Result | Evidence |
|---|---|---|---|---|
| b. Master closes before the limit fills | Slave pending deleted, nothing opened | X = 200. Master buy at 1.10149; slave buy limit at 1.09949 placed 479 ms later; deleted 446 ms after the master close; nothing opened. | Pass | `B/scenario-b.log` |
| a. Initial entry | Limit X ticks better | X input = 3, broker minimum distance 8 points: limit moved to 1.10141 = master 1.10149 - 8 ticks (`moved to the broker's minimum distance`). The first send, on the slave EA's first cycle 80 ms after the master's entry, was rejected with error 130 (the price ticked before the order reached the server); the retry 2 s later was accepted (not counted in the delays: the slave EA had just started). Filled about 145 s later. | Pass, one rejected send | `B/scenario-a.log`, `B/mt4-experts.log` |
| d. Add-on | Copied at market | Slave market buy 0.02, 409 ms after the master's add-on. | Pass | `B/scenario-d.log` |
| e. Partial close | Same fraction, rounded down | Slave closed 0.01 of its 0.02 copy, 384 ms later. MetaTrader 4 gave the slave's remainder a new ticket (`from #...`); it stayed linked (restart in g, closed in f). | Pass | `B/scenario-e.log` |
| g. Slave restart with open copies | No duplicate order | `2 link(s) loaded`; same tickets, including the renumbered remainder, 20 s later; no order placed. | Pass | `B/scenario-g.log` |
| f. Master exit | Copies closed at the same time | 567 ms and 616 ms after each master close. | Pass | `B/scenario-f.log`, `B/delays.csv` |
| h. Master stopped longer than 10 s | One alert each way | `MasterMT5` removed at 15:32:41.390; `ALERT ... slave frozen` once, at 15:32:52.181; pending unchanged; master back at 15:33:11.143; `ALERT ... slave resumed` once, at 15:33:12.305. The limit itself was placed 6.4 s after the master's entry: three sends at the minimum distance were rejected with error 130 before the fourth was accepted. | Pass; slow placement noted | `B/scenario-h.log`, `B/mt4-experts.log` |
| c. Limit price already reached | Sent at market | X = 0, buy and sell together: both at market, `limit price already reached: market`, 561 ms and 568 ms (the first is not counted below: the slave EA started 28 ms after the master's buy). | Pass | `B/scenario-c.log` |

### First runs, kept as they happened

| Run | What happened | Cause | What changed |
|---|---|---|---|
| A, first run (`A-run1/`) | The copier did b, a, d, e, g, f, h as in the second run. Scenario c was **not produced**: the driver waited for the MetaTrader 4 price to move, then restarted the slave, but the MetaTrader 5 quote was 1 tick above the buy limit, so both copies were placed as limits (correct behavior, scenario not exercised). The driver also logged false `TIMEOUT` lines: the terminals' logs show the copies within 0.5 s. | Driver: a single result has no `.Count` in Windows PowerShell 5.1; the c trigger used the master's quotes. | Driver fixed; c redone with X = 0 and a buy and a sell opened together. |
| B, first run (`B-run1/`) | **a failed**: MetaTrader 4 rejected the buy limit 3 ticks below the master's entry with error 130, 16 times in 30 s; no copy. d passed (413 ms). Then the master helper's partial close failed and the driver stopped, flattening both accounts. | The MetaTrader 4 demo's stops level is 8 points: a pending order closer than that to the market is invalid. The helper's `CTrade` had read the margin mode before the login, so `PositionClosePartial` refused to run. | Copier: a limit closer to the market than the broker's minimum distance is moved further away (still at least X ticks better), test `S1_LimitInsideTheBrokerMinimumDistanceMovesFurtherAway` and a mutant. `SlaveMT5` and the helper refresh `CTrade`'s margin mode once logged in. |

Direction A's second run used the EAs from before that fix. The fix changes nothing on this MetaTrader 5 demo: its stops level is 0, and `SlaveMT5`'s partial close worked in that run (scenario e).

## Copy delay

Each row of `delays.csv` pairs a master action, timed by the helper's `OPEN done` or `CLOSE done` line (written when the master's server confirmed it), with the slave EA's line for the copy (written when the slave's server confirmed it). Both come from the terminals' own logs on the same PC clock. A pair is not counted when the slave EA started after the master action (the slave was restarted on purpose).

Counted pairs of the two second runs (`A/delays.csv`, `B/delays.csv`):

| | Pairs | Min | Median | Max |
|---|---|---|---|---|
| All copy actions | 24 | 336 ms | 496.5 ms | 6430 ms (B, h: three error 130 rejections) |
| Exits only (close, partial close, delete) | 14 | 384 ms | 551.5 ms | 658 ms |
| Master exits in f (full close) | 4 | 469 ms | 563.5 ms | 616 ms |
| Direction A | 13 | 336 ms | 478 ms | 621 ms |
| Direction B | 11 | 384 ms | 568 ms | 6430 ms |

What the delay is made of: the master EA lists positions every 200 ms, the slave reads the file every 200 ms, and each order goes to the MetaQuotes demo server and back (the MetaTrader 5 journal shows `done in` 240.9 to 257.0 ms per order from this PC).

## Final state

Both accounts were left flat: `final-check.log` starts each terminal with only the helper script and reads `positions=0 orders=0` on both.
