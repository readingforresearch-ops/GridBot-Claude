# GridBot-Planner v23.04 — User Guide

## Table of Contents

1. [Overview](#1-overview)
2. [How It Works](#2-how-it-works)
3. [Installation & Setup](#3-installation--setup)
4. [Input Parameters Reference](#4-input-parameters-reference)
5. [The Physics Solver](#5-the-physics-solver)
6. [Range Modes](#6-range-modes)
7. [Grid Geometry & Gap Logic](#7-grid-geometry--gap-logic)
8. [Strike Modes & Auto-Lot](#8-strike-modes--auto-lot)
9. [Simulation Engine](#9-simulation-engine)
10. [HUD Display](#10-hud-display)
11. [Push to Live](#11-push-to-live)
12. [Export .SET File](#12-export-set-file)
13. [Inter-Bot Communication](#13-inter-bot-communication)
14. [Understanding the Metrics](#14-understanding-the-metrics)
15. [Troubleshooting](#15-troubleshooting)
16. [Configuration Examples](#16-configuration-examples)

---

## 1. Overview

**GridBot-Planner** ("The Strategist") is the planning and visualization tool of the 3-bot GridBot system. It does **not trade**. Its purpose is to:

- Calculate optimal grid parameters (range, levels, coefficient, lot sizes)
- Simulate risk, drawdown, margin, and recovery metrics
- Display everything on a large interactive HUD
- Push optimized parameters to GridBot-Executor in real-time
- Export .SET files for manual configuration

**Key characteristics:**
- Uses `Canvas.mqh` for HUD rendering (not chart objects)
- Runs a "Physics Solver" every second to recalculate
- Auto-adjusts to volatility (ATR-based)
- No trades, no orders, no positions
- Requires `InpExecutorMagic` to match Executor's magic number

---

## 2. How It Works

### Lifecycle

```
1. OnInit:
   a. Validate inputs (balance, leverage, risk)
   b. Detect cent accounts
   c. Initialize indicators (ATR D1, ATR H1, RSI, ATR Selected TF)
   d. Create Canvas HUD
   e. Run initial solver
   f. Draw HUD and chart lines

2. OnTimer (every 1 second):
   a. Refresh tick value and spread
   b. Re-run Physics Solver
   c. Redraw HUD
   d. Update chart lines

3. OnChartEvent (mouse clicks):
   a. Detect button clicks on HUD
   b. "AUTO-PHYSICS ON" → info alert
   c. "PUSH TO LIVE" → send parameters to Executor
   d. "EXPORT .SET" → save settings file

4. OnDeinit: Cleanup HUD, indicators, chart objects
```

### No Trading

Planner has no `Trade.mqh` include and never calls order/position functions. It communicates with Executor exclusively through GlobalVariables.

---

## 3. Installation & Setup

### Prerequisites
- MetaTrader 5 (any account type works — Planner doesn't trade)
- `Canvas.mqh` included with MT5 (standard library)
- Sufficient chart space for the 1300x900 HUD

### Steps
1. Copy `GridBot-Planner_v23_04.mq5` to `MQL5/Experts/`
2. Compile in MetaEditor
3. Attach to the **same symbol** chart as Executor (e.g., XAUUSD)
4. Set `InpExecutorMagic` to match Executor's `InpMagicNumber` (default: 205001)
5. Set `InpAccountBalance` to your actual account balance
6. Configure risk and leverage parameters
7. The HUD will appear and begin calculating

### Important Notes
- Planner can run on a different chart window than Executor (same symbol, different timeframe is fine)
- The HUD is 1300x900 pixels — use a sufficiently large monitor or scroll
- Planner does NOT need AutoTrading enabled (it doesn't trade), but the warning is shown because PUSH TO LIVE uses GlobalVariables

---

## 4. Input Parameters Reference

### Group 0: Executor Link

| Parameter | Default | Description |
|---|---|---|
| `InpExecutorMagic` | `205001` | Must match GridBot-Executor's `InpMagicNumber`. Used to construct the GV namespace for PUSH TO LIVE. |

**Critical:** If this doesn't match, PUSH TO LIVE writes to the wrong GV keys and Executor will never see the update.

### Group 1: Strategy & Lots

| Parameter | Default | Description |
|---|---|---|
| `InpUseAutoLot` | `true` | Auto-calculate lot sizes to fit within the risk limit. **Recommended: true.** |
| `InpManualLot` | `0.01` | If auto-lot is off, use this as the base lot for Zone 1 |
| `InpStrikeMethod` | `STRIKE_MANUAL` | Manual: you choose the strike mode. Auto: solver tests all 5 and picks the best. |
| `InpManualStrike` | `STRIKE_MODE_5` | (Manual only) Default strike aggressiveness. See [Section 8](#8-strike-modes--auto-lot). |

### Group 2: Grid Geometry

| Parameter | Default | Description |
|---|---|---|
| `InpGapLogic` | `GAP_ATR_TARGETS` | How grid gaps are calculated: ATR-based targets or auto-geometry |
| `InpGapTimeFrame` | `TF_H4_VOLATILITY` | Timeframe for gap ATR calculation (H1, H4, or D1) |
| `InpFirstGapPct` | `60.0` | First (smallest) gap as % of ATR. E.g., 60% of H4 ATR. |
| `InpLastGapPct` | `150.0` | Last (largest) gap as % of ATR. E.g., 150% of H4 ATR. |
| `InpSpreadBuffer` | `3.0` | Minimum gap must be > 3x the current spread. Safety margin. |

### Group 3: Range & Physics

| Parameter | Default | Description |
|---|---|---|
| `InpRangeMode` | `RANGE_AUTO_VOLATILITY` | How the grid range is determined. See [Section 6](#6-range-modes). |
| `InpManualUpper` | `0.0` | Manual upper price (Mode C only) |
| `InpManualLower` | `0.0` | Manual lower price (Mode C only) |
| `InpDaysToCover` | `22` | Mode A: how many days of volatility the range should cover (~1 month) |
| `InpFixedDropPct` | `20.0` | Mode B: fixed percentage drop from current price |
| `InpEfficiency` | `0.85` | Base density factor for auto-geometry gap logic |

### Group 4: Account & Risk

| Parameter | Default | Description |
|---|---|---|
| `InpAccountBalance` | `200000.0` | Account balance for simulation. Use your actual balance. |
| `InpMaxRiskPerc` | `25.0` | Maximum acceptable drawdown as % of balance. Auto-lot sizes to this. |
| `InpSimLeverage` | `200` | Account leverage (e.g., 1:200). Used for margin calculations. |
| `InpMinMarginLvl` | `300.0` | Minimum acceptable margin level at max drawdown |
| `InpStopOutLevel` | `50.0` | Broker's stop-out level (%) for liquidation price calculation |

### Group 5: Dredging Logic

| Parameter | Default | Description |
|---|---|---|
| `InpDredgeMinRangePerc` | `60.0` | Dredge threshold: only positions in the top 60% of the range are dredge-eligible (from the bottom). Exported to .SET file. |

### Group 6: Visuals

| Parameter | Default | Description |
|---|---|---|
| `InpShowLines` | `true` | Draw horizontal chart lines (upper, lower, break-even, dredge zone, liquidation) |
| `ClrUpper` | `clrAqua` | Upper boundary line color |
| `ClrLower` | `clrRed` | Lower boundary line color |
| `ClrBreakEven` | `clrYellow` | Break-even line color |
| `ClrDredgeZone` | `clrOrange` | Dredge threshold line color |
| `ClrLiquidation` | `clrMagenta` | Liquidation price line color |

---

## 5. The Physics Solver

### What It Does

The Physics Solver runs every second and calculates the complete grid simulation:

1. **Fetch indicators** — ATR (D1, H1, selected TF), RSI
2. **Determine range** — based on selected range mode (auto, fixed, manual)
3. **Calculate RSI skew** — RSI biases the range position (higher RSI → more downside coverage)
4. **Find optimal levels & coefficient** — iterates 10-150 levels to match ATR-based gap targets
5. **Calculate lot sizes** — auto-lot to fit within risk limit, or manual
6. **Run full simulation** — compute drawdown, margin, recovery, profit factor
7. **Validate** — check if capital is safe (lot >= min, DD <= max risk)

### RSI Skew

The RSI-based skew determines how the range is positioned relative to current price:

```
SkewVal = RSI / 100   (clamped to 0.50 - 0.85)

Range below price = Total Range × SkewVal
Range above price = Total Range × (1 - SkewVal)
```

- RSI = 50 → SkewVal = 0.50 → equal above/below
- RSI = 70 → SkewVal = 0.70 → more range below (expecting pullback)
- RSI = 85 → SkewVal = 0.85 → mostly below (strong overbought)
- RSI < 50 → clamped to 0.50 → never less than 50% below

### Caching

The solver caches the optimal level count and coefficient. It only recalculates when:
- ATR changes by more than 5%
- Gap inputs change (`InpFirstGapPct` or `InpLastGapPct`)

---

## 6. Range Modes

### Mode A: Auto-Volatility (`RANGE_AUTO_VOLATILITY`)

```
Total Range = ATR(D1) × sqrt(InpDaysToCover) × 2
Lower = Price - (Range × SkewVal)
Upper = Price + (Range × (1 - SkewVal))
```

The `sqrt(InpDaysToCover)` models volatility scaling over time (random walk). Default 22 trading days (~1 month) means the range covers approximately 1 month of expected price movement.

### Mode B: Fixed Percent (`RANGE_FIXED_PERCENT`)

```
Drop Distance = Price × (InpFixedDropPct / 100)
Lower = Price - Drop Distance
Upper = Price + (Range × (1 - SkewVal))
```

Use this when you want a specific percentage coverage (e.g., "cover a 20% drop").

### Mode C: Manual Levels (`RANGE_MANUAL_LEVELS`)

```
Upper = InpManualUpper
Lower = InpManualLower
```

Full manual control. The solver calculates levels and lots to fit this exact range.

**Fallback:** If manual prices are invalid (upper <= lower or lower <= 0), it defaults to a safe +-2% range around current price.

---

## 7. Grid Geometry & Gap Logic

### ATR Targets (`GAP_ATR_TARGETS`) — Recommended

The solver finds the optimal level count and coefficient to match your target gaps:

```
Target First Gap = ATR(selected TF) × (InpFirstGapPct / 100)
Target Last Gap  = ATR(selected TF) × (InpLastGapPct / 100)

For each candidate level count (10 to 150):
  Calculate coefficient: C = (LastGap/FirstGap)^(1/(levels-1))
  Simulate total range with these gaps
  Score: |simulated range - actual range|
  Pick level count with smallest error
```

**Gap timeframe choices:**
| Setting | ATR Period | Best For |
|---|---|---|
| `TF_H1_VOLATILITY` | H1 ATR(50) | Short-term scalping grids |
| `TF_H4_VOLATILITY` | H4 ATR(50) | Standard swing grids (recommended) |
| `TF_D1_VOLATILITY` | D1 ATR(50) | Long-term position grids |

### Auto-Geometry (`GAP_AUTO_GEOMETRY`)

Alternative approach: calculates levels from efficiency parameter, then optimizes coefficient for best profit factor:

```
Efficiency Gap = ATR × InpEfficiency
Safe Gap = max(Efficiency Gap, Spread × SpreadBuffer)
Levels = Range / Safe Gap   (clamped 10-150)
Coefficient: tested 0.95 to 1.10 in 0.05 steps, best score wins
```

### Spread Safety

All gaps must be at least `InpSpreadBuffer × Spread` (default: 3x spread). If a gap is narrower than this, the grid is unprofitable at that level (spread eats the TP).

---

## 8. Strike Modes & Auto-Lot

### Strike Modes

Strike mode controls the **lot multiplier** between zones:

| Strike | Zone 2 Multiplier | Zone 3 Multiplier | Aggressiveness |
|---|---|---|---|
| Mode 5 | 1.5x | 2.5x | Least aggressive |
| Mode 4 | 1.8x | 3.0x | |
| Mode 3 | 2.0x | 3.5x | Moderate |
| Mode 2 | 2.2x | 4.5x | |
| Mode 1 | 2.5x | 6.0x | Most aggressive |

**Example (Mode 5, Base = 0.04):**
- Zone 1: 0.04 lots
- Zone 2: 0.06 lots (0.04 × 1.5)
- Zone 3: 0.10 lots (0.04 × 2.5)

**Example (Mode 1, Base = 0.04):**
- Zone 1: 0.04 lots
- Zone 2: 0.10 lots (0.04 × 2.5)
- Zone 3: 0.24 lots (0.04 × 6.0)

### Auto-Strike Optimization

When `InpStrikeMethod = STRIKE_AUTO_OPTIMIZED`, the solver tests all 5 modes and picks the one with:
1. Drawdown within risk limit
2. Lowest recovery bounce % (shortest distance to break even)
3. Highest profit factor (tiebreaker)

### Auto-Lot Calculation

When `InpUseAutoLot = true`:

```
1. Calculate Unit Drawdown:
   - Simulate the grid with 1.0 base lot
   - Sum up (Level Price - Lower) × Zone Multiplier for all levels
   - Convert to USD using tick size/value

2. Calculate Max Risk in USD:
   Max Risk USD = Balance × (InpMaxRiskPerc / 100)

3. Base Lot = Max Risk USD / Unit Drawdown USD

4. Apply strike multipliers to get Zone 2 and Zone 3 lots
5. Floor all lots to nearest SYMBOL_VOLUME_STEP
```

This ensures that if ALL levels fill simultaneously and price hits the lower bound, the drawdown equals exactly `InpMaxRiskPerc`.

---

## 9. Simulation Engine

### What Gets Simulated

The solver runs a complete grid simulation (no actual trades):

```
For each level (top to bottom):
  1. Calculate grid price
  2. Determine zone and lot size
  3. Calculate notional value (Price × Contract × Lot)
  4. Calculate margin requirement (Notional / Leverage)
  5. Calculate drawdown contribution (Price - Lower) × Lot
  6. Calculate average profit per zone (Gap × Lot)
  7. Accumulate totals
```

### Output Metrics

| Metric | Description |
|---|---|
| `CalcUpper / CalcLower` | Computed grid boundaries |
| `CalcLevels` | Optimal number of levels |
| `CalcCoeff` | Expansion coefficient |
| `RecBaseLot / RecZone2Lot / RecZone3Lot` | Recommended lot sizes |
| `FinalMaxDD_USD / FinalMaxDD_Perc` | Maximum drawdown at full deployment |
| `Sim_AvgEntry` | Volume-weighted average entry price |
| `Sim_BouncePerc` | Recovery distance as % of lower price |
| `Sim_LiquidationPrice` | Estimated price at which stop-out occurs |
| `Sim_MarginLevel` | Margin level at maximum drawdown |
| `Est_CycleProfit` | Estimated profit if price returns to upper |
| `Sim_ProfitFactor` | Cycle profit / Max drawdown |
| `Sim_CoverageRatio` | Zone 3 win per cycle / Zone 1 loss per move |
| `Sim_DredgeQuality` | How well Zone 3 gaps match ATR targets (0-100%) |
| `Stat_Sigma / Stat_Prob` | Statistical probability of price reaching lower |
| `Sim_EstRecoveryDays` | Estimated days for price to travel bounce distance |
| `Est_SwapCost` | Estimated swap cost for holding all positions |
| `Sim_Effective_Lev` | Effective leverage (Notional / Balance) |

---

## 10. HUD Display

The HUD is a 1300x900 pixel Canvas bitmap overlay with 4 columns:

### Column 1: Strategy & Account
- Strike mode and auto-lot status
- Base lot, Zone 2/3 multipliers
- Range mode and coverage
- Balance, risk limit, leverage

### Column 2: Grid Structure
- Upper and lower boundaries
- Current spread
- Range in points and %
- Level count and coefficient
- Price position within range (%)
- Distance to lower bound
- First and last gap sizes

### Column 3: Investment & Exposure
- Per-zone breakdown: lot, notional value, margin, average profit
- Total holding (lots)
- Total notional value
- Effective leverage ratio

### Column 4: Performance & Risk
- Average entry price
- Liquidation price
- Recovery target (distance, %, estimated days)
- Max drawdown ($ and %)
- Margin level at max DD
- Cycle profit and profit factor
- Coverage ratio
- Total swap cost
- Dredge quality score

### Buttons (Bottom Row)

| Button | Action |
|---|---|
| **AUTO-PHYSICS ON** | Info alert — physics solver is always running |
| **RESET** | (Placeholder — no action currently) |
| **PUSH TO LIVE** | Send current parameters to Executor via GlobalVariables |
| **EXPORT .SET** | Save parameters to a .SET file for manual import |

### Color Coding

| Element | Green | Yellow | Red |
|---|---|---|---|
| Auto Lot | Active | — | — |
| Effective Leverage | < 10x | 10-20x | > 20x |
| Recovery % | < 10% | 10-15% | > 15% |
| Max DD % | < 80% of limit | 80-100% of limit | > limit |
| Margin Level | > 500% | 300-500% | < 300% |
| Coverage Ratio | > 0.15 | 0.08-0.15 | < 0.08 |
| Last Gap | > 5x spread | — | < 3x spread |
| Price Position | < 25% | 25-75% | > 75% |

---

## 11. Push to Live

### What Gets Pushed

When you click **PUSH TO LIVE**, Planner writes these GlobalVariables:

| GV Key | Value |
|---|---|
| `205001_SG_OPT_NEW_UPPER` | Calculated upper price |
| `205001_SG_OPT_NEW_LOWER` | Calculated lower price |
| `205001_SG_OPT_NEW_LEVELS` | Optimal level count |
| `205001_SG_OPT_NEW_COEFF` | Expansion coefficient |
| `205001_SG_OPT_NEW_LOT1` | Zone 1 recommended lot |
| `205001_SG_OPT_NEW_LOT2` | Zone 2 recommended lot |
| `205001_SG_OPT_NEW_LOT3` | Zone 3 recommended lot |
| `205001_SG_MAX_RISK_PCT` | Max risk % (for Guardian auto-scaling) |
| `205001_SG_OPT_CMD_PushTime` | Timestamp (triggers Executor to read) |

### What Happens Next

1. Executor detects `OPT_CMD_PushTime` is newer than `OPT_LAST_APPLIED`
2. Executor pauses trading
3. Executor deletes all pending orders
4. Executor updates boundaries, levels, coefficient, lot sizes
5. Executor recalculates zone floors (critical for correct lot assignment)
6. Executor rebuilds grid and remaps positions
7. Executor resumes trading
8. Executor logs: `OPTIMIZATION APPLIED`

### When to Push

- After changing the range or risk parameters and the HUD shows `IsCapitalSafe = true`
- After market conditions change significantly (large ATR shift)
- After adjusting strike mode
- **Do NOT push during active hedging** — Guardian is managing the account

### Guardian Risk Publishing

The `MAX_RISK_PCT` value is also pushed. If Guardian has `InpAutoScaleToRisk = true`, it will scale its hedge triggers to match your risk limit. This creates a unified risk framework across all 3 bots.

---

## 12. Export .SET File

### What Gets Exported

Clicking **EXPORT .SET** creates a file in `MQL5/Files/` with the format:
```
{Symbol}_SmartGrid_v23_04.set
```

Contents:
```ini
; === SMART GRID UNIVERSAL v23.04 SETTINGS ===
InpUpperPrice=2750.00000
InpLowerPrice=2650.00000
InpGridLevels=45
InpExpansionCoeff=1.0000
InpStartAtUpper=false

InpLotZone1=0.04
InpLotZone2=0.06
InpLotZone3=0.10

InpDredgeRangePct=0.60
InpUseBucketDredge=true

InpMaxSpread=150

InpHardStopDDPct=25.0
InpUseVirtualTP=true

InpMaxOpenPos=45
InpMagicNumber=205001
```

### How to Use

1. Open the .SET file from `MQL5/Files/`
2. In Executor's properties dialog, click "Load" and select the file
3. Executor will restart with the new parameters

**Note:** This is the manual alternative to PUSH TO LIVE. Use it when you want to review parameters before applying, or when Executor is on a different VPS.

### Capital Safety Check

Export is blocked if `IsCapitalSafe = false` (lot size below minimum or DD exceeds risk limit). An alert will say: `Cannot export: Capital unsafe!`

---

## 13. Inter-Bot Communication

### Planner Writes (to Executor)

| GV Key | When | Purpose |
|---|---|---|
| `205001_SG_OPT_NEW_UPPER` | On PUSH TO LIVE | Recommended upper price |
| `205001_SG_OPT_NEW_LOWER` | On PUSH TO LIVE | Recommended lower price |
| `205001_SG_OPT_NEW_LEVELS` | On PUSH TO LIVE | Recommended levels |
| `205001_SG_OPT_NEW_COEFF` | On PUSH TO LIVE | Recommended coefficient |
| `205001_SG_OPT_NEW_LOT1/2/3` | On PUSH TO LIVE | Recommended lot sizes |
| `205001_SG_MAX_RISK_PCT` | On PUSH TO LIVE | Max risk % for Guardian auto-scaling |
| `205001_SG_OPT_CMD_PushTime` | On PUSH TO LIVE | Trigger timestamp |

### Planner Reads (from Executor)

Planner does not actively read Executor's GVs for its calculations. It operates independently using market data and indicators. The `InpExecutorMagic` parameter is only used to construct the correct GV key namespace.

### No Direct Guardian Communication

Planner does not communicate directly with Guardian. The risk coupling works indirectly:
1. Planner publishes `MAX_RISK_PCT` via PUSH TO LIVE
2. Executor stores it as a GV
3. Guardian reads it from the GV namespace and scales triggers

---

## 14. Understanding the Metrics

### Recovery Target

The **bounce distance** is how far price must rise from the lower bound to reach the volume-weighted average entry:

```
Avg Entry = Sum(Price[i] × Lot[i]) / Sum(Lot[i])
Bounce Distance = Avg Entry - Lower
Bounce % = Bounce Distance / Lower × 100
```

A lower bounce % is better — it means the grid recovers faster. Typical values: 5-15% for gold.

### Profit Factor

```
Profit Factor = Cycle Profit / Max Drawdown
```

Where:
- **Cycle Profit** = (Upper - Avg Entry) × Tick Value × Total Lots
- **Max Drawdown** = Sum of (Level Price - Lower) × Tick Value × Level Lot for all levels

A profit factor > 1.0 means the grid earns more than it risks per cycle. Target: 1.5-3.0.

### Coverage Ratio

```
Coverage = Zone 3 Avg Win / Zone 1 Avg Loss per Move
```

Measures how effectively Zone 3 profits cover Zone 1 losses. Higher is better. Target: > 0.15.

### Liquidation Price

The price at which the broker would stop you out:

```
Dollar Per Point = Total Lots × Tick Value / Tick Size
Usable Equity = Balance - (Balance × Stop Out Level / 100)
Distance to Death = Usable Equity / Dollar Per Point
Liquidation = Avg Entry - Distance to Death
```

If liquidation price is above the lower bound, your grid is under-capitalized.

### Statistical Probability (Sigma)

How many standard deviations the lower bound is from current price:

```
Drop Distance = Current Price - Lower
Expected Volatility = ATR(D1) × sqrt(Days to Cover) × Skew
Sigma = Drop Distance / Expected Volatility
```

| Sigma | Probability of Touching Lower |
|---|---|
| < 1 | ~68% chance |
| 1-2 | ~5-32% chance |
| > 2 | < 5% chance |

Higher sigma = lower probability of reaching the lower bound = safer grid.

---

## 15. Troubleshooting

### HUD Not Showing

**Check:**
1. Is the chart large enough? HUD is 1300x900 pixels
2. Try zooming out the chart
3. Check Experts tab for `Error: Failed to create HUD`
4. Ensure `Canvas.mqh` is available (standard MT5 library)

### "Error: Invalid Tick Size"

**Cause:** Indicator data not yet loaded (common on first attach).
**Fix:** Wait a few seconds and re-attach, or switch timeframe and back.

### Zero Lot Size / "Capital Unsafe"

**Cause:** The risk budget is too small for even the minimum lot:
- `InpAccountBalance` is too low
- `InpMaxRiskPerc` is too low
- Range is too wide (too many levels, too much drawdown per lot)

**Fix:**
- Increase balance or risk %
- Narrow the range (fewer days to cover, or manual range)
- Use a less aggressive strike mode (Mode 5)
- Reduce levels

### Metrics Show 0 or NaN

**Cause:** Indicators haven't loaded yet (ATR needs 50 bars of history).
**Fix:** Wait for the next timer tick (1 second). Planner auto-retries.

### PUSH TO LIVE Not Working

**Check:**
1. Is `InpExecutorMagic` correct? Must match Executor's `InpMagicNumber`.
2. Is Executor running with `InpAllowRemoteOpt = true`?
3. Check GlobalVariables window (Tools → Global Variables) for `205001_SG_OPT_CMD_PushTime`
4. Check Executor's Experts log for `OPTIMIZATION APPLIED` or `REMOTE OPTIMIZATION RECEIVED`

### Cent Account Detection

Planner auto-detects cent accounts (currency contains "USC"/"EUC" or symbol ends with "c"). Lot sizes in cent accounts are 1/100 of standard. Verify your lot sizes make sense for your account type.

---

## 16. Configuration Examples

### Gold (XAUUSD) — Standard Setup

```
InpExecutorMagic = 205001
InpUseAutoLot = true
InpStrikeMethod = STRIKE_MANUAL
InpManualStrike = STRIKE_MODE_5    // Conservative zone multipliers

InpGapLogic = GAP_ATR_TARGETS
InpGapTimeFrame = TF_H4_VOLATILITY
InpFirstGapPct = 60.0
InpLastGapPct = 150.0

InpRangeMode = RANGE_AUTO_VOLATILITY
InpDaysToCover = 22               // ~1 month coverage

InpAccountBalance = 10000.0
InpMaxRiskPerc = 25.0
InpSimLeverage = 200
```

### Gold — Tight Range, High Frequency

```
InpRangeMode = RANGE_MANUAL_LEVELS
InpManualUpper = 2750.0
InpManualLower = 2700.0          // Only $50 range
InpFirstGapPct = 40.0            // Tighter gaps
InpLastGapPct = 80.0
InpManualStrike = STRIKE_MODE_5  // Low multipliers for tight range
```

### BTC — Wide Range, Conservative

```
InpRangeMode = RANGE_FIXED_PERCENT
InpFixedDropPct = 25.0           // Cover a 25% drop
InpGapTimeFrame = TF_D1_VOLATILITY  // Use daily ATR for BTC
InpFirstGapPct = 80.0            // Wider gaps (BTC is volatile)
InpLastGapPct = 200.0
InpMaxRiskPerc = 15.0            // Lower risk for crypto
InpManualStrike = STRIKE_MODE_4
```

### Auto-Optimized (Hands-Off)

```
InpUseAutoLot = true
InpStrikeMethod = STRIKE_AUTO_OPTIMIZED  // Let solver pick the best mode
InpRangeMode = RANGE_AUTO_VOLATILITY
InpDaysToCover = 22
InpGapLogic = GAP_ATR_TARGETS
```

The solver will automatically:
- Calculate range from ATR and RSI skew
- Find optimal levels and coefficient
- Test all 5 strike modes
- Pick the mode with lowest bounce % within risk limit
- Size lots to exactly fit `InpMaxRiskPerc`

---

## Appendix: Enum Reference

### ENUM_STRIKE_SELECTION
| Value | Description |
|---|---|
| `STRIKE_MANUAL` | You choose the strike mode |
| `STRIKE_AUTO_OPTIMIZED` | Solver tests all 5 and picks the best |

### ENUM_STRIKE_MODE
| Value | Zone 2x | Zone 3x |
|---|---|---|
| `STRIKE_MODE_5` | 1.5x | 2.5x |
| `STRIKE_MODE_4` | 1.8x | 3.0x |
| `STRIKE_MODE_3` | 2.0x | 3.5x |
| `STRIKE_MODE_2` | 2.2x | 4.5x |
| `STRIKE_MODE_1` | 2.5x | 6.0x |

### ENUM_RANGE_MODE
| Value | Description |
|---|---|
| `RANGE_AUTO_VOLATILITY` | ATR-based range (recommended) |
| `RANGE_FIXED_PERCENT` | Fixed % drop from current price |
| `RANGE_MANUAL_LEVELS` | Manual upper/lower prices |

### ENUM_GAP_LOGIC
| Value | Description |
|---|---|
| `GAP_ATR_TARGETS` | Match gaps to ATR % targets (recommended) |
| `GAP_AUTO_GEOMETRY` | Auto-calculate from efficiency parameter |

### ENUM_VOL_TF
| Value | ATR Period |
|---|---|
| `TF_H1_VOLATILITY` | H1 ATR(50) |
| `TF_H4_VOLATILITY` | H4 ATR(50) |
| `TF_D1_VOLATILITY` | D1 ATR(50) |

---

*Generated for GridBot-Planner v23.04 Audited Edition. Last updated: 2026-02-11.*
