//+------------------------------------------------------------------+
//| CopierMaster.mqh                                                 |
//| Publishes the master's open positions as a sealed snapshot.      |
//| Shared by MasterMT4 and MasterMT5; they only list positions.     |
//+------------------------------------------------------------------+
#ifndef COPIER_PROOF_MASTER_MQH
#define COPIER_PROOF_MASTER_MQH

#include "CopierCore.mqh"
#include "CopierFiles.mqh"

class CCopierMaster
  {
private:
   string            m_path;
   long              m_session;
   long              m_seq;
   long              m_lastWrite;
   string            m_lastBody;
   int               m_heartbeat;
   long              m_lastErrorLog;

public:
                     CCopierMaster(void) : m_session(0), m_seq(0), m_lastWrite(0), m_heartbeat(1), m_lastErrorLog(0) {}

   //--- continue the session of an existing snapshot so slaves keep accepting it
   bool              Init(const string channel, const int heartbeatSeconds, const long now)
     {
      if(!CP_EnsureFolder())
         return false;
      m_path      = CP_SnapshotPath(channel);
      m_heartbeat = MathMax(1, heartbeatSeconds);
      string text;
      CCPSnapshot prev;
      if(CP_ReadText(m_path, text) && CP_ParseSnapshot(text, prev))
        {
         m_session = prev.session;
         m_seq     = prev.seq;
        }
      else
        {
         m_session = now;
         m_seq     = 0;
        }
      m_lastBody  = "";
      m_lastWrite = 0;
      CP_Log("master publishing to Common\\Files\\" + m_path + " (session " + IntegerToString(m_session) +
             ", seq " + IntegerToString(m_seq) + ")");
      return true;
     }

   //--- writes when the positions changed or the heartbeat is due
   bool              Publish(CPMasterPos &pos[], const long now)
     {
      CP_SortPositions(pos);
      string body = CP_PositionsBody(pos);
      if(body == m_lastBody && now - m_lastWrite < m_heartbeat)
         return true;
      m_seq++;
      if(!CP_WriteTextAtomic(m_path, CP_BuildSnapshotText(m_session, m_seq, now, pos)))
        {
         if(now - m_lastErrorLog >= 10)
           {
            CP_Log("snapshot write failed (error " + IntegerToString(GetLastError()) + "), retrying");
            m_lastErrorLog = now;
           }
         return false;
        }
      if(body != m_lastBody)
         CP_Log("snapshot seq " + IntegerToString(m_seq) + ": " + IntegerToString(ArraySize(pos)) + " position(s)");
      m_lastBody  = body;
      m_lastWrite = now;
      return true;
     }
  };

#endif
