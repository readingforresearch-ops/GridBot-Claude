# GridBot Ecosystem — Complete Deployment & Operations Guide

## Table of Contents

1. [System Overview](#1-system-overview)
2. [Prerequisites](#2-prerequisites)
3. [Pre-Flight Checklist](#3-pre-flight-checklist)
4. [Installation](#4-installation)
5. [Initial Configuration](#5-initial-configuration)
6. [Startup Sequence](#6-startup-sequence)
7. [Verification & Health Checks](#7-verification--health-checks)
8. [Daily Operations](#8-daily-operations)
9. [Optimization & Parameter Updates](#9-optimization--parameter-updates)
10. [Monitoring & Alerts](#10-monitoring--alerts)
11. [Troubleshooting Common Issues](#11-troubleshooting-common-issues)
12. [Shutdown & Maintenance](#12-shutdown--maintenance)
13. [Recovery Procedures](#13-recovery-procedures)
14. [Best Practices](#14-best-practices)

---

## Complete Workflow at a Glance

> **Read this first.** The sections below go deep on every step — this page gives you the full picture in 2 minutes.

---

### Phase 1: First-Time Setup (one-time, ~30 minutes)

```
┌─────────────────────────────────────────────────────────────────────┐
│  FIRST-TIME SETUP                                                   │
├─────────────────────────────────────────────────────────────────────┤
│  1. Copy all 3 bot .mq5 files → MQL5/Experts/                      │
│  2. Compile all 3 in MetaEditor (F7) — verify 0 errors             │
│  3. Open MT5 chart for your symbol (e.g. XAUUSDm)                  │
│                                                                     │
│  4. Drag GridBot-EXECUTOR onto the chart                            │
│     • Set InpMagicNumber = 205001                                   │
│     • Set InpResetState = false (first run — no old state)          │
│     • Leave InpUpperPrice / InpLowerPrice / lots at 0              │
│     • Click OK                                                      │
│                                                                     │
│  5. Drag GridBot-GUARDIAN onto a second chart window (same symbol)  │
│     • Set InpManualGridMagic = 205001 (must match Executor)         │
│     • Configure drawdown triggers (30/35/40%)                       │
│     • Click OK                                                      │
│                                                                     │
│  6. Drag GridBot-PLANNER onto the Executor chart                    │
│     • Set InpExecutorMagic = 205001                                 │
│     • Set InpAccountBalance = your balance                          │
│     • Set InpMaxRiskPerc = 25-30%                                   │
│     • Click OK → wait 10 seconds for HUD to appear                 │
│                                                                     │
│  7. Review Planner HUD:                                             │
│     • Check Max DD% ≤ your InpMaxRiskPerc (should be green)        │
│     • Check Margin Level > 300% (should be green)                  │
│     • Check Recovery % < 15% (should be green)                     │
│                                                                     │
│  8. Click green "PUSH TO LIVE" button in Planner HUD               │
│     → Executor log: "OPTIMIZATION APPLIED"                          │
│     → Grid is now LIVE, orders start placing                        │
│                                                                     │
│  9. Remove Planner from chart (right-click → Expert Advisors →     │
│     Remove) — it's no longer needed until next optimization         │
│                                                                     │
│  ✅ DONE. Executor + Guardian will now run 24/7 unattended.         │
└─────────────────────────────────────────────────────────────────────┘
```

---

### Phase 2: Daily Operations (5 minutes/day)

**Executor and Guardian run automatically — you just monitor.**

| Time | Action | Tool |
|---|---|---|
| Morning | Check all dashboards are updating | MT5 dashboards |
| Morning | Verify heartbeats fresh (< 10s old) | Tools → Global Variables |
| Morning | Check DD% (alert if > 20%) | Guardian dashboard |
| Evening | Review day P/L | Executor dashboard |
| Evening | Check for any critical alerts | Experts log (Ctrl+T) |

**You do NOT need to attach Planner daily.** Only attach it when you want to re-optimize.

---

### Phase 3: Re-Optimization (monthly or when market changes)

```
1. Attach GridBot-PLANNER to chart
2. Update InpAccountBalance, InpMaxRiskPerc as needed
3. Wait for HUD to recalculate (10 seconds)
4. Review simulation — verify all metrics are green
5. Click "PUSH TO LIVE"
   → Executor UPDATES LIVE without restart (even during active hedge)
   → Log: "OPTIMIZATION APPLIED: new range / new lots"
6. Remove Planner from chart (optional — leave on if monitoring)
```

> **Why PUSH TO LIVE instead of .SET file?**
> PUSH TO LIVE updates the Executor while it's running — no restart needed, no state loss, safe during an active Guardian hedge. A .SET file requires restart and may cause state loss.

---

### Fresh/Clean Deployment (new instrument or after hard stop)

When starting completely fresh — no saved state from previous runs:

```
1. Tools → Global Variables → delete all {magic}_SG_* keys
   (e.g. 205001_SG_UPPER, 205001_SG_LOWER, etc.)
2. Attach Executor with InpResetState = true
   → This ignores any stale saved state
3. Attach Guardian with correct InpManualGridMagic
4. Attach Planner → configure → PUSH TO LIVE
5. After push confirmed: remove Planner
6. Set InpResetState = false next time (state is now clean)
```

> **Why this matters:** If Executor loads stale GVs from a previous run on a different instrument or price range, the bucket/dredge system can act on old data and close new positions at a loss within seconds. Always clean GVs when switching instruments.

---

### Which Bots Must Run Continuously?

| Bot | Continuous? | Notes |
|---|---|---|
| **GridBot-Executor** | ✅ Yes — 24/7 | Grid engine, never remove while trading |
| **GridBot-Guardian** | ✅ Yes — 24/7 | Defense system, never remove while trading |
| **GridBot-Planner** | ❌ On-demand only | Attach to optimize, remove when done |

---

## 1. System Overview

### The 3-Bot Architecture

```
┌─────────────────────┐
│  GridBot-Planner    │  ← Strategy & Optimization
│  (The Strategist)   │     • Calculates parameters
└──────────┬──────────┘     • Simulates risk
           │                • Pushes to Executor
           │ GlobalVariables
           ↓
┌─────────────────────┐
│  GridBot-Executor   │  ← Live Trading Engine
│  (The Grid Master)  │     • Places grid orders
└──────────┬──────────┘     • Manages positions
           │                • Runs bucket/dredge
           │ GlobalVariables
           ↓
┌─────────────────────┐
│  GridBot-Guardian   │  ← Defense System
│  (The General)      │     • Monitors drawdown
└─────────────────────┘     • Places hedge
                            • Executes cannibalism
```

### Communication Protocol

All 3 bots communicate exclusively via **MT5 GlobalVariables** (no files, no network, no DLLs).

### Key Principle

**Start order matters:** Executor must be running before Guardian. Planner can start anytime.

---

## 2. Prerequisites

### Account Requirements

| Requirement | Details | Why |
|---|---|---|
| **Account Type** | Hedging/Hedge-Enabled | Guardian needs to open SELL positions while grid has BUY positions |
| **Broker** | Exness, FXPro, IC Markets, etc. | Must support hedging accounts |
| **Minimum Balance** | $5,000+ for Gold | Lower risk = longer survival |
| **Leverage** | 1:100 to 1:500 | Higher leverage = less margin used |
| **VPS** | Recommended | 24/7 operation, low latency |

### Supported Instruments

| Symbol | Recommended Balance | Notes |
|---|---|---|
| XAUUSDm (Gold) | $5,000+ | Standard configuration |
| XAUUSD (Gold) | $5,000+ | Same as XAUUSDm |
| BTCUSDm (Bitcoin) | $10,000+ | Higher volatility, wider ranges |
| EURUSD | $3,000+ | Lower volatility |

### Software Requirements

| Software | Version | Notes |
|---|---|---|
| MetaTrader 5 | Build 3802+ | Older builds may have GV bugs |
| Windows | 7/10/11 or Server | VPS recommended |
| MT5 Standard Library | Included | Trade.mqh, Canvas.mqh |

---

## 3. Pre-Flight Checklist

Before installing the bots, verify:

### ✅ Account Verification

1. **Check account type:**
   - Open MT5 → Tools → Options → Server tab
   - Look for "Hedging" or "Hedge" in the account description
   - **OR** try placing a BUY and SELL order on the same symbol manually — if both stay open, it's hedging

2. **Verify symbol specifications:**
   - Market Watch → Right-click symbol → Specification
   - Note: `SYMBOL_VOLUME_MIN`, `SYMBOL_VOLUME_MAX`, `SYMBOL_VOLUME_STEP`
   - Note: `SYMBOL_TRADE_TICK_SIZE`, `SYMBOL_TRADE_TICK_VALUE`

3. **Check margin and leverage:**
   - Account → Right-click → Properties
   - Confirm leverage (e.g., 1:200)

### ✅ Terminal Configuration

1. **Enable AutoTrading:**
   - Toolbar → Click "AutoTrading" button (should turn green)
   - Tools → Options → Expert Advisors → Check "Allow automated trading"
   - Check "Allow DLL imports" is **OFF** (we don't use DLLs)

2. **Enable live account trading (if applicable):**
   - Tools → Options → Expert Advisors
   - Uncheck "Disable automated trading when account or server changes" (optional)

3. **Set up notifications (optional):**
   - Tools → Options → Notifications
   - Enable Push Notifications (for mobile alerts)
   - Enable Email (for email alerts)

### ✅ Chart Setup

1. **Open the trading symbol chart:**
   - File → New Chart → Select your symbol (e.g., XAUUSDm)

2. **Set a suitable timeframe:**
   - Recommended: H1 or H4 (doesn't affect bot logic, just for visual monitoring)

3. **Prepare chart space:**
   - Make the chart window large enough for dashboards (1300x900+ pixels recommended)
   - Zoom out to see the full price range

---

## 4. Installation

### Step 1: Copy Bot Files

1. Open MT5 → File → Open Data Folder
2. Navigate to `MQL5/Experts/`
3. Copy all 3 bot files:
   - `GridBot-Executor_v10_Integrated.mq5`
   - `GridBot-Guardian_v3.1_Integrated.mq5`
   - `GridBot-Planner_v23_04.mq5`

### Step 2: Compile

1. Open MetaEditor (F4 in MT5)
2. Navigate to Experts folder in the Navigator
3. Double-click each bot file to open
4. Click Compile (F7) for each bot
5. **Verify zero errors** in the Toolbox → Errors tab

Expected output:
```
GridBot-Executor_v10_Integrated.mq5: 0 error(s), 0 warning(s)
GridBot-Guardian_v3.1_Integrated.mq5: 0 error(s), 0 warning(s)
GridBot-Planner_v23_04.mq5: 0 error(s), 0 warning(s)
```

### Step 3: Refresh MT5

1. Return to MT5 terminal
2. Navigator → Expert Advisors → Right-click → Refresh
3. All 3 bots should now appear in the list

---

## 5. Initial Configuration

### Configuration Strategy

There are **three ways** to configure the ecosystem:

**Option A: Manual Configuration (Full Control)**
- Set all parameters manually in each bot
- Good for experienced users who know exact ranges
- Requires understanding of all 46 Executor input parameters

**Option B: Planner-First with PUSH TO LIVE (Recommended)**
- Configure Planner with your account/risk settings
- Let Planner calculate optimal parameters
- Push to Executor via "PUSH TO LIVE" button
- **Best for:** Initial deployment on any instrument

**Option C: Smart Defaults with Auto-Range Detection (Tier 3)**
- Start Executor with default XAUUSD values on any instrument
- Executor auto-detects instrument type by price and adjusts range
- Show orange warning banner until you optimize with Planner
- **Best for:** Quick testing or when you don't have Planner running yet

We'll use **Option B (Planner-First)** in this guide as it's the safest and most flexible.

---

### Understanding Tier 3 Smart Defaults (Auto-Range Detection)

**New in v10.03:** Executor can now auto-detect instrument type and adjust price ranges automatically.

#### How It Works

If you start Executor with the **default XAUUSD values** (Upper=2750, Lower=2650) on a **non-XAUUSD instrument**, Executor will:

1. **Detect current market price** for your symbol
2. **Identify instrument type** by price range:
   - **Crypto** (price > 50,000): Bitcoin, Ethereum → ±10% range
   - **Indices** (10,000 < price < 50,000): SPX, NDX → ±5% range
   - **Forex** (price < 10): EURUSD, GBPUSD → ±3% range
   - **Metals** (other): Keep XAUUSD defaults

3. **Calculate adjusted range** centered on current price
4. **Set global flag** `g_UsingAutoDefaults = true`
5. **Show prominent warnings:**
   - Alert popup: "⚠️ EXECUTOR USING AUTO-ADJUSTED DEFAULTS..."
   - Dashboard banner: "⚠️ AUTO-RANGE MODE - USE PLANNER TO OPTIMIZE!" (orange)
   - Experts log entry with detected price and calculated range

#### Example: Starting on BTCUSD

```
Current Bitcoin price: $92,000
Detected instrument type: CRYPTO (price > 50,000)
Auto-calculated range:
  - Upper: $92,000 × 1.10 = $101,200
  - Lower: $92,000 × 0.90 = $82,800
```

#### When Auto-Range Flag Clears

The orange warning banner disappears when:
- Planner pushes optimized parameters via "PUSH TO LIVE"
- You manually configure Executor with correct ranges via .SET file import
- You manually set non-default Upper/Lower values

Experts log will show:
```
✓ AUTO-RANGE MODE DEACTIVATED - Now using Planner-optimized configuration
```

#### Important Safety Notes

- **Auto-range is NOT optimized** — it's a placeholder to prevent crashes
- **Lot sizes remain default** (0.01/0.02/0.05) — likely too small or too large
- **No risk-based sizing** — Planner calculates proper lots for your balance
- **Always optimize with Planner** as soon as possible after auto-deployment

#### When to Use Auto-Range

✅ **Good use cases:**
- Quick testing on a new instrument without Planner
- Emergency deployment when Planner is unavailable
- Demo account experimentation

❌ **Bad use cases:**
- Live trading without optimization
- Large account balances (improper lot sizing = poor performance)
- Long-term deployment (always optimize within first hour)

---

### Step 1: Configure GridBot-Planner

1. Drag `GridBot-Planner_v23_04` from Navigator onto your chart
2. In the properties dialog, go to **Inputs** tab
3. Configure the following:

#### Critical Parameters

| Parameter | Recommended Setting | Notes |
|---|---|---|
| **InpExecutorMagic** | `205001` | Must match across all 3 bots |
| **InpAccountBalance** | Your actual balance | E.g., 10000.0 for $10k |
| **InpMaxRiskPerc** | `25.0` - `40.0` | Conservative: 25%, Aggressive: 40% |
| **InpSimLeverage** | Your actual leverage | E.g., 200 for 1:200 |
| **InpRangeMode** | `RANGE_AUTO_VOLATILITY` | Let ATR calculate range |
| **InpDaysToCover** | `22` | ~1 month volatility coverage |
| **InpUseAutoLot** | `true` | Auto-size lots to fit risk |
| **InpStrikeMethod** | `STRIKE_MANUAL` | Start with manual control |
| **InpManualStrike** | `STRIKE_MODE_5` | Conservative (1.5x/2.5x multipliers) |
| **InpGapLogic** | `GAP_ATR_TARGETS` | Match gaps to ATR targets |
| **InpGapTimeFrame** | `TF_H4_VOLATILITY` | Use H4 ATR for gaps |
| **InpFirstGapPct** | `60.0` | First gap = 60% of ATR |
| **InpLastGapPct** | `150.0` | Last gap = 150% of ATR |

#### Example for $10,000 Gold Account

```
InpExecutorMagic = 205001
InpAccountBalance = 10000.0
InpMaxRiskPerc = 30.0
InpSimLeverage = 200
InpRangeMode = RANGE_AUTO_VOLATILITY
InpDaysToCover = 22
InpUseAutoLot = true
InpStrikeMethod = STRIKE_MANUAL
InpManualStrike = STRIKE_MODE_5
InpGapLogic = GAP_ATR_TARGETS
InpGapTimeFrame = TF_H4_VOLATILITY
InpFirstGapPct = 60.0
InpLastGapPct = 150.0
InpShowLines = true
```

4. Click **OK**
5. The Planner HUD will appear and begin calculating

### Step 2: Review Planner Output

Wait 5-10 seconds for the Physics Solver to run. Check the HUD:

#### Column 1: Strategy & Account
- ✅ **Auto Lot should show GREEN** (if balance is sufficient)
- Note the **Base Lot** value (e.g., 0.04)
- Note **Z2 Mult** and **Z3 Mult**

#### Column 2: Grid Structure
- Note **Upper** and **Lower** prices (e.g., 2750.00 - 2650.00)
- Check **Levels** (typically 20-60)
- Verify **Last Gap** is GREEN (> 5x spread)

#### Column 4: Performance & Risk
- ✅ **Max Drawdown %** should be ≤ your `InpMaxRiskPerc` and show GREEN/YELLOW
- ✅ **Margin Level** should be > 300% and GREEN
- ✅ **Recovery %** (Bounce %) should be < 15% and GREEN/YELLOW
- ✅ **Profit Factor** should be > 1.5

If any of these are RED or show warnings, adjust parameters (see [Section 11](#11-troubleshooting-common-issues)).

### Step 3: Export Planner Settings (Optional)

Before pushing to live, you can export a backup .SET file:

1. Click **EXPORT .SET** button on the Planner HUD
2. The file is saved to `MQL5/Files/{Symbol}_SmartGrid_v23_04.set`
3. Copy this file to a backup location

---

## 6. Startup Sequence

**CRITICAL: Start bots in this exact order:**

```
1. GridBot-Executor  (FIRST — publishes GVs that others read)
2. GridBot-Guardian  (SECOND — reads Executor's GVs)
3. GridBot-Planner   (THIRD — optional, reads nothing, publishes optimization)
```

### Step 1: Start GridBot-Executor

1. Drag `GridBot-Executor_v10_Integrated` onto the chart
2. **Configure inputs:**

#### Critical Parameters

| Parameter | Setting | Notes |
|---|---|---|
| **InpMagicNumber** | `205001` | Must match Planner's InpExecutorMagic |
| **InpUpperPrice** | `0.0` | Leave at 0 — will be set by Planner |
| **InpLowerPrice** | `0.0` | Leave at 0 — will be set by Planner |
| **InpGridLevels** | `45` | Placeholder — will be updated by Planner |
| **InpExpansionCoeff** | `1.0` | Placeholder |
| **InpLotZone1** | `0.01` | Placeholder — will be updated by Planner |
| **InpLotZone2** | `0.02` | Placeholder |
| **InpLotZone3** | `0.05` | Placeholder |
| **InpMaxPendingOrders** | `20` | Limit rolling tail size |
| **InpUseBucketDredge** | `true` | Enable bucket/dredge system |
| **InpBucketRetentionHrs** | `48` | Bucket profit retention window |
| **InpDredgeRangePct** | `0.35` | Position must move 35% of range from entry before eligible for dredge |
| **InpUseVirtualTP** | `true` | Programmatic TP (recommended) |
| **InpHardStopDDPct** | `25.0` | Hard stop drawdown % from peak balance (auto-tracks realized profits, range 1–50%). Trigger checks equity. |
| **InpMaxOpenPos** | `100` | Max total positions |
| **InpMaxSpread** | `2000` | Max spread in points |
| **InpEnableGuardianCoordination** | `true` | Enable freeze protocol |
| **InpAllowRemoteOpt** | `true` | Accept Planner pushes |
| **InpResetState** | `false` | Set to true to clear saved state |

3. Click **OK**

4. **Check Experts log (Ctrl+T → Experts tab):**

**Expected output (when using Planner-First strategy with Upper/Lower = 0.0):**
```
GridBot-Executor v10.06 Integrated
Hedging account verified.
No saved state found - using input parameters.
Grid boundaries: 0.00 - 0.00 (INVALID - waiting for Planner push)
Initialization Complete.
```

**Expected output (when using Smart Defaults on BTCUSD with default XAUUSD values):**
```
GridBot-Executor v10.06 Integrated
Hedging account verified.
⚠️ AUTO-RANGE DETECTION ACTIVATED
Symbol: BTCUSD  Current Price: $92,000.00
Instrument Type: CRYPTO (±10% range)
Auto-calculated range: $82,800.00 - $101,200.00
Grid boundaries: $82,800.00 - $101,200.00
Initialization Complete.
⚠️ EXECUTOR USING AUTO-ADJUSTED DEFAULTS - USE PLANNER TO OPTIMIZE!
```

**The grid behavior depends on your configuration:**
- **If Upper/Lower = 0.0:** Grid will NOT be active yet — waiting for Planner push (normal)
- **If using default XAUUSD values on non-XAUUSD:** Auto-range activates, grid is LIVE but shows orange warning banner

### Step 2: Start GridBot-Guardian

1. Drag `GridBot-Guardian_v3.1_Integrated` onto the chart
2. **Configure inputs:**

| Parameter | Setting | Notes |
|---|---|---|
| **InpAutoDetectGrid** | `true` | Auto-find Executor's magic |
| **InpManualGridMagic** | `0` | Not needed when auto-detect is on |
| **InpHedgeMagic** | `999999` | Guardian's own magic (must differ from 205001) |
| **InpHedgeTrigger1** | `30.0` | Stage 1 DD trigger |
| **InpHedgeRatio1** | `0.30` | Stage 1 hedge 30% |
| **InpHedgeTrigger2** | `35.0` | Stage 2 DD trigger |
| **InpHedgeRatio2** | `0.30` | Stage 2 adds +30% (total 60%) |
| **InpHedgeTrigger3** | `40.0` | Stage 3 DD trigger |
| **InpHedgeRatio3** | `0.35` | Stage 3 adds +35% (total 95%) |
| **InpHardStopDD** | `45.0` | Nuclear option DD level |
| **InpEnablePruning** | `true` | Enable cannibalism |
| **InpPruneThreshold** | `100.0` | Min hedge profit for cannibalism |
| **InpPruneBuffer** | `20.0` | Extra buffer for safety |
| **InpSafeUnwindDD** | `20.0` | Unwind when DD < 20% (and price in range) |
| **InpMinFreeMarginPct** | `150.0` | Require 150% margin before hedging |
| **InpMaxHedgeDurationHrs** | `72` | Force-close hedge after 72 hours |
| **InpAutoScaleToRisk** | `true` | Scale triggers to Planner's MaxRiskPerc |
| **InpEnablePushNotify** | `true` | Mobile alerts |
| **InpEnableEmailNotify** | `false` | Email alerts |

3. Click **OK**

4. **Check Experts log:**

Expected output:
```
GridBot-Guardian v3.1 Integrated
SMARTGRID DETECTED: Magic 205001
Grid: 0.00000 - 0.00000 (waiting for Executor initialization)
GRID CONNECTION VERIFIED
Guardian initialization complete. Standing by.
```

### Step 3: Push Optimized Parameters from Planner

Now that Executor is running (but inactive), push the calculated parameters:

1. **In Planner HUD, click the green "PUSH TO LIVE" button**

2. You'll see an alert:
   ```
   ✅ CONFIG PUSHED TO LIVE! GridBot-Executor should update shortly.
   ```

3. **Check Executor's Experts log (within 10 seconds):**
   ```
   REMOTE OPTIMIZATION RECEIVED
   LOT UPDATE: Z1=0.24 Z2=0.43 Z3=0.72
   OPTIMIZATION APPLIED: 2750.000 - 2650.000
   Grid rebuilt: 45 levels, Coeff=1.0314
   ```

4. **Verify GlobalVariables (Tools → Global Variables):**
   ```
   205001_SG_UPPER = 2750.0
   205001_SG_LOWER = 2650.0
   205001_SG_LEVELS = 45.0
   205001_SG_COEFF = 1.0314
   205001_SG_LOT1 = 0.24
   205001_SG_LOT2 = 0.43
   205001_SG_LOT3 = 0.72
   205001_SG_MAX_RISK_PCT = 30.0
   ```

5. **Check Executor dashboard:**
   ```
   GRIDBOT-EXECUTOR v10.06
   Status: RUNNING  |  Guardian: Standby

   Grid: $2650.00 - $2750.00  |  Coeff: 1.0314
   Price: $2720.50  |  In Range
   ```

**✅ The grid is now LIVE and will start placing orders.**

---

## 7. Verification & Health Checks

### Immediate Checks (First 5 Minutes)

#### 1. Check Order Placement

1. **Terminal → Trade tab**
   - You should see BUY LIMIT orders appearing below the current price
   - Number of orders should be ≤ `InpMaxPendingOrders` (20 by default)
   - All orders should have:
     - Type: BUY LIMIT
     - Magic: 205001
     - Comment: "SmartGrid_v10"

2. **Verify order prices are within the grid range:**
   - All order prices should be between Lower and Upper
   - Prices should be descending (each order below the previous)

#### 2. Check GlobalVariables

**Tools → Global Variables**

Verify these keys exist and have reasonable values:

**Executor Keys:**
```
205001_SG_BOT_ACTIVE = 1.0
205001_SG_UPPER = <your upper price>
205001_SG_LOWER = <your lower price>
205001_SG_LEVELS = <your level count>
205001_SG_HEARTBEAT = <recent timestamp>
205001_SG_NET_EXPOSURE = <small value, likely 0 initially>
205001_SG_BUCKET = 0.0 (initially)
```

**Guardian Keys:**
```
999999_GH_ACTIVE = 0.0 (no hedge yet)
999999_GH_GRID_MAGIC = 205001.0
999999_GH_PEAK_EQUITY = <your current equity>
205001_SG_HEDGE_ACTIVE = 0.0 (Guardian not hedging)
```

#### 3. Check Dashboards

**Executor Dashboard (top-left):**
```
GRIDBOT-EXECUTOR v10.06
Status: RUNNING  |  Guardian: Standby  ← Should show RUNNING
Balance: $10000  |  Equity: $9995      ← Should be close to actual
DD: 0.05%  |  Positions: 0/45         ← DD should be near 0%
Grid: $2650 - $2750  |  Coeff: 1.0314  ← Should match Planner
Bucket: $0.00  |  Dredged: $0.00      ← Initially zero
```

**Guardian Dashboard (overlapping or below Executor):**
```
GRIDBOT-GUARDIAN v3.1
Linked: SmartGrid #205001                ← Confirms link
Equity: $10000  Peak: $10000  DD: 0.00%  ← Should match account
T1: 30.0%  |  T2: 35.0%  |  T3: 40.0%   ← Your trigger settings
Status: STANDBY  (Monitoring)            ← Should say STANDBY
```

#### 4. Monitor First Trade

1. Wait for price to drop and trigger a BUY LIMIT order
2. **When an order fills:**
   - Trade tab → A position should appear
   - Magic: 205001
   - Type: BUY
   - Lots: Should match the zone it's in (0.24 for Zone 1, 0.43 for Zone 2, 0.72 for Zone 3)

3. **Check Executor log:**
   ```
   2026.02.12 14:30:00 | BUY_LIMIT | L12 | $2695.50 | 0.24 lots | #54321
   SYNC: Level 12 occupied by #54321
   ```

4. **Wait for price to rise back to TP:**
   - When bid reaches the TP price (the level above), position should close
   - Log should show:
   ```
   2026.02.12 14:35:00 | TP_CLOSE | L12 | $2698.30 | 0.00 lots | #54321
   ```

5. **Verify profit:**
   - History tab → Check the closed trade
   - Profit should be positive (gap size × lot size × tick value)

---

## 8. Daily Operations

### Morning Routine (5 Minutes)

1. **Open MT5 and check connection:**
   - Bottom-right corner should show current ping (e.g., "150ms")
   - If red or disconnected, reconnect to the broker

2. **Check both dashboards:**
   - Executor: Status should be "RUNNING"
   - Guardian: Status should be "STANDBY" (or "HEDGE ACTIVE" if DD triggered)
   - Planner: Only visible if you've attached it for optimization — not required daily

3. **Review overnight performance:**
   - Executor dashboard → Check "Today P/L" and "Week P/L"
   - History tab → Review closed trades from the past 24 hours
   - Win rate should be > 80% (most trades close at TP)

4. **Check GlobalVariables heartbeats:**
   - `205001_SG_HEARTBEAT` should be within the last 10 seconds
   - `999999_GH_HEARTBEAT_TS` should be within the last 10 seconds
   - If stale (> 1 minute), a bot may have crashed

5. **Verify position count:**
   - Trade tab → Count open positions
   - Should be reasonable relative to price position in the range
   - If price is near upper: few positions
   - If price is near lower: many positions (up to `InpMaxOpenPos`)

### Evening Routine (3 Minutes)

1. **Check drawdown:**
   - Executor dashboard → Note the DD%
   - Guardian dashboard → Note distance to next trigger
   - If DD > 15%, review the situation

2. **Check bucket status:**
   - Executor dashboard → "Bucket: $XXX"
   - If bucket is growing, dredging is working
   - If bucket is empty for days, Zone 2/3 may not be trading

3. **Review worst positions:**
   - Executor dashboard → Bottom section shows 3 worst positions
   - Note the loss amounts
   - If losses are extreme (> 10% of balance on one position), review zone/lot configuration

4. **Check for alerts:**
   - Experts tab → Scroll through log
   - Look for "CRITICAL" or "WARNING" messages
   - Common alerts:
     - "Grid validation failed" → Reconnection issue (should retry)
     - "Spread too wide" → Normal during rollover
     - "HEDGE INCREASED" → Guardian activated

### Weekly Routine (15 Minutes)

1. **Performance review:**
   - Check "Week P/L" on Executor dashboard
   - Calculate win rate: Winning trades / Total trades
   - Target: > 80% win rate, positive weekly P/L

2. **Bucket/Dredge analysis:**
   - Check "Dredged: $XXX" cumulative total
   - If dredging is frequent, it means deep positions are being cleared
   - If no dredging for a week, bucket retention may be too short or Zone 2/3 lots too small

3. **Guardian history:**
   - Check "Cannibalized: $XXX" on Guardian dashboard
   - If non-zero, Guardian has been active
   - Review History tab for hedge positions (Magic 999999, Type SELL)

4. **Volatility check:**
   - Compare current ATR (in Planner HUD metrics) to the ATR from last week
   - If volatility increased significantly, consider widening the range
   - If volatility decreased, consider tightening the range

5. **Rebalance if needed:**
   - If market conditions changed drastically (e.g., gold moved from $2700 to $2500), run Planner optimization again and PUSH TO LIVE

---

## 9. Optimization & Parameter Updates

### When to Re-Optimize

Triggers for running a new optimization:

| Trigger | Example | Action |
|---|---|---|
| **Price broke above Upper + buffer** | Price rallied from $2750 to $2780 | Dynamic grid should auto-shift, but verify |
| **Range is misaligned** | Grid is $2650-$2750, price is at $2600 | Re-optimize with new range |
| **ATR changed significantly** | ATR was 20, now 35 (volatility spike) | Re-run Planner with new ATR targets |
| **Drawdown near max risk** | DD at 28%, max risk is 30% | Tighten risk, reduce lot sizes |
| **Balance changed** | Deposited more funds | Update `InpAccountBalance`, re-run auto-lot |

### Re-Optimization Workflow

1. **Stop new entries (optional):**
   - If you want to freeze the current grid, set `InpAllowRemoteOpt = false` in Executor temporarily
   - This prevents accidental pushes while you're testing

2. **Adjust Planner parameters:**
   - Remove Planner from chart (right-click → Expert Advisors → Remove)
   - Re-attach Planner with new settings:
     - Update `InpAccountBalance` if you deposited/withdrew
     - Adjust `InpMaxRiskPerc` if you want to change risk
     - Change `InpDaysToCover` if you want a wider/narrower range
     - Switch `InpRangeMode` to `RANGE_MANUAL_LEVELS` if you want exact control

3. **Review new calculations:**
   - Wait for Planner HUD to refresh
   - Check all 4 columns for safety:
     - Max DD% ≤ your risk limit
     - Margin Level > 300%
     - Recovery % < 15%
     - Profit Factor > 1.5
   - If any metric is RED, adjust parameters

4. **Export a backup .SET (recommended):**
   - Click "EXPORT .SET" before pushing
   - This creates a snapshot you can revert to

5. **Push to Executor:**
   - Click "PUSH TO LIVE"
   - Watch Executor's Experts log for "OPTIMIZATION APPLIED"
   - Verify new GVs in GlobalVariables window

6. **Monitor for 30 minutes:**
   - Check that new orders are being placed at correct prices
   - Verify lot sizes match the new calculations
   - Check that existing positions are still mapped correctly

### Manual Override (Advanced)

If you want to manually adjust a single parameter without re-running Planner:

1. **Edit GlobalVariables directly:**
   - Tools → Global Variables
   - Find the key you want to change (e.g., `205001_SG_LOT2`)
   - Double-click → Change the value
   - Click OK

2. **Restart Executor:**
   - Right-click chart → Expert Advisors → Remove (for Executor only)
   - Re-attach Executor
   - It will load the modified GV values

**⚠️ Warning:** Manual GV edits bypass Planner's safety checks. Use only if you know what you're doing.

---

## 10. Monitoring & Alerts

### What to Monitor

| Metric | Location | Normal Range | Alert If |
|---|---|---|---|
| **Drawdown %** | Executor/Guardian dashboard | 0-15% | > 25% |
| **Position Count** | Trade tab / Executor dashboard | Varies | > 80% of max levels |
| **Net Exposure** | Executor dashboard | 0.1 - 2.0 lots | > 5.0 lots |
| **Bucket Balance** | Executor dashboard | $0 - $500+ | Negative (impossible) |
| **Win Rate** | Executor dashboard | > 80% | < 70% |
| **Heartbeat Age** | Check GV timestamps | < 10 seconds | > 60 seconds |
| **Spread** | Executor dashboard or Market Watch | < 20 points (Gold) | > 50 points |
| **Free Margin** | Account info | > 50% of balance | < 20% of balance |

### Alert Channels

#### MT5 Alerts (Always Active)

- Pop-up alert boxes in the terminal
- Check Alerts tab (Ctrl+T → Alerts) for history

#### Mobile Push Notifications

**Setup:**
1. Install MetaTrader 5 app on your phone
2. In the app: Settings → Messages → Copy your MetaQuotes ID
3. In MT5 desktop: Tools → Options → Notifications
4. Paste your MetaQuotes ID
5. Click "Test" to verify

**Enable in bots:**
- Executor: `InpEnablePushNotify = true`
- Guardian: `InpEnablePushNotify = true`

#### Email Notifications

**Setup:**
1. Tools → Options → Email tab
2. Enter SMTP server details (e.g., Gmail: smtp.gmail.com:587)
3. Enable SMTP server
4. Click "Test" to verify

**Enable in bots:**
- Executor: `InpEnableEmailNotify = true`
- Guardian: `InpEnableEmailNotify = true`

### Critical Alerts to Watch For

| Alert | Meaning | Action |
|---|---|---|
| `HEDGE INCREASED (Stage 1)` | Guardian placed first hedge at 30% DD | Monitor closely, review grid sizing |
| `HEDGE INCREASED (Stage 2)` | DD reached 35%, second hedge added | Consider manual intervention |
| `HEDGE INCREASED (Stage 3)` | DD reached 40%, final hedge added | High risk situation, monitor constantly |
| `CRITICAL: HARD STOP TRIGGERED!` | DD reached 45%, all positions closed | Post-mortem analysis needed, account protection activated |
| `CANNIBALISM: Killed trade #XXX` | Guardian used hedge profit to close a grid position | Normal, working as designed |
| `HEDGE UNWOUND @ XXXX` | Market recovered, Guardian closed hedge | Recovery successful |
| `CRITICAL: Grid Bot FROZEN!` | Executor stopped updating heartbeat | Check VPS, restart Executor |
| `OPTIMIZATION APPLIED` | Planner push was successful | Verify new parameters in dashboards |
| `WARNING: Price below grid` | Price dropped below Lower bound | Grid won't place new orders, Guardian should be hedging |
| `DREDGED: Level XX` | Bucket closed a deep position | Normal, cash flow system working |

---

## 11. Troubleshooting Common Issues

### Issue 1: "No Saved State Found - Using Input Parameters" (Executor)

**Cause:** First-time startup with Upper/Lower = 0.0

**Fix:**
1. Run Planner and configure it with your account settings
2. Click "PUSH TO LIVE" in Planner
3. Executor will receive the parameters and activate

---

### Issue 2: Dashboard Shows "⚠️ AUTO-RANGE MODE - USE PLANNER TO OPTIMIZE!"

**Cause:** Executor detected you're using default XAUUSD values on a non-XAUUSD instrument and activated Tier 3 Smart Defaults.

**What This Means:**
- Executor auto-calculated a price range based on current market price
- Lot sizes are still defaults (0.01/0.02/0.05) — likely not optimized for your balance
- System is functional but NOT optimized for your risk profile

**Fix:**
1. **Option A: Use Planner to optimize (Recommended)**
   - Configure Planner with your actual account balance and risk settings
   - Click "PUSH TO LIVE" in Planner
   - Executor will receive optimized parameters and clear the warning
   - Log will show: "✓ AUTO-RANGE MODE DEACTIVATED - Now using Planner-optimized configuration"

2. **Option B: Import a .SET file**
   - Create/load a .SET file with proper parameters for your instrument
   - Right-click Executor → Expert Advisors → Remove
   - Re-attach Executor and load the .SET file
   - Auto-range flag clears automatically

3. **Option C: Manual configuration**
   - Remove Executor from chart
   - Re-attach with properly configured Upper/Lower prices (not the XAUUSD defaults)
   - Auto-range won't activate if you provide instrument-appropriate values

**Is it safe to trade in AUTO-RANGE MODE?**
- **Demo/Testing:** Yes, fine for exploration
- **Live with small balance:** Proceed with caution, optimize within 1 hour
- **Live with large balance:** NOT recommended — always optimize first

---

### Issue 3: Executor Shows "PAUSED" or "FROZEN"

**Possible Causes:**

| Symptom | Cause | Fix |
|---|---|---|
| Status: PAUSED, Guardian: Hedging | Guardian's hedge is active | Wait for market recovery, Guardian will unwind |
| Status: PAUSED, Hard Stop | Equity dropped `InpHardStopDDPct`% below peak — all positions closed | Review drawdown, restart Executor with `InpResetState=true` after funding |
| Status: FROZEN, Grid validation failed | Grid parameters are invalid | Check Experts log, fix invalid Upper/Lower/Levels |

---

### Issue 3: Lots Don't Match Planner

**Example:** Planner shows 0.24/0.43/0.72, but Executor is using 0.01/0.02/0.05

**Cause:** PUSH TO LIVE was never clicked, or Executor didn't apply it

**Fix:**
1. Click "PUSH TO LIVE" in Planner
2. Wait 10 seconds
3. Check Executor log for "OPTIMIZATION APPLIED"
4. Check GlobalVariables: `205001_SG_LOT1/2/3` should match Planner
5. If still mismatched, restart Executor (remove from chart and re-attach)

---

### Issue 4: Zone/Lot Mismatch (Wrong Lots for Zone)

**Example:** Trade at $2658 (Zone 3) has 0.24 lots (Zone 1 lot size)

**Cause:** Zone floors were not recalculated after Planner push (fixed in v10.02, but may occur on older versions)

**Fix:**
1. Set `InpResetState = true` in Executor
2. Restart Executor (remove and re-attach)
3. PUSH TO LIVE from Planner again
4. Verify zone floors in Executor log:
   ```
   Zone1 Floor: $2700.00
   Zone2 Floor: $2666.67
   ```
5. Future trades should have correct lot sizes

---

### Issue 5: Duplicate Positions at Same Level

**Cause:** SyncMemory race condition (fixed in v10.02)

**Fix:**
1. Update to GridBot-Executor v10.02 or later
2. If on v10.02 and still seeing duplicates, check Experts log for "SYNC:" messages
3. Report the issue with log excerpts

---

### Issue 6: "Grid Validation Failed" on Startup

**Cause:** Indicator data not loaded yet (common on VPS after restart)

**Fix:**
- Wait 5-10 seconds and check again
- Executor now has a 3-retry mechanism with 2-second delays
- If it fails after 3 retries, check:
  - Is the symbol data available? (Market Watch → show symbol)
  - Is the broker server connected?

---

### Issue 7: Guardian Shows "Cannot Find SmartGrid"

**Cause:** Executor is not running or hasn't published GVs yet

**Fix:**
1. Start Executor first
2. Wait for Executor log to show "Initialization Complete"
3. Check GlobalVariables for `205001_SG_LOWER` (Guardian looks for this)
4. Then start Guardian

---

### Issue 8: Hedge Not Triggering

**Symptoms:** DD is at 32%, but Guardian hasn't hedged (T1 is 30%)

**Possible Causes:**

| Check | Solution |
|---|---|
| **Risk auto-scaling active** | If `InpAutoScaleToRisk = true` and Planner's MaxRisk = 15%, effective T1 = 10%, not 30%. Check Guardian log for "RISK SCALE:" message. |
| **Peak equity too high** | Guardian tracks peak equity (only moves up). If equity was $11,000 and is now $10,000, DD = 9%, not 32%. Check `999999_GH_PEAK_EQUITY` GV. |
| **Margin insufficient** | Free margin < 150% of required hedge margin. Check for "HEDGE BLOCKED" alert. |

**Fix:**
- Review Guardian log for the exact DD% it's calculating
- Manually check: `DD = (Peak - Current) / Peak × 100`
- If risk scaling is the issue, either disable it or adjust Planner's MaxRiskPerc

---

### Issue 9: High Memory Usage / MT5 Slow

**Cause:** Bucket queue or sync system accumulating too much data

**Fix (already implemented in v10.02):**
- Bucket queue is capped at 1000 items
- SyncMemory slow-path is rate-limited
- If still experiencing issues, reduce `InpBucketRetentionHrs` from 48 to 24

---

### Issue 10: Bucket Never Accumulates / No Dredging

**Symptoms:** Bucket stays at $0.00 for days

**Possible Causes:**

| Cause | Fix |
|---|---|
| Price never reaches Zone 2/3 | Normal if price stays in Zone 1 (upper third) |
| Zone 2/3 lot sizes too small | Profits are too tiny to accumulate. Increase Zone 2/3 lots via Planner. |
| All Zone 2/3 profits are expiring | Reduce `InpBucketRetentionHrs` is set too low, OR increase trade frequency by tightening gaps. |
| Virtual TP is off | Set `InpUseVirtualTP = true` |

---

## 12. Shutdown & Maintenance

### Graceful Shutdown (Recommended)

**When:** End of trading session, VPS maintenance, parameter changes

**Steps:**

1. **Stop new entries (Executor):**
   - Option A: Remove Executor from chart (right-click → Expert Advisors → Remove)
   - Option B: Set `InpMaxOpenPos = 0` and restart Executor (blocks new entries)

2. **Wait for positions to close (optional):**
   - If you want a clean slate, wait for price to rise and hit all TPs
   - This may take hours or days depending on market

3. **If Guardian is hedging:**
   - DO NOT remove Guardian while hedge is active
   - Wait for unwind, OR manually close hedge positions (Magic 999999)

4. **Remove bots from chart:**
   - Right-click chart → Expert Advisors → Remove All

5. **Verify state is saved:**
   - Tools → Global Variables
   - `205001_SG_LAST_UPDATE` should show recent timestamp
   - All state GVs should be present

6. **Export GlobalVariables (backup):**
   - In GlobalVariables window, there's no built-in export, but you can screenshot the list
   - OR use a script to export to file (advanced)

### Emergency Shutdown

**When:** Critical issue, need to close everything immediately

**Steps:**

1. **Close all positions manually:**
   - Trade tab → Right-click first position → Close All by Symbol

2. **Remove all bots:**
   - Right-click chart → Expert Advisors → Remove All

3. **Disable AutoTrading:**
   - Toolbar → Click AutoTrading button (turns gray)

4. **Review damage:**
   - History tab → Calculate total loss
   - Experts tab → Find the error/issue that triggered shutdown

### VPS Restart

**When:** Monthly VPS maintenance, Windows updates

**Before restart:**
1. No action needed — state is saved to GlobalVariables
2. GlobalVariables persist across MT5 restarts

**After restart:**
1. Open MT5
2. Reconnect to broker (if needed)
3. Re-attach **Executor** first, then **Guardian** (required — must run 24/7)
4. Verify state was restored (check dashboard values match pre-restart)
5. Re-attach **Planner** only if you need to re-optimize (it's on-demand, not required)

---

## 13. Recovery Procedures

### Recovery from Hard Stop

**Scenario:** Guardian triggered hard stop at 45% DD, all positions closed.

**Post-Mortem Analysis:**

1. **Review what happened:**
   - History tab → Filter by Magic 205001 and 999999
   - Calculate total realized loss
   - Identify when DD started (check old screenshots or logs)

2. **Root cause analysis:**
   - Was the range too narrow? (price dropped farther than expected)
   - Were lot sizes too large? (DD exceeded MaxRiskPerc)
   - Did Guardian fail to hedge in time? (check for "HEDGE BLOCKED" alerts)

3. **Adjustments before restarting:**
   - Increase balance (deposit more funds), OR
   - Reduce `InpMaxRiskPerc` in Planner (e.g., 30% → 20%), OR
   - Widen the range (increase `InpDaysToCover` or use manual levels)

**Restart Steps:**

1. Set `InpResetState = true` in Executor
2. Configure Planner with new risk settings
3. PUSH TO LIVE
4. Monitor closely for first 24 hours

---

### Recovery from Frozen Executor

**Scenario:** Executor heartbeat stopped updating (frozen/crashed).

**Steps:**

1. **Check VPS:**
   - Is MT5 running?
   - Is MT5 connected to broker?

2. **Check Experts log:**
   - Scroll to the last messages from Executor
   - Look for errors (e.g., "Access violation", "Array out of range")

3. **Restart Executor:**
   - Remove from chart
   - Re-attach with same settings
   - It should load saved state and resume

4. **Verify positions weren't orphaned:**
   - Trade tab → Check for positions with Magic 205001
   - Executor should remap them (check log for "SYNC: Level X relinked")

---

### Recovery from Corrupted GlobalVariables

**Scenario:** GVs show impossible values (e.g., Upper = 0, Levels = -5).

**Steps:**

1. **Backup current GVs:**
   - Screenshot the GlobalVariables window

2. **Delete corrupted GVs:**
   - Tools → Global Variables
   - Select all `205001_SG_*` keys
   - Click Delete

3. **Restart Executor with reset:**
   - Set `InpResetState = true`
   - Attach Executor
   - It will start fresh with input parameters (likely all 0)

4. **PUSH TO LIVE from Planner:**
   - Planner recalculates and pushes clean values

5. **Verify new GVs are sane:**
   - Check that Upper > Lower
   - Check that Levels is reasonable (10-150)
   - Check that Lots are within MIN_LOT and MAX_LOT

---

## 14. Best Practices

### Risk Management

1. **Start conservative:**
   - Use `STRIKE_MODE_5` (smallest zone multipliers)
   - Set `InpMaxRiskPerc = 25%` or lower
   - Use auto-lot to ensure sizing is correct

2. **Never risk more than you can afford to lose:**
   - Hard stop at 45% DD means you could lose nearly half your account in extreme scenarios
   - Only trade with risk capital

3. **Monitor drawdown daily:**
   - If DD consistently exceeds 20%, your risk settings are too aggressive
   - Reduce lot sizes or widen the range

### Position Sizing

1. **Use auto-lot unless you're experienced:**
   - `InpUseAutoLot = true` in Planner
   - It automatically sizes to your risk limit

2. **Verify lot sizes match broker specs:**
   - Check MIN_LOT (e.g., 0.01 for standard, 0.01 for cent)
   - Check VOLUME_STEP (e.g., 0.01)
   - Planner floors lots to the nearest step

3. **Don't manually override lots without understanding:**
   - Changing Zone 3 lot from 0.72 to 2.00 could 3x your drawdown
   - Always re-run Planner simulation after manual changes

### Grid Configuration

1. **Match the range to market conditions:**
   - Volatile markets (ATR > 2% of price): wider range
   - Calm markets (ATR < 1%): narrower range

2. **Don't extend the range downward:**
   - The bot does NOT extend downward (removed for safety)
   - If price falls below Lower, grid stops placing orders
   - Guardian should hedge in this scenario

3. **Dynamic upward shift is your friend:**
   - When price rallies, the grid shifts up automatically
   - Verify `InpEnableDynamicGrid = true`
   - Verify `InpUpShiftTriggerPct` and `InpUpShiftAmountPct` are set

### Bucket/Dredge Optimization

1. **Zone 2/3 should be active:**
   - If price never enters Zone 2/3, the bucket never fills
   - Consider widening the range or increasing `InpDaysToCover`

2. **Retention window should match trade frequency:**
   - High-frequency grids (trades every hour): 24-hour retention
   - Low-frequency grids (trades every day): 48-72 hour retention

3. **Survival ratio protects capital:**
   - If balance < initial, only 50% of bucket is used for dredging
   - This prevents "dredging yourself to death" during a losing streak

### Guardian Configuration

1. **Don't disable Guardian:**
   - It's your insurance policy
   - Even if you never expect 30% DD, it can happen

2. **Test hedge triggers in a demo account first:**
   - If you're unsure whether 30%/35%/40% is right, backtest or demo trade

3. **Risk auto-scaling keeps everything aligned:**
   - `InpAutoScaleToRisk = true` means Guardian's triggers adjust when you change Planner's MaxRiskPerc
   - You only need to change risk in one place (Planner)

### Monitoring Discipline

1. **Check the system daily:**
   - Morning: verify bots are running, check DD%
   - Evening: review P/L, check for alerts

2. **Don't ignore alerts:**
   - "CRITICAL" alerts require immediate action
   - "WARNING" alerts should be investigated

3. **Keep a trading journal:**
   - Note parameter changes, market conditions, performance
   - Review weekly to identify patterns

### Continuous Improvement

1. **Re-optimize monthly (or when market changes):**
   - ATR changes seasonally
   - Gold volatility spikes during geopolitical events
   - Re-run Planner and PUSH TO LIVE

2. **Analyze dredge effectiveness:**
   - If bucket accumulates but never dredges, threshold is too high
   - If dredging happens every hour, Zone 3 lots may be too small

3. **Review Guardian's history:**
   - If Guardian activates frequently (weekly), grid is under-capitalized
   - If Guardian never activates in 6 months, triggers may be too loose

---

## Quick Reference Card

### Startup Checklist

- [ ] MetaTrader 5 running and connected
- [ ] AutoTrading enabled (green button)
- [ ] Hedging account verified
- [ ] All 3 bot files compiled (zero errors)
- [ ] Executor started FIRST (required — runs 24/7)
- [ ] Guardian started SECOND (required — runs 24/7)
- [ ] Planner attached for initial optimization (on-demand — remove after push)
- [ ] Planner configured with account balance and risk
- [ ] PUSH TO LIVE clicked in Planner
- [ ] Executor log shows "OPTIMIZATION APPLIED"
- [ ] GlobalVariables populated (205001_SG_*, 999999_GH_*)
- [ ] Dashboards show correct values
- [ ] First order placed successfully

### Daily Health Check

- [ ] All dashboards visible and updating
- [ ] Heartbeats fresh (< 10 seconds)
- [ ] Drawdown < 20%
- [ ] Win rate > 80%
- [ ] No critical alerts in log
- [ ] Bucket accumulating (if Zone 2/3 trading)
- [ ] Free margin > 50% of balance

### Emergency Contacts

- **Broker Support:** [Your broker's support number/email]
- **VPS Support:** [Your VPS provider's support]
- **Bot Developer:** [Your contact/GitHub issues]

---

## Appendix: File Locations

| File Type | Location | Purpose |
|---|---|---|
| Bot source code (.mq5) | `MQL5/Experts/` | Edit and compile here |
| Compiled bots (.ex5) | `MQL5/Experts/` | Auto-generated on compile |
| Exported .SET files | `MQL5/Files/` | Settings backups from Planner |
| MT5 logs | `MQL5/Logs/` | Detailed terminal logs |
| Screenshots | `MQL5/Files/` or custom | Manual captures for records |

---

## Appendix: Glossary

| Term | Definition |
|---|---|
| **ATR** | Average True Range — volatility indicator |
| **Bucket** | Accumulated Zone 2/3 profits used for dredging |
| **Cannibalism** | Guardian using hedge profit to close grid positions |
| **Condensing Grid** | Grid with variable gap sizes (coefficient ≠ 1.0) |
| **DD / Drawdown** | (Peak Equity - Current Equity) / Peak Equity × 100 |
| **Dredging** | Closing the worst grid position using bucket funds |
| **GV** | GlobalVariable — MT5's key-value storage |
| **Heartbeat** | Timestamp published every tick to prove bot is alive |
| **Magic Number** | Unique ID for a bot's orders/positions |
| **Rolling Tail** | Limited window of pending orders (not all levels placed) |
| **Strike Mode** | Zone 2/3 lot size multiplier aggressiveness (1-5) |
| **Virtual TP** | Programmatic position close (not broker TP order) |
| **Zone** | Grid divided into 3 equal zones by price |

---

## Appendix: Recovering a Claude Code Session

If you accidentally close the Claude Code chat window while working with the AI assistant that maintains this system, **nothing is lost** — all session data is saved to disk automatically.

### Method 1 — Resume the Most Recent Session (fastest)

```bash
claude --continue
# or shorthand:
claude -c
```

Run this from the project directory. Claude resumes exactly where you left off, with full conversation history.

### Method 2 — Browse All Past Sessions (interactive picker)

```bash
claude --resume
# or shorthand:
claude -r
```

An interactive picker opens. Use `↑`/`↓` to navigate, `P` to preview session content, `/` to search by keyword, `Enter` to resume.

### Method 3 — Resume a Named Session (CLI only)

If you are using the **CLI terminal** (not the VS Code extension), you can name sessions for easy retrieval by typing inside an active chat:

```
/rename gridbot-2026-02-27
```

Then resume by name later:

```bash
claude --resume gridbot-2026-02-27
```

> **VS Code extension users:** `/rename` is not available in the VS Code panel. Instead, use the **Past Conversations** dropdown at the top of the Claude Code panel to browse and click any previous session — no naming needed.

### Where Sessions Are Stored

All session transcripts are saved as JSONL files:

```
C:\Users\khan\.claude\projects\c--Users-khan-Downloads-GridBot-Claude\
  └── <session-id>.jsonl      ← full conversation + tool outputs
  └── memory\
        ├── MEMORY.md          ← project knowledge (always loaded)
        ├── REF_CODEBASE_MAP.md
        └── REF_PROTOCOL_AND_FIXES.md
```

Sessions are only deleted if you manually remove these files.

### What Is Recoverable vs. Lost

| State | Recoverable? |
|---|---|
| Full conversation history | Yes — JSONL on disk |
| All file reads and edits | Yes — part of transcript |
| MEMORY.md project knowledge | Yes — auto-memory persists |
| In-progress code changes | Yes — files were already written |
| Background bash jobs | No — terminal processes stop |
| Approved permissions | No — re-approve on next session |

### If the Session Cannot Be Resumed (e.g., very old or corrupted)

The project memory files are designed exactly for this case. Start a new session and say:

> *"Continue from memory — load REF_CODEBASE_MAP.md and REF_PROTOCOL_AND_FIXES.md"*

Claude will load the reference files and resume with full project context, as if continuing from the previous session.

---

*GridBot Ecosystem Deployment Guide v1.3 — Last updated: 2026-02-27*

**For individual bot details, see:**
- [GUIDE_GridBot-Executor.md](GUIDE_GridBot-Executor.md)
- [GUIDE_GridBot-Guardian.md](GUIDE_GridBot-Guardian.md)
- [GUIDE_GridBot-Planner.md](GUIDE_GridBot-Planner.md)
