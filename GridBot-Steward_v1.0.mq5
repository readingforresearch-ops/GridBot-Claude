//+------------------------------------------------------------------+
//|                  GridBot-Steward_v1.0.mq5                        |
//|        Unified Grid Trading + Hedge Defense Engine                |
//|        Combines Executor + Guardian into single EA                |
//|        Clean-sheet: All PA fixes baked in architecturally         |
//+------------------------------------------------------------------+
#property copyright "Strategy Architect - Steward Edition"
#property link      "https://www.exness.com"
#property version   "1.00"

#include <Trade\Trade.mqh>

//==================================================================
// INPUTS
//==================================================================
input group "=== 0. System Control ==="
input bool     InpResetState      = false;    // >> RESET SAVED DATA? (Use True to start fresh)
input int      InpGridMagic       = 205001;   // Grid Magic Number (Planner link)
input int      InpHedgeMagic      = 999999;   // Hedge Magic Number
input string   InpComment         = "Steward_v1";

input group "=== 1. Grid Settings ==="
input double   InpUpperPrice      = 2750.0;   // Initial Top (Ignored if Resuming)
input double   InpLowerPrice      = 2650.0;   // Initial Bottom (Ignored if Resuming)
input int      InpGridLevels      = 45;
input double   InpExpansionCoeff  = 1.0;      // Condensing coefficient (0.5-2.0)
input bool     InpStartAtUpper    = false;

input group "=== 2. Dynamic Grid (Upward Shift Only) ==="
input bool     InpEnableDynamicGrid = true;
input double   InpUpShiftTriggerPct = 0.10;   // Buffer % above upper to trigger shift
input double   InpUpShiftAmountPct  = 20.0;   // Shift amount as % of range

input group "=== 3. Rolling Tail & Execution ==="
input int      InpMaxPendingOrders = 20;
input int      InpMaxOpenPos       = 100;
input int      InpMaxSpread        = 2000;    // Max spread (points) for grid orders

input group "=== 4. Stepped Volume Zones ==="
input double   InpLotZone1        = 0.01;
input double   InpLotZone2        = 0.02;
input double   InpLotZone3        = 0.05;

input group "=== 5. Cash Flow Engine (The Bucket) ==="
input bool     InpUseBucketDredge = true;
input int      InpBucketRetentionHrs = 48;
input double   InpSurvivalRatio   = 0.5;
input double   InpDredgeRangePct  = 0.5;      // Price must move this % of range before dredge
input bool     InpUseVirtualTP    = true;

input group "=== 6. Hedge Defense ==="
input double   InpHedgeTrigger1   = 30.0;     // Stage 1 Trigger DD%
input double   InpHedgeRatio1     = 0.30;     // Stage 1 Hedge Ratio
input double   InpHedgeTrigger2   = 35.0;     // Stage 2 Trigger DD%
input double   InpHedgeRatio2     = 0.30;     // Stage 2 Hedge Ratio
input double   InpHedgeTrigger3   = 40.0;     // Stage 3 Trigger DD%
input double   InpHedgeRatio3     = 0.35;     // Stage 3 Hedge Ratio
input double   InpUltimateHardStopDD = 45.0;  // ULTIMATE: Close EVERYTHING at this DD%
input bool     InpEnableCannibalism = true;
input double   InpPruneThreshold  = 100.0;    // Min hedge profit ($) to start cannibalism
input double   InpPruneBuffer     = 20.0;     // Buffer ($) for cannibalism
input double   InpSafeUnwindDD    = 20.0;     // Close hedge if DD below this %
input int      InpMinStageHoldMins= 15;       // Min minutes before SafeUnwind (PA21)
input double   InpMinFreeMarginPct= 150.0;    // Required margin % before hedging
input int      InpMaxHedgeSpread  = 3500;     // Max spread (points) for hedge orders (PA20)
input int      InpMaxHedgeDurationHrs = 72;   // Force close hedge after N hours
input bool     InpAutoScaleToRisk = true;     // Scale triggers from Planner MAX_RISK_PCT
input int      InpFullCheckInterval = 5;      // Seconds between hedge management checks

input group "=== 7. Risk & Safety ==="
input double   InpHardStopDDPct   = 25.0;     // Grid Hard Stop DD% (balance-peak-based, PA16)

input group "=== 8. Dashboard & Visuals ==="
input bool              InpShowDashboard  = true;
input bool              InpShowGhostLines = true;
input bool              InpShowBreakEven  = true;
input ENUM_BASE_CORNER  InpDashCorner     = CORNER_LEFT_UPPER;
input color    InpColorZone1      = clrDodgerBlue;
input color    InpColorZone2      = clrOrange;
input color    InpColorZone3      = clrRed;

input group "=== 9. Logging & Notifications ==="
input bool     InpEnableTradeLog  = true;
input bool     InpEnableFileLog   = true;     // Write events to daily CSV log file
input bool     InpEnableDetailedLog = true;
input bool     InpEnablePushNotify = true;
input bool     InpEnableEmailNotify= false;
input bool     InpAllowRemoteOpt  = true;     // Accept Planner PUSH TO LIVE
input bool     InpEnableStateRecovery = true;

//==================================================================
// STRUCTURES
//==================================================================
struct BucketItem {
   double   amount;
   datetime time;
};

struct ZoneStats {
   int count;
   double profit;
   double volume;
   double avgPrice;
};

struct WorstPosition {
   ulong ticket;
   int level;
   double loss;
   double price;
   double distPct;
};

//==================================================================
// GLOBALS
//==================================================================
CTrade         tradeGrid;    // magic=InpGridMagic (205001) for all grid operations
CTrade         tradeHedge;   // magic=InpHedgeMagic (999999) for all hedge operations
BucketItem     g_BucketQueue[];

// Grid arrays
double         GridPrices[];
double         GridTPs[];
double         GridLots[];
double         GridStepSize[];
ulong          g_LevelTickets[];
bool           g_LevelLock[];

// Grid state (persistent via GVs)
double         g_CurrentUpper, g_CurrentLower;
int            g_CurrentLevels;
double         g_ActiveExpansionCoeff = 1.0;
double         g_BucketTotal = 0.0;
double         g_NetExposure = 0.0;

// Runtime lot overrides (updatable via PUSH TO LIVE)
double         g_RuntimeLot1 = 0.0, g_RuntimeLot2 = 0.0, g_RuntimeLot3 = 0.0;
int            g_RuntimeMaxSpread = 0;

// Zone floors
double         g_OriginalZone1_Floor, g_OriginalZone2_Floor;
double         g_TotalRangeDist = 0.0;

// Environment
int            DIGITS;
double         POINT, STEP_LOT, MIN_LOT, MAX_LOT;
const int      MAX_GRID_LEVELS = 200;

// Grid hard stop (PA16: balance-peak-based)
bool           IsTradingActive = true;
double         g_PeakBalance = 0.0;        // Highest BALANCE — floor rises with realized profits only
double         g_DynamicHardStop = 0.0;

// Hedge state — THE freeze flag is just a local bool (no GV coordination needed)
bool           g_HedgeActive = false;
ulong          g_HedgeTickets[3];
datetime       g_StageOpenTime[3];
datetime       g_HedgeStartTime = 0;
double         g_HedgeOpenVolume = 0.0, g_HedgeOpenPrice = 0.0;
int            g_HedgeStage = 0;
double         g_HedgePeakEquity = 0.0;    // Highest EQUITY — for hedge DD% calc (Guardian-style)
int            g_CannibalismCount = 0;
double         g_TotalPruned = 0.0;

// Effective thresholds (possibly auto-scaled by Planner MAX_RISK_PCT)
double         g_EffTrigger1 = 0.0, g_EffTrigger2 = 0.0, g_EffTrigger3 = 0.0;
double         g_EffHardStop = 0.0, g_EffSafeUnwind = 0.0;

// Dashboard stats
double         g_BreakEvenPrice = 0.0;
double         g_InitialBalance = 0.0;
bool           g_UsingAutoDefaults = false;
double         g_TotalDredged = 0.0;
double         g_DayPL = 0.0, g_WeekPL = 0.0;
int            g_TradesToday = 0, g_WinsToday = 0;
double         g_AvgWin = 0.0, g_AvgLoss = 0.0;
ZoneStats      g_Z1, g_Z2, g_Z3;
double         g_MaxDDPercent = 0.0;
int            g_DeepestLevel = 0, g_HighestLevel = 0;
double         g_DeepestPrice = 0.0, g_HighestPrice = 0.0;
double         g_NextLevelPrice = 0.0, g_BucketFillRate = 0.0;
WorstPosition  g_WorstPositions[3];
ulong          g_CurrentDredgeTarget = 0;

// Rate limiters
datetime       g_LastHistoryCheck, g_LastHistoryScan = 0;
datetime       g_LastDredgeTime = 0, g_LastOrderTime = 0, g_LastTailTime = 0;
datetime       g_LastLineUpdate = 0, g_LastDashUpdate = 0;
datetime       g_LastExposurePublish = 0, g_LastOptCheck = 0;
datetime       g_LastFullCheck = 0, g_LastStateCheck = 0;
datetime       g_StartTime, g_BucketStartTime;

// Forward declarations
void MapSystemToGrid();
void SyncMemoryWithBroker();
void CalculateCondensingGrid();
void DrawGhostLines();
void UpdateDashboard();
void CalculateDashboardStats();
void CloseAllGridPositions();
void CloseAllPositionsNuclear();
void DeleteAllOrders();
ENUM_ORDER_TYPE_FILLING GetFillingMode();
int GetLevelIndex(double price);
double NormalizeLot(double lot);
void ManageExits(double currentBid);
int GetZone(double price);
void ManageBucketDredging();
void RecalculateBucketTotal();
bool SpendFromBucket(double requiredAmount);
void CleanExpiredBucketItems();
void AddToBucket(double amount, datetime dealTime);
void ScanForRealizedProfits();
void ManageGridEntry(double ask);
void ManageRollingTail();
void CheckDynamicGrid(double ask, double bid);
void RebuildGrid(bool preserveBottom);
void DrawBreakEvenLine();
bool IsGridHealthy();
void LogTrade(string action, int level, double price, double lot, ulong ticket);
void WriteLog(string event, int level=0, double price=0, double lot=0, ulong ticket=0, string notes="");
void SaveGridState();
bool LoadGridState();
void ClearGridState();
void SaveHedgeState();
bool LoadHedgeState();
void ClearHedgeState();
void PublishCoordinationData();
double CalculateNetExposure();
void CheckForOptimizationUpdates();
void SendAlert(string msg);
void ExecuteHedge(int targetStage);
void ManageUnwindLogic(double currentDD);
void ProcessCannibalism();
void CheckHedgeDuration();
void VerifyExposureBalance();
bool VerifyHedgeHealthy();
bool VerifyHedgeExists();
double GetTotalHedgeVolume();
double GetTotalHedgePL();
double CalculateGridNetExposure();
void RecalcEffectiveThresholds();

//==================================================================
// UTILITY FUNCTIONS
//==================================================================
string GetGridGVKey(string suffix) {
   return IntegerToString(InpGridMagic) + "_SG_" + suffix;
}

string GetHedgeGVKey(string suffix) {
   return IntegerToString(InpHedgeMagic) + "_GH_" + suffix;
}

string FormatAge(int seconds) {
   if(seconds < 60)   return IntegerToString(seconds) + "s ago";
   if(seconds < 3600) return IntegerToString(seconds / 60) + "m ago";
   return IntegerToString(seconds / 3600) + "h " + IntegerToString((seconds % 3600) / 60) + "m ago";
}

ENUM_ORDER_TYPE_FILLING GetFillingMode()
{
   int f = (int)SymbolInfoInteger(_Symbol, SYMBOL_FILLING_MODE);
   if((f & SYMBOL_FILLING_FOK) == SYMBOL_FILLING_FOK) return ORDER_FILLING_FOK;
   if((f & SYMBOL_FILLING_IOC) == SYMBOL_FILLING_IOC) return ORDER_FILLING_IOC;
   return ORDER_FILLING_RETURN;
}

double NormalizeLot(double lot)
{
   double n = MathFloor(lot / STEP_LOT) * STEP_LOT;
   if(n < MIN_LOT) n = MIN_LOT;
   if(n > MAX_LOT) n = MAX_LOT;
   return NormalizeDouble(n, 2);
}

void SendAlert(string msg) {
   Alert(msg);
   if(InpEnablePushNotify) SendNotification(msg);
   if(InpEnableEmailNotify) SendMail("GridBot-Steward Alert", msg);
}

int GetZone(double price) {
   if(price > g_OriginalZone1_Floor) return 1;
   if(price > g_OriginalZone2_Floor) return 2;
   return 3;
}

int GetLevelIndex(double price) {
   for(int i=0; i<g_CurrentLevels; i++) {
      double tol = GridStepSize[i] * 0.4;
      if(MathAbs(price - GridPrices[i]) < tol) return i;
   }
   return -1;
}

//==================================================================
// STATE PERSISTENCE: GRID
//==================================================================
void SaveGridState() {
   GlobalVariableSet(GetGridGVKey("UPPER"), g_CurrentUpper);
   GlobalVariableSet(GetGridGVKey("LOWER"), g_CurrentLower);
   GlobalVariableSet(GetGridGVKey("LEVELS"), (double)g_CurrentLevels);
   GlobalVariableSet(GetGridGVKey("COEFF"), g_ActiveExpansionCoeff);
   RecalculateBucketTotal();
   GlobalVariableSet(GetGridGVKey("BUCKET"), g_BucketTotal);
   GlobalVariableSet(GetGridGVKey("LAST_UPDATE"), (double)TimeCurrent());
   GlobalVariableSet(GetGridGVKey("LOT1"), g_RuntimeLot1);
   GlobalVariableSet(GetGridGVKey("LOT2"), g_RuntimeLot2);
   GlobalVariableSet(GetGridGVKey("LOT3"), g_RuntimeLot3);
   GlobalVariableSet(GetGridGVKey("PEAK_EQUITY"), g_PeakBalance);
   GlobalVariableSet(GetGridGVKey("NET_EXPOSURE"), g_NetExposure);
   GlobalVariableSet(GetGridGVKey("BOT_ACTIVE"), IsTradingActive ? 1.0 : 0.0);
   GlobalVariableSet(GetGridGVKey("HARD_STOP_LEVEL"), g_DynamicHardStop);
}

bool LoadGridState() {
   if(!GlobalVariableCheck(GetGridGVKey("UPPER"))) return false;
   if(!GlobalVariableCheck(GetGridGVKey("LAST_UPDATE"))) return false;

   g_CurrentUpper  = GlobalVariableGet(GetGridGVKey("UPPER"));
   g_CurrentLower  = GlobalVariableGet(GetGridGVKey("LOWER"));
   g_CurrentLevels = (int)GlobalVariableGet(GetGridGVKey("LEVELS"));

   if(GlobalVariableCheck(GetGridGVKey("COEFF")))
      g_ActiveExpansionCoeff = GlobalVariableGet(GetGridGVKey("COEFF"));
   else
      g_ActiveExpansionCoeff = InpExpansionCoeff;

   if(GlobalVariableCheck(GetGridGVKey("LOT1"))) g_RuntimeLot1 = GlobalVariableGet(GetGridGVKey("LOT1"));
   if(GlobalVariableCheck(GetGridGVKey("LOT2"))) g_RuntimeLot2 = GlobalVariableGet(GetGridGVKey("LOT2"));
   if(GlobalVariableCheck(GetGridGVKey("LOT3"))) g_RuntimeLot3 = GlobalVariableGet(GetGridGVKey("LOT3"));
   if(GlobalVariableCheck(GetGridGVKey("PEAK_EQUITY"))) {
      g_PeakBalance = GlobalVariableGet(GetGridGVKey("PEAK_EQUITY"));
      g_DynamicHardStop = g_PeakBalance * (1.0 - InpHardStopDDPct / 100.0);
      Print("Hard Stop restored: Peak balance=$", DoubleToString(g_PeakBalance, 2),
            " | Floor=$", DoubleToString(g_DynamicHardStop, 2));
   }

   double savedBucket = 0;
   if(GlobalVariableCheck(GetGridGVKey("BUCKET")))
      savedBucket = GlobalVariableGet(GetGridGVKey("BUCKET"));
   if(savedBucket > 0) {
      ArrayResize(g_BucketQueue, 1);
      g_BucketQueue[0].amount = savedBucket;
      g_BucketQueue[0].time   = TimeCurrent();
      g_BucketTotal = savedBucket;
   }
   return true;
}

void ClearGridState() {
   string keys[] = {"UPPER","LOWER","LEVELS","COEFF","BUCKET","LAST_UPDATE","NET_EXPOSURE",
                     "LOT1","LOT2","LOT3","PEAK_EQUITY","HARD_STOP_LEVEL",
                     "OPT_NEW_UPPER","OPT_NEW_LOWER","OPT_NEW_LEVELS","OPT_NEW_COEFF",
                     "OPT_NEW_LOT1","OPT_NEW_LOT2","OPT_NEW_LOT3","OPT_NEW_MAX_SPREAD",
                     "OPT_CMD_PushTime","OPT_LAST_APPLIED"};
   for(int i=0; i<ArraySize(keys); i++) GlobalVariableDel(GetGridGVKey(keys[i]));
}

//==================================================================
// STATE PERSISTENCE: HEDGE
//==================================================================
void SaveHedgeState() {
   if(!InpEnableStateRecovery) return;
   GlobalVariableSet(GetHedgeGVKey("PEAK_EQUITY"), g_HedgePeakEquity);
   GlobalVariableSet(GetHedgeGVKey("ACTIVE"), g_HedgeActive ? 1.0 : 0.0);
   GlobalVariableSet(GetHedgeGVKey("TICKET_1"), (double)g_HedgeTickets[0]);
   GlobalVariableSet(GetHedgeGVKey("TICKET_2"), (double)g_HedgeTickets[1]);
   GlobalVariableSet(GetHedgeGVKey("TICKET_3"), (double)g_HedgeTickets[2]);
   GlobalVariableSet(GetHedgeGVKey("START_TIME"), (double)g_HedgeStartTime);
   GlobalVariableSet(GetHedgeGVKey("OPEN_VOL"), g_HedgeOpenVolume);
   GlobalVariableSet(GetHedgeGVKey("OPEN_PRICE"), g_HedgeOpenPrice);
   GlobalVariableSet(GetHedgeGVKey("HEARTBEAT_TS"), (double)TimeCurrent());
   GlobalVariableSet(GetHedgeGVKey("STAGE"), (double)g_HedgeStage);
   GlobalVariableSet(GetHedgeGVKey("GRID_MAGIC"), (double)InpGridMagic);
   GlobalVariableSet(GetHedgeGVKey("LAST_UPDATE"), (double)TimeCurrent());
}

bool LoadHedgeState() {
   if(!InpEnableStateRecovery) return false;
   if(!GlobalVariableCheck(GetHedgeGVKey("LAST_UPDATE"))) return false;

   datetime lastUpdate = (datetime)GlobalVariableGet(GetHedgeGVKey("LAST_UPDATE"));
   if(TimeCurrent() - lastUpdate > 86400) {
      Print("WARNING: Hedge state is stale (>24h) — discarding");
      ClearHedgeState();
      return false;
   }

   g_HedgePeakEquity = GlobalVariableGet(GetHedgeGVKey("PEAK_EQUITY"));
   g_HedgeActive = (GlobalVariableGet(GetHedgeGVKey("ACTIVE")) > 0.5);

   if(GlobalVariableCheck(GetHedgeGVKey("TICKET_1"))) {
      g_HedgeTickets[0] = (ulong)GlobalVariableGet(GetHedgeGVKey("TICKET_1"));
      g_HedgeTickets[1] = (ulong)GlobalVariableGet(GetHedgeGVKey("TICKET_2"));
      g_HedgeTickets[2] = (ulong)GlobalVariableGet(GetHedgeGVKey("TICKET_3"));
   } else {
      ArrayInitialize(g_HedgeTickets, 0);
   }

   g_HedgeStartTime  = (datetime)GlobalVariableGet(GetHedgeGVKey("START_TIME"));
   g_HedgeOpenVolume  = GlobalVariableGet(GetHedgeGVKey("OPEN_VOL"));
   g_HedgeOpenPrice   = GlobalVariableGet(GetHedgeGVKey("OPEN_PRICE"));
   g_HedgeStage = GlobalVariableCheck(GetHedgeGVKey("STAGE"))
                  ? (int)GlobalVariableGet(GetHedgeGVKey("STAGE"))
                  : (g_HedgeActive ? 3 : 0);

   Print("HEDGE STATE RESTORED: Peak=$", DoubleToString(g_HedgePeakEquity, 2),
         " | Active=", g_HedgeActive, " | Stage=", g_HedgeStage);
   return true;
}

void ClearHedgeState() {
   string keys[] = {"PEAK_EQUITY","ACTIVE","TICKET","TICKET_1","TICKET_2","TICKET_3",
                     "START_TIME","OPEN_VOL","OPEN_PRICE","STAGE","HEARTBEAT_TS",
                     "GRID_MAGIC","LAST_UPDATE"};
   for(int i=0; i<ArraySize(keys); i++) GlobalVariableDel(GetHedgeGVKey(keys[i]));
   ArrayInitialize(g_StageOpenTime, 0);
}

// Hedge helpers
double GetTotalHedgeVolume() {
   double total = 0;
   for(int i = 0; i < 3; i++)
      if(g_HedgeTickets[i] > 0 && PositionSelectByTicket(g_HedgeTickets[i]))
         total += PositionGetDouble(POSITION_VOLUME);
   return total;
}

double GetTotalHedgePL() {
   double total = 0;
   for(int i = 0; i < 3; i++)
      if(g_HedgeTickets[i] > 0 && PositionSelectByTicket(g_HedgeTickets[i]))
         total += PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP);
   return total;
}

double CalculateNetExposure() {
   double netVol = 0.0;
   for(int i=PositionsTotal()-1; i>=0; i--) {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(!PositionSelectByTicket(ticket)) continue;
      if(PositionGetInteger(POSITION_MAGIC) == InpGridMagic) {
         double vol = PositionGetDouble(POSITION_VOLUME);
         long type = PositionGetInteger(POSITION_TYPE);
         if(type == POSITION_TYPE_BUY) netVol += vol;
         else if(type == POSITION_TYPE_SELL) netVol -= vol;
      }
   }
   return netVol;
}

double CalculateGridNetExposure() { return CalculateNetExposure(); }

bool IsTradeBeingDredged(ulong ticket) {
   return (g_CurrentDredgeTarget > 0 && g_CurrentDredgeTarget == ticket);
}

void RecalcEffectiveThresholds() {
   g_EffTrigger1  = InpHedgeTrigger1;
   g_EffTrigger2  = InpHedgeTrigger2;
   g_EffTrigger3  = InpHedgeTrigger3;
   g_EffHardStop  = InpUltimateHardStopDD;
   g_EffSafeUnwind = InpSafeUnwindDD;

   if(!InpAutoScaleToRisk) return;

   string riskKey = GetGridGVKey("MAX_RISK_PCT");
   if(!GlobalVariableCheck(riskKey)) return;

   double maxRisk = GlobalVariableGet(riskKey);
   if(maxRisk <= 0 || maxRisk > 100) return;

   double scale = maxRisk / InpUltimateHardStopDD;
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
//| INITIALIZATION                                                    |
//+------------------------------------------------------------------+
int OnInit()
{
   Print("========================================");
   Print("GRIDBOT-STEWARD v1.0 — UNIFIED EDITION");
   Print("Grid Engine + Hedge Defense in One");
   Print("========================================");

   // 1. HEDGING ACCOUNT CHECK
   ENUM_ACCOUNT_MARGIN_MODE marginMode = (ENUM_ACCOUNT_MARGIN_MODE)AccountInfoInteger(ACCOUNT_MARGIN_MODE);
   if(marginMode == ACCOUNT_MARGIN_MODE_RETAIL_NETTING || marginMode == ACCOUNT_MARGIN_MODE_EXCHANGE) {
      Alert("CRITICAL: Account must be HEDGING type. Grid BUYs and Hedge SELLs cannot coexist on NETTING accounts.");
      return INIT_FAILED;
   }

   // 2. INSTANCE GUARD
   string instanceKey = "STEWARD_ACTIVE_" + _Symbol + "_" + IntegerToString(InpGridMagic);
   if(GlobalVariableCheck(instanceKey)) {
      long existing = (long)GlobalVariableGet(instanceKey);
      if(existing == InpGridMagic) {
         Alert("ERROR: Another Steward (magic=" + IntegerToString(InpGridMagic) + ") already running on " + _Symbol);
         return INIT_FAILED;
      }
   }
   GlobalVariableSet(instanceKey, (double)InpGridMagic);

   // 3. INPUT VALIDATION
   if(InpUpperPrice <= InpLowerPrice) { Alert("ERROR: Upper Price must be > Lower Price"); return INIT_PARAMETERS_INCORRECT; }
   if(InpGridLevels < 5 || InpGridLevels > MAX_GRID_LEVELS) { Alert("ERROR: Grid Levels must be 5-", MAX_GRID_LEVELS); return INIT_PARAMETERS_INCORRECT; }
   if(InpExpansionCoeff < 0.5 || InpExpansionCoeff > 2.0) { Alert("ERROR: Expansion Coefficient must be 0.5-2.0"); return INIT_PARAMETERS_INCORRECT; }
   if(InpHardStopDDPct < 1.0 || InpHardStopDDPct > 50.0) { Alert("ERROR: Hard Stop DD% must be 1-50"); return INIT_PARAMETERS_INCORRECT; }
   if(InpHedgeTrigger1 >= InpUltimateHardStopDD) { Alert("ERROR: Trigger1 must be < Ultimate Hard Stop"); return INIT_PARAMETERS_INCORRECT; }
   if(InpHedgeTrigger2 <= InpHedgeTrigger1 || InpHedgeTrigger3 <= InpHedgeTrigger2) { Alert("ERROR: Triggers must be T1 < T2 < T3"); return INIT_PARAMETERS_INCORRECT; }
   double totalRatio = InpHedgeRatio1 + InpHedgeRatio2 + InpHedgeRatio3;
   if(totalRatio > 1.0 || InpHedgeRatio1 < 0 || InpHedgeRatio2 < 0 || InpHedgeRatio3 < 0) {
      Alert("ERROR: Hedge ratios must be >= 0 and sum <= 1.0 (sum=", DoubleToString(totalRatio, 2), ")");
      return INIT_PARAMETERS_INCORRECT;
   }

   // 4. ENVIRONMENT
   DIGITS   = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   POINT    = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   STEP_LOT = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   MIN_LOT  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   MAX_LOT  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);

   tradeGrid.SetExpertMagicNumber(InpGridMagic);
   tradeGrid.SetDeviationInPoints(50);
   tradeGrid.SetTypeFilling(GetFillingMode());
   tradeGrid.SetAsyncMode(false);

   tradeHedge.SetExpertMagicNumber(InpHedgeMagic);
   tradeHedge.SetDeviationInPoints(100);   // L06: wider for VPS latency
   tradeHedge.SetTypeFilling(GetFillingMode());
   tradeHedge.SetAsyncMode(false);

   // M01/M02/M16 safety checks
   if(!TerminalInfoInteger(TERMINAL_TRADE_ALLOWED)) Print("WARNING: AutoTrading is disabled — orders will fail!");
   if(!AccountInfoInteger(ACCOUNT_TRADE_EXPERT)) Print("WARNING: Expert Advisors not permitted on this account!");
   ENUM_ACCOUNT_TRADE_MODE accMode = (ENUM_ACCOUNT_TRADE_MODE)AccountInfoInteger(ACCOUNT_TRADE_MODE);
   if(accMode != ACCOUNT_TRADE_MODE_DEMO) {
      Print("WARNING: LIVE ACCOUNT — ensure strategy tested!");
      SendNotification("GridBot-Steward started on LIVE account: " + _Symbol);
   }
   ENUM_SYMBOL_TRADE_MODE tradeMode = (ENUM_SYMBOL_TRADE_MODE)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_MODE);
   if(tradeMode == SYMBOL_TRADE_MODE_DISABLED) { Alert("ERROR: Trading DISABLED for ", _Symbol); return INIT_FAILED; }
   if(tradeMode == SYMBOL_TRADE_MODE_CLOSEONLY) Print("WARNING: ", _Symbol, " is in CLOSE-ONLY mode!");

   // 5. RESET OR RESTORE
   if(InpResetState) { ClearGridState(); ClearHedgeState(); Print(">> ALL STATE RESET BY USER <<"); }

   // 6. LOAD GRID STATE
   if(LoadGridState()) {
      Print(">> GRID STATE RESUMED: ", g_CurrentUpper, " - ", g_CurrentLower, " | Levels: ", g_CurrentLevels);
   } else {
      Print(">> FRESH START: Using Input Defaults");
      // Smart instrument-aware defaults
      bool userLeftDefaults = (InpUpperPrice == 2750.0 && InpLowerPrice == 2650.0);
      if(userLeftDefaults) {
         double currentPrice = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
         double adjustedUpper = InpUpperPrice, adjustedLower = InpLowerPrice;
         string instrumentType = "";
         if(currentPrice > 50000) { adjustedUpper = currentPrice * 1.10; adjustedLower = currentPrice * 0.90; instrumentType = "CRYPTO"; }
         else if(currentPrice > 10000) { adjustedUpper = currentPrice * 1.05; adjustedLower = currentPrice * 0.95; instrumentType = "INDEX"; }
         else if(currentPrice < 10) { adjustedUpper = currentPrice * 1.03; adjustedLower = currentPrice * 0.97; instrumentType = "FOREX"; }
         else { instrumentType = "METAL (XAUUSD-range)"; }
         if(adjustedUpper != InpUpperPrice || adjustedLower != InpLowerPrice) {
            g_CurrentUpper = adjustedUpper; g_CurrentLower = adjustedLower; g_UsingAutoDefaults = true;
            Print("AUTO-RANGE: ", instrumentType, " @ ", DoubleToString(currentPrice, _Digits),
                  " -> ", DoubleToString(adjustedLower, _Digits), " - ", DoubleToString(adjustedUpper, _Digits));
            SendAlert("STEWARD: Using auto-adjusted range for " + instrumentType + ". Use Planner for optimal config.");
         } else { g_CurrentUpper = InpUpperPrice; g_CurrentLower = InpLowerPrice; g_UsingAutoDefaults = false; }
      } else {
         g_CurrentUpper = InpUpperPrice; g_CurrentLower = InpLowerPrice; g_UsingAutoDefaults = false;
      }
      g_CurrentLevels = InpGridLevels;
      g_ActiveExpansionCoeff = InpExpansionCoeff;
      g_BucketTotal = 0.0; g_NetExposure = 0.0;
      SaveGridState();
   }

   // 7. INIT LOTS
   if(g_RuntimeLot1 <= 0) g_RuntimeLot1 = InpLotZone1;
   if(g_RuntimeLot2 <= 0) g_RuntimeLot2 = InpLotZone2;
   if(g_RuntimeLot3 <= 0) g_RuntimeLot3 = InpLotZone3;

   // 8. GRID GEOMETRY
   g_TotalRangeDist = g_CurrentUpper - g_CurrentLower;
   g_OriginalZone1_Floor = g_CurrentUpper - (g_TotalRangeDist / 3.0);
   g_OriginalZone2_Floor = g_CurrentUpper - ((g_TotalRangeDist / 3.0) * 2.0);
   g_StartTime = TimeCurrent(); g_BucketStartTime = TimeCurrent();
   g_InitialBalance = AccountInfoDouble(ACCOUNT_BALANCE);
   if(g_PeakBalance <= 0) {
      g_PeakBalance = AccountInfoDouble(ACCOUNT_BALANCE);
      g_DynamicHardStop = g_PeakBalance * (1.0 - InpHardStopDDPct / 100.0);
   }
   g_LastHistoryCheck = TimeCurrent(); g_LastHistoryScan = TimeCurrent();

   CalculateCondensingGrid();
   int gridRetries = 0;
   while(!IsGridHealthy() && gridRetries < 3) { gridRetries++; Sleep(2000); CalculateCondensingGrid(); }
   if(!IsGridHealthy()) { Alert("ERROR: Grid validation failed after 3 retries"); return INIT_FAILED; }

   ArrayResize(g_LevelTickets, g_CurrentLevels); ArrayInitialize(g_LevelTickets, 0);
   ArrayResize(g_LevelLock, g_CurrentLevels); ArrayInitialize(g_LevelLock, false);
   MapSystemToGrid();

   // 9. LOAD HEDGE STATE
   ArrayInitialize(g_HedgeTickets, 0);
   LoadHedgeState();
   if(g_HedgePeakEquity <= 0) g_HedgePeakEquity = AccountInfoDouble(ACCOUNT_BALANCE);
   if(g_HedgeActive) {
      if(!VerifyHedgeExists()) {
         Print("Hedge state claimed active but no positions found — resetting");
         g_HedgeActive = false; ArrayInitialize(g_HedgeTickets, 0); g_HedgeStage = 0;
         SaveHedgeState();
      } else {
         Print("Existing hedge verified — resuming management");
      }
   }

   // 10. INIT THRESHOLDS
   RecalcEffectiveThresholds();

   // 11. PUBLISH + DRAW
   PublishCoordinationData();
   if(InpShowGhostLines) DrawGhostLines();
   EventSetTimer(1);

   Print("========================================");
   Print("Grid: ", g_CurrentUpper, " - ", g_CurrentLower, " (", g_CurrentLevels, " levels)");
   Print("Hedge: T1=", g_EffTrigger1, "% T2=", g_EffTrigger2, "% T3=", g_EffTrigger3, "% Stop=", g_EffHardStop, "%");
   Print("========================================");

   WriteLog("STARTUP", 0, 0, 0, 0,
      StringFormat("gridMagic=%d hedgeMagic=%d upper=%.2f lower=%.2f levels=%d hardstop=%.1f%% ultimateStop=%.1f%%",
      InpGridMagic, InpHedgeMagic, g_CurrentUpper, g_CurrentLower, g_CurrentLevels, InpHardStopDDPct, g_EffHardStop));
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   Print("GridBot-Steward v1.0 — Shutting down (reason=", reason, ")");
   EventKillTimer();
   SaveGridState();
   SaveHedgeState();
   GlobalVariableDel("STEWARD_ACTIVE_" + _Symbol + "_" + IntegerToString(InpGridMagic));

   if(reason != REASON_CHARTCHANGE) {
      GlobalVariableSet(GetGridGVKey("BOT_ACTIVE"), 0);
      GlobalVariableSet(GetGridGVKey("HEDGE_ACTIVE"), g_HedgeActive ? 1.0 : 0.0); // Planner display
      ObjectsDeleteAll(0, "GhostLine_");
      ObjectDelete(0, "SG_BreakEven");
      DashCleanup();
   }
}

//+------------------------------------------------------------------+
//| UNIFIED OnTick                                                    |
//+------------------------------------------------------------------+
void OnTick()
{
   // PHASE 0: HEARTBEAT — always first, before any early return (PA25 baked in)
   {
      static datetime lastHB = 0;
      if(TimeCurrent() != lastHB) {
         GlobalVariableSet(GetGridGVKey("HEARTBEAT"), (double)TimeCurrent());
         lastHB = TimeCurrent();
      }
   }

   // PHASE 1: TRADING HALT CHECK
   if(!IsTradingActive) return;

   // PHASE 2: PRICE STALENESS (M03)
   datetime lastTick = (datetime)SymbolInfoInteger(_Symbol, SYMBOL_TIME);
   if(TimeCurrent() - lastTick > 30) {
      if(TimeCurrent() % 60 == 0) Print("WARNING: Price data stale — ", (int)(TimeCurrent()-lastTick), "s");
      return;
   }

   // PHASE 3: HEDGE DD ASSESSMENT (equity-peak-based, Guardian-style)
   double currentEquity = AccountInfoDouble(ACCOUNT_EQUITY);
   if(currentEquity > g_HedgePeakEquity) {
      g_HedgePeakEquity = currentEquity;
      if(InpEnableStateRecovery && TimeCurrent() - g_LastStateCheck > 60) {
         SaveHedgeState();
         g_LastStateCheck = TimeCurrent();
      }
   }
   double currentDD = 0.0;
   if(g_HedgePeakEquity > 0.01)
      currentDD = (g_HedgePeakEquity - currentEquity) / g_HedgePeakEquity * 100.0;
   else {
      g_HedgePeakEquity = currentEquity;
      Print("WARNING: g_HedgePeakEquity was zero — reset to $", DoubleToString(currentEquity, 2));
   }

   // PHASE 4: ULTIMATE HARD STOP (closes EVERYTHING — grid + hedge)
   if(currentDD >= g_EffHardStop) {
      Print("CRITICAL: ULTIMATE HARD STOP AT ", DoubleToString(currentDD, 2), "% DD (limit=", g_EffHardStop, "%)");
      SendAlert("ULTIMATE HARD STOP! DD=" + DoubleToString(currentDD, 2) + "%");
      WriteLog("HARD_STOP_ULTIMATE", 0, currentEquity, 0, 0,
         StringFormat("dd=%.2f%% peak=%.2f", currentDD, g_HedgePeakEquity));
      CloseAllPositionsNuclear();
      g_HedgeActive = false; ArrayInitialize(g_HedgeTickets, 0); g_HedgeStage = 0;
      g_HedgeOpenVolume = 0.0; g_HedgePeakEquity = AccountInfoDouble(ACCOUNT_BALANCE);
      ClearHedgeState();
      IsTradingActive = false;
      return;
   }

   // PHASE 5: DETERMINE DESIRED HEDGE STAGE
   RecalcEffectiveThresholds();
   int desiredStage = 0;
   if(currentDD >= g_EffTrigger3)      desiredStage = 3;
   else if(currentDD >= g_EffTrigger2) desiredStage = 2;
   else if(currentDD >= g_EffTrigger1) desiredStage = 1;

   // PHASE 6: HEDGE MANAGEMENT (rate-limited)
   if(TimeCurrent() - g_LastFullCheck >= InpFullCheckInterval) {
      if(desiredStage > g_HedgeStage) {
         Print("Hedge Upscale: Stage ", g_HedgeStage, " -> ", desiredStage);
         ExecuteHedge(desiredStage);
      }

      if(g_HedgeActive) {
         if(!VerifyHedgeHealthy()) {
            Print("Hedge health check failed — resetting");
            g_HedgeActive = false; ArrayInitialize(g_HedgeTickets, 0); g_HedgeStage = 0;
            SaveHedgeState();
            WriteLog("ORPHAN", 0, 0, 0, 0, "Hedge health fail — all tickets invalid");
         } else {
            ManageUnwindLogic(currentDD);
            if(InpEnableCannibalism && g_HedgeActive) ProcessCannibalism();
            CheckHedgeDuration();
            VerifyExposureBalance();
         }
      }
      g_LastFullCheck = TimeCurrent();
   }

   // PHASE 7: FREEZE CHECK — just a local bool, no GV read needed
   if(g_HedgeActive) {
      // Peak balance tracking during freeze
      double frozenBalance = AccountInfoDouble(ACCOUNT_BALANCE);
      if(frozenBalance > g_PeakBalance) {
         g_PeakBalance = frozenBalance;
         g_DynamicHardStop = g_PeakBalance * (1.0 - InpHardStopDDPct / 100.0);
      }
      if(TimeCurrent() % 60 == 0) Print("FROZEN: Hedge active (Stage ", g_HedgeStage, "/3)");
      // Publish for Planner, then skip grid operations
      PublishCoordinationData();
      CheckForOptimizationUpdates();
      return;
   }

   // PHASE 8: GRID HARD STOP (balance-peak-based, PA16)
   double currentBalance = AccountInfoDouble(ACCOUNT_BALANCE);
   if(currentBalance > g_PeakBalance) {
      g_PeakBalance = currentBalance;
      g_DynamicHardStop = g_PeakBalance * (1.0 - InpHardStopDDPct / 100.0);
   }
   if(currentEquity < g_DynamicHardStop) {
      Print("CRITICAL: Grid Hard Stop! Equity=$", DoubleToString(currentEquity, 2),
            " < Floor=$", DoubleToString(g_DynamicHardStop, 2));
      double hsDD = (g_PeakBalance > 0) ? (g_PeakBalance - currentEquity) / g_PeakBalance * 100.0 : 0.0;
      WriteLog("HARD_STOP", 0, currentEquity, 0, 0,
         StringFormat("floor=%.2f peak=%.2f dd=%.2f%%", g_DynamicHardStop, g_PeakBalance, hsDD));
      IsTradingActive = false;
      CloseAllGridPositions();
      SendAlert("GRID HARD STOP: -" + DoubleToString(InpHardStopDDPct, 1) + "% from peak $" + DoubleToString(g_PeakBalance, 2));
      return;
   }

   // PHASE 9: GRID OPERATIONS
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);

   if(InpEnableDynamicGrid) CheckDynamicGrid(ask, bid);
   SyncMemoryWithBroker();
   ManageRollingTail();

   if(InpUseBucketDredge) { ScanForRealizedProfits(); CleanExpiredBucketItems(); }

   int effectiveMaxSpread = (g_RuntimeMaxSpread > 0) ? g_RuntimeMaxSpread : InpMaxSpread;
   bool spreadOK = ((ask-bid)/POINT <= effectiveMaxSpread);
   if(spreadOK) {
      ManageGridEntry(ask);
      ManageExits(bid);
      if(InpUseBucketDredge) ManageBucketDredging();
   }

   if(InpShowBreakEven) DrawBreakEvenLine();
   if(InpShowGhostLines && TimeCurrent() - g_LastLineUpdate > 60) {
      DrawGhostLines(); g_LastLineUpdate = TimeCurrent();
   }

   // PHASE 10: PUBLISH + PLANNER
   PublishCoordinationData();
   CheckForOptimizationUpdates();
}

void OnTimer()
{
   if(InpShowDashboard) { CalculateDashboardStats(); UpdateDashboard(); }
}

//+------------------------------------------------------------------+
//| DYNAMIC GRID (UPWARD SHIFT ONLY)                                  |
//+------------------------------------------------------------------+
void CheckDynamicGrid(double ask, double bid)
{
   double buffer = (g_CurrentUpper - g_CurrentLower) * (InpUpShiftTriggerPct / 100.0);
   if(ask > g_CurrentUpper + buffer) {
      double shiftAmt = (g_CurrentUpper - g_CurrentLower) * (InpUpShiftAmountPct / 100.0);
      Print("DYNAMIC GRID: Shifting UP by $", DoubleToString(shiftAmt, 2));
      g_CurrentUpper += shiftAmt; g_CurrentLower += shiftAmt;
      g_OriginalZone1_Floor += shiftAmt; g_OriginalZone2_Floor += shiftAmt;
      DeleteAllOrders();
      RebuildGrid(false);
      SaveGridState();
      DrawGhostLines();
      if(InpEnableTradeLog) LogTrade("GRID_SHIFT_UP", 0, g_CurrentUpper, shiftAmt, 0);
      return;
   }
   if(bid < g_CurrentLower && TimeCurrent() % 300 == 0)
      Print("WARNING: Price below grid: $", bid, " < $", g_CurrentLower);
}

void RebuildGrid(bool isExtension)
{
   ulong tempTickets[]; bool tempLocks[];
   int oldSize = ArraySize(g_LevelTickets);
   if(isExtension && oldSize > 0) {
      ArrayResize(tempTickets, oldSize); ArrayResize(tempLocks, oldSize);
      ArrayCopy(tempTickets, g_LevelTickets); ArrayCopy(tempLocks, g_LevelLock);
   }
   ArrayResize(g_LevelTickets, g_CurrentLevels); ArrayResize(g_LevelLock, g_CurrentLevels);
   if(isExtension && oldSize > 0) {
      for(int i=0; i<oldSize && i<g_CurrentLevels; i++) { g_LevelTickets[i] = tempTickets[i]; g_LevelLock[i] = tempLocks[i]; }
      for(int i=oldSize; i<g_CurrentLevels; i++) { g_LevelTickets[i] = 0; g_LevelLock[i] = false; }
   } else { ArrayInitialize(g_LevelTickets, 0); ArrayInitialize(g_LevelLock, false); }
   CalculateCondensingGrid();
   if(!IsGridHealthy()) { Sleep(1000); CalculateCondensingGrid(); if(!IsGridHealthy()) { Alert("GRID CORRUPTION"); IsTradingActive = false; return; } }
   if(!isExtension) MapSystemToGrid();
}

void CalculateCondensingGrid()
{
   ArrayResize(GridPrices, g_CurrentLevels); ArrayResize(GridTPs, g_CurrentLevels);
   ArrayResize(GridLots, g_CurrentLevels); ArrayResize(GridStepSize, g_CurrentLevels);
   double range = g_CurrentUpper - g_CurrentLower;
   double firstGap = range / g_CurrentLevels;
   if(MathAbs(1.0 - g_ActiveExpansionCoeff) > 0.0001) {
      double num = range * (1 - g_ActiveExpansionCoeff);
      double den = 1 - MathPow(g_ActiveExpansionCoeff, g_CurrentLevels);
      if(MathAbs(den) > 0.0000001) firstGap = num / den;
   }
   double currentPrice = g_CurrentUpper;
   if(!InpStartAtUpper) currentPrice -= firstGap;
   double currentGap = firstGap;
   for(int i=0; i<g_CurrentLevels; i++) {
      GridPrices[i] = NormalizeDouble(currentPrice, DIGITS);
      GridTPs[i] = (i == 0) ? NormalizeDouble(g_CurrentUpper, DIGITS) : GridPrices[i-1];
      GridStepSize[i] = currentGap;
      int z = GetZone(GridPrices[i]);
      GridLots[i] = NormalizeLot((z==1) ? g_RuntimeLot1 : (z==2) ? g_RuntimeLot2 : g_RuntimeLot3);
      currentGap *= g_ActiveExpansionCoeff;
      currentPrice -= currentGap;
   }
}

bool IsGridHealthy()
{
   if(g_CurrentLevels <= 0 || ArraySize(GridPrices) != g_CurrentLevels) return false;
   for(int i=0; i<g_CurrentLevels; i++) {
      if(GridPrices[i] <= 0 || GridLots[i] < MIN_LOT || GridLots[i] > MAX_LOT || GridStepSize[i] <= 0) return false;
      if(i > 0 && GridPrices[i] >= GridPrices[i-1]) return false;
      if(GridTPs[i] <= GridPrices[i]) return false;
   }
   return true;
}

//+------------------------------------------------------------------+
//| GRID ENGINE                                                       |
//+------------------------------------------------------------------+
void ManageGridEntry(double ask)
{
   if(TimeCurrent() - g_LastOrderTime < 1) return;
   if(!IsGridHealthy()) return;

   int myPositions = 0;
   for(int p = PositionsTotal()-1; p >= 0; p--) {
      ulong pt = PositionGetTicket(p);
      if(pt > 0 && PositionSelectByTicket(pt) && PositionGetInteger(POSITION_MAGIC) == InpGridMagic)
         myPositions++;
   }
   if(myPositions >= InpMaxOpenPos) return;

   for(int i=0; i<g_CurrentLevels; i++) {
      if(g_LevelTickets[i] > 0 || g_LevelLock[i]) continue;
      if(GridPrices[i] <= 0 || GridLots[i] <= 0) continue;

      int activePending = 0;
      for(int k=0; k<g_CurrentLevels; k++) {
         if(g_LevelTickets[k] > 0 && OrderSelect(g_LevelTickets[k]))
            if(OrderGetInteger(ORDER_STATE)==ORDER_STATE_PLACED) activePending++;
      }
      if(activePending >= InpMaxPendingOrders) continue;

      double target = GridPrices[i];
      double stopsLevel = (double)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL) * POINT;
      if(ask - target < stopsLevel) continue;

      // Seatbelt: no duplicate at this price
      bool duplicateFound = false;
      for(int k=PositionsTotal()-1; k>=0; k--) {
         ulong t = PositionGetTicket(k);
         if(PositionSelectByTicket(t) && PositionGetInteger(POSITION_MAGIC)==InpGridMagic) {
            if(MathAbs(PositionGetDouble(POSITION_PRICE_OPEN) - target) < (GridStepSize[i]*0.4)) {
               duplicateFound = true; g_LevelTickets[i] = t; break;
            }
         }
      }
      if(duplicateFound) continue;

      if(ask > target) {
         double margin_required;
         if(OrderCalcMargin(ORDER_TYPE_BUY_LIMIT, _Symbol, GridLots[i], target, margin_required))
            if(AccountInfoDouble(ACCOUNT_MARGIN_FREE) < margin_required * 1.1) continue;

         // Freeze guard: direct bool check — no GV needed (PA26 elimination)
         if(g_HedgeActive) continue;

         g_LevelLock[i] = true;
         string comment = "SG_L"+IntegerToString(i+1);
         double tp = InpUseVirtualTP ? 0 : GridTPs[i];

         if(tradeGrid.BuyLimit(GridLots[i], target, _Symbol, 0, tp, ORDER_TIME_GTC, 0, comment)) {
            if(tradeGrid.ResultRetcode()==TRADE_RETCODE_DONE || tradeGrid.ResultRetcode()==TRADE_RETCODE_PLACED) {
               g_LevelTickets[i] = tradeGrid.ResultOrder();
               g_LastOrderTime = TimeCurrent();
               if(InpEnableTradeLog) LogTrade("BUY_LIMIT", i+1, target, GridLots[i], g_LevelTickets[i]);
            } else {
               WriteLog("ORDER_FAIL", i+1, target, GridLots[i], 0,
                  StringFormat("rc=%d %s", tradeGrid.ResultRetcode(), tradeGrid.ResultRetcodeDescription()));
            }
         }
         g_LevelLock[i] = false;
      }
   }
}

void ManageExits(double curBid)
{
   if(!InpUseVirtualTP) return;
   for(int i=PositionsTotal()-1; i>=0; i--) {
      ulong t = PositionGetTicket(i);
      if(t==0 || !PositionSelectByTicket(t)) continue;
      if(PositionGetInteger(POSITION_MAGIC) != InpGridMagic) continue;
      double openPrice = PositionGetDouble(POSITION_PRICE_OPEN);
      int idx = GetLevelIndex(openPrice);
      if(idx >= 0 && idx < g_CurrentLevels) {
         if(curBid >= GridTPs[idx]) {
            if(tradeGrid.PositionClose(t)) {
               g_LevelTickets[idx] = 0;
               if(InpEnableTradeLog) LogTrade("TP_CLOSE", idx+1, curBid, 0, t);
            }
         }
      } else {
         // PA23: Orphaned position TP fallback
         double orphanTP = g_CurrentUpper;
         for(int k = g_CurrentLevels - 1; k >= 0; k--)
            if(GridPrices[k] > openPrice) { orphanTP = GridPrices[k]; break; }
         if(curBid >= orphanTP) {
            if(tradeGrid.PositionClose(t))
               if(InpEnableTradeLog) LogTrade("TP_CLOSE_ORPHAN", 0, curBid, 0, t);
         }
      }
   }
}

void ManageRollingTail()
{
   if(TimeCurrent() - g_LastTailTime < 2) return;
   int pend = 0;
   for(int i=0; i<g_CurrentLevels; i++)
      if(g_LevelTickets[i] > 0 && OrderSelect(g_LevelTickets[i]) && OrderGetInteger(ORDER_STATE)==ORDER_STATE_PLACED) pend++;
   if(pend <= InpMaxPendingOrders) return;
   int rem = pend - InpMaxPendingOrders;
   for(int i=g_CurrentLevels-1; i>=0 && rem>0; i--)
      if(g_LevelTickets[i] > 0 && OrderSelect(g_LevelTickets[i]) && OrderGetInteger(ORDER_STATE)==ORDER_STATE_PLACED)
         if(tradeGrid.OrderDelete(g_LevelTickets[i])) { g_LevelTickets[i] = 0; rem--; }
   g_LastTailTime = TimeCurrent();
}

void SyncMemoryWithBroker()
{
   static datetime lastSlowSync = 0;
   bool allowSlowPath = (TimeCurrent() - lastSlowSync >= 2);
   for(int i=0; i<g_CurrentLevels; i++) {
      ulong currentTicket = g_LevelTickets[i];
      if(currentTicket > 0) {
         bool verified = false;
         if(OrderSelect(currentTicket) && OrderGetInteger(ORDER_STATE)==ORDER_STATE_PLACED) verified = true;
         if(!verified && PositionSelectByTicket(currentTicket) && PositionGetInteger(POSITION_MAGIC)==InpGridMagic) verified = true;
         if(verified) continue;
      }
      if(!allowSlowPath) continue;
      double target = GridPrices[i]; double tol = GridStepSize[i] * 0.4; ulong found = 0;
      for(int k=PositionsTotal()-1; k>=0; k--) {
         ulong t = PositionGetTicket(k);
         if(!PositionSelectByTicket(t)) continue;
         if(PositionGetInteger(POSITION_MAGIC) != InpGridMagic) continue;
         if(MathAbs(PositionGetDouble(POSITION_PRICE_OPEN) - target) < tol) { found = t; break; }
      }
      if(found == 0) {
         for(int k=OrdersTotal()-1; k>=0; k--) {
            ulong t = OrderGetTicket(k);
            if(!OrderSelect(t)) continue;
            if(OrderGetInteger(ORDER_MAGIC) != InpGridMagic) continue;
            if(OrderGetInteger(ORDER_STATE) != ORDER_STATE_PLACED) continue;
            if(MathAbs(OrderGetDouble(ORDER_PRICE_OPEN) - target) < tol) { found = t; break; }
         }
      }
      if(found != g_LevelTickets[i]) g_LevelTickets[i] = found;
   }
   if(allowSlowPath) lastSlowSync = TimeCurrent();
}

void MapSystemToGrid()
{
   for(int i=0; i<g_CurrentLevels; i++) {
      if(g_LevelTickets[i] > 0) continue;
      double target = GridPrices[i]; double tol = GridStepSize[i] * 0.4;
      for(int k=OrdersTotal()-1; k>=0; k--) {
         ulong tk = OrderGetTicket(k);
         if(tk && OrderSelect(tk) && OrderGetInteger(ORDER_MAGIC)==InpGridMagic)
            if(MathAbs(OrderGetDouble(ORDER_PRICE_OPEN) - target) < tol) { g_LevelTickets[i] = tk; break; }
      }
      if(g_LevelTickets[i] == 0) {
         for(int k=PositionsTotal()-1; k>=0; k--) {
            ulong tk = PositionGetTicket(k);
            if(tk && PositionSelectByTicket(tk) && PositionGetInteger(POSITION_MAGIC)==InpGridMagic)
               if(MathAbs(PositionGetDouble(POSITION_PRICE_OPEN) - target) < tol) { g_LevelTickets[i] = tk; break; }
         }
      }
   }
}

//+------------------------------------------------------------------+
//| BUCKET / DREDGE ENGINE                                            |
//+------------------------------------------------------------------+
void ScanForRealizedProfits()
{
   datetime now = TimeCurrent();
   if(now - g_LastHistoryCheck < 2) return;
   if(!HistorySelect(g_LastHistoryCheck, now)) return;
   ulong closeDealTickets[]; double closeDealProfits[]; long closeDealPosIds[];
   datetime closeDealTimes[]; double closeDealPrices[]; int count = 0;
   for(int i=0; i<HistoryDealsTotal(); i++) {
      ulong t = HistoryDealGetTicket(i); if(t==0) continue;
      datetime dealTime = (datetime)HistoryDealGetInteger(t, DEAL_TIME);
      if(dealTime < g_LastHistoryCheck) continue;
      if(HistoryDealGetInteger(t, DEAL_MAGIC) != InpGridMagic) continue;
      if(HistoryDealGetInteger(t, DEAL_ENTRY) != DEAL_ENTRY_OUT) continue;
      double profit = HistoryDealGetDouble(t, DEAL_PROFIT) + HistoryDealGetDouble(t, DEAL_SWAP) + HistoryDealGetDouble(t, DEAL_COMMISSION);
      if(profit <= 0) continue;
      ArrayResize(closeDealTickets, count+1); ArrayResize(closeDealProfits, count+1);
      ArrayResize(closeDealPosIds, count+1); ArrayResize(closeDealTimes, count+1); ArrayResize(closeDealPrices, count+1);
      closeDealTickets[count]=t; closeDealProfits[count]=profit;
      closeDealPosIds[count]=(long)HistoryDealGetInteger(t, DEAL_POSITION_ID);
      closeDealTimes[count]=dealTime; closeDealPrices[count]=HistoryDealGetDouble(t, DEAL_PRICE); count++;
   }
   for(int i=0; i<count; i++) {
      double openPrice = 0; long posId = closeDealPosIds[i];
      if(posId > 0 && HistorySelectByPosition(posId))
         for(int j=0; j<HistoryDealsTotal(); j++) {
            ulong et = HistoryDealGetTicket(j);
            if(et > 0 && HistoryDealGetInteger(et, DEAL_ENTRY)==DEAL_ENTRY_IN && HistoryDealGetInteger(et, DEAL_POSITION_ID)==posId)
               { openPrice = HistoryDealGetDouble(et, DEAL_PRICE); break; }
         }
      if(openPrice <= 0) openPrice = closeDealPrices[i];
      if(GetZone(openPrice) >= 2) AddToBucket(closeDealProfits[i], closeDealTimes[i]);
   }
   g_LastHistoryCheck = now;
}

void AddToBucket(double amount, datetime dealTime) {
   const int MAX_BUCKET_ITEMS = 1000;
   if(ArraySize(g_BucketQueue) >= MAX_BUCKET_ITEMS) CleanExpiredBucketItems();
   int s = ArraySize(g_BucketQueue);
   ArrayResize(g_BucketQueue, s+1);
   g_BucketQueue[s].amount = amount; g_BucketQueue[s].time = dealTime;
   g_BucketTotal += amount;
   SaveGridState();
}

bool SpendFromBucket(double req) {
   if(g_BucketTotal < req) return false;
   double rem = req;
   for(int i=0; i<ArraySize(g_BucketQueue) && rem>0; i++) {
      if(g_BucketQueue[i].amount >= rem) { g_BucketQueue[i].amount -= rem; rem = 0; }
      else { rem -= g_BucketQueue[i].amount; g_BucketQueue[i].amount = 0; }
   }
   RecalculateBucketTotal(); SaveGridState();
   return (rem <= 0.01);
}

void RecalculateBucketTotal() { g_BucketTotal = 0; for(int i=0; i<ArraySize(g_BucketQueue); i++) g_BucketTotal += g_BucketQueue[i].amount; }

void CleanExpiredBucketItems() {
   if(ArraySize(g_BucketQueue) == 0) return;
   datetime cutoff = TimeCurrent() - (InpBucketRetentionHrs * 3600);
   BucketItem temp[]; int count = 0;
   for(int i=0; i<ArraySize(g_BucketQueue); i++)
      if(g_BucketQueue[i].time >= cutoff && g_BucketQueue[i].amount > 0.001) {
         ArrayResize(temp, count+1); temp[count] = g_BucketQueue[i]; count++;
      }
   if(ArraySize(temp) != ArraySize(g_BucketQueue)) {
      ArrayFree(g_BucketQueue); ArrayCopy(g_BucketQueue, temp);
      RecalculateBucketTotal(); SaveGridState();
   }
}

void ManageBucketDredging()
{
   if(TimeCurrent() - g_LastDredgeTime < 5) return;
   if(g_BucketTotal <= 0.1) return;
   double currentBal = AccountInfoDouble(ACCOUNT_BALANCE);
   double availableCash = g_BucketTotal * ((currentBal > g_InitialBalance) ? 1.0 : InpSurvivalRatio);
   if(availableCash < 0.1) return;
   if(g_WorstPositions[0].ticket > 0 && g_WorstPositions[0].loss < 0) {
      double currentPrice = SymbolInfoDouble(_Symbol, SYMBOL_BID);
      double thresholdDist = g_TotalRangeDist * InpDredgeRangePct;
      if(MathAbs(g_WorstPositions[0].price - currentPrice) < thresholdDist) return;
      double lossAbs = MathAbs(g_WorstPositions[0].loss);
      if(availableCash > lossAbs && g_BucketTotal > lossAbs) {
         g_CurrentDredgeTarget = g_WorstPositions[0].ticket;
         if(tradeGrid.PositionClose(g_WorstPositions[0].ticket)) {
            if(SpendFromBucket(lossAbs)) {
               g_TotalDredged += lossAbs;
               for(int k=0; k<g_CurrentLevels; k++)
                  if(g_LevelTickets[k] == g_WorstPositions[0].ticket) { g_LevelTickets[k] = 0; break; }
               if(InpEnableTradeLog) LogTrade("DREDGED", g_WorstPositions[0].level, 0, lossAbs, g_WorstPositions[0].ticket);
               g_LastDredgeTime = TimeCurrent();
            }
         }
         g_CurrentDredgeTarget = 0;
      }
   }
}

//+------------------------------------------------------------------+
//| HEDGE ENGINE                                                      |
//+------------------------------------------------------------------+
void ExecuteHedge(int targetStage)
{
   double netVolume = CalculateNetExposure();
   if(netVolume <= 0) { Print("Net exposure zero — no hedge needed"); return; }

   double totalRatioTarget = 0.0;
   if(targetStage >= 1) totalRatioTarget += InpHedgeRatio1;
   if(targetStage >= 2) totalRatioTarget += InpHedgeRatio2;
   if(targetStage >= 3) totalRatioTarget += InpHedgeRatio3;

   double targetHedgeVol = NormalizeDouble(netVolume * totalRatioTarget, 2);
   double currentHedgeVol = GetTotalHedgeVolume();
   double volToAdd = targetHedgeVol - currentHedgeVol;
   double minVol = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   if(volToAdd < minVol) { g_HedgeStage = targetStage; SaveHedgeState(); return; }

   double currentBid = SymbolInfoDouble(_Symbol, SYMBOL_BID);

   // Spread check (PA20)
   double currentAsk = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double spreadPoints = (currentAsk - currentBid) / SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   if(InpMaxHedgeSpread > 0 && spreadPoints > InpMaxHedgeSpread) {
      Print("HEDGE DELAYED: Spread ", (int)spreadPoints, " pts > limit ", InpMaxHedgeSpread);
      return;
   }

   // Margin check
   double marginRequired = 0;
   if(!OrderCalcMargin(ORDER_TYPE_SELL, _Symbol, volToAdd, currentBid, marginRequired)) {
      SendAlert("HEDGE BLOCKED: Margin calc failed"); return;
   }
   if(AccountInfoDouble(ACCOUNT_MARGIN_FREE) < marginRequired * (InpMinFreeMarginPct / 100.0)) {
      SendAlert("HEDGE BLOCKED: Insufficient margin!"); return;
   }

   if(tradeHedge.Sell(volToAdd, _Symbol, 0, 0, 0, "Steward_Hedge_S" + IntegerToString(targetStage))) {
      if(tradeHedge.ResultRetcode()==TRADE_RETCODE_DONE || tradeHedge.ResultRetcode()==TRADE_RETCODE_PLACED) {
         g_HedgeTickets[targetStage - 1] = tradeHedge.ResultOrder();
         g_StageOpenTime[targetStage - 1] = TimeCurrent();
         if(!g_HedgeActive) { g_HedgeActive = true; g_HedgeStartTime = TimeCurrent(); }
         int oldStage = g_HedgeStage;
         g_HedgeOpenVolume = GetTotalHedgeVolume();
         g_HedgeOpenPrice = currentBid;
         g_HedgeStage = targetStage;
         SaveHedgeState();
         // Publish for Planner
         GlobalVariableSet(GetGridGVKey("HEDGE_ACTIVE"), 1.0);
         string msg = "HEDGE Stage " + IntegerToString(targetStage) + ": +" + DoubleToString(volToAdd, 2) + " lots @ " + DoubleToString(currentBid, _Digits);
         Print(msg); SendAlert(msg);
         WriteLog((oldStage==0) ? "HEDGE_OPEN" : "STAGE_UP", targetStage, currentBid, volToAdd,
            g_HedgeTickets[targetStage-1], StringFormat("oldStage=%d totalVol=%.2f", oldStage, g_HedgeOpenVolume));
      } else {
         Print("Hedge failed: RC=", tradeHedge.ResultRetcode(), " ", tradeHedge.ResultRetcodeDescription());
      }
   }
}

void ManageUnwindLogic(double currentDD)
{
   bool anyActive = false;
   for(int i=0; i<3; i++) if(g_HedgeTickets[i] > 0) anyActive = true;
   if(!anyActive || !g_HedgeActive) return;

   // Orphan cleanup
   for(int i=0; i<3; i++)
      if(g_HedgeTickets[i] > 0 && !PositionSelectByTicket(g_HedgeTickets[i])) { g_HedgeTickets[i] = 0; }

   anyActive = false;
   for(int i=0; i<3; i++) if(g_HedgeTickets[i] > 0) anyActive = true;
   if(!anyActive) {
      Print("All hedge tickets gone — resetting");
      g_HedgeActive = false; g_HedgeStage = 0; g_HedgeOpenVolume = 0.0;
      // PA22: Reset peak balance (forgive hedge-period losses)
      g_PeakBalance = AccountInfoDouble(ACCOUNT_BALANCE);
      g_DynamicHardStop = g_PeakBalance * (1.0 - InpHardStopDDPct / 100.0);
      SaveHedgeState();
      GlobalVariableSet(GetGridGVKey("HEDGE_ACTIVE"), 0.0);
      WriteLog("ORPHAN", 0, 0, 0, 0, "All hedge tickets disappeared — state reset");
      return;
   }

   // SafeUnwind logic
   double currentBid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   bool isInRange = (currentBid >= g_CurrentLower && currentBid <= g_CurrentUpper);

   if(currentBid < g_CurrentLower) {
      if(InpEnableDetailedLog && TimeCurrent() % 60 == 0)
         Print("BELOW RANGE: Holding | DD: ", DoubleToString(currentDD, 1), "% | P/L: $", DoubleToString(GetTotalHedgePL(), 2));
   }
   else if(isInRange && currentDD < g_EffSafeUnwind) {
      double pl = GetTotalHedgePL();
      // PA21 Fix 1: Profit guard
      if(pl <= 0) { Print("SAFEUNWIND HOLD: P/L=$", DoubleToString(pl, 2), " — waiting for profit"); return; }
      // PA21 Fix 2: Hold time guard
      int holdSecs = InpMinStageHoldMins * 60;
      for(int i=0; i<3; i++) {
         if(g_HedgeTickets[i] > 0 && g_StageOpenTime[i] > 0) {
            int ageSecs = (int)(TimeCurrent() - g_StageOpenTime[i]);
            if(ageSecs < holdSecs) { Print("SAFEUNWIND HOLD: Stage ", i+1, " only ", ageSecs, "s old"); return; }
         }
      }
      // Close all hedge positions
      bool allClosed = true;
      for(int i=0; i<3; i++)
         if(g_HedgeTickets[i] > 0) {
            if(tradeHedge.PositionClose(g_HedgeTickets[i])) g_HedgeTickets[i] = 0;
            else allClosed = false;
         }
      if(allClosed) {
         g_HedgeActive = false; g_HedgeStage = 0; g_HedgeOpenVolume = 0.0;
         g_HedgePeakEquity = AccountInfoDouble(ACCOUNT_EQUITY);
         // PA22: Reset peak balance
         g_PeakBalance = AccountInfoDouble(ACCOUNT_BALANCE);
         g_DynamicHardStop = g_PeakBalance * (1.0 - InpHardStopDDPct / 100.0);
         SaveHedgeState();
         GlobalVariableSet(GetGridGVKey("HEDGE_ACTIVE"), 0.0);
         WriteLog("SAFE_UNWIND", 0, currentBid, 0, 0, StringFormat("pl=%.2f dd=%.2f%%", pl, currentDD));
         Print("HEDGE UNWOUND successfully");
      }
   }
}

void ProcessCannibalism()
{
   bool anyActive = false;
   for(int i=0; i<3; i++) if(g_HedgeTickets[i] > 0) anyActive = true;
   if(!anyActive || !g_HedgeActive) return;

   double hedgeProfit = GetTotalHedgePL();
   double hedgeVol = GetTotalHedgeVolume();
   if(hedgeProfit < InpPruneThreshold) return;

   ulong worstTicket = 0; double worstLoss = 0.0;
   for(int i=PositionsTotal()-1; i>=0; i--) {
      ulong t = PositionGetTicket(i); if(t==0) continue;
      if(!PositionSelectByTicket(t)) continue;
      if(PositionGetInteger(POSITION_MAGIC) == InpGridMagic) {
         if(IsTradeBeingDredged(t)) continue;
         double p = PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP);
         if(p < worstLoss) { worstLoss = p; worstTicket = t; }
      }
   }
   if(worstTicket == 0) return;
   double budget = hedgeProfit - InpPruneBuffer;
   if(budget <= MathAbs(worstLoss)) return;

   // PA19: Close grid position FIRST
   if(!tradeGrid.PositionClose(worstTicket)) {
      Print("CANNIBALISM: Grid close failed — will retry"); return;
   }
   g_CannibalismCount++; g_TotalPruned += MathAbs(worstLoss);
   WriteLog("CANNIBALISM", 0, 0, 0, worstTicket, StringFormat("loss=%.2f total=%.2f", worstLoss, g_TotalPruned));

   // Step 2: Right-size hedge
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
      for(int i=2; i>=0; i--) {
         if(g_HedgeTickets[i] == 0 || !PositionSelectByTicket(g_HedgeTickets[i])) continue;
         double thisVol = PositionGetDouble(POSITION_VOLUME);
         if(thisVol > hedgeToClose + minVol) {
            if(tradeHedge.PositionClosePartial(g_HedgeTickets[i], hedgeToClose)) {
               WriteLog("HEDGE_REDUCE", i+1, 0, hedgeToClose, g_HedgeTickets[i], "");
               break;
            }
         }
      }
   }
   g_HedgeOpenVolume = GetTotalHedgeVolume();
   SaveHedgeState();
}

void CheckHedgeDuration()
{
   if(!g_HedgeActive || g_HedgeStartTime == 0) return;
   int durationHours = (int)((TimeCurrent() - g_HedgeStartTime) / 3600);
   if(durationHours >= InpMaxHedgeDurationHrs) {
      double pl = GetTotalHedgePL();
      Print("DURATION LIMIT: ", durationHours, "hrs | P/L: $", DoubleToString(pl, 2));
      bool allClosed = true;
      for(int i=0; i<3; i++)
         if(g_HedgeTickets[i] > 0) {
            if(tradeHedge.PositionClose(g_HedgeTickets[i])) g_HedgeTickets[i] = 0;
            else allClosed = false;
         }
      if(allClosed) {
         g_HedgeActive = false; g_HedgeStage = 0; g_HedgeOpenVolume = 0.0;
         g_HedgePeakEquity = AccountInfoDouble(ACCOUNT_EQUITY);
         g_PeakBalance = AccountInfoDouble(ACCOUNT_BALANCE);
         g_DynamicHardStop = g_PeakBalance * (1.0 - InpHardStopDDPct / 100.0);
         SaveHedgeState();
         GlobalVariableSet(GetGridGVKey("HEDGE_ACTIVE"), 0.0);
         Alert("HEDGE CLOSED: Time limit (", durationHours, "hrs)");
      }
   }
}

bool VerifyHedgeHealthy()
{
   bool anyHealthy = false;
   for(int i=0; i<3; i++) {
      if(g_HedgeTickets[i] == 0) continue;
      if(!PositionSelectByTicket(g_HedgeTickets[i])) { g_HedgeTickets[i] = 0; continue; }
      if(PositionGetInteger(POSITION_TYPE) != POSITION_TYPE_SELL) continue;
      if(PositionGetInteger(POSITION_MAGIC) != InpHedgeMagic) continue;
      anyHealthy = true;
   }
   return anyHealthy;
}

bool VerifyHedgeExists()
{
   for(int i=0; i<3; i++) {
      if(g_HedgeTickets[i] == 0) continue;
      for(int k=PositionsTotal()-1; k>=0; k--) {
         ulong t = PositionGetTicket(k);
         if(t == g_HedgeTickets[i] && PositionSelectByTicket(t) && PositionGetInteger(POSITION_MAGIC)==InpHedgeMagic)
            return true;
      }
      g_HedgeTickets[i] = 0;
   }
   return false;
}

void VerifyExposureBalance()
{
   if(!g_HedgeActive) return;
   double gridNet = CalculateGridNetExposure();
   double hedgeVol = GetTotalHedgeVolume();
   double activeRatio = 0.0;
   if(g_HedgeStage >= 1) activeRatio += InpHedgeRatio1;
   if(g_HedgeStage >= 2) activeRatio += InpHedgeRatio2;
   if(g_HedgeStage >= 3) activeRatio += InpHedgeRatio3;
   double expectedLeak = gridNet * (1.0 - activeRatio);
   double netExposure = gridNet - hedgeVol;
   if(MathAbs(netExposure - expectedLeak) > 0.10)
      Print("EXPOSURE IMBALANCE: Grid=", DoubleToString(gridNet, 2), " Hedge=", DoubleToString(hedgeVol, 2));
}

//+------------------------------------------------------------------+
//| HARD STOP + CLOSE FUNCTIONS                                       |
//+------------------------------------------------------------------+
void CloseAllGridPositions()
{
   for(int attempt=0; attempt<3; attempt++) {
      bool allClosed = true;
      for(int i=PositionsTotal()-1; i>=0; i--) {
         ulong t = PositionGetTicket(i);
         if(PositionSelectByTicket(t) && PositionGetInteger(POSITION_MAGIC)==InpGridMagic)
            if(!tradeGrid.PositionClose(t)) allClosed = false;
      }
      if(allClosed) break;
      if(attempt < 2) Sleep(200);
   }
   DeleteAllOrders();
}

void CloseAllPositionsNuclear()
{
   for(int attempt=0; attempt<3; attempt++) {
      bool allClosed = true;
      for(int i=PositionsTotal()-1; i>=0; i--) {
         ulong t = PositionGetTicket(i);
         if(!PositionSelectByTicket(t)) continue;
         long magic = PositionGetInteger(POSITION_MAGIC);
         if(magic == InpGridMagic) { if(!tradeGrid.PositionClose(t)) allClosed = false; }
         else if(magic == InpHedgeMagic) { if(!tradeHedge.PositionClose(t)) allClosed = false; }
      }
      if(allClosed) break;
      if(attempt < 2) Sleep(200);
   }
   DeleteAllOrders();
}

void DeleteAllOrders()
{
   for(int i=OrdersTotal()-1; i>=0; i--) {
      ulong t = OrderGetTicket(i);
      if(OrderSelect(t) && OrderGetInteger(ORDER_MAGIC)==InpGridMagic) tradeGrid.OrderDelete(t);
   }
   ArrayInitialize(g_LevelTickets, 0);
}

//+------------------------------------------------------------------+
//| PLANNER INTERFACE                                                  |
//+------------------------------------------------------------------+
void PublishCoordinationData()
{
   if(TimeCurrent() - g_LastExposurePublish < 10) return;
   g_NetExposure = CalculateNetExposure();
   GlobalVariableSet(GetGridGVKey("NET_EXPOSURE"), g_NetExposure);
   GlobalVariableSet(GetGridGVKey("BOT_ACTIVE"), IsTradingActive ? 1.0 : 0.0);
   GlobalVariableSet(GetGridGVKey("HEDGE_ACTIVE"), g_HedgeActive ? 1.0 : 0.0);
   g_LastExposurePublish = TimeCurrent();
}

void CheckForOptimizationUpdates()
{
   if(!InpAllowRemoteOpt) return;
   if(TimeCurrent() - g_LastOptCheck < 10) return;
   string cmdKey = GetGridGVKey("OPT_CMD_PushTime");
   if(GlobalVariableCheck(cmdKey)) {
      datetime pushTime = (datetime)GlobalVariableGet(cmdKey);
      double lastApplied = GlobalVariableCheck(GetGridGVKey("OPT_LAST_APPLIED"))
                           ? GlobalVariableGet(GetGridGVKey("OPT_LAST_APPLIED")) : 0;
      if((double)pushTime > lastApplied) {
         if(!GlobalVariableCheck(GetGridGVKey("OPT_NEW_UPPER"))) { g_LastOptCheck = TimeCurrent(); return; }
         double newUpper = GlobalVariableGet(GetGridGVKey("OPT_NEW_UPPER"));
         double newLower = GlobalVariableCheck(GetGridGVKey("OPT_NEW_LOWER")) ? GlobalVariableGet(GetGridGVKey("OPT_NEW_LOWER")) : 0;
         double newLevels = GlobalVariableCheck(GetGridGVKey("OPT_NEW_LEVELS")) ? GlobalVariableGet(GetGridGVKey("OPT_NEW_LEVELS")) : 0;
         double newCoeff = GlobalVariableCheck(GetGridGVKey("OPT_NEW_COEFF")) ? GlobalVariableGet(GetGridGVKey("OPT_NEW_COEFF")) : InpExpansionCoeff;
         if(GlobalVariableCheck(GetGridGVKey("OPT_NEW_LOT1"))) {
            double l1 = GlobalVariableGet(GetGridGVKey("OPT_NEW_LOT1"));
            double l2 = GlobalVariableCheck(GetGridGVKey("OPT_NEW_LOT2")) ? GlobalVariableGet(GetGridGVKey("OPT_NEW_LOT2")) : 0;
            double l3 = GlobalVariableCheck(GetGridGVKey("OPT_NEW_LOT3")) ? GlobalVariableGet(GetGridGVKey("OPT_NEW_LOT3")) : 0;
            if(l1 >= MIN_LOT && l1 <= MAX_LOT) g_RuntimeLot1 = l1;
            if(l2 >= MIN_LOT && l2 <= MAX_LOT) g_RuntimeLot2 = l2;
            if(l3 >= MIN_LOT && l3 <= MAX_LOT) g_RuntimeLot3 = l3;
         }
         if(GlobalVariableCheck(GetGridGVKey("OPT_NEW_MAX_SPREAD"))) {
            double ns = GlobalVariableGet(GetGridGVKey("OPT_NEW_MAX_SPREAD"));
            if(ns >= 50) g_RuntimeMaxSpread = (int)ns;
         }
         if(newUpper > newLower && newLevels > 5) {
            IsTradingActive = false; DeleteAllOrders();
            g_CurrentUpper = newUpper; g_CurrentLower = newLower;
            g_CurrentLevels = (int)newLevels; g_ActiveExpansionCoeff = newCoeff;
            g_TotalRangeDist = g_CurrentUpper - g_CurrentLower;
            g_OriginalZone1_Floor = g_CurrentUpper - (g_TotalRangeDist / 3.0);
            g_OriginalZone2_Floor = g_CurrentUpper - ((g_TotalRangeDist / 3.0) * 2.0);
            SaveGridState(); RebuildGrid(false); DrawGhostLines();
            GlobalVariableSet(GetGridGVKey("OPT_LAST_APPLIED"), (double)pushTime);
            if(g_UsingAutoDefaults) { g_UsingAutoDefaults = false; Print("AUTO-RANGE deactivated — using Planner config"); }
            IsTradingActive = true;
            SendAlert("OPTIMIZATION APPLIED: " + DoubleToString(newUpper, _Digits) + " - " + DoubleToString(newLower, _Digits));
            WriteLog("PUSH_APPLIED", 0, 0, 0, 0,
               StringFormat("upper=%.2f lower=%.2f levels=%d coeff=%.4f lot1=%.2f lot2=%.2f lot3=%.2f spread=%d",
               g_CurrentUpper, g_CurrentLower, g_CurrentLevels, g_ActiveExpansionCoeff,
               g_RuntimeLot1, g_RuntimeLot2, g_RuntimeLot3, g_RuntimeMaxSpread));
         }
      }
   }
   g_LastOptCheck = TimeCurrent();
}

//+------------------------------------------------------------------+
//| DASHBOARD (Unified HUD)                                           |
//+------------------------------------------------------------------+
#define DASH_PREFIX  "GBS_"
#define DASH_FONT    "Consolas"
#define DASH_FSIZE   9
#define DASH_X       10
#define DASH_Y       25
#define DASH_LINE_H  16
#define DASH_PAD     8
#define DASH_WIDTH   420

void DashLabel(int row, string name, string txt, color clr = clrWhite) {
   string objName = DASH_PREFIX + name;
   if(ObjectFind(0, objName) < 0) {
      ObjectCreate(0, objName, OBJ_LABEL, 0, 0, 0);
      ObjectSetInteger(0, objName, OBJPROP_CORNER, InpDashCorner);
      ObjectSetString(0, objName, OBJPROP_FONT, DASH_FONT);
      ObjectSetInteger(0, objName, OBJPROP_FONTSIZE, DASH_FSIZE);
      ObjectSetInteger(0, objName, OBJPROP_SELECTABLE, false);
      ObjectSetInteger(0, objName, OBJPROP_HIDDEN, true);
      ObjectSetInteger(0, objName, OBJPROP_BACK, false);
      ObjectSetInteger(0, objName, OBJPROP_ZORDER, 10);
   }
   ObjectSetString(0, objName, OBJPROP_TEXT, txt);
   ObjectSetInteger(0, objName, OBJPROP_COLOR, clr);
   ObjectSetInteger(0, objName, OBJPROP_XDISTANCE, DASH_X + DASH_PAD);
   ObjectSetInteger(0, objName, OBJPROP_YDISTANCE, DASH_Y + DASH_PAD + row * DASH_LINE_H);
}

void DashBackground(int totalRows) {
   string objName = DASH_PREFIX + "BG";
   if(ObjectFind(0, objName) < 0) {
      ObjectCreate(0, objName, OBJ_RECTANGLE_LABEL, 0, 0, 0);
      ObjectSetInteger(0, objName, OBJPROP_CORNER, InpDashCorner);
      ObjectSetInteger(0, objName, OBJPROP_SELECTABLE, false);
      ObjectSetInteger(0, objName, OBJPROP_HIDDEN, true);
      ObjectSetInteger(0, objName, OBJPROP_BORDER_TYPE, BORDER_FLAT);
      ObjectSetInteger(0, objName, OBJPROP_ZORDER, 0);
      ObjectSetInteger(0, objName, OBJPROP_BACK, true);
   }
   ObjectSetInteger(0, objName, OBJPROP_XDISTANCE, DASH_X);
   ObjectSetInteger(0, objName, OBJPROP_YDISTANCE, DASH_Y);
   ObjectSetInteger(0, objName, OBJPROP_XSIZE, DASH_WIDTH);
   ObjectSetInteger(0, objName, OBJPROP_YSIZE, DASH_PAD*2 + totalRows*DASH_LINE_H + 4);
   ObjectSetInteger(0, objName, OBJPROP_BGCOLOR, C'20,20,30');
   ObjectSetInteger(0, objName, OBJPROP_BORDER_COLOR, C'60,60,80');
}

void DashCleanup() {
   int total = ObjectsTotal(0, 0, -1);
   for(int i=total-1; i>=0; i--) { string name = ObjectName(0, i); if(StringFind(name, DASH_PREFIX)==0) ObjectDelete(0, name); }
   Comment("");
}

void CalculateDashboardStats()
{
   g_Z1.count=0; g_Z1.profit=0; g_Z1.volume=0; g_Z1.avgPrice=0;
   g_Z2.count=0; g_Z2.profit=0; g_Z2.volume=0; g_Z2.avgPrice=0;
   g_Z3.count=0; g_Z3.profit=0; g_Z3.volume=0; g_Z3.avgPrice=0;
   for(int i=0; i<3; i++) { g_WorstPositions[i].ticket=0; g_WorstPositions[i].level=0; g_WorstPositions[i].loss=0; g_WorstPositions[i].price=0; g_WorstPositions[i].distPct=0; }
   g_BreakEvenPrice=0; g_DeepestLevel=0; g_DeepestPrice=0; g_HighestLevel=0; g_HighestPrice=0; g_NextLevelPrice=0;
   double totalVol=0, totalVolPrice=0, currentPrice = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   WorstPosition tempWorst[200]; int worstCount=0;
   for(int i=PositionsTotal()-1; i>=0; i--) {
      ulong t = PositionGetTicket(i); if(!PositionSelectByTicket(t)) continue;
      if(PositionGetInteger(POSITION_MAGIC) != InpGridMagic) continue;
      double prof = PositionGetDouble(POSITION_PROFIT)+PositionGetDouble(POSITION_SWAP);
      double vol = PositionGetDouble(POSITION_VOLUME); double open = PositionGetDouble(POSITION_PRICE_OPEN);
      int lvl = GetLevelIndex(open)+1;
      totalVol += vol; totalVolPrice += (vol*open);
      if(lvl > g_DeepestLevel) { g_DeepestLevel=lvl; g_DeepestPrice=open; }
      if(g_HighestLevel==0 || lvl < g_HighestLevel) { g_HighestLevel=lvl; g_HighestPrice=open; }
      if(prof < 0 && worstCount < 200) { tempWorst[worstCount].ticket=t; tempWorst[worstCount].level=lvl; tempWorst[worstCount].loss=prof; tempWorst[worstCount].price=open; tempWorst[worstCount].distPct=MathAbs((open-currentPrice)/currentPrice)*100; worstCount++; }
      int z = GetZone(open);
      if(z==1) { g_Z1.count++; g_Z1.profit+=prof; g_Z1.volume+=vol; g_Z1.avgPrice+=(vol*open); }
      if(z==2) { g_Z2.count++; g_Z2.profit+=prof; g_Z2.volume+=vol; g_Z2.avgPrice+=(vol*open); }
      if(z==3) { g_Z3.count++; g_Z3.profit+=prof; g_Z3.volume+=vol; g_Z3.avgPrice+=(vol*open); }
   }
   for(int i=0; i<worstCount-1; i++) for(int j=i+1; j<worstCount; j++) if(tempWorst[j].loss < tempWorst[i].loss) { WorstPosition tmp=tempWorst[i]; tempWorst[i]=tempWorst[j]; tempWorst[j]=tmp; }
   for(int i=0; i<3 && i<worstCount; i++) g_WorstPositions[i] = tempWorst[i];
   if(totalVol>0) g_BreakEvenPrice=totalVolPrice/totalVol;
   if(g_Z1.volume>0) g_Z1.avgPrice/=g_Z1.volume; if(g_Z2.volume>0) g_Z2.avgPrice/=g_Z2.volume; if(g_Z3.volume>0) g_Z3.avgPrice/=g_Z3.volume;
   for(int i=0; i<g_CurrentLevels; i++) if(GridPrices[i] < currentPrice && g_LevelTickets[i]==0) { g_NextLevelPrice=GridPrices[i]; break; }
   // Trade history stats
   datetime startOfDay = iTime(_Symbol, PERIOD_D1, 0); datetime startOfWeek = iTime(_Symbol, PERIOD_W1, 0);
   if(TimeCurrent() - g_LastHistoryScan > 60) {
      g_DayPL=0; g_WeekPL=0; g_TradesToday=0; g_WinsToday=0; double totalWins=0, totalLosses=0; int lossCount=0;
      HistorySelect(startOfWeek, TimeCurrent());
      for(int i=0; i<HistoryDealsTotal(); i++) {
         ulong ticket = HistoryDealGetTicket(i);
         if(HistoryDealGetInteger(ticket, DEAL_MAGIC) != InpGridMagic) continue;
         if(HistoryDealGetInteger(ticket, DEAL_ENTRY) != DEAL_ENTRY_OUT) continue;
         double res = HistoryDealGetDouble(ticket, DEAL_PROFIT)+HistoryDealGetDouble(ticket, DEAL_SWAP)+HistoryDealGetDouble(ticket, DEAL_COMMISSION);
         datetime dt = (datetime)HistoryDealGetInteger(ticket, DEAL_TIME);
         if(dt >= startOfWeek) g_WeekPL += res;
         if(dt >= startOfDay) { g_DayPL+=res; g_TradesToday++; if(res>0) { g_WinsToday++; totalWins+=res; } else { totalLosses+=res; lossCount++; } }
      }
      g_AvgWin = (g_WinsToday>0) ? totalWins/g_WinsToday : 0;
      g_AvgLoss = (lossCount>0) ? totalLosses/lossCount : 0;
      g_LastHistoryScan = TimeCurrent();
   }
   double bal = AccountInfoDouble(ACCOUNT_BALANCE); double eq = AccountInfoDouble(ACCOUNT_EQUITY);
   g_MaxDDPercent = (bal>0) ? ((bal-eq)/bal)*100 : 0;
   double bucketTimeHrs = (double)(TimeCurrent()-g_BucketStartTime)/3600.0;
   g_BucketFillRate = (bucketTimeHrs>0) ? g_BucketTotal/bucketTimeHrs : 0;
}

void UpdateDashboard()
{
   if(!InpShowDashboard) return;
   static datetime lastUpdate = 0;
   if(TimeCurrent() - lastUpdate < 5) return;

   string status = IsTradingActive ? "RUNNING" : "STOPPED";
   color statusClr = clrLime;
   if(g_HedgeActive) { status = "FROZEN (Hedge S" + IntegerToString(g_HedgeStage) + "/3)"; statusClr = clrRed; }
   else if(!IsTradingActive) statusClr = clrRed;

   double bal=AccountInfoDouble(ACCOUNT_BALANCE), eq=AccountInfoDouble(ACCOUNT_EQUITY);
   double curPrice=SymbolInfoDouble(_Symbol, SYMBOL_BID);
   bool inRange = (curPrice >= g_CurrentLower && curPrice <= g_CurrentUpper);
   double dayPct=(bal>0)?(g_DayPL/bal)*100:0, weekPct=(bal>0)?(g_WeekPL/bal)*100:0;
   double winRate = (g_TradesToday>0)?((double)g_WinsToday/g_TradesToday)*100:0;

   int r = 0;
   DashLabel(r, "HDR", "  GRIDBOT-STEWARD v1.0", clrDodgerBlue); r++;
   datetime brokerTime=TimeCurrent(), vpsTime=TimeLocal(), pktTime=TimeGMT()+5*3600;
   DashLabel(r, "TME", "  Broker: "+TimeToString(brokerTime,TIME_MINUTES)+"  |  VPS: "+TimeToString(vpsTime,TIME_MINUTES)+"  |  PKT: "+TimeToString(pktTime,TIME_MINUTES), clrGray); r++;
   DashLabel(r, "STS", "  Status: " + status, statusClr); r++;
   if(g_UsingAutoDefaults) { DashLabel(r, "AUTO", "  AUTO-RANGE — USE PLANNER TO OPTIMIZE!", clrOrange); r++; }
   DashLabel(r, "S1", "  ___________________________________________", C'60,60,80'); r++;
   DashLabel(r, "BAL", "  Balance: $"+DoubleToString(bal,0)+"  |  Equity: $"+DoubleToString(eq,0), clrWhite); r++;
   DashLabel(r, "DD", "  DD: "+DoubleToString(g_MaxDDPercent,2)+"%  |  Positions: "+IntegerToString(PositionsTotal()), clrSilver); r++;
   int effSpread = (g_RuntimeMaxSpread>0)?g_RuntimeMaxSpread:InpMaxSpread;
   long curSpread = SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);
   DashLabel(r, "SPR", "  Spread: "+IntegerToString(curSpread)+"  |  Max: "+IntegerToString(effSpread)+" pts", (curSpread>effSpread)?clrRed:clrGray); r++;
   DashLabel(r, "S2", "  ___________________________________________", C'60,60,80'); r++;
   DashLabel(r, "GRD", "  Grid: $"+DoubleToString(g_CurrentLower,2)+" - $"+DoubleToString(g_CurrentUpper,2)+"  |  Coeff: "+DoubleToString(g_ActiveExpansionCoeff,4), clrSilver); r++;
   DashLabel(r, "PRC", "  Price: $"+DoubleToString(curPrice,2)+"  |  "+(inRange?"In Range":"OUT OF RANGE!"), inRange?clrWhite:clrRed); r++;
   DashLabel(r, "BEV", "  Break Even: $"+DoubleToString(g_BreakEvenPrice,2), clrSilver); r++;
   DashLabel(r, "S3", "  ___________________________________________", C'60,60,80'); r++;
   DashLabel(r, "BKT", "  Bucket: $"+DoubleToString(g_BucketTotal,2)+"  |  Dredged: $"+DoubleToString(g_TotalDredged,2), clrAqua); r++;
   DashLabel(r, "EXP", "  Net Exposure: "+DoubleToString(g_NetExposure,2)+" lots", clrSilver); r++;
   DashLabel(r, "S4", "  ___________________________________________", C'60,60,80'); r++;
   DashLabel(r, "DPL", "  Today: $"+DoubleToString(g_DayPL,2)+" ("+DoubleToString(dayPct,2)+"%)", g_DayPL>=0?clrLime:clrOrangeRed); r++;
   DashLabel(r, "WPL", "  Week:  $"+DoubleToString(g_WeekPL,2)+" ("+DoubleToString(weekPct,2)+"%)", g_WeekPL>=0?clrLime:clrOrangeRed); r++;
   DashLabel(r, "WIN", "  Win Rate: "+IntegerToString(g_WinsToday)+"/"+IntegerToString(g_TradesToday)+" ("+DoubleToString(winRate,0)+"%)", clrSilver); r++;
   DashLabel(r, "S5", "  ___________________________________________", C'60,60,80'); r++;
   DashLabel(r, "Z1", "  Zone 1: "+IntegerToString(g_Z1.count)+" pos  |  $"+DoubleToString(g_Z1.profit,2), clrDodgerBlue); r++;
   DashLabel(r, "Z2", "  Zone 2: "+IntegerToString(g_Z2.count)+" pos  |  $"+DoubleToString(g_Z2.profit,2), clrOrange); r++;
   DashLabel(r, "Z3", "  Zone 3: "+IntegerToString(g_Z3.count)+" pos  |  $"+DoubleToString(g_Z3.profit,2), clrOrangeRed); r++;
   DashLabel(r, "S6", "  ___________________________________________", C'60,60,80'); r++;
   DashLabel(r, "WH", "  Worst Positions:", clrGray); r++;
   for(int i=0; i<3; i++) {
      string wKey="W"+IntegerToString(i);
      if(g_WorstPositions[i].ticket>0)
         DashLabel(r, wKey, "   "+IntegerToString(i+1)+". L"+IntegerToString(g_WorstPositions[i].level)+": -$"+DoubleToString(MathAbs(g_WorstPositions[i].loss),2)+" @ $"+DoubleToString(g_WorstPositions[i].price,2), clrOrangeRed);
      else DashLabel(r, wKey, "   "+IntegerToString(i+1)+". ---", C'60,60,80');
      r++;
   }
   DashLabel(r, "S7", "  ___________________________________________", C'60,60,80'); r++;
   // Hedge section
   DashLabel(r, "HH", "  -- HEDGE DEFENSE --", C'100,100,140'); r++;
   if(g_HedgeActive) {
      DashLabel(r, "HST", "  ACTIVE (Stage "+IntegerToString(g_HedgeStage)+"/3)", clrRed); r++;
      DashLabel(r, "HVL", "  Volume: "+DoubleToString(GetTotalHedgeVolume(),2)+" lots", clrWhite); r++;
      double hpl = GetTotalHedgePL();
      DashLabel(r, "HPL", "  P/L: $"+DoubleToString(hpl,2), hpl>=0?clrLime:clrOrangeRed); r++;
      string nextStr = "  Next: ";
      if(g_HedgeStage<2) nextStr+=DoubleToString(g_EffTrigger2,1)+"% (S2)";
      else if(g_HedgeStage<3) nextStr+=DoubleToString(g_EffTrigger3,1)+"% (S3)";
      else nextStr+="ALL DEPLOYED";
      DashLabel(r, "NXT", nextStr, clrSilver); r++;
   } else {
      DashLabel(r, "HST", "  STANDBY (Monitoring)", clrLime); r++;
      DashLabel(r, "HVL", "  Next: "+DoubleToString(g_EffTrigger1,1)+"% DD", clrSilver); r++;
      DashLabel(r, "HPL", "", C'20,20,30'); r++;
      DashLabel(r, "NXT", "", C'20,20,30'); r++;
   }
   DashLabel(r, "CAN", "  Cannibalized: $"+DoubleToString(g_TotalPruned,2), g_TotalPruned>0?clrAqua:clrSilver); r++;
   DashLabel(r, "S8", "  ___________________________________________", C'60,60,80'); r++;
   // Hard stops
   DashLabel(r, "HS1", "  Grid Stop: Peak $"+DoubleToString(g_PeakBalance,0)+" -> Floor $"+DoubleToString(g_DynamicHardStop,0)+" ("+DoubleToString(InpHardStopDDPct,0)+"%)", clrSilver); r++;
   double hedgeDD = (g_HedgePeakEquity>0) ? (g_HedgePeakEquity-AccountInfoDouble(ACCOUNT_EQUITY))/g_HedgePeakEquity*100 : 0;
   color hsClr = (hedgeDD >= g_EffTrigger1) ? clrYellow : clrSilver;
   DashLabel(r, "HS2", "  Ultimate: "+DoubleToString(g_EffHardStop,1)+"% DD  |  Current: "+DoubleToString(hedgeDD,2)+"%", hsClr); r++;
   DashLabel(r, "S9", "  ___________________________________________", C'60,60,80'); r++;
   // Planner
   string pushKey = GetGridGVKey("OPT_CMD_PushTime");
   if(GlobalVariableCheck(pushKey)) {
      int pushAge = (int)(TimeCurrent() - (datetime)GlobalVariableGet(pushKey));
      DashLabel(r, "PL_PS", "  Last Push: "+FormatAge(pushAge), clrSilver);
   } else DashLabel(r, "PL_PS", "  Last Push: Never", C'80,80,80');
   r++;

   DashBackground(r);
   lastUpdate = TimeCurrent();
}

//+------------------------------------------------------------------+
//| CHART OBJECTS                                                      |
//+------------------------------------------------------------------+
void DrawBreakEvenLine() {
   static double lastBEPrice = 0.0;
   if(MathAbs(g_BreakEvenPrice - lastBEPrice) < POINT) return;
   lastBEPrice = g_BreakEvenPrice;
   ObjectDelete(0, "SG_BreakEven");
   if(g_BreakEvenPrice > 0) {
      ObjectCreate(0, "SG_BreakEven", OBJ_HLINE, 0, 0, g_BreakEvenPrice);
      ObjectSetInteger(0, "SG_BreakEven", OBJPROP_COLOR, clrYellow);
      ObjectSetInteger(0, "SG_BreakEven", OBJPROP_WIDTH, 2);
      ObjectSetString(0, "SG_BreakEven", OBJPROP_TEXT, "AVG ENTRY (BE)");
      ObjectSetInteger(0, "SG_BreakEven", OBJPROP_SELECTABLE, false);
   }
}

void DrawGhostLines() {
   for(int i=0; i<g_CurrentLevels; i++) {
      string name = "GhostLine_"+IntegerToString(i);
      if(ObjectFind(0, name) < 0) {
         ObjectCreate(0, name, OBJ_HLINE, 0, 0, GridPrices[i]);
         int z = GetZone(GridPrices[i]);
         ObjectSetInteger(0, name, OBJPROP_COLOR, (z==1)?InpColorZone1:(z==2)?InpColorZone2:InpColorZone3);
         ObjectSetInteger(0, name, OBJPROP_STYLE, STYLE_DOT);
         ObjectSetInteger(0, name, OBJPROP_WIDTH, 1);
         ObjectSetInteger(0, name, OBJPROP_BACK, true);
         ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
      } else ObjectSetDouble(0, name, OBJPROP_PRICE, GridPrices[i]);
   }
}

//+------------------------------------------------------------------+
//| LOGGING                                                            |
//+------------------------------------------------------------------+
void LogTrade(string action, int level, double price, double lot, ulong ticket) {
   if(InpEnableTradeLog) {
      string log = TimeToString(TimeCurrent(), TIME_DATE|TIME_SECONDS) + " | " + action;
      if(level > 0) log += " | L" + IntegerToString(level);
      if(price > 0) log += " | $" + DoubleToString(price, DIGITS);
      if(lot > 0)   log += " | " + DoubleToString(lot, 2) + " lots";
      if(ticket > 0) log += " | #" + IntegerToString(ticket);
      Print(log);
   }
   WriteLog(action, level, price, lot, ticket);
}

void WriteLog(string event, int level=0, double price=0, double lot=0, ulong ticket=0, string notes="")
{
   if(!InpEnableFileLog) return;
   MqlDateTime dt; TimeToStruct(TimeCurrent(), dt);
   string dateStr = StringFormat("%04d-%02d-%02d", dt.year, dt.mon, dt.day);
   string fn = "GridBot_" + _Symbol + "_" + dateStr + ".csv";
   int h = FileOpen(fn, FILE_WRITE|FILE_READ|FILE_TXT|FILE_ANSI|FILE_SHARE_READ|FILE_SHARE_WRITE);
   if(h == INVALID_HANDLE) return;
   if(FileSize(h) == 0)
      FileWrite(h, "Timestamp,Bot,Event,Symbol,Level,Price,Lot,Ticket,Equity,Balance,Peak,DD_Pct,Notes");
   FileSeek(h, 0, SEEK_END);
   double equity=AccountInfoDouble(ACCOUNT_EQUITY), balance=AccountInfoDouble(ACCOUNT_BALANCE);
   double dd = (g_HedgePeakEquity>0) ? (g_HedgePeakEquity-equity)/g_HedgePeakEquity*100 : 0;
   StringReplace(notes, ",", ";");
   string row = StringFormat("%s,STEWARD,%s,%s,%d,%.5f,%.2f,%I64u,%.2f,%.2f,%.2f,%.2f,%s",
      TimeToString(TimeCurrent(), TIME_DATE|TIME_SECONDS),
      event, _Symbol, level, price, lot, ticket,
      equity, balance, g_PeakBalance, dd, notes);
   FileWrite(h, row);
   FileClose(h);
}
//+------------------------------------------------------------------+
