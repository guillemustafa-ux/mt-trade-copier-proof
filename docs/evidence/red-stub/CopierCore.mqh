//+------------------------------------------------------------------+
//| CopierCore.mqh                                                   |
//| Platform-neutral decision logic of the trade copier.             |
//| No trading or terminal calls here: the same file compiles as     |
//| MQL4 and MQL5, and every rule below is exercised by              |
//| tests/CopierTests.mqh.                                           |
//+------------------------------------------------------------------+
#ifndef COPIER_PROOF_CORE_MQH
#define COPIER_PROOF_CORE_MQH

#define CP_SIDE_BUY            0
#define CP_SIDE_SELL           1

#define CP_ROLE_INITIAL        0   // first position of a direction: copied as a limit
#define CP_ROLE_ADDON          1   // later position of the same symbol and side: copied at market

#define CP_ST_PENDING          0   // slave limit placed, not (fully) filled yet
#define CP_ST_OPEN             1   // slave position open
#define CP_ST_DONE             2   // finished; the master ticket is never copied again

#define CP_KIND_PENDING        0
#define CP_KIND_POSITION       1

#define CP_ACT_PLACE_LIMIT     1
#define CP_ACT_PLACE_MARKET    2
#define CP_ACT_CLOSE           3   // close `lots` of slave position `slaveTicket`
#define CP_ACT_DELETE_PENDING  4

#define CP_CYCLE_OK            0
#define CP_CYCLE_NO_SNAPSHOT   1
#define CP_CYCLE_STALE         2

#define CP_ACCEPT_NEW          1
#define CP_ACCEPT_NOT_NEWER    0
#define CP_ACCEPT_INVALID     -1

#define CP_EPS                 1e-9

//--- one open position on the master account
struct CPMasterPos
  {
   long              ticket;       // stable identity (MT5: POSITION_IDENTIFIER, MT4: first ticket of the chain)
   string            symbol;
   int               side;         // CP_SIDE_*
   double            lots;
   double            price;        // open price
   long              openTimeMsc;  // open time in milliseconds
  };

//--- what the slave sees on its own account
struct CPSlaveItem
  {
   long              ticket;       // current ticket (used to close/delete)
   long              origin;       // identity of the copy (MT5: order ticket / POSITION_IDENTIFIER)
   int               kind;         // CP_KIND_*
   string            symbol;
   int               side;
   double            lots;
   long              magic;
   string            comment;
  };

//--- slave trading constraints of one symbol
struct CPSymbolSpec
  {
   string            symbol;
   bool              valid;
   double            tickSize;
   double            volMin;
   double            volMax;
   double            volStep;
   double            bid;
   double            ask;
  };

//--- persisted link between one master ticket and its slave copy
struct CPMapEntry
  {
   long              masterTicket;
   int               role;
   int               status;
   long              slaveTicket;       // origin of the copy
   string            slaveSymbol;
   int               side;
   double            masterLotsAtCopy;
   double            slaveLotsAtCopy;
   long              placedAt;          // GMT seconds
  };

struct CPAction
  {
   int               type;
   long              masterTicket;
   int               role;
   string            symbol;
   int               side;
   double            lots;
   double            price;             // limit price, 0 for market and close
   long              slaveTicket;       // ticket to close or delete
   double            masterLots;
   string            reason;
  };

struct CPConfig
  {
   long              magic;
   int               ticksBetter;
   double            lotMultiplier;
   string            symbolMap;
   string            masterSuffix;
   string            slaveSuffix;
   int               staleSeconds;
   int               graceSeconds;
  };

class CCPSnapshot
  {
public:
   long              session;
   long              seq;
   long              writeTime;
   CPMasterPos       pos[];
                     CCPSnapshot(void) { Reset(); }
   void              Reset(void) { session = 0; seq = 0; writeTime = 0; ArrayResize(pos, 0); }
  };

class CCPSlaveState
  {
public:
   bool              has;
   long              lastSession;
   long              lastSeq;
   CCPSnapshot       current;
                     CCPSlaveState(void) { has = false; lastSession = 0; lastSeq = 0; }
  };

//--- MT4 only: current ticket -> identity (MT4 renumbers the remainder of a partial close)
class CCPAliasTable
  {
public:
   long              tickets[];
   long              ids[];
  };

//--- RED stub: same API as the real core, rules not implemented
int CP_MapFind(const CPMapEntry &map[], const long masterTicket)
  {
   for(int i = 0; i < ArraySize(map); i++)
      if(map[i].masterTicket == masterTicket)
         return i;
   return -1;
  }
int CP_MapAdd(CPMapEntry &map[], const long masterTicket, const int role, const int status, const long slaveTicket,
              const string slaveSymbol, const int side, const double masterLots, const double slaveLots, const long placedAt)
  {
   int n = ArraySize(map);
   ArrayResize(map, n + 1);
   map[n].masterTicket = masterTicket; map[n].role = role; map[n].status = status; map[n].slaveTicket = slaveTicket;
   map[n].slaveSymbol = slaveSymbol; map[n].side = side; map[n].masterLotsAtCopy = masterLots;
   map[n].slaveLotsAtCopy = slaveLots; map[n].placedAt = placedAt;
   return n;
  }
void CP_CopySnapshot(const CCPSnapshot &src, CCPSnapshot &dst)
  {
   dst.session = src.session; dst.seq = src.seq; dst.writeTime = src.writeTime;
   int n = ArraySize(src.pos);
   ArrayResize(dst.pos, n);
   for(int i = 0; i < n; i++)
      dst.pos[i] = src.pos[i];
  }
string CP_MapToText(const CPMapEntry &map[]) { return ""; }
bool   CP_MapFromText(const string text, CPMapEntry &map[]) { ArrayResize(map, 0); return false; }
void   CP_AliasResolveAll(CCPAliasTable &t, const long &openTickets[], const string &comments[], long &ids[])
  {
   ArrayResize(ids, ArraySize(openTickets));
   for(int i = 0; i < ArraySize(openTickets); i++)
      ids[i] = openTickets[i];
  }
string CP_AliasToText(const CCPAliasTable &t) { return ""; }
bool   CP_AliasFromText(const string text, CCPAliasTable &t) { return false; }
string CP_BuildSnapshotText(const long session, const long seq, const long writeTime, const CPMasterPos &pos[]) { return ""; }
bool   CP_ParseSnapshot(const string text, CCPSnapshot &snap) { snap.Reset(); return false; }
int    CP_AcceptSnapshot(const string text, CCPSlaveState &st) { return CP_ACCEPT_INVALID; }
string CP_MapSymbol(const string masterSymbol, const string symbolMap, const string masterSuffix, const string slaveSuffix) { return masterSymbol; }
double CP_ClampLots(const double raw, const double volMin, const double volMax, const double volStep) { return raw; }
double CP_LimitPrice(const double masterPrice, const int side, const int ticks, const double tickSize) { return masterPrice; }
int    CP_SlaveCycle(CCPSlaveState &st, CPMapEntry &map[], const CPSlaveItem &items[], const CPSymbolSpec &specs[],
                     const CPConfig &cfg, const long now, CPAction &acts[])
  {
   ArrayResize(acts, 0);
   return CP_CYCLE_OK;
  }
#endif
