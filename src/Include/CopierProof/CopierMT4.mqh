//+------------------------------------------------------------------+
//| CopierMT4.mqh (MQL4 only)                                        |
//| Lists open MT4 orders with a stable identity. MT4 gives the      |
//| remainder of a partial close a new ticket and the comment        |
//| "from #<old>"; the alias table (saved in Common\Files) maps every |
//| new ticket back to the first one. Used by MasterMT4 and SlaveMT4.|
//+------------------------------------------------------------------+
#ifndef COPIER_PROOF_MT4_MQH
#define COPIER_PROOF_MT4_MQH

#include "CopierCore.mqh"
#include "CopierFiles.mqh"

struct CPMT4Order
  {
   long              ticket;
   long              identity;
   int               type;          // OP_BUY, OP_SELL, OP_BUYLIMIT, ...
   string            symbol;
   double            lots;
   double            openPrice;
   long              openTimeMsc;
   long              magic;
   string            comment;
  };

class CCPMT4Orders
  {
private:
   CCPAliasTable     m_aliases;
   string            m_path;
   string            m_saved;

public:
   bool              Init(const string path, string &error)
     {
      m_path = path;
      if(!CP_EnsureFolder())
        {
         error = "cannot create Common\\Files\\" + CP_FOLDER;
         return false;
        }
      string text;
      if(CP_ReadText(m_path, text) && !CP_AliasFromText(text, m_aliases))
        {
         error = "ticket alias file Common\\Files\\" + m_path + " is damaged; fix or remove it before starting";
         return false;
        }
      m_saved = CP_AliasToText(m_aliases);
      return true;
     }

   int               Scan(CPMT4Order &out[])
     {
      int total = OrdersTotal();
      ArrayResize(out, 0);
      int n = 0;
      for(int i = 0; i < total; i++)
        {
         if(!OrderSelect(i, SELECT_BY_POS, MODE_TRADES))
            continue;
         ArrayResize(out, n + 1);
         out[n].ticket      = OrderTicket();
         out[n].type        = OrderType();
         out[n].symbol      = OrderSymbol();
         out[n].lots        = OrderLots();
         out[n].openPrice   = OrderOpenPrice();
         out[n].openTimeMsc = (long)OrderOpenTime() * 1000;
         out[n].magic       = OrderMagicNumber();
         out[n].comment     = OrderComment();
         n++;
        }
      long tickets[];
      string comments[];
      long ids[];
      ArrayResize(tickets, n);
      ArrayResize(comments, n);
      for(int i = 0; i < n; i++)
        {
         tickets[i]  = out[i].ticket;
         comments[i] = out[i].comment;
        }
      CP_AliasResolveAll(m_aliases, tickets, comments, ids);
      for(int i = 0; i < n; i++)
         out[i].identity = ids[i];
      string now = CP_AliasToText(m_aliases);
      if(now != m_saved && CP_WriteTextAtomic(m_path, now))
         m_saved = now;
      return n;
     }
  };

#endif
