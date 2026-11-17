//+------------------------------------------------------------------+
//| CopierCoreTests.mq4                                              |
//| Runs the shared copier tests in MetaTrader 4. Places no orders.  |
//+------------------------------------------------------------------+
#property copyright "MIT License"
#property version   "1.00"
#property strict

#include "CopierTests.mqh"

void OnStart()
  {
   RunAllCopierTests();
  }
