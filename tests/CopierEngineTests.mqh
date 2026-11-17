//+------------------------------------------------------------------+
//| CopierEngineTests.mqh                                            |
//| Master and slave engines end to end through real files in        |
//| Terminal\Common\Files\CopierProof (channel "selftest"), with a   |
//| fake broker in place of the trading calls: no order is sent.     |
//+------------------------------------------------------------------+
#include <CopierProof/CopierMaster.mqh>
#include <CopierProof/CopierSlave.mqh>

#define ET_CHANNEL "selftest"
#define ET_ACCOUNT 999

class CFakeBroker : public CCopierBroker
  {
public:
   CPSlaveItem       items[];
   long              nextTicket;
   int               limits;
   int               markets;
   int               closes;
   int               deletes;
   double            lastLimitPrice;

                     CFakeBroker(void) : nextTicket(5000), limits(0), markets(0), closes(0), deletes(0), lastLimitPrice(0) {}

   int               Find(const long ticket)
     {
      for(int i = 0; i < ArraySize(items); i++)
         if(items[i].ticket == ticket)
            return i;
      return -1;
     }

   void              RemoveAt(const int i)
     {
      int n = ArraySize(items);
      for(int k = i; k < n - 1; k++)
         items[k] = items[k + 1];
      ArrayResize(items, n - 1);
     }

   long              Add(const int kind, const string symbol, const int side, const double lots, const string comment,
                         const long magic)
     {
      int n = ArraySize(items);
      ArrayResize(items, n + 1);
      items[n].ticket  = nextTicket;
      items[n].origin  = nextTicket;
      items[n].kind    = kind;
      items[n].symbol  = symbol;
      items[n].side    = side;
      items[n].lots    = lots;
      items[n].magic   = magic;
      items[n].comment = comment;
      return nextTicket++;
     }

   virtual long      AccountId(void) { return ET_ACCOUNT; }
   virtual bool      Ready(void) { return true; }

   virtual void      CollectItems(CPSlaveItem &out[])
     {
      ArrayResize(out, ArraySize(items));
      for(int i = 0; i < ArraySize(items); i++)
         out[i] = items[i];
     }

   virtual bool      GetSpec(const string symbol, CPSymbolSpec &spec)
     {
      spec.symbol   = symbol;
      spec.valid    = (symbol == "EURUSD");
      spec.tickSize = 0.00001;
      spec.volMin   = 0.01;
      spec.volMax   = 100;
      spec.volStep  = 0.01;
      spec.bid      = 1.10100;
      spec.ask      = 1.10102;
      return spec.valid;
     }

   virtual long      PlaceLimit(const string symbol, const int side, const double lots, const double price,
                                const string comment, const long magic)
     {
      limits++;
      lastLimitPrice = price;
      return Add(CP_KIND_PENDING, symbol, side, lots, comment, magic);
     }

   virtual long      PlaceMarket(const string symbol, const int side, const double lots,
                                 const string comment, const long magic)
     {
      markets++;
      return Add(CP_KIND_POSITION, symbol, side, lots, comment, magic);
     }

   virtual bool      ClosePosition(const long ticket, const double lots)
     {
      int i = Find(ticket);
      if(i < 0 || items[i].kind != CP_KIND_POSITION)
         return false;
      closes++;
      if(lots >= items[i].lots - CP_EPS)
         RemoveAt(i);
      else
         items[i].lots = NormalizeDouble(items[i].lots - lots, 8);
      return true;
     }

   virtual bool      DeletePending(const long ticket)
     {
      int i = Find(ticket);
      if(i < 0 || items[i].kind != CP_KIND_PENDING)
         return false;
      deletes++;
      RemoveAt(i);
      return true;
     }
  };

string EngineCounts(const CFakeBroker &b)
  {
   return "limits=" + IntegerToString(b.limits) + " markets=" + IntegerToString(b.markets) + " closes=" +
          IntegerToString(b.closes) + " deletes=" + IntegerToString(b.deletes);
  }

void EngineCleanup(void)
  {
   string files[4];
   files[0] = CP_SnapshotPath(ET_CHANNEL);
   files[1] = files[0] + ".tmp";
   files[2] = CP_SlaveMapPath(ET_CHANNEL, ET_ACCOUNT, T_MAGIC);
   files[3] = files[2] + ".tmp";
   for(int i = 0; i < 4; i++)
      if(FileIsExist(files[i], FILE_COMMON))
         FileDelete(files[i], FILE_COMMON);
  }

void SetPos(CPMasterPos &pos[], const int i, const long ticket, const int side, const double lots, const double price,
            const long openTimeMsc)
  {
   if(ArraySize(pos) <= i)
      ArrayResize(pos, i + 1);
   pos[i].ticket      = ticket;
   pos[i].symbol      = "EURUSD";
   pos[i].side        = side;
   pos[i].lots        = lots;
   pos[i].price       = price;
   pos[i].openTimeMsc = openTimeMsc;
  }

void Test_Engine_EndToEndThroughFiles()
  {
   EngineCleanup();
   CPConfig cfg; DefaultConfig(cfg);
   CCopierMaster master;
   CFakeBroker broker;
   CPMasterPos pos[];

//--- 1. initial entry: one limit, 5 ticks better
   bool init = master.Init(ET_CHANNEL, 1, (long)TimeGMT());
   SetPos(pos, 0, 100, CP_SIDE_BUY, 0.10, 1.10005, 1000);
   bool wrote = master.Publish(pos, (long)TimeGMT());
   CCopierSlave slave;
   slave.Init(GetPointer(broker), cfg, ET_CHANNEL, 1);
   slave.Cycle((long)TimeGMT());
   Expect(init && wrote && broker.limits == 1 && broker.markets == 0 && Near(broker.lastLimitPrice, 1.10000),
          "E2E_MasterFileToSlaveLimit", EngineCounts(broker) + " price=" + DoubleToString(broker.lastLimitPrice, 5));

//--- 2. slave restart: a new engine loads the saved map and places nothing
   CCopierSlave restarted;
   restarted.Init(GetPointer(broker), cfg, ET_CHANNEL, 1);
   restarted.Cycle((long)TimeGMT());
   restarted.Cycle((long)TimeGMT());
   Expect(broker.limits == 1 && broker.markets == 0, "E2E_SlaveRestartPlacesNoDuplicate", EngineCounts(broker));

//--- 3. add-on while the limit is unfilled: market, pending kept
   SetPos(pos, 1, 101, CP_SIDE_BUY, 0.20, 1.10050, 2000);
   master.Publish(pos, (long)TimeGMT());
   restarted.Cycle((long)TimeGMT());
   Expect(broker.markets == 1 && broker.deletes == 0 && broker.limits == 1, "E2E_AddOnAtMarketPendingKept",
          EngineCounts(broker));

//--- 4. master closes the initial before the fill: pending deleted, add-on copy untouched
   ArrayResize(pos, 0);
   SetPos(pos, 0, 101, CP_SIDE_BUY, 0.20, 1.10050, 2000);
   master.Publish(pos, (long)TimeGMT());
   restarted.Cycle((long)TimeGMT());
   Expect(broker.deletes == 1 && broker.closes == 0, "E2E_ExitBeforeFillDeletesPending", EngineCounts(broker));

//--- 5. master closes the add-on: slave copy closed
   ArrayResize(pos, 0);
   master.Publish(pos, (long)TimeGMT());
   restarted.Cycle((long)TimeGMT());
   Expect(broker.closes == 1 && ArraySize(broker.items) == 0, "E2E_ExitClosesCopy", EngineCounts(broker));

//--- 6. a half-written snapshot with a new position is ignored (its session is
//---    later than the master's, so only the seal check can reject it)
   SetPos(pos, 0, 102, CP_SIDE_BUY, 0.10, 1.10005, 3000);
   string text = CP_BuildSnapshotText(9000000000, 1, (long)TimeGMT(), pos);
   bool planted = CP_WriteTextAtomic(CP_SnapshotPath(ET_CHANNEL), StringSubstr(text, 0, StringLen(text) - 7));
   restarted.Cycle((long)TimeGMT());
   bool ignored = planted && broker.limits == 1 && broker.markets == 1;
//--- ...and the next complete snapshot from the master is copied
   master.Publish(pos, (long)TimeGMT());
   restarted.Cycle((long)TimeGMT());
   Expect(ignored && broker.limits == 2, "E2E_HalfWrittenFileIgnoredThenCompleteOneCopied", EngineCounts(broker));

//--- 7. a new master engine (master restart) continues the same session and sequence
   CCopierMaster master2;
   master2.Init(ET_CHANNEL, 1, (long)TimeGMT() + 100);
   CCPSnapshot before;
   string beforeText;
   CP_ReadText(CP_SnapshotPath(ET_CHANNEL), beforeText);
   CP_ParseSnapshot(beforeText, before);
   ArrayResize(pos, 0);
   master2.Publish(pos, (long)TimeGMT());
   string afterText;
   CCPSnapshot after;
   CP_ReadText(CP_SnapshotPath(ET_CHANNEL), afterText);
   bool parsed = CP_ParseSnapshot(afterText, after);
   restarted.Cycle((long)TimeGMT());
   Expect(parsed && after.session == before.session && after.seq == before.seq + 1 && broker.deletes == 2,
          "E2E_MasterRestartKeepsSessionAndSlaveFollows",
          "session " + IntegerToString(before.session) + "->" + IntegerToString(after.session) + " seq " +
          IntegerToString(before.seq) + "->" + IntegerToString(after.seq) + " " + EngineCounts(broker));
   EngineCleanup();
  }

void RunEngineTests(void)
  {
   Test_Engine_EndToEndThroughFiles();
  }
