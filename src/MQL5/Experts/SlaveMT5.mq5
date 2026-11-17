//+------------------------------------------------------------------+
//| SlaveMT5.mq5                                                     |
//| Copies the master's trades into this MT5 hedging account:        |
//| initial entry as a limit X ticks better, add-ons at market,      |
//| exits and partial closes when the master closes.                 |
//+------------------------------------------------------------------+
#property copyright "MIT License"
#property version   "1.00"
#property description "Trade copier slave (MT5). Reads Terminal\\Common\\Files\\CopierProof\\<channel>.snap"

#include <Trade/Trade.mqh>
#include <CopierProof/CopierSlave.mqh>

input string InpChannel        = "default";  // Channel name (same on master and slave)
input long   InpMagic          = 20261117;   // Magic number of the copies
input int    InpTicksBetter    = 5;          // Initial entry: ticks better than the master (SYMBOL_TRADE_TICK_SIZE)
input double InpLotMultiplier  = 1.0;        // Slave lots = master lots x multiplier (clamped to min/max/step)
input string InpSymbolMap      = "";         // Explicit pairs, e.g. "XAUUSD=GOLD;US30=DJ30"
input string InpMasterSuffix   = "";         // Suffix to strip from master symbols, e.g. ".a"
input string InpSlaveSuffix    = "";         // Suffix to add for slave symbols, e.g. ".m"
input int    InpTimerMs        = 200;        // Poll period, milliseconds
input int    InpStaleSeconds   = 10;         // Ignore a master snapshot older than this
input int    InpSlippagePoints = 10;         // Market order deviation, points
input int    InpRetrySeconds   = 2;          // Wait before retrying a failed order

#define CP_GRACE_SECONDS 10

class CBrokerMT5 : public CCopierBroker
  {
private:
   CTrade            m_trade;
   string            m_err;

   bool              Done(const bool sent)
     {
      uint rc = m_trade.ResultRetcode();
      if(sent && (rc == TRADE_RETCODE_DONE || rc == TRADE_RETCODE_PLACED || rc == TRADE_RETCODE_DONE_PARTIAL))
         return true;
      m_err = "retcode " + IntegerToString(rc) + " " + m_trade.ResultRetcodeDescription();
      return false;
     }

   double            Volume(const string symbol, const double lots)
     {
      return NormalizeDouble(lots, CP_StepDigits(SymbolInfoDouble(symbol, SYMBOL_VOLUME_STEP)));
     }

public:
   void              Setup(const long magic, const int slippage)
     {
      m_trade.SetExpertMagicNumber((ulong)magic);
      m_trade.SetDeviationInPoints((ulong)MathMax(0, slippage));
      m_trade.SetAsyncMode(false);
     }

   virtual long      AccountId(void) { return AccountInfoInteger(ACCOUNT_LOGIN); }

   virtual bool      AccountIsDemo(void)
     {
      return AccountInfoInteger(ACCOUNT_TRADE_MODE) == ACCOUNT_TRADE_MODE_DEMO;
     }

   virtual bool      Ready(void)
     {
      return TerminalInfoInteger(TERMINAL_CONNECTED) && AccountInfoInteger(ACCOUNT_LOGIN) != 0;
     }

   virtual bool      Start(string &error)
     {
      //--- CTrade reads the margin mode when it is built, which can be before the login;
      //--- PositionClosePartial refuses to run unless it knows the account is hedging
      m_trade.SetMarginMode();
      if(AccountInfoInteger(ACCOUNT_MARGIN_MODE) == ACCOUNT_MARGIN_MODE_RETAIL_HEDGING)
         return true;
      error = "slave needs an MT5 hedging account; netting accounts are not supported";
      return false;
     }

   virtual void      CollectItems(CPSlaveItem &items[])
     {
      ArrayResize(items, 0);
      int n = 0;
      for(int i = 0; i < PositionsTotal(); i++)
        {
         ulong t = PositionGetTicket(i);
         if(t == 0)
            continue;
         ArrayResize(items, n + 1);
         items[n].ticket  = (long)t;
         items[n].origin  = PositionGetInteger(POSITION_IDENTIFIER);
         items[n].kind    = CP_KIND_POSITION;
         items[n].symbol  = PositionGetString(POSITION_SYMBOL);
         items[n].side    = (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY) ? CP_SIDE_BUY : CP_SIDE_SELL;
         items[n].lots    = PositionGetDouble(POSITION_VOLUME);
         items[n].magic   = PositionGetInteger(POSITION_MAGIC);
         items[n].comment = PositionGetString(POSITION_COMMENT);
         n++;
        }
      for(int i = 0; i < OrdersTotal(); i++)
        {
         ulong t = OrderGetTicket(i);
         if(t == 0)
            continue;
         long type = OrderGetInteger(ORDER_TYPE);
         if(type != ORDER_TYPE_BUY_LIMIT && type != ORDER_TYPE_SELL_LIMIT)
            continue;
         ArrayResize(items, n + 1);
         items[n].ticket  = (long)t;
         items[n].origin  = (long)t;
         items[n].kind    = CP_KIND_PENDING;
         items[n].symbol  = OrderGetString(ORDER_SYMBOL);
         items[n].side    = (type == ORDER_TYPE_BUY_LIMIT) ? CP_SIDE_BUY : CP_SIDE_SELL;
         items[n].lots    = OrderGetDouble(ORDER_VOLUME_CURRENT);
         items[n].magic   = OrderGetInteger(ORDER_MAGIC);
         items[n].comment = OrderGetString(ORDER_COMMENT);
         n++;
        }
     }

   virtual bool      GetSpec(const string symbol, CPSymbolSpec &spec)
     {
      spec.symbol = symbol;
      spec.valid  = false;
      MqlTick tick;
      if(!SymbolSelect(symbol, true) || !SymbolInfoTick(symbol, tick))
         return false;
      spec.tickSize = SymbolInfoDouble(symbol, SYMBOL_TRADE_TICK_SIZE);
      spec.volMin   = SymbolInfoDouble(symbol, SYMBOL_VOLUME_MIN);
      spec.volMax   = SymbolInfoDouble(symbol, SYMBOL_VOLUME_MAX);
      spec.volStep  = SymbolInfoDouble(symbol, SYMBOL_VOLUME_STEP);
      spec.bid      = tick.bid;
      spec.ask      = tick.ask;
      spec.minDistance = (double)SymbolInfoInteger(symbol, SYMBOL_TRADE_STOPS_LEVEL) * SymbolInfoDouble(symbol, SYMBOL_POINT);
      spec.valid    = spec.tickSize > 0 && spec.volMin > 0 && spec.volStep > 0 && spec.bid > 0 && spec.ask > 0;
      return spec.valid;
     }

   virtual long      PlaceLimit(const string symbol, const int side, const double lots, const double price,
                                const string comment, const long magic)
     {
      m_trade.SetTypeFilling(ORDER_FILLING_RETURN);
      double p = NormalizeDouble(price, (int)SymbolInfoInteger(symbol, SYMBOL_DIGITS));
      double v = Volume(symbol, lots);
      bool sent = (side == CP_SIDE_BUY)
                  ? m_trade.BuyLimit(v, p, symbol, 0, 0, ORDER_TIME_GTC, 0, comment)
                  : m_trade.SellLimit(v, p, symbol, 0, 0, ORDER_TIME_GTC, 0, comment);
      return Done(sent) ? (long)m_trade.ResultOrder() : 0;
     }

   virtual long      PlaceMarket(const string symbol, const int side, const double lots,
                                 const string comment, const long magic)
     {
      m_trade.SetTypeFillingBySymbol(symbol);
      double v = Volume(symbol, lots);
      bool sent = (side == CP_SIDE_BUY) ? m_trade.Buy(v, symbol, 0, 0, 0, comment)
                                        : m_trade.Sell(v, symbol, 0, 0, 0, comment);
      return Done(sent) ? (long)m_trade.ResultOrder() : 0;
     }

   virtual bool      ClosePosition(const long ticket, const double lots)
     {
      if(!PositionSelectByTicket((ulong)ticket))
        {
         m_err = "position #" + IntegerToString(ticket) + " not found";
         return false;
        }
      string symbol = PositionGetString(POSITION_SYMBOL);
      double volume = PositionGetDouble(POSITION_VOLUME);
      m_trade.SetTypeFillingBySymbol(symbol);
      bool sent = (lots >= volume - CP_EPS) ? m_trade.PositionClose((ulong)ticket)
                                            : m_trade.PositionClosePartial((ulong)ticket, Volume(symbol, lots));
      return Done(sent);
     }

   virtual bool      DeletePending(const long ticket)
     {
      return Done(m_trade.OrderDelete((ulong)ticket));
     }

   virtual string    LastError(void) { return m_err; }
  };

CBrokerMT5   g_broker;
CCopierSlave g_slave;

int OnInit()
  {
   g_broker.Setup(InpMagic, InpSlippagePoints);
   CPConfig cfg;
   cfg.magic         = InpMagic;
   cfg.ticksBetter   = MathMax(0, InpTicksBetter);
   cfg.lotMultiplier = InpLotMultiplier;
   cfg.symbolMap     = InpSymbolMap;
   cfg.masterSuffix  = InpMasterSuffix;
   cfg.slaveSuffix   = InpSlaveSuffix;
   cfg.staleSeconds  = MathMax(1, InpStaleSeconds);
   cfg.graceSeconds  = CP_GRACE_SECONDS;
   g_slave.Init(GetPointer(g_broker), cfg, InpChannel, InpRetrySeconds);   // account checks run once connected
   if(!EventSetMillisecondTimer(MathMax(50, InpTimerMs)))
      return INIT_FAILED;
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
