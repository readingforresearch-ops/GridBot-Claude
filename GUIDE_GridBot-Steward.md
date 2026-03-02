# GridBot-Steward v1.0 — User Guide

## Table of Contents

1. [Overview](#1-overview)
2. [How It Works](#2-how-it-works)
3. [Installation & Setup](#3-installation--setup)
4. [Input Parameters Reference](#4-input-parameters-reference)
5. [Grid Engine](#5-grid-engine)
6. [Hedge Defense System](#6-hedge-defense-system)
7. [Freeze Mechanism (Unified)](#7-freeze-mechanism-unified)
8. [Cannibalism (Loss Shifting)](#8-cannibalism-loss-shifting)
9. [Unwind & Recovery Logic](#9-unwind--recovery-logic)
10. [Bucket & Dredge System](#10-bucket--dredge-system)
11. [Dynamic Grid (Upward Shift)](#11-dynamic-grid-upward-shift)
12. [Two-Tier Hard Stop](#12-two-tier-hard-stop)
13. [Dashboard (Unified HUD)](#13-dashboard-unified-hud)
14. [State Persistence & Recovery](#14-state-persistence--recovery)
15. [Planner Integration (PUSH TO LIVE)](#15-planner-integration-push-to-live)
16. [Log System](#16-log-system)
17. [Troubleshooting](#17-troubleshooting)
18. [Migration from Executor + Guardian](#18-migration-from-executor--guardian)

---

## 1. Overview

**GridBot-Steward** ("The Steward") is a unified Expert Advisor that combines the grid trading engine and the hedge defense system into a single process. It replaces the two-bot setup (Executor + Guardian) without changing the strategy or risk model.

**Key responsibilities:**
- Calculate and maintain a condensing BUY LIMIT grid across a price range
- Detect drawdown in real-time and deploy staggered SELL hedges
- Freeze new grid entries the moment a hedge is active (zero latency)
- Cannibalize hedge profits to close the worst-performing grid positions
- Unwind the hedge automatically when the market recovers
- Execute two-tier hard stops: grid-only stop (25% DD) and nuclear stop (45% DD)
- Operate the bucket/dredge cash-flow engine
- Accept remote parameter updates from GridBot-Planner (PUSH TO LIVE)

**What Steward does NOT do:**
- Does not calculate optimal parameters (Planner's job)
- Does not extend the grid downward
- Does not require a separate Guardian or Executor to run alongside it

**Relationship to other bots:**
- **GridBot-Planner:** Stays unchanged. Reads Steward's GVs and pushes optimization commands exactly as before.
- **GridBot-Executor v10.11 + Guardian v3.15:** Remain untouched. Can be restarted at any time as a rollback.

---

## 2. How It Works

### Lifecycle

```
OnInit:
  1. Hedging account check (must be HEDGING type)
  2. Instance guard (prevents duplicate Steward on same symbol)
  3. Input validation (range, levels, coefficient, triggers, ratios)
  4. Initialize two CTrade instances (tradeGrid + tradeHedge)
  5. Load saved grid state from GlobalVariables (or start fresh)
  6. Calculate condensing grid geometry
  7. Map existing broker positions to grid levels
  8. Load saved hedge state from GlobalVariables
  9. Calculate effective hedge thresholds (with optional risk scaling)
  10. Publish coordination data for Planner
  11. Draw ghost lines on chart

OnTick (every tick):
  Phase 0:  Heartbeat publish (always first — no bypass)
  Phase 1:  If grid hard stop fired → return (hedge still runs!)
  Phase 2:  Price staleness guard (skip if data >30s old)
  Phase 3:  Track peak equity for hedge DD calculations
  Phase 4:  Ultimate hard stop check (close everything at 45% DD)
  Phase 5:  Determine desired hedge stage from current DD
  Phase 6:  Hedge management every 5s (execute/verify/unwind/cannibalism/duration)
  Phase 7:  Freeze check — if hedge active: publish Planner data, return
  Phase 8:  Grid hard stop check (balance-peak-based)
  Phase 9:  Grid operations (shift / sync / tail / entry / exits / dredge)
  Phase 10: Publish coordination data for Planner

OnTimer (every 1 second):
  - Calculate dashboard statistics
  - Update unified HUD on chart
```

### Decision Flow

```
DD < T1 (30%)   → Grid runs normally, hedge on standby
DD >= T1 (30%)  → Stage 1: SELL hedge at 30% of grid net volume
DD >= T2 (35%)  → Stage 2: Add SELL, total ~60% of grid net volume
DD >= T3 (40%)  → Stage 3: Add SELL, total ~95% of grid net volume
DD >= Ultimate (45%) → NUCLEAR: close grid + hedge, halt everything

DD < SafeUnwind (20%) + in range + hedge profitable + hold time met
                → UNWIND: close hedge, unfreeze grid, resume
```

### Why Unified is Better

With Executor + Guardian, the freeze signal traveled via GlobalVariables with a 1-5 second polling gap. A BuyLimit order could be placed in that gap. In Steward, the freeze is a **local boolean** (`g_HedgeActive`). The moment the hedge executes, `g_HedgeActive` becomes `true`. The next BuyLimit attempt in ManageGridEntry checks it first — zero latency, zero gap.

---

## 3. Installation & Setup

### Prerequisites
- MetaTrader 5 with a **hedging** account (Exness recommended)
- AutoTrading enabled in MT5 toolbar
- Expert Advisors permitted on the account
- GridBot-Planner attached separately on any chart (same or different)

### Step 1: Copy the File
Place `GridBot-Steward_v1.0.mq5` in:
```
MetaTrader 5\MQL5\Experts\
```

### Step 2: Compile
Open MetaEditor → File → Open → select the file → F7 to compile. Ensure zero errors.

### Step 3: Attach to Chart
- Open a chart of your instrument (e.g., XAUUSDm)
- Drag **GridBot-Steward** from Navigator → Expert Advisors
- Set input parameters (see Section 4)
- Click OK

### Step 4: Verify Startup
Check the Experts tab for:
```
GRIDBOT-STEWARD v1.0 — UNIFIED EDITION
Grid Engine + Hedge Defense in One
Grid: 2750.00 - 2650.00 (45 levels)
Hedge: T1=30.0% T2=35.0% T3=40.0% Stop=45.0%
```

### Instance Guard
Only one Steward can run per symbol/magic combination. A second attach attempt will show:
```
ERROR: Another Steward (magic=205001) already running on XAUUSDm
```

### Running Alongside Old Bots
**Do not run Steward alongside Executor or Guardian on the same magic numbers.** The GV namespace is shared — two bots writing the same keys will conflict. Use Steward OR the old pair, not both simultaneously.

---

## 4. Input Parameters Reference

### Group 0 — System Control

| Parameter | Default | Description |
|---|---|---|
| `InpResetState` | `false` | Set `true` to wipe all saved GV state and start fresh |
| `InpGridMagic` | `205001` | Magic number for all grid orders. Must match Planner's `InpExecutorMagic` |
| `InpHedgeMagic` | `999999` | Magic number for all hedge orders |
| `InpComment` | `"Steward_v1"` | Order comment prefix |

> **Warning:** Changing magic numbers after running will orphan existing positions (they won't be recognized).

### Group 1 — Grid Settings

| Parameter | Default | Description |
|---|---|---|
| `InpUpperPrice` | `2750.0` | Top of grid range. Ignored if resuming from saved state. |
| `InpLowerPrice` | `2650.0` | Bottom of grid range. Ignored if resuming from saved state. |
| `InpGridLevels` | `45` | Number of grid levels (5–200) |
| `InpExpansionCoeff` | `1.0` | Condensing coefficient. 1.0 = equal spacing. <1.0 = tighter at top. >1.0 = tighter at bottom. |
| `InpStartAtUpper` | `false` | `true` = first level placed at upper bound. `false` = first level one step below upper. |

### Group 2 — Dynamic Grid (Upward Shift Only)

| Parameter | Default | Description |
|---|---|---|
| `InpEnableDynamicGrid` | `true` | Enable automatic upward grid shift when price breaks out |
| `InpUpShiftTriggerPct` | `0.10` | Shift triggers when price > upper + (range × this %). At 0.10 the buffer is 0.1% of range. |
| `InpUpShiftAmountPct` | `20.0` | Amount to shift upper and lower bounds, as % of current range |

> The grid never shifts downward. Downward extension was removed as a risk control measure.

### Group 3 — Rolling Tail & Execution

| Parameter | Default | Description |
|---|---|---|
| `InpMaxPendingOrders` | `20` | Maximum simultaneous BUY LIMIT orders. Older levels deleted first when exceeded. |
| `InpMaxOpenPos` | `100` | Maximum simultaneous open positions (hard cap) |
| `InpMaxSpread` | `2000` | Grid orders blocked if spread exceeds this (in points). XAUUSDm normal ~50pts. |

### Group 4 — Stepped Volume Zones

The grid is divided into three equal zones (by price, top-to-bottom):

| Parameter | Default | Description |
|---|---|---|
| `InpLotZone1` | `0.01` | Lot size for Zone 1 (top third — lower risk) |
| `InpLotZone2` | `0.02` | Lot size for Zone 2 (middle third) |
| `InpLotZone3` | `0.05` | Lot size for Zone 3 (bottom third — highest exposure) |

Lots can be updated live via Planner PUSH TO LIVE without restarting.

### Group 5 — Cash Flow Engine (The Bucket)

| Parameter | Default | Description |
|---|---|---|
| `InpUseBucketDredge` | `true` | Enable the bucket/dredge cash flow system |
| `InpBucketRetentionHrs` | `48` | Hours before old bucket credits expire |
| `InpSurvivalRatio` | `0.5` | When balance < initial balance, only this fraction of bucket is available for dredging |
| `InpDredgeRangePct` | `0.5` | Price must be at least this % of range away from worst position before dredge fires |
| `InpUseVirtualTP` | `true` | `true` = Steward manages exits in code (no broker SL/TP). Recommended. |

### Group 6 — Hedge Defense

| Parameter | Default | Description |
|---|---|---|
| `InpHedgeTrigger1` | `30.0` | DD% to open Stage 1 hedge |
| `InpHedgeRatio1` | `0.30` | Stage 1 volume = grid net exposure × this ratio |
| `InpHedgeTrigger2` | `35.0` | DD% to open Stage 2 hedge |
| `InpHedgeRatio2` | `0.30` | Stage 2 volume increment |
| `InpHedgeTrigger3` | `40.0` | DD% to open Stage 3 hedge |
| `InpHedgeRatio3` | `0.35` | Stage 3 volume increment |
| `InpUltimateHardStopDD` | `45.0` | Close ALL positions (grid + hedge) at this DD%. Nuclear option. |
| `InpEnableCannibalism` | `true` | Enable hedge profit → close worst grid position |
| `InpPruneThreshold` | `100.0` | Minimum hedge profit ($) before cannibalism fires |
| `InpPruneBuffer` | `20.0` | Safety buffer ($) — hedge profit must exceed loss + buffer |
| `InpSafeUnwindDD` | `20.0` | Close hedge when DD drops below this % (and in range, and profitable) |
| `InpMinStageHoldMins` | `15` | Minimum minutes each stage must be open before SafeUnwind can close it |
| `InpMinFreeMarginPct` | `150.0` | Required free margin % before hedge order is placed |
| `InpMaxHedgeSpread` | `3500` | Hedge orders blocked if spread exceeds this (XAUUSDm ~50pts, BTCUSDm ~1800pts) |
| `InpMaxHedgeDurationHrs` | `72` | Force-close hedge if it has been open this many hours |
| `InpAutoScaleToRisk` | `true` | If Planner publishes MAX_RISK_PCT, scale all thresholds proportionally |
| `InpFullCheckInterval` | `5` | Seconds between hedge management checks (execute/unwind/cannibalism) |

> **Ratio Constraint:** `Ratio1 + Ratio2 + Ratio3` must be ≤ 1.0 (checked at startup).
> At 0.30+0.30+0.35 = 0.95 → 95% of grid exposure is hedged at Stage 3.

### Group 7 — Risk & Safety

| Parameter | Default | Description |
|---|---|---|
| `InpHardStopDDPct` | `25.0` | Grid hard stop. Closes grid-only when equity drops this % below **peak balance**. Hedge continues. |

### Group 8 — Dashboard & Visuals

| Parameter | Default | Description |
|---|---|---|
| `InpShowDashboard` | `true` | Show unified HUD panel on chart |
| `InpShowGhostLines` | `true` | Draw horizontal lines at each grid level (color-coded by zone) |
| `InpShowBreakEven` | `true` | Draw yellow break-even line (weighted average entry price) |
| `InpDashCorner` | `CORNER_LEFT_UPPER` | Panel position on chart |
| `InpColorZone1` | `DodgerBlue` | Ghost line color for Zone 1 levels |
| `InpColorZone2` | `Orange` | Ghost line color for Zone 2 levels |
| `InpColorZone3` | `Red` | Ghost line color for Zone 3 levels |

### Group 9 — Logging & Notifications

| Parameter | Default | Description |
|---|---|---|
| `InpEnableTradeLog` | `true` | Print trade events to MT5 Experts log |
| `InpEnableFileLog` | `true` | Write events to daily CSV file (`GridBot_{Symbol}_{YYYY-MM-DD}.csv`) |
| `InpEnableDetailedLog` | `true` | Enable verbose internal logs (rate-limit checks, exposure, etc.) |
| `InpEnablePushNotify` | `true` | Send MT5 push notifications for alerts |
| `InpEnableEmailNotify` | `false` | Send email alerts |
| `InpAllowRemoteOpt` | `true` | Accept Planner PUSH TO LIVE optimization commands |
| `InpEnableStateRecovery` | `true` | Save/restore state via GlobalVariables across restarts |

---

## 5. Grid Engine

### Condensing Grid Geometry

Steward builds a **BUY LIMIT** grid from `InpUpperPrice` down to `InpLowerPrice`. Each level fills when price drops to it, and takes profit when price rises to the next level above.

The `InpExpansionCoeff` controls spacing:
- `1.0` — equal spacing (uniform grid)
- `< 1.0` — closer spacing toward the bottom (more levels in low zones)
- `> 1.0` — wider spacing toward the bottom

```
Level 1  ─── $2748 (TP at $2750)
Level 2  ─── $2736 (TP at $2748)
Level 3  ─── $2722 (TP at $2736)
  ...
Level 45 ─── $2650 (TP at ~$2664)
```

### Zone Assignment

Zones are calculated once at startup from the original grid range:
```
Zone 1: Upper 1/3 of range  (e.g., $2717 - $2750)  — small lots
Zone 2: Middle 1/3          (e.g., $2683 - $2717)  — medium lots
Zone 3: Lower 1/3           (e.g., $2650 - $2683)  — large lots
```

Zone boundaries do **not** move when the grid shifts upward. This ensures Zone 3 always represents the deepest historical levels.

### Virtual Take-Profit

When `InpUseVirtualTP=true`, no broker TP is set on positions. Instead, Steward checks on each tick whether `bid >= GridTPs[level]` and closes the position in code. This prevents broker-side TP rejections and allows precise exit management.

### Orphaned Position TP Fallback (PA23)

If a position's open price doesn't match any current grid level (e.g., after a PUSH TO LIVE grid shift), Steward finds the nearest grid level above the open price and uses it as the TP. This prevents profitable positions from being stranded indefinitely.

### Rolling Tail

Steward maintains at most `InpMaxPendingOrders` active BUY LIMITs at any time. When new levels need orders, the deepest pending orders (furthest from price) are deleted to make room. This keeps the active window near current price.

### SyncMemoryWithBroker

Every 2 seconds, Steward reconciles its internal level-to-ticket map against the actual broker order/position state. This handles cases where the broker closed an order or position without Steward's knowledge (e.g., margin call, stop out, manual intervention).

---

## 6. Hedge Defense System

The hedge is a SELL position (or positions across 3 stages) that offsets grid losses when drawdown deepens.

### Drawdown Calculation

DD is calculated against a **peak equity** baseline (`g_HedgePeakEquity`):
```
currentDD% = (peakEquity - currentEquity) / peakEquity × 100
```

Peak equity rises whenever current equity exceeds the previous peak. It does not fall.

### Stage Escalation

| Stage | Trigger | Cumulative Hedge |
|---|---|---|
| Stage 1 | DD >= 30% | 30% of grid net volume |
| Stage 2 | DD >= 35% | 60% of grid net volume |
| Stage 3 | DD >= 40% | 95% of grid net volume |

Each stage opens a new SELL ticket (`g_HedgeTickets[0/1/2]`). Stage 2 adds to Stage 1, Stage 3 adds to Stage 2. The hedge volume is calculated as:
```
targetVol = gridNetExposure × cumulativeRatio
volToAdd  = targetVol - currentHedgeVolume
```

### Hedge Guards (Pre-flight)

Before opening/escalating, Steward checks:
1. **Net exposure > 0** — no grid positions means no hedge needed
2. **Spread ≤ InpMaxHedgeSpread** — blocked during wide-spread conditions
3. **Free margin ≥ InpMinFreeMarginPct** — blocked if margin is too tight

### Stage Open Times

Each stage records its open time (`g_StageOpenTime[]`). SafeUnwind cannot close a stage until it has been open for `InpMinStageHoldMins` (PA21). This prevents closing a Stage 3 hedge that was opened at the price bottom and would immediately unfreeze the grid at the worst moment.

---

## 7. Freeze Mechanism (Unified)

**The freeze is a single local boolean: `g_HedgeActive`.**

When a hedge is opened:
```mql5
g_HedgeActive = true;  // Set inside ExecuteHedge()
```

In `ManageGridEntry()`, before placing any BuyLimit:
```mql5
if(g_HedgeActive) continue;  // Skip immediately — no GV read, no delay
```

In `OnTick()` Phase 7:
```mql5
if(g_HedgeActive) {
    PublishCoordinationData();
    CheckForOptimizationUpdates();
    return;  // Skip all grid operations
}
```

**Result:** The moment a hedge executes, the next tick's BuyLimit loop skips every level. Timing gap = zero. This eliminates the 1-5 second coordination window that existed between Executor and Guardian.

---

## 8. Cannibalism (Loss Shifting)

When the hedge is profitable, Steward can use that profit to close the worst-performing grid position, shifting the loss off the account.

### Trigger Conditions
1. `InpEnableCannibalism = true`
2. Total hedge P/L > `InpPruneThreshold` ($100 default)
3. Hedge profit > worst grid position loss + `InpPruneBuffer` ($20 default)

### Order of Operations (PA19)

**Grid close FIRST, hedge reduction SECOND:**

1. Find worst-performing grid position by P/L
2. Close that grid position via `tradeGrid.PositionClose()`
3. If close fails → return immediately (hedge unchanged, conservative)
4. Recalculate new grid net exposure
5. Reduce hedge proportionally to match new exposure

The PA19 fix ensures the worst-case failure is an over-hedged account (conservative) rather than an under-hedged account (dangerous).

---

## 9. Unwind & Recovery Logic

### SafeUnwind Conditions (ALL must be true)

| Condition | Reason |
|---|---|
| Hedge active and positions exist | Obvious |
| Current price is within grid range | Price below range = still in drawdown territory |
| DD < `InpSafeUnwindDD` (20%) | Enough recovery happened |
| Total hedge P/L > 0 (PA21 Fix 1) | Closing an underwater hedge unfreezes grid into unprotected bottom |
| All stages held ≥ `InpMinStageHoldMins` (PA21 Fix 2) | Prevents premature close on first bounce |

### On Successful Unwind

1. All hedge positions closed via `tradeHedge.PositionClose()`
2. `g_HedgeActive = false` — grid operations resume immediately next tick
3. `g_HedgePeakEquity` reset to current equity
4. `g_PeakBalance` reset to current balance (PA22 — forgives losses during hedge period)
5. New grid hard stop floor calculated from post-hedge balance

### PA22: Peak Balance Reset on Unfreeze

During the hedge period, the grid hard stop check is bypassed (Phase 7 returns early). Equity can drift well below the hard stop floor. Without PA22, the first tick after unfreeze would immediately fire the grid hard stop at the worst price. The fix resets `g_PeakBalance` to current balance on unfreeze, so the new 25% floor is calculated from the post-hedge reality.

### Duration Limit

If the hedge has been active for `InpMaxHedgeDurationHrs` (72 hours default), Steward force-closes it regardless of P/L or DD level. This prevents a permanently frozen account.

---

## 10. Bucket & Dredge System

### Concept

The Bucket accumulates Zone 2 and Zone 3 profits. When the bucket has enough cash and a deep Zone 3 position has moved far enough from current price, Steward uses bucket cash to close that losing position ("dredge") — absorbing the loss from realized profits rather than account balance.

### How Profits Enter the Bucket

Every 2 seconds, Steward scans deal history for closed positions. Any deal with:
- Magic number = InpGridMagic
- Entry = DEAL_ENTRY_OUT (close deal)
- Profit > 0
- Open price was in Zone 2 or Zone 3

...gets added to the bucket queue with a timestamp.

### Dredge Trigger

Steward fires a dredge when:
1. `g_BucketTotal > 0`
2. The worst open position has unrealized loss < 0
3. Price has moved at least `InpDredgeRangePct` × range away from that position's open price
4. Bucket has enough cash to cover the loss

### Survival Ratio

When `balance < initialBalance`, only `InpSurvivalRatio` (50%) of the bucket is available for dredging. This preserves cash reserves when the account is stressed.

### Retention

Bucket entries expire after `InpBucketRetentionHrs` hours. Profits from long ago don't fund today's dredge indefinitely.

---

## 11. Dynamic Grid (Upward Shift Only)

When price rises above `upper + buffer`, the entire grid shifts up:
- `buffer = range × InpUpShiftTriggerPct / 100`
- `shiftAmount = range × InpUpShiftAmountPct / 100`
- Both upper and lower bounds increase by shiftAmount
- All pending orders are deleted
- Grid is rebuilt at new bounds
- Ghost lines are redrawn

**The grid never shifts downward.** Price below `InpLowerPrice` triggers a warning log only.

---

## 12. Two-Tier Hard Stop

Steward has two independent hard stops with different baselines and different scopes.

### Tier 1: Grid Hard Stop (Phase 8)

| Property | Value |
|---|---|
| Trigger | Equity drops X% below peak **balance** |
| Default | `InpHardStopDDPct = 25%` |
| Peak baseline | `g_PeakBalance` — rises only when realized profits are banked |
| Scope | Closes grid positions and pending orders only |
| Hedge | Continues running (hedge defense is still active) |
| Recovery | None — `IsTradingActive = false` permanently |

Using **balance** (not equity) as the peak prevents floating equity spikes from falsely raising the stop floor. A grid full of open BUY positions has equity swinging on every tick; balance is stable.

### Tier 2: Ultimate Hard Stop (Phase 4)

| Property | Value |
|---|---|
| Trigger | Equity drops X% below peak **equity** |
| Default | `InpUltimateHardStopDD = 45%` |
| Peak baseline | `g_HedgePeakEquity` — tracks highest equity seen |
| Scope | **Closes everything** — all grid positions AND all hedge positions |
| Recovery | None — `IsTradingActive = false` |

This is the nuclear option. It fires even if the hedge is active (regardless of Phase 7 freeze). It is checked in Phase 4, before the freeze check.

### Hard Stop Interaction

```
Phase 4 (Ultimate):  Equity DD >= 45% → close ALL, halt
Phase 7 (Freeze):    If hedge active → skip grid, return
Phase 8 (Grid Stop): Balance DD >= 25% → close grid only, halt
```

Grid hard stop → hedge still runs
Ultimate hard stop → everything stops

---

## 13. Dashboard (Unified HUD)

The dashboard is a single panel combining grid, hedge, and planner sections. It updates every 5 seconds via `OnTimer`.

### Panel Sections

| Section | Contents |
|---|---|
| Header | "GRIDBOT-STEWARD v1.0" + status indicator |
| Time | Broker / VPS / PKT time |
| Account | Balance, Equity, DD%, open positions |
| Spread | Current spread vs. allowed max |
| Grid | Range, current price, in-range indicator, expansion coefficient |
| Break Even | Weighted average entry price |
| Bucket | Total bucket cash + total dredged |
| Performance | Today P/L, Week P/L, Win rate |
| Zone Stats | Count, P/L for Zone 1 / 2 / 3 |
| Worst Positions | Top 3 deepest losing positions (Level, Loss $, Open price) |
| Hedge | Status (STANDBY / ACTIVE Stage N/3), volume, P/L, next trigger |
| Cannibalism | Total pruned ($) |
| Hard Stops | Grid stop (peak → floor), Ultimate stop (current DD%) |
| Planner | Time since last PUSH TO LIVE |

### Status Colors

| Status | Color |
|---|---|
| RUNNING | Green |
| FROZEN (Hedge S1/2/3) | Red |
| STOPPED | Red |

### Auto-Range Warning

If Steward auto-adjusted the grid range (user left default XAUUSDm settings on a different instrument), a yellow warning banner shows: **"AUTO-RANGE — USE PLANNER TO OPTIMIZE!"**

---

## 14. State Persistence & Recovery

Steward saves all critical state to MetaTrader GlobalVariables. On restart, it restores exactly where it left off.

### Grid State Saved

- `{magic}_SG_UPPER` — current upper bound
- `{magic}_SG_LOWER` — current lower bound
- `{magic}_SG_LEVELS` — current level count
- `{magic}_SG_COEFF` — active expansion coefficient
- `{magic}_SG_BUCKET` — bucket total ($)
- `{magic}_SG_LOT1/2/3` — runtime lot overrides
- `{magic}_SG_PEAK_EQUITY` — peak balance (for grid hard stop)

### Hedge State Saved

- `{hedgeMagic}_GH_ACTIVE` — 0 or 1
- `{hedgeMagic}_GH_STAGE` — current stage (0-3)
- `{hedgeMagic}_GH_TICKET_1/2/3` — hedge position tickets
- `{hedgeMagic}_GH_START_TIME` — hedge start datetime
- `{hedgeMagic}_GH_PEAK_EQUITY` — peak equity for DD calculations

### Stale State Protection

If hedge state is >24 hours old when Steward starts, it discards the state rather than restoring a stale hedge.

On startup, if `g_HedgeActive=true` is restored but no matching positions exist, Steward resets the hedge state automatically (orphan protection).

### Fresh Start

Set `InpResetState = true` and restart. This deletes all saved GV keys and starts with input defaults.

---

## 15. Planner Integration (PUSH TO LIVE)

GridBot-Steward is fully compatible with GridBot-Planner v23.04. No changes to the Planner are required.

### GVs Published by Steward (Planner reads these)

**Grid namespace `{205001}_SG_*`:**

| Key | Value |
|---|---|
| `UPPER` | Current upper bound |
| `LOWER` | Current lower bound |
| `LEVELS` | Current level count |
| `COEFF` | Active expansion coefficient |
| `LOT1/2/3` | Runtime lot sizes |
| `BUCKET` | Bucket total ($) |
| `HEARTBEAT` | Last tick timestamp (always updated, even when stopped) |
| `LAST_UPDATE` | Last state save timestamp |
| `NET_EXPOSURE` | Net grid volume (long lots) |
| `BOT_ACTIVE` | 1.0 if trading, 0.0 if hard-stopped |
| `HARD_STOP_LEVEL` | Current grid hard stop equity floor |
| `HEDGE_ACTIVE` | 1.0 if hedge active (Planner HUD display only) |

**Hedge namespace `{999999}_GH_*`:**

| Key | Value |
|---|---|
| `ACTIVE` | 1.0 if hedge active |
| `STAGE` | Current stage (0-3) |
| `TICKET_1/2/3` | Hedge position tickets |
| `START_TIME` | Hedge open time |
| `OPEN_VOL` | Total hedge volume when opened |
| `OPEN_PRICE` | Price when hedge opened |
| `PEAK_EQUITY` | Peak equity for DD% calc |

### GVs Read by Steward (Planner writes these)

| Key | Action |
|---|---|
| `{magic}_SG_OPT_CMD_PushTime` | Triggers a parameter update check |
| `{magic}_SG_OPT_NEW_UPPER` | New grid upper |
| `{magic}_SG_OPT_NEW_LOWER` | New grid lower |
| `{magic}_SG_OPT_NEW_LEVELS` | New level count |
| `{magic}_SG_OPT_NEW_COEFF` | New expansion coefficient |
| `{magic}_SG_OPT_NEW_LOT1/2/3` | New zone lot sizes |
| `{magic}_SG_OPT_NEW_MAX_SPREAD` | New max spread limit |

### PUSH TO LIVE Behavior

When a new push is detected:
1. `IsTradingActive = false` — pause grid briefly
2. Delete all pending orders
3. Apply new upper/lower/levels/coeff
4. Rebuild zone floors
5. Rebuild grid
6. `IsTradingActive = true` — resume
7. Alert: "OPTIMIZATION APPLIED: new_upper - new_lower"

Lots and max spread are applied immediately without rebuilding the grid.

---

## 16. Log System

### Console Log (Experts Tab)

When `InpEnableTradeLog = true`, Steward prints structured events:
```
2026-03-01 10:23:45 | BUY_LIMIT | L12 | $2680.00 | 0.02 lots | #12345678
2026-03-01 10:23:51 | TP_CLOSE | L12 | $2695.00 | #12345678
2026-03-01 10:25:00 | DREDGED | L38 | 185.30 lots | #12345690
```

### CSV File Log (PA24)

When `InpEnableFileLog = true`, events are written to:
```
MQL5\Files\GridBot_{Symbol}_{YYYY-MM-DD}.csv
```

**Schema:**
```
Timestamp, Bot, Event, Symbol, Level, Price, Lot, Ticket, Equity, Balance, Peak, DD_Pct, Notes
```

**Bot column is always `STEWARD`** (distinguishable from old `EXECUTOR`/`GUARDIAN` logs).

**Key events logged:**

| Event | Trigger |
|---|---|
| `STARTUP` | OnInit success |
| `HARD_STOP` | Grid hard stop fired |
| `HARD_STOP_ULTIMATE` | Ultimate hard stop fired |
| `FREEZE_ON` | (published at hedge open) |
| `HEDGE_OPEN` | First hedge SELL placed |
| `STAGE_UP` | Hedge stage escalated |
| `SAFE_UNWIND` | Hedge closed by SafeUnwind |
| `ORPHAN` | Hedge tickets disappeared unexpectedly |
| `CANNIBALISM` | Grid position closed with hedge profit |
| `HEDGE_REDUCE` | Hedge partially closed after cannibalism |
| `BUY_LIMIT` | Grid entry order placed |
| `TP_CLOSE` | Virtual TP close |
| `TP_CLOSE_ORPHAN` | Orphaned position TP close (PA23) |
| `ORDER_FAIL` | BuyLimit order failed |
| `DREDGED` | Bucket dredge position close |
| `PUSH_APPLIED` | Planner PUSH TO LIVE accepted and applied |

---

## 17. Troubleshooting

### "Account must be HEDGING type"
The account is a netting or exchange account. Steward requires a hedging account to hold simultaneous BUY and SELL positions on the same symbol. Switch brokers or account types.

### "Another Steward already running"
A previous session didn't clean up its instance guard GV. This can happen after a crash. Fix: In MT5 Tools → Global Variables, find `STEWARD_ACTIVE_{Symbol}_{magic}` and delete it manually.

### Grid hard stop fired immediately after restart
The saved peak balance was higher than current equity when Steward restarted. Either:
- Use `InpResetState = true` to wipe state (peak resets to current balance)
- Accept it — the stop fired because the account genuinely declined since the last session

### Hedge not opening despite DD > trigger
Check in order:
1. Is net exposure > 0? (no grid positions = no hedge volume needed)
2. Is spread > `InpMaxHedgeSpread`? (blocked during wide spread)
3. Is free margin < `InpMinFreeMarginPct`? (blocked for margin safety)
4. Has 5 seconds passed since last full check? (`InpFullCheckInterval`)

### SafeUnwind not firing even though DD < 20%
Check all conditions:
1. Is price within range? (below range → holding)
2. Is total hedge P/L > 0? (PA21: blocked if underwater)
3. Has each stage been open ≥ `InpMinStageHoldMins`? (PA21: hold time guard)

### Dashboard not showing
Set `InpShowDashboard = true`. Ensure the chart has enough vertical space. The panel anchors to `InpDashCorner` — try a different corner if it's off-screen.

### PUSH TO LIVE not applying
1. Verify `InpAllowRemoteOpt = true`
2. Verify `InpGridMagic` matches Planner's `InpExecutorMagic`
3. Wait up to 10 seconds for the poll interval to fire
4. Check Planner is attached to a live chart (not a demo symbol mismatch)

### Auto-Range warning in dashboard
Steward detected you left the default 2750/2650 range while trading a non-gold instrument. Open Planner, configure the correct range, and use PUSH TO LIVE to apply it. The warning clears automatically after the first successful push.

### Switching timeframes on the Steward chart
Safe to do. Steward detects `REASON_CHARTCHANGE` in `OnDeinit` and skips the destructive shutdown steps — `BOT_ACTIVE` stays `1`, ghost lines and dashboard remain on chart. State is saved and the instance guard is cycled normally. OnInit re-runs immediately and resumes from saved state.

**Avoid switching timeframe while:**
- A hedge is active (unnecessary risk during the brief re-init gap)
- A PUSH TO LIVE grid rebuild is in progress (wait for "OPTIMIZATION APPLIED" alert)

**Best practice:** Attach Steward to a dedicated blank chart and run your analysis on a separate chart — then timeframe switches never touch the EA.

---

## 18. Migration from Executor + Guardian

### Pre-Migration Checklist
- [ ] Steward compiled and tested on demo with same magic numbers
- [ ] Demo results match Executor+Guardian outputs (grid geometry, hedge triggers)
- [ ] Planner reads Steward GVs correctly on demo
- [ ] CSV logs appear in MQL5\Files with Bot="STEWARD"

### Cutover Procedure (Live)

1. Note current state: Upper, Lower, Levels, Coeff, Bucket total, Hedge status
2. **Stop Guardian** (it saves state and clears HEDGE_ACTIVE)
3. Wait 5 seconds
4. **Stop Executor** (it saves grid state)
5. **Start Steward** on the same chart with same magic numbers
   - Steward reads the same GV namespace and resumes from saved state
   - Grid positions and hedge positions are recognized automatically
6. Verify dashboard shows correct range, bucket total, and hedge status

### Rollback Procedure

1. **Stop Steward** (saves state, clears instance guard)
2. Wait 5 seconds
3. **Start Guardian** first (reads hedge GVs)
4. **Start Executor** second (reads grid GVs)
5. Both bots resume exactly where Steward left off — same GV namespace

### Shadow Testing (Recommended Before Cutover)

Run Steward on the same live account with different magic numbers (e.g., 205002/999998) and minimum lots (0.01 across all zones). Observe for 1 week:
- Grid geometry matches Executor outputs
- Hedge triggers fire at same DD levels
- PUSH TO LIVE from Planner applies correctly (use a second Planner instance linked to magic 205002)

---

*GridBot-Steward v1.0 — Architecture: 26 PA fixes baked in. 8 eliminated. 8 kept. 2 simplified.*
