//+------------------------------------------------------------------+
//| MasterMT5.mq5                                                    |
//| Publishes this MT5 account's open positions for the slave EAs.   |
//| Places no orders.                                                |
//+------------------------------------------------------------------+
#property copyright "MIT License"
#property version   "1.00"
#property description "Trade copier master (MT5). Writes Terminal\\Common\\Files\\CopierProof\\<channel>.snap"

#include <CopierProof/CopierMaster.mqh>

input string InpChannel          = "default"; // Channel name (same on master and slave)
input int    InpTimerMs          = 200;       // Scan period, milliseconds
input int    InpHeartbeatSeconds = 1;         // Rewrite at least this often, seconds

CCopierMaster g_master;
bool          g_checked = false;

int OnInit()
  {
   if(!g_master.Init(InpChannel, InpHeartbeatSeconds, (long)TimeGMT()))
     {
      CP_Log("cannot create Common\\Files\\" + CP_FOLDER);
      return INIT_FAILED;
     }
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
//--- not connected: publish nothing, so slaves see an old snapshot and wait
   if(!TerminalInfoInteger(TERMINAL_CONNECTED) || AccountInfoInteger(ACCOUNT_LOGIN) == 0)
      return;
//--- the account type is checked once connected (at terminal start-up OnInit may run before login)
   if(!g_checked)
     {
      if(AccountInfoInteger(ACCOUNT_MARGIN_MODE) != ACCOUNT_MARGIN_MODE_RETAIL_HEDGING)
        {
         CP_Log("master needs an MT5 hedging account; netting accounts are not supported; master stopped");
         ExpertRemove();
         return;
        }
      g_checked = true;
     }
   CPMasterPos pos[];
   int n = 0;
   for(int i = 0; i < PositionsTotal(); i++)
     {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0)
         continue;
      long type = PositionGetInteger(POSITION_TYPE);
      if(type != POSITION_TYPE_BUY && type != POSITION_TYPE_SELL)
         continue;
      ArrayResize(pos, n + 1);
      pos[n].ticket      = PositionGetInteger(POSITION_IDENTIFIER);
      pos[n].symbol      = PositionGetString(POSITION_SYMBOL);
      pos[n].side        = (type == POSITION_TYPE_BUY) ? CP_SIDE_BUY : CP_SIDE_SELL;
      pos[n].lots        = PositionGetDouble(POSITION_VOLUME);
      pos[n].price       = PositionGetDouble(POSITION_PRICE_OPEN);
      pos[n].openTimeMsc = PositionGetInteger(POSITION_TIME_MSC);
      n++;
     }
   g_master.Publish(pos, (long)TimeGMT());
  }
