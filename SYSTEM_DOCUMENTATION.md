# GridBot System Documentation
## MT5 Automated Trading System — Three-Bot Architecture
*Generated: 2026-02-08 | Updated: 2026-02-28 | Source: 3 MQ5 files*

---

## 1. PROJECT OVERVIEW

### Purpose
This is a three-component MetaTrader 5 automated trading system designed primarily for **Gold (XAUUSD)**. It implements a grid trading strategy with integrated macro-level defense and an offline optimization planner. The system is designed to operate on a hedging account at Exness.

### System Philosophy
- **Primary strategy**: Buy-only grid trading (accumulate longs at declining price levels)
- **Defense layer**: Automated short hedging when drawdown thresholds are breached
- **Planning layer**: Offline physics simulation to calculate safe grid parameters before deploying

### Bot Roles Summary

| Bot File | Role | Trades? | Version |
|---|---|---|---|
| `GridBot-Planner_v23_04.mq5` | Planning & Optimization (HUD) | No | 23.04 |
| `GridBot-Executor_v10_Integrated.mq5` | Live Grid Trading Engine | Yes | 10.08 |
| `GridBot-Guardian_v3.1_Integrated.mq5` | Hedge Defense & Cannibalism | Yes | 3.13 |

---

## 2. INDIVIDUAL BOT ANALYSIS

---

### 2.1 GridBot-Planner_v23_04.mq5
**"The Physics Engine / Grid Planner"**

#### Primary Function
A read-only simulation and visualization tool. It does **not place trades**. It calculates optimal grid geometry using live market data and displays results on a canvas HUD. When satisfied with results, the operator clicks **"PUSH TO LIVE"** to inject parameters into the GridBot-Executor bot via GlobalVariables.

#### Key Features
- Grid geometry simulation with geometric progression (expansion coefficient)
- 3 range calculation modes (volatility-based, fixed %, manual levels)
- 2 gap calculation methods (auto geometry, ATR-targets with geometric fit)
- 5 strike modes controlling lot escalation ratios between zones
- Manual or auto-optimized strike selection
- Full financial simulation: margin, drawdown, liquidation price, profit factor
- Statistical analysis (sigma/probability calculation for range coverage)
- Visual canvas HUD with 4-column display
- "PUSH TO LIVE" button sends params to running GridBot-Executor
- "EXPORT .SET" generates a .set file for the grid bot

#### Input Parameters

| Group | Parameter | Default | Description |
|---|---|---|---|
| Strategy & Lots | `InpUseAutoLot` | true | Calculate lot from risk % |
| | `InpManualLot` | 0.01 | Lot if auto disabled |
| | `InpStrikeMethod` | STRIKE_MANUAL | Manual or auto-optimized |
| | `InpManualStrike` | STRIKE_MODE_5 | Strike mode 1-5 |
| Grid Geometry | `InpGapLogic` | GAP_ATR_TARGETS | ATR-based or geometric gap |
| | `InpGapTimeFrame` | TF_H4_VOLATILITY | TF for gap ATR calc |
| | `InpFirstGapPct` | 60.0 | First gap as % of ATR |
| | `InpLastGapPct` | 150.0 | Last gap as % of ATR |
| | `InpSpreadBuffer` | 3.0 | Gap must be > 3× spread |
| Range & Physics | `InpRangeMode` | RANGE_AUTO_VOLATILITY | Range calculation mode |
| | `InpManualUpper` | 0.0 | Manual upper price |
| | `InpManualLower` | 0.0 | Manual lower price |
| | `InpDaysToCover` | 22 | Volatility days for auto range |
| | `InpFixedDropPct` | 20.0 | Fixed drop % for mode B |
| | `InpEfficiency` | 0.85 | Base density multiplier |
| Account & Risk | `InpAccountBalance` | 200,000 | Simulated balance |
| | `InpMaxRiskPerc` | 25.0 | Max DD % allowed |
| | `InpSimLeverage` | 200 | Simulated leverage |
| | `InpMinMarginLvl` | 300.0 | Minimum margin level % |
| | `InpStopOutLevel` | 50.0 | Broker stop-out level % |
| Dredging Logic | `InpDredgeMinRangePerc` | 60.0 | Only dredge top 60% of range |

#### Strike Modes (Lot Zone Multipliers)
| Mode | Zone 2 Multiplier | Zone 3 Multiplier | Character |
|---|---|---|---|
| 1 (Most Aggressive) | 2.5× | 6.0× | Heaviest bottom loading |
| 2 | 2.2× | 4.5× | — |
| 3 | 2.0× | 3.5× | — |
| 4 | 1.8× | 3.0× | — |
| 5 (Most Conservative) | 1.5× | 2.5× | Lightest bottom loading |

#### Trading Logic
This bot does not trade. It simulates placing `CalcLevels` buy orders between `CalcLower` and `CalcUpper` with progressively increasing lot sizes (3-zone model) and computes:
- Maximum drawdown if price reaches `CalcLower`
- Average entry price, liquidation price
- Estimated cycle profit, profit factor, coverage ratio
- Statistical sigma/probability that price covers the range

#### Key Functions
| Function | Purpose |
|---|---|
| `RunUniversalSolver()` | Master solver: fetches indicators, calculates range, fits geometry |
| `CalculateSimulation()` | Full simulation: lots, margins, DD, profit for given parameters |
| `ApplyStrikeModeLogic()` | Calculates zone lot sizes based on active strike mode |
| `GetOptimalLevelCount()` | Determines level count from range / ATR ratio |
| `FetchIndicators()` | Reads ATR (D1, H1, selected TF) and RSI buffers |
| `PushToLive()` | Writes optimization results to GlobalVariables for SmartGrid |
| `SaveSetFile()` | Exports .set configuration file |
| `DrawHUD()` | Renders the 4-column canvas dashboard |
| `UpdateChartLines()` | Draws upper/lower/BE/dredge/liquidation lines on chart |

#### RSI Skew Mechanism
RSI (14, D1) is used to skew the range asymmetrically:
- `SkewVal = RSI / 100`, clamped to [0.5, 0.85]
- Controls proportion of range above vs below current price
- Higher RSI → more range allocated upward

---

### 2.2 GridBot-Executor_v10_Integrated.mq5
**"The Live Trading Engine"**

#### Primary Function
The active grid trading bot. Places BUY_LIMIT orders at calculated grid levels and manages the full lifecycle: fills → profit-taking → loss absorption via the "Bucket" dredge system. Coordinates with Guardian (pauses when hedging is active) and accepts remote parameter updates from the Master bot.

#### Key Features
- Condensing grid geometry with configurable expansion coefficient
- 3-zone lot escalation (configurable per zone)
- Dynamic upward grid shift when price breaks out above grid
- Rolling tail: caps the number of active pending orders
- Bucket cash flow engine: collects zone 2/3 profits, uses them to close worst positions
- Virtual TP system (closes positions programmatically when bid reaches grid TP level)
- State persistence via GlobalVariables (survives restarts)
- Guardian freeze protocol (halts new orders when Guardian hedge is active)
- Remote optimization: accepts parameter pushes from Master bot
- Self-healing: scans for orphaned positions and relinks them to grid levels
- Push/email notifications

#### Input Parameters

| Group | Parameter | Default | Description |
|---|---|---|---|
| System Control | `InpResetState` | false | Wipe saved state and restart fresh |
| | `InpMagicNumber` | 205001 | Unique trade identifier |
| | `InpComment` | "SmartGrid_v10" | Order comment |
| Grid Settings | `InpUpperPrice` | 2750.0 | Initial top (XAUUSD) |
| | `InpLowerPrice` | 2650.0 | Initial bottom |
| | `InpGridLevels` | 45 | Number of grid levels |
| | `InpExpansionCoeff` | 1.0 | Gap ratio between levels (1.0=uniform) |
| | `InpStartAtUpper` | false | Start first level at upper price |
| Dynamic Grid | `InpEnableDynamicGrid` | true | Enable grid shift |
| | `InpUpShiftTriggerPct` | 0.10 | Buffer above upper before shifting |
| | `InpUpShiftAmountPct` | 20.0 | Shift amount as % of range |
| Rolling Tail | `InpMaxPendingOrders` | 20 | Max simultaneous pending orders |
| Volume Zones | `InpLotZone1` | 0.01 | Lot for top third |
| | `InpLotZone2` | 0.02 | Lot for middle third |
| | `InpLotZone3` | 0.05 | Lot for bottom third |
| Cash Flow / Bucket | `InpUseBucketDredge` | true | Enable bucket system |
| | `InpBucketRetentionHrs` | 48 | Profit expires from bucket after N hours |
| | `InpSurvivalRatio` | 0.5 | Spend only 50% of bucket if in loss |
| | `InpDredgeRangePct` | 0.5 | Profit only added from zone 2+ |
| | `InpUseVirtualTP` | true | Software-managed TP |
| Risk & Safety | `InpHardStopDDPct` | 25.0 | Hard stop drawdown % from peak balance (tracks realized profits only, range 1-50%) |
| | `InpMaxOpenPos` | 100 | Max open positions |
| | `InpMaxSpread` | 2000 | Max spread in points |
| Guardian Integration | `InpEnableGuardianCoordination` | true | Enable freeze protocol |
| | `InpCoordinationCheckInterval` | 5 | Seconds between Guardian checks |
| | `InpAllowRemoteOpt` | true | Accept Master bot parameter pushes |

#### Grid Geometry
The grid uses a geometric progression (condensing grid):
```
FirstGap = Range * (1 - Coeff) / (1 - Coeff^Levels)   [if Coeff != 1]
FirstGap = Range / Levels                               [if Coeff == 1, uniform]
```
- Gap at level i = FirstGap × Coeff^i
- Levels are placed from upper downward
- Zone boundaries: top-third / mid-third / bottom-third by count

#### Trading Logic
1. Places BUY_LIMIT orders at each `GridPrices[i]` level
2. Each order has a virtual TP at `GridTPs[i]` (the price of the level above it)
3. As levels fill, the bot tracks P&L per zone
4. Zone 2 and 3 closed profits are added to the Bucket
5. Bucket funds can be spent to close ("dredge") the worst-performing open position
6. No downward grid extension (disabled to prevent runaway margin use)

#### Entry Conditions (ManageGridEntry)
- Grid is healthy (all prices/lots valid, sequential)
- Spread ≤ `InpMaxSpread`
- Not paused/frozen
- Level has no existing order/position
- Sufficient free margin (1.1× required margin)
- Price is above target (buy limit)
- Pending count < `InpMaxPendingOrders`

#### Exit Conditions
- Virtual TP: bid ≥ `GridTPs[idx]` → position closed
- Bucket dredge: worst loss position closed if bucket has sufficient funds
- Hard stop: all positions closed if equity drops `InpHardStopDDPct`% from peak balance (balance-based floor, equity-based trigger)
- Guardian hard stop: triggered externally via `HEDGE_BOT_ACTIVE` global var

#### Key Functions
| Function | Purpose |
|---|---|
| `OnTick()` | Main loop: coordination checks, equity checks, grid management |
| `CalculateCondensingGrid()` | Computes all GridPrices, GridTPs, GridLots arrays |
| `ManageGridEntry()` | Places BUY_LIMIT orders at unfilled levels |
| `ManageExits()` | Virtual TP — closes positions when bid hits TP level |
| `ManageBucketDredging()` | Closes worst loss position using bucket funds |
| `ScanForRealizedProfits()` | Scans deal history for new profits to add to bucket |
| `CheckDynamicGrid()` | Shifts grid up when price breaks above |
| `ManageRollingTail()` | Trims excess pending orders from bottom |
| `SyncMemoryWithBroker()` | Verifies tickets, relinks orphans |
| `CheckGuardianCoordination()` | Reads `HEDGE_ACTIVE` GV; returns early (freeze) when Guardian is active |
| `CheckForOptimizationUpdates()` | Receives parameter pushes from Master |
| `PublishCoordinationData()` | Writes net exposure, state flags to GlobalVars |
| `SaveSystemState()` / `LoadSystemState()` | Persist grid range/bucket to GlobalVars |
| `RebuildGrid()` | Full grid reconstruction after shift or remote opt |

---

### 2.3 GridBot-Guardian_v3.1_Integrated.mq5
**"The General" — Macro Defense & Cannibalism Engine**

#### Primary Function
A defensive overlay bot that monitors account drawdown and deploys short-sell hedges in stages when drawdown thresholds are breached. Additionally implements "Cannibalism": using hedge profits to forcibly close the worst-performing grid positions (loss shifting).

#### Key Features
- Auto-detection of running SmartGrid bot via GlobalVariable scanning
- 3-stage staggered hedging (activates incrementally as DD deepens)
- Hard stop at configurable DD% (emergency close-all)
- Cannibalism logic: hedge profit → close worst grid trade → reduce net exposure
- Hedge held open as shield (no broker SL, no trailing stop — exits only via 4 managed paths: SafeUnwind, Cannibalism, Duration limit, Hard Stop)
- Unwind logic: closes hedge when price returns to range AND DD recovers
- Hedge duration limit (force-close after N hours to control swap cost)
- Grid heartbeat monitoring with throttled alerts (once per 5 min, requires both HEARTBEAT and LAST_UPDATE stale)
- Full state persistence (survives restarts with 24-hour staleness check)

#### Input Parameters

| Group | Parameter | Default | Description |
|---|---|---|---|
| Auto-Detection | `InpAutoDetectGrid` | true | Auto-scan for SmartGrid |
| | `InpManualGridMagic` | 0 | Manual override (0=auto) |
| | `InpHedgeMagic` | 999999 | This bot's trade ID |
| Trigger Logic | `InpHedgeTrigger1` | 30.0% | Stage 1 DD threshold |
| | `InpHedgeRatio1` | 0.30 | Stage 1 sell = 30% of grid volume |
| | `InpHedgeTrigger2` | 35.0% | Stage 2 DD threshold |
| | `InpHedgeRatio2` | 0.30 | Stage 2 adds another 30% (total ~60%) |
| | `InpHedgeTrigger3` | 40.0% | Stage 3 DD threshold |
| | `InpHedgeRatio3` | 0.35 | Stage 3 adds 35% (total ~95%) |
| | `InpHardStopDD` | 45.0% | Nuclear option: close everything |
| Cannibalism | `InpEnablePruning` | true | Enable cannibalism |
| | `InpPruneThreshold` | 100.0 | Min hedge profit ($) before pruning |
| | `InpPruneBuffer` | 20.0 | Safety buffer ($) during pruning |
| Unwind & Recovery | `InpManualLowerPrice` | 0.0 | Fallback grid bottom if GV fails |
| | `InpManualUpperPrice` | 0.0 | Fallback grid top if GV fails |
| | `InpSafeUnwindDD` | 20.0 | Close hedge when DD drops below this (in range) |
| Safety & Limits | `InpMinFreeMarginPct` | 150.0 | Require 150% margin before hedging |
| | `InpMaxHedgeDurationHrs` | 72 | Force close hedge after 72 hours |
| | `InpEnableStateRecovery` | true | Persist state across restarts |

#### Staggered Hedging Logic
```
DD ≥ 30% → Sell 30% of grid net volume (Stage 1)
DD ≥ 35% → Sell additional 30% (total ~60%) (Stage 2)
DD ≥ 40% → Sell additional 35% (total ~95%) (Stage 3)
DD ≥ 45% → ExecuteHardStop(): close ALL grid + hedge positions
```

#### Cannibalism Process
1. Wait for hedge profit ≥ `InpPruneThreshold` ($100)
2. Find the worst-performing grid position (most negative P&L)
3. Check: hedge profit - `InpPruneBuffer` > loss amount
4. Partially close hedge to match new (reduced) grid exposure
5. Close the worst grid position (net equity impact is neutral or positive)
6. Record to g_TotalPruned counter

#### Unwind Logic (4 exit paths — no broker SL)
- **Below or above grid range**: Hold hedge open — shield stays alive
- **Inside grid range, DD < `InpSafeUnwindDD`**: Close hedge fully (recovery confirmed)
- **Duration limit reached**: Force-close after 72 hours (swap protection)
- **Hard stop**: Emergency close-all at DD >= `InpHardStopDD`

#### Key Functions
| Function | Purpose |
|---|---|
| `OnTick()` | Main loop: health check, DD tracking, staggered hedge decisions |
| `DetectSmartGrid()` | Scans all GlobalVariables for `*_SG_LOWER` pattern |
| `VerifyGridConnection()` | Confirms detected grid data is valid and recent |
| `ExecuteHedge(stage)` | Places sell order for the volume delta needed |
| `ManageUnwindLogic(DD)` | Decides whether to hold or close hedge |
| `ProcessCannibalism()` | Kill worst grid position using hedge profit |
| `ExecuteHardStop()` | Emergency: close all positions for both bots |
| `CheckHedgeDuration()` | Force-close hedge if older than 72 hours |
| `CheckGridHealth()` | Monitors SmartGrid heartbeat for freezes (throttled 5 min) |
| `VerifyExposureBalance()` | Checks hedge volume matches expected ratio |

---

## 3. INTER-BOT DEPENDENCIES

### Communication Architecture
All three bots communicate exclusively via **MT5 GlobalVariables** (shared memory). No direct function calls or file I/O between bots.

### GlobalVariable Map

```
┌─────────────────────────────────────────────────────────────────┐
│                    GLOBAL VARIABLE CHANNELS                      │
├──────────────────────────┬──────────────────────────────────────┤
│ Variable Name            │ Publisher → Readers                   │
├──────────────────────────┼──────────────────────────────────────┤
│ 205001_SG_UPPER          │ GridBot-Executor → Guardian, Master │
│ 205001_SG_LOWER          │ GridBot-Executor → Guardian, Master │
│ 205001_SG_LEVELS         │ GridBot-Executor → Guardian        │
│ 205001_SG_COEFF          │ GridBot-Executor → Guardian        │
│ 205001_SG_BUCKET         │ GridBot-Executor (internal persist) │
│ 205001_SG_LAST_UPDATE    │ GridBot-Executor → Guardian        │
│ 205001_SG_HEARTBEAT      │ GridBot-Executor → Guardian        │
│ 205001_SG_NET_EXPOSURE   │ GridBot-Executor → Guardian        │
│ SG_DREDGE_TARGET         │ GridBot-Executor → Guardian        │
│ GRID_BOT_ACTIVE          │ GridBot-Executor → Guardian        │
├──────────────────────────┼──────────────────────────────────────┤
│ HEDGE_BOT_ACTIVE         │ Guardian → GridBot-Executor        │
│ 999999_GH_*              │ Guardian (internal state persist)     │
├──────────────────────────┼──────────────────────────────────────┤
│ 205001_SG_OPT_NEW_UPPER  │ GridBot-Planner → GridBot-Executor│
│ 205001_SG_OPT_NEW_LOWER  │ GridBot-Planner → GridBot-Executor│
│ 205001_SG_OPT_NEW_LEVELS │ GridBot-Planner → GridBot-Executor│
│ 205001_SG_OPT_NEW_COEFF  │ GridBot-Planner → GridBot-Executor│
│ 205001_SG_OPT_CMD_PushTime│ GridBot-Planner → GridBot-Executor│
└──────────────────────────┴──────────────────────────────────────┘
```

### Relationships & Hierarchy

```
┌─────────────────────────────────────────────────────┐
│           GridBot-Planner (Planner)                 │
│    - No trading, HUD only                           │
│    - Calculates optimal parameters                  │
│    - PUSH TO LIVE → injects via GlobalVars          │
└────────────────────────┬────────────────────────────┘
                         │ OPT_NEW_* GlobalVars
                         ▼
┌─────────────────────────────────────────────────────┐
│        GridBot-Executor (GridBot-Planner)               │
│    - Places buy limit grid orders                   │
│    - Runs Bucket cash flow engine                   │
│    - Publishes heartbeat & net exposure             │
│    - FREEZES when Guardian is hedging               │
└────────────┬────────────────────────────────────────┘
             │  GRID_BOT_ACTIVE, NET_EXPOSURE, UPPER/LOWER
             ▼
┌─────────────────────────────────────────────────────┐
│         GridBot-Guardian (Defender)                │
│    - Monitors DD from peak equity                   │
│    - Deploys staged short hedges                    │
│    - Cannibalizes worst grid positions              │
│    - Publishes HEDGE_BOT_ACTIVE flag                │
└─────────────────────────────────────────────────────┘
```

### Master/Slave Relationships
- **GridBot-Planner** is an operator tool (no trading), acts as configuration master
- **GridBot-Executor** is the active trading engine, slave to Master for parameters
- **Guardian** is an autonomous defense system, its `HEDGE_BOT_ACTIVE` flag gives it authority to **pause** GridBot-Executor
- When Guardian activates: GridBot-Executor stops placing new orders (frozen)
- When Guardian deactivates: GridBot-Executor resumes automatically

---

## 4. WORKFLOW AND EXECUTION FLOW

### System Startup Sequence
```
1. Run GridBot-Executor first
   → It publishes GlobalVars: UPPER, LOWER, LEVELS, COEFF, GRID_BOT_ACTIVE=1

2. Run GridBot-Guardian
   → It auto-detects SmartGrid by scanning GlobalVars for *_SG_LOWER pattern
   → Verifies connection, loads/initializes state

3. Run GridBot-Planner (optional, for monitoring/planning)
   → Attaches to any chart, reads market data for simulation
   → NOTE: Master hardcodes prefix "205001_SG_" — must match SmartGrid magic
```

### Tick-by-Tick Execution (GridBot-Executor)
```
OnTick() {
   1. Check Guardian coordination (HEDGE_BOT_ACTIVE)
      → If active: FREEZE (update heartbeat, track peak balance, return)
   2. Check equity stop condition (dynamic hard stop — peak balance based)
      → If triggered: close all, stop
   3. Check dynamic grid (upward shift if breakout)
   4. SyncMemoryWithBroker() — verify/repair level-ticket linkages
   5. ManageRollingTail() — trim excess pending orders
   6. ScanForRealizedProfits() — add profits to Bucket
   7. CleanExpiredBucketItems() — remove stale bucket entries
   8. If spread OK:
      a. ManageGridEntry() — place new buy limits
      b. ManageExits() — close positions at virtual TP
      c. ManageBucketDredging() — close worst loss using bucket
   9. DrawBreakEvenLine()
  10. PublishCoordinationData() — update GlobalVars for Guardian
  11. Write heartbeat timestamp
  12. CheckForOptimizationUpdates() — apply Master bot pushes
}
```

### Tick-by-Tick Execution (Guardian)
```
OnTick() {
   1. CheckGridHealth() — monitor SmartGrid heartbeat
   2. Track current equity; update peak equity if new high
   3. Calculate current DD = (peak - equity) / peak × 100
   4. If DD ≥ HardStopDD (45%): ExecuteHardStop() — close everything
   5. Determine desired hedge stage based on DD thresholds
   6. If desiredStage > g_HedgeStage: ExecuteHedge(desiredStage)
   7. Every 5 seconds (InpFullCheckInterval):
      a. Publish HEDGE_BOT_ACTIVE flag
      b. VerifyHedgeHealthy()
      c. ManageUnwindLogic() — trail/close hedge on recovery
      d. ProcessCannibalism() — use hedge profit to kill bad grid trade
      e. CheckHedgeDuration() — force close if too old
      f. CheckGridExpansion() — monitor grid level changes
      g. VerifyExposureBalance() — detect hedge/grid mismatch
   8. UpdateDashboard()
}
```

### Optimization Push Flow (Master → Ultimate)
```
1. Master runs physics simulation on current market data
2. Operator clicks "PUSH TO LIVE" button
3. Master writes to GlobalVars:
   - 205001_SG_OPT_NEW_UPPER
   - 205001_SG_OPT_NEW_LOWER
   - 205001_SG_OPT_NEW_LEVELS
   - 205001_SG_OPT_NEW_COEFF
   - 205001_SG_OPT_NEW_LOT1/2/3
   - 205001_SG_MAX_RISK_PCT
   - 205001_SG_OPT_CMD_PushTime = current timestamp
4. Within ~10 seconds, GridBot-Executor's CheckForOptimizationUpdates() fires:
   - Validates new params
   - Pauses trading
   - Deletes all pending orders
   - Updates grid parameters and runtime lot sizes
   - Recalculates zone floors
   - Rebuilds grid
   - Records OPT_LAST_APPLIED timestamp (prevents double-apply)
   - Resumes trading
```

### Hedge Lifecycle
```
Normal State:
  Grid bot running → accumulating buy positions → collecting profits in Bucket

Stress State (price falling):
  DD hits 30% → Guardian sells 30% of grid volume short
  DD hits 35% → Guardian sells more shorts (total ~60% hedge)
  DD hits 40% → Guardian sells more shorts (total ~95% hedge)
  → GridBot-Executor FREEZES (no new entries)

  While hedged:
  → Hedge held open as shield (no broker SL, no trailing stop)
  → Exits only via: SafeUnwind / Cannibalism / Duration limit / Hard Stop
  → Cannibalism: when hedge profit > $100, close worst grid trade

Recovery:
  Price recovers to within grid range AND DD < 20%
  → Guardian closes hedge completely
  → GridBot-Executor unfreezes and resumes

Nuclear option:
  DD hits 45% → Close ALL positions (grid + hedge)
```

---

## 5. TECHNICAL IMPLEMENTATION

### Dependencies & Libraries
| Bot | Library | Purpose |
|---|---|---|
| GridBot-Planner | `<Canvas\Canvas.mqh>` | HUD rendering on chart bitmap |
| GridBot-Executor | `<Trade\Trade.mqh>` | CTrade class for order management |
| GridBot-Guardian | `<Trade\Trade.mqh>` | CTrade class for order management |

### Key MT5 Functions Used
- `GlobalVariableSet/Get/Check/Del` — inter-bot communication
- `iATR`, `iRSI` — technical indicators for range/gap calculation
- `CopyBuffer` — reading indicator values
- `trade.BuyLimit()`, `trade.Sell()` — order placement
- `trade.PositionClose()`, `trade.PositionClosePartial()` — position management
- `trade.OrderDelete()` — cancel pending orders
- `PositionSelectByTicket`, `OrderSelect` — position/order lookup
- `HistorySelect`, `HistoryDealGetTicket` — scan closed trade history
- `SendNotification`, `SendMail` — push/email alerts
- `OrderCalcMargin` — pre-trade margin validation
- `ObjectCreate`, `ObjectSetDouble` — chart line drawing
- `EventSetTimer` — periodic timer callbacks

### Important Variable Roles

**GridBot-Executor:**
| Variable | Role |
|---|---|
| `g_BucketQueue[]` | FIFO queue of realized profits with timestamps |
| `g_BucketTotal` | Sum of bucket queue |
| `g_LevelTickets[]` | Maps each grid level to its active order/position ticket |
| `g_LevelLock[]` | Prevents duplicate orders while one is being placed |
| `GridPrices[]` | Entry price for each level |
| `GridTPs[]` | Take-profit price for each level (= price of level above) |
| `GridLots[]` | Lot size for each level (zone-dependent) |
| `g_WorstPositions[3]` | Top-3 worst-loss positions (for dredging) |
| `IsGuardianActive` | True when Guardian HEDGE_ACTIVE=1 (Executor returns early) |

**Guardian:**
| Variable | Role |
|---|---|
| `g_MaxEquity` | Peak equity high-water mark for DD calculation |
| `g_HedgeStage` | Current hedge stage (0=none, 1/2/3=active) |
| `g_HedgeTicket` | Ticket of the active hedge short position |
| `g_HedgeOpenVolume` | Total volume of active hedge |
| `g_DetectedGridMagic` | Magic number of the linked SmartGrid |
| `g_GridGVPrefix` | String prefix for all SmartGrid GlobalVars |
| `g_CannibalismCount` | Count of successful cannibalisms |
| `g_TotalPruned` | Total dollar value pruned via cannibalism |

### Magic Number Cross-Reference
| Bot | Magic Number | Usage |
|---|---|---|
| GridBot-Executor | 205001 (default) | All buy limit orders use this |
| GridBot-Guardian | 999999 (default) | Hedge sell positions use this |
| GridBot-Planner | Hardcoded "205001" | GetGVKey() prefix for all GlobalVars |

> **Critical**: GridBot-Planner has `return "205001_SG_" + suffix` hardcoded at line 208. This must match the magic number configured in GridBot-Executor.

---

## 6. CONFIGURATION AND SETTINGS

### Global Settings Affecting All Bots
| Setting | Where Set | Description |
|---|---|---|
| Magic Number | GridBot-Executor `InpMagicNumber` | All GlobalVar prefixes derive from this |
| Symbol | Chart attachment | All bots run on the same chart symbol |
| Account type | Broker | Must be HEDGING type (netting disabled) |

### Critical Configuration Interdependencies

1. **Magic Number Sync**: GridBot-Executor's `InpMagicNumber` (default 205001) must match the hardcoded `205001` in GridBot-Planner's `GetGVKey()`. If you change the magic number in Ultimate, you must update the Master source code at [GridBot-Planner_v23_04.mq5:208](GridBot-Planner_v23_04.mq5#L208) and recompile.

2. **Guardian Auto-Detection**: Guardian auto-detects SmartGrid by scanning for `*_SG_LOWER` in GlobalVars. This works as long as GridBot-Executor uses the standard `{magic}_SG_` prefix format.

3. **Exness Broker Specific**: The GridBot-Executor checks for `IOC` or `FOK` filling modes via `GetFillingMode()`. Default deviation is 50 points.

### Per-Bot Configuration Priorities

**GridBot-Planner** — Adjust these first (planning):
- `InpAccountBalance`, `InpMaxRiskPerc`, `InpSimLeverage` — risk parameters
- `InpRangeMode` + range inputs — define the grid range
- `InpGapLogic` + gap inputs — define grid spacing
- Strike mode — define lot escalation aggressiveness

**GridBot-Executor** — Operational settings:
- `InpUpperPrice`, `InpLowerPrice` — initial range (overridden by Master push or saved state)
- `InpGridLevels`, `InpExpansionCoeff` — grid geometry
- `InpLotZone1/2/3` — actual lots to trade
- `InpMaxPendingOrders` — bandwidth control
- `InpHardStopDDPct` — hard stop % from peak equity (auto-calculated floor, never drifts)
- `InpResetState = true` — use once when starting completely fresh

**Guardian** — Defense parameters:
- Trigger DD% levels (30/35/40/45) — tune to account risk tolerance
- `InpHedgeRatio1/2/3` — hedge size at each stage
- `InpPruneThreshold` — when to start cannibalizing
- `InpMaxHedgeDurationHrs` — swap cost control
- `InpSafeUnwindDD` — how much recovery needed before unwinding

### Recommended Startup Order
1. Configure GridBot-Planner with your account balance and risk parameters
2. Run simulation until IsCapitalSafe = true and risk metrics are acceptable
3. Click "EXPORT .SET" to generate configuration file
4. Load the .set file into GridBot-Executor
5. Verify InpMagicNumber matches Master's hardcoded 205001
6. Start GridBot-Executor (it will publish GlobalVars)
7. Start GridBot-Guardian (auto-detects SmartGrid)
8. Keep GridBot-Planner running for live monitoring and re-optimization

### How to Modify Settings Live
- **Grid range only** (no downtime): Use Master's "PUSH TO LIVE" — GridBot-Executor will rebuild the grid automatically
- **Lot sizes**: Must change `InpLotZone1/2/3` in Ultimate's inputs (requires EA restart or input change)
- **Hedge thresholds**: Change Guardian inputs — takes effect immediately on next tick
- **Full reset**: Set `InpResetState = true` in Ultimate, restart → rebuilds from input defaults, clears bucket
