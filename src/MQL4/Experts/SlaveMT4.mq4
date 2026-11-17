//+------------------------------------------------------------------+
//| SlaveMT4.mq4                                                     |
//| Copies the master's trades into this MT4 account:                |
//| initial entry as a limit X ticks better, add-ons at market,      |
//| exits and partial closes when the master closes.                 |
//+------------------------------------------------------------------+
#property copyright "MIT License"
#property version   "1.00"
#property strict
#property description "Trade copier slave (MT4). Reads Terminal\\Common\\Files\\CopierProof\\<channel>.snap"

#include <CopierProof/CopierSlave.mqh>
#include <CopierProof/CopierMT4.mqh>

input string InpChannel        = "default";  // Channel name (same on master and slave)
input int    InpMagic          = 20261117;   // Magic number of the copies
input int    InpTicksBetter    = 5;          // Initial entry: ticks better than the master (MODE_TICKSIZE)
input double InpLotMultiplier  = 1.0;        // Slave lots = master lots x multiplier (clamped to min/max/step)
input string InpSymbolMap      = "";         // Explicit pairs, e.g. "XAUUSD=GOLD;US30=DJ30"
input string InpMasterSuffix   = "";         // Suffix to strip from master symbols, e.g. ".a"
input string InpSlaveSuffix    = "";         // Suffix to add for slave symbols, e.g. ".m"
input int    InpTimerMs        = 200;        // Poll period, milliseconds
input int    InpStaleSeconds   = 10;         // Ignore a master snapshot older than this
input int    InpSlippagePoints = 10;         // Market order slippage, points
input int    InpRetrySeconds   = 2;          // Wait before retrying a failed order

#define CP_GRACE_SECONDS 10

class CBrokerMT4 : public CCopierBroker
  {
private:
   CCPMT4Orders     *m_orders;
   int               m_slippage;
   string            m_err;
   string            m_channel;

   string            Fail(const string what)
     {
      m_err = what + " error " + IntegerToString(GetLastError());
      return m_err;
     }

   double            Volume(const string symbol, const double lots)
     {
      return NormalizeDouble(lots, CP_StepDigits(MarketInfo(symbol, MODE_LOTSTEP)));
     }

public:
   void              Setup(CCPMT4Orders *orders, const string channel, const int slippage)
     {
      m_orders   = orders;
      m_channel  = channel;
      m_slippage = MathMax(0, slippage);
     }

   virtual long      AccountId(void) { return AccountNumber(); }

   virtual bool      AccountIsDemo(void) { return IsDemo(); }

   virtual bool      Ready(void) { return IsConnected() && AccountNumber() != 0; }

   virtual bool      Start(string &error)
     {
      return m_orders.Init(CP_AliasPath(m_channel, "slave", AccountNumber()), error);
     }

   virtual void      CollectItems(CPSlaveItem &items[])
     {
      ArrayResize(items, 0);
      CPMT4Order orders[];
      int total = m_orders.Scan(orders);
      int n = 0;
      for(int i = 0; i < total; i++)
        {
         int type = orders[i].type;
         bool position = (type == OP_BUY || type == OP_SELL);
         bool limit    = (type == OP_BUYLIMIT || type == OP_SELLLIMIT);
         if(!position && !limit)
            continue;
         ArrayResize(items, n + 1);
         items[n].ticket  = orders[i].ticket;
         items[n].origin  = orders[i].identity;
         items[n].kind    = position ? CP_KIND_POSITION : CP_KIND_PENDING;
         items[n].symbol  = orders[i].symbol;
         items[n].side    = (type == OP_BUY || type == OP_BUYLIMIT) ? CP_SIDE_BUY : CP_SIDE_SELL;
         items[n].lots    = orders[i].lots;
         items[n].magic   = orders[i].magic;
         items[n].comment = orders[i].comment;
         n++;
        }
     }

   virtual bool      GetSpec(const string symbol, CPSymbolSpec &spec)
     {
      spec.symbol = symbol;
      spec.valid  = false;
      if(!SymbolSelect(symbol, true))
         return false;
      spec.tickSize = MarketInfo(symbol, MODE_TICKSIZE);
      spec.volMin   = MarketInfo(symbol, MODE_MINLOT);
      spec.volMax   = MarketInfo(symbol, MODE_MAXLOT);
      spec.volStep  = MarketInfo(symbol, MODE_LOTSTEP);
      spec.bid      = MarketInfo(symbol, MODE_BID);
      spec.ask      = MarketInfo(symbol, MODE_ASK);
      spec.minDistance = MarketInfo(symbol, MODE_STOPLEVEL) * MarketInfo(symbol, MODE_POINT);
      spec.valid    = spec.tickSize > 0 && spec.volMin > 0 && spec.volStep > 0 && spec.bid > 0 && spec.ask > 0;
      return spec.valid;
     }

   virtual long      PlaceLimit(const string symbol, const int side, const double lots, const double price,
                                const string comment, const long magic)
     {
      double p = NormalizeDouble(price, (int)MarketInfo(symbol, MODE_DIGITS));
      int ticket = OrderSend(symbol, side == CP_SIDE_BUY ? OP_BUYLIMIT : OP_SELLLIMIT, Volume(symbol, lots), p,
                             m_slippage, 0, 0, comment, (int)magic, 0, clrNONE);
      if(ticket < 0)
        {
         Fail("OrderSend limit");
         return 0;
        }
      return ticket;
     }

   virtual long      PlaceMarket(const string symbol, const int side, const double lots,
                                 const string comment, const long magic)
     {
      RefreshRates();
      double p = MarketInfo(symbol, side == CP_SIDE_BUY ? MODE_ASK : MODE_BID);
      int ticket = OrderSend(symbol, side == CP_SIDE_BUY ? OP_BUY : OP_SELL, Volume(symbol, lots), p,
                             m_slippage, 0, 0, comment, (int)magic, 0, clrNONE);
      if(ticket < 0)
        {
         Fail("OrderSend market");
         return 0;
        }
      return ticket;
     }

   //--- a partial close gives the remainder a new ticket; CCPMT4Orders keeps its identity
   virtual bool      ClosePosition(const long ticket, const double lots)
     {
      if(!OrderSelect((int)ticket, SELECT_BY_TICKET, MODE_TRADES) || OrderCloseTime() != 0)
        {
         m_err = "order #" + IntegerToString(ticket) + " not open";
         return false;
        }
      RefreshRates();
      string symbol = OrderSymbol();
      double p = MarketInfo(symbol, OrderType() == OP_BUY ? MODE_BID : MODE_ASK);
      double v = MathMin(Volume(symbol, lots), OrderLots());
      if(!OrderClose((int)ticket, v, p, m_slippage, clrNONE))
        {
         Fail("OrderClose");
         return false;
        }
      return true;
     }

   virtual bool      DeletePending(const long ticket)
     {
      if(!OrderDelete((int)ticket, clrNONE))
        {
         Fail("OrderDelete");
         return false;
        }
      return true;
     }

   virtual string    LastError(void) { return m_err; }
  };

CCPMT4Orders g_orders;
CBrokerMT4   g_broker;
CCopierSlave g_slave;

int OnInit()
  {
   g_broker.Setup(GetPointer(g_orders), InpChannel, InpSlippagePoints);
   CPConfig cfg;
   cfg.magic         = InpMagic;
   cfg.ticksBetter   = MathMax(0, InpTicksBetter);
   cfg.lotMultiplier = InpLotMultiplier;
   cfg.symbolMap     = InpSymbolMap;
   cfg.masterSuffix  = InpMasterSuffix;
   cfg.slaveSuffix   = InpSlaveSuffix;
   cfg.staleSeconds  = MathMax(1, InpStaleSeconds);
   cfg.graceSeconds  = CP_GRACE_SECONDS;
   g_slave.Init(GetPointer(g_broker), cfg, InpChannel, InpRetrySeconds);   // account setup runs once connected
   if(!EventSetMillisecondTimer(MathMax(50, InpTimerMs)))
     {
      CP_Log("timer not available (error " + IntegerToString(GetLastError()) + ")");
      return INIT_FAILED;
     }
   return INIT_SUCCEEDED;
  }

void OnDeinit(const int reason)
  {
   EventKillTimer();
  }

void OnTimer()
  {
   g_slave.Cycle((long)TimeGMT());
  }
