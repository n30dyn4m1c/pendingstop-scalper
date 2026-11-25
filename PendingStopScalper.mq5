//+------------------------------------------------------------------+
//| PendingStopScalper.mq5                                           |
//| Keeps one Buy Stop above and one Sell Stop below price with      |
//| SL/TP, cancels stale pendings, caps exposure, and adds optional  |
//| ATR distances, risk-% sizing, breakeven/trailing and daily       |
//| risk limits.                                                     |
//|                                                                  |
//| Educational example. Not a proven strategy. Backtest and demo    |
//| trade before risking real money.                                 |
//+------------------------------------------------------------------+
#property copyright "Educational example"
#property version   "2.00"
#property description "Pending stop breakout scalper: Buy Stop / Sell Stop around price."
#property description "Fixed or ATR distances, fixed or risk-% lots, timeout, spread/time filters,"
#property description "exposure cap, OCO, breakeven/trailing, daily loss and trade-count limits."

#include <Trade\Trade.mqh>

//--- enums (the trailing comments are shown in the inputs dialog)
enum ENUM_LOT_MODE
{
   LOT_FIXED        = 0, // Fixed lot
   LOT_RISK_PERCENT = 1  // Risk % of balance per trade
};

enum ENUM_DIST_MODE
{
   DIST_POINTS = 0, // Fixed points
   DIST_ATR    = 1  // ATR multiples
};

//--- inputs
input group "=== Position Size ==="
input ENUM_LOT_MODE  InpLotMode            = LOT_FIXED;  // Lot mode
input double         InpLotSize            = 0.1;        // Fixed lot size
input double         InpRiskPercent        = 0.5;        // Risk % of balance per trade (risk mode)
input double         InpMaxLot             = 1.0;        // Hard lot cap (0 = symbol max)

input group "=== Distances ==="
input ENUM_DIST_MODE InpDistanceMode       = DIST_POINTS; // Distance mode
input int            InpDistancePoints     = 80;         // Entry distance from price (points)
input int            InpSL_Points          = 150;        // Stop Loss from entry (points)
input int            InpTP_Points          = 250;        // Take Profit from entry (points, 0 = none)
input ENUM_TIMEFRAMES InpATRTimeframe      = PERIOD_CURRENT; // ATR timeframe
input int            InpATRPeriod          = 14;         // ATR period
input double         InpATRDistMult        = 0.5;        // Entry distance = ATR x
input double         InpATRSLMult          = 1.0;        // Stop Loss = ATR x
input double         InpATRTPMult          = 1.5;        // Take Profit = ATR x (0 = none)
input int            InpStopsBufferPoints  = 5;          // Extra points above broker stops/freeze level

input group "=== Order Management ==="
input long           InpMagic              = 20251125;   // Magic number (unique per chart)
input string         InpOrderComment       = "PSS";      // Order comment
input int            InpMaxOpenPositions   = 2;          // Max exposure: open positions + pending orders
input int            InpPendingTimeoutMin  = 15;         // Delete unfilled pending after X minutes (0 = never)
input bool           InpOnNewBarOnly       = true;       // Place new pendings at most once per bar
input bool           InpCancelOnNewBar     = false;      // Delete unfilled pendings when a new bar opens
input bool           InpOCO                = false;      // OCO: when one side fills, cancel the other and pause
input bool           InpTradeLong          = true;       // Allow Buy Stops
input bool           InpTradeShort         = true;       // Allow Sell Stops
input int            InpSlippagePoints     = 30;         // Max deviation for market closes (points)
input int            InpRetryCooldownSec   = 30;         // Wait after a failed request (seconds)
input bool           InpDeletePendingsOnRemove = true;   // Delete our pendings when the EA is removed

input group "=== Trade Management ==="
input int            InpBreakevenTriggerPts = 0;         // Move SL to breakeven at +X points (0 = off)
input int            InpBreakevenLockPts   = 10;         // Points locked in at breakeven
input int            InpTrailStartPoints   = 0;          // Start trailing at +X points (0 = off)
input int            InpTrailDistancePoints= 100;        // Trailing distance (points)
input int            InpTrailStepPoints    = 10;         // Min SL improvement per modify (points)

input group "=== Daily Risk Limits ==="
input double         InpMaxDailyLossMoney  = 0;          // Max daily loss in account currency (0 = off)
input double         InpMaxDailyLossPercent= 0;          // Max daily loss in % of day-start balance (0 = off)
input bool           InpCloseOnDailyLoss   = false;      // Also close open positions when the limit is hit
input int            InpMaxTradesPerDay    = 0;          // Max entries per day (0 = off)

input group "=== Filters ==="
input int            InpMaxSpreadPoints    = 50;         // Max allowed spread (points, 0 = off)
input string         InpStartHour          = "01:00";    // Trading start (server time, HH:MM)
input string         InpEndHour            = "23:00";    // Trading end (server time, HH:MM)
input bool           InpDeleteOutsideHours = true;       // Delete our pendings outside trading hours

input group "=== Display ==="
input bool           InpShowInfo           = true;       // Show status on chart

//--- globals
CTrade   g_trade;
int      g_atrHandle       = INVALID_HANDLE;
int      g_startMin        = 0;
int      g_endMin          = 0;
datetime g_lastPlacedBar   = 0;     // bar on which pendings were last placed successfully
datetime g_lastSeenBar     = 0;     // for new-bar detection (cancel-on-new-bar)
datetime g_nextAttempt     = 0;     // retry cooldown after a failed placement
datetime g_nextModify      = 0;     // retry cooldown after a failed SL modification
datetime g_dayStart        = 0;     // server-time midnight of the current day
bool     g_statsDirty      = true;  // daily stats must be recalculated
bool     g_dailyLossHit    = false; // daily loss limit reached -> no trading until tomorrow
bool     g_useServerExpiry = true;  // send ORDER_TIME_SPECIFIED when the broker allows it
double   g_realizedToday   = 0.0;   // closed P/L today incl. swap/commission/fee
int      g_tradesToday     = 0;     // entry deals today
string   g_lastComment     = "";

//+------------------------------------------------------------------+
//| Small helpers                                                    |
//+------------------------------------------------------------------+
int IMax(const int a, const int b) { return (a > b) ? a : b; }

int StopsLevel()  { return (int)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL); }
int FreezeLevel() { return (int)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_FREEZE_LEVEL); }

//+------------------------------------------------------------------+
//| Round a price to the symbol tick size.                           |
//| dir: +1 round up, -1 round down, 0 nearest.                      |
//| Rounding *away* from price/entry keeps us outside stops levels.  |
//+------------------------------------------------------------------+
double RoundToTick(const double price, const int dir)
{
   double ts = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   if(ts <= 0)
      ts = _Point;
   double n = price / ts;
   double r;
   if(dir > 0)
      r = MathCeil(n - 1e-7);
   else if(dir < 0)
      r = MathFloor(n + 1e-7);
   else
      r = MathRound(n);
   return NormalizeDouble(r * ts, _Digits);
}

//+------------------------------------------------------------------+
//| Number of decimals in the volume step (0.01 -> 2).               |
//+------------------------------------------------------------------+
int VolumeDigits(const double step)
{
   int d = 0;
   double v = step;
   while(d < 8 && MathAbs(v - MathRound(v)) > 1e-8)
   {
      v *= 10.0;
      d++;
   }
   return d;
}

//+------------------------------------------------------------------+
//| Floor lots to the volume step and clamp to symbol/user limits.   |
//| Returns 0 if the result is below the symbol minimum.             |
//+------------------------------------------------------------------+
double NormalizeLots(const double lots)
{
   double minLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double step   = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   if(InpMaxLot > 0 && (maxLot <= 0 || InpMaxLot < maxLot))
      maxLot = InpMaxLot;

   double v = lots;
   if(maxLot > 0 && v > maxLot)
      v = maxLot;
   if(step > 0)
      v = MathFloor(v / step + 1e-7) * step;   // floor: never exceed the requested risk
   if(v < minLot - 1e-10)
   {
      PrintFormat("Lot %.4f is below the symbol minimum %.4f, order skipped", lots, minLot);
      return 0.0;
   }
   return NormalizeDouble(v, VolumeDigits(step));
}

//+------------------------------------------------------------------+
//| "HH:MM" -> minutes since midnight                                |
//+------------------------------------------------------------------+
bool ParseHHMM(const string s, int &minutes)
{
   string parts[];
   if(StringSplit(s, ':', parts) != 2)
      return false;
   string hs = parts[0];
   string ms = parts[1];
   StringTrimLeft(hs);  StringTrimRight(hs);
   StringTrimLeft(ms);  StringTrimRight(ms);
   if(StringLen(hs) < 1 || StringLen(hs) > 2 || StringLen(ms) != 2)
      return false;
   int h = (int)StringToInteger(hs);
   int m = (int)StringToInteger(ms);
   if(h < 0 || h > 23 || m < 0 || m > 59)
      return false;
   minutes = h * 60 + m;
   return true;
}

//+------------------------------------------------------------------+
//| Inclusive window; supports overnight windows (22:00 -> 06:00).   |
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

datetime DayStart(const datetime t)
{
   MqlDateTime dt;
   TimeToStruct(t, dt);
   dt.hour = 0;
   dt.min  = 0;
   dt.sec  = 0;
   return StructToTime(dt);
}

//+------------------------------------------------------------------+
//| Terminal / EA / account permissions                              |
//+------------------------------------------------------------------+
bool TradingAllowed(string &why)
{
   if(!TerminalInfoInteger(TERMINAL_TRADE_ALLOWED))  { why = "Algo Trading is off in the terminal"; return false; }
   if(!MQLInfoInteger(MQL_TRADE_ALLOWED))            { why = "Algo Trading is off in the EA properties"; return false; }
   if(!AccountInfoInteger(ACCOUNT_TRADE_ALLOWED))    { why = "trading not allowed on this account"; return false; }
   if(!AccountInfoInteger(ACCOUNT_TRADE_EXPERT))     { why = "broker does not allow EA trading"; return false; }
   ENUM_SYMBOL_TRADE_MODE tm = (ENUM_SYMBOL_TRADE_MODE)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_MODE);
   if(tm == SYMBOL_TRADE_MODE_DISABLED)              { why = "trading disabled for symbol"; return false; }
   why = "";
   return true;
}

//+------------------------------------------------------------------+
//| Selection filters (call after PositionGetTicket / OrderGetTicket)|
//+------------------------------------------------------------------+
bool IsOurPositionSelected()
{
   return PositionGetInteger(POSITION_MAGIC) == InpMagic &&
          PositionGetString(POSITION_SYMBOL) == _Symbol;
}

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
      if(PositionGetTicket(i) == 0)
         continue;
      if(IsOurPositionSelected())
         count++;
   }
   return count;
}

int CountPendings()
{
   int count = 0;
   for(int i = OrdersTotal() - 1; i >= 0; i--)
   {
      if(OrderGetTicket(i) == 0)
         continue;
      if(IsOurOrderSelected())
         count++;
   }
   return count;
}

bool HasPending(const ENUM_ORDER_TYPE type)
{
   for(int i = OrdersTotal() - 1; i >= 0; i--)
   {
      if(OrderGetTicket(i) == 0)
         continue;
      if(IsOurOrderSelected() && (ENUM_ORDER_TYPE)OrderGetInteger(ORDER_TYPE) == type)
         return true;
   }
   return false;
}

double FloatingPL()
{
   double pl = 0.0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(PositionGetTicket(i) == 0)
         continue;
      if(IsOurPositionSelected())
         pl += PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP);
   }
   return pl;
}

//+------------------------------------------------------------------+
//| Exposure = positions + pendings that could still become one.     |
//+------------------------------------------------------------------+
bool CanOpenMore()
{
   int pendings = CountPendings();
   if(CountOpenPositions() + pendings >= InpMaxOpenPositions)
      return false;
   if(InpMaxTradesPerDay > 0 && g_tradesToday + pendings >= InpMaxTradesPerDay)
      return false;
   return true;
}

//+------------------------------------------------------------------+
//| Daily statistics from deal history (our magic + symbol only).    |
//+------------------------------------------------------------------+
void RecalcDailyStats()
{
   if(!HistorySelect(g_dayStart, TimeCurrent() + 60))
      return;                                   // keep dirty, retry next tick

   double realized = 0.0;
   int    entries  = 0;
   int    total    = HistoryDealsTotal();
   for(int i = 0; i < total; i++)
   {
      ulong deal = HistoryDealGetTicket(i);
      if(deal == 0)
         continue;
      if(HistoryDealGetInteger(deal, DEAL_MAGIC) != InpMagic ||
         HistoryDealGetString(deal, DEAL_SYMBOL) != _Symbol)
         continue;

      ENUM_DEAL_ENTRY entry = (ENUM_DEAL_ENTRY)HistoryDealGetInteger(deal, DEAL_ENTRY);
      if(entry == DEAL_ENTRY_IN || entry == DEAL_ENTRY_INOUT)
         entries++;

      realized += HistoryDealGetDouble(deal, DEAL_PROFIT)
                + HistoryDealGetDouble(deal, DEAL_SWAP)
                + HistoryDealGetDouble(deal, DEAL_COMMISSION)
                + HistoryDealGetDouble(deal, DEAL_FEE);
   }
   g_realizedToday = realized;
   g_tradesToday   = entries;
   g_statsDirty    = false;
}

bool DailyLossExceeded(const double dayPL)
{
   if(InpMaxDailyLossMoney > 0 && dayPL <= -InpMaxDailyLossMoney)
      return true;
   if(InpMaxDailyLossPercent > 0)
   {
      double dayStartBalance = AccountInfoDouble(ACCOUNT_BALANCE) - g_realizedToday;
      if(dayStartBalance > 0 && dayPL <= -dayStartBalance * InpMaxDailyLossPercent / 100.0)
         return true;
   }
   return false;
}

//+------------------------------------------------------------------+
//| Pending order deletion (respects the freeze level)               |
//+------------------------------------------------------------------+
bool PendingDeletable(const ENUM_ORDER_TYPE type, const double openPrice, const MqlTick &tick)
{
   int freeze = FreezeLevel();
   if(freeze <= 0)
      return true;
   double f = freeze * _Point;
   if(type == ORDER_TYPE_BUY_STOP)
      return (openPrice - tick.ask) > f;
   if(type == ORDER_TYPE_SELL_STOP)
      return (tick.bid - openPrice) > f;
   return true;
}

bool TryDeleteSelectedOrder(const ulong ticket, const string reason, const MqlTick &tick)
{
   ENUM_ORDER_TYPE type = (ENUM_ORDER_TYPE)OrderGetInteger(ORDER_TYPE);
   double open = OrderGetDouble(ORDER_PRICE_OPEN);
   if(!PendingDeletable(type, open, tick))
      return false;                             // inside freeze level: retry on a later tick
   if(g_trade.OrderDelete(ticket))
   {
      PrintFormat("Deleted %s #%I64u (%s)", EnumToString(type), ticket, reason);
      return true;
   }
   PrintFormat("Delete #%I64u failed: %u %s", ticket, g_trade.ResultRetcode(), g_trade.ResultRetcodeDescription());
   return false;
}

//--- typeFilter: -1 = all our pendings, otherwise an ENUM_ORDER_TYPE value
void DeletePendings(const int typeFilter, const string reason, const MqlTick &tick)
{
   for(int i = OrdersTotal() - 1; i >= 0; i--)
   {
      ulong ticket = OrderGetTicket(i);
      if(ticket == 0 || !IsOurOrderSelected())
         continue;
      if(typeFilter >= 0 && (int)OrderGetInteger(ORDER_TYPE) != typeFilter)
         continue;
      TryDeleteSelectedOrder(ticket, reason, tick);
   }
}

void DeleteExpiredPendings(const MqlTick &tick)
{
   if(InpPendingTimeoutMin <= 0)
      return;
   datetime now = TimeCurrent();
   for(int i = OrdersTotal() - 1; i >= 0; i--)
   {
      ulong ticket = OrderGetTicket(i);
      if(ticket == 0 || !IsOurOrderSelected())
         continue;
      datetime setup = (datetime)OrderGetInteger(ORDER_TIME_SETUP);
      if((long)(now - setup) >= (long)InpPendingTimeoutMin * 60)
         TryDeleteSelectedOrder(ticket, "timeout", tick);
   }
}

//+------------------------------------------------------------------+
//| OCO: if we hold a position, cancel the opposite-side pending.    |
//+------------------------------------------------------------------+
void EnforceOCO(const MqlTick &tick)
{
   if(!InpOCO)
      return;
   bool hasBuy = false, hasSell = false;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(PositionGetTicket(i) == 0 || !IsOurPositionSelected())
         continue;
      if(PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY)
         hasBuy = true;
      else
         hasSell = true;
   }
   if(hasBuy)
      DeletePendings((int)ORDER_TYPE_SELL_STOP, "OCO", tick);
   if(hasSell)
      DeletePendings((int)ORDER_TYPE_BUY_STOP, "OCO", tick);
}

void CloseAllPositions()
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0 || !IsOurPositionSelected())
         continue;
      if(!g_trade.PositionClose(ticket))
         PrintFormat("Close #%I64u failed: %u %s", ticket, g_trade.ResultRetcode(), g_trade.ResultRetcodeDescription());
   }
}

//+------------------------------------------------------------------+
//| Breakeven and trailing stop (respects stops and freeze levels)   |
//+------------------------------------------------------------------+
void ManageOpenPositions(const MqlTick &tick)
{
   if(InpBreakevenTriggerPts <= 0 && InpTrailStartPoints <= 0)
      return;
   if(TimeCurrent() < g_nextModify)
      return;

   double pt     = _Point;
   double stops  = StopsLevel() * pt;
   double freeze = FreezeLevel() * pt;
   double step   = IMax(InpTrailStepPoints, 1) * pt;

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0 || !IsOurPositionSelected())
         continue;

      long   type = PositionGetInteger(POSITION_TYPE);
      double open = PositionGetDouble(POSITION_PRICE_OPEN);
      double sl   = PositionGetDouble(POSITION_SL);
      double tp   = PositionGetDouble(POSITION_TP);
      double cand = 0.0;

      if(type == POSITION_TYPE_BUY)
      {
         double profitPts = (tick.bid - open) / pt;
         if(InpBreakevenTriggerPts > 0 && profitPts >= InpBreakevenTriggerPts)
            cand = open + InpBreakevenLockPts * pt;
         if(InpTrailStartPoints > 0 && profitPts >= InpTrailStartPoints)
            cand = MathMax(cand, tick.bid - InpTrailDistancePoints * pt);
         if(cand <= 0)
            continue;
         cand = RoundToTick(cand, -1);
         if(sl > 0 && cand - sl < step)                       continue; // no meaningful improvement
         if(tick.bid - cand < stops)                          continue; // too close to price
         if(freeze > 0 && sl > 0 && tick.bid - sl <= freeze)  continue; // SL frozen
         if(freeze > 0 && tp > 0 && tp - tick.bid <= freeze)  continue; // TP frozen
      }
      else
      {
         double profitPts = (open - tick.ask) / pt;
         if(InpBreakevenTriggerPts > 0 && profitPts >= InpBreakevenTriggerPts)
            cand = open - InpBreakevenLockPts * pt;
         if(InpTrailStartPoints > 0 && profitPts >= InpTrailStartPoints)
         {
            double t = tick.ask + InpTrailDistancePoints * pt;
            cand = (cand > 0) ? MathMin(cand, t) : t;
         }
         if(cand <= 0)
            continue;
         cand = RoundToTick(cand, +1);
         if(sl > 0 && sl - cand < step)                       continue;
         if(cand - tick.ask < stops)                          continue;
         if(freeze > 0 && sl > 0 && sl - tick.ask <= freeze)  continue;
         if(freeze > 0 && tp > 0 && tick.ask - tp <= freeze)  continue;
      }

      if(!g_trade.PositionModify(ticket, cand, tp))
      {
         PrintFormat("SL modify #%I64u -> %s failed: %u %s", ticket, DoubleToString(cand, _Digits),
                     g_trade.ResultRetcode(), g_trade.ResultRetcodeDescription());
         g_nextModify = TimeCurrent() + 5;
      }
   }
}

//+------------------------------------------------------------------+
//| Distances in points (fixed or ATR), raised to broker minimums.   |
//+------------------------------------------------------------------+
int MinBrokerDistance(const int spreadPts)
{
   int lvl = IMax(StopsLevel(), FreezeLevel());
   if(lvl == 0)
      lvl = spreadPts;   // 0 usually means "floating": use the spread as a practical minimum
   return lvl + IMax(InpStopsBufferPoints, 0);
}

bool GetDistances(const int spreadPts, int &distPts, int &slPts, int &tpPts)
{
   if(InpDistanceMode == DIST_ATR)
   {
      double buf[];
      if(CopyBuffer(g_atrHandle, 0, 1, 1, buf) != 1 || buf[0] <= 0)
         return false;                          // ATR not ready yet
      double atrPts = buf[0] / _Point;
      distPts = (int)MathRound(atrPts * InpATRDistMult);
      slPts   = (int)MathRound(atrPts * InpATRSLMult);
      tpPts   = (InpATRTPMult > 0) ? (int)MathRound(atrPts * InpATRTPMult) : 0;
   }
   else
   {
      distPts = InpDistancePoints;
      slPts   = InpSL_Points;
      tpPts   = InpTP_Points;
   }

   int minDist = MinBrokerDistance(spreadPts);
   distPts = IMax(distPts, minDist);
   slPts   = IMax(slPts, minDist);
   if(tpPts > 0)
      tpPts = IMax(tpPts, minDist);
   return true;
}

//+------------------------------------------------------------------+
//| Sizing and pre-trade checks                                      |
//+------------------------------------------------------------------+
double CalcLots(const bool isBuy, const double price, const double sl)
{
   if(InpLotMode == LOT_FIXED)
      return NormalizeLots(InpLotSize);

   double riskMoney = AccountInfoDouble(ACCOUNT_BALANCE) * InpRiskPercent / 100.0;
   double pl = 0.0;
   if(!OrderCalcProfit(isBuy ? ORDER_TYPE_BUY : ORDER_TYPE_SELL, _Symbol, 1.0, price, sl, pl) || pl >= 0)
   {
      Print("Risk sizing failed: could not compute the loss per lot");
      return 0.0;
   }
   return NormalizeLots(riskMoney / (-pl));
}

bool MarginOk(const bool isBuy, const double lots, const double price)
{
   double margin = 0.0;
   if(!OrderCalcMargin(isBuy ? ORDER_TYPE_BUY : ORDER_TYPE_SELL, _Symbol, lots, price, margin))
      return true;                              // cannot compute: let the server decide
   double freeMargin = AccountInfoDouble(ACCOUNT_MARGIN_FREE);
   if(margin > freeMargin)
   {
      PrintFormat("Not enough free margin: need %.2f, have %.2f", margin, freeMargin);
      return false;
   }
   return true;
}

//--- SYMBOL_VOLUME_LIMIT: max total volume of positions + pendings in one direction
bool VolumeLimitOk(const bool isBuy, const double lots)
{
   double limit = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_LIMIT);
   if(limit <= 0)
      return true;
   double vol = 0.0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      if(PositionGetTicket(i) == 0 || PositionGetString(POSITION_SYMBOL) != _Symbol)
         continue;
      bool posBuy = (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY);
      if(posBuy == isBuy)
         vol += PositionGetDouble(POSITION_VOLUME);
   }
   for(int i = OrdersTotal() - 1; i >= 0; i--)
   {
      if(OrderGetTicket(i) == 0 || OrderGetString(ORDER_SYMBOL) != _Symbol)
         continue;
      ENUM_ORDER_TYPE t = (ENUM_ORDER_TYPE)OrderGetInteger(ORDER_TYPE);
      bool ordBuy = (t == ORDER_TYPE_BUY || t == ORDER_TYPE_BUY_LIMIT ||
                     t == ORDER_TYPE_BUY_STOP || t == ORDER_TYPE_BUY_STOP_LIMIT);
      if(ordBuy == isBuy)
         vol += OrderGetDouble(ORDER_VOLUME_CURRENT);
   }
   if(vol + lots > limit + 1e-8)
   {
      PrintFormat("Symbol volume limit %.2f would be exceeded", limit);
      return false;
   }
   return true;
}

//+------------------------------------------------------------------+
//| Expiration: server-side expiry as a safety net when supported,   |
//| otherwise GTC, otherwise DAY.                                    |
//+------------------------------------------------------------------+
void GetExpiration(ENUM_ORDER_TYPE_TIME &typeTime, datetime &expiration)
{
   int mode = (int)SymbolInfoInteger(_Symbol, SYMBOL_EXPIRATION_MODE);
   expiration = 0;
   if(g_useServerExpiry && InpPendingTimeoutMin > 0 && (mode & SYMBOL_EXPIRATION_SPECIFIED) != 0)
   {
      typeTime   = ORDER_TIME_SPECIFIED;
      // +60 s so the EA's own timeout normally fires first; the server copy
      // protects against orphaned orders if the EA or terminal stops.
      expiration = TimeCurrent() + InpPendingTimeoutMin * 60 + 60;
      return;
   }
   if((mode & SYMBOL_EXPIRATION_GTC) != 0)
      typeTime = ORDER_TIME_GTC;
   else
      typeTime = ORDER_TIME_DAY;
}

bool SendPending(const bool isBuy, const double lots, const double price, const double sl, const double tp)
{
   ENUM_ORDER_TYPE_TIME typeTime = ORDER_TIME_GTC;
   datetime expiration = 0;
   GetExpiration(typeTime, expiration);

   bool sent = isBuy
               ? g_trade.BuyStop(lots, price, _Symbol, sl, tp, typeTime, expiration, InpOrderComment)
               : g_trade.SellStop(lots, price, _Symbol, sl, tp, typeTime, expiration, InpOrderComment);

   uint rc = g_trade.ResultRetcode();
   if(rc == TRADE_RETCODE_INVALID_EXPIRATION && typeTime == ORDER_TIME_SPECIFIED)
   {
      Print("Broker rejected the expiration time, falling back to GTC/DAY orders");
      g_useServerExpiry = false;
      return SendPending(isBuy, lots, price, sl, tp);
   }
   // CTrade returning true only means the request was sent; the retcode is the real result.
   return sent && (rc == TRADE_RETCODE_DONE || rc == TRADE_RETCODE_PLACED);
}

//+------------------------------------------------------------------+
//| Build, check and send one pending stop order.                    |
//+------------------------------------------------------------------+
bool PlacePending(const ENUM_ORDER_TYPE type, const MqlTick &tick,
                  const int distPts, const int slPts, const int tpPts)
{
   bool   isBuy = (type == ORDER_TYPE_BUY_STOP);
   double pt    = _Point;
   double price = 0.0, sl = 0.0, tp = 0.0;

   if(isBuy)
   {
      price = RoundToTick(tick.ask + distPts * pt, +1);
      sl    = RoundToTick(price - slPts * pt, -1);
      if(tpPts > 0)
         tp = RoundToTick(price + tpPts * pt, +1);
   }
   else
   {
      price = RoundToTick(tick.bid - distPts * pt, -1);
      sl    = RoundToTick(price + slPts * pt, +1);
      if(tpPts > 0)
         tp = RoundToTick(price - tpPts * pt, -1);
   }
   if(price <= 0 || sl <= 0 || (tpPts > 0 && tp <= 0))
   {
      Print("Computed prices are invalid, check the distance inputs");
      return false;
   }

   double lots = CalcLots(isBuy, price, sl);
   if(lots <= 0 || !VolumeLimitOk(isBuy, lots) || !MarginOk(isBuy, lots, price))
      return false;

   if(SendPending(isBuy, lots, price, sl, tp))
   {
      PrintFormat("%s placed: %.2f lots @ %s SL %s TP %s", EnumToString(type), lots,
                  DoubleToString(price, _Digits), DoubleToString(sl, _Digits), DoubleToString(tp, _Digits));
      return true;
   }

   PrintFormat("%s failed: %u %s | ask %s bid %s price %s SL %s TP %s stops %d freeze %d",
               EnumToString(type), g_trade.ResultRetcode(), g_trade.ResultRetcodeDescription(),
               DoubleToString(tick.ask, _Digits), DoubleToString(tick.bid, _Digits),
               DoubleToString(price, _Digits), DoubleToString(sl, _Digits), DoubleToString(tp, _Digits),
               StopsLevel(), FreezeLevel());
   return false;
}

//+------------------------------------------------------------------+
//| On-chart status                                                  |
//+------------------------------------------------------------------+
void ShowStatus(const string state)
{
   if(!InpShowInfo)
      return;
   if(MQLInfoInteger(MQL_TESTER) && !MQLInfoInteger(MQL_VISUAL_MODE))
      return;
   string txt = StringFormat("PendingStopScalper v2.00  |  magic %I64d\nState: %s\nToday: P/L %.2f %s  |  entries %d\nPositions %d  |  Pendings %d",
                             InpMagic, state,
                             g_realizedToday + FloatingPL(), AccountInfoString(ACCOUNT_CURRENCY),
                             g_tradesToday, CountOpenPositions(), CountPendings());
   if(txt != g_lastComment)
   {
      Comment(txt);
      g_lastComment = txt;
   }
}

//+------------------------------------------------------------------+
//| Expert initialization                                            |
//+------------------------------------------------------------------+
int OnInit()
{
   //--- input validation
   if(InpLotMode == LOT_FIXED && InpLotSize <= 0)
      { Print("Lot size must be > 0"); return INIT_PARAMETERS_INCORRECT; }
   if(InpLotMode == LOT_RISK_PERCENT && (InpRiskPercent <= 0 || InpRiskPercent > 10))
      { Print("Risk % must be in (0, 10]"); return INIT_PARAMETERS_INCORRECT; }
   if(InpDistanceMode == DIST_POINTS && (InpDistancePoints <= 0 || InpSL_Points <= 0 || InpTP_Points < 0))
      { Print("Distance and SL must be > 0, TP must be >= 0"); return INIT_PARAMETERS_INCORRECT; }
   if(InpDistanceMode == DIST_ATR && (InpATRPeriod <= 0 || InpATRDistMult <= 0 || InpATRSLMult <= 0 || InpATRTPMult < 0))
      { Print("ATR period and multipliers must be > 0 (TP multiplier >= 0)"); return INIT_PARAMETERS_INCORRECT; }
   if(InpMaxOpenPositions < 1)
      { Print("Max exposure must be >= 1"); return INIT_PARAMETERS_INCORRECT; }
   if(InpBreakevenTriggerPts > 0 && (InpBreakevenLockPts < 0 || InpBreakevenLockPts >= InpBreakevenTriggerPts))
      { Print("Breakeven lock must be >= 0 and below the trigger"); return INIT_PARAMETERS_INCORRECT; }
   if(InpTrailStartPoints > 0 && InpTrailDistancePoints <= 0)
      { Print("Trailing distance must be > 0"); return INIT_PARAMETERS_INCORRECT; }
   if(InpMaxDailyLossMoney < 0 || InpMaxDailyLossPercent < 0 || InpMaxTradesPerDay < 0)
      { Print("Daily limits must be >= 0"); return INIT_PARAMETERS_INCORRECT; }
   if(!ParseHHMM(InpStartHour, g_startMin) || !ParseHHMM(InpEndHour, g_endMin))
   {
      PrintFormat("Invalid trading hours, expected HH:MM (got '%s' / '%s')", InpStartHour, InpEndHour);
      return INIT_PARAMETERS_INCORRECT;
   }

   //--- symbol capabilities
   int orderMode = (int)SymbolInfoInteger(_Symbol, SYMBOL_ORDER_MODE);
   if((orderMode & SYMBOL_ORDER_STOP) == 0)
      { PrintFormat("%s does not allow stop orders", _Symbol); return INIT_FAILED; }
   if((orderMode & SYMBOL_ORDER_SL) == 0 || (orderMode & SYMBOL_ORDER_TP) == 0)
      PrintFormat("Warning: %s may not accept SL/TP on orders (order mode flags %d)", _Symbol, orderMode);

   //--- indicators
   if(InpDistanceMode == DIST_ATR)
   {
      g_atrHandle = iATR(_Symbol, InpATRTimeframe, InpATRPeriod);
      if(g_atrHandle == INVALID_HANDLE)
         { PrintFormat("Failed to create ATR handle: %d", GetLastError()); return INIT_FAILED; }
   }

   //--- trade object
   g_trade.SetExpertMagicNumber((ulong)InpMagic);
   g_trade.SetDeviationInPoints((ulong)IMax(InpSlippagePoints, 0));
   g_trade.SetTypeFillingBySymbol(_Symbol);
   g_trade.SetMarginMode();
   g_trade.SetAsyncMode(false);
   g_trade.LogLevel(LOG_LEVEL_ERRORS);

   //--- state (OnInit also runs on timeframe/input changes; our orders are found again by magic)
   g_dayStart        = 0;
   g_statsDirty      = true;
   g_dailyLossHit    = false;
   g_useServerExpiry = true;
   g_lastPlacedBar   = 0;
   g_lastSeenBar     = 0;
   g_nextAttempt     = 0;
   g_nextModify      = 0;
   g_lastComment     = "";

   if((ENUM_ACCOUNT_MARGIN_MODE)AccountInfoInteger(ACCOUNT_MARGIN_MODE) != ACCOUNT_MARGIN_MODE_RETAIL_HEDGING)
      Print("Warning: account is not hedging. A filled Buy Stop and Sell Stop will net against each other; consider OCO.");

   PrintFormat("%s: point=%s digits=%d tick=%s stops=%d freeze=%d volMin=%.2f step=%.2f expModes=%d",
               _Symbol, DoubleToString(_Point, _Digits), _Digits,
               DoubleToString(SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE), _Digits),
               StopsLevel(), FreezeLevel(),
               SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN), SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP),
               (int)SymbolInfoInteger(_Symbol, SYMBOL_EXPIRATION_MODE));
   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   if(InpDeletePendingsOnRemove && (reason == REASON_REMOVE || reason == REASON_CHARTCLOSE))
   {
      MqlTick tick;
      if(SymbolInfoTick(_Symbol, tick))
         DeletePendings(-1, "EA removed", tick);
   }
   if(g_atrHandle != INVALID_HANDLE)
   {
      IndicatorRelease(g_atrHandle);
      g_atrHandle = INVALID_HANDLE;
   }
   Comment("");
}

//+------------------------------------------------------------------+
//| React immediately to fills (OCO) and refresh daily stats.        |
//+------------------------------------------------------------------+
void OnTradeTransaction(const MqlTradeTransaction &trans,
                        const MqlTradeRequest &request,
                        const MqlTradeResult &result)
{
   if(trans.type != TRADE_TRANSACTION_DEAL_ADD || trans.symbol != _Symbol)
      return;
   g_statsDirty = true;
   if(InpOCO)
   {
      MqlTick tick;
      if(SymbolInfoTick(_Symbol, tick))
         EnforceOCO(tick);
   }
}

//+------------------------------------------------------------------+
//| Main loop                                                        |
//+------------------------------------------------------------------+
void OnTick()
{
   MqlTick tick;
   if(!SymbolInfoTick(_Symbol, tick) || tick.bid <= 0 || tick.ask <= 0)
      return;

   datetime now = TimeCurrent();

   //--- day rollover and daily stats
   datetime today = DayStart(now);
   if(today != g_dayStart)
   {
      g_dayStart     = today;
      g_dailyLossHit = false;
      g_statsDirty   = true;
   }
   if(g_statsDirty)
      RecalcDailyStats();

   //--- permissions
   string why;
   if(!TradingAllowed(why))
   {
      ShowStatus("Paused: " + why);
      return;
   }

   //--- housekeeping, runs every tick regardless of filters
   ManageOpenPositions(tick);
   DeleteExpiredPendings(tick);
   EnforceOCO(tick);

   datetime barTime = iTime(_Symbol, PERIOD_CURRENT, 0);
   if(barTime == 0)
      return;                                   // history not ready
   if(barTime != g_lastSeenBar)
   {
      if(InpCancelOnNewBar && g_lastSeenBar != 0)
         DeletePendings(-1, "new bar", tick);
      g_lastSeenBar = barTime;
   }

   //--- daily loss limit
   if(!g_dailyLossHit && DailyLossExceeded(g_realizedToday + FloatingPL()))
   {
      g_dailyLossHit = true;
      PrintFormat("Daily loss limit reached (P/L %.2f). No new trades until the next server day.",
                  g_realizedToday + FloatingPL());
      if(InpCloseOnDailyLoss)
         CloseAllPositions();
   }
   if(g_dailyLossHit)
   {
      DeletePendings(-1, "daily loss limit", tick);
      ShowStatus("Stopped: daily loss limit");
      return;
   }

   //--- time window
   if(!IsTradingTime())
   {
      if(InpDeleteOutsideHours)
         DeletePendings(-1, "outside trading hours", tick);
      ShowStatus("Outside trading hours");
      return;
   }

   if(now < g_nextAttempt)
   {
      ShowStatus("Cooling down after a failed request");
      return;
   }

   //--- spread from the live tick (SYMBOL_SPREAD can lag)
   int spreadPts = (int)MathRound((tick.ask - tick.bid) / _Point);
   if(InpMaxSpreadPoints > 0 && spreadPts > InpMaxSpreadPoints)
   {
      ShowStatus(StringFormat("Spread too wide (%d)", spreadPts));
      return;
   }

   if(InpOnNewBarOnly && barTime == g_lastPlacedBar)
   {
      ShowStatus("Waiting for next bar");
      return;
   }

   if(InpOCO && CountOpenPositions() > 0)
   {
      ShowStatus("OCO: position open, waiting");
      return;
   }

   //--- which sides are needed and allowed
   ENUM_SYMBOL_TRADE_MODE tm = (ENUM_SYMBOL_TRADE_MODE)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_MODE);
   bool allowBuy  = InpTradeLong  && (tm == SYMBOL_TRADE_MODE_FULL || tm == SYMBOL_TRADE_MODE_LONGONLY);
   bool allowSell = InpTradeShort && (tm == SYMBOL_TRADE_MODE_FULL || tm == SYMBOL_TRADE_MODE_SHORTONLY);
   bool needBuy   = allowBuy  && !HasPending(ORDER_TYPE_BUY_STOP);
   bool needSell  = allowSell && !HasPending(ORDER_TYPE_SELL_STOP);
   if(!needBuy && !needSell)
   {
      ShowStatus("Pendings in place");
      return;
   }

   int distPts = 0, slPts = 0, tpPts = 0;
   if(!GetDistances(spreadPts, distPts, slPts, tpPts))
   {
      ShowStatus("Waiting for ATR data");
      return;
   }

   //--- place (exposure re-checked before each side)
   bool failed = false;
   if(needBuy && CanOpenMore())
      if(!PlacePending(ORDER_TYPE_BUY_STOP, tick, distPts, slPts, tpPts))
         failed = true;
   if(needSell && CanOpenMore())
      if(!PlacePending(ORDER_TYPE_SELL_STOP, tick, distPts, slPts, tpPts))
         failed = true;

   if(failed)
      g_nextAttempt = now + IMax(InpRetryCooldownSec, 1);  // no request flood; retry this bar later
   else
      g_lastPlacedBar = barTime;

   ShowStatus(failed ? "Placement failed, cooling down" : "Active");
}
//+------------------------------------------------------------------+
