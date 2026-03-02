# GridBot-Steward v1.0 — System Documentation

## Table of Contents

1. [Architecture Overview](#1-architecture-overview)
2. [Why Unified? Design Rationale](#2-why-unified-design-rationale)
3. [Internal Data Flow (OnTick Phases)](#3-internal-data-flow-ontick-phases)
4. [Global State Variables](#4-global-state-variables)
5. [Two CTrade Instance Design](#5-two-ctrade-instance-design)
6. [GlobalVariable Interface (GV Map)](#6-globalvariable-interface-gv-map)
7. [State Persistence Protocol](#7-state-persistence-protocol)
8. [PA Fix Disposition (All 26)](#8-pa-fix-disposition-all-26)
9. [Peak Tracking: Two Variables, Two Purposes](#9-peak-tracking-two-variables-two-purposes)
10. [Hard Stop Architecture](#10-hard-stop-architecture)
11. [Hedge Engine Internals](#11-hedge-engine-internals)
12. [Grid Engine Internals](#12-grid-engine-internals)
13. [Bucket/Dredge Engine Internals](#13-bucketdredge-engine-internals)
14. [Planner Compatibility Verification](#14-planner-compatibility-verification)
15. [Verification Checklist](#15-verification-checklist)
16. [Known Limitations](#16-known-limitations)

---

## 1. Architecture Overview

GridBot-Steward is a clean-sheet unified Expert Advisor that combines the grid trading logic (previously in GridBot-Executor) and the hedge defense logic (previously in GridBot-Guardian) into a single MQL5 process.

```
┌────────────────────────────────────────────────┐
│              GridBot-Steward v1.0              │
│                                                │
│  ┌──────────────┐    ┌────────────────────┐   │
│  │  Grid Engine │    │   Hedge Engine     │   │
│  │  (tradeGrid) │    │  (tradeHedge)      │   │
│  │  magic=205001│    │  magic=999999      │   │
│  └──────┬───────┘    └────────┬───────────┘   │
│         │                     │               │
│         │    g_HedgeActive    │               │
│         │◄────────────────────┘               │
│         │    (local bool — zero latency)      │
│                                               │
│  ┌─────────────────────────────────────┐      │
│  │         Unified OnTick              │      │
│  │  Phase 0-4: Hedge DD + hard stops   │      │
│  │  Phase 5-6: Hedge management        │      │
│  │  Phase 7:   Freeze gate             │      │
│  │  Phase 8-9: Grid hard stop + ops    │      │
│  │  Phase 10:  Publish GVs             │      │
│  └─────────────────────────────────────┘      │
│                                               │
│  ┌─────────────────────────────────────┐      │
│  │         GV Interface                │      │
│  │  Publishes: {205001}_SG_*           │      │
│  │  Publishes: {999999}_GH_*           │      │
│  │  Reads:     {205001}_SG_OPT_*       │      │
│  └─────────────────────────────────────┘      │
└────────────────────────────────────────────────┘
         ▲                        ▲
         │ reads GVs              │ reads GVs
         │                        │
  ┌──────────────┐        ┌───────────────────┐
  │  GridBot-    │        │  MT5 GlobalVar    │
  │  Planner     │        │  Terminal         │
  └──────────────┘        └───────────────────┘
```

**Key design decisions:**
1. **Two CTrade instances** — no magic-switching, no race conditions
2. **Freeze = local bool** — zero latency, no GV polling
3. **Two peak variables** — balance-based (grid stop) and equity-based (hedge DD)
4. **GV interface preserved** — Planner works without modification
5. **Existing bots untouched** — complete rollback safety

---

## 2. Why Unified? Design Rationale

### The Problem with Two-Bot Architecture

Executor and Guardian communicated via GlobalVariables:
- Guardian set `{magic}_SG_HEDGE_ACTIVE = 1`
- Executor polled every `InpCoordinationCheckInterval` seconds (default 5s, reduced to 1s in PA26)
- **PA26 worst case:** Executor could still place a BuyLimit in the ~1s window between hedge execution and the next poll

More fundamentally, even with PA26, the communication was **asynchronous by design**. The hedge and grid were in separate processes with no shared memory.

### The Steward Solution

Both engines run in the same process. `g_HedgeActive` is a C-style boolean in shared memory. When `ExecuteHedge()` sets it to `true`, the next call to `ManageGridEntry()` reads `true` immediately — no poll, no delay, no window.

**PA26 becomes architecturally impossible** in Steward. The bug class (new grid order placed while hedge active) cannot occur.

### What Was NOT Changed

- Strategy logic: same condensing grid, same staggered hedge, same cannibalism
- Risk model: same DD% triggers, same ratios, same SafeUnwind conditions
- GV interface: same key names, same namespaces, Planner reads correctly
- Magic numbers: same 205001/999999, same Planner link

### Scope

Steward replaces Executor + Guardian only. GridBot-Planner remains a separate EA on a separate chart. Planner's role (simulation, optimization, HUD) is unchanged.

---

## 3. Internal Data Flow (OnTick Phases)

```
Phase 0: Heartbeat
  GlobalVariableSet("{magic}_SG_HEARTBEAT", TimeCurrent())
  Always executes. Never bypassed. [PA25 baked in]

Phase 1: Trading halt gate
  if(!IsTradingActive) return;
  Fires after grid hard stop. Hedge continues in Phases 0-6.

Phase 2: Price staleness guard
  if(TimeCurrent() - lastTick > 30) return;
  Throttled to 1-minute log.

Phase 3: Peak equity tracking + DD calculation
  if(currentEquity > g_HedgePeakEquity) g_HedgePeakEquity = currentEquity;
  currentDD = (g_HedgePeakEquity - currentEquity) / g_HedgePeakEquity × 100

Phase 4: Ultimate hard stop check
  if(currentDD >= g_EffHardStop):
    CloseAllPositionsNuclear()     // grid + hedge
    g_HedgeActive = false
    IsTradingActive = false
    return

Phase 5: Determine desired hedge stage
  desiredStage = 0/1/2/3 based on currentDD vs g_EffTrigger1/2/3

Phase 6: Hedge management (rate-limited every InpFullCheckInterval seconds)
  if(desiredStage > g_HedgeStage) → ExecuteHedge(desiredStage)
  if(g_HedgeActive):
    VerifyHedgeHealthy()
    ManageUnwindLogic(currentDD)
    ProcessCannibalism()
    CheckHedgeDuration()
    VerifyExposureBalance()

Phase 7: Freeze gate (just an if-statement)
  if(g_HedgeActive):
    track peak balance during freeze
    PublishCoordinationData()
    CheckForOptimizationUpdates()
    return  ← grid phases 8-9 never execute

Phase 8: Grid hard stop check
  if(currentBalance > g_PeakBalance) update peak + floor
  if(currentEquity < g_DynamicHardStop):
    IsTradingActive = false
    CloseAllGridPositions()        // hedge NOT closed
    return

Phase 9: Grid operations
  CheckDynamicGrid()         — upward shift detection
  SyncMemoryWithBroker()     — reconcile ticket map
  ManageRollingTail()        — enforce MaxPendingOrders
  ScanForRealizedProfits()   — bucket fill
  CleanExpiredBucketItems()  — bucket maintenance
  if(spreadOK):
    ManageGridEntry(ask)     — place BuyLimit orders
    ManageExits(bid)         — virtual TP closes
    ManageBucketDredging()   — bucket spend

Phase 10: Planner publish
  PublishCoordinationData()  — every 10s
  CheckForOptimizationUpdates() — every 10s
```

---

## 4. Global State Variables

### Grid State (Critical — persisted to GVs)

| Variable | Type | Purpose |
|---|---|---|
| `g_CurrentUpper` | double | Live upper grid bound (may differ from InpUpperPrice after shift/push) |
| `g_CurrentLower` | double | Live lower grid bound |
| `g_CurrentLevels` | int | Current level count |
| `g_ActiveExpansionCoeff` | double | Live coefficient (may be overridden by Planner push) |
| `g_BucketTotal` | double | Current bucket balance ($) |
| `g_RuntimeLot1/2/3` | double | Live lot sizes (may be overridden by Planner push) |
| `g_RuntimeMaxSpread` | int | Live max spread override (0 = use InpMaxSpread) |
| `g_PeakBalance` | double | Highest BALANCE seen — grid hard stop reference (PA16) |
| `g_DynamicHardStop` | double | Current equity floor for grid hard stop |
| `IsTradingActive` | bool | false = grid hard stop or ultimate hard stop fired |

### Hedge State (Critical — persisted to GVs)

| Variable | Type | Purpose |
|---|---|---|
| `g_HedgeActive` | bool | **The freeze flag** — true = hedge open, grid frozen |
| `g_HedgeStage` | int | Current stage (0=none, 1/2/3=active) |
| `g_HedgeTickets[3]` | ulong[] | Ticket for each stage's SELL position |
| `g_StageOpenTime[3]` | datetime[] | When each stage was opened (for MinStageHoldMins check) |
| `g_HedgeStartTime` | datetime | When the hedge sequence started (for duration check) |
| `g_HedgeOpenVolume` | double | Total hedge volume when last updated |
| `g_HedgeOpenPrice` | double | Price when hedge was opened |
| `g_HedgePeakEquity` | double | Highest EQUITY seen — hedge DD% reference |
| `g_CannibalismCount` | int | Number of cannibalism events this session |
| `g_TotalPruned` | double | Total loss closed via cannibalism ($) |

### Effective Thresholds (Calculated — not persisted)

| Variable | Source |
|---|---|
| `g_EffTrigger1/2/3` | InpHedgeTrigger1/2/3 × risk scale factor |
| `g_EffHardStop` | InpUltimateHardStopDD × risk scale factor |
| `g_EffSafeUnwind` | InpSafeUnwindDD × risk scale factor |

If `InpAutoScaleToRisk = true` and Planner publishes `{magic}_SG_MAX_RISK_PCT`, all thresholds are scaled by `maxRisk / InpUltimateHardStopDD`. Recalculated every tick in Phase 5.

### Grid Arrays (Runtime — not persisted)

| Array | Size | Content |
|---|---|---|
| `GridPrices[]` | g_CurrentLevels | Entry price for each level |
| `GridTPs[]` | g_CurrentLevels | Take-profit price for each level |
| `GridLots[]` | g_CurrentLevels | Lot size for each level |
| `GridStepSize[]` | g_CurrentLevels | Gap to next level (used for tolerance matching) |
| `g_LevelTickets[]` | g_CurrentLevels | Current broker ticket at each level (0 = empty) |
| `g_LevelLock[]` | g_CurrentLevels | True during BuyLimit placement (prevents duplicate submissions) |

---

## 5. Two CTrade Instance Design

```mql5
CTrade tradeGrid;    // magic=InpGridMagic  (205001) | deviation=50pts
CTrade tradeHedge;   // magic=InpHedgeMagic (999999) | deviation=100pts
```

**Why two instances?**

A single CTrade instance with dynamic magic switching was considered and rejected:

```mql5
// DANGEROUS — not used
trade.SetExpertMagicNumber(InpGridMagic);
trade.BuyLimit(...);
// ← race condition if called again before BuyLimit settles
trade.SetExpertMagicNumber(InpHedgeMagic);
trade.Sell(...);
```

With two instances, each engine exclusively uses its own CTrade:
- `tradeGrid` is only called from grid functions (ManageGridEntry, ManageExits, CloseAllGridPositions, etc.)
- `tradeHedge` is only called from hedge functions (ExecuteHedge, ManageUnwindLogic, ProcessCannibalism, CloseAllPositionsNuclear)

**Deviation settings:**
- Grid: 50 points — standard for limit orders
- Hedge: 100 points — wider for VPS latency on market SELL orders (L06 fix)

---

## 6. GlobalVariable Interface (GV Map)

### Published by Steward → Read by Planner

**Grid namespace: `{InpGridMagic}_SG_{SUFFIX}`** (default prefix: `205001_SG_`)

| Suffix | Type | Frequency | Description |
|---|---|---|---|
| `UPPER` | double | On change | Current grid upper bound |
| `LOWER` | double | On change | Current grid lower bound |
| `LEVELS` | double(int) | On change | Current level count |
| `COEFF` | double | On change | Active expansion coefficient |
| `LOT1/2/3` | double | On change | Active zone lot sizes |
| `BUCKET` | double | On change | Bucket total ($) |
| `LAST_UPDATE` | double(datetime) | On state save | Last state save time |
| `HEARTBEAT` | double(datetime) | Every tick | Last OnTick call (Phase 0) |
| `NET_EXPOSURE` | double | Every 10s | Grid net long volume (lots) |
| `BOT_ACTIVE` | double(0/1) | Every 10s | 1.0 = trading, 0.0 = stopped |
| `HARD_STOP_LEVEL` | double | On state save | Current equity hard stop floor |
| `PEAK_EQUITY` | double | On state save | Peak balance (grid hard stop reference) |
| `HEDGE_ACTIVE` | double(0/1) | On hedge change | 1.0 = hedge open (Planner display) |

**Hedge namespace: `{InpHedgeMagic}_GH_{SUFFIX}`** (default prefix: `999999_GH_`)

| Suffix | Type | Frequency | Description |
|---|---|---|---|
| `ACTIVE` | double(0/1) | On hedge change | Hedge active flag |
| `STAGE` | double(int) | On hedge change | Stage 0-3 |
| `TICKET_1/2/3` | double(ulong) | On hedge change | Position tickets |
| `START_TIME` | double(datetime) | On hedge open | When hedge started |
| `OPEN_VOL` | double | On hedge change | Total hedge volume |
| `OPEN_PRICE` | double | On hedge change | Price when hedge opened |
| `HEARTBEAT_TS` | double(datetime) | On state save | Last hedge state save |
| `GRID_MAGIC` | double(int) | On state save | Linked grid magic (for Planner) |
| `PEAK_EQUITY` | double | On state save | Peak equity for DD calc |
| `LAST_UPDATE` | double(datetime) | On state save | Last hedge state save |

### Written by Planner → Read by Steward

**Optimization commands: `{InpGridMagic}_SG_OPT_{SUFFIX}`**

| Suffix | Type | Description |
|---|---|---|
| `CMD_PushTime` | double(datetime) | Triggers update check when > OPT_LAST_APPLIED |
| `NEW_UPPER` | double | New grid upper bound |
| `NEW_LOWER` | double | New grid lower bound |
| `NEW_LEVELS` | double(int) | New level count |
| `NEW_COEFF` | double | New expansion coefficient |
| `NEW_LOT1/2/3` | double | New zone lot sizes |
| `NEW_MAX_SPREAD` | double(int) | New max spread limit |
| `LAST_APPLIED` | double(datetime) | Written by Steward after applying push |

### Written by Planner → Read for Risk Scaling

| Key | Description |
|---|---|
| `{magic}_SG_MAX_RISK_PCT` | Max allowed risk %. Used by RecalcEffectiveThresholds() if InpAutoScaleToRisk=true |

---

## 7. State Persistence Protocol

### On Normal Shutdown (OnDeinit)

```
1. EventKillTimer()
2. SaveGridState()        — writes all grid GVs
3. SaveHedgeState()       — writes all hedge GVs
4. GlobalVariableDel("STEWARD_ACTIVE_{symbol}_{magic}")
5. if(reason != REASON_CHARTCHANGE):
   a. GlobalVariableSet("{magic}_SG_BOT_ACTIVE", 0)
   b. GlobalVariableSet("{magic}_SG_HEDGE_ACTIVE", currentState)
   c. ObjectsDeleteAll — ghost lines, break-even
   d. DashCleanup()    — remove dashboard objects
```

**REASON_CHARTCHANGE handling:** When the user switches timeframe on the Steward chart, MT5 calls OnDeinit with reason `REASON_CHARTCHANGE` then immediately calls OnInit. Steps 5a-5d are skipped — `BOT_ACTIVE` stays `1`, chart objects remain visible, Planner sees no interruption. State save and instance guard cycle always run regardless of reason.

### On Startup (OnInit)

```
1. InpResetState == true → ClearGridState() + ClearHedgeState()
2. LoadGridState():
   - Restores upper/lower/levels/coeff/bucket/lots/peak
   - Recalculates DynamicHardStop from restored peak
3. LoadHedgeState():
   - Restores active flag/stage/tickets/startTime/volume/price/peakEquity
   - Discards if stale (>24 hours old)
4. if g_HedgeActive == true:
   - VerifyHedgeExists() — check tickets against live broker
   - If no positions found: reset g_HedgeActive = false
```

### Incremental Saves

- `SaveGridState()` called when bucket changes (AddToBucket, SpendFromBucket, CleanExpiredBucketItems)
- `SaveGridState()` called after dynamic grid shift (CheckDynamicGrid)
- `SaveGridState()` called after Planner push applied (CheckForOptimizationUpdates)
- `SaveHedgeState()` called every 60s during hedge (throttled in Phase 3)
- `SaveHedgeState()` called after ExecuteHedge, ManageUnwindLogic, CheckHedgeDuration, ProcessCannibalism

---

## 8. PA Fix Disposition (All 26)

### Eliminated (Architecturally Impossible)

| Fix | Original Problem | How Steward Eliminates It |
|---|---|---|
| PA07 | Guardian false "stale data" warning (required BOTH keys stale) | No stale-data cross-check needed — no inter-bot communication |
| PA08 | Heartbeat blocked during Guardian freeze (Executor returned early) | Single process: heartbeat in Phase 0 always fires before any return |
| PA13 | Emergency brake parameter coupling (Planner-calculated threshold pushed via GV) | Emergency brake removed entirely in PA15 |
| PA15 | Emergency brake removed (was masking grid recovery mechanism) | Never implemented in Steward — clean sheet |
| PA17 | Stale OPT_NEW_BRAKE GV reference in Planner after PA15 removal | Steward never published or read this GV |
| PA18 | Guardian trailing stop killed hedge in live incident | Hedge exit is code-only (SafeUnwind/Cannibalism/Duration/HardStop) — no trailing stop ever implemented |
| PA25 | Heartbeat at end of OnTick — blocked by hard stop early return | Phase 0 heartbeat always first, before any return in Phases 1-9 |
| PA26 | BuyLimit placed in 1-5s gap between hedge open and Executor poll | g_HedgeActive is a local bool — checked inline before every BuyLimit |

### Simplified (Inline — No Special Handling Needed)

| Fix | Original Problem | Steward Approach |
|---|---|---|
| PA14 | Input validation for HardStopDDPct (1-50%), peak tracked during freeze | Input validation in OnInit, peak tracked inline in Phase 7 freeze block |
| PA22 | Peak balance reset on Guardian unfreeze | Reset inline in ManageUnwindLogic and CheckHedgeDuration on state change |

### Kept (Still Critical)

| Fix | What It Does | Where in Steward |
|---|---|---|
| PA10 | SaveGridState after RebuildGrid in CheckDynamicGrid | CheckDynamicGrid() — line after RebuildGrid |
| PA12 | Hard stop as % of peak equity (not static dollar value) | Phase 8 — balance-peak-based g_DynamicHardStop |
| PA16 | Hard stop peak uses BALANCE (not equity) — immune to floating equity spikes | g_PeakBalance tracks ACCOUNT_BALANCE only |
| PA19 | Cannibalism step order: close grid FIRST, then reduce hedge | ProcessCannibalism() — tradeGrid.PositionClose before tradeHedge.PositionClosePartial |
| PA20 | Hedge trigger inside rate-limit block; InpMaxHedgeSpread default 3500 | Phase 6 rate-limited; spread check in ExecuteHedge |
| PA21 | SafeUnwind: profit guard + hold time guard | ManageUnwindLogic() — pl > 0 check + ageSecs check |
| PA23 | Orphaned position TP fallback (nearest level above open price) | ManageExits() — GetLevelIndex fails → search GridPrices for nearest above |
| PA24 | Persistent CSV file logging with daily rotation | WriteLog() — shared file with FILE_SHARE_READ/WRITE; header guard |

---

## 9. Peak Tracking: Two Variables, Two Purposes

### g_PeakBalance — Grid Hard Stop Reference (PA16)

```mql5
// Updated in Phase 8 (grid operations only) and Phase 7 (during freeze)
if(currentBalance > g_PeakBalance) {
    g_PeakBalance = currentBalance;
    g_DynamicHardStop = g_PeakBalance * (1.0 - InpHardStopDDPct / 100.0);
}
// Trigger: equity (not balance) vs floor
if(currentEquity < g_DynamicHardStop) → CloseAllGridPositions()
```

**Why balance as the peak?**

A grid with 40 open BUY positions has equity swinging constantly as price moves. If peak used equity, every price peak would raise the hard stop floor, and the first price dip would fire the stop. Balance only changes when positions close — it reflects *realized* P/L. The floor only rises when real profits are banked.

**Why equity as the trigger?**

The trigger must respond to actual account risk. Using balance as trigger would ignore floating losses entirely.

### g_HedgePeakEquity — Hedge DD Reference

```mql5
// Updated every tick in Phase 3
if(currentEquity > g_HedgePeakEquity)
    g_HedgePeakEquity = currentEquity;

currentDD = (g_HedgePeakEquity - currentEquity) / g_HedgePeakEquity × 100
```

**Why equity as the peak?**

The hedge system monitors drawdown from the highest point the account has ever reached (in equity terms). This mirrors the original Guardian design — the hedge fires when equity is X% below peak, regardless of balance.

**Reset points:**

- On SafeUnwind success: `g_HedgePeakEquity = AccountInfoDouble(ACCOUNT_EQUITY)`
- On duration close: same
- On ultimate hard stop: reset to current balance
- On startup (no saved state): `g_HedgePeakEquity = AccountInfoDouble(ACCOUNT_BALANCE)`

---

## 10. Hard Stop Architecture

### Stop Sequence and Scope

```
Phase 4 (runs every tick, before freeze):
  if(hedgeDD >= g_EffHardStop):
    CloseAllPositionsNuclear()     // grid magic + hedge magic
    g_HedgeActive = false
    IsTradingActive = false
    ClearHedgeState()
    return

Phase 7 (freeze gate):
  if(g_HedgeActive): return        // grid phases 8-9 skipped

Phase 8 (runs only if not frozen):
  if(gridEquity < g_DynamicHardStop):
    CloseAllGridPositions()        // grid magic only
    IsTradingActive = false
    return                         // hedge still active!
```

### CloseAllGridPositions

```mql5
for(attempt = 0..2):
    for each position with magic == InpGridMagic:
        tradeGrid.PositionClose(t)
    if allClosed: break
    Sleep(200)
DeleteAllOrders()
```

### CloseAllPositionsNuclear

```mql5
for(attempt = 0..2):
    for each position:
        if magic == InpGridMagic:  tradeGrid.PositionClose(t)
        if magic == InpHedgeMagic: tradeHedge.PositionClose(t)
    if allClosed: break
    Sleep(200)
DeleteAllOrders()
```

Three retry attempts with 200ms sleep between. This handles transient broker failures without infinite loops.

---

## 11. Hedge Engine Internals

### ExecuteHedge(targetStage)

```
1. netVolume = CalculateNetExposure() — sum all InpGridMagic BUY positions
2. if netVolume <= 0: return (nothing to hedge)
3. totalRatioTarget = sum of ratios up to targetStage
4. targetHedgeVol = netVolume × totalRatioTarget
5. currentHedgeVol = GetTotalHedgeVolume()
6. volToAdd = targetHedgeVol - currentHedgeVol
7. if volToAdd < minVol: skip order, just update stage number
8. Spread check: if spread > InpMaxHedgeSpread: return
9. Margin check: if free margin < required × (InpMinFreeMarginPct/100): alert + return
10. tradeHedge.Sell(volToAdd, ...)
11. On success: set g_HedgeTickets[targetStage-1], g_StageOpenTime, g_HedgeActive=true
12. GlobalVariableSet(HEDGE_ACTIVE, 1.0) — for Planner display only
13. SaveHedgeState()
```

### VerifyHedgeHealthy()

Iterates all three tickets. For each ticket > 0:
- `PositionSelectByTicket` — exists?
- `POSITION_TYPE == POSITION_TYPE_SELL` — correct direction?
- `POSITION_MAGIC == InpHedgeMagic` — correct magic?

Returns `true` if at least one ticket passes all checks. Failed tickets are zeroed out.

### ManageUnwindLogic(currentDD)

```
1. Orphan scan: zero out g_HedgeTickets[i] if position no longer exists
2. If all tickets gone:
   - g_HedgeActive = false, stage = 0
   - PA22: g_PeakBalance = current balance
   - Log "ORPHAN"
   return
3. if price < g_CurrentLower: hold (log below-range status)
4. if price in range AND currentDD < g_EffSafeUnwind:
   a. PA21 Fix 1: if GetTotalHedgePL() <= 0: return (hold)
   b. PA21 Fix 2: for each stage, if age < InpMinStageHoldMins×60: return (hold)
   c. Close all hedge tickets
   d. On success:
      - g_HedgeActive = false, stage = 0
      - g_HedgePeakEquity = currentEquity
      - PA22: g_PeakBalance = currentBalance
      - GlobalVariableSet(HEDGE_ACTIVE, 0.0)
      - Log "SAFE_UNWIND"
```

### ProcessCannibalism() — PA19 Order

```
1. if hedge P/L < InpPruneThreshold: return
2. Find worst grid position (lowest P/L, magic == InpGridMagic, not being dredged)
3. if budget (hedgeProfit - InpPruneBuffer) <= MathAbs(worstLoss): return
4. tradeGrid.PositionClose(worstTicket)    ← GRID FIRST
   if fail: return (hedge untouched — conservative failure)
5. Recalculate grid net exposure
6. Compute new target hedge volume
7. tradeHedge.PositionClosePartial(...)    ← HEDGE SECOND
8. SaveHedgeState()
```

---

## 12. Grid Engine Internals

### CalculateCondensingGrid()

Computes `GridPrices[]`, `GridTPs[]`, `GridLots[]`, `GridStepSize[]` for all levels.

Geometric spacing formula:
```
if coeff == 1.0:
    firstGap = range / levels  (uniform)
else:
    firstGap = range × (1 - coeff) / (1 - coeff^levels)  (geometric series)

currentPrice = upper - firstGap  (or upper if InpStartAtUpper)
currentGap = firstGap
for i in 0..levels-1:
    GridPrices[i] = currentPrice
    GridTPs[i] = GridPrices[i-1] if i>0 else upper
    GridStepSize[i] = currentGap
    GridLots[i] = lot based on zone
    currentGap *= coeff
    currentPrice -= currentGap
```

### ManageGridEntry(ask)

Per-level inner loop logic:
```
for i in 0..levels-1:
    if g_LevelTickets[i] > 0: skip (already placed)
    if g_LevelLock[i]: skip (placement in progress)
    if pending count >= InpMaxPendingOrders: skip level
    target = GridPrices[i]
    if ask - target < stopsLevel: skip (too close to current price)
    if duplicate position at this price: register ticket, skip
    if margin insufficient: skip
    if g_HedgeActive: continue  ← FREEZE GUARD (inline, zero latency)
    g_LevelLock[i] = true
    tradeGrid.BuyLimit(...)
    if success: g_LevelTickets[i] = result ticket
    g_LevelLock[i] = false
```

### GetLevelIndex(price)

Linear search through GridPrices[]. Tolerance = `GridStepSize[i] × 0.4`. Returns -1 if no match (triggers PA23 orphan fallback in ManageExits).

### Zone Calculation

```mql5
g_OriginalZone1_Floor = upper - (range / 3.0)
g_OriginalZone2_Floor = upper - (range × 2.0 / 3.0)

GetZone(price):
    if price > g_OriginalZone1_Floor: return 1
    if price > g_OriginalZone2_Floor: return 2
    return 3
```

Zone floors are fixed at startup from the original grid range. Dynamic shifts upward do **not** recalculate zone floors — Zone 3 always refers to the bottom third of the historical range.

---

## 13. Bucket/Dredge Engine Internals

### AddToBucket(amount, dealTime)

Appends to `g_BucketQueue[]` (up to 1000 items). Each item has amount + timestamp. Calls `SaveGridState()` to persist total.

### ScanForRealizedProfits()

Runs every 2 seconds. Queries deal history from `g_LastHistoryCheck` to now:
- Filter: DEAL_MAGIC == InpGridMagic AND DEAL_ENTRY == DEAL_ENTRY_OUT
- Filter: profit > 0
- Lookup open deal for same position ID to get zone assignment
- If zone >= 2: AddToBucket(profit, dealTime)

### ManageBucketDredging()

Runs every 5 seconds. Uses `g_WorstPositions[0]` (pre-calculated by CalculateDashboardStats):
- `availableCash = g_BucketTotal × survivalRatio` (if balance < initialBalance)
- Threshold distance: `thresholdDist = range × InpDredgeRangePct`
- If position is within threshold distance: skip (too close to current price — may recover)
- If `availableCash > lossAbs`: close position, SpendFromBucket(lossAbs)

The distance check (PA05) prevents immediate dredging of freshly filled Zone 3 positions. Price must have moved far enough to suggest the position is genuinely stranded.

---

## 14. Planner Compatibility Verification

The following checks confirm Steward is a drop-in replacement from Planner's perspective:

### GV Keys Published

Compare against REF_PROTOCOL_AND_FIXES.md Sections 1A-1F:

| Section | Keys | Steward Status |
|---|---|---|
| 1A: Grid state | UPPER/LOWER/LEVELS/COEFF/BUCKET/LOT1-3 | ✓ Published via SaveGridState() |
| 1B: Runtime | HEARTBEAT/LAST_UPDATE/NET_EXPOSURE/BOT_ACTIVE | ✓ Published via PublishCoordinationData() + Phase 0 |
| 1C: Hard stop | HARD_STOP_LEVEL/PEAK_EQUITY | ✓ Published via SaveGridState() |
| 1D: Hedge status | HEDGE_ACTIVE (display) | ✓ Published on state change + OnDeinit |
| 1E: Hedge detail | GH_ACTIVE/STAGE/TICKET_1-3/etc. | ✓ Published via SaveHedgeState() |
| 1F: OPT commands | OPT_CMD_PushTime/NEW_* | ✓ Read via CheckForOptimizationUpdates() |

### Magic Number Coupling

Planner's `InpExecutorMagic` (default 205001) must match Steward's `InpGridMagic`. No change required from Executor setup.

### Eliminated GV Keys (no longer written or read)

| Key | Was Used For | Status |
|---|---|---|
| `{magic}_SG_BRAKE_THRESHOLD` | Emergency brake (PA15 removed) | Not written — Planner reads OK (returns 0/missing) |
| `{magic}_SG_OPT_NEW_BRAKE` | Planner push for brake (PA15 removed) | Not read — written by old Planner versions, ignored |

These were cleaned from Planner in PA17. Old Planner versions may write OPT_NEW_BRAKE harmlessly — Steward never reads it.

---

## 15. Verification Checklist

### After First Deploy (Demo)

- [ ] Dashboard shows "GRIDBOT-STEWARD v1.0" in header
- [ ] Grid geometry matches: same Upper/Lower/Levels/Coeff → same GridPrices[] as Executor
- [ ] Hedge triggers fire at correct DD%: simulate by lowering InpHedgeTrigger1 to 5% temporarily
- [ ] Freeze works: when hedge active, no new BuyLimit orders are placed (check BuyLimit count = 0)
- [ ] SafeUnwind fires: hedge closes when DD drops below InpSafeUnwindDD and profit > 0
- [ ] PA22: after unwind, hard stop floor resets (peak shown in dashboard drops to post-hedge balance)
- [ ] PA23: create position with manually mismatched price → verify it gets a TP via orphan path
- [ ] PA24: CSV file appears in MQL5\Files, Bot column = "STEWARD"
- [ ] PUSH_APPLIED: push range from Planner → CSV row with event=PUSH_APPLIED and Notes showing new params
- [ ] Timeframe switch: switch chart timeframe → BOT_ACTIVE stays 1, ghost lines stay, OnInit resumes correctly
- [ ] Planner: attach Planner with same magic → verify HUD shows correct grid range and hedge status
- [ ] PUSH TO LIVE: push new range from Planner → Steward rebuilds grid correctly
- [ ] Hard stop: temporarily set InpHardStopDDPct = 0.1% → verify CloseAllGridPositions fires
- [ ] Ultimate hard stop: temporarily set InpUltimateHardStopDD = 0.1% → verify nuclear close fires
- [ ] Restart: stop and restart Steward → grid resumes from same Upper/Lower, bucket preserved

### Before Live Cutover

- [ ] Demo test ran ≥ 1 week without unexpected stops or hedge misfires
- [ ] Shadow test on live with different magic numbers and minimum lots
- [ ] Rollback tested: stopped Steward, started Executor + Guardian, both resumed correctly
- [ ] Planner reads all GVs correctly on live account

---

## 16. Known Limitations

### No Downward Grid Extension

The grid never shifts downward. If price falls below `InpLowerPrice`, Steward logs a warning but takes no grid action. The hedge defense activates instead.

### Single Symbol Per Instance

One Steward instance manages one symbol. For multiple symbols, run separate instances with different magic numbers. Ensure Planner is linked to the correct magic for each.

### Hard Stop is Permanent

Once the grid hard stop (`IsTradingActive = false`) fires, the grid does not restart automatically. Manual intervention required: stop Steward, optionally reset state, restart.

### Bucket Not Zone 1

Profits from Zone 1 (top third of grid) are **not** added to the bucket. Zone 1 is low-risk territory; its profits are considered normal grid income and don't fund dredging operations.

### Orphan Ticket Recovery

If a hedge ticket is lost (e.g., broker disconnection during hedge open), VerifyHedgeHealthy() will zero that ticket. If all three tickets are gone but the position still exists at the broker with magic 999999, it will not be managed. Manual inspection of broker positions required after unexpected restarts during active hedging.

### Cannibalism Does Not Reduce Grid Equity Floor

Cannibalism closes a grid position (improves equity) but does not reset `g_PeakBalance`. The grid hard stop floor is only recalculated when `currentBalance > g_PeakBalance`. If cannibalism closes a position at a loss, balance may drop — the floor may not rise until profitable positions are closed.

---

*GridBot-Steward v1.0 — System Documentation*
*Source: GridBot-Executor_v10_Integrated.mq5 + GridBot-Guardian_v3.1_Integrated.mq5*
*Architecture: 26 PA fixes baked in. Planner compatible. Rollback safe.*
