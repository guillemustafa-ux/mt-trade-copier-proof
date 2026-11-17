//+------------------------------------------------------------------+
//| LiveAgentCommon.mqh                                              |
//| Shared part of LiveAgentMT5 / LiveAgentMT4, the helper scripts   |
//| of the demo run (tools/live-run.ps1). Not part of the copier.    |
//| Files in Terminal\Common\Files\CopierProof\live\<name>.*:        |
//|   .in       commands written by the driver: id|VERB|arg|...|END  |
//|   .out      one result line per command: id|OK or ERR|VERB|...   |
//|   .events   every change of this account's positions and orders |
//|   .state    the current positions and orders                     |
//|   .status   connection, demo flag, quotes (every 500 ms)         |
//|   .history  deal and order history, written by EXPORT            |
//| No account number is written to any of these files.             |
//+------------------------------------------------------------------+
#ifndef LIVE_AGENT_COMMON_MQH
#define LIVE_AGENT_COMMON_MQH

#include <CopierProof/CopierFiles.mqh>

#define LA_DIR    "CopierProof\\live"
#define LA_MAGIC  7770001          // positions the driver opens on the master account

struct LAItem
  {
   long              ticket;
   int               kind;         // 0 position, 1 pending order
   string            type;         // buy, sell, buy limit, sell limit, ...
   string            symbol;
   double            lots;
   double            price;
   long              magic;
   string            comment;
  };

string LA_Path(const string name, const string ext) { return LA_DIR + "\\" + name + "." + ext; }

string LA_Now(void)
  {
   return TimeToString(TimeLocal(), TIME_DATE | TIME_SECONDS) + ";" + IntegerToString((long)GetTickCount());
  }

void LA_Log(const string msg) { Print("[LiveAgent] ", msg); }

void LA_Append(const string path, const string line)
  {
   int h = FileOpen(path, FILE_READ | FILE_WRITE | FILE_BIN | FILE_ANSI | FILE_COMMON | FILE_SHARE_READ);
   if(h == INVALID_HANDLE)
     {
      LA_Log("cannot append to " + path + " (error " + IntegerToString(GetLastError()) + ")");
      return;
     }
   FileSeek(h, 0, SEEK_END);
   FileWriteString(h, line + "\r\n");
   FileClose(h);
  }

string LA_ItemText(const LAItem &it, const int digits)
  {
   return (it.kind == 0 ? "position" : "order") + ";" + IntegerToString(it.ticket) + ";" + it.type + ";" + it.symbol +
          ";" + DoubleToString(it.lots, 2) + ";" + DoubleToString(it.price, digits) + ";" +
          IntegerToString(it.magic) + ";" + it.comment;
  }

int LA_Find(const LAItem &items[], const long ticket, const int kind)
  {
   for(int i = 0; i < ArraySize(items); i++)
      if(items[i].ticket == ticket && items[i].kind == kind)
         return i;
   return -1;
  }

//--- writes ADD / GONE / CHANGE events; returns true if anything changed
bool LA_Diff(const string name, const LAItem &prev[], const LAItem &cur[], const int digits)
  {
   bool changed = false;
   string path = LA_Path(name, "events");
   for(int i = 0; i < ArraySize(cur); i++)
     {
      int p = LA_Find(prev, cur[i].ticket, cur[i].kind);
      string ev = "";
      if(p < 0)
         ev = "ADD";
      else if(prev[p].type != cur[i].type || MathAbs(prev[p].lots - cur[i].lots) > 1e-9 ||
              MathAbs(prev[p].price - cur[i].price) > 1e-9)
         ev = "CHANGE";
      if(ev == "")
         continue;
      changed = true;
      LA_Append(path, LA_Now() + ";" + ev + ";" + LA_ItemText(cur[i], digits));
      LA_Log(ev + " " + LA_ItemText(cur[i], digits));
     }
   for(int i = 0; i < ArraySize(prev); i++)
     {
      if(LA_Find(cur, prev[i].ticket, prev[i].kind) >= 0)
         continue;
      changed = true;
      LA_Append(path, LA_Now() + ";GONE;" + LA_ItemText(prev[i], digits));
      LA_Log("GONE " + LA_ItemText(prev[i], digits));
     }
   return changed;
  }

void LA_WriteState(const string name, const LAItem &items[], const int digits)
  {
   string text = "";
   for(int i = 0; i < ArraySize(items); i++)
      text += LA_ItemText(items[i], digits) + "\r\n";
   CP_WriteTextAtomic(LA_Path(name, "state"), text);
  }

void LA_CopyItems(const LAItem &src[], LAItem &dst[])
  {
   ArrayResize(dst, ArraySize(src));
   for(int i = 0; i < ArraySize(src); i++)
      dst[i] = src[i];
  }

//--- largest command id already in the file: commands written before this start are never run
long LA_MaxId(const string name)
  {
   string text;
   long maxId = 0;
   if(!CP_ReadText(LA_Path(name, "in"), text))
      return 0;
   string lines[];
   int n = StringSplit(text, '\n', lines);
   for(int i = 0; i < n; i++)
     {
      string f[];
      if(StringSplit(lines[i], '|', f) >= 2 && StringToInteger(f[0]) > maxId)
         maxId = StringToInteger(f[0]);
     }
   return maxId;
  }

//--- next command after lastId: fills id, verb and args; false if none.
//--- a command line is id|VERB|arg...|END; a line without END is not complete yet
bool LA_NextCommand(const string name, const long lastId, long &id, string &verb, string &args[])
  {
   string text;
   if(!CP_ReadText(LA_Path(name, "in"), text))
      return false;
   string lines[];
   int n = StringSplit(text, '\n', lines);
   for(int i = 0; i < n; i++)
     {
      string line = lines[i];
      StringReplace(line, "\r", "");
      string f[];
      int k = StringSplit(line, '|', f);
      if(k < 3 || StringToInteger(f[0]) <= lastId)
         continue;
      if(f[k - 1] != "END")
         return false;
      id   = StringToInteger(f[0]);
      verb = f[1];
      ArrayResize(args, k - 3);
      for(int j = 2; j < k - 1; j++)
         args[j - 2] = f[j];
      return true;
     }
   return false;
  }

string LA_Arg(const string &args[], const int i) { return i < ArraySize(args) ? args[i] : ""; }

#endif
