# GridBot-Executor v10.08 — User Guide

## Table of Contents

1. [Overview](#1-overview)
2. [How It Works](#2-how-it-works)
3. [Installation & Setup](#3-installation--setup)
4. [Input Parameters Reference](#4-input-parameters-reference)
5. [Grid Geometry & Zones](#5-grid-geometry--zones)
6. [Condensing Grid Engine](#6-condensing-grid-engine)
7. [Rolling Tail & Order Management](#7-rolling-tail--order-management)
8. [Virtual Take-Profit System](#8-virtual-take-profit-system)
9. [Bucket & Dredge System](#9-bucket--dredge-system)
10. [Dynamic Grid (Upward Shift)](#10-dynamic-grid-upward-shift)
11. [Guardian Coordination (Freeze Protocol)](#11-guardian-coordination-freeze-protocol)
12. [Remote Optimization (Planner Push)](#12-remote-optimization-planner-push)
13. [Dashboard](#13-dashboard)
14. [State Persistence & Recovery](#14-state-persistence--recovery)
15. [Safety Mechanisms](#15-safety-mechanisms)
16. [Log System](#16-log-system)
17. [Troubleshooting](#17-troubleshooting)
18. [Configuration Examples](#18-configuration-examples)

---

## 1. Overview

**GridBot-Executor** is the live trading engine of the 3-bot GridBot system. It is the only bot that places and manages grid orders. It creates a **buy-only grid** of limit orders across a price range, takes profit when price rises to target levels, and uses a bucket/dredge system to clear deep positions.

**Key responsibilities:**
- Calculate and maintain a condensing grid of BUY LIMIT orders
- Manage position entries, virtual take-profits, and order lifecycle
- Operate the bucket/dredge cash flow engine
- Publish coordination data (exposure, heartbeat) for Guardian
- Accept remote parameter updates from Planner
- Dynamically shift the grid upward when price breaks out

**What Executor does NOT do:**
- It does not place SELL/hedge orders (that's Guardian's job)
- It does not extend the grid downward (removed for safety)
- It does not calculate optimal parameters (that's Planner's job)

---

## 2. How It Works

### Lifecycle

```
1. OnInit:
   a. Safety checks (hedging account, AutoTrading, instance guard)
   b. Load saved state from GlobalVariables (or start fresh)
   c. Calculate grid geometry (prices, lots, TPs)
   d. Map existing broker positions to grid levels
   e. Publish coordination data for Guardian

2. OnTick (every tick):
   a. Price staleness check (skip if data >30s old)
   b. Guardian coordination check (FREEZE if hedge active)
   c. Equity stop check
   d. Dynamic grid shift check (upward only)
   e. SyncMemoryWithBroker (keep grid state in sync with broker)
   f. Rolling tail management (delete excess pending orders)
   g. Scan for realized profits → feed bucket
   h. Place new grid entries (BUY LIMITs)
   i. Manage exits (virtual TP closes)
   j. Bucket dredging (close worst positions with profit)
   k. Publish heartbeat and exposure data

3. OnTimer (every 1 second):
   a. Calculate dashboard statistics
   b. Update chart dashboard
```

### Grid Concept

The grid is a series of **BUY LIMIT** orders placed at decreasing prices below the current market. When price drops to a level, the order fills. When price rises back to the level's take-profit (the next level above), the position closes for profit.

```
Upper Price ─── $2750 (TP target for Level 1)
  Level 1   ─── $2745 (BUY at this price, TP = $2750)
  Level 2   ─── $2739 (BUY at this price, TP = $2745)
  Level 3   ─── $2732 (BUY at this price, TP = $2739)
  ...
  Level 45  ─── $2650 (BUY at this price, TP = Level 44)
Lower Price ─── $2650
```

---

## 3. Installation & Setup

### Prerequisites
- MetaTrader 5 with a **hedging** account
- AutoTrading enabled in MT5 terminal
- `Trade.mqh` included with MT5 (standard library)

### Steps
1. Copy `GridBot-Executor_v10_Integrated.mq5` to `MQL5/Experts/`
2. Compile in MetaEditor (zero errors expected)
3. Set initial parameters (Upper/Lower price, levels, lot sizes)
4. Attach to the desired chart (e.g., XAUUSD, BTCUSDm)
5. Verify the Experts log shows `Initialization Complete`

### First Run vs. Resume
- **First run:** Executor uses `InpUpperPrice` and `InpLowerPrice` as grid boundaries
- **Resume:** If saved state exists in GlobalVariables, those values are loaded instead (input prices are ignored)
- **Reset:** Set `InpResetState = true` to discard saved state and start fresh

### Instance Guard
Only one Executor per symbol+magic combination is allowed. If you attach a second instance with the same magic on the same symbol, it will fail with: `Another GridBot-Executor already running`.

---

## 4. Input Parameters Reference

### Group 0: System Control

| Parameter | Default | Description |
|---|---|---|
| `InpResetState` | `false` | Set to `true` once to clear all saved state and start fresh. Set back to `false` after. |
| `InpMagicNumber` | `205001` | Unique identifier for this bot's orders/positions. Must match in all 3 bots. |
| `InpComment` | `"SmartGrid_v10"` | Comment attached to all orders placed by this bot |

### Group 1: Grid Settings

| Parameter | Default | Description |
|---|---|---|
| `InpUpperPrice` | `2750.0` | Initial grid top. Only used on first run; ignored when resuming from saved state. |
| `InpLowerPrice` | `2650.0` | Initial grid bottom. Only used on first run. |
| `InpGridLevels` | `45` | Number of grid levels (5-200). More levels = denser grid = more margin required. |
| `InpExpansionCoeff` | `1.0` | Grid condensing coefficient. `1.0` = uniform spacing. `<1.0` = tighter at top, wider at bottom. `>1.0` = wider at top, tighter at bottom. |
| `InpStartAtUpper` | `false` | If `true`, first level is AT the upper price. If `false`, first level is one gap below upper. |

### Group 2: Dynamic Grid Engine

| Parameter | Default | Description |
|---|---|---|
| `InpEnableDynamicGrid` | `true` | Enable automatic upward grid shift when price breaks above the range |
| `InpUpShiftTriggerPct` | `0.10` | Trigger shift when price exceeds upper by this % of range (buffer zone) |
| `InpUpShiftAmountPct` | `20.0` | Shift both upper and lower by this % of range when triggered |

### Group 3: Rolling Tail & Execution

| Parameter | Default | Description |
|---|---|---|
| `InpMaxPendingOrders` | `20` | Maximum number of BUY LIMIT orders to have pending simultaneously |

The bot does NOT place all grid levels as pending orders at once. It maintains a "rolling window" of the nearest N levels. As price moves, orders are added/removed to keep the window around the current price. See [Section 7](#7-rolling-tail--order-management).

### Group 4: Stepped Volume Zones

| Parameter | Default | Description |
|---|---|---|
| `InpLotZone1` | `0.01` | Lot size for Zone 1 (upper third of the grid — closest to current price) |
| `InpLotZone2` | `0.02` | Lot size for Zone 2 (middle third — moderate drawdown) |
| `InpLotZone3` | `0.05` | Lot size for Zone 3 (lower third — deep drawdown, highest risk/reward) |

These are initial values. They can be overridden at runtime via Planner's `PUSH TO LIVE` button, and the runtime values persist across restarts.

### Group 5: Cash Flow Engine (The Bucket)

| Parameter | Default | Description |
|---|---|---|
| `InpUseBucketDredge` | `true` | Enable the bucket/dredge system for clearing deep positions |
| `InpBucketRetentionHrs` | `48` | Hours before bucket profits expire (use-it-or-lose-it) |
| `InpSurvivalRatio` | `0.5` | If balance < initial balance, only use 50% of bucket for dredging |
| `InpDredgeRangePct` | `0.5` | Price must move at least 50% of total range away from position before dredge eligible (distance filter) |
| `InpUseVirtualTP` | `true` | Close positions programmatically instead of broker TP orders |

### Group 6: Risk & Safety

| Parameter | Default | Description |
|---|---|---|
| `InpHardStopDDPct` | `25.0` | Hard stop drawdown % from peak balance. Auto-tracks peak — floor rises when real profits are banked, never drifts on floating equity. Range: 1–50%. Triggers `CloseAllPositions()`. |
| `InpMaxOpenPos` | `100` | Maximum total open positions allowed |
| `InpMaxSpread` | `2000` | Maximum spread (in points) for order placement. Orders skip if spread exceeds this. |

### Group 7: Dashboard Settings

| Parameter | Default | Description |
|---|---|---|
| `InpShowDashboard` | `true` | Show the real-time chart panel |
| `InpShowGhostLines` | `true` | Draw horizontal lines at each grid level on the chart |
| `InpShowBreakEven` | `true` | Draw a yellow line at the volume-weighted average entry price |
| `InpColorZone1` | `clrDodgerBlue` | Color for Zone 1 ghost lines |
| `InpColorZone2` | `clrOrange` | Color for Zone 2 ghost lines |
| `InpColorZone3` | `clrRed` | Color for Zone 3 ghost lines |

### Group 8: Advanced Features

| Parameter | Default | Description |
|---|---|---|
| `InpEnableTradeLog` | `true` | Print detailed trade logs (BUY_LIMIT placed, TP_CLOSE, DREDGED, etc.) |

### Group 9: Guardian Integration & Notifications

| Parameter | Default | Description |
|---|---|---|
| `InpEnableGuardianCoordination` | `true` | Enable communication with Guardian via GlobalVariables |
| `InpCoordinationCheckInterval` | `5` | Seconds between checking Guardian's HEDGE_ACTIVE flag |
| `InpGuardianMagic` | `999999` | Guardian bot magic number — used to read Guardian GVs for the master dashboard section |
| `InpEnablePushNotify` | `true` | Send mobile push notifications for grid events |
| `InpEnableEmailNotify` | `false` | Send email notifications |
| `InpAllowRemoteOpt` | `true` | Accept parameter updates from Planner's PUSH TO LIVE |

---

## 5. Grid Geometry & Zones

### Zone System

The grid range is divided into 3 equal zones by price:

```
Upper ────────────── $2750
  Zone 1 (top 1/3)    Lot: 0.01  (smallest — low risk, frequent TP)
  Zone1 Floor ──────── $2717
  Zone 2 (mid 1/3)    Lot: 0.02  (medium — moderate risk)
  Zone2 Floor ──────── $2683
  Zone 3 (bot 1/3)    Lot: 0.05  (largest — high risk, big dredge fuel)
Lower ────────────── $2650
```

Zone boundaries are calculated as:
```
Zone1 Floor = Upper - (Range / 3)
Zone2 Floor = Upper - (Range × 2/3)
Zone3 = everything below Zone2 Floor
```

### Zone Purpose

| Zone | Location | Lot Size | Purpose |
|---|---|---|---|
| Zone 1 | Upper third | Smallest | Quick profits, low exposure. The "money maker." |
| Zone 2 | Middle third | Medium | Profits feed the bucket for dredging |
| Zone 3 | Lower third | Largest | Deep positions. Zone 2/3 profits clear these via dredge. |

### Why Different Lot Sizes?

The deeper the price falls, the more distance each position needs to travel for recovery. Larger lots in Zone 3 mean each position earns more per point when price eventually rises, making recovery faster. However, they also mean more drawdown — this is why Guardian exists.

---

## 6. Condensing Grid Engine

### Expansion Coefficient

The `InpExpansionCoeff` controls how grid spacing changes from top to bottom:

| Coeff | Behavior | Use Case |
|---|---|---|
| `1.0` | Uniform gaps | Standard grid |
| `0.95` | Gaps shrink toward bottom | Dense bottom, protect deep positions |
| `1.05` | Gaps widen toward bottom | Wider bottom, save margin |

### Calculation

```
First Gap = Range / Levels  (if coeff = 1.0)
First Gap = Range × (1 - Coeff) / (1 - Coeff^Levels)  (if coeff ≠ 1.0)

For each level i:
  Price[i] = Price[i-1] - Current Gap
  TP[i]    = Price[i-1]   (TP is always the level above)
  Lot[i]   = Zone-based lot size
  Current Gap *= Coeff
```

### Grid Health Check

After calculation, the grid is validated:
- All prices must be positive and strictly descending
- All lots must be within `[MIN_LOT, MAX_LOT]`
- All step sizes must be positive
- All TPs must be above their level price

If validation fails, the bot retries up to 3 times (with 2-second delays) before halting.

---

## 7. Rolling Tail & Order Management

### The Problem

Placing all 45+ grid levels as pending orders simultaneously would:
- Consume excessive margin
- Create broker-side order management overhead
- Risk rejection on brokers with order limits

### The Solution: Rolling Tail

Executor only maintains `InpMaxPendingOrders` (default 20) pending BUY LIMITs at any time. These are the nearest levels below the current price.

```
Current Price: $2720

Active pending orders (20 nearest below price):
  Level 5  @ $2718  ← closest to price
  Level 6  @ $2714
  Level 7  @ $2710
  ...
  Level 24 @ $2630  ← farthest pending
  Level 25 @ $2625  ← NOT placed (tail deleted)
  ...
```

### How It Works

1. **Entry scan:** Each tick, Executor checks all levels. For unoccupied levels below the current ask price, it places BUY LIMIT orders (respecting the max pending limit).

2. **Tail trim:** If pending count exceeds `InpMaxPendingOrders`, the farthest orders (deepest levels) are deleted first.

3. **As price moves:**
   - **Price drops:** New levels enter the window, orders are placed. Farthest are trimmed.
   - **Price rises:** Filled positions hit virtual TP and close. The window shifts up.

### Order Cooldowns

- Minimum 1 second between order placements (`g_LastOrderTime`)
- Minimum 2 seconds between tail trims (`g_LastTailTime`)

---

## 8. Virtual Take-Profit System

### Why Virtual TP?

When `InpUseVirtualTP = true` (recommended), positions are closed programmatically instead of using broker-side TP orders.

**Benefits:**
- No TP order visible to the broker (reduces order clutter)
- TP logic can be modified without canceling/replacing orders
- Works consistently across all brokers regardless of TP rules

### How It Works

Each tick, `ManageExits()` scans all open positions:

```
For each position with magic = InpMagicNumber:
  1. Find its grid level index by matching open price (±40% of step size)
  2. If match found AND current Bid >= GridTPs[level]:
     → Close the position at market
     → Clear the level ticket
     → Log as TP_CLOSE
  3. If no match (orphaned position — PA23):
     → Find nearest grid level ABOVE open price
     → Use that level price as fallback TP
     → If current Bid >= fallback TP: close at market, log as TP_CLOSE_ORPHAN
```

The TP target for each level is the **price of the level above it**:
- Level 1 TP = Upper Price
- Level 2 TP = Level 1 Price
- Level N TP = Level N-1 Price

### Orphaned Position Fallback (PA23)

Positions placed under a previous grid configuration (before a Push to Live or grid shift) may not match any current grid level — their open price falls outside the ±40% tolerance of all GridPrices. Without the fallback, these positions would never close via virtual TP.

**PA23 fix:** When `GetLevelIndex()` returns -1, the fallback scans for the nearest grid level above the open price and uses it as the TP. Logged as `TP_CLOSE_ORPHAN` in the Expert log for easy identification.

**When this happens:** After any Push to Live that changes `InpExpansionCoeff`, `InpUpperPrice`, `InpLowerPrice`, or `InpGridLevels` — positions from the old grid config become orphaned until they close or are manually managed.

---

## 9. Bucket & Dredge System

### Concept

The bucket/dredge system is a **cash flow engine** that uses profits from Zone 2 and Zone 3 positions to close the deepest (worst-performing) position.

### Flow

```
Zone 2/3 position hits TP → Profit goes into "Bucket"
                              ↓
Bucket accumulates over time (48h window)
                              ↓
If Bucket > |Worst Position Loss|:
  → Close worst position (realize the loss)
  → Deduct loss from bucket
  → The level is now free for a new entry
```

### Bucket Details

| Concept | Description |
|---|---|
| **Source** | Only Zone 2 and Zone 3 closed profits feed the bucket |
| **Retention** | Profits expire after `InpBucketRetentionHrs` (48 hours) |
| **Survival ratio** | If balance < initial balance, only 50% of bucket is available for dredging |
| **Queue** | Bucket is a FIFO queue of {amount, time} entries |
| **Max items** | Capped at 1000 entries to prevent memory growth |

### Dredge Range Filter (`InpDredgeRangePct`)

The `InpDredgeRangePct` parameter (default 0.5) acts as a **distance filter**. A position is only eligible for dredging when the current price has moved far enough away from that position's open price — proving it is genuinely stuck.

```
Threshold Distance = Total Range × InpDredgeRangePct
Position Distance  = |Position Open Price - Current Bid|

Eligible only if: Position Distance > Threshold Distance
```

**Example: Range $2650-$2750 (100 pts), InpDredgeRangePct=0.5**
```
Threshold = 100 × 0.5 = 50 points

Position opened at $2720, current price = $2720 (just opened):
  dist = |2720 - 2720| = 0 pts  →  0 < 50  →  PROTECTED ✅ (reaches TP naturally)

Position opened at $2720, current price = $2660 (stuck):
  dist = |2720 - 2660| = 60 pts  →  60 > 50  →  ELIGIBLE ✅ (genuinely stuck)
```

**Key benefit:** New positions are always protected (dist ≈ 0 at open). Only positions where price has genuinely moved away — meaning the position is stuck — become eligible. This prevents the bucket from immediately dredging positions that would have closed profitably at TP.

**Parameter tuning:**
- `0.3` = more aggressive (price needs to move 30% of range away)
- `0.5` = balanced default (price needs to move 50% of range away)
- `0.6` = conservative (price needs to move 60% of range away — very strict)

### Worst Position Selection

Executor tracks the 3 worst positions (by unrealized P/L). Dredging always targets the worst (biggest loss). It skips positions that Guardian is already cannibalizing (checked via `DREDGE_TARGET` GV).

### Profit Scanning (Two-Pass Approach)

To correctly classify which zone a profit came from, Executor uses the position's **open price** (not close price):

1. **Pass 1:** Collect all closing deals from recent history
2. **Pass 2:** For each deal, use `HistorySelectByPosition()` to find the entry deal's open price
3. Classify by zone using the open price → only Zone 2/3 profits enter the bucket

---

## 10. Dynamic Grid (Upward Shift)

### Behavior

When price breaks above the grid's upper bound by a buffer amount, the entire grid shifts upward:

```
Trigger: Ask > Upper + (Range × InpUpShiftTriggerPct)
Shift:   Both Upper and Lower move up by (Range × InpUpShiftAmountPct / 100)
```

### Example

```
Grid: $2650 - $2750 (Range = $100)
Buffer: 0.10 × $100 = $10
Trigger: Ask > $2760

When triggered:
  Shift = $100 × 20% = $20
  New Upper: $2770
  New Lower: $2670
```

### What Happens During Shift

1. All pending orders are deleted
2. Grid boundaries updated
3. Zone floors shifted by the same amount
4. Grid is recalculated and remapped
5. Ghost lines redrawn
6. State saved to GlobalVariables

### Downward Extension: REMOVED

The grid does **not** extend downward. If price falls below the lower bound, the grid stays where it is. This prevents runaway exposure. Guardian is expected to handle below-range scenarios with hedging.

---

## 11. Guardian Coordination (Freeze Protocol)

### How It Works

Every `InpCoordinationCheckInterval` (5) seconds, Executor checks:

```
HEDGE_ACTIVE GV = 1.0?
  → Yes: early return (FREEZE: no new orders, no dredging)
  → No:  normal operation continues
```

### Dashboard Status During Freeze

When Guardian is hedging, the Executor dashboard shows:

```
Status: FROZEN  |  Guardian: ACTIVE (Hedging)
```

- **FROZEN** — Executor is paused (no new grid trades)
- **Guardian: ACTIVE (Hedging)** — explains why the Executor is frozen

When Guardian unwinds and sets `HEDGE_ACTIVE = 0`, the status returns to:

```
Status: RUNNING  |  Guardian: Standby
```

> **PA22 — Peak Balance Reset on Unfreeze:** During a Guardian freeze, the Executor's hard stop check is bypassed entirely (early return). Equity can drift below the hard stop floor for hours while Guardian is hedging. Without the fix, the first tick after unfreeze would immediately trigger `CloseAllPositions()` at the worst price.
>
> **Fix:** On the `HEDGE_ACTIVE 1→0` transition, `g_PeakEquity` is reset to the current account balance. Losses that occurred while Guardian was defending are "forgiven" — Guardian was already the active defense. The hard stop floor is recalculated from the post-hedge balance, giving the grid a fair baseline to resume trading.

### What Gets Frozen

| Function | Frozen? |
|---|---|
| New BUY LIMIT placement | Yes |
| Virtual TP closes | **No** (positions can still close for profit) |
| Rolling tail management | Still runs |
| Dynamic grid shift | Yes |
| Bucket/dredge | Yes (sort of — dredge skipped, bucket still collects) |
| Heartbeat publishing | **No** (Guardian needs to see Executor is alive) |
| Peak equity tracking | **No** (hard stop level can still rise) |

### What Executor Publishes

| GV Key | Frequency | Data |
|---|---|---|
| `205001_SG_NET_EXPOSURE` | Every 10s | Net long volume (sum of all BUY lots) |
| `205001_SG_HEARTBEAT` | Every 1s | Current timestamp |
| `205001_SG_BOT_ACTIVE` | Every 10s | 1.0 if active and not paused |
| `205001_SG_DREDGE_TARGET` | On change | Ticket of position being dredged |
| `205001_SG_UPPER/LOWER/LEVELS` | On save | Grid boundaries and level count |

---

## 12. Remote Optimization (Planner Push)

### How It Works

When the Planner clicks "PUSH TO LIVE":
1. Planner writes optimization GVs: `OPT_NEW_UPPER`, `OPT_NEW_LOWER`, `OPT_NEW_LEVELS`, `OPT_NEW_COEFF`, `OPT_NEW_LOT1/2/3`, `MAX_RISK_PCT`
2. Planner writes `OPT_CMD_PushTime` with current timestamp
3. Executor checks every 10 seconds for new push times
4. If new push detected and `InpAllowRemoteOpt = true`:
   a. Pause trading
   b. Delete all pending orders
   c. Update grid boundaries, levels, coefficient
   d. Update runtime lot sizes (if provided)
   e. **Recalculate zone floors** (critical fix applied 2026-02-11)
   f. Rebuild grid and remap positions
   g. Resume trading

### Lot Override

Runtime lot sizes (`g_RuntimeLot1/2/3`) override the input parameters. They persist via GlobalVariables across restarts. A Planner push updates these runtime values without requiring recompilation.

### Safety

- Lot values are validated: must be within `[MIN_LOT, MAX_LOT]`
- Grid is validated after rebuild (health check)
- The push is applied only once (tracked by `OPT_LAST_APPLIED` GV)

---

### Parameter Ownership — What Planner Controls vs What You Must Set

Understanding which parameters Planner manages and which ones you must configure manually is critical. **If you only rely on PUSH TO LIVE and never review the manual parameters, your risk settings may be at defaults that don't match your account.**

#### Parameters Set by Planner (PUSH TO LIVE — 7 values)

| Parameter | Notes |
|---|---|
| `InpUpperPrice` | Grid upper boundary |
| `InpLowerPrice` | Grid lower boundary |
| `InpGridLevels` | Number of grid levels |
| `InpExpansionCoeff` | Condensing coefficient |
| `InpLotZone1` | Zone 1 lot size |
| `InpLotZone2` | Zone 2 lot size |
| `InpLotZone3` | Zone 3 lot size |

#### Parameters Set by Planner EXPORT .SET (partial — calculated values)

| Parameter | How Calculated |
|---|---|
| `InpHardStopDDPct` | Set to `InpMaxRiskPerc` (same % used for Guardian hard stop) |
| `InpDredgeRangePct` | From Planner's `InpDredgeMinRangePerc ÷ 100` |
| `InpMaxSpread` | `CurrentSpread × SpreadBuffer × 1.5` |
| `InpMaxOpenPos` | Set to `CalcLevels` |
| `InpStartAtUpper` | Hardcoded `false` |
| `InpUseBucketDredge` | Hardcoded `true` |
| `InpUseVirtualTP` | Hardcoded `true` |
| `InpMagicNumber` | From Planner's `InpExecutorMagic` |

> Note: EXPORT .SET is optional. If you don't use it, all of the above must be set manually.

#### 🔴 Parameters You MUST Set Manually — Never Touched by Planner

These are never written by PUSH TO LIVE or EXPORT .SET. They retain their defaults (or whatever you typed) indefinitely:

| Parameter | Default | Risk Level | Recommended Action |
|---|---|---|---|
| **InpEnableDynamicGrid** | `true` | 🔴 Critical | Keep `true` — disabling this prevents the grid from shifting up with rising price. |
| **InpUpShiftTriggerPct** | `0.10` | 🟡 Important | Shift triggers when price is 10% above upper. Keep default unless range is very wide. |
| **InpUpShiftAmountPct** | `20.0` | 🟡 Important | Grid shifts up by 20% of range. Keep default. |
| **InpMaxPendingOrders** | `20` | 🟡 Important | Rolling tail size. `20` is conservative, `30` is more aggressive. |
| **InpBucketRetentionHrs** | `48` | 🟡 Important | How long Zone 2/3 profits stay in bucket. Increase to `72` for slow markets. |
| **InpSurvivalRatio** | `0.5` | 🟡 Important | Only 50% of bucket used for dredging when balance < initial. Keep `0.5`. |
| **InpEnableGuardianCoordination** | `true` | 🔴 Critical | Must be `true` — disabling this breaks the Guardian freeze protocol. |
| **InpAllowRemoteOpt** | `true` | 🔴 Critical | Must be `true` — disabling this blocks all PUSH TO LIVE updates from Planner. |
| **InpCoordinationCheckInterval** | `5` | 🟢 Low | Seconds between Guardian checks. Keep at `5`. |
| **InpEnablePushNotify** | `true` | 🟢 Low | Mobile push alerts. Set per your preference. |
| **InpEnableEmailNotify** | `false` | 🟢 Low | Email alerts. Set per your preference. |
| **InpEnableTradeLog** | `true` | 🟢 Low | Detailed trade logging. Keep `true` for diagnostics. |
| **InpResetState** | `false` | 🔴 Critical | Set `true` only for fresh deployment — resets all saved state. Always set back to `false` after. |
| **InpMagicNumber** | `205001` | 🔴 Critical | Must match Planner's `InpExecutorMagic` and Guardian's `InpManualGridMagic`. |
| **InpComment** | `SmartGrid_v10` | 🟢 Low | Trade comment on broker side. Leave as-is. |
| Dashboard settings | various | 🟢 Low | Visual only — no trading impact. |

> **Key takeaway:** After every PUSH TO LIVE, **7 parameters** are updated: upper/lower/levels/coeff + lot1/lot2/lot3. The hard stop (`InpHardStopDDPct`) tracks peak realized balance automatically — floor rises only when real profits are banked, not on temporary equity spikes.

---

## 13. Dashboard

Executor displays a real-time chart panel in the top-left corner:

```
  GRIDBOT-EXECUTOR v10.08
  Status: RUNNING  |  Guardian: Standby
  ___________________________________________
  Balance: $10000  |  Equity: $9850
  DD: 1.50%  |  Positions: 12/45
  ___________________________________________
  Grid: $2650.00 - $2750.00  |  Coeff: 1.0000
  Price: $2720.50  |  In Range
  Break Even: $2705.30
  ___________________________________________
  Bucket: $145.20  |  Dredged: $320.00
  Net Exposure: 0.36 lots
  ___________________________________________
  Today: $43.60 (0.44%)
  Week:  $208.78 (2.09%)
  Win Rate: 15/18 (83%)
  ___________________________________________
  Zone 1: 5 pos  |  $25.40
  Zone 2: 4 pos  |  -$12.30
  Zone 3: 3 pos  |  -$85.60
  ___________________________________________
  Worst Positions:
   1. L38: -$42.50 @ $2662.30
   2. L35: -$28.10 @ $2670.80
   3. L32: -$15.00 @ $2679.40
  ___________________________________________
  ── GUARDIAN ──────────────────────────────
  ♥ Alive: 3s ago
  STANDBY  (Monitoring)

  Peak: $178,244  |  DD: 21.87%
  ___________________________________________
  ── PLANNER ───────────────────────────────
  Last Push: 4h 12m ago
```

### How P/L Is Calculated

| Metric | Calculation |
|---|---|
| **Today P/L** | Sum of all closing deals (DEAL_ENTRY_OUT) with matching magic since start of current day (`iTime(PERIOD_D1, 0)`) |
| **Week P/L** | Same but since start of current week (`iTime(PERIOD_W1, 0)`) |
| **Bucket** | Sum of unexpired Zone 2/3 profits (48h window) minus dredge spending |
| **Win Rate** | Winning deals / Total deals today |
| **DD%** | `(Balance - Equity) / Balance × 100` |
| **Break Even** | Volume-weighted average entry price of all open positions |

### Ghost Lines

Horizontal lines drawn at each grid level price, color-coded by zone:
- Blue (Zone 1) — upper third
- Orange (Zone 2) — middle third
- Red (Zone 3) — lower third

### Break Even Line

A yellow horizontal line at the break-even price. When the current bid is above this line, the total grid is in profit.

---

## 14. State Persistence & Recovery

### What Gets Saved

| GV Key | Data |
|---|---|
| `205001_SG_UPPER` | Current grid upper boundary |
| `205001_SG_LOWER` | Current grid lower boundary |
| `205001_SG_LEVELS` | Number of grid levels |
| `205001_SG_COEFF` | Active expansion coefficient |
| `205001_SG_BUCKET` | Current bucket total ($) |
| `205001_SG_LOT1/2/3` | Runtime lot sizes |
| `205001_SG_LAST_UPDATE` | Timestamp |

### On Restart

1. Executor checks for saved state GVs
2. If found → loads boundaries, levels, coefficient, bucket, lots
3. Recalculates grid geometry
4. Maps existing broker positions to grid levels via `MapSystemToGrid()`
5. Resumes trading from where it left off

### Resetting State

Set `InpResetState = true` and restart. This deletes all saved GVs and starts fresh with input parameters. **Warning:** This does NOT close existing positions — it just resets the grid memory. Existing positions may become orphaned.

---

## 15. Safety Mechanisms

### 1. Hedging Account Guard

On init, Executor checks the account margin mode. If the account is NETTING or EXCHANGE (not hedging), it refuses to start:
```
CRITICAL ERROR: Account must be HEDGING type.
```

### 2. Instance Guard

Only one Executor per symbol+magic is allowed. Prevents accidental double-attachment.

### 3. Hard Stop (Dynamic)

Tracks **peak balance** (realized profits only) continuously. Hard stop floor = `g_PeakEquity × (1 - InpHardStopDDPct / 100)`. When current **equity** drops below the floor, Executor closes all positions and halts.

- Floor **rises only when real profits are banked** (balance increases) — immune to temporary floating equity spikes from open grid positions
- Floor **holds** during drawdown (never drifts dangerously close to current equity)
- Trigger checks **equity** so the stop fires during live drawdown
- Peak balance continues tracking even during Guardian freeze
- Peak and floor persist across restarts via `PEAK_EQUITY` GlobalVariable
- Published as `HARD_STOP_LEVEL` GV for Planner/Guardian visibility

### 4. Spread Filter

Orders are only placed when `(Ask - Bid) / Point <= InpMaxSpread`. This prevents placing orders during high-spread events (news, rollover).

### 5. Margin Check

Before each BUY LIMIT, Executor calculates required margin and verifies free margin is at least 110% of that amount.

### 6. Price Staleness Detection

If the last tick is older than 30 seconds, Executor skips the tick (possible disconnect).

### 7. Seatbelt Safety Check

Before placing each order, Executor scans all existing positions to ensure no position already exists within `GridStepSize × 0.4` of the target price. Prevents duplicate entries.

### 8. Grid Validation Retry

Grid health is checked after calculation. If it fails (possible during reconnection), Executor retries up to 3 times with 2-second delays.

---

## 16. Log System

### Where to Find Logs

| Location | What It Shows |
|---|---|
| **Experts tab** (bottom of MT5) | All `Print()` output — grid events, sync, errors |
| **Journal tab** | MT5 terminal system messages |
| **History tab** | Completed trades with profit/loss |
| **Trade log** (via `LogTrade()`) | Formatted entries: `BUY_LIMIT`, `TP_CLOSE`, `DREDGED`, `GRID_SHIFT_UP` |

### Log Format

```
2026.02.11 14:30:00 | BUY_LIMIT | L12 | $2695.50 | 0.02 lots | #54321
2026.02.11 14:35:00 | TP_CLOSE  | L12 | $2698.30 | 0.00 lots | #54321
2026.02.11 14:40:00 | DREDGED   | L38 | $0.00    | 42.50 lots| #54290
```

### Key Log Messages

| Message | Meaning |
|---|---|
| `SYNC: Level X relinked #Y` | SyncMemory found an existing position/order for a level |
| `SYNC: Level X cleared` | Level's ticket no longer exists (order canceled or position closed) |
| `FROZEN: Guardian hedge protection active` | Executor is paused by Guardian (dashboard shows `Status: FROZEN \| Guardian: ACTIVE (Hedging)`) |
| `DYNAMIC GRID: Shifting UP` | Upward grid shift triggered |
| `OPTIMIZATION APPLIED` | Planner's PUSH TO LIVE was received and applied |
| `DREDGED: Level X` | Worst position closed using bucket funds |
| `WARNING: Price below grid` | Price has fallen below the grid's lower boundary |

---

## 17. Troubleshooting

### No Orders Being Placed

**Check:**
1. Is `IsTradingActive = true`? (Check for equity stop or grid failure)
2. Is Guardian freezing? (check `HEDGE_ACTIVE` GV — Guardian sets 1.0 when hedging)
3. Is spread > `InpMaxSpread`? (Check spread in Market Watch)
4. Is free margin sufficient? (Check Account > Free Margin)
5. Has `InpMaxOpenPos` been reached?
6. Is price above the grid? (Orders are only placed below current price)

### Duplicate Positions at Same Level

This was a known bug fixed in v10.02. The fix involves:
1. **SyncMemoryWithBroker** uses a unified fast+slow path (no clear-then-scan race)
2. **Seatbelt check** in ManageGridEntry prevents orders at occupied prices
3. Both use `GridStepSize × 0.4` tolerance for price matching

If you still see duplicates, check the Experts log for `SYNC:` messages.

### Zone/Lot Mismatch

If trades have wrong lot sizes for their zone:
1. Check if zone floors were recalculated after a Planner push (should show `OPTIMIZATION APPLIED` in log)
2. Check runtime lots: `g_RuntimeLot1/2/3` via GlobalVariables window
3. Zone floors may be stale from a previous session — use `InpResetState = true` to force recalculation

### Grid Validation Failed

**Cause:** Grid prices, lots, or TPs are invalid (e.g., negative, out of order, out of lot range).
**Fix:**
- Check that `InpUpperPrice > InpLowerPrice`
- Check that `InpGridLevels` is between 5 and 200
- Verify MIN_LOT/MAX_LOT on your broker (Market Watch → right-click → Specification)

### High Memory Usage

If MT5 uses excessive memory:
- Bucket queue is capped at 1000 items (fixed in v10.02)
- Reduce `InpBucketRetentionHrs` to expire entries faster
- SyncMemory slow-path is rate-limited to every 2 seconds

---

## 18. Configuration Examples

### Gold (XAUUSD) — Conservative

```
InpUpperPrice = 2750.0
InpLowerPrice = 2650.0
InpGridLevels = 45
InpExpansionCoeff = 1.0
InpLotZone1 = 0.01
InpLotZone2 = 0.02
InpLotZone3 = 0.04
InpMaxPendingOrders = 15
InpDredgeRangePct = 0.5
InpHardStopDDPct = 25.0    // Hard stop at 25% DD from peak balance
```

### Gold (XAUUSD) — Aggressive

```
InpUpperPrice = 2800.0
InpLowerPrice = 2600.0
InpGridLevels = 60
InpExpansionCoeff = 0.98   // Denser at bottom
InpLotZone1 = 0.04
InpLotZone2 = 0.08
InpLotZone3 = 0.20
InpMaxPendingOrders = 25
InpDredgeRangePct = 0.6
```

### BTC (BTCUSDm) — Wider Range

```
InpUpperPrice = 72000.0
InpLowerPrice = 60000.0
InpGridLevels = 50
InpExpansionCoeff = 1.02   // Wider at bottom (BTC has big moves)
InpLotZone1 = 0.01
InpLotZone2 = 0.02
InpLotZone3 = 0.05
InpMaxPendingOrders = 20
InpMaxSpread = 5000        // BTC has wider spreads
```

---

*Generated for GridBot-Executor v10.08 Integrated Edition. Last updated: 2026-02-28.*
