//+------------------------------------------------------------------+
//|                  GridBot-Executor_v10_Integrated.mq5             |
//|         INTEGRATED EDITION: Full Guardian Coordination           |
//|         HARDENED: Downward Extensions REMOVED                    |
//|         Features: State Persistence, Coordination Protocol       |
//+------------------------------------------------------------------+
#property copyright "Custom Strategy Team - Integrated Edition"
#property link      "https://www.exness.com"
#property version   "10.11"

#include <Trade\Trade.mqh>

//==================================================================
// INPUTS
//==================================================================
input group "=== 0. System Control ==="
input bool     InpResetState     = false;    // >> RESET SAVED DATA? (Use True to start fresh)
input int      InpMagicNumber    = 205001;   // Magic Number (Unique ID)
input string   InpComment        = "SmartGrid_v10";

input group "=== 1. Grid Settings (Gold/XAUUSD) ==="
input double   InpUpperPrice     = 2750.0;   // Initial Top (Ignored if Resuming)
input double   InpLowerPrice     = 2650.0;   // Initial Bottom (Ignored if Resuming)
input int      InpGridLevels     = 45;
input double   InpExpansionCoeff = 1.0;
input bool     InpStartAtUpper   = false;

input group "=== 2. Dynamic Grid Engine (Upward Shift Only) ==="
input bool     InpEnableDynamicGrid = true;
input double   InpUpShiftTriggerPct = 0.10;
input double   InpUpShiftAmountPct  = 20.0;

input group "=== 3. Rolling Tail & Execution ==="
input int      InpMaxPendingOrders = 20;

input group "=== 4. Stepped Volume Zones ==="
input double   InpLotZone1       = 0.01;
input double   InpLotZone2       = 0.02;
input double   InpLotZone3       = 0.05;

input group "=== 5. Cash Flow Engine (The Bucket) ==="
input bool     InpUseBucketDredge= true;
input int      InpBucketRetentionHrs = 48;
input double   InpSurvivalRatio  = 0.5;
input double   InpDredgeRangePct = 0.5;
input bool     InpUseVirtualTP   = true;

input group "=== 6. Risk & Safety ==="
input double   InpHardStopDDPct      = 25.0;  // Hard Stop Drawdown % (auto-calculated from peak balance)
input int      InpMaxOpenPos     = 100;
input int      InpMaxSpread      = 2000;     // Points

input group "=== 7. Dashboard Settings ==="
input bool              InpShowDashboard  = true;
input bool              InpShowGhostLines = true;
input bool              InpShowBreakEven  = true;
input ENUM_BASE_CORNER  InpDashCorner     = CORNER_LEFT_UPPER; // Dashboard corner (LEFT_UPPER / RIGHT_UPPER / LEFT_LOWER / RIGHT_LOWER)
input color    InpColorZone1     = clrDodgerBlue;
input color    InpColorZone2     = clrOrange;
input color    InpColorZone3     = clrRed;

input group "=== 8. Advanced Features ==="
input bool     InpEnableTradeLog = true;
input bool     InpEnableFileLog  = true;   // Write events to daily CSV log file

input group "=== 9. Guardian Integration & Notifications ==="
input bool     InpEnableGuardianCoordination = true; // Coordinate with Guardian Hedge Bot
input int      InpCoordinationCheckInterval = 1;     // Seconds between coordination checks (PA26: 5→1)
input long     InpGuardianMagic       = 999999;      // Guardian bot magic (for master dashboard)
input bool     InpEnablePushNotify    = true;        // Send Mobile Push Notifications
input bool     InpEnableEmailNotify   = false;       // Send Email Notifications
input bool     InpAllowRemoteOpt      = true;        // Allow Planner to update grid range remotely

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
CTrade         trade;
BucketItem     g_BucketQueue[];

double         GridPrices[];
double         GridTPs[];
double         GridLots[];
double         GridStepSize[];
ulong          g_LevelTickets[];
bool           g_LevelLock[];

// -- PERSISTENT VARIABLES (Managed via GlobalVariables) --
double         g_CurrentUpper;
double         g_CurrentLower;
int            g_CurrentLevels;
double         g_BucketTotal = 0.0;
double         g_NetExposure = 0.0;
double         g_ActiveExpansionCoeff = 1.0;
 
// --------------------------------------------------------

// Runtime lot overrides — set from InpLotZone defaults, updatable via PUSH TO LIVE
double         g_RuntimeLot1 = 0.0;
double         g_RuntimeLot2 = 0.0;
double         g_RuntimeLot3 = 0.0;
int            g_RuntimeMaxSpread = 0;  // 0 = use InpMaxSpread fallback

double         g_OriginalZone1_Floor;
double         g_OriginalZone2_Floor;

int            DIGITS;
double         POINT;
double         STEP_LOT, MIN_LOT, MAX_LOT;
double         g_TotalRangeDist = 0.0;
double         g_BreakEvenPrice = 0.0;

bool           IsTradingActive = true;
bool           IsGuardianActive = false;
bool           g_UsingAutoDefaults = false;  // Tier 3: tracks if using instrument-aware auto-defaults
double         g_InitialBalance = 0.0;
double         g_PeakEquity = 0.0;          // Highest balance seen — hard stop floor rises with realized profits only
double         g_DynamicHardStop = 0.0;     // Calculated: g_PeakEquity * (1 - InpHardStopDDPct/100)
double         g_TotalDredged = 0.0;

double         g_DayPL = 0.0;
double         g_WeekPL = 0.0;
int            g_TradesToday = 0;
int            g_WinsToday = 0;
double         g_AvgWin = 0.0;
double         g_AvgLoss = 0.0;
ZoneStats      g_Z1, g_Z2, g_Z3;
double         g_MaxDDPercent = 0.0;

int            g_DeepestLevel = 0;
double         g_DeepestPrice = 0.0;
int            g_HighestLevel = 0;
double         g_HighestPrice = 0.0;
double         g_NextLevelPrice = 0.0;
double         g_BucketFillRate = 0.0;

WorstPosition  g_WorstPositions[3];
ulong          g_CurrentDredgeTarget = 0;

datetime       g_LastHistoryCheck;
datetime       g_LastHistoryScan = 0;
datetime       g_LastDredgeTime = 0;
datetime       g_LastOrderTime = 0;
datetime       g_LastTailTime  = 0;
datetime       g_LastLineUpdate = 0;
datetime       g_LastDashUpdate = 0;
datetime       g_LastCoordinationCheck = 0;
datetime       g_LastExposurePublish = 0;
datetime       g_LastOptCheck = 0;
datetime       g_StartTime;
datetime       g_BucketStartTime;

const int MAX_GRID_LEVELS = 200;

// FORWARD DECLARATIONS
void MapSystemToGrid();
void SyncMemoryWithBroker();
void CalculateCondensingGrid();
void DrawGhostLines();
void UpdateDashboard();
void CalculateDashboardStats();
void CloseAllPositions();
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
void SaveSystemState();
bool LoadSystemState();
void ClearSystemState();
void CheckGuardianCoordination();
void PublishCoordinationData();
double CalculateNetExposure();
void CheckForOptimizationUpdates();
void SendAlert(string msg);

//+------------------------------------------------------------------+
//| Expert initialization function                                   |
//+------------------------------------------------------------------+
int OnInit()
{
   Print("========================================");
   Print("GridBot-Executor v10.11 - INTEGRATED EDITION");
   Print("Status: Guardian Coordination Enabled");
   Print("Note: Downward Extensions DISABLED");
   Print("========================================");
   
   // 1. CRITICAL SAFETY CHECK: Hedging Account Only (C01 fix)
   ENUM_ACCOUNT_MARGIN_MODE marginMode = (ENUM_ACCOUNT_MARGIN_MODE)AccountInfoInteger(ACCOUNT_MARGIN_MODE);
   if(marginMode == ACCOUNT_MARGIN_MODE_RETAIL_NETTING || marginMode == ACCOUNT_MARGIN_MODE_EXCHANGE) {
      Alert("CRITICAL ERROR: Account must be HEDGING type. This EA fails on NETTING/EXCHANGE accounts.");
      return INIT_FAILED;
   }

   // 2. Validate Inputs
   // H02 fix: per-symbol instance guard
   string instanceKey = "EXEC_ACTIVE_" + _Symbol + "_" + IntegerToString(InpMagicNumber);
   if(GlobalVariableCheck(instanceKey)) {
      long existing = (long)GlobalVariableGet(instanceKey);
      if(existing == InpMagicNumber) {
         Alert("ERROR: Another GridBot-Executor (magic=" + IntegerToString(InpMagicNumber) + ") already running on " + _Symbol);
         return INIT_FAILED;
      }
   }
   GlobalVariableSet(instanceKey, (double)InpMagicNumber);

   if(InpUpperPrice <= InpLowerPrice) {
      Alert("ERROR: Upper Price must be > Lower Price");
      return INIT_PARAMETERS_INCORRECT;
   }
   
   if(InpGridLevels < 5 || InpGridLevels > MAX_GRID_LEVELS) {
      Alert("ERROR: Grid Levels must be between 5 and ", MAX_GRID_LEVELS);
      return INIT_PARAMETERS_INCORRECT;
   }

   // M11 fix: validate expansion coefficient range
   if(InpExpansionCoeff < 0.5 || InpExpansionCoeff > 2.0) {
      Alert("ERROR: Expansion Coefficient must be 0.5 - 2.0 (got ", DoubleToString(InpExpansionCoeff, 4), ")");
      return INIT_PARAMETERS_INCORRECT;
   }

   // PA14 fix: validate risk percentages — 0 would cause immediate false triggers
   if(InpHardStopDDPct < 1.0 || InpHardStopDDPct > 50.0) {
      Alert("ERROR: Hard Stop DD% must be 1-50 (got ", DoubleToString(InpHardStopDDPct, 1), ")");
      return INIT_PARAMETERS_INCORRECT;
   }

   // 3. Initialize Environment
   DIGITS   = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   POINT    = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   STEP_LOT = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   MIN_LOT  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   MAX_LOT  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   
   trade.SetExpertMagicNumber(InpMagicNumber);
   trade.SetDeviationInPoints(50);
   trade.SetTypeFilling(GetFillingMode());
   trade.SetAsyncMode(false);

   // M01 fix: AutoTrading enabled check
   if(!TerminalInfoInteger(TERMINAL_TRADE_ALLOWED))
      Print("WARNING: AutoTrading is disabled in terminal — grid orders will fail!");
   if(!AccountInfoInteger(ACCOUNT_TRADE_EXPERT))
      Print("WARNING: Expert Advisors not permitted on this account!");

   // M02 fix: Demo vs live detection
   ENUM_ACCOUNT_TRADE_MODE accMode = (ENUM_ACCOUNT_TRADE_MODE)AccountInfoInteger(ACCOUNT_TRADE_MODE);
   if(accMode != ACCOUNT_TRADE_MODE_DEMO) {
      Print("WARNING: LIVE ACCOUNT — ensure strategy tested before running!");
      SendNotification("GridBot-Executor started on LIVE account: " + _Symbol);
   }

   // M16 fix: check SYMBOL_TRADE_MODE
   ENUM_SYMBOL_TRADE_MODE tradeMode = (ENUM_SYMBOL_TRADE_MODE)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_MODE);
   if(tradeMode == SYMBOL_TRADE_MODE_DISABLED) {
      Alert("ERROR: Trading is DISABLED for ", _Symbol);
      return INIT_FAILED;
   }
   if(tradeMode == SYMBOL_TRADE_MODE_CLOSEONLY)
      Print("WARNING: ", _Symbol, " is in CLOSE-ONLY mode — new grid entries will fail!");

   // 4. RESET OR RESTORE STATE
   if(InpResetState) {
      ClearSystemState();
      Print(">> SYSTEM STATE RESET BY USER <<");
   }

   // 5. LOAD STATE (Persistence Layer)
    if(LoadSystemState()) {
       Print(">> STATE RESUMED: Grid ", g_CurrentUpper, " - ", g_CurrentLower, " | Levels: ", g_CurrentLevels);
    } else {
       Print(">> FRESH START: Using Input Defaults");

       // Tier 3: Smart instrument-aware defaults
       bool userLeftDefaults = (InpUpperPrice == 2750.0 && InpLowerPrice == 2650.0);

       if(userLeftDefaults) {
          double currentPrice = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
          double adjustedUpper = InpUpperPrice;
          double adjustedLower = InpLowerPrice;
          string instrumentType = "";

          // Detect instrument type by current price range
          if(currentPrice > 50000) {
             // HIGH PRICE INSTRUMENT (Crypto: BTC, BTC/ETH)
             adjustedUpper = currentPrice * 1.10;  // +10% above
             adjustedLower = currentPrice * 0.90;  // -10% below
             instrumentType = "CRYPTO (High-Price)";

          } else if(currentPrice > 10000 && currentPrice < 50000) {
             // MEDIUM-HIGH PRICE (Indices: US30, NAS100, DAX)
             adjustedUpper = currentPrice * 1.05;  // +5%
             adjustedLower = currentPrice * 0.95;  // -5%
             instrumentType = "INDEX (Medium-Price)";

          } else if(currentPrice < 10) {
             // LOW PRICE INSTRUMENT (Forex: EURUSD, GBPUSD, etc.)
             adjustedUpper = currentPrice * 1.03;  // +3%
             adjustedLower = currentPrice * 0.97;  // -3%
             instrumentType = "FOREX (Low-Price)";

          } else {
             // GOLD/SILVER RANGE (2000-10000) - keep XAUUSD defaults
             adjustedUpper = InpUpperPrice;
             adjustedLower = InpLowerPrice;
             instrumentType = "METAL (XAUUSD-range)";
             Print("Price range matches XAUUSD defaults (", _Symbol, " @ ", DoubleToString(currentPrice, 2), ")");
          }

          // Apply adjusted values or defaults
          if(adjustedUpper != InpUpperPrice || adjustedLower != InpLowerPrice) {
             // Auto-adjustment was applied
             g_CurrentUpper = adjustedUpper;
             g_CurrentLower = adjustedLower;
             g_UsingAutoDefaults = true;

             Print("========================================");
             Print("⚠️⚠️⚠️ AUTO-RANGE MODE ACTIVATED ⚠️⚠️⚠️");
             Print("========================================");
             Print("Symbol: ", _Symbol);
             Print("Detected: ", instrumentType);
             Print("Current Price: ", DoubleToString(currentPrice, _Digits));
             Print("Auto-Adjusted Range:");
             Print("  Upper: ", DoubleToString(adjustedUpper, _Digits));
             Print("  Lower: ", DoubleToString(adjustedLower, _Digits));
             Print("========================================");
             Print("⚠️ THIS IS NOT OPTIMIZED!");
             Print("⚠️ USE PLANNER FOR PROPER CONFIGURATION!");
             Print("⚠️ PERFORMANCE MAY BE SUBOPTIMAL!");
             Print("========================================");

             // Send prominent alert
             string alertMsg = "⚠️⚠️⚠️ EXECUTOR USING AUTO-ADJUSTED DEFAULTS ⚠️⚠️⚠️\n\n" +
                               "Symbol: " + _Symbol + "\n" +
                               "Type: " + instrumentType + "\n" +
                               "Current Price: " + DoubleToString(currentPrice, _Digits) + "\n\n" +
                               "Auto Range: " + DoubleToString(adjustedLower, _Digits) +
                               " - " + DoubleToString(adjustedUpper, _Digits) + "\n\n" +
                               "⚠️ THIS IS NOT OPTIMIZED!\n" +
                               "⚠️ USE PLANNER FOR PROPER CONFIGURATION!\n" +
                               "⚠️ PERFORMANCE MAY BE SUBOPTIMAL!";
             SendAlert(alertMsg);

          } else {
             // Defaults matched instrument (XAUUSD case)
             g_CurrentUpper = InpUpperPrice;
             g_CurrentLower = InpLowerPrice;
             g_UsingAutoDefaults = false;
          }

       } else {
          // User configured inputs manually
          g_CurrentUpper = InpUpperPrice;
          g_CurrentLower = InpLowerPrice;
          g_UsingAutoDefaults = false;
          Print("Using manually configured range: ", g_CurrentUpper, " - ", g_CurrentLower);
       }

       g_CurrentLevels = InpGridLevels;
       g_ActiveExpansionCoeff = InpExpansionCoeff;
       g_BucketTotal = 0.0;
       g_NetExposure = 0.0;

       SaveSystemState();
    }

   // 6. Initialize runtime lot sizes and brake threshold (may be overridden by LoadSystemState or remote opt)
   if(g_RuntimeLot1 <= 0) g_RuntimeLot1 = InpLotZone1;
   if(g_RuntimeLot2 <= 0) g_RuntimeLot2 = InpLotZone2;
   if(g_RuntimeLot3 <= 0) g_RuntimeLot3 = InpLotZone3;

   // 7. Recalculate Geometry
   g_TotalRangeDist = g_CurrentUpper - g_CurrentLower;
   g_OriginalZone1_Floor = g_CurrentUpper - (g_TotalRangeDist / 3.0);
   g_OriginalZone2_Floor = g_CurrentUpper - ((g_TotalRangeDist / 3.0) * 2.0);

   g_StartTime = TimeCurrent();
   g_BucketStartTime = TimeCurrent();
   g_InitialBalance = AccountInfoDouble(ACCOUNT_BALANCE);
   if(g_PeakEquity <= 0) {
      g_PeakEquity = AccountInfoDouble(ACCOUNT_BALANCE);  // Seed from balance, not equity
      g_DynamicHardStop = g_PeakEquity * (1.0 - InpHardStopDDPct / 100.0);
      Print("Hard Stop initialized: Peak balance=$", DoubleToString(g_PeakEquity, 2),
            " | Floor=$", DoubleToString(g_DynamicHardStop, 2),
            " (", DoubleToString(InpHardStopDDPct, 1), "% DD)");
   }
   g_LastHistoryCheck = TimeCurrent();
   g_LastHistoryScan = TimeCurrent();

   CalculateCondensingGrid();

   // Retry grid validation up to 3 times (reconnection may cause transient data issues)
   int gridRetries = 0;
   while(!IsGridHealthy() && gridRetries < 3) {
      gridRetries++;
      Print("WARNING: Grid validation failed (attempt ", gridRetries, "/3). Retrying in 2s...");
      Sleep(2000);
      CalculateCondensingGrid();
   }
   if(!IsGridHealthy()) {
      Alert("ERROR: Grid validation failed after 3 retries. Check parameters.");
      return INIT_FAILED;
   }
   
   ArrayResize(g_LevelTickets, g_CurrentLevels);
   ArrayInitialize(g_LevelTickets, 0);
   ArrayResize(g_LevelLock, g_CurrentLevels);
   ArrayInitialize(g_LevelLock, false);

   // 7. Map existing live orders to the grid
   MapSystemToGrid();
   
   // 8. Initial coordination data publish
   if(InpEnableGuardianCoordination) {
      PublishCoordinationData();
      Print("Guardian Coordination: ENABLED");
   }
   
   if(InpShowGhostLines) DrawGhostLines();
   
   EventSetTimer(1);
   
   Print("Initialization Complete - Guardian Integration Active");
   Print("GridBot-Executor magic=", InpMagicNumber, " on ", _Symbol);
   WriteLog("STARTUP", 0, 0, 0, 0,
      StringFormat("magic=%d upper=%.2f lower=%.2f levels=%d lot1=%.2f lot2=%.2f lot3=%.2f hardstop=%.1f%%",
      InpMagicNumber, g_CurrentUpper, g_CurrentLower, g_CurrentLevels,
      g_RuntimeLot1, g_RuntimeLot2, g_RuntimeLot3, InpHardStopDDPct));
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   Print("GridBot-Executor v10.11 - Shutting down");
   EventKillTimer();
   ObjectsDeleteAll(0, "GhostLine_");
   ObjectDelete(0, "SG_BreakEven");

   // H02 fix: release instance guard
   GlobalVariableDel("EXEC_ACTIVE_" + _Symbol + "_" + IntegerToString(InpMagicNumber));

   // C02 fix: clear namespaced coordination flags
   GlobalVariableSet(GetGVKey("BOT_ACTIVE"), 0);

   DashCleanup();
}

//+------------------------------------------------------------------+
//| STATE PERSISTENCE MANAGER                                        |
//+------------------------------------------------------------------+
string GetGVKey(string suffix) {
   return IntegerToString(InpMagicNumber) + "_SG_" + suffix;
}

string GetGuardianKey(string suffix) {
   return IntegerToString(InpGuardianMagic) + "_GH_" + suffix;
}

string FormatAge(int seconds) {
   if(seconds < 60)   return IntegerToString(seconds) + "s ago";
   if(seconds < 3600) return IntegerToString(seconds / 60) + "m ago";
   return IntegerToString(seconds / 3600) + "h " + IntegerToString((seconds % 3600) / 60) + "m ago";
}

void SaveSystemState() {
   GlobalVariableSet(GetGVKey("UPPER"), g_CurrentUpper);
   GlobalVariableSet(GetGVKey("LOWER"), g_CurrentLower);
   GlobalVariableSet(GetGVKey("LEVELS"), (double)g_CurrentLevels);
   GlobalVariableSet(GetGVKey("COEFF"), g_ActiveExpansionCoeff);
   
   RecalculateBucketTotal(); 
   GlobalVariableSet(GetGVKey("BUCKET"), g_BucketTotal);
   GlobalVariableSet(GetGVKey("LAST_UPDATE"), (double)TimeCurrent());
   GlobalVariableSet(GetGVKey("LOT1"), g_RuntimeLot1);
   GlobalVariableSet(GetGVKey("LOT2"), g_RuntimeLot2);
   GlobalVariableSet(GetGVKey("LOT3"), g_RuntimeLot3);
   GlobalVariableSet(GetGVKey("PEAK_EQUITY"), g_PeakEquity);

   // Coordination data (C02 fix: namespaced key)
   if(InpEnableGuardianCoordination) {
      GlobalVariableSet(GetGVKey("NET_EXPOSURE"), g_NetExposure);
      GlobalVariableSet(GetGVKey("BOT_ACTIVE"), IsTradingActive ? 1.0 : 0.0);
      GlobalVariableSet(GetGVKey("HARD_STOP_LEVEL"), g_DynamicHardStop);  // Planner/Guardian visibility
   }
}

bool LoadSystemState() {
   if(!GlobalVariableCheck(GetGVKey("UPPER"))) return false;
   if(!GlobalVariableCheck(GetGVKey("LAST_UPDATE"))) return false;
   
   g_CurrentUpper  = GlobalVariableGet(GetGVKey("UPPER"));
   g_CurrentLower  = GlobalVariableGet(GetGVKey("LOWER"));
   g_CurrentLevels = (int)GlobalVariableGet(GetGVKey("LEVELS"));
   
   if(GlobalVariableCheck(GetGVKey("COEFF"))) {
      g_ActiveExpansionCoeff = GlobalVariableGet(GetGVKey("COEFF"));
   } else {
      g_ActiveExpansionCoeff = InpExpansionCoeff;
   }

   if(GlobalVariableCheck(GetGVKey("LOT1"))) g_RuntimeLot1 = GlobalVariableGet(GetGVKey("LOT1"));
   if(GlobalVariableCheck(GetGVKey("LOT2"))) g_RuntimeLot2 = GlobalVariableGet(GetGVKey("LOT2"));
   if(GlobalVariableCheck(GetGVKey("LOT3"))) g_RuntimeLot3 = GlobalVariableGet(GetGVKey("LOT3"));
   if(GlobalVariableCheck(GetGVKey("PEAK_EQUITY"))) {
      g_PeakEquity = GlobalVariableGet(GetGVKey("PEAK_EQUITY"));
      g_DynamicHardStop = g_PeakEquity * (1.0 - InpHardStopDDPct / 100.0);
      Print("Hard Stop restored: Peak balance=$", DoubleToString(g_PeakEquity, 2),
            " | Floor=$", DoubleToString(g_DynamicHardStop, 2));
   }
   
   double savedBucket = 0;
   if(GlobalVariableCheck(GetGVKey("BUCKET"))) {
      savedBucket = GlobalVariableGet(GetGVKey("BUCKET"));
   }
   
   // L10 note: individual bucket item timestamps are not persisted.
   // On restore, all funds are assigned TimeCurrent() — items that should
   // have expired (>InpBucketRetentionHrs old) survive. This is conservative
   // behavior (money stays in bucket longer), which is generally safe.
   if(savedBucket > 0) {
      ArrayResize(g_BucketQueue, 1);
      g_BucketQueue[0].amount = savedBucket;
      g_BucketQueue[0].time   = TimeCurrent();
      g_BucketTotal = savedBucket;
   }
   
   return true;
}

void ClearSystemState() {
   GlobalVariableDel(GetGVKey("UPPER"));
   GlobalVariableDel(GetGVKey("LOWER"));
   GlobalVariableDel(GetGVKey("LEVELS"));
   GlobalVariableDel(GetGVKey("COEFF"));
   GlobalVariableDel(GetGVKey("BUCKET"));
   GlobalVariableDel(GetGVKey("LAST_UPDATE"));
   GlobalVariableDel(GetGVKey("NET_EXPOSURE"));
   GlobalVariableDel(GetGVKey("LOT1"));
   GlobalVariableDel(GetGVKey("LOT2"));
   GlobalVariableDel(GetGVKey("LOT3"));
   GlobalVariableDel(GetGVKey("PEAK_EQUITY"));
   GlobalVariableDel(GetGVKey("HARD_STOP_LEVEL"));

   // M14 fix: clear stale optimizer GVs to prevent re-application after reset
   GlobalVariableDel(GetGVKey("OPT_NEW_UPPER"));
   GlobalVariableDel(GetGVKey("OPT_NEW_LOWER"));
   GlobalVariableDel(GetGVKey("OPT_NEW_LEVELS"));
   GlobalVariableDel(GetGVKey("OPT_NEW_COEFF"));
   GlobalVariableDel(GetGVKey("OPT_NEW_LOT1"));
   GlobalVariableDel(GetGVKey("OPT_NEW_LOT2"));
   GlobalVariableDel(GetGVKey("OPT_NEW_LOT3"));
   GlobalVariableDel(GetGVKey("OPT_NEW_MAX_SPREAD"));
   GlobalVariableDel(GetGVKey("OPT_CMD_PushTime"));
   GlobalVariableDel(GetGVKey("OPT_LAST_APPLIED"));
}

//+------------------------------------------------------------------+
//| GUARDIAN COORDINATION LAYER                                      |
//+------------------------------------------------------------------+
void CheckGuardianCoordination()
{
   if(!InpEnableGuardianCoordination) return;
   if(TimeCurrent() - g_LastCoordinationCheck < InpCoordinationCheckInterval) return;
   
   // Check if Guardian has activated hedge mode (C02 fix: namespaced key)
   bool wasGuardianActive = IsGuardianActive;
   IsGuardianActive = false;

   string hedgeKey = GetGVKey("HEDGE_ACTIVE");
   if(GlobalVariableCheck(hedgeKey)) {
      double guardianFlag = GlobalVariableGet(hedgeKey);
      IsGuardianActive = (guardianFlag > 0.5);
   }
   
   // State change detection
   if(IsGuardianActive && !wasGuardianActive) {
      Print("GUARDIAN ACTIVATED: GridBot-Executor entering FREEZE mode");
      Print("   | Reason: Hedge protection engaged");
      Print("   | Action: All new grid entries suspended");
      WriteLog("FREEZE_ON", 0, 0, 0, 0, "Guardian hedge activated — grid suspended");
   }
   else if(!IsGuardianActive && wasGuardianActive) {
      // PA22: Reset peak balance reference on unfreeze.
      // During Guardian freeze the hard stop check is bypassed (early return), so equity
      // can drift far below the hard stop floor undetected over many hours.
      // On the first tick after unfreeze, the check would immediately fire CloseAllPositions()
      // at the worst possible price (confirmed from Feb 27 trade log analysis).
      // Fix: reset g_PeakEquity to current balance — losses that occurred while Guardian
      // was actively hedging are "forgiven"; a new hard stop floor is calculated from here.
      double currentBalance = AccountInfoDouble(ACCOUNT_BALANCE);
      g_PeakEquity      = currentBalance;
      g_DynamicHardStop = g_PeakEquity * (1.0 - InpHardStopDDPct / 100.0);
      GlobalVariableSet(GetGVKey("PEAK_EQUITY"), g_PeakEquity);
      Print("GUARDIAN DEACTIVATED: SmartGrid resuming operations");
      Print("PA22: Peak balance reset to $", DoubleToString(g_PeakEquity, 2),
            " | New hard stop floor: $", DoubleToString(g_DynamicHardStop, 2));
      WriteLog("FREEZE_OFF", 0, 0, 0, 0,
         StringFormat("newPeak=%.2f newFloor=%.2f", g_PeakEquity, g_DynamicHardStop));
   }
   
   g_LastCoordinationCheck = TimeCurrent();
}

void PublishCoordinationData()
{
   if(!InpEnableGuardianCoordination) return;
   if(TimeCurrent() - g_LastExposurePublish < 10) return;
   
   // Calculate and publish net exposure
   g_NetExposure = CalculateNetExposure();
   GlobalVariableSet(GetGVKey("NET_EXPOSURE"), g_NetExposure);
   
   // Publish dredge target if active (C02 fix: namespaced key)
   string dredgeKey = GetGVKey("DREDGE_TARGET");
   if(g_CurrentDredgeTarget > 0) {
      GlobalVariableSet(dredgeKey, (double)g_CurrentDredgeTarget);
   } else {
      if(GlobalVariableCheck(dredgeKey)) {
         GlobalVariableDel(dredgeKey);
      }
   }

   // Update state flag (C02 fix: namespaced key)
   GlobalVariableSet(GetGVKey("BOT_ACTIVE"), IsTradingActive ? 1.0 : 0.0);
   
   g_LastExposurePublish = TimeCurrent();
}

double CalculateNetExposure()
{
   double netVol = 0.0;
   
   for(int i=PositionsTotal()-1; i>=0; i--) {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue;
      if(!PositionSelectByTicket(ticket)) continue;
      
      if(PositionGetInteger(POSITION_MAGIC) == InpMagicNumber) {
         double vol = PositionGetDouble(POSITION_VOLUME);
         long type = PositionGetInteger(POSITION_TYPE);
         
         if(type == POSITION_TYPE_BUY) netVol += vol;
         else if(type == POSITION_TYPE_SELL) netVol -= vol;
      }
   }
   
   return netVol;
}

void CheckForOptimizationUpdates()
{
   if(!InpAllowRemoteOpt) return;
   if(TimeCurrent() - g_LastOptCheck < 10) return;
   
   string cmdKey = GetGVKey("OPT_CMD_PushTime");
   if(GlobalVariableCheck(cmdKey)) {
      datetime pushTime = (datetime)GlobalVariableGet(cmdKey);
      
      // Store last applied push time to avoid loops
      double lastApplied = 0;
      if(GlobalVariableCheck(GetGVKey("OPT_LAST_APPLIED"))) {
         lastApplied = GlobalVariableGet(GetGVKey("OPT_LAST_APPLIED"));
      }
      
      if((double)pushTime > lastApplied) {
         Print("REMOTE OPTIMIZATION RECEIVED");

         // H03 fix: null-check before reading optimization GVs
         if(!GlobalVariableCheck(GetGVKey("OPT_NEW_UPPER"))) { g_LastOptCheck = TimeCurrent(); return; }
         double newUpper  = GlobalVariableGet(GetGVKey("OPT_NEW_UPPER"));
         double newLower  = GlobalVariableCheck(GetGVKey("OPT_NEW_LOWER"))  ? GlobalVariableGet(GetGVKey("OPT_NEW_LOWER"))  : 0;
         double newLevels = GlobalVariableCheck(GetGVKey("OPT_NEW_LEVELS")) ? GlobalVariableGet(GetGVKey("OPT_NEW_LEVELS")) : 0;
         double newCoeff  = GlobalVariableCheck(GetGVKey("OPT_NEW_COEFF"))  ? GlobalVariableGet(GetGVKey("OPT_NEW_COEFF"))  : InpExpansionCoeff;

         // Optional lot override from Master
         if(GlobalVariableCheck(GetGVKey("OPT_NEW_LOT1"))) {
            double lot1 = GlobalVariableGet(GetGVKey("OPT_NEW_LOT1"));
            // PA11 fix: individual null-checks for LOT2/LOT3 — prevent silent 0.0 read if GV missing
            double lot2 = GlobalVariableCheck(GetGVKey("OPT_NEW_LOT2")) ? GlobalVariableGet(GetGVKey("OPT_NEW_LOT2")) : 0;
            double lot3 = GlobalVariableCheck(GetGVKey("OPT_NEW_LOT3")) ? GlobalVariableGet(GetGVKey("OPT_NEW_LOT3")) : 0;
            if(lot1 >= MIN_LOT && lot1 <= MAX_LOT) g_RuntimeLot1 = lot1;
            if(lot2 >= MIN_LOT && lot2 <= MAX_LOT) g_RuntimeLot2 = lot2;
            if(lot3 >= MIN_LOT && lot3 <= MAX_LOT) g_RuntimeLot3 = lot3;
            Print("LOT UPDATE: Z1=", g_RuntimeLot1, " Z2=", g_RuntimeLot2, " Z3=", g_RuntimeLot3);
         }

         // Optional max spread override from Planner
         if(GlobalVariableCheck(GetGVKey("OPT_NEW_MAX_SPREAD"))) {
            double newSpread = GlobalVariableGet(GetGVKey("OPT_NEW_MAX_SPREAD"));
            if(newSpread >= 50) g_RuntimeMaxSpread = (int)newSpread;
            Print("MAX SPREAD UPDATE: ", g_RuntimeMaxSpread, " pts (from Planner)");
         }

         if(newUpper > newLower && newLevels > 5) {
            IsTradingActive = false; // Pause
            DeleteAllOrders();

            g_CurrentUpper = newUpper;
            g_CurrentLower = newLower;
            g_CurrentLevels = (int)newLevels;
            g_ActiveExpansionCoeff = newCoeff;

            // CRITICAL: Recalculate zone floors after boundary change
            g_TotalRangeDist = g_CurrentUpper - g_CurrentLower;
            g_OriginalZone1_Floor = g_CurrentUpper - (g_TotalRangeDist / 3.0);
            g_OriginalZone2_Floor = g_CurrentUpper - ((g_TotalRangeDist / 3.0) * 2.0);

            SaveSystemState();
            RebuildGrid(false);
            DrawGhostLines();
            
            GlobalVariableSet(GetGVKey("OPT_LAST_APPLIED"), (double)pushTime);
            
            string msg = "OPTIMIZATION APPLIED: " + DoubleToString(newUpper, _Digits) + " - " + DoubleToString(newLower, _Digits);
            Print(msg);
            SendAlert(msg);

            // Tier 3: Clear auto-range flag - now using Planner-optimized values
            if(g_UsingAutoDefaults) {
               g_UsingAutoDefaults = false;
               Print("✓ AUTO-RANGE MODE DEACTIVATED - Now using Planner-optimized configuration");
            }

            IsTradingActive = true;
         }
      }
   }
   g_LastOptCheck = TimeCurrent();
}

void SendAlert(string msg) {
   Alert(msg); // H04 fix: always show MT5 popup
   if(InpEnablePushNotify) SendNotification(msg);
   if(InpEnableEmailNotify) SendMail("GridBot-Executor Alert", msg); // M08 fix: updated branding
}

//+------------------------------------------------------------------+
//| Main Engine                                                      |
//+------------------------------------------------------------------+
void OnTick()
{
   // PA25: Heartbeat published FIRST — before any early return.
   // Previously at end of OnTick (line ~878), which meant hard stop (IsTradingActive=false)
   // prevented heartbeat from ever updating again → Guardian falsely reported bot as FROZEN
   // for the entire remainder of the session. Now: Guardian always sees the EA is running,
   // even when trading is halted by hard stop.
   if(InpEnableGuardianCoordination) {
      string hbKeyEarly = GetGVKey("HEARTBEAT");
      static datetime lastHBEarly = 0;
      if(TimeCurrent() != lastHBEarly) {
         GlobalVariableSet(hbKeyEarly, (double)TimeCurrent());
         lastHBEarly = TimeCurrent();
      }
   }

   if(!IsTradingActive) return;

   // M03 fix: price staleness detection
   datetime lastTick = (datetime)SymbolInfoInteger(_Symbol, SYMBOL_TIME);
   if(TimeCurrent() - lastTick > 30) {
      if(TimeCurrent() % 60 == 0)
         Print("WARNING: Price data stale — last tick ", (int)(TimeCurrent()-lastTick), "s ago");
      return;
   }

   // 1. Guardian Coordination Check (PRIORITY)
   if(InpEnableGuardianCoordination) {
      CheckGuardianCoordination();
      
      // If Guardian is active, FREEZE all trading
      if(IsGuardianActive) {
         // PA08 fix: keep HEARTBEAT alive during Guardian freeze so Guardian
         // doesn't falsely alert "SmartGrid FROZEN!" against its own freeze command
         static datetime lastFrozenHB = 0;
         if(TimeCurrent() != lastFrozenHB) {
            GlobalVariableSet(GetGVKey("HEARTBEAT"), (double)TimeCurrent());
            lastFrozenHB = TimeCurrent();
         }
         // Keep peak balance tracking alive during freeze
         double frozenBalance = AccountInfoDouble(ACCOUNT_BALANCE);
         if(frozenBalance > g_PeakEquity) {
            g_PeakEquity = frozenBalance;
            g_DynamicHardStop = g_PeakEquity * (1.0 - InpHardStopDDPct / 100.0);
         }
         if(TimeCurrent() % 60 == 0) {
            Print("FROZEN: Guardian hedge protection active");
         }
         return;
      }
   }

   // 2. Critical Equity Check — Dynamic Hard Stop
   // Peak tracks BALANCE (realized only) — immune to floating equity spikes from grid positions.
   // Floor rises only when real profits are banked, not when unrealized P&L temporarily spikes.
   // Trigger checks EQUITY — detects actual account value including floating loss.
   double currentEquity  = AccountInfoDouble(ACCOUNT_EQUITY);
   double currentBalance = AccountInfoDouble(ACCOUNT_BALANCE);
   if(currentBalance > g_PeakEquity) {
      g_PeakEquity = currentBalance;
      g_DynamicHardStop = g_PeakEquity * (1.0 - InpHardStopDDPct / 100.0);
   }
   if(currentEquity < g_DynamicHardStop) {
      Print("CRITICAL: Hard Stop triggered! Equity=$", DoubleToString(currentEquity, 2),
            " < Floor=$", DoubleToString(g_DynamicHardStop, 2),
            " (", DoubleToString(InpHardStopDDPct, 1), "% DD from peak balance $", DoubleToString(g_PeakEquity, 2), ")");
      double hsDD = (g_PeakEquity > 0) ? (g_PeakEquity - currentEquity) / g_PeakEquity * 100.0 : 0.0;
      WriteLog("HARD_STOP", 0, currentEquity, 0, 0,
         StringFormat("floor=%.2f peak=%.2f dd=%.2f%%", g_DynamicHardStop, g_PeakEquity, hsDD));
      IsTradingActive = false;
      CloseAllPositions();
      Alert("EQUITY STOP TRIGGERED: -" + DoubleToString(InpHardStopDDPct, 1) + "% from peak balance $" + DoubleToString(g_PeakEquity, 2));
      return;
   }

   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   
   // 4. Dynamic Grid (UPWARD ONLY)
   if(InpEnableDynamicGrid) CheckDynamicGrid(ask, bid);

   SyncMemoryWithBroker();
   ManageRollingTail();
   
   if(InpUseBucketDredge) {
      ScanForRealizedProfits();
      CleanExpiredBucketItems();
   }

   int effectiveMaxSpread = (g_RuntimeMaxSpread > 0) ? g_RuntimeMaxSpread : InpMaxSpread;
   bool spreadOK = ((ask-bid)/POINT <= effectiveMaxSpread);
   
   // 5. Trade Execution
   if(spreadOK) {
      ManageGridEntry(ask);
      ManageExits(bid);
      if(InpUseBucketDredge) ManageBucketDredging();
   }
   
   if(InpShowBreakEven) DrawBreakEvenLine();
   
   // 6. Periodic Updates
   if(InpShowGhostLines && TimeCurrent() - g_LastLineUpdate > 60) {
      DrawGhostLines();
      g_LastLineUpdate = TimeCurrent();
   }
   
   // 7. Publish coordination data
   if(InpEnableGuardianCoordination) {
      PublishCoordinationData();
      // Heartbeat moved to top of OnTick (PA25) — see beginning of function
   }

   // 8. Listen for Remote Optimization
   CheckForOptimizationUpdates();
}

void OnTimer()
{
   if(InpShowDashboard) {
      CalculateDashboardStats();
      UpdateDashboard();
   }
}

//+------------------------------------------------------------------+
//| DYNAMIC GRID (UPWARD SHIFT ONLY)                                 |
//+------------------------------------------------------------------+
void CheckDynamicGrid(double ask, double bid)
{
   double buffer = (g_CurrentUpper - g_CurrentLower) * (InpUpShiftTriggerPct / 100.0);
   
   // --- LOGIC: SHIFT UP ONLY ---
   if(ask > g_CurrentUpper + buffer) {
      double shiftAmt = (g_CurrentUpper - g_CurrentLower) * (InpUpShiftAmountPct / 100.0);
      Print("DYNAMIC GRID: Upside breakout - Shifting UP by $", DoubleToString(shiftAmt, 2));
      
      g_CurrentUpper += shiftAmt;
      g_CurrentLower += shiftAmt;
      g_OriginalZone1_Floor += shiftAmt;
      g_OriginalZone2_Floor += shiftAmt;

      DeleteAllOrders();
      RebuildGrid(false);
      SaveSystemState();  // PA10 fix: save AFTER rebuild so persisted state matches actual grid
      DrawGhostLines();
      
      if(InpEnableTradeLog) LogTrade("GRID_SHIFT_UP", 0, g_CurrentUpper, shiftAmt, 0);
      return;
   }

   // --- DOWNWARD EXTENSION REMOVED ---
   if(bid < g_CurrentLower) {
      if(TimeCurrent() % 300 == 0) {
         Print("WARNING: Price below grid: $", bid, " < $", g_CurrentLower);
         Print("   | Guardian should handle this scenario");
      }
   }
}

void RebuildGrid(bool isExtension)
{
   ulong tempTickets[];
   bool tempLocks[];
   int oldSize = ArraySize(g_LevelTickets);
   
   if(isExtension && oldSize > 0) {
      ArrayResize(tempTickets, oldSize);
      ArrayResize(tempLocks, oldSize);
      ArrayCopy(tempTickets, g_LevelTickets);
      ArrayCopy(tempLocks, g_LevelLock);
   }
   
   ArrayResize(g_LevelTickets, g_CurrentLevels);
   ArrayResize(g_LevelLock, g_CurrentLevels);
   
   if(isExtension && oldSize > 0) {
      for(int i=0; i<oldSize && i<g_CurrentLevels; i++) {
         g_LevelTickets[i] = tempTickets[i];
         g_LevelLock[i] = tempLocks[i];
      }
      for(int i=oldSize; i<g_CurrentLevels; i++) {
         g_LevelTickets[i] = 0;
         g_LevelLock[i] = false;
      }
   } else {
      ArrayInitialize(g_LevelTickets, 0);
      ArrayInitialize(g_LevelLock, false);
   }
   
   CalculateCondensingGrid();

   if(!IsGridHealthy()) {
      // Retry once — transient data issue during reconnection
      Sleep(1000);
      CalculateCondensingGrid();
      if(!IsGridHealthy()) {
         Print("ERROR: Grid health check failed after rebuild");
         Alert("GRID CORRUPTION DETECTED");
         IsTradingActive = false;
         return;
      }
   }

   if(!isExtension) MapSystemToGrid();
}

void CalculateCondensingGrid()
{
   ArrayResize(GridPrices, g_CurrentLevels);
   ArrayResize(GridTPs, g_CurrentLevels);
   ArrayResize(GridLots, g_CurrentLevels);
   ArrayResize(GridStepSize, g_CurrentLevels);

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
      
      if(i == 0) GridTPs[i] = NormalizeDouble(g_CurrentUpper, DIGITS);
      else GridTPs[i] = GridPrices[i-1];
      
      GridStepSize[i] = currentGap;
      
      int z = GetZone(GridPrices[i]);
      double rawLot = (z==1) ? g_RuntimeLot1 : (z==2) ? g_RuntimeLot2 : g_RuntimeLot3;
      GridLots[i] = NormalizeLot(rawLot);

      currentGap *= g_ActiveExpansionCoeff;
      currentPrice -= currentGap;
   }
}

bool IsGridHealthy()
{
   if(g_CurrentLevels <= 0 || ArraySize(GridPrices) != g_CurrentLevels) return false;
   
   for(int i=0; i<g_CurrentLevels; i++) {
      if(GridPrices[i] <= 0) return false;
      if(GridLots[i] < MIN_LOT || GridLots[i] > MAX_LOT) return false;
      if(GridStepSize[i] <= 0) return false;
      if(i > 0 && GridPrices[i] >= GridPrices[i-1]) return false;
      if(GridTPs[i] <= GridPrices[i]) return false;
   }
   
   return true;
}

void ManageGridEntry(double ask)
{
   if(TimeCurrent() - g_LastOrderTime < 1) return;
   if(!IsGridHealthy()) return;

   // H09 fix: count only THIS bot's positions (not all symbols/EAs)
   int myPositions = 0;
   for(int p = PositionsTotal()-1; p >= 0; p--) {
      ulong pt = PositionGetTicket(p);
      if(pt > 0 && PositionSelectByTicket(pt) && PositionGetInteger(POSITION_MAGIC) == InpMagicNumber)
         myPositions++;
   }
   if(myPositions >= InpMaxOpenPos) return;

   for(int i=0; i<g_CurrentLevels; i++) {
      if(g_LevelTickets[i] > 0 || g_LevelLock[i]) continue;
      if(GridPrices[i] <= 0 || GridLots[i] <= 0) continue;
      
      int activePending = 0;
      for(int k=0; k<g_CurrentLevels; k++) {
         if(g_LevelTickets[k] > 0 && OrderSelect(g_LevelTickets[k])) {
            if(OrderGetInteger(ORDER_STATE)==ORDER_STATE_PLACED) activePending++;
         }
      }
      if(activePending >= InpMaxPendingOrders) continue;

      double target = GridPrices[i];
      
      double stopsLevel = (double)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL) * POINT;
      if(ask - target < stopsLevel) continue; 
      
      // --- SEATBELT SAFETY CHECK ---
      // Ensure no position exists here (Double check against SyncMemory failures)
      bool duplicateFound = false;
      for(int k=PositionsTotal()-1; k>=0; k--) {
         ulong t = PositionGetTicket(k);
         if(PositionSelectByTicket(t) && PositionGetInteger(POSITION_MAGIC)==InpMagicNumber) {
            if(MathAbs(PositionGetDouble(POSITION_PRICE_OPEN) - target) < (GridStepSize[i]*0.4)) {
               duplicateFound = true;
               g_LevelTickets[i] = t; // Auto-fix
               break;
            }
         }
      }
      if(duplicateFound) continue;
      // ----------------------------- 
      
      if(ask > target) {
         double margin_required;
         if(OrderCalcMargin(ORDER_TYPE_BUY_LIMIT, _Symbol, GridLots[i], target, margin_required)) {
            if(AccountInfoDouble(ACCOUNT_MARGIN_FREE) < margin_required * 1.1) {
               if(InpEnableTradeLog) Print("Skipping Level ", i, ": Insufficient Margin");
               continue;
            }
         }
      
         // PA26: last-line-of-defense — direct GV read bypasses poll cache.
         // Catches the ~1s gap between Guardian publishing HEDGE_ACTIVE and the next
         // CheckGuardianCoordination poll. No state/log update here (that's handled
         // by CheckGuardianCoordination on the transition tick).
         if(InpEnableGuardianCoordination) {
            string immediateHedgeKey = GetGVKey("HEDGE_ACTIVE");
            if(GlobalVariableCheck(immediateHedgeKey) && GlobalVariableGet(immediateHedgeKey) > 0.5)
               continue;
         }

         g_LevelLock[i] = true;
         string comment = "SG_L"+IntegerToString(i+1);
         double tp = InpUseVirtualTP ? 0 : GridTPs[i];

         if(trade.BuyLimit(GridLots[i], target, _Symbol, 0, tp, ORDER_TIME_GTC, 0, comment)) {
            if(trade.ResultRetcode()==TRADE_RETCODE_DONE || trade.ResultRetcode()==TRADE_RETCODE_PLACED) {
               g_LevelTickets[i] = trade.ResultOrder();
               g_LastOrderTime = TimeCurrent();

               if(InpEnableTradeLog) LogTrade("BUY_LIMIT", i+1, target, GridLots[i], g_LevelTickets[i]);

               if(InpEnablePushNotify) SendNotification("GRID ORDER: Level " + IntegerToString(i+1) + " Placed");
            } else {
               // H01 fix: log order failure details
               if(InpEnableTradeLog) Print("ORDER FAILED L", i+1, " @ ", DoubleToString(target, DIGITS), " RC=", trade.ResultRetcode(), ": ", trade.ResultRetcodeDescription());
               WriteLog("ORDER_FAIL", i+1, target, GridLots[i], 0,
                  StringFormat("rc=%d %s", trade.ResultRetcode(), trade.ResultRetcodeDescription()));
            }
         }
         g_LevelLock[i] = false;
      }
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
      // DredgeRangePct filter: only dredge positions where price has moved FAR enough away
      // e.g. InpDredgeRangePct=0.5 means price must be at least 50% of total range away from position open price
      // This naturally protects new positions (dist≈0) without needing an explicit age check
      double currentPrice = SymbolInfoDouble(_Symbol, SYMBOL_BID);
      double thresholdDist = g_TotalRangeDist * InpDredgeRangePct;
      double dist = MathAbs(g_WorstPositions[0].price - currentPrice);
      if(dist < thresholdDist) {
         return;  // Price hasn't moved far enough from this position yet — let it reach TP naturally
      }

      double lossAbs = MathAbs(g_WorstPositions[0].loss);
      if(availableCash > lossAbs && g_BucketTotal > lossAbs) {
         
         g_CurrentDredgeTarget = g_WorstPositions[0].ticket;
         PublishCoordinationData();
         
         if(trade.PositionClose(g_WorstPositions[0].ticket)) {
            if(SpendFromBucket(lossAbs)) {
               Print("DREDGED: Level ", g_WorstPositions[0].level, " | Loss: $", DoubleToString(g_WorstPositions[0].loss, 2));
               g_TotalDredged += lossAbs;
               
               for(int k=0; k<g_CurrentLevels; k++) {
                  if(g_LevelTickets[k] == g_WorstPositions[0].ticket) {
                     g_LevelTickets[k] = 0;
                     break;
                  }
               }
               
               if(InpEnableTradeLog) LogTrade("DREDGED", g_WorstPositions[0].level, 0, lossAbs, g_WorstPositions[0].ticket);
               SendAlert("DREDGE ACTION: Cleared Level " + IntegerToString(g_WorstPositions[0].level) + " (-$" + DoubleToString(lossAbs, 2) + ")");
               g_LastDredgeTime = TimeCurrent();
            }
         }
         
         g_CurrentDredgeTarget = 0;
         PublishCoordinationData();
      }
   }
}

void ManageExits(double curBid)
{
   if(!InpUseVirtualTP) return;
   
   for(int i=PositionsTotal()-1; i>=0; i--) {
      ulong t = PositionGetTicket(i);
      if(t==0 || !PositionSelectByTicket(t)) continue;
      if(PositionGetInteger(POSITION_MAGIC) != InpMagicNumber) continue;
      
      double openPrice = PositionGetDouble(POSITION_PRICE_OPEN);
      int idx = GetLevelIndex(openPrice);
      
      if(idx >= 0 && idx < g_CurrentLevels) {
         // Normal TP: position maps to a grid level
         if(curBid >= GridTPs[idx]) {
            if(trade.PositionClose(t)) {
               g_LevelTickets[idx] = 0;
               if(InpEnableTradeLog) LogTrade("TP_CLOSE", idx+1, curBid, 0, t);
               SendAlert("TAKE PROFIT: Level " + IntegerToString(idx+1) + " Closed");
            }
         }
      }
      else {
         // PA23: Orphaned position — doesn't match any current grid level.
         // Find nearest grid level ABOVE open price and use it as TP.
         double orphanTP = g_CurrentUpper;
         for(int k = g_CurrentLevels - 1; k >= 0; k--) {
            if(GridPrices[k] > openPrice) {
               orphanTP = GridPrices[k];
               break;
            }
         }
         if(curBid >= orphanTP) {
            if(trade.PositionClose(t)) {
               if(InpEnableTradeLog) LogTrade("TP_CLOSE_ORPHAN", 0, curBid, 0, t);
               Print("PA23: Orphaned position #", t, " closed at TP $",
                     DoubleToString(curBid, (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS)),
                     " | Entry: $", DoubleToString(openPrice, (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS)),
                     " | Orphan TP: $", DoubleToString(orphanTP, (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS)));
            }
         }
      }
   }
}

void CalculateDashboardStats()
{
   g_Z1.count = 0; g_Z1.profit = 0; g_Z1.volume = 0; g_Z1.avgPrice = 0;
   g_Z2.count = 0; g_Z2.profit = 0; g_Z2.volume = 0; g_Z2.avgPrice = 0;
   g_Z3.count = 0; g_Z3.profit = 0; g_Z3.volume = 0; g_Z3.avgPrice = 0;
   
   for(int i=0; i<3; i++) {
      g_WorstPositions[i].ticket = 0;
      g_WorstPositions[i].level = 0;
      g_WorstPositions[i].loss = 0;
      g_WorstPositions[i].price = 0;
      g_WorstPositions[i].distPct = 0;
   }
   
   g_BreakEvenPrice = 0.0;
   g_DeepestLevel = 0;
   g_DeepestPrice = 0.0;
   g_HighestLevel = 0;
   g_HighestPrice = 0.0;
   g_NextLevelPrice = 0.0;
   
   double totalVol = 0;
   double totalVolPrice = 0;
   double currentPrice = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   
   WorstPosition tempWorst[200]; // L08 fix: match MAX_GRID_LEVELS
   int worstCount = 0;
   
   for(int i=PositionsTotal()-1; i>=0; i--) {
      ulong t = PositionGetTicket(i);
      if(!PositionSelectByTicket(t)) continue;
      if(PositionGetInteger(POSITION_MAGIC) != InpMagicNumber) continue;
      
      double prof = PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP);
      double vol  = PositionGetDouble(POSITION_VOLUME);
      double open = PositionGetDouble(POSITION_PRICE_OPEN);
      int lvl = GetLevelIndex(open) + 1;
      
      totalVol += vol;
      totalVolPrice += (vol * open);
      
      if(lvl > g_DeepestLevel) {
         g_DeepestLevel = lvl;
         g_DeepestPrice = open;
      }
      if(g_HighestLevel == 0 || lvl < g_HighestLevel) {
         g_HighestLevel = lvl;
         g_HighestPrice = open;
      }
      
      if(prof < 0 && worstCount < 200) {
         tempWorst[worstCount].ticket = t;
         tempWorst[worstCount].level = lvl;
         tempWorst[worstCount].loss = prof;
         tempWorst[worstCount].price = open;
         tempWorst[worstCount].distPct = MathAbs((open - currentPrice) / currentPrice) * 100.0;
         worstCount++;
      }
      
      int z = GetZone(open);
      if(z==1) { g_Z1.count++; g_Z1.profit+=prof; g_Z1.volume+=vol; g_Z1.avgPrice+=(vol*open); }
      if(z==2) { g_Z2.count++; g_Z2.profit+=prof; g_Z2.volume+=vol; g_Z2.avgPrice+=(vol*open); }
      if(z==3) { g_Z3.count++; g_Z3.profit+=prof; g_Z3.volume+=vol; g_Z3.avgPrice+=(vol*open); }
   }
   
   for(int i=0; i<worstCount-1; i++) {
      for(int j=i+1; j<worstCount; j++) {
         if(tempWorst[j].loss < tempWorst[i].loss) {
            WorstPosition temp = tempWorst[i];
            tempWorst[i] = tempWorst[j];
            tempWorst[j] = temp;
         }
      }
   }
   
   for(int i=0; i<3 && i<worstCount; i++) {
      g_WorstPositions[i] = tempWorst[i];
   }
   
   if(totalVol > 0) g_BreakEvenPrice = totalVolPrice / totalVol;
   if(g_Z1.volume>0) g_Z1.avgPrice /= g_Z1.volume;
   if(g_Z2.volume>0) g_Z2.avgPrice /= g_Z2.volume;
   if(g_Z3.volume>0) g_Z3.avgPrice /= g_Z3.volume;
   
   for(int i=0; i<g_CurrentLevels; i++) {
      if(GridPrices[i] < currentPrice && g_LevelTickets[i] == 0) {
         g_NextLevelPrice = GridPrices[i];
         break;
      }
   }

   datetime startOfDay = iTime(_Symbol, PERIOD_D1, 0);
   datetime startOfWeek = iTime(_Symbol, PERIOD_W1, 0);
   
   if(TimeCurrent() - g_LastHistoryScan > 60) {
      g_DayPL = 0.0;
      g_WeekPL = 0.0;
      g_TradesToday = 0;
      g_WinsToday = 0;
      double totalWins = 0.0;
      double totalLosses = 0.0;
      int lossCount = 0;
      
      HistorySelect(startOfWeek, TimeCurrent());
      
      for(int i=0; i<HistoryDealsTotal(); i++) {
         ulong ticket = HistoryDealGetTicket(i);
         if(HistoryDealGetInteger(ticket, DEAL_MAGIC) != InpMagicNumber) continue;
         if(HistoryDealGetInteger(ticket, DEAL_ENTRY) != DEAL_ENTRY_OUT) continue;
         
         double res = HistoryDealGetDouble(ticket, DEAL_PROFIT) + 
                      HistoryDealGetDouble(ticket, DEAL_SWAP) + 
                      HistoryDealGetDouble(ticket, DEAL_COMMISSION);
         datetime dt = (datetime)HistoryDealGetInteger(ticket, DEAL_TIME);
         
         if(dt >= startOfWeek) g_WeekPL += res;
         if(dt >= startOfDay) {
            g_DayPL += res;
            g_TradesToday++;
            if(res > 0) {
               g_WinsToday++;
               totalWins += res;
            } else {
               totalLosses += res;
               lossCount++;
            }
         }
      }
      
      g_AvgWin = (g_WinsToday > 0) ? totalWins / g_WinsToday : 0;
      g_AvgLoss = (lossCount > 0) ? totalLosses / lossCount : 0;
      
      g_LastHistoryScan = TimeCurrent();
   }
   
   double bal = AccountInfoDouble(ACCOUNT_BALANCE);
   double eq = AccountInfoDouble(ACCOUNT_EQUITY);
   if(bal > 0) g_MaxDDPercent = ((bal - eq) / bal) * 100.0;
   else g_MaxDDPercent = 0.0;
   
   double bucketTimeHrs = (double)(TimeCurrent() - g_BucketStartTime) / 3600.0;
   if(bucketTimeHrs > 0) g_BucketFillRate = g_BucketTotal / bucketTimeHrs;
   else g_BucketFillRate = 0.0;
}

//--- Dashboard panel helpers ---
#define DASH_PREFIX  "GBE_"
#define DASH_FONT    "Consolas"
#define DASH_FSIZE   9
#define DASH_X       10
#define DASH_Y       25
#define DASH_LINE_H  16
#define DASH_PAD     8
#define DASH_WIDTH   420

void DashLabel(int row, string name, string txt, color clr = clrWhite)
{
   string objName = DASH_PREFIX + name;
   if(ObjectFind(0, objName) < 0) {
      ObjectCreate(0, objName, OBJ_LABEL, 0, 0, 0);
      ObjectSetInteger(0, objName, OBJPROP_CORNER, InpDashCorner);
      ObjectSetString(0, objName, OBJPROP_FONT, DASH_FONT);
      ObjectSetInteger(0, objName, OBJPROP_FONTSIZE, DASH_FSIZE);
      ObjectSetInteger(0, objName, OBJPROP_SELECTABLE, false);
      ObjectSetInteger(0, objName, OBJPROP_HIDDEN, true);
      ObjectSetInteger(0, objName, OBJPROP_BACK, false);  // foreground — renders in front of candles
      ObjectSetInteger(0, objName, OBJPROP_ZORDER, 10);
   }
   ObjectSetString(0, objName, OBJPROP_TEXT, txt);
   ObjectSetInteger(0, objName, OBJPROP_COLOR, clr);
   ObjectSetInteger(0, objName, OBJPROP_XDISTANCE, DASH_X + DASH_PAD);
   ObjectSetInteger(0, objName, OBJPROP_YDISTANCE, DASH_Y + DASH_PAD + row * DASH_LINE_H);
}

void DashBackground(int totalRows)
{
   string objName = DASH_PREFIX + "BG";
   if(ObjectFind(0, objName) < 0) {
      ObjectCreate(0, objName, OBJ_RECTANGLE_LABEL, 0, 0, 0);
      ObjectSetInteger(0, objName, OBJPROP_CORNER, InpDashCorner);
      ObjectSetInteger(0, objName, OBJPROP_SELECTABLE, false);
      ObjectSetInteger(0, objName, OBJPROP_HIDDEN, true);
      ObjectSetInteger(0, objName, OBJPROP_BORDER_TYPE, BORDER_FLAT);
      ObjectSetInteger(0, objName, OBJPROP_ZORDER, 0);
      ObjectSetInteger(0, objName, OBJPROP_BACK, true); // true = behind price bars; labels (BACK=false) float on top
   }
   ObjectSetInteger(0, objName, OBJPROP_XDISTANCE, DASH_X);
   ObjectSetInteger(0, objName, OBJPROP_YDISTANCE, DASH_Y);
   ObjectSetInteger(0, objName, OBJPROP_XSIZE, DASH_WIDTH);
   ObjectSetInteger(0, objName, OBJPROP_YSIZE, DASH_PAD * 2 + totalRows * DASH_LINE_H + 4);
   ObjectSetInteger(0, objName, OBJPROP_BGCOLOR, C'20,20,30');
   ObjectSetInteger(0, objName, OBJPROP_BORDER_COLOR, C'60,60,80');
}

void DashCleanup()
{
   int total = ObjectsTotal(0, 0, -1);
   for(int i = total - 1; i >= 0; i--) {
      string name = ObjectName(0, i);
      if(StringFind(name, DASH_PREFIX) == 0)
         ObjectDelete(0, name);
   }
   Comment("");
}

void UpdateDashboard()
{
   if(!InpShowDashboard) return;

   static datetime lastUpdate = 0;
   if(TimeCurrent() - lastUpdate < 5) return;

   string status = IsTradingActive ? "RUNNING" : "STOPPED";
   color  statusClr = clrLime;
   if(IsGuardianActive)  { status = "FROZEN"; statusClr = clrRed; }
   else if(!IsTradingActive) { statusClr = clrRed; }

   double bal = AccountInfoDouble(ACCOUNT_BALANCE);
   double eq  = AccountInfoDouble(ACCOUNT_EQUITY);
   double curPrice = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   int activePos = PositionsTotal();
   string guardianStatus = IsGuardianActive ? "ACTIVE (Hedging)" : "Standby";
   bool inRange = (curPrice >= g_CurrentLower && curPrice <= g_CurrentUpper);

   double dayPct  = (bal > 0) ? (g_DayPL / bal) * 100 : 0;
   double weekPct = (bal > 0) ? (g_WeekPL / bal) * 100 : 0;
   double winRate = (g_TradesToday > 0) ? ((double)g_WinsToday / g_TradesToday) * 100 : 0;

   int r = 0;

   // --- Header ---
   DashLabel(r, "HDR",  "  GRIDBOT-EXECUTOR v10.08", clrDodgerBlue);                r++;

   // --- Time Display ---
   datetime brokerTime = TimeCurrent();
   datetime vpsTime    = TimeLocal();
   datetime pktTime    = TimeGMT() + 5 * 3600;  // Pakistan Standard Time = UTC+5
   DashLabel(r, "TME",  "  Broker: " + TimeToString(brokerTime, TIME_MINUTES) +
                         "  |  VPS: " + TimeToString(vpsTime, TIME_MINUTES) +
                         "  |  PKT: " + TimeToString(pktTime, TIME_MINUTES), clrGray); r++;

   DashLabel(r, "STS",  "  Status: " + status + "  |  Guardian: " + guardianStatus, statusClr); r++;

   // Tier 3: Auto-range mode indicator
   if(g_UsingAutoDefaults) {
      DashLabel(r, "AUTO", "  ⚠️ AUTO-RANGE MODE - USE PLANNER TO OPTIMIZE!", clrOrange); r++;
   }

   DashLabel(r, "S1",   "  ___________________________________________", C'60,60,80'); r++;

   // --- Account ---
   DashLabel(r, "BAL",  "  Balance: $" + DoubleToString(bal, 0) +
                         "  |  Equity: $" + DoubleToString(eq, 0), clrWhite);        r++;
   DashLabel(r, "DD",   "  DD: " + DoubleToString(g_MaxDDPercent, 2) + "%" +
                         "  |  Positions: " + IntegerToString(activePos) +
                         "/" + IntegerToString(g_CurrentLevels), clrSilver);          r++;
   int effSpread = (g_RuntimeMaxSpread > 0) ? g_RuntimeMaxSpread : InpMaxSpread;
   long curSpread = SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);
   color spClr = (curSpread > effSpread) ? clrRed : clrGray;
   DashLabel(r, "SPR",  "  Spread: " + IntegerToString(curSpread) +
                         "  |  Max: " + IntegerToString(effSpread) + " pts" +
                         (g_RuntimeMaxSpread > 0 ? " (Planner)" : " (Manual)"), spClr); r++;
   DashLabel(r, "S2",   "  ___________________________________________", C'60,60,80'); r++;

   // --- Grid ---
   DashLabel(r, "GRD",  "  Grid: $" + DoubleToString(g_CurrentLower, 2) +
                         " - $" + DoubleToString(g_CurrentUpper, 2) +
                         "  |  Coeff: " + DoubleToString(g_ActiveExpansionCoeff, 4), clrSilver); r++;
   DashLabel(r, "PRC",  "  Price: $" + DoubleToString(curPrice, 2) +
                         "  |  " + (inRange ? "In Range" : "OUT OF RANGE!"),
                         inRange ? clrWhite : clrRed);                                r++;
   DashLabel(r, "BEV",  "  Break Even: $" + DoubleToString(g_BreakEvenPrice, 2), clrSilver); r++;
   DashLabel(r, "S3",   "  ___________________________________________", C'60,60,80'); r++;

   // --- Bucket ---
   DashLabel(r, "BKT",  "  Bucket: $" + DoubleToString(g_BucketTotal, 2) +
                         "  |  Dredged: $" + DoubleToString(g_TotalDredged, 2), clrAqua); r++;
   DashLabel(r, "EXP",  "  Net Exposure: " + DoubleToString(g_NetExposure, 2) + " lots", clrSilver); r++;
   DashLabel(r, "S4",   "  ___________________________________________", C'60,60,80'); r++;

   // --- P/L ---
   DashLabel(r, "DPL",  "  Today: $" + DoubleToString(g_DayPL, 2) +
                         " (" + DoubleToString(dayPct, 2) + "%)",
                         g_DayPL >= 0 ? clrLime : clrOrangeRed);                     r++;
   DashLabel(r, "WPL",  "  Week:  $" + DoubleToString(g_WeekPL, 2) +
                         " (" + DoubleToString(weekPct, 2) + "%)",
                         g_WeekPL >= 0 ? clrLime : clrOrangeRed);                    r++;
   DashLabel(r, "WIN",  "  Win Rate: " + IntegerToString(g_WinsToday) + "/" +
                         IntegerToString(g_TradesToday) +
                         " (" + DoubleToString(winRate, 0) + "%)", clrSilver);        r++;
   DashLabel(r, "S5",   "  ___________________________________________", C'60,60,80'); r++;

   // --- Zones ---
   DashLabel(r, "Z1",   "  Zone 1: " + IntegerToString(g_Z1.count) +
                         " pos  |  $" + DoubleToString(g_Z1.profit, 2), clrDodgerBlue); r++;
   DashLabel(r, "Z2",   "  Zone 2: " + IntegerToString(g_Z2.count) +
                         " pos  |  $" + DoubleToString(g_Z2.profit, 2), clrOrange);     r++;
   DashLabel(r, "Z3",   "  Zone 3: " + IntegerToString(g_Z3.count) +
                         " pos  |  $" + DoubleToString(g_Z3.profit, 2), clrOrangeRed);  r++;
   DashLabel(r, "S6",   "  ___________________________________________", C'60,60,80'); r++;

   // --- Worst positions ---
   DashLabel(r, "WH",   "  Worst Positions:", clrGray);                               r++;
   for(int i = 0; i < 3; i++) {
      string wKey = "W" + IntegerToString(i);
      if(g_WorstPositions[i].ticket > 0) {
         DashLabel(r, wKey, "   " + IntegerToString(i+1) + ". L" +
                  IntegerToString(g_WorstPositions[i].level) +
                  ": -$" + DoubleToString(MathAbs(g_WorstPositions[i].loss), 2) +
                  " @ $" + DoubleToString(g_WorstPositions[i].price, 2), clrOrangeRed);
      } else {
         DashLabel(r, wKey, "   " + IntegerToString(i+1) + ". ---", C'60,60,80');
      }
      r++;
   }

   // --- GUARDIAN section ---
   r++;
   DashLabel(r, "GD_SEP", "  -- GUARDIAN -----------------------", C'60,60,80'); r++;

   string ghHbKey = GetGuardianKey("HEARTBEAT_TS");
   if(GlobalVariableCheck(ghHbKey)) {
      int ghAge = (int)(TimeCurrent() - (datetime)GlobalVariableGet(ghHbKey));
      string ghAliveStr = (ghAge < 30) ? "[+] Alive: " + FormatAge(ghAge)
                                       : "[X] DEAD: " + FormatAge(ghAge);
      color ghHbClr = (ghAge < 30) ? clrLime : clrRed;
      DashLabel(r, "GD_HB", "  " + ghAliveStr, ghHbClr);
   } else {
      DashLabel(r, "GD_HB", "  Guardian: Not detected", C'80,80,80');
   }
   r++;

   double ghActive = GlobalVariableCheck(GetGuardianKey("ACTIVE")) ?
                     GlobalVariableGet(GetGuardianKey("ACTIVE")) : 0;
   int    ghStage  = (int)(GlobalVariableCheck(GetGuardianKey("STAGE")) ?
                     GlobalVariableGet(GetGuardianKey("STAGE")) : 0);
   if(ghActive > 0.5) {
      double ghVol = GlobalVariableCheck(GetGuardianKey("OPEN_VOL")) ?
                     GlobalVariableGet(GetGuardianKey("OPEN_VOL")) : 0;
      DashLabel(r, "GD_ST", "  HEDGE ACTIVE  Stage " + IntegerToString(ghStage) + "/3", clrRed); r++;
      DashLabel(r, "GD_VL", "  Vol: " + DoubleToString(ghVol, 2) + " lots", clrWhite); r++;
   } else {
      DashLabel(r, "GD_ST", "  STANDBY  (Monitoring)", clrLime); r++;
      DashLabel(r, "GD_VL", "", C'20,20,30'); r++;
   }

   double ghPeak = GlobalVariableCheck(GetGuardianKey("PEAK_EQUITY")) ?
                   GlobalVariableGet(GetGuardianKey("PEAK_EQUITY")) : 0;
   if(ghPeak > 0.01) {
      double ghDD = (ghPeak - AccountInfoDouble(ACCOUNT_EQUITY)) / ghPeak * 100.0;
      color  ghDDClr = (ghDD >= 22.2) ? clrRed : (ghDD >= 19.4) ? clrOrangeRed :
                       (ghDD >= 16.7) ? clrYellow : clrLime;
      DashLabel(r, "GD_PK", "  Peak: $" + DoubleToString(ghPeak, 0) +
                "  |  DD: " + DoubleToString(ghDD, 2) + "%", ghDDClr);
   } else {
      DashLabel(r, "GD_PK", "  Peak: ---", C'80,80,80');
   }
   r++;

   // --- PLANNER section ---
   r++;
   DashLabel(r, "PL_SEP", "  -- PLANNER ------------------------", C'60,60,80'); r++;

   string pushKey = GetGVKey("OPT_CMD_PushTime");
   if(GlobalVariableCheck(pushKey)) {
      datetime lastPush = (datetime)GlobalVariableGet(pushKey);
      int pushAge = (int)(TimeCurrent() - lastPush);
      DashLabel(r, "PL_PS", "  Last Push: " + FormatAge(pushAge), clrSilver);
   } else {
      DashLabel(r, "PL_PS", "  Last Push: Never", C'80,80,80');
   }
   r++;

   // --- Background panel ---
   DashBackground(r);

   lastUpdate = TimeCurrent();
}

void DrawBreakEvenLine()
{
   // L11 fix: only update when break-even price changes meaningfully
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

int GetZone(double price)
{
   if(price > g_OriginalZone1_Floor) return 1;
   if(price > g_OriginalZone2_Floor) return 2;
   return 3;
}

void SyncMemoryWithBroker()
{
   // H05 fix: rate-limit expensive slow-path to max every 2 seconds
   static datetime lastSlowSync = 0;
   bool allowSlowPath = (TimeCurrent() - lastSlowSync >= 2);

   for(int i=0; i<g_CurrentLevels; i++) {
      ulong currentTicket = g_LevelTickets[i];

      // --- FAST PATH: verify existing ticket is still active ---
      if(currentTicket > 0) {
         bool verified = false;
         if(OrderSelect(currentTicket) && OrderGetInteger(ORDER_STATE) == ORDER_STATE_PLACED)
            verified = true;
         if(!verified && PositionSelectByTicket(currentTicket) &&
            PositionGetInteger(POSITION_MAGIC) == InpMagicNumber)
            verified = true;
         if(verified) continue; // still valid, no change needed
      }

      // --- SLOW PATH: ticket missing or failed verify — search by price proximity ---
      if(!allowSlowPath) continue; // H05: skip expensive scan this tick
      // This handles the order->position ticket transition race condition and
      // broker-specific ticket assignment differences across all instruments.
      double target = GridPrices[i];
      double tol    = GridStepSize[i] * 0.4;
      ulong  found  = 0;

      // Priority 1: open positions (highest priority — already filled)
      for(int k = PositionsTotal()-1; k >= 0; k--) {
         ulong t = PositionGetTicket(k);
         if(!PositionSelectByTicket(t)) continue;
         if(PositionGetInteger(POSITION_MAGIC) != InpMagicNumber) continue;
         if(MathAbs(PositionGetDouble(POSITION_PRICE_OPEN) - target) < tol) { found = t; break; }
      }

      // Priority 2: pending orders (only if no position found at this level)
      if(found == 0) {
         for(int k = OrdersTotal()-1; k >= 0; k--) {
            ulong t = OrderGetTicket(k);
            if(!OrderSelect(t)) continue;
            if(OrderGetInteger(ORDER_MAGIC) != InpMagicNumber) continue;
            if(OrderGetInteger(ORDER_STATE) != ORDER_STATE_PLACED) continue;
            if(MathAbs(OrderGetDouble(ORDER_PRICE_OPEN) - target) < tol) { found = t; break; }
         }
      }

      if(found != g_LevelTickets[i]) {
         if(found > 0) Print("SYNC: Level ", i+1, " relinked #", found);
         else if(g_LevelTickets[i] > 0) Print("SYNC: Level ", i+1, " cleared (nothing at price)");
         g_LevelTickets[i] = found;
      }
   }
   if(allowSlowPath) lastSlowSync = TimeCurrent();
}

void ManageRollingTail()
{
   if(TimeCurrent() - g_LastTailTime < 2) return;
   
   int pend = 0;
   for(int i=0; i<g_CurrentLevels; i++) {
      if(g_LevelTickets[i] > 0 && OrderSelect(g_LevelTickets[i]) && OrderGetInteger(ORDER_STATE) == ORDER_STATE_PLACED) pend++;
   }
   
   if(pend <= InpMaxPendingOrders) return;
   
   int rem = pend - InpMaxPendingOrders;
   for(int i=g_CurrentLevels-1; i>=0 && rem>0; i--) {
      if(g_LevelTickets[i] > 0 && OrderSelect(g_LevelTickets[i]) && OrderGetInteger(ORDER_STATE) == ORDER_STATE_PLACED) {
         if(trade.OrderDelete(g_LevelTickets[i])) { g_LevelTickets[i] = 0; rem--; }
      }
   }
   
   g_LastTailTime = TimeCurrent();
}

int GetLevelIndex(double price)
{
   for(int i=0; i<g_CurrentLevels; i++) {
      double tol = GridStepSize[i] * 0.4;
      if(MathAbs(price - GridPrices[i]) < tol) return i;
   }
   return -1;
}

void MapSystemToGrid()
{
   for(int i=0; i<g_CurrentLevels; i++) {
      if(g_LevelTickets[i] > 0) continue;
      
      double target = GridPrices[i];
      double tol = GridStepSize[i] * 0.4;
      
      for(int k=OrdersTotal()-1; k>=0; k--) {
         ulong tk = OrderGetTicket(k);
         if(tk && OrderSelect(tk) && OrderGetInteger(ORDER_MAGIC)==InpMagicNumber) {
            if(MathAbs(OrderGetDouble(ORDER_PRICE_OPEN) - target) < tol) {
               g_LevelTickets[i] = tk;
               break;
            }
         }
      }
      
      if(g_LevelTickets[i] == 0) {
         for(int k=PositionsTotal()-1; k>=0; k--) {
            ulong tk = PositionGetTicket(k);
            if(tk && PositionSelectByTicket(tk) && PositionGetInteger(POSITION_MAGIC)==InpMagicNumber) {
               if(MathAbs(PositionGetDouble(POSITION_PRICE_OPEN) - target) < tol) {
                  g_LevelTickets[i] = tk;
                  break;
               }
            }
         }
      }
   }
}

double NormalizeLot(double lot)
{
   double n = MathFloor(lot / STEP_LOT) * STEP_LOT;
   if(n < MIN_LOT) n = MIN_LOT;
   if(n > MAX_LOT) n = MAX_LOT;
   return NormalizeDouble(n, 2);
}

ENUM_ORDER_TYPE_FILLING GetFillingMode()
{
   int f = (int)SymbolInfoInteger(_Symbol, SYMBOL_FILLING_MODE);
   if((f & SYMBOL_FILLING_FOK) == SYMBOL_FILLING_FOK) return ORDER_FILLING_FOK;
   if((f & SYMBOL_FILLING_IOC) == SYMBOL_FILLING_IOC) return ORDER_FILLING_IOC;
   return ORDER_FILLING_RETURN;
}

void CloseAllPositions()
{
   // L07 fix: retry failed closes up to 3 times
   for(int attempt = 0; attempt < 3; attempt++) {
      bool allClosed = true;
      for(int i=PositionsTotal()-1; i>=0; i--) {
         ulong t = PositionGetTicket(i);
         if(PositionSelectByTicket(t) && PositionGetInteger(POSITION_MAGIC) == InpMagicNumber) {
            if(!trade.PositionClose(t)) {
               Print("CloseAllPositions: failed to close #", t, " (attempt ", attempt+1, ") RC=", trade.ResultRetcode());
               allClosed = false;
            }
         }
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
      if(OrderSelect(t) && OrderGetInteger(ORDER_MAGIC) == InpMagicNumber) {
         trade.OrderDelete(t);
      }
   }
   ArrayInitialize(g_LevelTickets, 0);
}

void ScanForRealizedProfits()
{
   datetime now = TimeCurrent();
   // M05 fix: throttle HistorySelect to max every 2 seconds
   if(now - g_LastHistoryCheck < 2) return;
   if(!HistorySelect(g_LastHistoryCheck, now)) return;

   // Pass 1: collect closing deals (before HistorySelectByPosition changes the buffer)
   ulong  closeDealTickets[];
   double closeDealProfits[];
   long   closeDealPosIds[];
   datetime closeDealTimes[];
   double closeDealPrices[];
   int count = 0;

   for(int i = 0; i < HistoryDealsTotal(); i++) {
      ulong t = HistoryDealGetTicket(i);
      if(t == 0) continue;
      datetime dealTime = (datetime)HistoryDealGetInteger(t, DEAL_TIME);
      if(dealTime < g_LastHistoryCheck) continue;
      if(HistoryDealGetInteger(t, DEAL_MAGIC) != InpMagicNumber) continue;
      if(HistoryDealGetInteger(t, DEAL_ENTRY) != DEAL_ENTRY_OUT) continue;
      double profit = HistoryDealGetDouble(t, DEAL_PROFIT) + HistoryDealGetDouble(t, DEAL_SWAP) + HistoryDealGetDouble(t, DEAL_COMMISSION);
      if(profit <= 0) continue;

      ArrayResize(closeDealTickets, count + 1);
      ArrayResize(closeDealProfits, count + 1);
      ArrayResize(closeDealPosIds,  count + 1);
      ArrayResize(closeDealTimes,   count + 1);
      ArrayResize(closeDealPrices,  count + 1);
      closeDealTickets[count] = t;
      closeDealProfits[count] = profit;
      closeDealPosIds[count]  = (long)HistoryDealGetInteger(t, DEAL_POSITION_ID);
      closeDealTimes[count]   = dealTime;
      closeDealPrices[count]  = HistoryDealGetDouble(t, DEAL_PRICE);
      count++;
   }

   // Pass 2: resolve open price per deal (zone = where position OPENED, not closed)
   for(int i = 0; i < count; i++) {
      double openPrice = 0;
      long posId = closeDealPosIds[i];
      if(posId > 0 && HistorySelectByPosition(posId)) {
         for(int j = 0; j < HistoryDealsTotal(); j++) {
            ulong entryTicket = HistoryDealGetTicket(j);
            if(entryTicket > 0 && HistoryDealGetInteger(entryTicket, DEAL_ENTRY) == DEAL_ENTRY_IN
               && HistoryDealGetInteger(entryTicket, DEAL_POSITION_ID) == posId) {
               openPrice = HistoryDealGetDouble(entryTicket, DEAL_PRICE);
               break;
            }
         }
      }
      // Fallback: use close price if entry deal not found
      if(openPrice <= 0) openPrice = closeDealPrices[i];

      if(GetZone(openPrice) >= 2) {
         AddToBucket(closeDealProfits[i], closeDealTimes[i]);
      }
   }
   
   g_LastHistoryCheck = now;
}

void AddToBucket(double amount, datetime dealTime)
{
   // M06 fix: cap BucketQueue to prevent unbounded growth
   const int MAX_BUCKET_ITEMS = 1000;
   if(ArraySize(g_BucketQueue) >= MAX_BUCKET_ITEMS) {
      CleanExpiredBucketItems();
   }

   int s = ArraySize(g_BucketQueue);
   ArrayResize(g_BucketQueue, s + 1);
   g_BucketQueue[s].amount = amount;
   g_BucketQueue[s].time = dealTime;
   g_BucketTotal += amount;
   
   SaveSystemState();
}

bool SpendFromBucket(double req)
{
   if(g_BucketTotal < req) return false;
   
   double rem = req;
   for(int i=0; i<ArraySize(g_BucketQueue) && rem>0; i++) {
      if(g_BucketQueue[i].amount >= rem) {
         g_BucketQueue[i].amount -= rem;
         rem = 0;
      } else {
         rem -= g_BucketQueue[i].amount;
         g_BucketQueue[i].amount = 0;
      }
   }
   
   RecalculateBucketTotal();
   SaveSystemState();
   
   return (rem <= 0.01);
}

void RecalculateBucketTotal()
{
   g_BucketTotal = 0;
   for(int i=0; i<ArraySize(g_BucketQueue); i++) g_BucketTotal += g_BucketQueue[i].amount;
}

void CleanExpiredBucketItems()
{
   if(ArraySize(g_BucketQueue) == 0) return;
   
   datetime cutoff = TimeCurrent() - (InpBucketRetentionHrs * 3600);
   BucketItem temp[];
   int count = 0;
   
   for(int i=0; i<ArraySize(g_BucketQueue); i++) {
      if(g_BucketQueue[i].time >= cutoff && g_BucketQueue[i].amount > 0.001) {
         ArrayResize(temp, count + 1);
         temp[count] = g_BucketQueue[i];
         count++;
      }
   }
   
   if(ArraySize(temp) != ArraySize(g_BucketQueue)) {
      ArrayFree(g_BucketQueue);
      ArrayCopy(g_BucketQueue, temp);
      RecalculateBucketTotal();
      SaveSystemState();
   }
}

void DrawGhostLines()
{
   for(int i=0; i<g_CurrentLevels; i++) {
      string name = "GhostLine_" + IntegerToString(i);
      
      if(ObjectFind(0, name) < 0) {
         ObjectCreate(0, name, OBJ_HLINE, 0, 0, GridPrices[i]);
         int z = GetZone(GridPrices[i]);
         color lineColor = (z==1) ? InpColorZone1 : (z==2) ? InpColorZone2 : InpColorZone3;
         ObjectSetInteger(0, name, OBJPROP_COLOR, lineColor);
         ObjectSetInteger(0, name, OBJPROP_STYLE, STYLE_DOT);
         ObjectSetInteger(0, name, OBJPROP_WIDTH, 1);
         ObjectSetInteger(0, name, OBJPROP_BACK, true);
         ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
      } else {
         ObjectSetDouble(0, name, OBJPROP_PRICE, GridPrices[i]);
      }
   }
}

void LogTrade(string action, int level, double price, double lot, ulong ticket)
{
   if(InpEnableTradeLog) {
      string log = TimeToString(TimeCurrent(), TIME_DATE|TIME_SECONDS) + " | " + action;
      if(level > 0) log += " | L" + IntegerToString(level);
      if(price > 0) log += " | $" + DoubleToString(price, DIGITS);
      if(lot > 0) log += " | " + DoubleToString(lot, 2) + " lots";
      if(ticket > 0) log += " | #" + IntegerToString(ticket);
      Print(log);
   }
   WriteLog(action, level, price, lot, ticket);
}
//+------------------------------------------------------------------+
//| CSV File Logger                                                  |
//+------------------------------------------------------------------+
void WriteLog(string event, int level=0, double price=0, double lot=0,
              ulong ticket=0, string notes="")
{
   if(!InpEnableFileLog) return;
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   string dateStr = StringFormat("%04d-%02d-%02d", dt.year, dt.mon, dt.day);
   string fn = "GridBot_" + _Symbol + "_" + dateStr + ".csv";
   int h = FileOpen(fn, FILE_WRITE|FILE_READ|FILE_TXT|FILE_ANSI|FILE_SHARE_READ|FILE_SHARE_WRITE);
   if(h == INVALID_HANDLE) {
      if(InpEnableTradeLog) Print("WriteLog: FileOpen failed for ", fn, " err=", GetLastError());
      return;
   }
   if(FileSize(h) == 0)
      FileWrite(h, "Timestamp,Bot,Event,Symbol,Level,Price,Lot,Ticket,Equity,Balance,Peak,DD_Pct,Notes");
   FileSeek(h, 0, SEEK_END);
   double equity  = AccountInfoDouble(ACCOUNT_EQUITY);
   double balance = AccountInfoDouble(ACCOUNT_BALANCE);
   double dd      = (g_PeakEquity > 0) ? (g_PeakEquity - equity) / g_PeakEquity * 100.0 : 0.0;
   StringReplace(notes, ",", ";");
   string row = StringFormat("%s,EXECUTOR,%s,%s,%d,%.5f,%.2f,%I64u,%.2f,%.2f,%.2f,%.2f,%s",
      TimeToString(TimeCurrent(), TIME_DATE|TIME_SECONDS),
      event, _Symbol, level, price, lot, ticket,
      equity, balance, g_PeakEquity, dd, notes);
   FileWrite(h, row);
   FileClose(h);
}
//+------------------------------------------------------------------+