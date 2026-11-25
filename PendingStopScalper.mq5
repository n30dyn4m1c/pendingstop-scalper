//+------------------------------------------------------------------+
//| PendingStopScalper.mq5                                           |
//| Places a Buy Stop above and a Sell Stop below price with fixed   |
//| lots and SL/TP, cancels stale pendings, caps total exposure.     |
//|                                                                  |
//| Educational example. Not a proven strategy. Demo/backtest first. |
//+------------------------------------------------------------------+
#property copyright "Educational example"
#property version   "1.10"
#property description "Pending stop breakout scalper: Buy Stop / Sell Stop around price with fixed SL/TP."

#include <Trade\Trade.mqh>

CTrade trade;

//--- inputs
input group "=== Main Settings ==="
input double   InpLotSize           = 0.1;      // Lot size
input int      InpDistancePoints    = 80;       // Distance of pending stops from price (points)
input int      InpSL_Points         = 150;      // Stop Loss (points, from entry)
input int      InpTP_Points         = 250;      // Take Profit (points, from entry; 0 = none)
input long     InpMagic             = 20251125; // Magic number
input int      InpMaxOpenPositions  = 2;        // Max exposure: open positions + pending orders
input int      InpPendingTimeoutMin = 15;       // Delete unfilled pending after X minutes (0 = never)
input bool     InpOnNewBarOnly      = true;     // Place new pendings at most once per bar
input bool     InpTradeLong         = true;     // Allow Buy Stops
input bool     InpTradeShort        = true;     // Allow Sell Stops

input group "=== Filters ==="
input int      InpMaxSpreadPoints   = 50;       // Max allowed spread (points, 0 = off)
input string   InpStartHour         = "01:00";  // Trading start (server time, HH:MM)
input string   InpEndHour           = "23:00";  // Trading end (server time, HH:MM)
input bool     InpDeleteOutsideHours= true;     // Delete our pendings outside trading hours

//--- globals
datetime g_lastPlacedBar = 0;
int      g_startMin      = 0;
int      g_endMin        = 0;

//+------------------------------------------------------------------+
int OnInit()
{
   if(InpLotSize <= 0 || InpDistancePoints <= 0 || InpSL_Points <= 0 || InpTP_Points < 0)
   {
      Print("Invalid inputs: lot, distance and SL must be > 0, TP must be >= 0");
      return(INIT_PARAMETERS_INCORRECT);
   }
   if(!ParseHHMM(InpStartHour, g_startMin) || !ParseHHMM(InpEndHour, g_endMin))
   {
      Print("Invalid trading hours, expected HH:MM (got '", InpStartHour, "' / '", InpEndHour, "')");
      return(INIT_PARAMETERS_INCORRECT);
   }

   trade.SetExpertMagicNumber((ulong)InpMagic);
   trade.SetDeviationInPoints(30);
   trade.SetTypeFillingBySymbol(_Symbol);

   if(AccountInfoInteger(ACCOUNT_MARGIN_MODE) != ACCOUNT_MARGIN_MODE_RETAIL_HEDGING)
      Print("Warning: account is not hedging. A filled Buy Stop and Sell Stop will net against each other.");

   PrintFormat("%s: point=%g digits=%d stopsLevel=%d freezeLevel=%d",
               _Symbol, _Point, _Digits,
               (int)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL),
               (int)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_FREEZE_LEVEL));
   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
void OnDeinit(const int reason) {}

//+------------------------------------------------------------------+
void OnTick()
{
   // Housekeeping runs every tick so timeouts are honoured precisely.
   DeleteExpiredPendings();

   if(!IsTradingTime())
   {
      if(InpDeleteOutsideHours)
         DeleteAllPendings();
      return;
   }

   if(InpMaxSpreadPoints > 0 && SymbolInfoInteger(_Symbol, SYMBOL_SPREAD) > InpMaxSpreadPoints)
      return;

   // Only "consume" the bar once filters pass, so a wide spread at the
   // bar open does not cost us the whole bar.
   datetime barTime = iTime(_Symbol, PERIOD_CURRENT, 0);
   if(InpOnNewBarOnly && barTime == g_lastPlacedBar)
      return;

   bool needBuy  = InpTradeLong  && !HasPending(ORDER_TYPE_BUY_STOP);
   bool needSell = InpTradeShort && !HasPending(ORDER_TYPE_SELL_STOP);
   if(!needBuy && !needSell)
      return;

   MqlTick tick;
   if(!SymbolInfoTick(_Symbol, tick) || tick.ask <= 0 || tick.bid <= 0)
      return;

   // Respect broker minimum distances (stops level) for entry, SL and TP.
   int minDist  = (int)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL) + 1;
   int distPts  = MathMax(InpDistancePoints, minDist);
   int slPts    = MathMax(InpSL_Points, minDist);
   int tpPts    = (InpTP_Points > 0) ? MathMax(InpTP_Points, minDist) : 0;
   double lots  = NormalizeLots(InpLotSize);
   if(lots <= 0)
      return;

   if(needBuy && Exposure() < InpMaxOpenPositions)
   {
      double price = NormalizePrice(tick.ask + distPts * _Point);
      double sl    = NormalizePrice(price - slPts * _Point);
      double tp    = (tpPts > 0) ? NormalizePrice(price + tpPts * _Point) : 0.0;

      if(trade.BuyStop(lots, price, _Symbol, sl, tp, ORDER_TIME_GTC, 0, "PSS BuyStop"))
         PrintFormat("Buy Stop placed: %.*f SL %.*f TP %.*f", _Digits, price, _Digits, sl, _Digits, tp);
      else
         PrintFormat("Buy Stop failed: %u %s", trade.ResultRetcode(), trade.ResultRetcodeDescription());
   }

   if(needSell && Exposure() < InpMaxOpenPositions)
   {
      double price = NormalizePrice(tick.bid - distPts * _Point);
      double sl    = NormalizePrice(price + slPts * _Point);
      double tp    = (tpPts > 0) ? NormalizePrice(price - tpPts * _Point) : 0.0;

      if(trade.SellStop(lots, price, _Symbol, sl, tp, ORDER_TIME_GTC, 0, "PSS SellStop"))
         PrintFormat("Sell Stop placed: %.*f SL %.*f TP %.*f", _Digits, price, _Digits, sl, _Digits, tp);
      else
         PrintFormat("Sell Stop failed: %u %s", trade.ResultRetcode(), trade.ResultRetcodeDescription());
   }

   g_lastPlacedBar = barTime;
}

//+------------------------------------------------------------------+
//| "HH:MM" -> minutes since midnight                                |
//+------------------------------------------------------------------+
bool ParseHHMM(const string s, int &minutes)
{
   string parts[];
   if(StringSplit(s, ':', parts) != 2)
      return false;
   int h = (int)StringToInteger(parts[0]);
   int m = (int)StringToInteger(parts[1]);
   if(h < 0 || h > 23 || m < 0 || m > 59)
      return false;
   minutes = h * 60 + m;
   return true;
}

//+------------------------------------------------------------------+
//| Supports overnight windows (e.g. 22:00 -> 06:00).                |
//+------------------------------------------------------------------+
bool IsTradingTime()
{
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   int now = dt.hour * 60 + dt.min;
   if(g_startMin <= g_endMin)
      return (now >= g_startMin && now <= g_endMin);
   return (now >= g_startMin || now <= g_endMin);
}

//+------------------------------------------------------------------+
double NormalizePrice(const double price)
{
   double tickSize = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   if(tickSize > 0)
      return NormalizeDouble(MathRound(price / tickSize) * tickSize, _Digits);
   return NormalizeDouble(price, _Digits);
}

//+------------------------------------------------------------------+
double NormalizeLots(const double lots)
{
   double minLot  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxLot  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double step    = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   double v = lots;
   if(step > 0)
      v = MathFloor(v / step + 1e-9) * step;
   if(v < minLot)
   {
      PrintFormat("Lot %.2f below symbol minimum %.2f", lots, minLot);
      return 0;
   }
   if(maxLot > 0 && v > maxLot)
      v = maxLot;
   return NormalizeDouble(v, 8);
}

//+------------------------------------------------------------------+
bool IsOurOrderSelected()
{
   return OrderGetInteger(ORDER_MAGIC) == InpMagic &&
          OrderGetString(ORDER_SYMBOL) == _Symbol;
}

//+------------------------------------------------------------------+
int CountOpenPositions()
{
   int count = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0)
         continue;
      if(PositionGetInteger(POSITION_MAGIC) == InpMagic &&
         PositionGetString(POSITION_SYMBOL) == _Symbol)
         count++;
   }
   return count;
}

//+------------------------------------------------------------------+
int CountPendings()
{
   int count = 0;
   for(int i = OrdersTotal() - 1; i >= 0; i--)
   {
      ulong ticket = OrderGetTicket(i);
      if(ticket == 0)
         continue;
      if(IsOurOrderSelected())
         count++;
   }
   return count;
}

//+------------------------------------------------------------------+
//| Positions plus pendings that could still become positions.       |
//+------------------------------------------------------------------+
int Exposure()
{
   return CountOpenPositions() + CountPendings();
}

//+------------------------------------------------------------------+
bool HasPending(const ENUM_ORDER_TYPE type)
{
   for(int i = OrdersTotal() - 1; i >= 0; i--)
   {
      ulong ticket = OrderGetTicket(i);
      if(ticket == 0)
         continue;
      if(IsOurOrderSelected() && (ENUM_ORDER_TYPE)OrderGetInteger(ORDER_TYPE) == type)
         return true;
   }
   return false;
}

//+------------------------------------------------------------------+
void DeleteExpiredPendings()
{
   if(InpPendingTimeoutMin <= 0)
      return;

   datetime now = TimeCurrent();
   for(int i = OrdersTotal() - 1; i >= 0; i--)
   {
      ulong ticket = OrderGetTicket(i);
      if(ticket == 0 || !IsOurOrderSelected())
         continue;

      datetime setupTime = (datetime)OrderGetInteger(ORDER_TIME_SETUP);
      if((now - setupTime) > InpPendingTimeoutMin * 60)
      {
         if(trade.OrderDelete(ticket))
            PrintFormat("Deleted stale pending #%I64u", ticket);
         else
            PrintFormat("Failed to delete #%I64u: %u %s", ticket, trade.ResultRetcode(), trade.ResultRetcodeDescription());
      }
   }
}

//+------------------------------------------------------------------+
void DeleteAllPendings()
{
   for(int i = OrdersTotal() - 1; i >= 0; i--)
   {
      ulong ticket = OrderGetTicket(i);
      if(ticket == 0 || !IsOurOrderSelected())
         continue;
      if(trade.OrderDelete(ticket))
         PrintFormat("Deleted pending #%I64u (outside trading hours)", ticket);
   }
}
//+------------------------------------------------------------------+
