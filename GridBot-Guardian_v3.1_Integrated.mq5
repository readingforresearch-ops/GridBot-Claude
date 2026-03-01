//+------------------------------------------------------------------+
//|                  GridBot-Guardian_v3.1_Integrated.mq5            |
//|        "The General": Macro-Defense & Cannibalism Engine         |
//|        INTEGRATED EDITION: Full SmartGrid Coordination           |
//|        AUTO-DETECTION: Zero-config SmartGrid linking             |
//+------------------------------------------------------------------+
#property copyright "Strategy Architect - Integrated Edition"
#property link      "https://www.exness.com"
#property version   "3.15"

#include <Trade\Trade.mqh>

//==================================================================
// INPUTS
//==================================================================
input group "=== 1. Auto-Detection & Linking ==="
input bool   InpAutoDetectGrid   = true;      // Auto-detect SmartGrid (recommended)
input long   InpManualGridMagic  = 0;         // Manual Grid Magic (0 = auto-detect)
input long   InpHedgeMagic       = 999999;    // Unique ID for this Hedge Bot

input group "=== 2. Trigger Logic (Staggered Hedging) ==="
input double InpHedgeTrigger1    = 30.0;      // Stage 1 Trigger DD%
input double InpHedgeRatio1      = 0.30;      // Stage 1 Hedge Ratio (30%)
input double InpHedgeTrigger2    = 35.0;      // Stage 2 Trigger DD%
input double InpHedgeRatio2      = 0.30;      // Stage 2 Hedge Ratio (Total ~60%)
input double InpHedgeTrigger3    = 40.0;      // Stage 3 Trigger DD%
input double InpHedgeRatio3      = 0.35;      // Stage 3 Hedge Ratio (Total ~95%)
input double InpHardStopDD       = 45.0;      // HARD STOP: Close EVERYTHING at 45% DD (Fail-safe)

input group "=== 3. Cannibalism (Loss Shifting) ==="
input bool   InpEnablePruning    = true;      // Enable actively killing bad grid trades?
input double InpPruneThreshold   = 100.0;     // Minimum Hedge Profit ($) to start checking
input double InpPruneBuffer      = 20.0;      // Extra buffer ($) to ensure positive equity shift

input group "=== 4. Unwind & Recovery ==="
input double InpManualLowerPrice = 0.0;       // Fallback: Enter Grid Bottom manually if GV fails
input double InpManualUpperPrice = 0.0;       // Fallback: Enter Grid Top manually if GV fails
input double InpSafeUnwindDD     = 20.0;      // Only full close if DD drops below this % AND in range
input int    InpMinStageHoldMins = 15;        // Min minutes each stage must be held before SafeUnwind can close it

input group "=== 5. Safety & Limits ==="
input double InpMinFreeMarginPct = 150.0;     // Require 150% of needed margin before hedging
input int    InpMaxSpreadPoints = 3500;       // Max spread (points) before hedge is delayed (XAUUSD: ~200, BTCUSDm: ~3500)
input int    InpMaxHedgeDurationHrs = 72;     // Force close hedge after 72 hours (swap protection)
input bool   InpEnableStateRecovery = true;   // Persist state across restarts?

input group "=== 6. Performance ==="
input int    InpFullCheckInterval = 5;        // Seconds between full system scans
input bool   InpEnableDetailedLog = true;     // Detailed logging for debugging
input bool   InpEnableFileLog     = true;     // Write events to daily CSV log file

input group "=== 7. Risk Auto-Scaling ==="
input bool   InpAutoScaleToRisk  = true;    // Scale hedge triggers to Grid's published max risk %

input group "=== 8. Integration & Notifications ==="
input int    InpGridHealthCheckInterval = 10; // Seconds between SmartGrid health checks (Heartbeat)
input bool   InpEnableAutoRebalance = false;  // Auto-rebalance hedge when grid expands (experimental)
input bool   InpEnablePushNotify    = true;   // Send Mobile Push Notifications
input bool   InpEnableEmailNotify   = false;  // Send Email Notifications

//==================================================================
// GLOBALS
//==================================================================
CTrade trade;

// Grid Detection & Linking
long     g_DetectedGridMagic = 0;
string   g_GridGVPrefix = "";
bool     g_GridDetected = false;
datetime g_LastGridHealthCheck = 0;

// Persistent State Variables
double   g_MaxEquity = 0.0;
bool     g_HedgeActive = false;
ulong    g_HedgeTickets[3];  // [0]=Stage1, [1]=Stage2, [2]=Stage3
datetime g_HedgeStartTime = 0;
double   g_HedgeOpenVolume = 0.0;
double   g_HedgeOpenPrice = 0.0;
int      g_HedgeStage = 0; // 0=None, 1=30%, 2=60%, 3=95%

// Runtime Variables
datetime g_LastFullCheck = 0;
datetime g_LastStateCheck = 0;
datetime g_LastGridCheck = 0;
int      g_LastKnownGridLevels = 0;

// Performance Metrics
int      g_CannibalismCount = 0;
double   g_TotalPruned = 0.0;
double   g_TotalSwapCost = 0.0;
datetime g_StageOpenTime[3] = {0, 0, 0};    // When each stage opened — used by SafeUnwind hold-time check (PA21)

// Effective (possibly scaled) thresholds — use these in trading logic instead of raw inputs
double   g_EffTrigger1 = 0.0;
double   g_EffTrigger2 = 0.0;
double   g_EffTrigger3 = 0.0;
double   g_EffHardStop = 0.0;
double   g_EffSafeUnwind = 0.0;

//==================================================================
// STATE PERSISTENCE LAYER
//==================================================================
string GetGVKey(string suffix) {
   return IntegerToString(InpHedgeMagic) + "_GH_" + suffix;
}

// Cross-bot GV key using the grid magic namespace (C02 fix)
string GetCrossKey(string suffix) {
   if(g_GridGVPrefix == "") return "";
   return g_GridGVPrefix + suffix;
}

void SaveHedgeState() {
   if(!InpEnableStateRecovery) return;

   GlobalVariableSet(GetGVKey("PEAK_EQUITY"), g_MaxEquity);
   GlobalVariableSet(GetGVKey("ACTIVE"), g_HedgeActive ? 1.0 : 0.0);
   // C03 fix: save all three stage tickets
   GlobalVariableSet(GetGVKey("TICKET_1"), (double)g_HedgeTickets[0]);
   GlobalVariableSet(GetGVKey("TICKET_2"), (double)g_HedgeTickets[1]);
   GlobalVariableSet(GetGVKey("TICKET_3"), (double)g_HedgeTickets[2]);
   GlobalVariableSet(GetGVKey("START_TIME"), (double)g_HedgeStartTime);
   GlobalVariableSet(GetGVKey("OPEN_VOL"), g_HedgeOpenVolume);
   GlobalVariableSet(GetGVKey("OPEN_PRICE"), g_HedgeOpenPrice);
   GlobalVariableSet(GetGVKey("HEARTBEAT_TS"), (double)TimeCurrent());
   GlobalVariableSet(GetGVKey("STAGE"), (double)g_HedgeStage);
   GlobalVariableSet(GetGVKey("GRID_MAGIC"), (double)g_DetectedGridMagic);
   GlobalVariableSet(GetGVKey("LAST_UPDATE"), (double)TimeCurrent());
}

bool LoadHedgeState() {
   if(!InpEnableStateRecovery) return false;
   if(!GlobalVariableCheck(GetGVKey("LAST_UPDATE"))) return false;

   datetime lastUpdate = (datetime)GlobalVariableGet(GetGVKey("LAST_UPDATE"));
   if(TimeCurrent() - lastUpdate > 86400) {
      Print("WARNING: Saved state is stale - Discarding");
      ClearHedgeState();
      return false;
   }

   g_MaxEquity = GlobalVariableGet(GetGVKey("PEAK_EQUITY"));
   g_HedgeActive = (GlobalVariableGet(GetGVKey("ACTIVE")) > 0.5);

   // C03 fix: load all three stage tickets (backward compat: fall back to old TICKET key)
   if(GlobalVariableCheck(GetGVKey("TICKET_1"))) {
      g_HedgeTickets[0] = (ulong)GlobalVariableGet(GetGVKey("TICKET_1"));
      g_HedgeTickets[1] = (ulong)GlobalVariableGet(GetGVKey("TICKET_2"));
      g_HedgeTickets[2] = (ulong)GlobalVariableGet(GetGVKey("TICKET_3"));
   } else if(GlobalVariableCheck(GetGVKey("TICKET"))) {
      // Legacy state: single ticket → assign to stage 1
      g_HedgeTickets[0] = (ulong)GlobalVariableGet(GetGVKey("TICKET"));
      g_HedgeTickets[1] = 0;
      g_HedgeTickets[2] = 0;
   } else {
      ArrayInitialize(g_HedgeTickets, 0);
   }

   g_HedgeStartTime = (datetime)GlobalVariableGet(GetGVKey("START_TIME"));
   g_HedgeOpenVolume = GlobalVariableGet(GetGVKey("OPEN_VOL"));
   g_HedgeOpenPrice = GlobalVariableGet(GetGVKey("OPEN_PRICE"));

   if(GlobalVariableCheck(GetGVKey("STAGE"))) {
      g_HedgeStage = (int)GlobalVariableGet(GetGVKey("STAGE"));
   } else {
      g_HedgeStage = g_HedgeActive ? 3 : 0; // Legacy state assumption
   }

   if(GlobalVariableCheck(GetGVKey("GRID_MAGIC"))) {
      g_DetectedGridMagic = (long)GlobalVariableGet(GetGVKey("GRID_MAGIC"));
   }

   Print("STATE RESTORED: Peak=$", g_MaxEquity, " | Active=", g_HedgeActive, " | Tickets=[", g_HedgeTickets[0], ",", g_HedgeTickets[1], ",", g_HedgeTickets[2], "]");

   return true;
}

void ClearHedgeState() {
   GlobalVariableDel(GetGVKey("PEAK_EQUITY"));
   GlobalVariableDel(GetGVKey("ACTIVE"));
   // C03 fix: clear all ticket keys
   GlobalVariableDel(GetGVKey("TICKET"));
   GlobalVariableDel(GetGVKey("TICKET_1"));
   GlobalVariableDel(GetGVKey("TICKET_2"));
   GlobalVariableDel(GetGVKey("TICKET_3"));
   GlobalVariableDel(GetGVKey("START_TIME"));
   GlobalVariableDel(GetGVKey("OPEN_VOL"));
   GlobalVariableDel(GetGVKey("OPEN_PRICE"));
   // L02 fix: also clear STAGE and HEARTBEAT_TS
   GlobalVariableDel(GetGVKey("STAGE"));
   GlobalVariableDel(GetGVKey("HEARTBEAT_TS"));
   GlobalVariableDel(GetGVKey("GRID_MAGIC"));
   GlobalVariableDel(GetGVKey("LAST_UPDATE"));
   ArrayInitialize(g_StageOpenTime, 0); // PA21: clear stage open times on full reset
}

// Helper: total volume across all active hedge positions
double GetTotalHedgeVolume() {
   double total = 0;
   for(int i = 0; i < 3; i++) {
      if(g_HedgeTickets[i] > 0 && PositionSelectByTicket(g_HedgeTickets[i])) {
         total += PositionGetDouble(POSITION_VOLUME);
      }
   }
   return total;
}

// Helper: total P/L across all active hedge positions
double GetTotalHedgePL() {
   double total = 0;
   for(int i = 0; i < 3; i++) {
      if(g_HedgeTickets[i] > 0 && PositionSelectByTicket(g_HedgeTickets[i])) {
         total += PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP);
      }
   }
   return total;
}

//==================================================================
// SMARTGRID AUTO-DETECTION
//==================================================================
bool DetectSmartGrid()
{
   if(!InpAutoDetectGrid && InpManualGridMagic > 0) {
      g_DetectedGridMagic = InpManualGridMagic;
      g_GridGVPrefix = IntegerToString(g_DetectedGridMagic) + "_SG_";
      Print("MANUAL MODE: Using Grid Magic = ", g_DetectedGridMagic);
      return VerifyGridConnection();
   }

   Print("AUTO-DETECTION: Scanning for SmartGrid...");

   int totalVars = GlobalVariablesTotal();
   Print("   | Found ", totalVars, " global variables");

   for(int i=0; i<totalVars; i++) {
      string varName = GlobalVariableName(i);

      if(StringFind(varName, "_SG_LOWER") > 0) {
         int underscorePos = StringFind(varName, "_");
         if(underscorePos > 0) {
            string magicStr = StringSubstr(varName, 0, underscorePos);
            g_DetectedGridMagic = StringToInteger(magicStr);
            g_GridGVPrefix = IntegerToString(g_DetectedGridMagic) + "_SG_";

            Print("SMARTGRID DETECTED:");
            Print("   | Magic Number: ", g_DetectedGridMagic);
            Print("   | Global Variable: ", varName);

            if(VerifyGridConnection()) {
               SaveHedgeState();
               return true;
            }
         }
      }
   }

   Print("AUTO-DETECTION FAILED: No SmartGrid found");
   Print("   | Looking for pattern: *_SG_LOWER");

   return false;
}

bool VerifyGridConnection()
{
   if(g_DetectedGridMagic == 0) return false;

   string lowerKey = g_GridGVPrefix + "LOWER";
   string upperKey = g_GridGVPrefix + "UPPER";
   string levelsKey = g_GridGVPrefix + "LEVELS";
   string updateKey = g_GridGVPrefix + "LAST_UPDATE";

   if(!GlobalVariableCheck(lowerKey)) {
      Print("Grid verification failed: ", lowerKey, " not found");
      return false;
   }

   if(GlobalVariableCheck(updateKey)) {
      datetime lastUpdate = (datetime)GlobalVariableGet(updateKey);
      int ageSeconds = (int)(TimeCurrent() - lastUpdate);

      if(ageSeconds > 300) {
         Print("WARNING: SmartGrid last update ", ageSeconds, "s ago");
      }
   }

   double gridLower = GlobalVariableGet(lowerKey);
   double gridUpper = GlobalVariableCheck(upperKey) ? GlobalVariableGet(upperKey) : 0;
   int gridLevels = GlobalVariableCheck(levelsKey) ? (int)GlobalVariableGet(levelsKey) : 0;

   Print("GRID CONNECTION VERIFIED:");
   Print("   | Lower: $", gridLower);
   if(gridUpper > 0) Print("   | Upper: $", gridUpper);
   if(gridLevels > 0) Print("   | Levels: ", gridLevels);

   g_GridDetected = true;
   return true;
}

void CheckGridHealth()
{
   if(!g_GridDetected) return;
   if(TimeCurrent() - g_LastGridHealthCheck < InpGridHealthCheckInterval) return;

   string updateKey = g_GridGVPrefix + "LAST_UPDATE";

   if(GlobalVariableCheck(updateKey)) {
      datetime lastUpdate = (datetime)GlobalVariableGet(updateKey);
      int ageSeconds = (int)(TimeCurrent() - lastUpdate);

      // Heartbeat Monitor
      string hbKey = g_GridGVPrefix + "HEARTBEAT";
      if(GlobalVariableCheck(hbKey)) {
          datetime lastHB = (datetime)GlobalVariableGet(hbKey);
          int hbAge = (int)(TimeCurrent() - lastHB);

          if(hbAge > 60) {
             // PA18 fix: throttle FROZEN alert to once per 300s
             static datetime lastFrozenAlert = 0;
             if(TimeCurrent() - lastFrozenAlert >= 300) {
                Print("CRITICAL: SmartGrid FROZEN! Heartbeat age: ", hbAge, "s");
                SendAlert("CRITICAL: Grid Bot FROZEN! Last heartbeat " + IntegerToString(hbAge) + "s ago");
                lastFrozenAlert = TimeCurrent();
             }
          }

          // PA07 fix: only warn about stale state when heartbeat is ALSO stale.
          // LAST_UPDATE is written only on significant events (grid shift, PUSH TO LIVE),
          // not continuously — so it goes stale during normal stable trading.
          // HEARTBEAT is the real liveness signal (updated every 1s by Executor).
          if(ageSeconds > 300 && hbAge > 60) {
             Print("WARNING: SmartGrid data stale! Last update: ", ageSeconds, "s ago");
          }
      }
   }

   RecalcEffectiveThresholds();
   g_LastGridHealthCheck = TimeCurrent();
}

void SendAlert(string msg) {
   Alert(msg);
   if(InpEnablePushNotify) SendNotification(msg);
   if(InpEnableEmailNotify) SendMail("GridBot-Guardian Alert", msg);
}

//+------------------------------------------------------------------+
//| RISK AUTO-SCALING                                                |
//+------------------------------------------------------------------+
void RecalcEffectiveThresholds()
{
   if(!InpAutoScaleToRisk || g_GridGVPrefix == "") {
      g_EffTrigger1  = InpHedgeTrigger1;
      g_EffTrigger2  = InpHedgeTrigger2;
      g_EffTrigger3  = InpHedgeTrigger3;
      g_EffHardStop  = InpHardStopDD;
      g_EffSafeUnwind = InpSafeUnwindDD;
      return;
   }

   string riskKey = g_GridGVPrefix + "MAX_RISK_PCT";
   if(!GlobalVariableCheck(riskKey)) {
      // Master hasn't published yet — fall back to manual thresholds
      g_EffTrigger1  = InpHedgeTrigger1;
      g_EffTrigger2  = InpHedgeTrigger2;
      g_EffTrigger3  = InpHedgeTrigger3;
      g_EffHardStop  = InpHardStopDD;
      g_EffSafeUnwind = InpSafeUnwindDD;
      return;
   }

   double maxRisk = GlobalVariableGet(riskKey);
   if(maxRisk <= 0 || maxRisk > 100) return; // Sanity check — ignore bad values

   // Scale proportionally: preserve the stage ratios from the user's manual inputs
   double scale = maxRisk / InpHardStopDD;
   g_EffTrigger1  = NormalizeDouble(InpHedgeTrigger1 * scale, 1);
   g_EffTrigger2  = NormalizeDouble(InpHedgeTrigger2 * scale, 1);
   g_EffTrigger3  = NormalizeDouble(InpHedgeTrigger3 * scale, 1);
   g_EffHardStop  = NormalizeDouble(maxRisk, 1);
   g_EffSafeUnwind = NormalizeDouble(InpSafeUnwindDD * scale, 1);

   if(InpEnableDetailedLog)
      Print("RISK SCALE: MaxRisk=", maxRisk, "% | T1=", g_EffTrigger1,
            "% T2=", g_EffTrigger2, "% T3=", g_EffTrigger3,
            "% Stop=", g_EffHardStop, "% Unwind=", g_EffSafeUnwind, "%");
}

//+------------------------------------------------------------------+
//| H06 FIX: Dynamic filling mode (same as Executor)                |
//+------------------------------------------------------------------+
ENUM_ORDER_TYPE_FILLING GetFillingMode()
{
   int f = (int)SymbolInfoInteger(_Symbol, SYMBOL_FILLING_MODE);
   if((f & SYMBOL_FILLING_FOK) == SYMBOL_FILLING_FOK) return ORDER_FILLING_FOK;
   if((f & SYMBOL_FILLING_IOC) == SYMBOL_FILLING_IOC) return ORDER_FILLING_IOC;
   return ORDER_FILLING_RETURN;
}

//+------------------------------------------------------------------+
//| Initialization                                                   |
//+------------------------------------------------------------------+
int OnInit()
{
   trade.SetExpertMagicNumber(InpHedgeMagic);
   trade.SetTypeFilling(GetFillingMode()); // H06 fix: dynamic filling mode
   trade.SetDeviationInPoints(100);        // L06 fix: 100 pts for 150ms VPS latency
   trade.SetAsyncMode(false);

   // H08 fix: hedging account mode check (mirrors Executor C01 fix)
   ENUM_ACCOUNT_MARGIN_MODE marginMode = (ENUM_ACCOUNT_MARGIN_MODE)AccountInfoInteger(ACCOUNT_MARGIN_MODE);
   if(marginMode == ACCOUNT_MARGIN_MODE_RETAIL_NETTING || marginMode == ACCOUNT_MARGIN_MODE_EXCHANGE) {
      Alert("CRITICAL: Guardian requires HEDGING account. SELL hedges will NET against grid BUYs on NETTING/EXCHANGE accounts.");
      return INIT_FAILED;
   }

   if(InpHedgeTrigger1 >= InpHardStopDD) {
      Alert("ERROR: Trigger1 DD must be less than Hard Stop DD");
      return INIT_PARAMETERS_INCORRECT;
   }
   if(InpHedgeTrigger2 <= InpHedgeTrigger1 || InpHedgeTrigger3 <= InpHedgeTrigger2) {
      Alert("ERROR: Hedge trigger stages must be in ascending order (T1 < T2 < T3)");
      return INIT_PARAMETERS_INCORRECT;
   }

   // M12 fix: validate hedge ratios
   double totalRatio = InpHedgeRatio1 + InpHedgeRatio2 + InpHedgeRatio3;
   if(totalRatio > 1.0 || InpHedgeRatio1 < 0 || InpHedgeRatio2 < 0 || InpHedgeRatio3 < 0) {
      Alert("ERROR: Hedge ratios must be >= 0 and sum <= 1.0 (current sum: ", DoubleToString(totalRatio, 2), ")");
      return INIT_PARAMETERS_INCORRECT;
   }

   // M01 fix: AutoTrading enabled check
   if(!TerminalInfoInteger(TERMINAL_TRADE_ALLOWED))
      Print("WARNING: AutoTrading is disabled in terminal — hedge orders will fail!");
   if(!AccountInfoInteger(ACCOUNT_TRADE_EXPERT))
      Print("WARNING: Expert Advisors not permitted on this account!");

   // M02 fix: Demo vs live detection
   ENUM_ACCOUNT_TRADE_MODE accMode = (ENUM_ACCOUNT_TRADE_MODE)AccountInfoInteger(ACCOUNT_TRADE_MODE);
   if(accMode != ACCOUNT_TRADE_MODE_DEMO) {
      Print("WARNING: LIVE ACCOUNT — ensure strategy tested before running!");
      SendNotification("GridBot-Guardian started on LIVE account: " + _Symbol);
   }

   // M16 fix: check SYMBOL_TRADE_MODE
   ENUM_SYMBOL_TRADE_MODE tradeMode = (ENUM_SYMBOL_TRADE_MODE)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_MODE);
   if(tradeMode == SYMBOL_TRADE_MODE_DISABLED) {
      Alert("ERROR: Trading is DISABLED for ", _Symbol);
      return INIT_FAILED;
   }
   if(tradeMode == SYMBOL_TRADE_MODE_CLOSEONLY)
      Print("WARNING: ", _Symbol, " is in CLOSE-ONLY mode — hedge orders may fail!");

   Print("========================================");
   Print("GRIDBOT-GUARDIAN v3.14 - INTEGRATED");
   Print("========================================");

   // C03 fix: initialize all ticket slots
   ArrayInitialize(g_HedgeTickets, 0);

   bool stateLoaded = LoadHedgeState();

   if(g_DetectedGridMagic == 0) {
      if(!DetectSmartGrid()) {
         Print("INIT FAILED: Cannot find SmartGrid");

         if(InpAutoDetectGrid) {
            Alert("Guardian init failed: SmartGrid not detected!");
            return INIT_FAILED;
         }
      }
   } else {
      Print("Using Grid Magic from saved state: ", g_DetectedGridMagic);
      g_GridGVPrefix = IntegerToString(g_DetectedGridMagic) + "_SG_";
      VerifyGridConnection();
   }

   if(!stateLoaded) {
      g_MaxEquity = AccountInfoDouble(ACCOUNT_BALANCE);
      Print("FRESH START: Initial Equity=$", g_MaxEquity);
      SaveHedgeState();
   }

   // Initialise effective thresholds (scales to Grid's max risk if Master has published it)
   RecalcEffectiveThresholds();

   if(g_HedgeActive) {
      if(!VerifyHedgeExists()) {
         Print("State claims hedge active but not found - Resetting");
         g_HedgeActive = false;
         ArrayInitialize(g_HedgeTickets, 0);
         SaveHedgeState();
      } else {
         Print("Existing hedge verified - Resuming management");
      }
   }

   Print("========================================");
   Print("CONFIGURATION:");
   Print("   | Grid Magic: ", g_DetectedGridMagic);
   Print("   | Hedge Magic: ", InpHedgeMagic);
   Print("   | Staggered Hedging:");
   Print("   |   Stage 1: ", InpHedgeTrigger1, "% DD -> ", (InpHedgeRatio1*100), "% Vol");
   Print("   |   Stage 2: ", InpHedgeTrigger2, "% DD -> +", (InpHedgeRatio2*100), "% Vol");
   Print("   |   Stage 3: ", InpHedgeTrigger3, "% DD -> +", (InpHedgeRatio3*100), "% Vol");
   Print("   | Hard Stop: ", InpHardStopDD, "%");
   Print("========================================");
   WriteLog("STARTUP", 0, 0, 0, 0,
      StringFormat("linkedMagic=%d T1=%.1f%% T2=%.1f%% T3=%.1f%% hardstop=%.1f%%",
      g_DetectedGridMagic, g_EffTrigger1, g_EffTrigger2, g_EffTrigger3, g_EffHardStop));
   return(INIT_SUCCEEDED);
}

void OnDeinit(const int reason)
{
   SaveHedgeState();

   // C02 fix: use namespaced cross-bot key
   string hKey = GetCrossKey("HEDGE_ACTIVE");
   if(hKey != "") GlobalVariableSet(hKey, 0);

   GhCleanup();
   Print("Guardian Shutdown - Reason: ", reason);
}

//+------------------------------------------------------------------+
//| Main Logic Loop                                                  |
//+------------------------------------------------------------------+
void OnTick()
{
   CheckGridHealth();

   double currentEquity = AccountInfoDouble(ACCOUNT_EQUITY);

   if(currentEquity > g_MaxEquity) {
      g_MaxEquity = currentEquity;
      if(InpEnableStateRecovery && TimeCurrent() - g_LastStateCheck > 60) {
         SaveHedgeState();
         g_LastStateCheck = TimeCurrent();
      }
   }

   // M13 fix: guard against division by zero if g_MaxEquity is 0 (corrupt state)
   double currentDD = 0.0;
   if(g_MaxEquity > 0.01)
      currentDD = (g_MaxEquity - currentEquity) / g_MaxEquity * 100.0;
   else {
      g_MaxEquity = currentEquity;
      Print("WARNING: g_MaxEquity was zero — reset to current equity $", DoubleToString(currentEquity, 2));
   }

   if(currentDD >= g_EffHardStop) {
      Print("CRITICAL: HARD STOP AT ", DoubleToString(currentDD, 2), "% DD (limit=", g_EffHardStop, "%)");
      SendAlert("CRITICAL: HARD STOP TRIGGERED! Equity: " + DoubleToString(currentEquity, 2));
      ExecuteHardStop();
      return;
   }

   // Staggered Hedging Logic (uses effective thresholds, auto-scaled if Master published risk %)
   int desiredStage = 0;
   if(currentDD >= g_EffTrigger3) desiredStage = 3;
   else if(currentDD >= g_EffTrigger2) desiredStage = 2;
   else if(currentDD >= g_EffTrigger1) desiredStage = 1;

   if(TimeCurrent() - g_LastFullCheck >= InpFullCheckInterval) {

      // PA20 fix: hedge trigger moved inside rate-limited block.
      // Previously fired every tick — caused log spam when spread check blocked it.
      // Now retries every InpFullCheckInterval (5s) — no functional delay for a hedge trigger.
      if(desiredStage > g_HedgeStage) {
         Print("Requesting Hedge Upscale: Stage ", g_HedgeStage, " -> ", desiredStage);
         ExecuteHedge(desiredStage);
      }

      if(g_HedgeActive) {
         if(!VerifyHedgeHealthy()) {
            Print("Hedge health check failed - Resetting");
            g_HedgeActive = false;
            ArrayInitialize(g_HedgeTickets, 0);
            SaveHedgeState();
            // PA18 fix: update cross-bot GV so Executor unfreezes
            string hKeyHealth = GetCrossKey("HEDGE_ACTIVE");
            if(hKeyHealth != "") GlobalVariableSet(hKeyHealth, 0.0);
            return;
         }

         ManageUnwindLogic(currentDD);

         if(InpEnablePruning && g_HedgeActive) {
            ProcessCannibalism();
         }

         CheckHedgeDuration();
         CheckGridExpansion();
         VerifyExposureBalance();
      }

      g_LastFullCheck = TimeCurrent();
   }

   // PA26: publish HEDGE_ACTIVE every tick (was inside 5s rate-limited block — C02 location).
   // Guarantees Executor sees freeze signal at tick resolution after Guardian restart.
   // PA18 point-of-state-change clears inside VerifyHedgeHealthy/ManageUnwindLogic remain.
   {
      string hKey = GetCrossKey("HEDGE_ACTIVE");
      if(hKey != "") GlobalVariableSet(hKey, g_HedgeActive ? 1.0 : 0.0);
   }

   UpdateDashboard(currentDD);
}

//+------------------------------------------------------------------+
//| DASHBOARD                                                        |
//+------------------------------------------------------------------+
//--- Guardian dashboard panel helpers ---
#define GH_PREFIX   "GBG_"
#define GH_FONT     "Consolas"
#define GH_FSIZE    9
#define GH_X        10
#define GH_Y        25
#define GH_LINE_H   16
#define GH_PAD      8
#define GH_WIDTH    370

void GhLabel(int row, string name, string txt, color clr = clrWhite)
{
   string objName = GH_PREFIX + name;
   if(ObjectFind(0, objName) < 0) {
      ObjectCreate(0, objName, OBJ_LABEL, 0, 0, 0);
      ObjectSetInteger(0, objName, OBJPROP_CORNER, CORNER_LEFT_UPPER);
      ObjectSetString(0, objName, OBJPROP_FONT, GH_FONT);
      ObjectSetInteger(0, objName, OBJPROP_FONTSIZE, GH_FSIZE);
      ObjectSetInteger(0, objName, OBJPROP_SELECTABLE, false);
      ObjectSetInteger(0, objName, OBJPROP_HIDDEN, true);
      ObjectSetInteger(0, objName, OBJPROP_ZORDER, 10);
   }
   ObjectSetString(0, objName, OBJPROP_TEXT, txt);
   ObjectSetInteger(0, objName, OBJPROP_COLOR, clr);
   ObjectSetInteger(0, objName, OBJPROP_XDISTANCE, GH_X + GH_PAD);
   ObjectSetInteger(0, objName, OBJPROP_YDISTANCE, GH_Y + GH_PAD + row * GH_LINE_H);
}

void GhBackground(int totalRows)
{
   string objName = GH_PREFIX + "BG";
   if(ObjectFind(0, objName) < 0) {
      ObjectCreate(0, objName, OBJ_RECTANGLE_LABEL, 0, 0, 0);
      ObjectSetInteger(0, objName, OBJPROP_CORNER, CORNER_LEFT_UPPER);
      ObjectSetInteger(0, objName, OBJPROP_SELECTABLE, false);
      ObjectSetInteger(0, objName, OBJPROP_HIDDEN, true);
      ObjectSetInteger(0, objName, OBJPROP_BORDER_TYPE, BORDER_FLAT);
      ObjectSetInteger(0, objName, OBJPROP_ZORDER, 0);
      ObjectSetInteger(0, objName, OBJPROP_BACK, true);
   }
   ObjectSetInteger(0, objName, OBJPROP_XDISTANCE, GH_X);
   ObjectSetInteger(0, objName, OBJPROP_YDISTANCE, GH_Y);
   ObjectSetInteger(0, objName, OBJPROP_XSIZE, GH_WIDTH);
   ObjectSetInteger(0, objName, OBJPROP_YSIZE, GH_PAD * 2 + totalRows * GH_LINE_H + 4);
   ObjectSetInteger(0, objName, OBJPROP_BGCOLOR, C'20,20,30');
   ObjectSetInteger(0, objName, OBJPROP_BORDER_COLOR, C'60,60,80');
}

void GhCleanup()
{
   int total = ObjectsTotal(0, 0, -1);
   for(int i = total - 1; i >= 0; i--) {
      string name = ObjectName(0, i);
      if(StringFind(name, GH_PREFIX) == 0)
         ObjectDelete(0, name);
   }
   Comment("");
}

void UpdateDashboard(double currentDD)
{
   int r = 0;
   double eq = AccountInfoDouble(ACCOUNT_EQUITY);

   // --- Header ---
   GhLabel(r, "HDR", "  GRIDBOT-GUARDIAN v3.14", clrMagenta);                         r++;

   // --- Connection ---
   if(g_GridDetected)
      GhLabel(r, "LNK", "  Linked: SmartGrid #" + IntegerToString(g_DetectedGridMagic), clrLime);
   else
      GhLabel(r, "LNK", "  Scanning for SmartGrid...", clrYellow);
   r++;
   GhLabel(r, "S1",  "  ______________________________________", C'60,60,80');       r++;

   // --- Account Health ---
   GhLabel(r, "EQ",  "  Equity: $" + DoubleToString(eq, 2), clrWhite);              r++;
   GhLabel(r, "PEQ", "  Peak:   $" + DoubleToString(g_MaxEquity, 2), clrSilver);    r++;

   // DD with color progression
   color ddClr = clrLime;
   string ddWarn = "";
   if(currentDD >= g_EffTrigger3)      { ddClr = clrRed;        ddWarn = "  STAGE 3!"; }
   else if(currentDD >= g_EffTrigger2) { ddClr = clrOrangeRed;  ddWarn = "  STAGE 2!"; }
   else if(currentDD >= g_EffTrigger1) { ddClr = clrYellow;     ddWarn = "  WARNING";  }
   GhLabel(r, "DD",  "  Drawdown: " + DoubleToString(currentDD, 2) + "%" + ddWarn, ddClr); r++;
   GhLabel(r, "S2",  "  ______________________________________", C'60,60,80');       r++;

   // --- Trigger Levels ---
   color t1Clr = (currentDD >= g_EffTrigger1) ? clrYellow    : C'80,80,100';
   color t2Clr = (currentDD >= g_EffTrigger2) ? clrOrangeRed : C'80,80,100';
   color t3Clr = (currentDD >= g_EffTrigger3) ? clrRed       : C'80,80,100';
   GhLabel(r, "T1", "  T1: " + DoubleToString(g_EffTrigger1, 1) + "%"
                     + "  |  T2: " + DoubleToString(g_EffTrigger2, 1) + "%"
                     + "  |  T3: " + DoubleToString(g_EffTrigger3, 1) + "%",
                     (currentDD >= g_EffTrigger1) ? ddClr : C'80,80,100');            r++;
   GhLabel(r, "S3",  "  ______________________________________", C'60,60,80');       r++;

   // --- Hedge Status ---
   if(g_HedgeActive) {
      GhLabel(r, "HST", "  HEDGE ACTIVE  (Stage " + IntegerToString(g_HedgeStage) + "/3)", clrRed); r++;
      GhLabel(r, "HVL", "  Volume: " + DoubleToString(GetTotalHedgeVolume(), 2) + " lots", clrWhite); r++;
      double hpl = GetTotalHedgePL();
      GhLabel(r, "HPL", "  Hedge P/L: $" + DoubleToString(hpl, 2),
              hpl >= 0 ? clrLime : clrOrangeRed);                                    r++;
      // PA18 fix: show next escalation trigger during active hedge
      string nextTrigStr = "  Next: ";
      if(g_HedgeStage < 2)       nextTrigStr += DoubleToString(g_EffTrigger2, 1) + "% (S2)";
      else if(g_HedgeStage < 3)  nextTrigStr += DoubleToString(g_EffTrigger3, 1) + "% (S3)";
      else                        nextTrigStr += "ALL STAGES DEPLOYED";
      GhLabel(r, "NXT", nextTrigStr, clrSilver);                                     r++;

      // Ticket details per stage
      for(int i = 0; i < 3; i++) {
         string tKey = "HT" + IntegerToString(i);
         if(g_HedgeTickets[i] > 0) {
            GhLabel(r, tKey, "   S" + IntegerToString(i+1) + ": #" + IntegerToString(g_HedgeTickets[i]), clrSilver);
         } else {
            GhLabel(r, tKey, "   S" + IntegerToString(i+1) + ": ---", C'60,60,80');
         }
         r++;
      }
   } else {
      GhLabel(r, "HST", "  STANDBY  (Monitoring)", clrLime);                         r++;
      GhLabel(r, "HVL", "  Next Trigger: " + DoubleToString(g_EffTrigger1, 1) + "% DD", clrSilver); r++;
      GhLabel(r, "HPL", "", C'20,20,30');                                             r++;
      for(int i = 0; i < 3; i++) {
         GhLabel(r, "HT" + IntegerToString(i), "", C'20,20,30');                      r++;
      }
   }
   GhLabel(r, "S4",  "  ______________________________________", C'60,60,80');       r++;

   // --- Stats ---
   GhLabel(r, "CAN", "  Cannibalized: $" + DoubleToString(g_TotalPruned, 2),
           g_TotalPruned > 0 ? clrAqua : clrSilver);                                 r++;

   // --- Background ---
   GhBackground(r);
}

//+------------------------------------------------------------------+
//| EXECUTION LOGIC                                                  |
//+------------------------------------------------------------------+
void ExecuteHedge(int targetStage)
{
   if(!g_GridDetected) {
      Print("Cannot hedge: SmartGrid not detected");
      return;
   }

   double netVolume = 0.0;
   string exposureKey = g_GridGVPrefix + "NET_EXPOSURE";

   if(GlobalVariableCheck(exposureKey)) {
      netVolume = GlobalVariableGet(exposureKey);
   } else {
      netVolume = CalculateGridNetExposure();
   }

   if(netVolume <= 0) {
      Print("Net exposure is zero/short - No hedge needed");
      return;
   }

   // Calculate Target Volume based on Stages
   double totalRatio = 0.0;
   if(targetStage >= 1) totalRatio += InpHedgeRatio1;
   if(targetStage >= 2) totalRatio += InpHedgeRatio2;
   if(targetStage >= 3) totalRatio += InpHedgeRatio3;

   double targetHedgeVol = NormalizeDouble(netVolume * totalRatio, 2);

   // C03 fix: compute current hedge volume from all active tickets
   double currentHedgeVol = GetTotalHedgeVolume();

   double volToAdd = targetHedgeVol - currentHedgeVol;
   double minVol = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);

   if(volToAdd < minVol) {
      if(volToAdd > 0) Print("Hedge add amount too small: ", volToAdd);
      g_HedgeStage = targetStage; // Upgrade stage anyway if volume matches roughly
      SaveHedgeState();
      return;
   }

   double currentBid = SymbolInfoDouble(_Symbol, SYMBOL_BID);

   // M15 fix: spread check before hedge — delay during extreme spreads
   double currentAskH = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double spreadPoints = (currentAskH - currentBid) / SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   if(InpMaxSpreadPoints > 0 && spreadPoints > InpMaxSpreadPoints) {
      Print("HEDGE DELAYED: Extreme spread (", (int)spreadPoints, " pts) — waiting for normalization");
      return;
   }

   double marginRequired = 0;

   if(!OrderCalcMargin(ORDER_TYPE_SELL, _Symbol, volToAdd, currentBid, marginRequired)) {
      Print("ERROR: Margin calculation failed");
      SendAlert("HEDGE BLOCKED: Margin calc failed");
      return;
   }

   double freeMargin = AccountInfoDouble(ACCOUNT_MARGIN_FREE);
   if(freeMargin < marginRequired * (InpMinFreeMarginPct / 100.0)) {
      Print("HEDGE BLOCKED: Insufficient Margin. Needed: ", marginRequired);
      SendAlert("HEDGE BLOCKED: Insufficient margin!");
      return;
   }

   trade.SetExpertMagicNumber(InpHedgeMagic);

   if(trade.Sell(volToAdd, _Symbol, 0, 0, 0, "Guardian_Stage_" + IntegerToString(targetStage))) {
      if(trade.ResultRetcode() == TRADE_RETCODE_DONE ||
         trade.ResultRetcode() == TRADE_RETCODE_PLACED) {

         // C03 fix: store ticket in the correct stage slot
         g_HedgeTickets[targetStage - 1] = trade.ResultOrder();
         g_StageOpenTime[targetStage - 1] = TimeCurrent(); // PA21: track open time for hold-time guard

         if(!g_HedgeActive) {
             g_HedgeActive = true;
             g_HedgeStartTime = TimeCurrent();
         }

         int oldStage = g_HedgeStage;  // capture before assignment for HEDGE_OPEN/STAGE_UP log
         g_HedgeOpenVolume = GetTotalHedgeVolume();
         g_HedgeOpenPrice = currentBid;
         g_HedgeStage = targetStage;

         SaveHedgeState();
         // C02 fix: publish via namespaced key
         string hKey = GetCrossKey("HEDGE_ACTIVE");
         if(hKey != "") GlobalVariableSet(hKey, 1.0);

         string alertMsg = "HEDGE INCREASED (Stage " + IntegerToString(targetStage) + "): +" + DoubleToString(volToAdd, 2) + " lots @ " + DoubleToString(currentBid, _Digits);
         Print(alertMsg);
         SendAlert(alertMsg);
         string eventCode = (oldStage == 0) ? "HEDGE_OPEN" : "STAGE_UP";
         WriteLog(eventCode, targetStage, currentBid, volToAdd, g_HedgeTickets[targetStage-1],
            StringFormat("oldStage=%d newStage=%d totalVol=%.2f", oldStage, targetStage, g_HedgeOpenVolume));

      } else {
         Print("Hedge execution failed: ", trade.ResultRetcode(), " ", trade.ResultRetcodeDescription());
      }
   }
}

//+------------------------------------------------------------------+
//| UNWIND LOGIC                                                     |
//+------------------------------------------------------------------+
void ManageUnwindLogic(double currentDD)
{
   // C03 fix: check if any hedge ticket is active
   bool anyActive = false;
   for(int i = 0; i < 3; i++) if(g_HedgeTickets[i] > 0) anyActive = true;
   if(!anyActive || !g_HedgeActive) return;

   // Verify primary ticket still exists (clean up orphans)
   for(int i = 0; i < 3; i++) {
      if(g_HedgeTickets[i] > 0 && !PositionSelectByTicket(g_HedgeTickets[i])) {
         Print("Stage ", i+1, " hedge position disappeared - clearing ticket");
         g_HedgeTickets[i] = 0;
      }
   }

   // Re-check after cleanup
   anyActive = false;
   for(int i = 0; i < 3; i++) if(g_HedgeTickets[i] > 0) anyActive = true;
   if(!anyActive) {
      Print("All hedge positions gone - resetting state");
      g_HedgeActive = false;
      g_HedgeStage = 0;
      g_HedgeOpenVolume = 0.0;
      SaveHedgeState();
      // PA18 fix: update cross-bot GV so Executor unfreezes
      string hKeyOrphan = GetCrossKey("HEDGE_ACTIVE");
      if(hKeyOrphan != "") GlobalVariableSet(hKeyOrphan, 0.0);
      WriteLog("ORPHAN", 0, 0, 0, 0, "All hedge tickets disappeared — state reset; Executor unfrozen");
      return;
   }

   double currentBid = SymbolInfoDouble(_Symbol, SYMBOL_BID);

   double gridLower = InpManualLowerPrice;
   double gridUpper = InpManualUpperPrice;

   string lowerKey = g_GridGVPrefix + "LOWER";
   string upperKey = g_GridGVPrefix + "UPPER";

   if(GlobalVariableCheck(lowerKey)) {
      double gvValue = GlobalVariableGet(lowerKey);
      if(gvValue > 0) gridLower = gvValue;
   }

   if(GlobalVariableCheck(upperKey)) {
      double gvValue = GlobalVariableGet(upperKey);
      if(gvValue > 0) gridUpper = gvValue;
   }

   bool hasValidBounds = (gridLower > 0 && gridUpper > gridLower);
   bool isBelowRange = hasValidBounds ? (currentBid < gridLower) : true;
   bool isInRange = hasValidBounds ? (currentBid >= gridLower && currentBid <= gridUpper) : false;

   if(isBelowRange) {
      if(InpEnableDetailedLog && TimeCurrent() % 60 == 0) {
         double pl = GetTotalHedgePL();
         Print("BELOW RANGE: Holding | DD: ", DoubleToString(currentDD, 1), "% | P/L: $", DoubleToString(pl, 2));
      }
   }
   else if(isInRange) {
      if(currentDD < g_EffSafeUnwind) {
         double pl = GetTotalHedgePL();

         // PA21 Fix 1: Require hedge to be net profitable before closing.
         // Prevents closing an underwater hedge and immediately unfreezing Executor
         // into unprotected grid positions at the worst price point.
         if(pl <= 0) {
            Print("SAFEUNWIND HOLD: DD=", DoubleToString(currentDD, 2),
                  "% but hedge P/L=$", DoubleToString(pl, 2), " — waiting for profit");
            return;
         }

         // PA21 Fix 3: Require each active stage to be >= InpMinStageHoldMins old.
         // Prevents Stage 3 opened at price bottom from closing immediately on first bounce.
         int holdSecs = InpMinStageHoldMins * 60;
         for(int i = 0; i < 3; i++) {
            if(g_HedgeTickets[i] > 0 && g_StageOpenTime[i] > 0) {
               int ageSecs = (int)(TimeCurrent() - g_StageOpenTime[i]);
               if(ageSecs < holdSecs) {
                  Print("SAFEUNWIND HOLD: Stage ", i+1, " only ", ageSecs,
                        "s old (min=", holdSecs, "s) — waiting to mature");
                  return;
               }
            }
         }

         Print("RECOVERY CONFIRMED:");
         Print("   | DD: ", DoubleToString(currentDD, 2), "% < ", InpSafeUnwindDD, "%");
         Print("   | P/L: $", DoubleToString(pl, 2));

         // C03 fix: close all stage tickets
         bool allClosed = true;
         for(int i = 0; i < 3; i++) {
            if(g_HedgeTickets[i] > 0) {
               if(trade.PositionClose(g_HedgeTickets[i])) {
                  g_HedgeTickets[i] = 0;
               } else {
                  allClosed = false;
                  Print("Failed to close stage ", i+1, " ticket: ", g_HedgeTickets[i]);
               }
            }
         }

         if(allClosed) {
            Print("HEDGE CLOSED SUCCESSFULLY");
            g_HedgeActive = false;
            g_HedgeStage  = 0;
            g_HedgeOpenVolume = 0.0;
            g_MaxEquity = AccountInfoDouble(ACCOUNT_EQUITY);

            SaveHedgeState();
            // C02 fix: namespaced key
            string hKey = GetCrossKey("HEDGE_ACTIVE");
            if(hKey != "") GlobalVariableSet(hKey, 0);

            Alert("HEDGE UNWOUND @ ", currentBid);
            WriteLog("SAFE_UNWIND", 0, currentBid, 0, 0,
               StringFormat("pl=%.2f dd=%.2f%%", pl, currentDD));
         }
      }
   }
}

//+------------------------------------------------------------------+
//| CANNIBALISM LOGIC                                                |
//+------------------------------------------------------------------+
void ProcessCannibalism()
{
   // C03 fix: verify at least one hedge ticket active
   bool anyActive = false;
   for(int i = 0; i < 3; i++) if(g_HedgeTickets[i] > 0) anyActive = true;
   if(!anyActive || !g_HedgeActive) return;

   // C03 fix: sum profit and volume across all hedge positions
   double hedgeProfit = GetTotalHedgePL();
   double hedgeVol = GetTotalHedgeVolume();

   if(hedgeProfit < InpPruneThreshold) return;

   ulong worstTicket = 0;
   double worstLoss = 0.0;
   double worstVol = 0.0;

   for(int i=PositionsTotal()-1; i>=0; i--) {
      ulong t = PositionGetTicket(i);
      if(t == 0) continue;
      if(!PositionSelectByTicket(t)) continue;

      if(PositionGetInteger(POSITION_MAGIC) == g_DetectedGridMagic) {
         if(IsTradeBeingDredged(t)) continue;

         double p = PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP);

         if(p < worstLoss) {
            worstLoss = p;
            worstTicket = t;
            worstVol = PositionGetDouble(POSITION_VOLUME);
         }
      }
   }

   if(worstTicket == 0) return;

   double costToKill = MathAbs(worstLoss);
   double budget = hedgeProfit - InpPruneBuffer;

   if(budget <= costToKill) return;

   Print("CANNIBALISM TARGET: #", worstTicket, " | Loss: $", DoubleToString(worstLoss, 2));

   // PA19 fix: Close grid position FIRST — if it fails, hedge is unchanged (safe).
   // Previous order (hedge reduce → grid close) left hedge UNDERSIZED if grid close failed.
   // Reversed order worst-case: hedge stays over-sized (conservative, not dangerous).
   if(!trade.PositionClose(worstTicket)) {
      Print("CANNIBALISM: Grid close failed — hedge unchanged, will retry next cycle");
      return;
   }

   // Grid position confirmed closed. Record stats.
   g_CannibalismCount++;
   g_TotalPruned += MathAbs(worstLoss);
   string pMsg = "CANNIBALISM: Killed trade #" + IntegerToString(worstTicket) + " | Loss: $" + DoubleToString(worstLoss, 2);
   Print(pMsg);
   SendAlert(pMsg);
   WriteLog("CANNIBALISM", 0, 0, 0, worstTicket,
      StringFormat("loss=%.2f totalPruned=%.2f", worstLoss, g_TotalPruned));

   // Step 2: Right-size hedge to the actual (now smaller) grid exposure.
   // Re-query live exposure post-close for accuracy (avoids relying on worstVol estimate).
   double activeRatio = 0.0;
   if(g_HedgeStage >= 1) activeRatio += InpHedgeRatio1;
   if(g_HedgeStage >= 2) activeRatio += InpHedgeRatio2;
   if(g_HedgeStage >= 3) activeRatio += InpHedgeRatio3;

   double newGridNet = CalculateGridNetExposure();
   double targetHedgeVol = NormalizeDouble(newGridNet * activeRatio, 2);
   double hedgeToClose = hedgeVol - targetHedgeVol;

   double minVol = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   if(hedgeToClose >= minVol) {
      if(hedgeToClose >= hedgeVol) hedgeToClose = hedgeVol - minVol;
      hedgeToClose = NormalizeDouble(hedgeToClose, 2);

      // C03 fix: close partial from whichever stage ticket has enough volume
      bool partialClosed = false;
      for(int i = 2; i >= 0; i--) { // Highest stage first (most recent)
         if(g_HedgeTickets[i] == 0) continue;
         if(!PositionSelectByTicket(g_HedgeTickets[i])) continue;

         double thisVol = PositionGetDouble(POSITION_VOLUME);
         if(thisVol > hedgeToClose + minVol) {
            if(trade.PositionClosePartial(g_HedgeTickets[i], hedgeToClose)) {
               Print("Step 2: Hedge Stage ", i+1, " reduced by ", hedgeToClose, " lots");
               WriteLog("HEDGE_REDUCE", i+1, 0, hedgeToClose, g_HedgeTickets[i],
                  StringFormat("targetVol=%.2f stage=%d", targetHedgeVol, i+1));
               partialClosed = true;
               break;
            }
         }
      }

      if(!partialClosed)
         Print("CANNIBALISM: Hedge reduction skipped — oversized by ", DoubleToString(hedgeToClose, 2),
               " lots (safe: over-hedged is conservative)");
   }

   g_HedgeOpenVolume = GetTotalHedgeVolume();
   Print("CANNIBALISM COMPLETE: Total=$", DoubleToString(g_TotalPruned, 2));
   SaveHedgeState();
}

//+------------------------------------------------------------------+
//| HELPER FUNCTIONS                                                 |
//+------------------------------------------------------------------+
double CalculateGridNetExposure()
{
   double netVol = 0.0;

   for(int i=PositionsTotal()-1; i>=0; i--) {
      ulong t = PositionGetTicket(i);
      if(t == 0) continue;
      if(!PositionSelectByTicket(t)) continue;

      if(PositionGetInteger(POSITION_MAGIC) == g_DetectedGridMagic) {
         double vol = PositionGetDouble(POSITION_VOLUME);
         long type = PositionGetInteger(POSITION_TYPE);

         if(type == POSITION_TYPE_BUY) netVol += vol;
         else if(type == POSITION_TYPE_SELL) netVol -= vol;
      }
   }

   return netVol;
}

int CountGridPositions()
{
   int count = 0;

   for(int i=PositionsTotal()-1; i>=0; i--) {
      ulong t = PositionGetTicket(i);
      if(t == 0) continue;
      if(!PositionSelectByTicket(t)) continue;

      if(PositionGetInteger(POSITION_MAGIC) == g_DetectedGridMagic) {
         count++;
      }
   }

   return count;
}

bool IsTradeBeingDredged(ulong ticket)
{
   // C02 fix: use namespaced dredge target key
   string dKey = GetCrossKey("DREDGE_TARGET");
   if(dKey != "" && GlobalVariableCheck(dKey)) {
      ulong target = (ulong)GlobalVariableGet(dKey);
      if(target == ticket) return true;
   }
   return false;
}

bool VerifyHedgeExists()
{
   // C03 fix: verify at least one stage ticket is live
   for(int i = 0; i < 3; i++) {
      if(g_HedgeTickets[i] == 0) continue;

      for(int k=PositionsTotal()-1; k>=0; k--) {
         ulong t = PositionGetTicket(k);
         if(t == g_HedgeTickets[i]) {
            if(PositionSelectByTicket(t) &&
               PositionGetInteger(POSITION_MAGIC) == InpHedgeMagic) {
               return true;
            }
         }
      }
      // This ticket not found in positions — clean up
      g_HedgeTickets[i] = 0;
   }

   return false;
}

bool VerifyHedgeHealthy()
{
   // C03 fix: check all active tickets and clean up orphans
   bool anyHealthy = false;
   for(int i = 0; i < 3; i++) {
      if(g_HedgeTickets[i] == 0) continue;

      if(!PositionSelectByTicket(g_HedgeTickets[i])) {
         g_HedgeTickets[i] = 0;
         continue;
      }
      if(PositionGetInteger(POSITION_TYPE) != POSITION_TYPE_SELL) continue;
      if(PositionGetInteger(POSITION_MAGIC) != InpHedgeMagic) continue;
      anyHealthy = true;
   }
   return anyHealthy;
}

void VerifyExposureBalance()
{
   if(!g_HedgeActive) return;

   double gridNet = CalculateGridNetExposure();
   // C03 fix: sum volume across all hedge tickets
   double hedgeVol = GetTotalHedgeVolume();

   double netExposure = gridNet - hedgeVol;

   double activeRatio = 0.0;
   if(g_HedgeStage >= 1) activeRatio += InpHedgeRatio1;
   if(g_HedgeStage >= 2) activeRatio += InpHedgeRatio2;
   if(g_HedgeStage >= 3) activeRatio += InpHedgeRatio3;

   double expectedLeak = gridNet * (1.0 - activeRatio);

   if(MathAbs(netExposure - expectedLeak) > 0.10) {
      Print("EXPOSURE IMBALANCE:");
      Print("   | Grid: ", DoubleToString(gridNet, 2));
      Print("   | Hedge: ", DoubleToString(hedgeVol, 2));
      Print("   | Net: ", DoubleToString(netExposure, 2));
   }
}

void CheckGridExpansion()
{
   if(!g_GridDetected) return;
   if(TimeCurrent() - g_LastGridCheck < 10) return;

   string levelsKey = g_GridGVPrefix + "LEVELS";

   if(!GlobalVariableCheck(levelsKey)) {
      g_LastGridCheck = TimeCurrent();
      return;
   }

   int currentLevels = (int)GlobalVariableGet(levelsKey);

   if(g_LastKnownGridLevels == 0) {
      g_LastKnownGridLevels = currentLevels;
      g_LastGridCheck = TimeCurrent();
      return;
   }

   if(currentLevels > g_LastKnownGridLevels) {
      Print("GRID EXPANSION: ", g_LastKnownGridLevels, " -> ", currentLevels);
      g_LastKnownGridLevels = currentLevels;
   }

   g_LastGridCheck = TimeCurrent();
}

void CheckHedgeDuration()
{
   if(!g_HedgeActive || g_HedgeStartTime == 0) return;

   int durationHours = (int)((TimeCurrent() - g_HedgeStartTime) / 3600);

   if(durationHours >= InpMaxHedgeDurationHrs) {
      // C03 fix: verify at least one ticket is live before printing P/L
      double pl = GetTotalHedgePL();

      Print("DURATION LIMIT: ", durationHours, "hrs | P/L: $", DoubleToString(pl, 2));

      // C03 fix: close all stage tickets
      bool allClosed = true;
      for(int i = 0; i < 3; i++) {
         if(g_HedgeTickets[i] > 0) {
            if(trade.PositionClose(g_HedgeTickets[i])) {
               g_HedgeTickets[i] = 0;
            } else {
               allClosed = false;
            }
         }
      }

      if(allClosed) {
         g_HedgeActive = false;
         g_HedgeStage  = 0;
         g_HedgeOpenVolume = 0.0;
         g_MaxEquity = AccountInfoDouble(ACCOUNT_EQUITY);

         SaveHedgeState();
         // C02 fix: namespaced key
         string hKey = GetCrossKey("HEDGE_ACTIVE");
         if(hKey != "") GlobalVariableSet(hKey, 0);

         Alert("HEDGE CLOSED: Time limit (", durationHours, "hrs)");
      }
   }
}

void ExecuteHardStop()
{
   Print("EXECUTING HARD STOP");

   int closedGrid = 0;
   int closedHedge = 0;
   double totalLoss = 0.0;

   // L07 fix: retry failed closes up to 3 times
   for(int attempt = 0; attempt < 3; attempt++) {
      bool allClosed = true;
      for(int i=PositionsTotal()-1; i>=0; i--) {
         ulong ticket = PositionGetTicket(i);
         if(ticket == 0) continue;
         if(!PositionSelectByTicket(ticket)) continue;

         long magic = PositionGetInteger(POSITION_MAGIC);

         if(magic == g_DetectedGridMagic || magic == InpHedgeMagic) {
            double pl = PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP);
            totalLoss += pl;

            if(trade.PositionClose(ticket)) {
               if(magic == g_DetectedGridMagic) closedGrid++;
               else closedHedge++;
            } else {
               Print("HardStop: failed to close #", ticket, " (attempt ", attempt+1, ") RC=", trade.ResultRetcode());
               allClosed = false;
            }
         }
      }
      if(allClosed) break;
      if(attempt < 2) Sleep(200);
   }

   Print("Closed: Grid=", closedGrid, " Hedge=", closedHedge);
   Print("Total Loss: $", DoubleToString(totalLoss, 2));
   double hsEquity = AccountInfoDouble(ACCOUNT_EQUITY);
   double hsPeak   = g_MaxEquity;
   double hsDD     = (hsPeak > 0) ? (hsPeak - hsEquity) / hsPeak * 100.0 : 0.0;
   WriteLog("HARD_STOP", 0, hsEquity, 0, 0,
      StringFormat("dd=%.2f%% closedGrid=%d closedHedge=%d totalLoss=%.2f",
      hsDD, closedGrid, closedHedge, totalLoss));

   g_HedgeActive = false;
   // C03 fix: clear all ticket slots
   ArrayInitialize(g_HedgeTickets, 0);
   g_HedgeStage  = 0;
   g_HedgeOpenVolume = 0.0;
   g_MaxEquity = AccountInfoDouble(ACCOUNT_BALANCE);
   ClearHedgeState();

   // C02 fix: namespaced key
   string hKey = GetCrossKey("HEDGE_ACTIVE");
   if(hKey != "") GlobalVariableSet(hKey, 0);

   Alert("HARD STOP EXECUTED: Loss $", DoubleToString(totalLoss, 2));
}

double NormalizeLot(double lot)
{
   double stepLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   double minLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);

   double normalized = MathFloor(lot / stepLot) * stepLot;

   if(normalized < minLot) normalized = minLot;
   if(normalized > maxLot) normalized = maxLot;

   return NormalizeDouble(normalized, 2);
}
//+------------------------------------------------------------------+
//| CSV File Logger                                                  |
//+------------------------------------------------------------------+
void WriteLog(string event, int stage=0, double price=0, double lot=0,
              ulong ticket=0, string notes="")
{
   if(!InpEnableFileLog) return;
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   string dateStr = StringFormat("%04d-%02d-%02d", dt.year, dt.mon, dt.day);
   string fn = "GridBot_" + _Symbol + "_" + dateStr + ".csv";
   int h = FileOpen(fn, FILE_WRITE|FILE_READ|FILE_TXT|FILE_ANSI|FILE_SHARE_READ|FILE_SHARE_WRITE);
   if(h == INVALID_HANDLE) {
      if(InpEnableDetailedLog) Print("WriteLog: FileOpen failed for ", fn, " err=", GetLastError());
      return;
   }
   if(FileSize(h) == 0)
      FileWrite(h, "Timestamp,Bot,Event,Symbol,Level,Price,Lot,Ticket,Equity,Balance,Peak,DD_Pct,Notes");
   FileSeek(h, 0, SEEK_END);
   double equity  = AccountInfoDouble(ACCOUNT_EQUITY);
   double balance = AccountInfoDouble(ACCOUNT_BALANCE);
   double dd      = (g_MaxEquity > 0) ? (g_MaxEquity - equity) / g_MaxEquity * 100.0 : 0.0;
   StringReplace(notes, ",", ";");
   string row = StringFormat("%s,GUARDIAN,%s,%s,%d,%.5f,%.2f,%I64u,%.2f,%.2f,%.2f,%.2f,%s",
      TimeToString(TimeCurrent(), TIME_DATE|TIME_SECONDS),
      event, _Symbol, stage, price, lot, ticket,
      equity, balance, g_MaxEquity, dd, notes);
   FileWrite(h, row);
   FileClose(h);
}
//+------------------------------------------------------------------+
