//+------------------------------------------------------------------+
//| LiveAgentMT4.mq4                                                 |
//| Helper script of the demo run (tools/live-run.ps1), MetaTrader 4.|
//| On the master account it opens and closes the master's own       |
//| orders when the driver asks. On the slave account it records     |
//| what the copier does and flattens the account at the end.        |
//| It is not part of the copier. It stops at once, doing nothing,   |
//| on an account that is not a demo account.                        |
//+------------------------------------------------------------------+
#property copyright "MIT License"
#property version   "1.00"
#property strict

#include "LiveAgentCommon.mqh"

#define LA_NAME     "mt4"
#define LA_SLIPPAGE 20

string OrderTypeName(const int type)
  {
   switch(type)
     {
      case OP_BUY:       return "buy";
      case OP_SELL:      return "sell";
      case OP_BUYLIMIT:  return "buy limit";
      case OP_SELLLIMIT: return "sell limit";
      case OP_BUYSTOP:   return "buy stop";
      case OP_SELLSTOP:  return "sell stop";
     }
   return "type " + IntegerToString(type);
  }

void Collect(LAItem &items[])
  {
   ArrayResize(items, 0);
   int n = 0;
   for(int i = 0; i < OrdersTotal(); i++)
     {
      if(!OrderSelect(i, SELECT_BY_POS, MODE_TRADES))
         continue;
      ArrayResize(items, n + 1);
      items[n].ticket  = OrderTicket();
      items[n].kind    = (OrderType() == OP_BUY || OrderType() == OP_SELL) ? 0 : 1;
      items[n].type    = OrderTypeName(OrderType());
      items[n].symbol  = OrderSymbol();
      items[n].lots    = OrderLots();
      items[n].price   = OrderOpenPrice();
      items[n].magic   = OrderMagicNumber();
      items[n].comment = OrderComment();
      n++;
     }
  }

string Status(LAItem &items[])
  {
   int positions = 0;
   for(int i = 0; i < ArraySize(items); i++)
      if(items[i].kind == 0)
         positions++;
   return "tick=" + IntegerToString((long)GetTickCount()) +
          "|connected=" + (IsConnected() ? "1" : "0") +
          "|demo=" + (IsDemo() ? "1" : "0") +
          "|hedging=1" +
          "|terminal_trade_allowed=" + (IsExpertEnabled() ? "1" : "0") +
          "|program_trade_allowed=" + (IsTradeAllowed() ? "1" : "0") +
          "|symbol=" + _Symbol +
          "|bid=" + DoubleToString(MarketInfo(_Symbol, MODE_BID), _Digits) +
          "|ask=" + DoubleToString(MarketInfo(_Symbol, MODE_ASK), _Digits) +
          "|tick_size=" + DoubleToString(MarketInfo(_Symbol, MODE_TICKSIZE), 8) +
          "|digits=" + IntegerToString(_Digits) +
          "|vol_min=" + DoubleToString(MarketInfo(_Symbol, MODE_MINLOT), 2) +
          "|vol_step=" + DoubleToString(MarketInfo(_Symbol, MODE_LOTSTEP), 2) +
          "|stops_level=" + DoubleToString(MarketInfo(_Symbol, MODE_STOPLEVEL), 0) +
          "|positions=" + IntegerToString(positions) + "|orders=" + IntegerToString(ArraySize(items) - positions);
  }

string LastError(const string what) { return "ERR|" + what + " error " + IntegerToString(GetLastError()); }

string ClosePosition(const int ticket, const double lots)
  {
   if(!OrderSelect(ticket, SELECT_BY_TICKET, MODE_TRADES) || OrderCloseTime() != 0)
      return "ERR|order not open";
   double volume = OrderLots();
   bool full = (lots <= 0 || lots >= volume - 1e-9);
   double v = full ? volume : lots;
   RefreshRates();
   double price = MarketInfo(OrderSymbol(), OrderType() == OP_BUY ? MODE_BID : MODE_ASK);
   if(!OrderClose(ticket, v, price, LA_SLIPPAGE, clrNONE))
      return LastError("OrderClose");
   string remainder = "0";
   if(!full)
      for(int i = 0; i < OrdersTotal(); i++)
         if(OrderSelect(i, SELECT_BY_POS, MODE_TRADES) && StringFind(OrderComment(), "from #" + IntegerToString(ticket)) >= 0)
            remainder = IntegerToString(OrderTicket());
   LA_Log("CLOSE done #" + IntegerToString(ticket) + " " + DoubleToString(v, 2) + " of " + DoubleToString(volume, 2) +
          " @" + DoubleToString(price, _Digits) + (full ? "" : " remainder #" + remainder));
   return "OK|ticket=" + IntegerToString(ticket) + "|closed=" + DoubleToString(v, 2) + "|price=" +
          DoubleToString(price, _Digits) + "|remainder=" + remainder;
  }

string Flatten(const int magic, const bool orders)
  {
   int closed = 0, deleted = 0, failed = 0;
   for(int i = OrdersTotal() - 1; i >= 0; i--)
     {
      if(!OrderSelect(i, SELECT_BY_POS, MODE_TRADES) || OrderMagicNumber() != magic)
         continue;
      int ticket = OrderTicket();
      int type = OrderType();
      if(type == OP_BUY || type == OP_SELL)
        {
         if(StringFind(ClosePosition(ticket, 0), "OK") == 0)
            closed++;
         else
            failed++;
        }
      else if(orders)
        {
         if(OrderDelete(ticket, clrNONE))
           {
            deleted++;
            LA_Log("DELETE done #" + IntegerToString(ticket));
           }
         else
            failed++;
        }
     }
   return (failed == 0 ? "OK" : "ERR") + "|closed=" + IntegerToString(closed) + "|deleted=" + IntegerToString(deleted) +
          "|failed=" + IntegerToString(failed);
  }

string Export(const int secondsBack)
  {
   datetime from = TimeCurrent() - secondsBack;
   string text = "# MetaTrader 4 order history (server time, seconds), from " + TimeToString(from, TIME_DATE | TIME_SECONDS) + "\r\n";
   text += "ticket;type;open_time;open_price;close_time;close_price;lots;magic;comment\r\n";
   int n = 0;
   for(int i = 0; i < OrdersHistoryTotal(); i++)
     {
      if(!OrderSelect(i, SELECT_BY_POS, MODE_HISTORY) || OrderType() > OP_SELLSTOP)
         continue;
      if(OrderOpenTime() < from && OrderCloseTime() < from)
         continue;
      text += IntegerToString(OrderTicket()) + ";" + OrderTypeName(OrderType()) + ";" +
              TimeToString(OrderOpenTime(), TIME_DATE | TIME_SECONDS) + ";" + DoubleToString(OrderOpenPrice(), _Digits) + ";" +
              TimeToString(OrderCloseTime(), TIME_DATE | TIME_SECONDS) + ";" + DoubleToString(OrderClosePrice(), _Digits) + ";" +
              DoubleToString(OrderLots(), 2) + ";" + IntegerToString(OrderMagicNumber()) + ";" + OrderComment() + "\r\n";
      n++;
     }
   if(!CP_WriteTextAtomic(LA_Path(LA_NAME, "history"), text))
      return "ERR|history file not written";
   return "OK|orders=" + IntegerToString(n);
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
      RefreshRates();
      double price = MarketInfo(_Symbol, side == "buy" ? MODE_ASK : MODE_BID);
      int ticket = OrderSend(_Symbol, side == "buy" ? OP_BUY : OP_SELL, lots, price, LA_SLIPPAGE, 0, 0, comment, LA_MAGIC, 0, clrNONE);
      if(ticket < 0)
         return LastError("OrderSend");
      double open = OrderSelect(ticket, SELECT_BY_TICKET) ? OrderOpenPrice() : price;
      LA_Log("OPEN done #" + IntegerToString(ticket) + " " + side + " " + DoubleToString(lots, 2) + " " + _Symbol +
             " @" + DoubleToString(open, _Digits) + " (" + comment + ")");
      return "OK|ticket=" + IntegerToString(ticket) + "|price=" + DoubleToString(open, _Digits) + "|lots=" + DoubleToString(lots, 2);
     }
   if(verb == "CLOSE")
      return ClosePosition((int)StringToInteger(LA_Arg(args, 0)), StringToDouble(LA_Arg(args, 1)));
   if(verb == "CLOSEALL")
      return Flatten((int)StringToInteger(LA_Arg(args, 0)), false);
   if(verb == "FLAT")
      return Flatten((int)StringToInteger(LA_Arg(args, 0)), true);
   if(verb == "EXPORT")
      return Export((int)StringToInteger(LA_Arg(args, 0)));
   return "ERR|unknown command";
  }

void OnStart()
  {
   FolderCreate(LA_DIR, FILE_COMMON);
   uint waitStart = GetTickCount();
   while(!IsStopped() && (!IsConnected() || AccountNumber() == 0))
     {
      CP_WriteTextAtomic(LA_Path(LA_NAME, "status"), "tick=" + IntegerToString((long)GetTickCount()) + "|connected=0");
      if(GetTickCount() - waitStart > 180000)
        {
         LA_Log("not connected after 180 s: agent stopped");
         return;
        }
      Sleep(200);
     }
   if(!IsDemo())
     {
      CP_WriteTextAtomic(LA_Path(LA_NAME, "status"), "tick=" + IntegerToString((long)GetTickCount()) + "|connected=1|demo=0");
      LA_Log("this account is not a demo account: agent stopped, nothing done");
      return;
     }
   long lastId = LA_MaxId(LA_NAME);
   LAItem prev[], cur[];
   Collect(prev);
   LA_WriteState(LA_NAME, prev, _Digits);
   for(int i = 0; i < ArraySize(prev); i++)
      LA_Append(LA_Path(LA_NAME, "events"), LA_Now() + ";INIT;" + LA_ItemText(prev[i], _Digits));
   LA_Log("agent started on " + _Symbol + ": demo account, " + IntegerToString(ArraySize(prev)) + " open item(s)");
   uint lastStatus = 0;
   while(!IsStopped())
     {
      Collect(cur);
      if(LA_Diff(LA_NAME, prev, cur, _Digits))
        {
         LA_WriteState(LA_NAME, cur, _Digits);
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
         continue;
        }
      if(GetTickCount() - lastStatus >= 500)
        {
         CP_WriteTextAtomic(LA_Path(LA_NAME, "status"), Status(cur));
         lastStatus = GetTickCount();
        }
      Sleep(20);
     }
  }
