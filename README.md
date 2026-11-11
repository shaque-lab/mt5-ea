# Shinvest Secondary Structure — MT5 EA

MQL5 implementation of the secondary zigzag HH→HL (BUY) / LL→LH (SELL) TradingView backtest in `shaque-lab/pricebias-model-v2`, branch `fix/structural-context-semantics-agent2`, file `scripts/tradingview/shinvest_secondary_trades_backtest.pine`.

**Status: source-only initial port. Not compiled or validated in MetaEditor/MT5 yet. Do not run on a live/prop account until compilation, Strategy Tester and demo parity checks pass.**

## Manual chart trading switch

A prominent **EA TRADING: OFF / ON** button appears at the top-left of the chart. It always starts **OFF**, including after restarting or reattaching the EA. Click to toggle automatic new entries ON or OFF. When OFF, the EA continues tracking confirmed fractals and checking loss guards, but will **not** open new trades; missed signals are not queued for later. Existing positions keep their broker-side SL/TP and are not closed by this button. The daily/overall loss-guard close behavior, if enabled separately, remains active even while trading is OFF. This switch controls **this EA's automatic entries only**, not MT5's manual trading controls or other EAs. MT5's global Algo Trading permission must also be enabled for ON to place orders.

## Entry rules
- Operate on closed M1 candles (default). Confirm a three-candle high/low pivot using strict comparisons.
- Maintain alternating high/low zigzag; same-type more-extreme pivots replace the current endpoint.
- Both high and low pivots on the same confirmation candle are processed in the same order as Pine (opposite last endpoint first).
- BUY: new HL after a completed HH; SELL: new LH after a completed LL. Reject HH+HL / LL+LH on same pivot candle; reject if the confirmation candle already touched the target.
- At the first tick of the following bar, verify minimum RR 5, minimum stop distance 19 × 0.01 gold price units, and execute at current ask (BUY) or bid (SELL). SL is the HL/LH pivot; TP the preceding HH/LL pivot.
- No IMB/FVG or intermediate-fractal filters.

## Configurable Inputs (EA Properties → Inputs)
| Option | Default |
|---|---|
| Symbol | XAUUSD; blank uses chart symbol, recommended for suffix brokers |
| Timeframe | M1 |
| Direction | Both |
| Minimum RR | 5 |
| Minimum SL (pips) | 19 |
| Pip size | 0.01 |
| Risk per trade | 0.1% of current equity |
| Maximum open positions | 1 |
| Maximum spread | 30 MT5 points |
| Daily loss cutoff | enabled, 2% |
| Overall drawdown cutoff | enabled, 5% |
| Close positions at cutoff | disabled (block new trades only) |
| History replay | 3000 bars |
| Magic number | 26011101 |

The default maximum open-position check covers **all positions on the traded symbol**, including manual positions and other EAs. Set `InpBlockOtherSymbolPositions=true` to apply the cap account-wide. **Do not run several copies with the same account/magic and different risk settings**.

## Setup
1. Download `Experts/ShinvestSecondaryEA.mq5`; in MT5 open **File → Open Data Folder → MQL5 → Experts**, copy it there.
2. Open MetaEditor (F4), compile, and resolve any compiler feedback before continuing.
3. Attach to your broker's **XAUUSD M1** chart; if the symbol has a suffix (e.g. XAUUSDm), set `InpSymbol=""` to use the chart symbol.
4. Enable Algo Trading and review Inputs. Check the symbol's tick size, contract size, stops level, point and spread, and whether the prop firm permits EAs.
5. Run Strategy Tester on **Every tick based on real ticks**, then demo-forward-test. Compare individual pivot timestamps, signals, and fills to Pine before deploying.

## Safety / differences from TradingView
- MT5 uses executable bid/ask and live tick data; Pine's signal-close risk check/next-open market order can give different trade counts and realised RR.
- Position sizing uses `OrderCalcProfit` to estimate equity risk in **account currency**, rounds volume down to the broker step and skips if the broker minimum lot would exceed budget. Fees/slippage are **not** included in risk budgeting; actual realized loss can exceed 0.1%.
- Loss guards use broker-server midnight and **account equity**; they're not a guarantee against loss limits. Guard baselines/locks persist in MT5 terminal Global Variables per account+magic; first launch establishes overall initial balance and daily starting equity. Overall lock is sticky; daily lock resets at server midnight. To reset the initial baseline intentionally, remove corresponding `ShinvestEA.*` Global Variables (F3) only when the EA is stopped and you're deliberately reconfiguring the account.
- Daily cutoff is based on day-start equity rather than a prop firm's exact daily-loss rule. Prop firms may use balance, higher-of-balance/equity, or fixed day-start boundaries; confirm your account terms.
- `OnTick` fires on the chart symbol. For reliable timing, attach EA to the **same symbol** it trades.
- `InpHistoryBars` controls how much prior history is replayed at initialization; longer history may be needed to match Pine's original complete historical fractal state, since the Pine strategy processed all chart bars.
- One tick/bar processing; restart during a bar replays historical pivots and does not issue stale orders. State reconstructed with a limited history window can differ from Pine.
- This first port has **not been compiled or MT5-backtested** in this environment. Strategy Tester matching and real-broker execution validation are required.

## Reference implementation
[TradingView Pine strategy](https://github.com/shaque-lab/pricebias-model-v2/blob/fix/structural-context-semantics-agent2/scripts/tradingview/shinvest_secondary_trades_backtest.pine)
