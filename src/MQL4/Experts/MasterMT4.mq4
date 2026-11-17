//+------------------------------------------------------------------+
//| MasterMT4.mq4                                                    |
//| Publishes this MT4 account's open market orders for the slave    |
//| EAs. Places no orders.                                           |
//+------------------------------------------------------------------+
#property copyright "MIT License"
#property version   "1.00"
#property strict
#property description "Trade copier master (MT4). Writes Terminal\\Common\\Files\\CopierProof\\<channel>.snap"

#include <CopierProof/CopierMaster.mqh>
#include <CopierProof/CopierMT4.mqh>

input string InpChannel          = "default"; // Channel name (same on master and slave)
input int    InpTimerMs          = 200;       // Scan period, milliseconds
input int    InpHeartbeatSeconds = 1;         // Rewrite at least this often, seconds

CCopierMaster g_master;
CCPMT4Orders  g_orders;
bool          g_started = false;

int OnInit()
  {
   if(!g_master.Init(InpChannel, InpHeartbeatSeconds, (long)TimeGMT()))
     {
      CP_Log("cannot create Common\\Files\\" + CP_FOLDER);
      return INIT_FAILED;
     }
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
//--- not connected: publish nothing, so slaves see an old snapshot and wait
   if(!IsConnected() || AccountNumber() == 0)
      return;
//--- the alias file is named after the account, unknown in OnInit at terminal start-up
   if(!g_started)
     {
      string error = "";
      if(!g_orders.Init(CP_AliasPath(InpChannel, "master", AccountNumber()), error))
        {
         CP_Log(error + "; master stopped");
         ExpertRemove();
         return;
        }
      g_started = true;
     }
   CPMT4Order orders[];
   int total = g_orders.Scan(orders);
   CPMasterPos pos[];
   int n = 0;
   for(int i = 0; i < total; i++)
     {
      if(orders[i].type != OP_BUY && orders[i].type != OP_SELL)
         continue;
      ArrayResize(pos, n + 1);
      pos[n].ticket      = orders[i].identity;
      pos[n].symbol      = orders[i].symbol;
      pos[n].side        = (orders[i].type == OP_BUY) ? CP_SIDE_BUY : CP_SIDE_SELL;
      pos[n].lots        = orders[i].lots;
      pos[n].price       = orders[i].openPrice;
      pos[n].openTimeMsc = orders[i].openTimeMsc;
      n++;
     }
   g_master.Publish(pos, (long)TimeGMT());
  }
