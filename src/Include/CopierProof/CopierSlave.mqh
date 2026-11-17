//+------------------------------------------------------------------+
//| CopierSlave.mqh                                                  |
//| Slave loop shared by SlaveMT4 and SlaveMT5: read the snapshot,   |
//| run the core cycle, execute its actions through a broker         |
//| adapter, keep the ticket map on disk.                            |
//+------------------------------------------------------------------+
#ifndef COPIER_PROOF_SLAVE_MQH
#define COPIER_PROOF_SLAVE_MQH

#include "CopierCore.mqh"
#include "CopierFiles.mqh"

//--- the only platform-specific part of a slave
class CCopierBroker
  {
public:
   virtual          ~CCopierBroker(void) {}
   virtual long      AccountId(void) { return 0; }
   //--- MT5: ACCOUNT_TRADE_MODE_DEMO, MT4: IsDemo(); anything else stops the slave
   virtual bool      AccountIsDemo(void) { return false; }
   //--- connected and logged in: before that the order lists can be empty
   virtual bool      Ready(void) { return false; }
   //--- operator alert (stale master); the tests count these instead
   virtual void      Notify(const string msg) { Alert("[CopierProof] ", msg); }
   //--- account-dependent setup, called once on the first Ready() cycle
   virtual bool      Start(string &error) { return true; }
   virtual void      CollectItems(CPSlaveItem &items[]) { ArrayResize(items, 0); }
   virtual bool      GetSpec(const string symbol, CPSymbolSpec &spec) { spec.valid = false; return false; }
   //--- return the new ticket (MT5: order ticket = position identifier), 0 on failure
   virtual long      PlaceLimit(const string symbol, const int side, const double lots, const double price,
                                const string comment, const long magic) { return 0; }
   virtual long      PlaceMarket(const string symbol, const int side, const double lots,
                                 const string comment, const long magic) { return 0; }
   virtual bool      ClosePosition(const long ticket, const double lots) { return false; }
   virtual bool      DeletePending(const long ticket) { return false; }
   virtual string    LastError(void) { return ""; }
  };

class CCopierSlave
  {
private:
   CCopierBroker    *m_broker;
   CPConfig          m_cfg;
   string            m_snapPath;
   string            m_mapPath;
   CCPSlaveState     m_state;
   CPMapEntry        m_map[];
   long              m_failMaster[];
   long              m_failTime[];
   int               m_retrySeconds;
   string            m_lastStatus;
   long              m_lastInvalidLog;
   string            m_channel;
   bool              m_started;
   bool              m_stopped;
   bool              m_frozen;

   bool              SaveMap(void)
     {
      if(CP_WriteTextAtomic(m_mapPath, CP_MapToText(m_map)))
         return true;
      CP_Log("could not save the ticket map (error " + IntegerToString(GetLastError()) + ")");
      return false;
     }

   void              SetStatus(const string status)
     {
      if(status == m_lastStatus)
         return;
      m_lastStatus = status;
      CP_Log(status);
     }

   int               FailIndex(const long master)
     {
      for(int i = 0; i < ArraySize(m_failMaster); i++)
         if(m_failMaster[i] == master)
            return i;
      return -1;
     }

   bool              Throttled(const long master, const long now)
     {
      int i = FailIndex(master);
      return i >= 0 && now - m_failTime[i] < m_retrySeconds;
     }

   void              MarkFailure(const long master, const long now)
     {
      int i = FailIndex(master);
      if(i < 0)
        {
         i = ArraySize(m_failMaster);
         ArrayResize(m_failMaster, i + 1);
         ArrayResize(m_failTime, i + 1);
         m_failMaster[i] = master;
        }
      m_failTime[i] = now;
     }

   void              ClearFailure(const long master)
     {
      int i = FailIndex(master);
      if(i < 0)
         return;
      int n = ArraySize(m_failMaster);
      m_failMaster[i] = m_failMaster[n - 1];
      m_failTime[i]   = m_failTime[n - 1];
      ArrayResize(m_failMaster, n - 1);
      ArrayResize(m_failTime, n - 1);
     }

   bool              Execute(const CPAction &a, const long now)
     {
      string what = " master #" + IntegerToString(a.masterTicket) + " " + a.symbol + " " +
                    (a.side == CP_SIDE_BUY ? "buy" : "sell") + " " + DoubleToString(a.lots, 2);
      if(a.type == CP_ACT_PLACE_LIMIT || a.type == CP_ACT_PLACE_MARKET)
        {
         string comment = CP_CopyComment(a.masterTicket);
         long ticket = (a.type == CP_ACT_PLACE_LIMIT)
                       ? m_broker.PlaceLimit(a.symbol, a.side, a.lots, a.price, comment, m_cfg.magic)
                       : m_broker.PlaceMarket(a.symbol, a.side, a.lots, comment, m_cfg.magic);
         if(ticket <= 0)
           {
            CP_Log("FAILED " + (a.type == CP_ACT_PLACE_LIMIT ? "limit" : "market") + what + ": " + m_broker.LastError());
            return false;
           }
         CP_MapRecordPlacement(m_map, a, ticket, now);
         SaveMap();   // right after the order: a restart must find the link
         CP_Log((a.type == CP_ACT_PLACE_LIMIT ? "limit @" + DoubleToString(a.price, 8) : "market") + what +
                " -> slave #" + IntegerToString(ticket) + " (" + a.reason + ")");
         return true;
        }
      bool ok = (a.type == CP_ACT_DELETE_PENDING) ? m_broker.DeletePending(a.slaveTicket)
                                                   : m_broker.ClosePosition(a.slaveTicket, a.lots);
      string verb = (a.type == CP_ACT_DELETE_PENDING) ? "delete" : "close";
      if(!ok)
        {
         CP_Log("FAILED " + verb + " slave #" + IntegerToString(a.slaveTicket) + what + ": " + m_broker.LastError());
         return false;
        }
      CP_Log(verb + " slave #" + IntegerToString(a.slaveTicket) + what + " (" + a.reason + ")");
      return true;
     }

   //--- runs on the first connected cycle: the account number names the map file,
   //--- and at terminal start-up it is not known yet in OnInit
   bool              Start(const long now, string &error)
     {
      error = CP_DemoOnlyError(MQLInfoString(MQL_PROGRAM_NAME), m_broker.AccountIsDemo());
      if(error != "")
         return false;
      if(!m_broker.Start(error))
         return false;
      if(!CP_EnsureFolder())
        {
         error = "cannot create Common\\Files\\" + CP_FOLDER;
         return false;
        }
      m_snapPath = CP_SnapshotPath(m_channel);
      m_mapPath  = CP_SlaveMapPath(m_channel, m_broker.AccountId(), m_cfg.magic);
      ArrayResize(m_map, 0);
      string text;
      if(CP_ReadText(m_mapPath, text) && !CP_MapFromText(text, m_map))
        {
         error = "ticket map Common\\Files\\" + m_mapPath + " is damaged; fix or remove it before starting";
         return false;
        }
      CP_MapMarkSeen(m_map, now);
      CP_Log("slave reading Common\\Files\\" + m_snapPath + ", ticket map " + m_mapPath + " (" +
             IntegerToString(ArraySize(m_map)) + " link(s) loaded)");
      return true;
     }

public:
                     CCopierSlave(void) : m_broker(NULL), m_retrySeconds(2), m_lastInvalidLog(0),
                     m_started(false), m_stopped(false), m_frozen(false) {}

   void              Init(CCopierBroker *broker, const CPConfig &cfg, const string channel, const int retrySeconds)
     {
      m_broker       = broker;
      m_cfg          = cfg;
      m_channel      = channel;
      m_retrySeconds = MathMax(1, retrySeconds);
      m_started      = false;
      m_stopped      = false;
      m_frozen       = false;
     }

   void              Cycle(const long now)
     {
      if(m_stopped)
         return;
      if(!m_broker.Ready())
        {
         SetStatus("slave terminal not connected: waiting");
         return;
        }
      if(!m_started)
        {
         string error = "";
         if(!Start(now, error))
           {
            CP_Log(error + "; slave stopped");
            m_stopped = true;
            ExpertRemove();
            return;
           }
         m_started = true;
        }
      string text;
      if(CP_ReadText(m_snapPath, text) && CP_AcceptSnapshot(text, m_state) == CP_ACCEPT_INVALID &&
         now - m_lastInvalidLog >= 10)
        {
         CP_Log("snapshot incomplete or damaged: ignored, keeping the last complete one");
         m_lastInvalidLog = now;
        }

      CPSymbolSpec specs[];
      string missing = "";
      if(m_state.has)
         for(int i = 0; i < ArraySize(m_state.current.pos); i++)
           {
            string sym = CP_MapSymbol(m_state.current.pos[i].symbol, m_cfg.symbolMap, m_cfg.masterSuffix, m_cfg.slaveSuffix);
            if(CP_FindSpec(specs, sym) >= 0)
               continue;
            int n = ArraySize(specs);
            ArrayResize(specs, n + 1);
            specs[n].symbol = sym;
            specs[n].valid  = m_broker.GetSpec(sym, specs[n]);
            specs[n].symbol = sym;
            if(!specs[n].valid)
               missing += (missing == "" ? "" : ",") + sym;
           }

      CPSlaveItem items[];
      m_broker.CollectItems(items);
      string mapBefore = CP_MapToText(m_map);
      CPAction acts[];
      int r = CP_SlaveCycle(m_state, m_map, items, specs, m_cfg, now, acts);
      if(r == CP_CYCLE_NO_SNAPSHOT)
         SetStatus("waiting for a complete master snapshot");
      else if(r == CP_CYCLE_STALE)
         SetStatus("master snapshot older than " + IntegerToString(m_cfg.staleSeconds) +
                   " s: master not running? no copies and no exits until it is back");
      else
         SetStatus("following master session " + IntegerToString(m_state.current.session) +
                   (missing == "" ? "" : "; slave symbol unavailable: " + missing));

      int freeze = CP_FreezeEvent(m_frozen, r);
      string alert = "";
      if(freeze == CP_FREEZE_ENTER)
         alert = "master snapshot older than " + IntegerToString(m_cfg.staleSeconds) +
                 " s: slave frozen, no copies and no exits until the master is back";
      else if(freeze == CP_FREEZE_RESUME)
         alert = "master snapshot fresh again: slave resumed";
      if(alert != "")
        {
         CP_Log("ALERT " + alert);
         m_broker.Notify(alert);
        }

      for(int i = 0; i < ArraySize(acts); i++)
        {
         if(Throttled(acts[i].masterTicket, now))
            continue;
         if(Execute(acts[i], now))
            ClearFailure(acts[i].masterTicket);
         else
            MarkFailure(acts[i].masterTicket, now);
        }
      if(CP_MapToText(m_map) != mapBefore)
         SaveMap();
     }
  };

#endif
