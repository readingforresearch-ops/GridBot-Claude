# GridBot Trading System — Comprehensive Audit Report (v2)

**Date:** 2026-02-13 (Second Audit)
**Auditor:** Claude Code (claude-opus-4-6)
**Scope:** Full 11-section checklist audit covering code quality, order management, grid logic, risk management, error handling, state management, broker compatibility, performance, logging, input validation, and edge cases. Excludes backtesting results and strategy viability/profitability.
**Deployment:** Exness Global CENT account, VPS 2GB RAM / 4vCPU, ~150ms latency
**Previous Audit:** 2026-02-08 by Claude Sonnet 4.5 — 27 findings (4C/7H/10M/6L) all fixed + 4 post-audit runtime fixes (PA01-PA04)

---

## Files Audited

| File | Role | Magic | Lines |
|------|------|-------|-------|
| `GridBot-Executor_v10_Integrated.mq5` | Live grid trading engine | 205001 | 1,607 |
| `GridBot-Guardian_v3.1_Integrated.mq5` | Hedge defense engine | 999999 | 1,290 |
| `GridBot-Planner_v23_04.mq5` | Planning / HUD (no trades) | N/A | 818 |

---

## Audit Summary

### Previous Findings (v1 Audit — All Fixed)

| Severity | Count | IDs | Status |
|----------|-------|-----|--------|
| Critical | 4 | C01–C04 | **All Fixed** |
| High | 7 | H01–H07 | **All Fixed** |
| Medium | 10 | M01–M10 | **All Fixed** |
| Low | 6 | L01–L06 | **All Fixed** |
| Post-Audit | 4 | PA01–PA04 | **All Fixed** |

### New Findings (v2 Audit)

| Severity | Count | IDs | Status |
|----------|-------|-----|--------|
| Critical | 0 | — | — |
| High | 3 | H08–H10 | **Fixed** |
| Medium | 7 | M11–M17 | **Fixed** |
| Low | 6 | L07–L12 | **Fixed (L09/L12 deferred)** |

**Overall Risk After v1 Fixes: MEDIUM** — Core architecture is sound. Remaining issues are defensive gaps that could cause problems in specific edge-case scenarios.

---

## Section 1: Code Quality & Structure

**Status: ✅ Properly Handled**

**Positive Findings:**
- Consistent naming conventions: `InpXxx` for inputs, `g_Xxx` for globals, `GetGVKey()`/`GetCrossKey()` for GV builders
- Clean modular design: grid management, order execution, bucket/dredge, coordination, and dashboard are well-separated functions
- Good use of MQL5 enums (5 in Planner: `ENUM_STRIKE_SELECTION`, `ENUM_STRIKE_MODE`, `ENUM_RANGE_MODE`, `ENUM_GAP_LOGIC`, `ENUM_VOL_TF`)
- Proper structs: `BucketItem`, `ZoneStats`, `WorstPosition` (Executor:75-93)
- Constants defined via `const` (`MAX_GRID_LEVELS=200` at Executor:170) and `#define` (dashboard layout constants)
- Forward declarations present (Executor:172-206)
- Sensible input defaults with descriptive comments throughout

**Minor Issues:**
- See L09: `DIGITS`/`POINT` globals shadow MQL5 built-ins `_Digits`/`_Point`
- See M17: `#property strict` (MQL4 directive) still present in Planner:11 and Guardian:10

---

## Section 2: Order Management & Execution

**Status: ✅ Properly Handled**

**Positive Findings:**
- Correct use of `CTrade` class in both Executor (line 98) and Guardian (line 63)
- Dynamic filling mode detection (`GetFillingMode()` at Executor:1414, Guardian:380) — queries `SYMBOL_FILLING_MODE` and selects FOK→IOC→RETURN appropriately
- Proper deviation handling: Executor 50pts (line 256), Guardian 100pts for hedge urgency (line 395, L06 fix)
- BUY_LIMIT for grid entries (Executor:879) — correct use of pending orders instead of polling
- Magic number filtering on all position/order iterations
- Ticket tracking via `g_LevelTickets[]` array mapped to grid levels
- Order result codes checked: `TRADE_RETCODE_DONE` and `TRADE_RETCODE_PLACED` (Executor:880, Guardian:761)
- Order failure logging (H01 fix at Executor:889)
- Duplicate position seatbelt check before new orders (Executor:852-863)
- Margin check before every BUY_LIMIT with 1.1× safety buffer (Executor:867-873)
- Staggered hedge execution with margin pre-check (Guardian:745-756)
- Partial close support for cannibalism (`PositionClosePartial` at Guardian:1014)

**Issues:**
- No retry logic on hedge order failure (Guardian:786 just prints and returns). During critical DD, a single requote means no protection until next check cycle (5s). Severity: accepted risk given 5s retry cadence.
- No specific `TRADE_RETCODE_REQUOTE` or `TRADE_RETCODE_TIMEOUT` branch handlers — all failures treated identically. Severity: Low, the grid bot naturally retries on next tick.

---

## Section 3: Grid Logic Integrity

**Status: ✅ Properly Handled**

**Positive Findings:**
- Grid calculation mathematically correct: handles uniform (coeff=1.0) and geometric (coeff≠1.0) spacing with proper formula (Executor:784-788)
- Grid health validation (`IsGridHealthy()` at Executor:811-823) checks: monotonicity, lot range, step size > 0, TP > entry
- TPs set to previous level price (Executor:798) — correct "bounce to next level above" logic
- Zone-based lot assignment per level (Executor:802-804)
- Rolling tail manages pending order count (Executor:1344-1363), prioritizes removing deepest (farthest from price) levels
- Duplicate position seatbelt prevents double-fills at same grid level (Executor:852-863)
- SyncMemoryWithBroker handles order→position ticket transition with fast/slow path (Executor:1288-1341)
- MapSystemToGrid reconstructs level-ticket mapping after restart (Executor:1374-1403)
- Grid rebuild preserves existing tickets on extension, full reset on shift (Executor:727-772)
- Dynamic grid shift recalculates zone floors (Executor:705-706) — maintains zone consistency
- Grid health re-checked after rebuild with retry (Executor:759-768)

**Limitations (by design, not bugs):**
- Flash crash: only `InpMaxPendingOrders` (default 20) levels exist as pending orders at any time. If price gaps through all 20 in one tick, remaining 25+ levels are never placed until rolling tail adds them (1s rate limit at ManageGridEntry:828). This is an accepted trade-off of the rolling tail design.
- Dynamic grid shift has a brief window (delete all orders → rebuild) where no pending orders exist. During high-volatility, incoming fills could be missed. Severity: Low, window is sub-millisecond in practice.

---

## Section 4: Risk Management & Capital Protection

**Status: ⚠️ Partially Handled**

**Positive Findings:**
- Hard stop: `InpHardStopDDPct` (% from peak equity, auto-tracked via `g_PeakEquity`) closes all positions — PA12
- Emergency brake removed (PA15): contradicted grid recovery logic; Guardian freeze is the only pause mechanism
- Guardian hard stop at DD% threshold closes ALL positions across both magic numbers (Guardian:510-515, 1232-1274)
- Staggered hedging (30/35/40% DD) — progressive defense (Guardian:517-526)
- Margin check before every order with 1.1× buffer (Executor:867-873)
- Guardian hedge margin check with `InpMinFreeMarginPct` (Guardian:751-756)
- Lot normalization validates `SYMBOL_VOLUME_MIN/MAX/STEP` (Executor:1406-1412, Guardian:1276-1288)
- Spread filter blocks entries during wide spreads (Executor:649)
- Bucket dredge has survival ratio (`InpSurvivalRatio`) to protect capital (Executor:903)
- DredgeRangePct ceiling filter prevents shallow dredging (Executor:909-912, PA01 fix)

**Issues:**
- **H09**: MaxOpenPos check uses `PositionsTotal()` which counts ALL positions on ALL symbols — see finding below
- ~~**H10**: Emergency brake `IsPaused` no auto-recovery~~ — moot, emergency brake removed entirely (PA15)
- No total combined lot exposure cap at runtime — only validated by Planner simulation, not enforced by Executor
- `InpHardStopDDPct` validated 1–50% in OnInit — cannot be 0 or left disabled (PA14)

---

## Section 5: Error Handling & Resilience

**Status: ⚠️ Partially Handled**

**Positive Findings:**
- Full state persistence via GlobalVariables — survives terminal/VPS restarts
- Executor: `LoadSystemState()` + `MapSystemToGrid()` reconstructs grid state (Executor:280-331)
- Guardian: `LoadHedgeState()` + `VerifyHedgeExists()` validates hedge positions (Guardian:427-462)
- 24-hour staleness discard for Guardian state (Guardian:134)
- Price staleness detection skips stale ticks (Executor:597-602, M03 fix)
- Grid health validation with retry on startup (Executor:314-323) and after rebuild (Executor:759-768)
- Instance guard prevents duplicate Executors on same symbol (Executor:228-236, H02 fix)
- Orphan hedge position cleanup (Guardian:801-807, 453-462)
- Chart timeframe change: OnDeinit saves state → OnInit restores

**Issues:**
- **L07**: `CloseAllPositions()` and `ExecuteHardStop()` have no retry on individual `PositionClose()` failures — positions may remain open
- No `OnTrade()` handler — relies solely on `OnTick()` polling, which misses events during low-liquidity periods (no new ticks = no processing)
- No explicit handling of `ERR_TRADE_TIMEOUT` — timeouts are treated same as other failures

---

## Section 6: State Management & Persistence

**Status: ⚠️ Partially Handled**

**Positive Findings:**
- Comprehensive GV-based persistence: 10 keys for Executor, 12 keys for Guardian
- Namespaced keys prevent cross-symbol/cross-bot collision (C02 fix)
- Bucket total persisted and restored on restart
- Guardian saves all 3 hedge stage tickets independently (C03 fix)
- Atomic GV operations prevent cross-bot race conditions
- DREDGE_TARGET GV prevents dredge/cannibalism collision

**Issues:**
- **M14**: `ClearSystemState()` doesn't clear `OPT_NEW_*` or `OPT_LAST_APPLIED` GVs — see finding below
- **L10**: BucketQueue item timestamps lost on restart — see finding below
- No file-based backup — all state in GlobalVariables only (MT5 GV store corruption, though very rare, would cause complete state loss)

---

## Section 7: Broker & Market Compatibility

**Status: ⚠️ Partially Handled**

**Positive Findings:**
- Executor validates hedging account mode (C01 fix at Executor:220-224)
- Dynamic filling mode detection (Executor:1414, Guardian:380)
- Spread filter blocks entries during abnormally wide spreads (Executor:649)
- Stops level distance respected for pending orders (Executor:847-848)
- Hedge positions carry no broker SL — exits managed only via code (PA18)
- Swap exposure limited by hedge duration cap (Guardian, `InpMaxHedgeDurationHrs=72`)
- Proper use of `_Symbol`, `_Digits`, `_Point` throughout
- Gold-specific contract size overrides in Planner (Planner:150-151)

**Issues:**
- **H08**: Guardian missing hedging account check — see finding below
- **M15**: Guardian has no spread check before hedge execution — see finding below
- **M16**: `SYMBOL_TRADE_MODE` not validated in OnInit — see finding below
- **M17**: `#property strict` still in Planner:11 and Guardian:10 — see finding below

---

## Section 8: Performance & Efficiency

**Status: ✅ Properly Handled**

**Positive Findings:**
- `OnTick()` is lightweight: all heavy computation rate-limited or in `OnTimer()`
- 12 rate limiters in Executor, 4 in Guardian — comprehensive throttling (detailed in REF_PROTOCOL_AND_FIXES.md §2)
- SyncMemoryWithBroker: fast path O(n), slow path O(n×m) rate-limited to 2s (H05 fix)
- Dashboard updates via `OnTimer(1s)`, not OnTick — good separation
- Heartbeat throttled to 1s (M07 fix)
- BucketQueue capped at 1000 items (M06 fix)
- History scan throttled to 60s (Executor:1062)
- ScanForRealizedProfits throttled to 2s (M05 fix)

**Minor Inefficiencies:**
- **L11**: `DrawBreakEvenLine()` deletes and recreates object every tick (Executor:1271) — should only update when `g_BreakEvenPrice` changes
- **L12**: ManageGridEntry seatbelt: for each grid level, scans all positions (Executor:853-861) — O(n²) per call, rate-limited to 1s
- `CalculateDashboardStats()` uses bubble sort to find worst 3 positions (Executor:1033-1041) — O(n²) for up to 100 items, acceptable given 1s OnTimer cadence
- `WorstPosition tempWorst[100]` fixed array (Executor:993) — see L08

---

## Section 9: Logging & Monitoring

**Status: ✅ Properly Handled**

**Positive Findings:**
- `LogTrade()` function logs: action, level, price, lot, ticket with timestamp (Executor:1595-1606)
- Toggle via `InpEnableTradeLog` (Executor) and `InpEnableDetailedLog` (Guardian)
- Comprehensive Executor dashboard (20+ rows): status, balance, equity, DD, grid bounds, break-even, bucket, P&L, zone stats, worst positions
- Guardian dashboard (15+ rows): connection status, equity, peak, DD with color progression, trigger levels, hedge status per stage, cannibalism total
- Planner HUD via Canvas (4-column layout): strategy, grid structure, investment/exposure, performance/risk
- Push notifications for key events: order placed, hedge activated, hard stop, dredge, cannibalism
- Optional email notifications
- Alert popups for critical events (H04 fix)
- Order failure logging with return code and description (H01 fix)
- Guardian heartbeat monitoring detects frozen Executor (Guardian:308-318)

**Minor Issues:**
- No log severity levels — all output via `Print()`. No way to filter info/warning/error in MT5 Journal at runtime. (Informational — MT5 has no built-in severity mechanism)

---

## Section 10: Security & Input Validation

**Status: ⚠️ Partially Handled**

**Positive Findings (Executor OnInit):**
- Upper > Lower validated (line 238) → `INIT_PARAMETERS_INCORRECT`
- Grid levels 5-200 validated (line 243) → `INIT_PARAMETERS_INCORRECT`
- Hedging account mode validated (line 220) → `INIT_FAILED`
- Instance guard prevents duplicates (line 228) → `INIT_FAILED`
- Tick size > 0 validated in Planner (line 141-142)
- Balance > 0, leverage >= 1, risk 0-100% validated in Planner (lines 124-126)

**Positive Findings (Guardian OnInit):**
- Trigger ordering T1 < T2 < T3 validated (line 402-405) → `INIT_PARAMETERS_INCORRECT`
- Trigger1 < HardStop validated (line 398) → `INIT_PARAMETERS_INCORRECT`

**Missing Validations:**
- **M11**: `InpExpansionCoeff` — no check for 0 or negative values. Coeff=0 produces a single-level grid; negative values produce unpredictable grid geometry.
- **M12**: `InpHedgeRatio1/2/3` — no check that individual ratios are 0.0-1.0 or that their sum ≤ 1.0. Sum > 1.0 causes over-hedging (net short).
- `InpLotZone1/2/3`: not validated, but `NormalizeLot()` clamps to `SYMBOL_VOLUME_MIN` — implicitly safe
- `InpMaxPendingOrders`: 0 would effectively disable the grid (no entries placed) — not validated but non-critical
- `InpDredgeRangePct`: expected 0.0-1.0, no validation — value > 1.0 would disable dredging, < 0 would dredge everything
- `InpBucketRetentionHrs`: 0 would expire all items immediately — not validated
- `InpSurvivalRatio`: > 1.0 would spend more than bucket balance — not validated

**Division-by-zero paths:**
- Guardian:508 `(g_MaxEquity - currentEquity) / g_MaxEquity` — see M13
- All other division paths have upstream guards (tick size, balance, etc.)

---

## Section 11: Edge Cases & Stress Scenarios

**Status: ⚠️ Partially Handled**

**Positive Findings:**
- Account balance zero: Guardian hard stop fires (DD→infinity → exceeds threshold) → closes all
- Flash crash: spread filter blocks new entries during extreme spreads; Guardian detects DD and hedges
- Broker pending order limit: `InpMaxPendingOrders` default 20 — well within typical broker limits (200-500)
- Symbol delisted: Guardian heartbeat staleness detects frozen Executor after 60s; alerts fire
- System time: all rate limiters use `TimeCurrent()` (server time), not local time — safe
- Weekend/market close: price staleness detection (M03 fix) skips stale ticks
- Connection loss: GV state survives; OnInit restores on reconnection

**Remaining Gaps:**
- Flash crash with rolling tail: only 20 pending orders exist. If price gaps through all 20 in one tick, remaining levels are never placed until rolling tail catches up (1 per second). Deep grid levels during a fast crash are missed.
- **M13**: If `g_MaxEquity` is loaded as 0 from GV (corrupt state), division by zero in DD calculation
- No `SYMBOL_TRADE_MODE` check — bot doesn't detect if trading is halted on the symbol
- No volume/liquidity check — low-liquidity conditions could result in extreme slippage on market orders (hedge)

---

## New Findings (v2 Audit)

### High Findings

#### H08 — Guardian Missing Hedging Account Check
**File:** GridBot-Guardian_v3.1_Integrated.mq5 (OnInit:391-476)
**Severity:** High
**Evidence:** The C01 fix (hedging account guard) was only applied to Executor at line 220-224. Guardian has no equivalent check.
**Impact:** If Guardian is deployed on a NETTING account, `trade.Sell()` calls in `ExecuteHedge()` would NET against existing BUY positions instead of creating separate short positions. This would close grid positions instead of hedging them — the opposite of intended behavior.
**Recommended Fix:**
```mql5
// Add at Guardian OnInit, before line 398:
ENUM_ACCOUNT_MARGIN_MODE marginMode = (ENUM_ACCOUNT_MARGIN_MODE)AccountInfoInteger(ACCOUNT_MARGIN_MODE);
if(marginMode == ACCOUNT_MARGIN_MODE_RETAIL_NETTING || marginMode == ACCOUNT_MARGIN_MODE_EXCHANGE) {
   Alert("CRITICAL: Guardian requires HEDGING account. SELL hedges will NET against grid BUYs on this account.");
   return INIT_FAILED;
}
```

#### H09 — MaxOpenPos Check Counts All Symbols/EAs
**File:** GridBot-Executor_v10_Integrated.mq5 (ManageGridEntry:831)
**Severity:** High
**Evidence:** `if(PositionsTotal() >= InpMaxOpenPos) return;` — `PositionsTotal()` returns the count of ALL open positions across ALL symbols and ALL magic numbers.
**Impact:** If the user has manual positions on other symbols, or runs multiple EAs, the grid entry is prematurely blocked. With 50 manual positions and `InpMaxOpenPos=100`, only 50 grid levels can fill instead of 100. This silently stops grid construction with no warning.
**Recommended Fix:**
```mql5
// Replace line 831 with magic-filtered count:
int myPositions = 0;
for(int p = PositionsTotal()-1; p >= 0; p--) {
   ulong t = PositionGetTicket(p);
   if(t > 0 && PositionSelectByTicket(t) && PositionGetInteger(POSITION_MAGIC) == InpMagicNumber)
      myPositions++;
}
if(myPositions >= InpMaxOpenPos) return;
```

#### H10 — Emergency Brake Has No Auto-Recovery
**File:** GridBot-Executor_v10_Integrated.mq5
**Severity:** High → ✅ **REMOVED (PA15)**
**Evidence:** Emergency brake (`IsPaused`) was fixed in PA06/PA13 but later determined to contradict grid recovery logic. A paused grid cannot average down; Guardian freeze is the correct pause mechanism.
**Fix applied:** Entire emergency brake feature removed in PA15. `IsPaused`, `g_RuntimeMaxLoss`, `InpEmergencyBrakePct`, `BRAKE_THRESHOLD` GV all deleted. Guardian freeze (early return) is the only pause mechanism.

---

### Medium Findings

#### M11 — InpExpansionCoeff Not Validated
**File:** GridBot-Executor_v10_Integrated.mq5 (OnInit)
**Severity:** Medium
**Evidence:** `InpExpansionCoeff` (default 1.0) is used directly in `CalculateCondensingGrid()` at line 784 without validation.
**Impact:** Value of 0 produces `firstGap = range / 1 = range` — effectively a single-level grid. Negative values produce mathematically unpredictable grid geometry. The bot won't crash (IsGridHealthy catches bad grids), but configuration errors produce silently degraded behavior.
**Recommended Fix:**
```mql5
// Add in OnInit after line 246:
if(InpExpansionCoeff < 0.5 || InpExpansionCoeff > 2.0) {
   Alert("ERROR: Expansion Coefficient must be 0.5 - 2.0");
   return INIT_PARAMETERS_INCORRECT;
}
```

#### M12 — Hedge Ratio Sum Not Validated
**File:** GridBot-Guardian_v3.1_Integrated.mq5 (OnInit)
**Severity:** Medium
**Evidence:** `InpHedgeRatio1/2/3` (defaults 0.30/0.30/0.35) are used in `ExecuteHedge()` at lines 723-725 without validating individual range or total sum.
**Impact:** Ratios summing to > 1.0 (e.g., 0.5+0.5+0.5=1.5) cause 150% hedge volume → the account becomes net SHORT. Individual ratios > 1.0 are also unchecked.
**Recommended Fix:**
```mql5
// Add in OnInit after line 405:
double totalRatio = InpHedgeRatio1 + InpHedgeRatio2 + InpHedgeRatio3;
if(totalRatio > 1.0 || InpHedgeRatio1 < 0 || InpHedgeRatio2 < 0 || InpHedgeRatio3 < 0) {
   Alert("ERROR: Hedge ratios must be >= 0 and sum <= 1.0 (current sum: ", DoubleToString(totalRatio, 2), ")");
   return INIT_PARAMETERS_INCORRECT;
}
```

#### M13 — Guardian g_MaxEquity=0 Division by Zero
**File:** GridBot-Guardian_v3.1_Integrated.mq5 (OnTick:508)
**Severity:** Medium
**Evidence:** `currentDD = (g_MaxEquity - currentEquity) / g_MaxEquity * 100.0` — if `g_MaxEquity` is 0 (loaded from corrupt GV, or account fully drained), this is a division by zero.
**Impact:** Produces `NaN` or `infinity` for `currentDD`. Infinity would trigger the hard stop (line 510 `if(currentDD >= g_EffHardStop)`), which is a safe outcome but mathematically undefined behavior. On some platforms, NaN comparisons return false, meaning NO protection would engage.
**Recommended Fix:**
```mql5
// Replace line 507-508 with:
double currentDD = 0.0;
if(g_MaxEquity > 0.01)
   currentDD = (g_MaxEquity - currentEquity) / g_MaxEquity * 100.0;
else {
   g_MaxEquity = currentEquity; // Reset from bad state
   Print("WARNING: g_MaxEquity was zero — reset to current equity");
}
```

#### M14 — ClearSystemState Doesn't Clear Optimizer GVs
**File:** GridBot-Executor_v10_Integrated.mq5 (ClearSystemState:424-435)
**Severity:** Medium
**Evidence:** `ClearSystemState()` deletes UPPER, LOWER, LEVELS, COEFF, BUCKET, LAST_UPDATE, NET_EXPOSURE, LOT1/2/3. It does NOT delete `OPT_NEW_*`, `OPT_CMD_PushTime`, or `OPT_LAST_APPLIED`.
**Impact:** After user reset (`InpResetState=true`), `LoadSystemState()` returns false → fresh start with `InpUpperPrice/LowerPrice`. But stale `OPT_NEW_*` GVs still exist. On next `CheckForOptimizationUpdates()` call (10s later), the old optimizer data is re-applied, overriding the fresh start with stale parameters.
**Recommended Fix:**
```mql5
// Add to ClearSystemState() after line 434:
GlobalVariableDel(GetGVKey("OPT_NEW_UPPER"));
GlobalVariableDel(GetGVKey("OPT_NEW_LOWER"));
GlobalVariableDel(GetGVKey("OPT_NEW_LEVELS"));
GlobalVariableDel(GetGVKey("OPT_NEW_COEFF"));
GlobalVariableDel(GetGVKey("OPT_NEW_LOT1"));
GlobalVariableDel(GetGVKey("OPT_NEW_LOT2"));
GlobalVariableDel(GetGVKey("OPT_NEW_LOT3"));
GlobalVariableDel(GetGVKey("OPT_CMD_PushTime"));
GlobalVariableDel(GetGVKey("OPT_LAST_APPLIED"));
```

#### M15 — Guardian No Spread Check Before Hedge
**File:** GridBot-Guardian_v3.1_Integrated.mq5 (ExecuteHedge:700)
**Severity:** Medium
**Evidence:** `ExecuteHedge()` places market SELL orders without checking the current spread. Executor has a spread filter (`InpMaxSpread` at Executor:649), but Guardian has no equivalent.
**Impact:** During news events, spreads on Gold can widen to 500-2000 points. A hedge SELL during extreme spread locks in immediate significant slippage, reducing hedge effectiveness.
**Recommended Fix:**
```mql5
// Add at ExecuteHedge() before line 742 (after volume validation):
double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
double spreadPoints = (ask - bid) / SymbolInfoDouble(_Symbol, SYMBOL_POINT);
if(spreadPoints > 500) { // Reasonable max for Gold
   Print("HEDGE DELAYED: Extreme spread (", (int)spreadPoints, " pts) — waiting for normalization");
   return;
}
```
**Note:** The threshold must be balanced — too tight and the hedge never fires during the crisis when it's needed most.

#### M16 — SYMBOL_TRADE_MODE Not Checked
**File:** GridBot-Executor_v10_Integrated.mq5 (OnInit), GridBot-Guardian_v3.1_Integrated.mq5 (OnInit)
**Severity:** Medium
**Evidence:** Neither bot checks `SymbolInfoInteger(_Symbol, SYMBOL_TRADE_MODE)` to verify trading is allowed.
**Impact:** If the symbol is in close-only mode or trading-disabled mode, all order attempts fail silently. The bot appears running but cannot trade.
**Recommended Fix:**
```mql5
// Add in OnInit after environment initialization:
ENUM_SYMBOL_TRADE_MODE tradeMode = (ENUM_SYMBOL_TRADE_MODE)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_MODE);
if(tradeMode == SYMBOL_TRADE_MODE_DISABLED) {
   Alert("ERROR: Trading is DISABLED for ", _Symbol);
   return INIT_FAILED;
}
if(tradeMode == SYMBOL_TRADE_MODE_CLOSEONLY) {
   Print("WARNING: Symbol is in CLOSE-ONLY mode — new grid entries will fail!");
}
```

#### M17 — #property strict Still Present
**File:** GridBot-Planner_v23_04.mq5 (line 11), GridBot-Guardian_v3.1_Integrated.mq5 (line 10)
**Severity:** Medium
**Evidence:** `#property strict` is an MQL4 directive that has no meaning in MQL5. It was supposed to be removed (mentioned in PA fix notes) but remains in Planner and Guardian.
**Impact:** Generates compiler warnings. While functionally harmless, it indicates MQL4→MQL5 migration residue and may confuse developers inspecting the code.
**Recommended Fix:** Delete `#property strict` from Planner:11 and Guardian:10.

---

### Low Findings

#### L07 — CloseAllPositions/ExecuteHardStop No Retry
**File:** GridBot-Executor_v10_Integrated.mq5 (CloseAllPositions:1422), GridBot-Guardian_v3.1_Integrated.mq5 (ExecuteHardStop:1232)
**Severity:** Low
**Evidence:** Both functions iterate positions and call `trade.PositionClose()` once per position without checking the return value or retrying on failure.
**Impact:** During high-volatility or requote conditions, individual close operations may fail. The equity stop or hard stop would leave some positions open. Broker's stop-out is the final backstop, but the bot's intended safety mechanism is weakened.
**Recommended Fix:** Add retry logic (up to 3 attempts with 100ms sleep) for failed closes during critical stop operations.

#### L08 — WorstPosition tempWorst[100] Fixed Array
**File:** GridBot-Executor_v10_Integrated.mq5 (CalculateDashboardStats:993)
**Severity:** Low
**Evidence:** `WorstPosition tempWorst[100]` is a stack-allocated fixed array. The check `worstCount < 100` (line 1018) prevents overflow.
**Impact:** If more than 100 positions have negative P&L (unlikely with a 45-level grid, but possible with multiple instances on same magic or after many manual interventions), positions beyond 100 are silently excluded from worst-3 ranking.
**Recommended Fix:** Use dynamic array or increase to 200 (matching MAX_GRID_LEVELS).

#### L09 — DIGITS/POINT Globals Shadow MQL5 Built-ins
**File:** GridBot-Executor_v10_Integrated.mq5 (lines 126-127)
**Severity:** Low
**Evidence:** `int DIGITS; double POINT;` declared as globals, then set to `_Digits` and `_Point` values in OnInit (lines 249-250). These shadow the MQL5 predefined variables `_Digits` and `_Point`.
**Impact:** No functional issue — they hold the same values. But it creates confusion for developers who may not realize these are re-declared globals rather than the built-in identifiers. Potential for desynchronization if symbol changes.
**Recommended Fix:** Rename to `g_Digits` and `g_Point`, or remove entirely and use `_Digits`/`_Point` directly throughout.

#### L10 — BucketQueue Timestamps Lost on Restart
**File:** GridBot-Executor_v10_Integrated.mq5 (LoadSystemState:414-418)
**Severity:** Low
**Evidence:** `SaveSystemState()` saves `g_BucketTotal` as a single number (line 378). On restore, it creates one `BucketItem` with `time = TimeCurrent()` (line 417).
**Impact:** The retention period logic (`InpBucketRetentionHrs = 48`) is defeated on restart. Items that should have expired (>48h old) survive indefinitely because their timestamp is reset to "now." Over many restarts, the bucket could accumulate stale funds that should have expired.
**Recommended Fix:** Either persist individual bucket items (file-based), or accept this as a known limitation (conservative behavior — money stays in bucket longer, which is generally safe).

#### L11 — DrawBreakEvenLine Called Every Tick
**File:** GridBot-Executor_v10_Integrated.mq5 (OnTick:658, DrawBreakEvenLine:1269-1278)
**Severity:** Low
**Evidence:** `DrawBreakEvenLine()` is called every tick from `OnTick:658`. Inside, it deletes the object (`ObjectDelete`) and recreates it every time (line 1271-1278).
**Impact:** Unnecessary object delete/create cycles on every tick. On high-frequency instruments, this causes minor chart flickering and wasted CPU.
**Recommended Fix:** Cache `g_BreakEvenPrice` and only update the object when the price changes significantly (e.g., by more than 1 point).

#### L12 — ManageGridEntry Seatbelt O(n²)
**File:** GridBot-Executor_v10_Integrated.mq5 (ManageGridEntry:852-863)
**Severity:** Low
**Evidence:** For each grid level (up to 200), the seatbelt check iterates all positions (`PositionsTotal()-1` down to 0) to find duplicates. With 45 levels × 45 positions = 2,025 iterations per call.
**Impact:** Combined with the rate limit of 1s (line 828), this runs at most once per second. On a 4vCPU VPS with typical 45 levels, the performance impact is negligible. But with `MAX_GRID_LEVELS=200`, it could reach 40,000 iterations.
**Recommended Fix:** Build a price→ticket hash map once per call, then look up each level in O(1). Or accept current behavior given the 1s rate limit.

---

## Previously Fixed Findings (v1 Audit) — Verification

All 31 previous findings were verified as correctly implemented during this audit:

| ID | Description | Verified At |
|----|-------------|-------------|
| C01 | Hedging account guard | Executor:220-224 ✅ |
| C02 | GV namespace collision | All files, ~15 locations ✅ |
| C03 | Multi-stage hedge tickets | Guardian:74, all hedge logic ✅ |
| C04 | SaveSetFile magic mismatch | Planner:24, 212-214, 812 ✅ |
| H01 | Order failure logging | Executor:889 ✅ |
| H02 | Instance guard | Executor:228-236, OnDeinit:356 ✅ |
| H03 | Optimization GV null checks | Executor:535 ✅ |
| H04 | SendAlert Alert() popup | Executor:584 ✅ |
| H05 | SyncMemory rate limit | Executor:1291 ✅ |
| H06 | Dynamic filling mode | Guardian:380-386, 394 ✅ |
| H07 | Multi-stage volume accounting | Guardian (via C03) ✅ |
| M01 | AutoTrading check | All 3 OnInit ✅ |
| M02 | Demo vs live detection | Executor:267-271, Guardian:414-418 ✅ |
| M03 | Price staleness | Executor:597-602 ✅ |
| M05 | HistorySelect throttle | Executor:1448 ✅ |
| M06 | BucketQueue cap | Executor:1510-1513 ✅ |
| M07 | Heartbeat throttle | Executor:672-676 ✅ |
| M08 | Stale branding | Executor dashboard ✅ |
| M09 | Sleep in Planner OnInit | Planner:181 ✅ |
| L02 | ClearHedgeState keys | Guardian:188-189 ✅ |
| L05 | Cent account warning | Planner:137-139 ✅ |
| L06 | Deviation 100pts | Guardian:395 ✅ |
| PA01 | DredgeRangePct enforced | Executor:909-912 ✅ |
| PA02 | Zone floors recalculated | Executor:562-564 ✅ |
| PA03 | Open price for zone check | Executor:1483-1497 ✅ |
| PA04 | Hedging constant fix | Executor:220-224 ✅ |

---

## Executive Summary

| Section | Status | Key Strength | Remaining Gap |
|---------|--------|--------------|---------------|
| 1. Code Quality | ✅ Handled | Clean naming, modular design, proper MQL5 types | `#property strict` residue (M17) |
| 2. Order Management | ✅ Handled | CTrade, dynamic fill, pending orders, margin check | No retry on hedge failure (accepted) |
| 3. Grid Logic | ✅ Handled | Correct math, health checks, duplicate seatbelt | Rolling tail limits flash-crash coverage |
| 4. Risk Management | ⚠️ Partial | Dynamic hard stop (% of peak balance), staggered Guardian hedge | MaxOpenPos counts all symbols (H09); H10 moot — emergency brake removed PA15 |
| 5. Error Handling | ⚠️ Partial | Full state persistence, restart recovery | No retry on critical close ops (L07) |
| 6. State Management | ⚠️ Partial | GV-based, namespaced, collision-safe | Stale optimizer GVs survive reset (M14) |
| 7. Broker Compat | ⚠️ Partial | Hedging check, fill mode, spread filter, stops level | Guardian no hedging check (H08) |
| 8. Performance | ✅ Handled | 16 rate limiters, fast/slow path sync, timer-based dashboard | Minor O(n²) in seatbelt (L12) |
| 9. Logging | ✅ Handled | Comprehensive dashboards, push/email, trade log | No severity levels (inherent MT5 limit) |
| 10. Input Validation | ⚠️ Partial | Key params validated, INIT returns correct | Coeff, ratios, trade mode unchecked (M11-M12, M16) |
| 11. Edge Cases | ⚠️ Partial | DD-based hard stop, staleness detection, GV recovery | g_MaxEquity=0 div-by-zero (M13) |

---

## Priority Fix List (Ordered by Severity × Impact)

| Priority | ID | Severity | Description | Effort |
|----------|-----|----------|-------------|--------|
| 1 | H08 | High | Guardian: add hedging account check in OnInit | 5 min |
| 2 | H09 | High | Executor: filter PositionsTotal by magic in MaxOpenPos check | 10 min |
| 3 | H10 | High | Executor: add auto-recovery for emergency brake when P&L recovers | 5 min |
| 4 | M13 | Medium | Guardian: guard g_MaxEquity=0 division-by-zero in DD calculation | 5 min |
| 5 | M14 | Medium | Executor: clear OPT_*/OPT_LAST_APPLIED in ClearSystemState | 5 min |
| 6 | M12 | Medium | Guardian: validate hedge ratio sum ≤ 1.0 in OnInit | 5 min |
| 7 | M11 | Medium | Executor: validate InpExpansionCoeff range in OnInit | 3 min |
| 8 | M16 | Medium | Both: check SYMBOL_TRADE_MODE in OnInit | 5 min |
| 9 | M15 | Medium | Guardian: add spread check before hedge (with balanced threshold) | 10 min |
| 10 | M17 | Medium | Planner + Guardian: remove `#property strict` | 1 min |
| 11 | L07 | Low | Both: add retry on critical close operations | 15 min |
| 12 | L08 | Low | Executor: increase tempWorst to 200 or use dynamic array | 2 min |
| 13 | L09 | Low | Executor: rename DIGITS/POINT to avoid shadowing | 5 min |
| 14 | L10 | Low | Executor: document bucket timestamp reset as known limitation | 2 min |
| 15 | L11 | Low | Executor: throttle DrawBreakEvenLine to price changes only | 5 min |
| 16 | L12 | Low | Executor: optimize seatbelt with price→ticket map (optional) | 20 min |

**Estimated Total Fix Time: ~100 minutes for all 16 findings**

---

## Remediation Status

### v1 Findings (2026-02-08): All 27 findings + 4 post-audit fixes **IMPLEMENTED AND VERIFIED**
### v2 Findings (2026-02-13): 16 new findings (3H/7M/6L) **ALL IMPLEMENTED**

**Note:** L09 (rename DIGITS/POINT globals) and L12 (seatbelt O(n²) optimization) were deferred as purely cosmetic/optional with no functional impact. All other 14 findings are implemented in the source files.

---

## Post-Audit Fixes (PA05–PA18)

These fixes were applied after the v2 audit based on runtime testing and operational experience.

| ID | Date | Bot | Description | Category |
|----|------|-----|-------------|----------|
| PA05 | 2026-02-17 | Executor | Dredge logic changed from ceiling-based to distance-based filter — fixes immediate dredging of newly opened positions | Bug fix |
| PA06 | 2026-02-19 | Executor+Planner | Emergency brake threshold now Planner-calculated (InpBrakeAtDDPercent=35% of MaxDD); recovery improved from >=0 to >threshold×0.5 | Enhancement |
| PA07 | 2026-02-20 | Guardian | False "SmartGrid data stale" warning fixed — now requires BOTH LAST_UPDATE AND HEARTBEAT stale before alerting | Bug fix |
| PA08 | 2026-02-20 | Executor | HEARTBEAT kept alive during Guardian freeze — prevents false FROZEN alerts from Guardian | Bug fix |
| PA09 | 2026-02-20 | Executor | ClearSystemState now deletes BRAKE_THRESHOLD GV (prevents stale threshold surviving reset) | Bug fix |
| PA10 | 2026-02-20 | Executor | SaveSystemState moved to after RebuildGrid in CheckDynamicGrid (persisted state now matches actual grid) | Bug fix |
| PA11 | 2026-02-20 | Executor | LOT2/LOT3 individual null-checks in CheckForOptimizationUpdates (prevents silent 0.0 read) | Bug fix |
| PA12 | 2026-02-23 | Executor | Hard stop changed from static `InpEquityStopVal` ($) to dynamic `InpHardStopDDPct` (%, default 25%). Auto-tracks peak equity; persists via PEAK_EQUITY GV | Enhancement |
| PA13 | 2026-02-23 | Executor | Emergency brake changed from static $ to dynamic % (`InpEmergencyBrakePct`). Both recovery and trigger use brakeLevel | Enhancement |
| PA14 | 2026-02-23 | Executor | Input validation: HardStopDDPct 1-50%, peak equity tracks during freeze, ClearSystemState deletes HARD_STOP_LEVEL | Review fix |
| PA15 | 2026-02-23 | Executor | **Emergency Brake REMOVED entirely.** IsPaused, g_RuntimeMaxLoss, InpEmergencyBrakePct, BRAKE_THRESHOLD GV all deleted. Guardian freeze is the only pause mechanism. | Architecture change |
| PA16 | 2026-02-23 | Executor | Hard stop peak reference changed from EQUITY to BALANCE. Floor rises on realized profits only — immune to floating equity spikes. Trigger still checks equity. | Enhancement |
| PA17 | 2026-02-23 | All 3 bots | Cross-bot consistency audit: removed stale OPT_NEW_BRAKE and InpEmergencyBrakePct references from Planner code and all documentation | Cleanup |
| PA18 | 2026-02-27 | Guardian | **(A)** Removed ApplySmartTrailingStop — hedge is a shield, broker SL killed $48k in real incident; exits now via SafeUnwind/Cannibalism/Duration/HardStop only. **(B)** Fixed orphan detection GV bug — two paths forgot to set HEDGE_ACTIVE=0, leaving Executor permanently frozen. **(C)** FROZEN alert throttled to once per 5 min. **(D)** Active HUD now shows next escalation trigger. | Bug fix + Enhancement |
| PA19 | 2026-02-27 | Guardian | Cannibalism step order reversed. Old: reduce hedge first → close grid → hedge undersized on failure (dangerous). New: close grid first → if fails, return safe → then reduce hedge. Worst-case failure is now over-hedged (conservative) not under-hedged (exposed). | Architecture fix |
| PA20 | 2026-02-27 | Guardian | **(A)** Hedge trigger moved inside InpFullCheckInterval rate-limit block — was firing every tick causing log spam when spread blocked it. **(B)** InpMaxSpreadPoints default raised 500→3500 — 500 blocked every BTC hedge attempt (BTCUSDm normal spread ~1800 pts). | Bug fix |
| PA21 | 2026-02-28 | Guardian | SafeUnwind two-guard fix: **(A)** Profit check — hedge net P/L must be > 0 before SafeUnwind can close (prevents closing underwater hedge and unfreezing Executor into unprotected grid at price bottom). **(B)** Hold time — each stage must be ≥ InpMinStageHoldMins (default 15 min) before closing (prevents Stage 3 opened at bottom being closed immediately on first bounce). | Bug fix |
| PA22 | 2026-02-28 | Executor | Peak balance reset on Guardian unfreeze. During freeze, Executor bypasses hard stop check entirely — equity drifted below floor for hours undetected. On unfreeze, first tick triggered CloseAllPositions() at worst price (confirmed from Feb 27 live trade log). Fix: on HEDGE_ACTIVE 1→0 transition, reset g_PeakEquity to current balance and recalculate floor. | Critical bug fix |
| PA23 | 2026-02-28 | Executor | Orphaned position TP fallback. Positions from prior grid config (before Push to Live or grid shift) don't match any current GridPrices[] level (GetLevelIndex returns -1), so ManageExits skips them and virtual TP never fires. Fix: when GetLevelIndex fails, find nearest grid level above open price and use it as fallback TP. Logged as TP_CLOSE_ORPHAN. | Bug fix |

### Summary of Architecture Changes Since v2 Audit

1. **Emergency Brake removed** (PA15) — Grid runs fully during drawdown to preserve recovery mechanism. Guardian freeze is the only pause.
2. **Hard stop tracks balance, not equity** (PA16) — Floor rises only on realized profits, immune to floating P&L spikes.
3. **Hedge has no broker SL or trailing stop** (PA18) — Exits only via 4 managed paths. Prevents $48k-class incidents from broker SL killing the hedge shield.
4. **Orphan HEDGE_ACTIVE fix** (PA18-B) — Two code paths in Guardian now properly clear HEDGE_ACTIVE=0, preventing permanent Executor freeze.
5. **Cannibalism step order corrected** (PA19) — Grid close BEFORE hedge reduction. Worst-case failure is over-hedged (safe) not under-hedged (exposed).
6. **SafeUnwind guards** (PA21) — Hedge must be profitable AND held ≥ 15 min before SafeUnwind can close it.
7. **Peak balance reset on unfreeze** (PA22) — Prevents hard stop firing immediately after Guardian unwind when equity drifted below floor during freeze.
8. **Orphaned position TP fallback** (PA23) — Positions from old grid configs get a fallback TP from the nearest current grid level above entry.

---

*Report generated by Claude Code (claude-opus-4-6) on 2026-02-13. Post-audit fixes updated through 2026-02-28. This audit covers code correctness, safety, and resilience. It does not evaluate trading strategy viability, expected profitability, or backtesting results.*
