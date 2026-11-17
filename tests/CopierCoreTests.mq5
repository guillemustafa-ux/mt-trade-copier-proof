//+------------------------------------------------------------------+
//| CopierCoreTests.mq5                                              |
//| Runs the shared copier tests in MetaTrader 5. Places no orders.  |
//+------------------------------------------------------------------+
#property copyright "MIT License"
#property version   "1.00"
#property script_show_inputs false

#include "CopierTests.mqh"

void OnStart()
  {
   RunAllCopierTests();
  }
