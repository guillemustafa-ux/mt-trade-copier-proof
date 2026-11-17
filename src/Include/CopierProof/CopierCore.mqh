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

#define CP_FREEZE_NONE         0
#define CP_FREEZE_ENTER        1   // the slave has just frozen: master snapshot too old
#define CP_FREEZE_RESUME       2   // the slave has just resumed: a fresh snapshot arrived

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
   double            minDistance;  // broker's minimum distance of a pending order from the market, in price
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
   long              lastSeen;          // GMT seconds
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

//+------------------------------------------------------------------+
//| Small string helpers (StringTrim* differs between MQL4 and MQL5) |
//+------------------------------------------------------------------+
bool CP_IsSpace(const ushort c) { return c == ' ' || c == '\t' || c == '\r' || c == '\n'; }

string CP_Trim(const string s)
  {
   int n = StringLen(s);
   int a = 0;
   while(a < n && CP_IsSpace(StringGetCharacter(s, a)))
      a++;
   int b = n - 1;
   while(b >= a && CP_IsSpace(StringGetCharacter(s, b)))
      b--;
   if(b < a)
      return "";
   return StringSubstr(s, a, b - a + 1);
  }

bool CP_StartsWith(const string s, const string prefix)
  {
   return StringLen(s) >= StringLen(prefix) && StringSubstr(s, 0, StringLen(prefix)) == prefix;
  }

bool CP_EndsWith(const string s, const string suffix)
  {
   int n = StringLen(s), m = StringLen(suffix);
   return m <= n && StringSubstr(s, n - m, m) == suffix;
  }

//--- non-empty lines of a text
int CP_SplitLines(const string text, string &lines[])
  {
   string raw[];
   int n = StringSplit(text, '\n', raw);
   ArrayResize(lines, 0);
   int k = 0;
   for(int i = 0; i < n; i++)
     {
      if(StringLen(raw[i]) == 0)
         continue;
      ArrayResize(lines, k + 1);
      lines[k++] = raw[i];
     }
   return k;
  }

//+------------------------------------------------------------------+
//| Sealed text: body + "END|<checksum>\n" (FNV-1a 32 of the body)   |
//| A half-written or edited file fails the seal and is ignored.     |
//+------------------------------------------------------------------+
uint CP_Checksum(const string text)
  {
   uint h = (uint)2166136261;
   int n = StringLen(text);
   for(int i = 0; i < n; i++)
     {
      h ^= (uint)StringGetCharacter(text, i);
      h *= (uint)16777619;
     }
   return h;
  }

string CP_Seal(const string body)
  {
   return body + "END|" + IntegerToString((long)CP_Checksum(body)) + "\n";
  }

bool CP_Unseal(const string text, string &body)
  {
   body = "";
   int p = StringFind(text, "\nEND|");
   if(p < 0)
      return false;
   string tail = StringSubstr(text, p + 5);
   if(StringLen(tail) < 2 || !CP_EndsWith(tail, "\n"))
      return false;
   tail = StringSubstr(tail, 0, StringLen(tail) - 1);
   if(StringLen(tail) == 0 || StringFind(tail, "\n") >= 0)
      return false;
   string candidate = StringSubstr(text, 0, p + 1);
   if(IntegerToString((long)CP_Checksum(candidate)) != tail)
      return false;
   body = candidate;
   return true;
  }

//+------------------------------------------------------------------+
//| Snapshot format (written by both masters, read by both slaves)   |
//|   CPSNAP|1|<session>|<seq>|<writeTimeGmt>|<count>                |
//|   P|<ticket>|<symbol>|<side>|<lots>|<price>|<openTimeMsc>        |
//|   END|<checksum>                                                 |
//+------------------------------------------------------------------+
void CP_SortPositions(CPMasterPos &pos[])
  {
   int n = ArraySize(pos);
   for(int i = 1; i < n; i++)
     {
      CPMasterPos key = pos[i];
      int j = i - 1;
      while(j >= 0 && (pos[j].openTimeMsc > key.openTimeMsc ||
                       (pos[j].openTimeMsc == key.openTimeMsc && pos[j].ticket > key.ticket)))
        {
         pos[j + 1] = pos[j];
         j--;
        }
      pos[j + 1] = key;
     }
  }

string CP_PositionsBody(const CPMasterPos &pos[])
  {
   string s = "";
   for(int i = 0; i < ArraySize(pos); i++)
      s += "P|" + IntegerToString(pos[i].ticket) + "|" + pos[i].symbol + "|" + IntegerToString(pos[i].side) +
           "|" + DoubleToString(pos[i].lots, 8) + "|" + DoubleToString(pos[i].price, 8) +
           "|" + IntegerToString(pos[i].openTimeMsc) + "\n";
   return s;
  }

string CP_BuildSnapshotText(const long session, const long seq, const long writeTime, const CPMasterPos &pos[])
  {
   string body = "CPSNAP|1|" + IntegerToString(session) + "|" + IntegerToString(seq) + "|" +
                 IntegerToString(writeTime) + "|" + IntegerToString(ArraySize(pos)) + "\n" + CP_PositionsBody(pos);
   return CP_Seal(body);
  }

bool CP_ParseSnapshot(const string text, CCPSnapshot &snap)
  {
   snap.Reset();
   string body;
   if(!CP_Unseal(text, body))
      return false;
   string lines[];
   int n = CP_SplitLines(body, lines);
   if(n < 1)
      return false;
   string h[];
   if(StringSplit(lines[0], '|', h) != 6 || h[0] != "CPSNAP" || h[1] != "1")
      return false;
   int count = (int)StringToInteger(h[5]);
   if(count != n - 1)
      return false;
   ArrayResize(snap.pos, count);
   for(int i = 0; i < count; i++)
     {
      string f[];
      if(StringSplit(lines[i + 1], '|', f) != 7 || f[0] != "P")
        {
         snap.Reset();
         return false;
        }
      snap.pos[i].ticket      = StringToInteger(f[1]);
      snap.pos[i].symbol      = f[2];
      snap.pos[i].side        = (int)StringToInteger(f[3]);
      snap.pos[i].lots        = StringToDouble(f[4]);
      snap.pos[i].price       = StringToDouble(f[5]);
      snap.pos[i].openTimeMsc = StringToInteger(f[6]);
     }
   snap.session   = StringToInteger(h[2]);
   snap.seq       = StringToInteger(h[3]);
   snap.writeTime = StringToInteger(h[4]);
   return true;
  }

void CP_CopySnapshot(const CCPSnapshot &src, CCPSnapshot &dst)
  {
   dst.session   = src.session;
   dst.seq       = src.seq;
   dst.writeTime = src.writeTime;
   int n = ArraySize(src.pos);
   ArrayResize(dst.pos, n);
   for(int i = 0; i < n; i++)
      dst.pos[i] = src.pos[i];
  }

//--- a snapshot is applied only if it is later than the last one applied
bool CP_IsNewer(const long session, const long seq, const long lastSession, const long lastSeq)
  {
   return session > lastSession || (session == lastSession && seq > lastSeq);
  }

//--- the master writes a heartbeat; an old snapshot means the master is not running
bool CP_IsFresh(const long writeTime, const long now, const int staleSeconds)
  {
   long age = now - writeTime;
   if(age < 0)
      age = -age;
   return age <= staleSeconds;
  }

int CP_AcceptSnapshot(const string text, CCPSlaveState &st)
  {
   CCPSnapshot parsed;
   if(!CP_ParseSnapshot(text, parsed))
      return CP_ACCEPT_INVALID;
   if(st.has && !CP_IsNewer(parsed.session, parsed.seq, st.lastSession, st.lastSeq))
      return CP_ACCEPT_NOT_NEWER;
   CP_CopySnapshot(parsed, st.current);
   st.has         = true;
   st.lastSession = parsed.session;
   st.lastSeq     = parsed.seq;
   return CP_ACCEPT_NEW;
  }

//+------------------------------------------------------------------+
//| Comments and identities                                          |
//+------------------------------------------------------------------+
string CP_CopyComment(const long masterTicket) { return "CP:" + IntegerToString(masterTicket); }

long CP_ParseCopyComment(const string comment)
  {
   if(!CP_StartsWith(comment, "CP:"))
      return 0;
   string digits = StringSubstr(comment, 3);
   if(StringLen(digits) == 0)
      return 0;
   for(int i = 0; i < StringLen(digits); i++)
     {
      ushort c = StringGetCharacter(digits, i);
      if(c < '0' || c > '9')
         return 0;
     }
   return StringToInteger(digits);
  }

//--- MT4 writes "from #<old ticket>" on the remainder of a partial close
long CP_ParseFromTicket(const string comment)
  {
   if(!CP_StartsWith(comment, "from #"))
      return 0;
   string digits = StringSubstr(comment, 6);
   int n = StringLen(digits);
   if(n == 0)
      return 0;
   for(int i = 0; i < n; i++)
     {
      ushort c = StringGetCharacter(digits, i);
      if(c < '0' || c > '9')
         return 0;
     }
   return StringToInteger(digits);
  }

int CP_AliasFind(const CCPAliasTable &t, const long ticket)
  {
   for(int i = 0; i < ArraySize(t.tickets); i++)
      if(t.tickets[i] == ticket)
         return i;
   return -1;
  }

//--- resolve the identity of every open ticket, then keep only the open tickets
//--- (resolve first: the ticket a remainder points to has just been closed)
void CP_AliasResolveAll(CCPAliasTable &t, const long &openTickets[], const string &comments[], long &ids[])
  {
   int n = ArraySize(openTickets);
   ArrayResize(ids, n);
   for(int i = 0; i < n; i++)
     {
      int k = CP_AliasFind(t, openTickets[i]);
      if(k >= 0)
        {
         ids[i] = t.ids[k];
         continue;
        }
      long from = CP_ParseFromTicket(comments[i]);
      if(from > 0)
        {
         int j = CP_AliasFind(t, from);
         ids[i] = (j >= 0) ? t.ids[j] : from;
        }
      else
         ids[i] = openTickets[i];
     }
   ArrayResize(t.tickets, n);
   ArrayResize(t.ids, n);
   for(int i = 0; i < n; i++)
     {
      t.tickets[i] = openTickets[i];
      t.ids[i]     = ids[i];
     }
  }

string CP_AliasToText(const CCPAliasTable &t)
  {
   int n = ArraySize(t.tickets);
   string body = "CPALIAS|1|" + IntegerToString(n) + "\n";
   for(int i = 0; i < n; i++)
      body += "A|" + IntegerToString(t.tickets[i]) + "|" + IntegerToString(t.ids[i]) + "\n";
   return CP_Seal(body);
  }

bool CP_AliasFromText(const string text, CCPAliasTable &t)
  {
   ArrayResize(t.tickets, 0);
   ArrayResize(t.ids, 0);
   string body;
   if(!CP_Unseal(text, body))
      return false;
   string lines[];
   int n = CP_SplitLines(body, lines);
   string h[];
   if(n < 1 || StringSplit(lines[0], '|', h) != 3 || h[0] != "CPALIAS" || h[1] != "1")
      return false;
   int count = (int)StringToInteger(h[2]);
   if(count != n - 1)
      return false;
   ArrayResize(t.tickets, count);
   ArrayResize(t.ids, count);
   for(int i = 0; i < count; i++)
     {
      string f[];
      if(StringSplit(lines[i + 1], '|', f) != 3 || f[0] != "A")
        {
         ArrayResize(t.tickets, 0);
         ArrayResize(t.ids, 0);
         return false;
        }
      t.tickets[i] = StringToInteger(f[1]);
      t.ids[i]     = StringToInteger(f[2]);
     }
   return true;
  }

//+------------------------------------------------------------------+
//| Symbol mapping: explicit pairs first, then suffix rule           |
//|   map "EURUSD=EURUSD.m;XAUUSD=GOLD" (';' or ',' separated)       |
//|   suffix rule: strip masterSuffix, append slaveSuffix            |
//+------------------------------------------------------------------+
string CP_MapSymbol(const string masterSymbol, const string symbolMap, const string masterSuffix, const string slaveSuffix)
  {
   string spec = symbolMap;
   StringReplace(spec, ",", ";");
   string pairs[];
   int n = StringSplit(spec, ';', pairs);
   for(int i = 0; i < n; i++)
     {
      int eq = StringFind(pairs[i], "=");
      if(eq < 0)
         continue;
      string left  = CP_Trim(StringSubstr(pairs[i], 0, eq));
      string right = CP_Trim(StringSubstr(pairs[i], eq + 1));
      if(left == masterSymbol && StringLen(right) > 0)
         return right;
     }
   string base = masterSymbol;
   string ms = CP_Trim(masterSuffix);
   if(StringLen(ms) > 0 && CP_EndsWith(base, ms) && StringLen(base) > StringLen(ms))
      base = StringSubstr(base, 0, StringLen(base) - StringLen(ms));
   return base + CP_Trim(slaveSuffix);
  }

//+------------------------------------------------------------------+
//| Lots and prices                                                  |
//+------------------------------------------------------------------+
double CP_FloorToStep(const double value, const double step)
  {
   if(step <= 0)
      return value;
   double v = MathFloor(value / step + 1e-7) * step;
   if(v < 0)
      v = 0;
   return NormalizeDouble(v, 8);
  }

//--- decimals of a lot step (0.01 -> 2, 0.1 -> 1, 1 -> 0), for normalizing order volumes
int CP_StepDigits(const double step)
  {
   int d = 0;
   double v = step;
   while(d < 8 && MathAbs(v - MathRound(v)) > 1e-7)
     {
      v *= 10;
      d++;
     }
   return d;
  }

//--- master lots x multiplier, rounded down to the step, clamped to [min, max]
double CP_ClampLots(const double raw, const double volMin, const double volMax, const double volStep)
  {
   double v = CP_FloorToStep(raw, volStep);
   if(v < volMin)
      v = volMin;
   if(volMax > 0 && v > volMax)
      v = CP_FloorToStep(volMax, volStep);
   return NormalizeDouble(v, 8);
  }

//--- X ticks better than the master entry, snapped to the slave tick grid in the
//--- direction that keeps it at least X ticks better (down for buys, up for sells)
double CP_LimitPrice(const double masterPrice, const int side, const int ticks, const double tickSize)
  {
   if(tickSize <= 0)
      return 0;
   if(side == CP_SIDE_BUY)
      return NormalizeDouble(MathFloor((masterPrice - ticks * tickSize) / tickSize + 1e-7) * tickSize, 10);
   return NormalizeDouble(MathCeil((masterPrice + ticks * tickSize) / tickSize - 1e-7) * tickSize, 10);
  }

//--- the market is already at or beyond the limit price: a limit there is invalid
bool CP_LimitIsMarketable(const int side, const double limitPrice, const double bid, const double ask)
  {
   if(side == CP_SIDE_BUY)
      return ask > 0 && ask <= limitPrice + CP_EPS;
   return bid > 0 && bid >= limitPrice - CP_EPS;
  }

//--- a limit closer to the market than the broker's minimum distance (stops level) is
//--- rejected (MT4 error 130): move it further away, which keeps it at least X ticks better
double CP_LimitOutsideMinDistance(const int side, const double limitPrice, const double bid, const double ask,
                                  const double minDistance, const double tickSize)
  {
   if(minDistance <= 0 || tickSize <= 0)
      return limitPrice;
   if(side == CP_SIDE_BUY)
     {
      double highest = ask - minDistance;
      if(limitPrice > highest + CP_EPS)
         return NormalizeDouble(MathFloor(highest / tickSize + 1e-7) * tickSize, 10);
      return limitPrice;
     }
   double lowest = bid + minDistance;
   if(limitPrice < lowest - CP_EPS)
      return NormalizeDouble(MathCeil(lowest / tickSize - 1e-7) * tickSize, 10);
   return limitPrice;
  }

//--- initial entry = no earlier master position with the same symbol and side
int CP_ClassifyRole(const CPMasterPos &pos[], const int idx)
  {
   for(int i = 0; i < ArraySize(pos); i++)
     {
      if(i == idx || pos[i].symbol != pos[idx].symbol || pos[i].side != pos[idx].side)
         continue;
      if(pos[i].openTimeMsc < pos[idx].openTimeMsc ||
         (pos[i].openTimeMsc == pos[idx].openTimeMsc && pos[i].ticket < pos[idx].ticket))
         return CP_ROLE_ADDON;
     }
   return CP_ROLE_INITIAL;
  }

//+------------------------------------------------------------------+
//| Ticket map (persisted by the slave)                              |
//|   CPMAP|1|<count>                                                |
//|   M|master|role|status|slaveTicket|symbol|side|mLots|sLots       |
//+------------------------------------------------------------------+
int CP_MapFind(const CPMapEntry &map[], const long masterTicket)
  {
   for(int i = 0; i < ArraySize(map); i++)
      if(map[i].masterTicket == masterTicket)
         return i;
   return -1;
  }

int CP_MapFindBySlave(const CPMapEntry &map[], const long slaveTicket)
  {
   for(int i = 0; i < ArraySize(map); i++)
      if(map[i].slaveTicket == slaveTicket)
         return i;
   return -1;
  }

int CP_MapAdd(CPMapEntry &map[], const long masterTicket, const int role, const int status, const long slaveTicket,
              const string slaveSymbol, const int side, const double masterLots, const double slaveLots, const long lastSeen)
  {
   int n = ArraySize(map);
   ArrayResize(map, n + 1);
   map[n].masterTicket     = masterTicket;
   map[n].role             = role;
   map[n].status           = status;
   map[n].slaveTicket      = slaveTicket;
   map[n].slaveSymbol      = slaveSymbol;
   map[n].side             = side;
   map[n].masterLotsAtCopy = masterLots;
   map[n].slaveLotsAtCopy  = slaveLots;
   map[n].lastSeen         = lastSeen;
   return n;
  }

void CP_MapRemoveAt(CPMapEntry &map[], const int idx)
  {
   int n = ArraySize(map);
   for(int i = idx; i < n - 1; i++)
      map[i] = map[i + 1];
   ArrayResize(map, n - 1);
  }

//--- lastSeen is not saved: a loaded map is marked seen at load time (CP_MapMarkSeen)
string CP_MapToText(const CPMapEntry &map[])
  {
   int n = ArraySize(map);
   string body = "CPMAP|1|" + IntegerToString(n) + "\n";
   for(int i = 0; i < n; i++)
      body += "M|" + IntegerToString(map[i].masterTicket) + "|" + IntegerToString(map[i].role) + "|" +
              IntegerToString(map[i].status) + "|" + IntegerToString(map[i].slaveTicket) + "|" + map[i].slaveSymbol +
              "|" + IntegerToString(map[i].side) + "|" + DoubleToString(map[i].masterLotsAtCopy, 8) + "|" +
              DoubleToString(map[i].slaveLotsAtCopy, 8) + "\n";
   return CP_Seal(body);
  }

//--- after a restart the terminal may not list every order yet: give it the grace period
void CP_MapMarkSeen(CPMapEntry &map[], const long now)
  {
   for(int i = 0; i < ArraySize(map); i++)
      map[i].lastSeen = now;
  }

bool CP_MapFromText(const string text, CPMapEntry &map[])
  {
   ArrayResize(map, 0);
   string body;
   if(!CP_Unseal(text, body))
      return false;
   string lines[];
   int n = CP_SplitLines(body, lines);
   string h[];
   if(n < 1 || StringSplit(lines[0], '|', h) != 3 || h[0] != "CPMAP" || h[1] != "1")
      return false;
   int count = (int)StringToInteger(h[2]);
   if(count != n - 1)
      return false;
   for(int i = 0; i < count; i++)
     {
      string f[];
      if(StringSplit(lines[i + 1], '|', f) != 9 || f[0] != "M")
        {
         ArrayResize(map, 0);
         return false;
        }
      CP_MapAdd(map, StringToInteger(f[1]), (int)StringToInteger(f[2]), (int)StringToInteger(f[3]),
                StringToInteger(f[4]), f[5], (int)StringToInteger(f[6]), StringToDouble(f[7]),
                StringToDouble(f[8]), 0);
     }
   return true;
  }

//--- record a copy that the platform adapter has just placed
void CP_MapRecordPlacement(CPMapEntry &map[], const CPAction &a, const long slaveTicket, const long now)
  {
   int status = (a.type == CP_ACT_PLACE_LIMIT) ? CP_ST_PENDING : CP_ST_OPEN;
   CP_MapAdd(map, a.masterTicket, a.role, status, slaveTicket, a.symbol, a.side, a.masterLots, a.lots, now);
  }

//+------------------------------------------------------------------+
//| Lookups over slave items and snapshot                            |
//+------------------------------------------------------------------+
int CP_FindMaster(const CCPSnapshot &snap, const long ticket)
  {
   for(int i = 0; i < ArraySize(snap.pos); i++)
      if(snap.pos[i].ticket == ticket)
         return i;
   return -1;
  }

int CP_FindSpec(const CPSymbolSpec &specs[], const string symbol)
  {
   for(int i = 0; i < ArraySize(specs); i++)
      if(specs[i].symbol == symbol)
         return i;
   return -1;
  }

bool CP_HasPending(const CPSlaveItem &items[], const long origin, const long magic)
  {
   for(int i = 0; i < ArraySize(items); i++)
      if(items[i].magic == magic && items[i].origin == origin && items[i].kind == CP_KIND_PENDING)
         return true;
   return false;
  }

double CP_PositionVolume(const CPSlaveItem &items[], const long origin, const long magic)
  {
   double v = 0;
   for(int i = 0; i < ArraySize(items); i++)
      if(items[i].magic == magic && items[i].origin == origin && items[i].kind == CP_KIND_POSITION)
         v += items[i].lots;
   return v;
  }

int CP_PushAction(CPAction &acts[], const int type, const long masterTicket, const int role, const string symbol,
                  const int side, const double lots, const double price, const long slaveTicket,
                  const double masterLots, const string reason)
  {
   int n = ArraySize(acts);
   ArrayResize(acts, n + 1);
   acts[n].type         = type;
   acts[n].masterTicket = masterTicket;
   acts[n].role         = role;
   acts[n].symbol       = symbol;
   acts[n].side         = side;
   acts[n].lots         = lots;
   acts[n].price        = price;
   acts[n].slaveTicket  = slaveTicket;
   acts[n].masterLots   = masterLots;
   acts[n].reason       = reason;
   return n;
  }

//+------------------------------------------------------------------+
//| Sync: update the map from what the slave account shows           |
//|  - recover links from "CP:<ticket>" comments (crash between the  |
//|    order and the map save)                                       |
//|  - PENDING/OPEN/DONE from the items carrying the copy's origin   |
//|  - forget DONE entries whose master ticket is gone               |
//+------------------------------------------------------------------+
void CP_SyncMap(CPMapEntry &map[], const CPSlaveItem &items[], const CCPSnapshot &snap, const CPConfig &cfg, const long now)
  {
   for(int i = 0; i < ArraySize(items); i++)
     {
      if(items[i].magic != cfg.magic)
         continue;
      long master = CP_ParseCopyComment(items[i].comment);
      if(master <= 0 || CP_MapFind(map, master) >= 0 || CP_MapFindBySlave(map, items[i].origin) >= 0)
         continue;
      int mi = CP_FindMaster(snap, master);
      int role = (mi >= 0) ? CP_ClassifyRole(snap.pos, mi) : CP_ROLE_INITIAL;
      double masterLots = (mi >= 0) ? snap.pos[mi].lots : 0;
      double slaveLots = CP_PositionVolume(items, items[i].origin, cfg.magic);
      for(int k = 0; k < ArraySize(items); k++)
         if(items[k].magic == cfg.magic && items[k].origin == items[i].origin && items[k].kind == CP_KIND_PENDING)
            slaveLots += items[k].lots;
      int status = CP_HasPending(items, items[i].origin, cfg.magic) ? CP_ST_PENDING : CP_ST_OPEN;
      CP_MapAdd(map, master, role, status, items[i].origin, items[i].symbol, items[i].side, masterLots, slaveLots, now);
     }

   for(int i = 0; i < ArraySize(map); i++)
     {
      if(map[i].status == CP_ST_DONE)
         continue;
      bool pending = CP_HasPending(items, map[i].slaveTicket, cfg.magic);
      double vol = CP_PositionVolume(items, map[i].slaveTicket, cfg.magic);
      if(pending || vol > CP_EPS)
        {
         map[i].status   = pending ? CP_ST_PENDING : CP_ST_OPEN;
         map[i].lastSeen = now;
        }
      //--- not listed for longer than the grace period (a new order or a terminal that
      //--- is still loading its trades gets that long): filled and closed, deleted or
      //--- closed by hand. The master ticket is never copied again.
      else if(now - map[i].lastSeen > cfg.graceSeconds)
         map[i].status = CP_ST_DONE;
     }

   for(int i = ArraySize(map) - 1; i >= 0; i--)
      if(map[i].status == CP_ST_DONE && CP_FindMaster(snap, map[i].masterTicket) < 0)
         CP_MapRemoveAt(map, i);
  }

//+------------------------------------------------------------------+
//| Decide: actions that bring the slave in line with the master     |
//+------------------------------------------------------------------+
int CP_Decide(const CCPSnapshot &snap, const CPMapEntry &map[], const CPSlaveItem &items[],
              const CPSymbolSpec &specs[], const CPConfig &cfg, CPAction &acts[])
  {
   ArrayResize(acts, 0);

//--- exits first: master ticket gone -> delete pendings and close positions of the copy
   for(int i = 0; i < ArraySize(map); i++)
     {
      if(map[i].status == CP_ST_DONE || CP_FindMaster(snap, map[i].masterTicket) >= 0)
         continue;
      for(int k = 0; k < ArraySize(items); k++)
        {
         if(items[k].magic != cfg.magic || items[k].origin != map[i].slaveTicket)
            continue;
         if(items[k].kind == CP_KIND_PENDING)
            CP_PushAction(acts, CP_ACT_DELETE_PENDING, map[i].masterTicket, map[i].role, items[k].symbol, items[k].side,
                          items[k].lots, 0, items[k].ticket, 0, "master closed before the limit filled");
         else
            CP_PushAction(acts, CP_ACT_CLOSE, map[i].masterTicket, map[i].role, items[k].symbol, items[k].side,
                          items[k].lots, 0, items[k].ticket, 0, "master closed");
        }
     }

//--- master positions: new copies and partial closes
   for(int m = 0; m < ArraySize(snap.pos); m++)
     {
      int side = snap.pos[m].side;
      if(side != CP_SIDE_BUY && side != CP_SIDE_SELL)
         continue;
      string symbol = CP_MapSymbol(snap.pos[m].symbol, cfg.symbolMap, cfg.masterSuffix, cfg.slaveSuffix);
      int s = CP_FindSpec(specs, symbol);
      if(s < 0 || !specs[s].valid)
         continue;
      int e = CP_MapFind(map, snap.pos[m].ticket);

      if(e < 0)
        {
         double lots = CP_ClampLots(snap.pos[m].lots * cfg.lotMultiplier, specs[s].volMin, specs[s].volMax, specs[s].volStep);
         int role = CP_ClassifyRole(snap.pos, m);
         if(role == CP_ROLE_ADDON)
           {
            CP_PushAction(acts, CP_ACT_PLACE_MARKET, snap.pos[m].ticket, role, symbol, side, lots, 0, 0,
                          snap.pos[m].lots, "add-on copied at market");
            continue;
           }
         double limit = CP_LimitPrice(snap.pos[m].price, side, cfg.ticksBetter, specs[s].tickSize);
         if(CP_LimitIsMarketable(side, limit, specs[s].bid, specs[s].ask))
           {
            CP_PushAction(acts, CP_ACT_PLACE_MARKET, snap.pos[m].ticket, role, symbol, side, lots, 0, 0,
                          snap.pos[m].lots, "limit price already reached: market");
            continue;
           }
         double placed = CP_LimitOutsideMinDistance(side, limit, specs[s].bid, specs[s].ask, specs[s].minDistance,
                                                    specs[s].tickSize);
         CP_PushAction(acts, CP_ACT_PLACE_LIMIT, snap.pos[m].ticket, role, symbol, side, lots, placed, 0,
                       snap.pos[m].lots, MathAbs(placed - limit) > CP_EPS ?
                       "initial entry as limit, moved to the broker's minimum distance" : "initial entry as limit");
         continue;
        }

      if(map[e].status == CP_ST_DONE || map[e].masterLotsAtCopy <= 0)
         continue;
      if(CP_HasPending(items, map[e].slaveTicket, cfg.magic))
         continue;   // partial close is applied once the copy is a position
      double vol = CP_PositionVolume(items, map[e].slaveTicket, cfg.magic);
      if(vol <= CP_EPS || snap.pos[m].lots >= map[e].masterLotsAtCopy - CP_EPS)
         continue;

      //--- partial close: same fraction as the master, rounded down to the slave step
      double step = specs[s].volStep;
      double closedFraction = (map[e].masterLotsAtCopy - snap.pos[m].lots) / map[e].masterLotsAtCopy;
      double desiredClosed = CP_FloorToStep(map[e].slaveLotsAtCopy * closedFraction, step);
      double alreadyClosed = map[e].slaveLotsAtCopy - vol;
      double closeNow = CP_FloorToStep(desiredClosed - alreadyClosed, step);
      if(vol - closeNow < specs[s].volMin - CP_EPS)
         closeNow = CP_FloorToStep(vol - specs[s].volMin, step);
      if(closeNow < step - CP_EPS)
         continue;
      for(int k = 0; k < ArraySize(items) && closeNow > CP_EPS; k++)
        {
         if(items[k].magic != cfg.magic || items[k].origin != map[e].slaveTicket || items[k].kind != CP_KIND_POSITION)
            continue;
         double part = MathMin(closeNow, items[k].lots);
         CP_PushAction(acts, CP_ACT_CLOSE, map[e].masterTicket, map[e].role, items[k].symbol, items[k].side,
                       part, 0, items[k].ticket, snap.pos[m].lots, "master partial close");
         closeNow = NormalizeDouble(closeNow - part, 8);
        }
     }
   return ArraySize(acts);
  }

//+------------------------------------------------------------------+
//| One slave cycle on the last accepted snapshot                    |
//+------------------------------------------------------------------+
int CP_SlaveCycle(CCPSlaveState &st, CPMapEntry &map[], const CPSlaveItem &items[], const CPSymbolSpec &specs[],
                  const CPConfig &cfg, const long now, CPAction &acts[])
  {
   ArrayResize(acts, 0);
   if(!st.has)
      return CP_CYCLE_NO_SNAPSHOT;
   if(!CP_IsFresh(st.current.writeTime, now, cfg.staleSeconds))
      return CP_CYCLE_STALE;
   CP_SyncMap(map, items, st.current, cfg, now);
   CP_Decide(st.current, map, items, specs, cfg, acts);
   return CP_CYCLE_OK;
  }

//+------------------------------------------------------------------+
//| Stale-master alert: one event when the slave freezes and one     |
//| when it resumes, never one per cycle. `frozen` is the slave's    |
//| memory of the previous cycles.                                   |
//+------------------------------------------------------------------+
int CP_FreezeEvent(bool &frozen, const int cycleResult)
  {
   if(cycleResult == CP_CYCLE_STALE && !frozen)
     {
      frozen = true;
      return CP_FREEZE_ENTER;
     }
   if(cycleResult == CP_CYCLE_OK && frozen)
     {
      frozen = false;
      return CP_FREEZE_RESUME;
     }
   return CP_FREEZE_NONE;
  }

//--- this build runs on demo accounts only: "" when allowed, otherwise the reason to stop
string CP_DemoOnlyError(const string program, const bool isDemo)
  {
   if(isDemo)
      return "";
   return program + " runs on demo accounts only and this account is not a demo account";
  }

#endif
