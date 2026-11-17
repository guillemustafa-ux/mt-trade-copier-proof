# MT4/MT5 trade copier: limit entry X ticks better, add-ons at market, mirrored exits

Four Expert Advisors that copy trades from a master account to a slave account running on the **same PC**. Master and slave can each be MetaTrader 4 or MetaTrader 5. They talk through one file in the terminals' shared `Terminal\Common\Files\CopierProof` folder.

> **Status (2026-11-17), every number below comes from a file in [`docs/evidence/`](docs/evidence):**
> - All six programs (four EAs, two test scripts) compile with `0 errors, 0 warnings`: `MetaEditor64.exe` file version 5.0.0.6274 for MQL5, MetaTrader 4's `metaeditor.exe` file version 5.0.0.2425 for MQL4 ([compile logs](docs/evidence/compile)).
> - The test script runs **in MetaTrader 5 (build 6274), with no trading account and no orders sent**: `47 passed, 0 failed` ([output](docs/evidence/tests-mt5.txt)). 40 tests exercise the pure decision logic. 7 run the real master and slave code end to end through real files, with a fake broker in place of the trading calls.
> - One-line mutants of the decision logic: each of the 13 makes at least one test fail, `mutants: 13, survived: 0` ([output](docs/evidence/mutants-mt5.txt)).
> - **Not yet run on any trading account.** A run on demo accounts is pending; see [Live demo run](#live-demo-run-pending).

## What it does

The rules as the client wrote them:

> "I need a trade copier that will copy from a master account into a slave account at 'X' ticks better than the initial entry from the master account. Add-on positions will be copied at the time that it gets added to the master account. So, no price is specified for add-on positions. Exits will be at the same time as the master account."

How this copier reads them:

| Event on the master | What the slave does |
|---|---|
| **Initial entry** (no other open master position on that symbol and side) | Places a **limit order X ticks better**: master open price minus X ticks for a buy, plus X ticks for a sell. A tick is the slave symbol's `SYMBOL_TRADE_TICK_SIZE` (MQL4: `MODE_TICKSIZE`). The price is snapped to the slave's tick grid in the direction that keeps it at least X ticks better. |
| **Add-on** (another position on the same symbol and side, opened later) | Opens it **at market** at once, with no price. |
| **Full close** | Closes the slave copy at market and **deletes the copy's limit if it has not filled**. |
| **Partial close** | Closes the same fraction of the slave copy (see rule 4 below). |

A position on the opposite side is a new initial entry, not an add-on. A position is classified once, when the slave first sees it.

## How it works

```text
 master terminal                     Common\Files\CopierProof\                 slave terminal
 MasterMT5 / MasterMT4  --writes-->  <channel>.snap (sealed snapshot)  <--reads--  SlaveMT5 / SlaveMT4
 (lists open positions                                                          (decides, then trades;
  every 200 ms)                      <channel>.slave-<login>-<magic>.map  <-->   keeps the ticket map)
```

- The **master** writes its open positions (identity, symbol, side, lots, open price, open time) every time they change, and at least once per second as a heartbeat. It writes to `<channel>.snap.tmp` and then renames over `<channel>.snap`. The file ends with an FNV-1a checksum line, and carries a session and a sequence number.
- The **slave** reads the file every 200 ms. It keeps the last complete snapshot. From the snapshot, its own orders and positions, and its ticket map, it decides a list of actions: place limit, place market, close (all or part), delete pending.
- The decision logic is in [`CopierCore.mqh`](src/Include/CopierProof/CopierCore.mqh). It makes no terminal or trading calls, compiles as both MQL4 and MQL5, and is what the tests exercise. The EAs only list positions and send orders.

| File | Role |
|---|---|
| `src/Include/CopierProof/CopierCore.mqh` | Decision logic, file formats, symbol map, lot and price rules. Shared by all four EAs. |
| `src/Include/CopierProof/CopierFiles.mqh` | File names and the write-then-rename helper. |
| `src/Include/CopierProof/CopierMaster.mqh` | Master loop (shared by both masters). |
| `src/Include/CopierProof/CopierSlave.mqh` | Slave loop and the broker interface (shared by both slaves). |
| `src/Include/CopierProof/CopierMT4.mqh` | MT4 order list with stable identities across partial closes (rule 4). |
| `src/MQL5/Experts/MasterMT5.mq5`, `SlaveMT5.mq5` | MT5 EAs. The slave trades with `CTrade`. |
| `src/MQL4/Experts/MasterMT4.mq4`, `SlaveMT4.mq4` | MT4 EAs. The slave trades with `OrderSend` / `OrderClose` / `OrderDelete`. |
| `tests/CopierTests.mqh`, `tests/CopierEngineTests.mqh` | The tests. `tests/CopierCoreTests.mq5` and `.mq4` run them. |
| `tools/*.ps1` | Deploy to the data folders, compile, run the MT5 test script, run the mutants. |

## The seven edge cases

Each rule has deterministic tests; the names are the ones printed in [`tests-mt5.txt`](docs/evidence/tests-mt5.txt).

1. **Master exits before the slave's limit fills.** The slave deletes its pending order and opens nothing. Tests: `S3_1_MasterExitBeforeFillDeletesThePending`, `S3_1_AfterTheDeleteNothingIsOpened`, `E2E_ExitBeforeFillDeletesPending`.
2. **Add-on while the initial limit is still unfilled.** The add-on is copied at market at once. The pending limit stays in place. Tests: `S3_2_AddOnGoesAtMarketAndThePendingStays`, `E2E_AddOnAtMarketPendingKept`.
3. **Slave terminal restart, no duplicates.** Every copy is recorded in a ticket map file (master ticket to slave ticket), written right after each order. Every copy also carries the slave's magic number and the comment `CP:<master ticket>`. If the terminal stops between an order and the map save, the link is rebuilt from that magic and comment. After a restart, links are kept for 10 s even if the terminal has not listed its orders yet. Tests: `S3_3_TicketMapSurvivesSaveAndLoad`, `S3_3_RestartWithSavedMapPlacesNothingNew`, `S3_3_LostMapIsRebuiltFromMagicAndComment`, `S3_3_OrderWithAnotherMagicIsNotTakenAsTheCopy`, `S3_3_CopyNotYetListedIsNotPlacedTwice`, `S3_3_RestartBeforeTheTerminalListsOrdersKeepsTheLinks`, `E2E_SlaveRestartPlacesNoDuplicate`.
4. **Partial close on the master.** The slave closes the same fraction of its copy, rounded **down** to its lot step. Fractions add up across several partial closes. A partial close never leaves less than the slave's minimum volume. MT4 gives the remaining part a new ticket with the comment `from #<old ticket>`. Both MT4 EAs keep an alias file, so the copy stays linked to the original ticket. Tests: `S3_4_HalfClosedOnMasterClosesHalfOnSlave`, `S3_4_ClosedFractionRoundsDownToTheSlaveStep`, `S3_4_SecondPartialCloseCountsWhatWasAlreadyClosed`, `S3_4_AppliedPartialCloseIsNotRepeated`, `S3_4_RemainderNeverGoesBelowTheSlaveMinimum`, `S3_4_Mt4RemainderTicketKeepsTheOriginalIdentity`.
5. **Stale or half-written master file.** The slave never acts on a partial snapshot:
   - the master writes a temporary file and renames it;
   - the slave accepts a file only if its checksum matches;
   - the slave accepts a snapshot only if it is later than the last one it applied (session, then sequence);
   - a snapshot older than 10 s means the master is not running, and the slave then neither copies nor closes until it is back.

   Tests: `S3_5_CompleteSnapshotIsReadBack`, `S3_5_EveryHalfWrittenPrefixIsRejected` (every prefix of a snapshot is rejected), `S3_5_SnapshotWithAChangedByteIsRejected`, `S3_5_OlderOrRepeatedSnapshotIsNotApplied`, `S3_5_NewMasterSessionIsAccepted`, `S3_5_StaleSnapshotNeitherOpensNorCloses`, `S3_5_SlaveActsOnlyOnceTheCompleteFileArrives`, `E2E_HalfWrittenFileIgnoredThenCompleteOneCopied`, `E2E_MasterRestartKeepsSessionAndSlaveFollows`.
6. **Symbol names that differ between brokers** (`EURUSD` and `EURUSD.m`). Explicit pairs (`XAUUSD=GOLD`) win. Otherwise the master suffix is stripped and the slave suffix is added. A master position whose slave symbol does not exist is skipped and reported. Tests: `S3_6_SlaveSuffixIsAppended`, `S3_6_MasterSuffixIsReplaced`, `S3_6_ExplicitPairWinsOverSuffix`, `S3_6_NoRuleKeepsTheName`, `S3_6_CopyUsesTheSlaveSymbolAndSkipsUnknownOnes`.
7. **Lot sizing.** Slave lots are master lots × multiplier, rounded down to the slave's lot step. Below the slave's minimum, the minimum is used; above its maximum, the maximum. Tests: `S3_7_CopyIsSizedWithTheMultiplier`, `S3_7_LotsRoundDownToTheStep`, `S3_7_LotsBelowMinimumBecomeTheMinimum`, `S3_7_LotsAboveMaximumBecomeTheMaximum`, `S3_7_CoarseStepRoundsDown`, `S3_7_VolumeDecimalsFollowTheStep`.

The client's rules have their own tests: `S1_InitialBuyIsLimitXTicksBelowMasterEntry`, `S1_InitialSellIsLimitXTicksAboveMasterEntry`, `S1_LimitSnapsToSlaveTickGridNeverFewerThanXTicks`, `S1_AddOnIsCopiedAtMarketWithNoPrice`, `S1_MasterExitClosesTheSlaveCopyInTheSameCycle`, `S1_OppositeSideIsANewInitialEntry`, `E2E_MasterFileToSlaveLimit`, `E2E_ExitClosesCopy`.

### Other rules this copier applies

- **The limit price is already reached when the slave places it.** A buy limit at or above the ask, or a sell limit at or below the bid, is not a valid limit order. The slave sends a market order instead, which at that moment fills at the limit price or better (slippage aside). Test: `S1_LimitPriceAlreadyReachedIsSentAtMarket`.
- **A copy closed on the slave side** (its own stop, or by hand), or a pending deleted by hand, is not copied again while the master position stays open.
- **First start of the slave:** every open master position is copied by the same rules.
- **Not connected:** the master publishes nothing, and the slave waits. Account checks run on the first connected cycle, because at terminal start-up the account number is not known yet in `OnInit`.

## Install

1. In each terminal, find its data folder: **File > Open Data Folder**.
2. Copy the files, by hand or with the script:
   ```powershell
   .\tools\deploy.ps1 -Mt5Data "<MT5 data folder>" -Mt4Data "<MT4 data folder>"
   ```
   It writes only into `CopierProof` subfolders of `MQL5\Include`, `\Experts` and `\Scripts` (MQL4 the same).
3. Compile in MetaEditor (`Experts\CopierProof\*.mq5` or `*.mq4`), or:
   ```powershell
   .\tools\compile.ps1 -Mt5Data "<MT5 data folder>" -Mt5Editor "<MetaTrader 5>\MetaEditor64.exe" `
                       -Mt4Data "<MT4 data folder>" -Mt4Editor "<MetaTrader 4>\metaeditor.exe"
   ```
4. Master terminal: attach `MasterMT5` or `MasterMT4` to any one chart.
5. Slave terminal: attach `SlaveMT5` or `SlaveMT4` to any one chart. Set the inputs, and turn on **Algo Trading** (MT5) or **AutoTrading** (MT4).
6. Both terminals run on the same Windows user on the same PC, with the same `Channel` input.

### Inputs

Master (`MasterMT5`, `MasterMT4`):

| Input | Default | Meaning |
|---|---|---|
| `InpChannel` | `default` | Name of the snapshot file. One master per channel. |
| `InpTimerMs` | `200` | How often the master lists its positions. |
| `InpHeartbeatSeconds` | `1` | Rewrite the file at least this often, so slaves know the master is running. |

Slave (`SlaveMT5`, `SlaveMT4`):

| Input | Default | Meaning |
|---|---|---|
| `InpChannel` | `default` | Same as the master's. |
| `InpMagic` | `20261117` | Magic number of the copies. The ticket map is per account and magic. |
| `InpTicksBetter` | `5` | X: ticks better than the master's entry, for the initial entry's limit. |
| `InpLotMultiplier` | `1.0` | Slave lots = master lots × this, then rule 7. |
| `InpSymbolMap` | empty | Explicit pairs, `XAUUSD=GOLD;US30=DJ30` (`;` or `,`). |
| `InpMasterSuffix` | empty | Suffix to strip from master symbols, e.g. `.a`. |
| `InpSlaveSuffix` | empty | Suffix to add for slave symbols, e.g. `.m`. |
| `InpTimerMs` | `200` | How often the slave reads the snapshot. |
| `InpStaleSeconds` | `10` | A snapshot older than this stops all copying and closing (rule 5). |
| `InpSlippagePoints` | `10` | Deviation for market orders and closes. |
| `InpRetrySeconds` | `2` | Wait before retrying a failed order for the same master position. |

## Tests

- `tests/CopierCoreTests.mq5` runs every test in MetaTrader 5. It needs no trading account and sends no order. The end-to-end tests write and then delete files named `selftest.*` in `Common\Files\CopierProof`. To run it from the command line, after deploying and compiling:
  ```powershell
  .\tools\run-tests-mt5.ps1 -Mt5Data "<MT5 data folder>" -Terminal "<MetaTrader 5>\terminal64.exe" -OutFile docs\evidence\tests-mt5.txt
  ```
  This starts the terminal with a startup configuration (`[StartUp] Script=CopierProof\CopierCoreTests`, `ShutdownTerminal=1`) and copies the lines the script printed.
- `tests/CopierCoreTests.mq4` runs the same tests in MetaTrader 4. It compiles with 0 errors and 0 warnings, but it has **not been run** (see Limits).
- `tools/mutants-mt5.ps1` changes one line of the decision logic at a time and checks that some test fails.
- **First failing run:** before the logic was written, the test script ran against a stub with the same functions and no rules. The result was `1 passed, 37 failed`. The stub is [`docs/evidence/red-stub/CopierCore.mqh`](docs/evidence/red-stub/CopierCore.mqh) and the output is [`tests-mt5-red-stub.txt`](docs/evidence/tests-mt5-red-stub.txt). That run used the first 38 tests; the end-to-end and later tests were added afterwards.

## Live demo run (pending)

Pending: master and slave on demo accounts, with the slave's actions and timings recorded from the terminals. No result is claimed here until that run is in this repository.

## Limits

- **Same PC only.** Master and slave share `Terminal\Common\Files`. There is no network, VPS or cloud transport.
- **MT5 hedging accounts only.** On a netting account the MT5 EAs stop at their first connected cycle. MT4 accounts are hedging by design.
- **Not run on any trading account yet:** no demo run (pending) and no real account. Nothing here claims results with real money or with any broker.
- **The order calls are untested.** The end-to-end tests replace the broker with a fake. Real fills, rejections, filling modes, `GTC` support, comment handling and timings are not verified until the demo run. The MT5 limit orders use `ORDER_FILLING_RETURN`.
- **The MQL4 test script was compiled, not run.** The MT4 terminal on this machine logs into a saved account when it starts, and this work does not log into any account.
- **MT4 partial closes** rely on the server's `from #<ticket>` comment, and on the MT4 EA running when the partial close happens. A broker that rewrites that comment, or a partial close made while the EA is off, can break the link for that position.
- **Comments can be changed by brokers.** The ticket map is the primary link. Rebuilding from the `CP:<ticket>` comment only covers a stop between an order and the map save. It does not cover an MT4 remainder after a partial close, which carries `from #<ticket>` instead.
- **A stopped master freezes the slave:** after `InpStaleSeconds` without a snapshot, the slave neither copies nor closes. An exit made on the master in that time is copied only when the master's EA writes again.
- **Rename atomicity is not documented** for MQL's `FileMove`. The checksum, not the rename, is what makes the slave reject a partial file.
- **Lots raised to the minimum** (rule 7) increase the slave's relative size when the master trades below it.
- Symbol names containing `|` are not supported. Staleness uses `TimeGMT()` of the one PC both terminals run on.

## License

MIT, see [LICENSE](LICENSE).
