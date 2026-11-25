# PendingStopScalper (MT5)

A MetaTrader 5 Expert Advisor that keeps one **Buy Stop** above price and one **Sell Stop** below price, each with a fixed lot and fixed SL/TP. Pending orders that don't fill within a timeout get cancelled. The EA only touches orders and positions that carry its own magic number on the chart's symbol.

> **Warning:** This is a simple breakout scalper for learning purposes. It is not a proven strategy and it is not "AI". Gold (XAUUSD) moves fast: slippage, spread spikes and losing streaks are normal. Backtest it and run it on a demo account before you risk real money.

## Install

1. In MT5, open MetaEditor (F4).
2. Copy `PendingStopScalper.mq5` into `MQL5/Experts/`. You can find that folder with *File → Open Data Folder*.
3. Open the file and compile it (F7).
4. Attach the EA to a chart, for example XAUUSD M5, and turn on Algo Trading.

## Inputs

| Input | Default | Notes |
|---|---|---|
| `InpLotSize` | 0.1 | Rounded to the symbol's volume step. Rejected if below the symbol's minimum lot. |
| `InpDistancePoints` | 80 | Distance from Ask (Buy Stop) or Bid (Sell Stop) to the entry. |
| `InpSL_Points` / `InpTP_Points` | 150 / 250 | Measured from the entry price. Set TP to 0 for no TP. |
| `InpMagic` | 20251125 | Use a different value on each chart. |
| `InpMaxOpenPositions` | 2 | Cap on **open positions plus pending orders** combined. |
| `InpPendingTimeoutMin` | 15 | Checked on every tick. 0 turns it off. |
| `InpOnNewBarOnly` | true | Places new pendings at most once per bar. |
| `InpMaxSpreadPoints` | 50 | 0 turns the spread filter off. |
| `InpStartHour` / `InpEndHour` | 01:00 / 23:00 | Server time. Overnight windows such as 22:00 to 06:00 work. |
| `InpDeleteOutsideHours` | true | Cancels this EA's pendings outside the trading window. |

**Points depend on your broker.** On a gold symbol with 2 digits, 1 point is 0.01, so 80 points is $0.80. With 3 digits, 1 point is 0.001. The EA prints the symbol's point size and stops level to the Experts log when it starts. Check those values and scale the inputs to match.

Rough starting ranges for XAUUSD M5 with 2 digits: distance 50 to 150, SL 100 to 300, TP 150 to 400. Set the max spread a little above your broker's normal gold spread.

## Changes from the original draft

- Prices are rounded to the symbol's tick size, and lots to its volume step, so the broker doesn't reject orders as invalid.
- The entry distance, SL and TP are raised to the broker's minimum stops level when they are set too small.
- The position limit counts pending orders too. Before, both pendings could fill and go past the limit.
- The pending timeout is checked on every tick, not only when a new bar opens.
- A bar is only marked as used once the spread and time filters pass. Before, a wide spread at the bar open skipped the whole bar.
- The time window is parsed properly and works across midnight.
- Failed orders log the broker's return code.
- The warning prints on netting accounts, where a filled Buy Stop and Sell Stop cancel each other out. A hedging account is recommended.
- Removed `#property strict`, which only exists in MQL4.

## Ideas for later

ATR-based distance and SL, a fair value gap or higher-timeframe trend filter, trailing stop, daily loss limit or max trades per day, a news filter, lot size from risk %.
