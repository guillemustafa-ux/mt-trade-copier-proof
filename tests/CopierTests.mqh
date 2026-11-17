//+------------------------------------------------------------------+
//| CopierTests.mqh                                                  |
//| Deterministic tests of CopierCore.mqh: the client's rules (S1)   |
//| and the seven edge cases (S3). Shared by the MQL5 and MQL4       |
//| runner scripts. Prints PASS/FAIL lines and "N passed, M failed". |
//+------------------------------------------------------------------+
#include <CopierProof/CopierCore.mqh>

#define T_NOW     1800000000
#define T_MAGIC   20261117

int g_pass = 0;
int g_fail = 0;

void Expect(const bool ok, const string name, const string detail)
  {
   if(ok)
     {
      g_pass++;
      Print("PASS ", name);
     }
   else
     {
      g_fail++;
      Print("FAIL ", name, ": ", detail);
     }
  }

bool Near(const double a, const double b) { return MathAbs(a - b) < 1e-8; }

void DefaultConfig(CPConfig &c)
  {
   c.magic         = T_MAGIC;
   c.ticksBetter   = 5;
   c.lotMultiplier = 1.0;
   c.symbolMap     = "";
   c.masterSuffix  = "";
   c.slaveSuffix   = "";
   c.staleSeconds  = 10;
   c.graceSeconds  = 10;
  }

void AddPos(CCPSnapshot &s, const long ticket, const string symbol, const int side, const double lots,
            const double price, const long openTimeMsc)
  {
   int n = ArraySize(s.pos);
   ArrayResize(s.pos, n + 1);
   s.pos[n].ticket      = ticket;
   s.pos[n].symbol      = symbol;
   s.pos[n].side        = side;
   s.pos[n].lots        = lots;
   s.pos[n].price       = price;
   s.pos[n].openTimeMsc = openTimeMsc;
  }

void AddItem(CPSlaveItem &items[], const long ticket, const long origin, const int kind, const string symbol,
             const int side, const double lots, const long magic, const string comment)
  {
   int n = ArraySize(items);
   ArrayResize(items, n + 1);
   items[n].ticket  = ticket;
   items[n].origin  = origin;
   items[n].kind    = kind;
   items[n].symbol  = symbol;
   items[n].side    = side;
   items[n].lots    = lots;
   items[n].magic   = magic;
   items[n].comment = comment;
  }

void AddSpec(CPSymbolSpec &specs[], const string symbol, const double tick, const double vmin, const double vmax,
             const double step, const double bid, const double ask)
  {
   int n = ArraySize(specs);
   ArrayResize(specs, n + 1);
   specs[n].symbol   = symbol;
   specs[n].valid    = true;
   specs[n].tickSize = tick;
   specs[n].volMin   = vmin;
   specs[n].volMax   = vmax;
   specs[n].volStep  = step;
   specs[n].bid      = bid;
   specs[n].ask      = ask;
  }

//--- EURUSD on the slave: 5-digit tick, 0.01 lots min/step, market well above 1.1000
void EurusdSpec(CPSymbolSpec &specs[], const string name)
  {
   AddSpec(specs, name, 0.00001, 0.01, 100.0, 0.01, 1.10100, 1.10102);
  }

string Describe(const CPAction &acts[])
  {
   string s = IntegerToString(ArraySize(acts)) + " action(s)";
   for(int i = 0; i < ArraySize(acts); i++)
      s += " [type=" + IntegerToString(acts[i].type) + " master=" + IntegerToString(acts[i].masterTicket) +
           " sym=" + acts[i].symbol + " side=" + IntegerToString(acts[i].side) + " lots=" +
           DoubleToString(acts[i].lots, 2) + " price=" + DoubleToString(acts[i].price, 5) + " slave=" +
           IntegerToString(acts[i].slaveTicket) + "]";
   return s;
  }

int CountType(const CPAction &acts[], const int type)
  {
   int n = 0;
   for(int i = 0; i < ArraySize(acts); i++)
      if(acts[i].type == type)
         n++;
   return n;
  }

//--- runs one fresh slave cycle on snapshot `s`
int Cycle(const CCPSnapshot &s, CPMapEntry &map[], const CPSlaveItem &items[], const CPSymbolSpec &specs[],
          const CPConfig &cfg, const long now, CPAction &acts[])
  {
   CCPSlaveState st;
   CP_CopySnapshot(s, st.current);
   st.has = true;
   return CP_SlaveCycle(st, map, items, specs, cfg, now, acts);
  }

void FreshSnapshot(CCPSnapshot &s)
  {
   s.Reset();
   s.session   = 1;
   s.seq       = 1;
   s.writeTime = T_NOW;
  }

//+------------------------------------------------------------------+
//| S1: client's rules                                               |
//+------------------------------------------------------------------+
void Test_S1_InitialBuyIsLimitXTicksBelow()
  {
   CPConfig cfg; DefaultConfig(cfg);
   CCPSnapshot s; FreshSnapshot(s);
   AddPos(s, 100, "EURUSD", CP_SIDE_BUY, 0.10, 1.10005, 1000);
   CPMapEntry map[]; CPSlaveItem items[]; CPSymbolSpec specs[]; EurusdSpec(specs, "EURUSD");
   CPAction acts[];
   Cycle(s, map, items, specs, cfg, T_NOW, acts);
   bool ok = ArraySize(acts) == 1 && acts[0].type == CP_ACT_PLACE_LIMIT && acts[0].side == CP_SIDE_BUY &&
             Near(acts[0].price, 1.10000) && Near(acts[0].lots, 0.10) && acts[0].masterTicket == 100;
   Expect(ok, "S1_InitialBuyIsLimitXTicksBelowMasterEntry", Describe(acts));
  }

void Test_S1_InitialSellIsLimitXTicksAbove()
  {
   CPConfig cfg; DefaultConfig(cfg);
   CCPSnapshot s; FreshSnapshot(s);
   AddPos(s, 100, "EURUSD", CP_SIDE_SELL, 0.10, 1.10005, 1000);
   CPMapEntry map[]; CPSlaveItem items[]; CPSymbolSpec specs[];
   AddSpec(specs, "EURUSD", 0.00001, 0.01, 100.0, 0.01, 1.09900, 1.09902);
   CPAction acts[];
   Cycle(s, map, items, specs, cfg, T_NOW, acts);
   bool ok = ArraySize(acts) == 1 && acts[0].type == CP_ACT_PLACE_LIMIT && acts[0].side == CP_SIDE_SELL &&
             Near(acts[0].price, 1.10010);
   Expect(ok, "S1_InitialSellIsLimitXTicksAboveMasterEntry", Describe(acts));
  }

void Test_S1_LimitSnapsToSlaveTickGrid()
  {
   double buy  = CP_LimitPrice(4500.30, CP_SIDE_BUY, 2, 0.25);
   double sell = CP_LimitPrice(4500.30, CP_SIDE_SELL, 2, 0.25);
   Expect(Near(buy, 4499.75) && Near(sell, 4501.00), "S1_LimitSnapsToSlaveTickGridNeverFewerThanXTicks",
          "buy=" + DoubleToString(buy, 2) + " sell=" + DoubleToString(sell, 2));
  }

void Test_S1_AddOnAtMarket()
  {
   CPConfig cfg; DefaultConfig(cfg);
   CCPSnapshot s; FreshSnapshot(s);
   AddPos(s, 100, "EURUSD", CP_SIDE_BUY, 0.10, 1.10005, 1000);
   AddPos(s, 101, "EURUSD", CP_SIDE_BUY, 0.20, 1.10050, 2000);
   CPMapEntry map[];
   CP_MapAdd(map, 100, CP_ROLE_INITIAL, CP_ST_OPEN, 500, "EURUSD", CP_SIDE_BUY, 0.10, 0.10, T_NOW - 100);
   CPSlaveItem items[];
   AddItem(items, 500, 500, CP_KIND_POSITION, "EURUSD", CP_SIDE_BUY, 0.10, T_MAGIC, "CP:100");
   CPSymbolSpec specs[]; EurusdSpec(specs, "EURUSD");
   CPAction acts[];
   Cycle(s, map, items, specs, cfg, T_NOW, acts);
   bool ok = ArraySize(acts) == 1 && acts[0].type == CP_ACT_PLACE_MARKET && acts[0].masterTicket == 101 &&
             acts[0].price == 0 && Near(acts[0].lots, 0.20) && acts[0].role == CP_ROLE_ADDON;
   Expect(ok, "S1_AddOnIsCopiedAtMarketWithNoPrice", Describe(acts));
  }

void Test_S1_ExitClosesCopy()
  {
   CPConfig cfg; DefaultConfig(cfg);
   CCPSnapshot s; FreshSnapshot(s);
   CPMapEntry map[];
   CP_MapAdd(map, 100, CP_ROLE_INITIAL, CP_ST_OPEN, 500, "EURUSD", CP_SIDE_BUY, 0.10, 0.10, T_NOW - 100);
   CPSlaveItem items[];
   AddItem(items, 500, 500, CP_KIND_POSITION, "EURUSD", CP_SIDE_BUY, 0.10, T_MAGIC, "CP:100");
   CPSymbolSpec specs[]; EurusdSpec(specs, "EURUSD");
   CPAction acts[];
   Cycle(s, map, items, specs, cfg, T_NOW, acts);
   bool ok = ArraySize(acts) == 1 && acts[0].type == CP_ACT_CLOSE && acts[0].slaveTicket == 500 && Near(acts[0].lots, 0.10);
   Expect(ok, "S1_MasterExitClosesTheSlaveCopyInTheSameCycle", Describe(acts));
  }

void Test_S1_OppositeSideIsInitial()
  {
   CPConfig cfg; DefaultConfig(cfg);
   CCPSnapshot s; FreshSnapshot(s);
   AddPos(s, 100, "EURUSD", CP_SIDE_BUY, 0.10, 1.10005, 1000);
   AddPos(s, 101, "EURUSD", CP_SIDE_SELL, 0.10, 1.10000, 2000);
   CPMapEntry map[];
   CP_MapAdd(map, 100, CP_ROLE_INITIAL, CP_ST_OPEN, 500, "EURUSD", CP_SIDE_BUY, 0.10, 0.10, T_NOW - 100);
   CPSlaveItem items[];
   AddItem(items, 500, 500, CP_KIND_POSITION, "EURUSD", CP_SIDE_BUY, 0.10, T_MAGIC, "CP:100");
   CPSymbolSpec specs[]; AddSpec(specs, "EURUSD", 0.00001, 0.01, 100.0, 0.01, 1.09990, 1.09992);
   CPAction acts[];
   Cycle(s, map, items, specs, cfg, T_NOW, acts);
   bool ok = ArraySize(acts) == 1 && acts[0].type == CP_ACT_PLACE_LIMIT && acts[0].masterTicket == 101 &&
             Near(acts[0].price, 1.10005);
   Expect(ok, "S1_OppositeSideIsANewInitialEntry", Describe(acts));
  }

void Test_S1_LimitAlreadyReached()
  {
   CPConfig cfg; DefaultConfig(cfg);
   CCPSnapshot s; FreshSnapshot(s);
   AddPos(s, 100, "EURUSD", CP_SIDE_BUY, 0.10, 1.10005, 1000);
   CPMapEntry map[]; CPSlaveItem items[];
   CPSymbolSpec specs[]; AddSpec(specs, "EURUSD", 0.00001, 0.01, 100.0, 0.01, 1.09988, 1.09990);
   CPAction acts[];
   Cycle(s, map, items, specs, cfg, T_NOW, acts);
   bool ok = ArraySize(acts) == 1 && acts[0].type == CP_ACT_PLACE_MARKET && acts[0].role == CP_ROLE_INITIAL;
   Expect(ok, "S1_LimitPriceAlreadyReachedIsSentAtMarket", Describe(acts));
  }

//+------------------------------------------------------------------+
//| S3.1 master exits before the slave limit fills                   |
//+------------------------------------------------------------------+
void Test_S3_1_ExitBeforeFill()
  {
   CPConfig cfg; DefaultConfig(cfg);
   CCPSnapshot s; FreshSnapshot(s);
   CPMapEntry map[];
   CP_MapAdd(map, 100, CP_ROLE_INITIAL, CP_ST_PENDING, 500, "EURUSD", CP_SIDE_BUY, 0.10, 0.10, T_NOW - 100);
   CPSlaveItem items[];
   AddItem(items, 500, 500, CP_KIND_PENDING, "EURUSD", CP_SIDE_BUY, 0.10, T_MAGIC, "CP:100");
   CPSymbolSpec specs[]; EurusdSpec(specs, "EURUSD");
   CPAction acts[];
   Cycle(s, map, items, specs, cfg, T_NOW, acts);
   bool ok = ArraySize(acts) == 1 && acts[0].type == CP_ACT_DELETE_PENDING && acts[0].slaveTicket == 500;
   Expect(ok, "S3_1_MasterExitBeforeFillDeletesThePending", Describe(acts));

//--- pending deleted: nothing is opened, and after the grace period the link is forgotten
   CPSlaveItem none[];
   Cycle(s, map, none, specs, cfg, T_NOW + 1, acts);
   int soon = ArraySize(acts);
   s.writeTime = T_NOW + cfg.graceSeconds + 1;
   Cycle(s, map, none, specs, cfg, T_NOW + cfg.graceSeconds + 1, acts);
   Expect(soon == 0 && ArraySize(acts) == 0 && ArraySize(map) == 0, "S3_1_AfterTheDeleteNothingIsOpened",
          "soon=" + IntegerToString(soon) + " later " + Describe(acts) + " map=" + IntegerToString(ArraySize(map)));
  }

//+------------------------------------------------------------------+
//| S3.2 add-on arrives while the initial limit is unfilled          |
//+------------------------------------------------------------------+
void Test_S3_2_AddOnWhilePending()
  {
   CPConfig cfg; DefaultConfig(cfg);
   CCPSnapshot s; FreshSnapshot(s);
   AddPos(s, 100, "EURUSD", CP_SIDE_BUY, 0.10, 1.10005, 1000);
   AddPos(s, 101, "EURUSD", CP_SIDE_BUY, 0.10, 1.10050, 2000);
   CPMapEntry map[];
   CP_MapAdd(map, 100, CP_ROLE_INITIAL, CP_ST_PENDING, 500, "EURUSD", CP_SIDE_BUY, 0.10, 0.10, T_NOW - 100);
   CPSlaveItem items[];
   AddItem(items, 500, 500, CP_KIND_PENDING, "EURUSD", CP_SIDE_BUY, 0.10, T_MAGIC, "CP:100");
   CPSymbolSpec specs[]; EurusdSpec(specs, "EURUSD");
   CPAction acts[];
   Cycle(s, map, items, specs, cfg, T_NOW, acts);
   bool ok = ArraySize(acts) == 1 && acts[0].type == CP_ACT_PLACE_MARKET && acts[0].masterTicket == 101 &&
             CountType(acts, CP_ACT_DELETE_PENDING) == 0;
   Expect(ok, "S3_2_AddOnGoesAtMarketAndThePendingStays", Describe(acts));
  }

//+------------------------------------------------------------------+
//| S3.3 slave restart: no duplicates                                |
//+------------------------------------------------------------------+
void RestartFixture(CCPSnapshot &s, CPSlaveItem &items[], CPSymbolSpec &specs[])
  {
   FreshSnapshot(s);
   AddPos(s, 100, "EURUSD", CP_SIDE_BUY, 0.10, 1.10005, 1000);
   AddPos(s, 101, "EURUSD", CP_SIDE_BUY, 0.20, 1.10050, 2000);
   AddItem(items, 500, 500, CP_KIND_PENDING, "EURUSD", CP_SIDE_BUY, 0.10, T_MAGIC, "CP:100");
   AddItem(items, 501, 501, CP_KIND_POSITION, "EURUSD", CP_SIDE_BUY, 0.20, T_MAGIC, "CP:101");
   EurusdSpec(specs, "EURUSD");
  }

void Test_S3_3_MapRoundTrip()
  {
   CPMapEntry a[];
   CP_MapAdd(a, 100, CP_ROLE_INITIAL, CP_ST_PENDING, 500, "EURUSD.m", CP_SIDE_BUY, 0.10, 0.25, T_NOW);
   CP_MapAdd(a, 101, CP_ROLE_ADDON, CP_ST_OPEN, 501, "XAUUSD", CP_SIDE_SELL, 1.5, 0.75, T_NOW + 7);
   CPMapEntry b[];
   bool parsed = CP_MapFromText(CP_MapToText(a), b);
   bool same = parsed && ArraySize(b) == 2;
   for(int i = 0; same && i < 2; i++)
      same = b[i].masterTicket == a[i].masterTicket && b[i].role == a[i].role && b[i].status == a[i].status &&
             b[i].slaveTicket == a[i].slaveTicket && b[i].slaveSymbol == a[i].slaveSymbol && b[i].side == a[i].side &&
             Near(b[i].masterLotsAtCopy, a[i].masterLotsAtCopy) && Near(b[i].slaveLotsAtCopy, a[i].slaveLotsAtCopy);
   Expect(same, "S3_3_TicketMapSurvivesSaveAndLoad", CP_MapToText(b));
  }

void Test_S3_3_RestartBeforeOrdersAreListed()
  {
   CPConfig cfg; DefaultConfig(cfg);
   CCPSnapshot s; CPSlaveItem items[]; CPSymbolSpec specs[];
   RestartFixture(s, items, specs);
   CPMapEntry saved[];
   CP_MapAdd(saved, 100, CP_ROLE_INITIAL, CP_ST_PENDING, 500, "EURUSD", CP_SIDE_BUY, 0.10, 0.10, T_NOW - 3600);
   CP_MapAdd(saved, 101, CP_ROLE_ADDON, CP_ST_OPEN, 501, "EURUSD", CP_SIDE_BUY, 0.20, 0.20, T_NOW - 3600);
   CPMapEntry map[];
   CP_MapFromText(CP_MapToText(saved), map);
   CP_MapMarkSeen(map, T_NOW);                 // what the slave does after loading
   CPSlaveItem notYetListed[];
   CPAction acts[];
   Cycle(s, map, notYetListed, specs, cfg, T_NOW + 2, acts);
   int early = ArraySize(acts);
   bool kept = ArraySize(map) == 2 && map[0].status != CP_ST_DONE && map[1].status != CP_ST_DONE;
   Cycle(s, map, items, specs, cfg, T_NOW + 3, acts);   // the terminal has listed them now
   int listed = ArraySize(acts);
//--- control: without the load-time mark the same empty list drops both links
   CPMapEntry unmarked[];
   CP_MapFromText(CP_MapToText(saved), unmarked);
   Cycle(s, unmarked, notYetListed, specs, cfg, T_NOW + 2, acts);
   bool dropped = ArraySize(unmarked) == 2 && unmarked[0].status == CP_ST_DONE && unmarked[1].status == CP_ST_DONE;
   Expect(early == 0 && kept && listed == 0 && dropped, "S3_3_RestartBeforeTheTerminalListsOrdersKeepsTheLinks",
          "early=" + IntegerToString(early) + " kept=" + (kept ? "yes" : "no") + " listed=" + IntegerToString(listed) +
          " control dropped=" + (dropped ? "yes" : "no"));
  }

void Test_S3_3_RestartWithMap()
  {
   CPConfig cfg; DefaultConfig(cfg);
   CCPSnapshot s; CPSlaveItem items[]; CPSymbolSpec specs[];
   RestartFixture(s, items, specs);
   CPMapEntry before[];
   CP_MapAdd(before, 100, CP_ROLE_INITIAL, CP_ST_PENDING, 500, "EURUSD", CP_SIDE_BUY, 0.10, 0.10, T_NOW - 60);
   CP_MapAdd(before, 101, CP_ROLE_ADDON, CP_ST_OPEN, 501, "EURUSD", CP_SIDE_BUY, 0.20, 0.20, T_NOW - 30);
   CPMapEntry map[];
   CP_MapFromText(CP_MapToText(before), map);   // what a restarted slave loads
   CPAction acts[];
   Cycle(s, map, items, specs, cfg, T_NOW, acts);
   int afterRestart = ArraySize(acts);
//--- control: the same master state on an empty slave places both copies
   CPMapEntry emptyMap[]; CPSlaveItem noItems[];
   Cycle(s, emptyMap, noItems, specs, cfg, T_NOW, acts);
   Expect(afterRestart == 0 && ArraySize(acts) == 2, "S3_3_RestartWithSavedMapPlacesNothingNew",
          "after restart=" + IntegerToString(afterRestart) + ", control: " + Describe(acts));
  }

void Test_S3_3_RecoverFromComments()
  {
   CPConfig cfg; DefaultConfig(cfg);
   CCPSnapshot s; CPSlaveItem items[]; CPSymbolSpec specs[];
   RestartFixture(s, items, specs);
   CPMapEntry map[];   // map lost: crash between the order and the map save
   CPAction acts[];
   Cycle(s, map, items, specs, cfg, T_NOW, acts);
   bool linked = ArraySize(map) == 2 && CP_MapFind(map, 100) >= 0 && CP_MapFind(map, 101) >= 0 &&
                 map[CP_MapFind(map, 100)].slaveTicket == 500 && map[CP_MapFind(map, 101)].slaveTicket == 501;
   Expect(ArraySize(acts) == 0 && linked, "S3_3_LostMapIsRebuiltFromMagicAndComment",
          Describe(acts) + " map=" + IntegerToString(ArraySize(map)));
  }

void Test_S3_3_ForeignMagic()
  {
   CPConfig cfg; DefaultConfig(cfg);
   CCPSnapshot s; FreshSnapshot(s);
   AddPos(s, 100, "EURUSD", CP_SIDE_BUY, 0.10, 1.10005, 1000);
   CPSlaveItem items[];
   AddItem(items, 900, 900, CP_KIND_PENDING, "EURUSD", CP_SIDE_BUY, 0.10, 999, "CP:100");
   CPSymbolSpec specs[]; EurusdSpec(specs, "EURUSD");
   CPMapEntry map[];
   CPAction acts[];
   Cycle(s, map, items, specs, cfg, T_NOW, acts);
   bool ok = ArraySize(acts) == 1 && acts[0].type == CP_ACT_PLACE_LIMIT && CountType(acts, CP_ACT_DELETE_PENDING) == 0;
   Expect(ok, "S3_3_OrderWithAnotherMagicIsNotTakenAsTheCopy", Describe(acts));
  }

void Test_S3_3_JustPlacedNotVisible()
  {
   CPConfig cfg; DefaultConfig(cfg);
   CCPSnapshot s; FreshSnapshot(s);
   AddPos(s, 100, "EURUSD", CP_SIDE_BUY, 0.10, 1.10005, 1000);
   CPMapEntry map[];
   CP_MapAdd(map, 100, CP_ROLE_INITIAL, CP_ST_PENDING, 500, "EURUSD", CP_SIDE_BUY, 0.10, 0.10, T_NOW - 1);
   CPSlaveItem items[];   // the terminal has not listed the new order yet
   CPSymbolSpec specs[]; EurusdSpec(specs, "EURUSD");
   CPAction acts[];
   Cycle(s, map, items, specs, cfg, T_NOW, acts);
   bool ok = ArraySize(acts) == 0 && ArraySize(map) == 1 && map[0].status == CP_ST_PENDING;
//--- control: still not listed after the grace period -> the link is closed, not re-placed
   s.writeTime = T_NOW + cfg.graceSeconds + 1;   // the master heartbeat keeps the snapshot fresh
   Cycle(s, map, items, specs, cfg, T_NOW + cfg.graceSeconds + 1, acts);
   ok = ok && ArraySize(acts) == 0 && ArraySize(map) == 1 && map[0].status == CP_ST_DONE;
   Expect(ok, "S3_3_CopyNotYetListedIsNotPlacedTwice",
          Describe(acts) + " status=" + (ArraySize(map) > 0 ? IntegerToString(map[0].status) : "none"));
  }

//+------------------------------------------------------------------+
//| S3.4 partial close on the master                                 |
//+------------------------------------------------------------------+
void PartialFixture(CCPSnapshot &s, CPMapEntry &map[], CPSlaveItem &items[], CPSymbolSpec &specs[],
                    const double masterNow, const double slaveAtCopy, const double slaveNow, const double volMin)
  {
   FreshSnapshot(s);
   AddPos(s, 100, "EURUSD", CP_SIDE_BUY, masterNow, 1.10005, 1000);
   CP_MapAdd(map, 100, CP_ROLE_INITIAL, CP_ST_OPEN, 500, "EURUSD", CP_SIDE_BUY, 1.00, slaveAtCopy, T_NOW - 100);
   AddItem(items, 500, 500, CP_KIND_POSITION, "EURUSD", CP_SIDE_BUY, slaveNow, T_MAGIC, "CP:100");
   AddSpec(specs, "EURUSD", 0.00001, volMin, 100.0, 0.01, 1.10100, 1.10102);
  }

void Test_S3_4_SameFraction()
  {
   CPConfig cfg; DefaultConfig(cfg);
   CCPSnapshot s; CPMapEntry map[]; CPSlaveItem items[]; CPSymbolSpec specs[]; CPAction acts[];
   PartialFixture(s, map, items, specs, 0.50, 0.30, 0.30, 0.01);
   Cycle(s, map, items, specs, cfg, T_NOW, acts);
   bool ok = ArraySize(acts) == 1 && acts[0].type == CP_ACT_CLOSE && acts[0].slaveTicket == 500 && Near(acts[0].lots, 0.15);
   Expect(ok, "S3_4_HalfClosedOnMasterClosesHalfOnSlave", Describe(acts));
  }

void Test_S3_4_RoundsDown()
  {
   CPConfig cfg; DefaultConfig(cfg);
   CCPSnapshot s; CPMapEntry map[]; CPSlaveItem items[]; CPSymbolSpec specs[]; CPAction acts[];
   PartialFixture(s, map, items, specs, 0.67, 0.25, 0.25, 0.01);   // 33% of 0.25 = 0.0825
   Cycle(s, map, items, specs, cfg, T_NOW, acts);
   bool ok = ArraySize(acts) == 1 && Near(acts[0].lots, 0.08);
   Expect(ok, "S3_4_ClosedFractionRoundsDownToTheSlaveStep", Describe(acts));
  }

void Test_S3_4_Cumulative()
  {
   CPConfig cfg; DefaultConfig(cfg);
   CCPSnapshot s; CPMapEntry map[]; CPSlaveItem items[]; CPSymbolSpec specs[]; CPAction acts[];
   PartialFixture(s, map, items, specs, 0.34, 0.25, 0.17, 0.01);   // 66% of 0.25 = 0.165 -> 0.16, 0.08 done
   Cycle(s, map, items, specs, cfg, T_NOW, acts);
   bool ok = ArraySize(acts) == 1 && Near(acts[0].lots, 0.08);
   Expect(ok, "S3_4_SecondPartialCloseCountsWhatWasAlreadyClosed", Describe(acts));
  }

void Test_S3_4_NotRepeated()
  {
   CPConfig cfg; DefaultConfig(cfg);
   CCPSnapshot s; CPMapEntry map[]; CPSlaveItem items[]; CPSymbolSpec specs[]; CPAction acts[];
   PartialFixture(s, map, items, specs, 0.50, 0.30, 0.30, 0.01);
   Cycle(s, map, items, specs, cfg, T_NOW, acts);
   int first = ArraySize(acts);
   items[0].lots = 0.15;   // the slave has executed that close
   Cycle(s, map, items, specs, cfg, T_NOW + 1, acts);
   Expect(first == 1 && ArraySize(acts) == 0, "S3_4_AppliedPartialCloseIsNotRepeated",
          "first=" + IntegerToString(first) + " then " + Describe(acts));
  }

void Test_S3_4_KeepsMinVolume()
  {
   CPConfig cfg; DefaultConfig(cfg);
   CCPSnapshot s; CPMapEntry map[]; CPSlaveItem items[]; CPSymbolSpec specs[]; CPAction acts[];
   PartialFixture(s, map, items, specs, 0.50, 0.15, 0.15, 0.10);   // 0.07 would leave 0.08 < min 0.10
   Cycle(s, map, items, specs, cfg, T_NOW, acts);
   bool ok = ArraySize(acts) == 1 && Near(acts[0].lots, 0.05);
   Expect(ok, "S3_4_RemainderNeverGoesBelowTheSlaveMinimum", Describe(acts));
  }

void Test_S3_4_Mt4Renumbering()
  {
   CCPAliasTable t;
   long ids[];
   long t1[] = {100};
   string c1[] = {""};
   CP_AliasResolveAll(t, t1, c1, ids);
   long id1 = ids[0];
   long t2[] = {101};
   string c2[] = {"from #100"};
   CP_AliasResolveAll(t, t2, c2, ids);
   long id2 = ids[0];
   CCPAliasTable reloaded;
   bool parsed = CP_AliasFromText(CP_AliasToText(t), reloaded);   // the EA restarts here
   long t3[] = {102};
   string c3[] = {"from #101"};
   CP_AliasResolveAll(reloaded, t3, c3, ids);
   long id3 = ids[0];
   Expect(parsed && id1 == 100 && id2 == 100 && id3 == 100, "S3_4_Mt4RemainderTicketKeepsTheOriginalIdentity",
          "ids=" + IntegerToString(id1) + "," + IntegerToString(id2) + "," + IntegerToString(id3));
  }

//+------------------------------------------------------------------+
//| S3.5 stale or half-written master file                           |
//+------------------------------------------------------------------+
string SnapshotText(const long session, const long seq, const long writeTime)
  {
   CPMasterPos pos[];
   ArrayResize(pos, 2);
   pos[0].ticket = 100; pos[0].symbol = "EURUSD"; pos[0].side = CP_SIDE_BUY;  pos[0].lots = 0.10; pos[0].price = 1.10005; pos[0].openTimeMsc = 1000;
   pos[1].ticket = 101; pos[1].symbol = "XAUUSD"; pos[1].side = CP_SIDE_SELL; pos[1].lots = 1.50; pos[1].price = 2650.45; pos[1].openTimeMsc = 2000;
   return CP_BuildSnapshotText(session, seq, writeTime, pos);
  }

void Test_S3_5_RoundTrip()
  {
   CCPSnapshot s;
   bool ok = CP_ParseSnapshot(SnapshotText(7, 3, T_NOW), s) && s.session == 7 && s.seq == 3 && s.writeTime == T_NOW &&
             ArraySize(s.pos) == 2 && s.pos[1].ticket == 101 && s.pos[1].symbol == "XAUUSD" &&
             s.pos[1].side == CP_SIDE_SELL && Near(s.pos[1].lots, 1.50) && Near(s.pos[1].price, 2650.45) &&
             s.pos[1].openTimeMsc == 2000;
   Expect(ok, "S3_5_CompleteSnapshotIsReadBack", SnapshotText(7, 3, T_NOW));
  }

void Test_S3_5_EveryTruncationRejected()
  {
   string full = SnapshotText(7, 3, T_NOW);
   CCPSnapshot s;
   int accepted = CP_ParseSnapshot("", s) ? 1 : 0;
   // length 0 is checked above: MQL4 reads StringSubstr(s, 0, 0) as "to the end"
   for(int len = 1; len < StringLen(full); len++)
      if(CP_ParseSnapshot(StringSubstr(full, 0, len), s))
         accepted++;
   bool fullAccepted = CP_ParseSnapshot(full, s);   // control
   Expect(accepted == 0 && fullAccepted, "S3_5_EveryHalfWrittenPrefixIsRejected",
          IntegerToString(accepted) + " of " + IntegerToString(StringLen(full)) + " prefixes accepted; full=" +
          (fullAccepted ? "accepted" : "rejected"));
  }

void Test_S3_5_CorruptionRejected()
  {
   string text = SnapshotText(7, 3, T_NOW);
   int p = StringFind(text, "0.10000000");
   string bad = StringSubstr(text, 0, p) + "0.90000000" + StringSubstr(text, p + 10);
   CCPSnapshot s;
   Expect(p > 0 && !CP_ParseSnapshot(bad, s), "S3_5_SnapshotWithAChangedByteIsRejected", bad);
  }

void Test_S3_5_OlderRejected()
  {
   CCPSlaveState st;
   int a = CP_AcceptSnapshot(SnapshotText(7, 5, T_NOW), st);
   int b = CP_AcceptSnapshot(SnapshotText(7, 4, T_NOW), st);
   int c = CP_AcceptSnapshot(SnapshotText(7, 5, T_NOW), st);
   Expect(a == CP_ACCEPT_NEW && b == CP_ACCEPT_NOT_NEWER && c == CP_ACCEPT_NOT_NEWER && st.current.seq == 5,
          "S3_5_OlderOrRepeatedSnapshotIsNotApplied",
          "a=" + IntegerToString(a) + " b=" + IntegerToString(b) + " c=" + IntegerToString(c));
  }

void Test_S3_5_NewSessionAccepted()
  {
   CCPSlaveState st;
   int a = CP_AcceptSnapshot(SnapshotText(7, 900, T_NOW), st);
   int b = CP_AcceptSnapshot(SnapshotText(8, 1, T_NOW + 5), st);
   Expect(a == CP_ACCEPT_NEW && b == CP_ACCEPT_NEW && st.current.session == 8, "S3_5_NewMasterSessionIsAccepted",
          "a=" + IntegerToString(a) + " b=" + IntegerToString(b));
  }

void Test_S3_5_StaleNoAction()
  {
   CPConfig cfg; DefaultConfig(cfg);
   CCPSnapshot s; FreshSnapshot(s);
   s.writeTime = T_NOW - 60;
   AddPos(s, 100, "EURUSD", CP_SIDE_BUY, 0.10, 1.10005, 1000);
   CPMapEntry map[];
   CP_MapAdd(map, 99, CP_ROLE_INITIAL, CP_ST_OPEN, 499, "EURUSD", CP_SIDE_BUY, 0.10, 0.10, T_NOW - 100);
   CPSlaveItem items[];
   AddItem(items, 499, 499, CP_KIND_POSITION, "EURUSD", CP_SIDE_BUY, 0.10, T_MAGIC, "CP:99");
   CPSymbolSpec specs[]; EurusdSpec(specs, "EURUSD");
   CPAction acts[];
   int r = Cycle(s, map, items, specs, cfg, T_NOW, acts);
   Expect(r == CP_CYCLE_STALE && ArraySize(acts) == 0, "S3_5_StaleSnapshotNeitherOpensNorCloses",
          "r=" + IntegerToString(r) + " " + Describe(acts));
  }

void Test_S3_5_FreezeEventOncePerChange()
  {
   int results[] = {CP_CYCLE_OK, CP_CYCLE_STALE, CP_CYCLE_STALE, CP_CYCLE_STALE, CP_CYCLE_OK, CP_CYCLE_OK};
   bool frozen = false;
   string seq = "";
   int enters = 0, resumes = 0;
   for(int i = 0; i < ArraySize(results); i++)
     {
      int ev = CP_FreezeEvent(frozen, results[i]);
      seq += IntegerToString(ev);
      if(ev == CP_FREEZE_ENTER)
         enters++;
      if(ev == CP_FREEZE_RESUME)
         resumes++;
     }
   Expect(seq == "010020" && enters == 1 && resumes == 1 && !frozen, "S3_5_FreezeAlertOnceOnFreezeOnceOnResume",
          "events " + seq);
  }

void Test_DemoOnlyGuard()
  {
   string demo = CP_DemoOnlyError("SlaveMT5", true);
   string real = CP_DemoOnlyError("SlaveMT5", false);
   Expect(demo == "" && StringFind(real, "demo accounts only") >= 0 && StringFind(real, "SlaveMT5") == 0,
          "Demo_NonDemoAccountIsRefused", "demo='" + demo + "' real='" + real + "'");
  }

void Test_S3_5_HalfWrittenNeverActedOn()
  {
   CPConfig cfg; DefaultConfig(cfg);
   CPSymbolSpec specs[]; EurusdSpec(specs, "EURUSD");
   AddSpec(specs, "XAUUSD", 0.01, 0.01, 100.0, 0.01, 2600.00, 2600.30);
   CPMapEntry map[]; CPSlaveItem items[]; CPAction acts[];
   CCPSlaveState st;
   string full = SnapshotText(7, 1, T_NOW);
   int a = CP_AcceptSnapshot(StringSubstr(full, 0, StringLen(full) / 2), st);
   int r1 = CP_SlaveCycle(st, map, items, specs, cfg, T_NOW, acts);
   int n1 = ArraySize(acts);
   int b = CP_AcceptSnapshot(full, st);
   int r2 = CP_SlaveCycle(st, map, items, specs, cfg, T_NOW, acts);
   bool ok = a == CP_ACCEPT_INVALID && r1 == CP_CYCLE_NO_SNAPSHOT && n1 == 0 && b == CP_ACCEPT_NEW &&
             r2 == CP_CYCLE_OK && ArraySize(acts) == 2;
   Expect(ok, "S3_5_SlaveActsOnlyOnceTheCompleteFileArrives",
          "a=" + IntegerToString(a) + " r1=" + IntegerToString(r1) + " n1=" + IntegerToString(n1) + " b=" +
          IntegerToString(b) + " " + Describe(acts));
  }

//+------------------------------------------------------------------+
//| S3.6 symbol mapping                                              |
//+------------------------------------------------------------------+
void Test_S3_6_Mapping()
  {
   string a = CP_MapSymbol("EURUSD", "", "", ".m");
   string b = CP_MapSymbol("EURUSD.a", "", ".a", ".m");
   string c = CP_MapSymbol("XAUUSD", " XAUUSD = GOLD ; EURUSD=EURUSD.pro", "", ".m");
   string d = CP_MapSymbol("EURUSD", "XAUUSD=GOLD,EURUSD=EURUSD.pro", "", ".m");
   string e = CP_MapSymbol("GBPUSD", "", "", "");
   Expect(a == "EURUSD.m", "S3_6_SlaveSuffixIsAppended", a);
   Expect(b == "EURUSD.m", "S3_6_MasterSuffixIsReplaced", b);
   Expect(c == "GOLD" && d == "EURUSD.pro", "S3_6_ExplicitPairWinsOverSuffix", c + " " + d);
   Expect(e == "GBPUSD", "S3_6_NoRuleKeepsTheName", e);
  }

void Test_S3_6_ActionUsesMappedSymbol()
  {
   CPConfig cfg; DefaultConfig(cfg);
   cfg.slaveSuffix = ".m";
   CCPSnapshot s; FreshSnapshot(s);
   AddPos(s, 100, "EURUSD", CP_SIDE_BUY, 0.10, 1.10005, 1000);
   AddPos(s, 101, "USDJPY", CP_SIDE_BUY, 0.10, 150.000, 1000);   // slave has no USDJPY.m
   CPMapEntry map[]; CPSlaveItem items[];
   CPSymbolSpec specs[]; EurusdSpec(specs, "EURUSD.m");
   CPAction acts[];
   Cycle(s, map, items, specs, cfg, T_NOW, acts);
   bool ok = ArraySize(acts) == 1 && acts[0].symbol == "EURUSD.m" && acts[0].masterTicket == 100;
   Expect(ok, "S3_6_CopyUsesTheSlaveSymbolAndSkipsUnknownOnes", Describe(acts));
  }

//+------------------------------------------------------------------+
//| S3.7 lot sizing                                                  |
//+------------------------------------------------------------------+
void Test_S3_7_Lots()
  {
   double b = CP_ClampLots(0.237, 0.01, 100, 0.01);
   double c = CP_ClampLots(0.004, 0.01, 100, 0.01);
   double d = CP_ClampLots(150, 0.01, 100, 0.01);
   double e = CP_ClampLots(0.35, 0.1, 50, 0.1);
   Expect(Near(b, 0.23), "S3_7_LotsRoundDownToTheStep", DoubleToString(b, 8));
   Expect(Near(c, 0.01), "S3_7_LotsBelowMinimumBecomeTheMinimum", DoubleToString(c, 8));
   Expect(Near(d, 100), "S3_7_LotsAboveMaximumBecomeTheMaximum", DoubleToString(d, 8));
   Expect(Near(e, 0.30), "S3_7_CoarseStepRoundsDown", DoubleToString(e, 8));
   int d1 = CP_StepDigits(0.01), d2 = CP_StepDigits(0.1), d3 = CP_StepDigits(1.0), d4 = CP_StepDigits(0.05);
   Expect(d1 == 2 && d2 == 1 && d3 == 0 && d4 == 2, "S3_7_VolumeDecimalsFollowTheStep",
          IntegerToString(d1) + "," + IntegerToString(d2) + "," + IntegerToString(d3) + "," + IntegerToString(d4));
  }

void Test_S3_7_MultiplierInDecision()
  {
   CPConfig cfg; DefaultConfig(cfg);
   cfg.lotMultiplier = 2.5;
   CCPSnapshot s; FreshSnapshot(s);
   AddPos(s, 100, "EURUSD", CP_SIDE_BUY, 0.10, 1.10005, 1000);
   CPMapEntry map[]; CPSlaveItem items[];
   CPSymbolSpec specs[]; EurusdSpec(specs, "EURUSD");
   CPAction acts[];
   Cycle(s, map, items, specs, cfg, T_NOW, acts);
   Expect(ArraySize(acts) == 1 && Near(acts[0].lots, 0.25), "S3_7_CopyIsSizedWithTheMultiplier", Describe(acts));
  }

#include "CopierEngineTests.mqh"

//+------------------------------------------------------------------+
int RunAllCopierTests()
  {
   g_pass = 0;
   g_fail = 0;
   Test_S1_InitialBuyIsLimitXTicksBelow();
   Test_S1_InitialSellIsLimitXTicksAbove();
   Test_S1_LimitSnapsToSlaveTickGrid();
   Test_S1_AddOnAtMarket();
   Test_S1_ExitClosesCopy();
   Test_S1_OppositeSideIsInitial();
   Test_S1_LimitAlreadyReached();
   Test_S3_1_ExitBeforeFill();
   Test_S3_2_AddOnWhilePending();
   Test_S3_3_MapRoundTrip();
   Test_S3_3_RestartWithMap();
   Test_S3_3_RecoverFromComments();
   Test_S3_3_ForeignMagic();
   Test_S3_3_JustPlacedNotVisible();
   Test_S3_3_RestartBeforeOrdersAreListed();
   Test_S3_4_SameFraction();
   Test_S3_4_RoundsDown();
   Test_S3_4_Cumulative();
   Test_S3_4_NotRepeated();
   Test_S3_4_KeepsMinVolume();
   Test_S3_4_Mt4Renumbering();
   Test_S3_5_RoundTrip();
   Test_S3_5_EveryTruncationRejected();
   Test_S3_5_CorruptionRejected();
   Test_S3_5_OlderRejected();
   Test_S3_5_NewSessionAccepted();
   Test_S3_5_StaleNoAction();
   Test_S3_5_HalfWrittenNeverActedOn();
   Test_S3_5_FreezeEventOncePerChange();
   Test_DemoOnlyGuard();
   Test_S3_6_Mapping();
   Test_S3_6_ActionUsesMappedSymbol();
   Test_S3_7_Lots();
   Test_S3_7_MultiplierInDecision();
   RunEngineTests();
   Print(IntegerToString(g_pass), " passed, ", IntegerToString(g_fail), " failed");
   return g_fail;
  }
