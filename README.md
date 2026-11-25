# PendingStopScalper (MT5)

A MetaTrader 5 Expert Advisor that keeps one **Buy Stop** above price and one **Sell Stop** below price, each with a fixed lot and fixed SL/TP. Pending orders that don't fill within a timeout get cancelled. The EA only touches orders and positions that carry its own magic number on the chart's symbol.

> **Warning:** This is a simple breakout scalper for learning purposes. It is not a proven strategy and it is not "AI". Gold (XAUUSD) moves fast: slippage, spread spikes and losing streaks are normal. Backtest it and run it on a demo account before you risk real money.

## Install

1. In MT5, open MetaEditor (F4).
2. Copy `PendingStopScalper.mq5` into `MQL5/Experts/`. You can find that folder with *File → Open Data Folder*.
3. Open the file and compile it (F7).
4. Attach the EA to a chart, for example XAUUSD M5, and turn on Algo Trading.

## Inputs (v2.00)

| Group | Key inputs | Notes |
|---|---|---|
| Position size | `InpLotMode`, `InpLotSize`, `InpRiskPercent`, `InpMaxLot` | Fixed lot or % of balance risked from entry to SL. Lots are floored to the volume step and never rounded up. |
| Distances | `InpDistanceMode`, `InpDistancePoints`, `InpSL_Points`, `InpTP_Points`, `InpATR*`, `InpStopsBufferPoints` | Fixed points or ATR multiples (from the last closed bar). Each value is raised to the larger of the stops and freeze levels, plus the buffer. If the broker reports 0, the spread is used as the minimum instead. |
| Order management | `InpMaxOpenPositions`, `InpPendingTimeoutMin`, `InpOnNewBarOnly`, `InpCancelOnNewBar`, `InpOCO`, `InpRetryCooldownSec`, `InpDeletePendingsOnRemove` | The exposure cap counts positions plus pending orders. The timeout is checked every tick, and the broker's own expiry is also set as a backup when the symbol supports it. |
| Trade management | `InpBreakevenTriggerPts`, `InpBreakevenLockPts`, `InpTrailStartPoints`, `InpTrailDistancePoints`, `InpTrailStepPoints` | Off by default. Stop moves respect the stops and freeze levels. |
| Daily risk | `InpMaxDailyLossMoney`, `InpMaxDailyLossPercent`, `InpCloseOnDailyLoss`, `InpMaxTradesPerDay` | Uses server days. Counts only this EA's deals (same magic and symbol), including swap, commission and fees. |
| Filters | `InpMaxSpreadPoints`, `InpStartHour`, `InpEndHour`, `InpDeleteOutsideHours` | The spread comes from the live tick. Trading windows can cross midnight. |

With the default inputs the behavior matches v1: fixed 0.1 lots, 80/150/250 points, 15-minute timeout, and all new features turned off.

**Points depend on your broker.** On a gold symbol with 2 digits, 1 point is 0.01. When the EA starts, it writes the point size, tick size, stops level, freeze level, volume step and allowed expiration modes to the Experts log. Check those values first.

Use a **hedging** account. On a netting account, a filled Buy Stop and Sell Stop cancel each other out. If you have to use netting, turn on `InpOCO`.

## Ideas for later

ATR-based distance and SL, a fair value gap or higher-timeframe trend filter, trailing stop, daily loss limit or max trades per day, a news filter, lot size from risk %.
