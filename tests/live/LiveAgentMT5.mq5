//+------------------------------------------------------------------+
//| LiveAgentMT5.mq5                                                 |
//| Helper script of the demo run (tools/live-run.ps1), MetaTrader 5.|
//| On the master account it opens and closes the master's own       |
//| positions when the driver asks. On the slave account it records  |
//| what the copier does and flattens the account at the end.        |
//| It is not part of the copier. It stops at once, doing nothing,   |
//| on an account that is not a demo account.                        |
//+------------------------------------------------------------------+
#property copyright "MIT License"
#property version   "1.00"

#include <Trade/Trade.mqh>
#include "LiveAgentCommon.mqh"

#define LA_NAME "mt5"

CTrade g_trade;
int    g_digits = 5;

bool IsDemoAccount(void) { return AccountInfoInteger(ACCOUNT_TRADE_MODE) == ACCOUNT_TRADE_MODE_DEMO; }

string OrderTypeName(const long type)
  {
   switch((int)type)
     {
      case ORDER_TYPE_BUY:        return "buy";
      case ORDER_TYPE_SELL:       return "sell";
      case ORDER_TYPE_BUY_LIMIT:  return "buy limit";
      case ORDER_TYPE_SELL_LIMIT: return "sell limit";
      case ORDER_TYPE_BUY_STOP:   return "buy stop";
      case ORDER_TYPE_SELL_STOP:  return "sell stop";
     }
   return "type " + IntegerToString(type);
  }

void Collect(LAItem &items[])
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
      items[n].kind    = 0;
      items[n].type    = (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY) ? "buy" : "sell";
      items[n].symbol  = PositionGetString(POSITION_SYMBOL);
      items[n].lots    = PositionGetDouble(POSITION_VOLUME);
      items[n].price   = PositionGetDouble(POSITION_PRICE_OPEN);
      items[n].magic   = PositionGetInteger(POSITION_MAGIC);
      items[n].comment = PositionGetString(POSITION_COMMENT);
      n++;
     }
   for(int i = 0; i < OrdersTotal(); i++)
     {
      ulong t = OrderGetTicket(i);
      if(t == 0)
         continue;
      ArrayResize(items, n + 1);
      items[n].ticket  = (long)t;
      items[n].kind    = 1;
      items[n].type    = OrderTypeName(OrderGetInteger(ORDER_TYPE));
      items[n].symbol  = OrderGetString(ORDER_SYMBOL);
      items[n].lots    = OrderGetDouble(ORDER_VOLUME_CURRENT);
      items[n].price   = OrderGetDouble(ORDER_PRICE_OPEN);
      items[n].magic   = OrderGetInteger(ORDER_MAGIC);
      items[n].comment = OrderGetString(ORDER_COMMENT);
      n++;
     }
  }

string Status(const int positions, const int orders)
  {
   MqlTick t;
   bool quoted = SymbolInfoTick(_Symbol, t);
   return "tick=" + IntegerToString((long)GetTickCount()) +
          "|connected=" + IntegerToString(TerminalInfoInteger(TERMINAL_CONNECTED)) +
          "|demo=" + (IsDemoAccount() ? "1" : "0") +
          "|hedging=" + (AccountInfoInteger(ACCOUNT_MARGIN_MODE) == ACCOUNT_MARGIN_MODE_RETAIL_HEDGING ? "1" : "0") +
          "|terminal_trade_allowed=" + IntegerToString(TerminalInfoInteger(TERMINAL_TRADE_ALLOWED)) +
          "|program_trade_allowed=" + IntegerToString(MQLInfoInteger(MQL_TRADE_ALLOWED)) +
          "|symbol=" + _Symbol +
          "|bid=" + (quoted ? DoubleToString(t.bid, g_digits) : "0") +
          "|ask=" + (quoted ? DoubleToString(t.ask, g_digits) : "0") +
          "|tick_size=" + DoubleToString(SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE), 8) +
          "|digits=" + IntegerToString(g_digits) +
          "|vol_min=" + DoubleToString(SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN), 2) +
          "|vol_step=" + DoubleToString(SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP), 2) +
          "|filling=" + IntegerToString(SymbolInfoInteger(_Symbol, SYMBOL_FILLING_MODE)) +
          "|stops_level=" + IntegerToString(SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL)) +
          "|positions=" + IntegerToString(positions) + "|orders=" + IntegerToString(orders);
  }

bool Sent(const bool ok)
  {
   uint rc = g_trade.ResultRetcode();
   return ok && (rc == TRADE_RETCODE_DONE || rc == TRADE_RETCODE_PLACED || rc == TRADE_RETCODE_DONE_PARTIAL);
  }

string TradeError(void)
  {
   return "retcode=" + IntegerToString(g_trade.ResultRetcode()) + "|" + g_trade.ResultRetcodeDescription();
  }

string ClosePosition(const ulong ticket, const double lots)
  {
   if(!PositionSelectByTicket(ticket))
      return "ERR|position not found";
   double volume = PositionGetDouble(POSITION_VOLUME);
   bool full = (lots <= 0 || lots >= volume - 1e-9);
   g_trade.SetTypeFillingBySymbol(PositionGetString(POSITION_SYMBOL));
   bool ok = full ? g_trade.PositionClose(ticket) : g_trade.PositionClosePartial(ticket, lots);
   if(!Sent(ok))
      return "ERR|" + TradeError();
   double closed = full ? volume : lots;
   LA_Log("CLOSE done #" + IntegerToString((long)ticket) + " " + DoubleToString(closed, 2) + " of " +
          DoubleToString(volume, 2) + " @" + DoubleToString(g_trade.ResultPrice(), g_digits));
   return "OK|ticket=" + IntegerToString((long)ticket) + "|closed=" + DoubleToString(closed, 2) +
          "|price=" + DoubleToString(g_trade.ResultPrice(), g_digits);
  }

//--- closes every position with this magic; with orders=true also deletes its pending orders
string Flatten(const long magic, const bool orders)
  {
   int closed = 0, deleted = 0, failed = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong t = PositionGetTicket(i);
      if(t == 0 || PositionGetInteger(POSITION_MAGIC) != magic)
         continue;
      if(StringFind(ClosePosition(t, 0), "OK") == 0)
         closed++;
      else
         failed++;
     }
   for(int i = OrdersTotal() - 1; orders && i >= 0; i--)
     {
      ulong t = OrderGetTicket(i);
      if(t == 0 || OrderGetInteger(ORDER_MAGIC) != magic)
         continue;
      if(Sent(g_trade.OrderDelete(t)))
        {
         deleted++;
         LA_Log("DELETE done #" + IntegerToString((long)t));
        }
      else
         failed++;
     }
   return (failed == 0 ? "OK" : "ERR") + "|closed=" + IntegerToString(closed) + "|deleted=" + IntegerToString(deleted) +
          "|failed=" + IntegerToString(failed);
  }

string Export(const int secondsBack)
  {
   datetime from = TimeCurrent() - secondsBack;
   if(!HistorySelect(from, TimeCurrent() + 86400))
      return "ERR|HistorySelect failed";
   string text = "# MetaTrader 5 deal history (server time), from " + TimeToString(from, TIME_DATE | TIME_SECONDS) + "\r\n";
   text += "deal;time;time_msc;type;entry;position;order;symbol;volume;price;magic;comment\r\n";
   int deals = 0, orders = 0;
   for(int i = 0; i < HistoryDealsTotal(); i++)
     {
      ulong d = HistoryDealGetTicket(i);
      long type = HistoryDealGetInteger(d, DEAL_TYPE);
      if(type != DEAL_TYPE_BUY && type != DEAL_TYPE_SELL)
         continue;
      text += IntegerToString((long)d) + ";" + TimeToString((datetime)HistoryDealGetInteger(d, DEAL_TIME), TIME_DATE | TIME_SECONDS) +
              ";" + IntegerToString(HistoryDealGetInteger(d, DEAL_TIME_MSC)) + ";" + (type == DEAL_TYPE_BUY ? "buy" : "sell") +
              ";" + EnumToString((ENUM_DEAL_ENTRY)HistoryDealGetInteger(d, DEAL_ENTRY)) +
              ";" + IntegerToString(HistoryDealGetInteger(d, DEAL_POSITION_ID)) + ";" + IntegerToString(HistoryDealGetInteger(d, DEAL_ORDER)) +
              ";" + HistoryDealGetString(d, DEAL_SYMBOL) + ";" + DoubleToString(HistoryDealGetDouble(d, DEAL_VOLUME), 2) +
              ";" + DoubleToString(HistoryDealGetDouble(d, DEAL_PRICE), g_digits) + ";" + IntegerToString(HistoryDealGetInteger(d, DEAL_MAGIC)) +
              ";" + HistoryDealGetString(d, DEAL_COMMENT) + "\r\n";
      deals++;
     }
   text += "# MetaTrader 5 order history (server time)\r\n";
   text += "order;setup_time;setup_msc;done_msc;type;state;position;symbol;volume_initial;price_open;magic;comment\r\n";
   for(int i = 0; i < HistoryOrdersTotal(); i++)
     {
      ulong o = HistoryOrderGetTicket(i);
      text += IntegerToString((long)o) + ";" + TimeToString((datetime)HistoryOrderGetInteger(o, ORDER_TIME_SETUP), TIME_DATE | TIME_SECONDS) +
              ";" + IntegerToString(HistoryOrderGetInteger(o, ORDER_TIME_SETUP_MSC)) + ";" + IntegerToString(HistoryOrderGetInteger(o, ORDER_TIME_DONE_MSC)) +
              ";" + OrderTypeName(HistoryOrderGetInteger(o, ORDER_TYPE)) + ";" + EnumToString((ENUM_ORDER_STATE)HistoryOrderGetInteger(o, ORDER_STATE)) +
              ";" + IntegerToString(HistoryOrderGetInteger(o, ORDER_POSITION_ID)) + ";" + HistoryOrderGetString(o, ORDER_SYMBOL) +
              ";" + DoubleToString(HistoryOrderGetDouble(o, ORDER_VOLUME_INITIAL), 2) + ";" + DoubleToString(HistoryOrderGetDouble(o, ORDER_PRICE_OPEN), g_digits) +
              ";" + IntegerToString(HistoryOrderGetInteger(o, ORDER_MAGIC)) + ";" + HistoryOrderGetString(o, ORDER_COMMENT) + "\r\n";
      orders++;
     }
   if(!CP_WriteTextAtomic(LA_Path(LA_NAME, "history"), text))
      return "ERR|history file not written";
   return "OK|deals=" + IntegerToString(deals) + "|orders=" + IntegerToString(orders);
  }

string Execute(const string verb, const string &args[])
  {
   if(verb == "PING")
      return "OK";
   if(verb == "OPEN")
     {
      string side = LA_Arg(args, 0);
      double lots = StringToDouble(LA_Arg(args, 1));
      string comment = "live:" + LA_Arg(args, 2);
      g_trade.SetTypeFillingBySymbol(_Symbol);
      bool ok = (side == "buy") ? g_trade.Buy(lots, _Symbol, 0, 0, 0, comment) : g_trade.Sell(lots, _Symbol, 0, 0, 0, comment);
      if(!Sent(ok))
         return "ERR|" + TradeError();
      ulong ticket = g_trade.ResultOrder();      // hedging: position ticket = opening order ticket
      double price = PositionSelectByTicket(ticket) ? PositionGetDouble(POSITION_PRICE_OPEN) : g_trade.ResultPrice();
      LA_Log("OPEN done #" + IntegerToString((long)ticket) + " " + side + " " + DoubleToString(lots, 2) + " " + _Symbol +
             " @" + DoubleToString(price, g_digits) + " (" + comment + ")");
      return "OK|ticket=" + IntegerToString((long)ticket) + "|price=" + DoubleToString(price, g_digits) +
             "|lots=" + DoubleToString(lots, 2);
     }
   if(verb == "CLOSE")
      return ClosePosition((ulong)StringToInteger(LA_Arg(args, 0)), StringToDouble(LA_Arg(args, 1)));
   if(verb == "CLOSEALL")
      return Flatten(StringToInteger(LA_Arg(args, 0)), false);
   if(verb == "FLAT")
      return Flatten(StringToInteger(LA_Arg(args, 0)), true);
   if(verb == "EXPORT")
      return Export((int)StringToInteger(LA_Arg(args, 0)));
   return "ERR|unknown command";
  }

void OnStart()
  {
   FolderCreate(LA_DIR, FILE_COMMON);
   g_digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   uint waitStart = GetTickCount();
   while(!IsStopped() && (!TerminalInfoInteger(TERMINAL_CONNECTED) || AccountInfoInteger(ACCOUNT_LOGIN) == 0))
     {
      CP_WriteTextAtomic(LA_Path(LA_NAME, "status"), "tick=" + IntegerToString((long)GetTickCount()) + "|connected=0");
      if(GetTickCount() - waitStart > 180000)
        {
         LA_Log("not connected after 180 s: agent stopped");
         return;
        }
      Sleep(200);
     }
   if(!IsDemoAccount())
     {
      CP_WriteTextAtomic(LA_Path(LA_NAME, "status"), "tick=" + IntegerToString((long)GetTickCount()) + "|connected=1|demo=0");
      LA_Log("this account is not a demo account: agent stopped, nothing done");
      return;
     }
   g_digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   g_trade.SetMarginMode();   // read when CTrade was built, possibly before the login: partial closes need it
   g_trade.SetExpertMagicNumber(LA_MAGIC);
   g_trade.SetDeviationInPoints(20);
   g_trade.SetAsyncMode(false);
   long lastId = LA_MaxId(LA_NAME);
   LAItem prev[], cur[];
   Collect(prev);
   LA_WriteState(LA_NAME, prev, g_digits);
   for(int i = 0; i < ArraySize(prev); i++)
      LA_Append(LA_Path(LA_NAME, "events"), LA_Now() + ";INIT;" + LA_ItemText(prev[i], g_digits));
   LA_Log("agent started on " + _Symbol + ": demo account, " + IntegerToString(ArraySize(prev)) + " open item(s)");
   uint lastStatus = 0;
   while(!IsStopped())
     {
      Collect(cur);
      if(LA_Diff(LA_NAME, prev, cur, g_digits))
        {
         LA_WriteState(LA_NAME, cur, g_digits);
         LA_CopyItems(cur, prev);
        }
      long id;
      string verb;
      string args[];
      if(LA_NextCommand(LA_NAME, lastId, id, verb, args))
        {
         lastId = id;
         if(verb == "QUIT")
           {
            LA_Append(LA_Path(LA_NAME, "out"), IntegerToString(id) + "|OK|QUIT");
            LA_Log("QUIT: closing this chart");
            ChartClose(ChartID());
            return;
           }
         string result = Execute(verb, args);
         int bar = StringFind(result, "|");
         string head = (bar < 0) ? result : StringSubstr(result, 0, bar);
         string tail = (bar < 0) ? "" : StringSubstr(result, bar);
         LA_Append(LA_Path(LA_NAME, "out"), IntegerToString(id) + "|" + head + "|" + verb + tail);
         LA_Log("command " + IntegerToString(id) + " " + verb + ": " + result);
         continue;   // record the change of state at once
        }
      if(GetTickCount() - lastStatus >= 500)
        {
         CP_WriteTextAtomic(LA_Path(LA_NAME, "status"), Status(PositionsTotal(), OrdersTotal()));
         lastStatus = GetTickCount();
        }
      Sleep(20);
     }
  }
