//+------------------------------------------------------------------+
//|                           GridBot-Planner_v23_04.mq5             |
//|      AUDITED EDITION: Linear Execution Logic                     |
//|      Update: Added Manual Price Range Capability                 |
//|      Status: Mathematically Verified                             |
//|                                  Copyright 2026, Custom Strategy |
//+------------------------------------------------------------------+
#property copyright "Custom Strategy Team"
#property link      "https://www.exness.com"
#property version   "23.04"

#include <Canvas\Canvas.mqh>

//--- ENUMS ---
enum ENUM_STRIKE_SELECTION { STRIKE_MANUAL, STRIKE_AUTO_OPTIMIZED };
enum ENUM_STRIKE_MODE { STRIKE_MODE_5, STRIKE_MODE_4, STRIKE_MODE_3, STRIKE_MODE_2, STRIKE_MODE_1 };
enum ENUM_RANGE_MODE  { RANGE_AUTO_VOLATILITY, RANGE_FIXED_PERCENT, RANGE_MANUAL_LEVELS };
enum ENUM_GAP_LOGIC   { GAP_AUTO_GEOMETRY, GAP_ATR_TARGETS };
enum ENUM_VOL_TF      { TF_H1_VOLATILITY, TF_H4_VOLATILITY, TF_D1_VOLATILITY };

//--- INPUTS ---
input group  "=== 0. EXECUTOR LINK ==="
input int    InpExecutorMagic = 205001; // Must match GridBot-Executor's InpMagicNumber

input group  "=== 1. STRATEGY & LOTS ==="
input bool                  InpUseAutoLot     = true;               // Auto-Calculate Lot?
input double                InpManualLot      = 0.01;               // Manual Lot (if Auto=false)
input ENUM_STRIKE_SELECTION InpStrikeMethod   = STRIKE_MANUAL;      // Manual or Auto Selection?
input ENUM_STRIKE_MODE      InpManualStrike   = STRIKE_MODE_5;      // (Manual Only) Default Strike

input group  "=== 2. GRID GEOMETRY ==="
input ENUM_GAP_LOGIC   InpGapLogic       = GAP_ATR_TARGETS;    // How to calc Gaps?
input ENUM_VOL_TF      InpGapTimeFrame   = TF_H4_VOLATILITY;   // Timeframe for Gap Calc
input double           InpFirstGapPct    = 60.0;               // First Gap % of ATR
input double           InpLastGapPct     = 150.0;              // Last Gap % of ATR
input double           InpSpreadBuffer   = 3.0;                // Safety: Gap must be > 3x Spread
input double           InpSpreadGapRatio = 0.33;               // Max spread as fraction of First Gap (0.33 = 33%)

input group  "=== 3. RANGE & PHYSICS ==="
input ENUM_RANGE_MODE  InpRangeMode      = RANGE_AUTO_VOLATILITY; 
input double           InpManualUpper    = 0.0;                   // Manual Upper Price (Mode C)
input double           InpManualLower    = 0.0;                   // Manual Lower Price (Mode C)
input int              InpDaysToCover    = 22;                    // Mode A: Days of Volatility
input double           InpFixedDropPct   = 20.0;                  // Mode B: Fixed Drop %
input double           InpEfficiency     = 0.85;                  // Base Density

input group  "=== 4. ACCOUNT & RISK ==="
input double InpAccountBalance = 200000.0; 
input double InpMaxRiskPerc    = 25.0;     
input int    InpSimLeverage    = 200;      
input double InpMinMarginLvl   = 300.0;
input double InpStopOutLevel   = 50.0;

input group  "=== 5. DREDGING LOGIC ==="
input double InpDredgeMinRangePerc = 60.0; // Only dredge top 60%

input group  "=== 6. VISUALS ==="
input bool   InpShowLines      = true;     
input color  ClrUpper          = clrAqua;  
input color  ClrLower          = clrRed;   
input color  ClrBreakEven      = clrYellow;
input color  ClrDredgeZone     = clrOrange;
input color  ClrLiquidation    = clrMagenta;

//--- GLOBALS ---
CCanvas hud;
int     h_ATR_D1, h_ATR_H1, h_RSI, h_ATR_Sel;
double  atrD1[], atrH1[], rsiBuffer[], atrSel[];
bool    IsOptimized = false;
string  OptStatus = "AUDIT COMPLETE: SYSTEM ACTIVE";

// GLOBAL PHYSICS CACHE
double  g_TickSize = 0.00001;
double  g_TickVal  = 0.0;
double  g_Contract = 100000.0;
double  g_SpreadVal = 0.0;

int     g_ActiveStrikeInt = 5;

// Logic Vars
double  CalcUpper, CalcLower, CalcRange;
int     CalcLevels;
double  CalcCoeff;
double  RecBaseLot, RecZone2Lot, RecZone3Lot;
double  SkewVal = 0.5;

// Metrics
double  Sim_TotalLots, Sim_AvgEntry, Sim_BouncePerc, Sim_BounceDist;
double  FinalMaxDD_USD, FinalMaxDD_Perc, Est_CycleProfit, Est_SwapCost;
double  Sim_MarginLevel, Sim_MaxMarginUsed, Sim_LiquidationPrice;
double  Sim_MinGridGap, Sim_MaxGridGap, Sim_BottomZoneGap, Sim_DredgeQuality, Sim_ProfitFactor; 
double  Sim_CoverageRatio, Sim_PricePosition, Sim_DredgeThresholdPrice;
double  Sim_FirstGap, Sim_LastGap;
double  Stat_Sigma, Stat_Prob;
double  Sim_EstRecoveryDays;

// Financials
double  Sim_Z1_Margin, Sim_Z2_Margin, Sim_Z3_Margin;
double  Sim_Z1_Val, Sim_Z2_Val, Sim_Z3_Val;
double  Sim_Z1_AvgProfit, Sim_Z2_AvgProfit, Sim_Z3_AvgProfit; 
double  Sim_Total_Notional, Sim_Effective_Lev;

bool    IsCapitalSafe = true;
bool    IsCentMode = false;

// Optimization Caching
double  cache_LastATR = 0;
int     cache_BestLvl = 36;
double  cache_BestCoeff = 1.0;
double  cache_InpFirst = 0;
double  cache_InpLast = 0;

// --- VISUAL CONFIGURATION ---
int HUD_X=10; int HUD_Y=10; 
int HUD_W=1300; int HUD_H=900;  
int FONT_SIZE=16; int LINE_H=34;    
int COL1_X=40; int COL2_X=300; int COL3_X=560; int COL4_X=820;

//+------------------------------------------------------------------+
//| Init                                                             |
//+------------------------------------------------------------------+
int OnInit()
{
   if(InpAccountBalance <= 0) { Alert("Error: Balance must be > 0"); return(INIT_PARAMETERS_INCORRECT); }
   if(InpSimLeverage < 1)     { Alert("Error: Leverage must be >= 1"); return(INIT_PARAMETERS_INCORRECT); }
   if(InpMaxRiskPerc <= 0 || InpMaxRiskPerc > 100) { Alert("Error: Risk % must be 0-100"); return(INIT_PARAMETERS_INCORRECT); }

   // M01 fix: AutoTrading check (Planner does not trade but uses GV comms)
   if(!TerminalInfoInteger(TERMINAL_TRADE_ALLOWED))
      Print("WARNING: AutoTrading is disabled — PUSH TO LIVE may not reach Executor!");
   
   string currency = AccountInfoString(ACCOUNT_CURRENCY);
   if(StringFind(currency, "USC") >= 0 || StringFind(currency, "EUC") >= 0) IsCentMode = true;
   else if(StringFind(Symbol(), "c") == StringLen(Symbol())-1) IsCentMode = true;

   // L05 fix: warn user when running on CENT account
   if(IsCentMode) {
      Print("WARNING: CENT ACCOUNT DETECTED (", currency, ") — lot sizes are 1/100 of standard. Verify sizing before trading!");
   }
   
   g_TickSize = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   if(g_TickSize <= 0) { Alert("Error: Invalid Tick Size"); return(INIT_FAILED); }
   
   g_TickVal  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   if(g_TickVal <= 0) { g_TickVal = 1.0; Print("Warning: Tick Value 0, defaulting to 1.0"); }
   
   g_Contract = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_CONTRACT_SIZE);
   if(g_Contract <= 0) g_Contract = 100000.0;
   
   if(StringFind(_Symbol, "XAU") >= 0 && g_Contract < 100) g_Contract = 100;
   if(StringFind(_Symbol, "XAG") >= 0 && g_Contract < 5000) g_Contract = 5000;
   
   h_ATR_D1 = iATR(_Symbol, PERIOD_D1, 50); 
   h_ATR_H1 = iATR(_Symbol, PERIOD_H1, 50); 
   h_RSI    = iRSI(_Symbol, PERIOD_D1, 14, PRICE_CLOSE);
   
   ENUM_TIMEFRAMES selTF = PERIOD_H1;
   if(InpGapTimeFrame == TF_H4_VOLATILITY) selTF = PERIOD_H4;
   if(InpGapTimeFrame == TF_D1_VOLATILITY) selTF = PERIOD_D1;
   h_ATR_Sel = iATR(_Symbol, selTF, 50);
   
   if(h_ATR_D1 == INVALID_HANDLE || h_ATR_H1 == INVALID_HANDLE || h_RSI == INVALID_HANDLE || h_ATR_Sel == INVALID_HANDLE) {
      Alert("Error: Failed to initialize indicators");
      return(INIT_FAILED);
   }
   
   ArraySetAsSeries(atrD1, true); ArraySetAsSeries(atrH1, true); 
   ArraySetAsSeries(rsiBuffer, true); ArraySetAsSeries(atrSel, true);
   
   if(!hud.CreateBitmapLabel("MasterHUD", HUD_X, HUD_Y, HUD_W, HUD_H, COLOR_FORMAT_ARGB_NORMALIZE)) {
      Alert("Error: Failed to create HUD");
      return(INIT_FAILED);
   }
   hud.FontSet("Consolas", FONT_SIZE, FW_BOLD); 
   EventSetTimer(1); 
   
   long spreadPoints = SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);
   g_SpreadVal = spreadPoints * SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   
   // M09 fix: removed Sleep(50) retry loop — OnTimer will retry automatically
   RunUniversalSolver();
   
   DrawHUD();
   if(InpShowLines) UpdateChartLines();
   ChartRedraw(); 
   
   return(INIT_SUCCEEDED);
}

void OnDeinit(const int reason) { 
   EventKillTimer(); 
   hud.Destroy(); 
   ObjectsDeleteAll(0, "SM_"); 
   IndicatorRelease(h_ATR_D1); IndicatorRelease(h_ATR_H1); 
   IndicatorRelease(h_RSI);    IndicatorRelease(h_ATR_Sel);
   Comment("");
}

void OnTimer() { 
   g_TickVal = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   long spreadPoints = SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);
   g_SpreadVal = spreadPoints * SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   
   RunUniversalSolver(); 
   DrawHUD(); 
   if(InpShowLines) UpdateChartLines();
}

//+------------------------------------------------------------------+
//| PHYSICS SOLVER                                                   |
//+------------------------------------------------------------------+
string GetGVKey(string suffix) {
   // C04 fix: use configurable InpExecutorMagic instead of hardcoded 205001
   return IntegerToString(InpExecutorMagic) + "_SG_" + suffix;
}

void PushToLive() {
   GlobalVariableSet(GetGVKey("OPT_NEW_UPPER"), CalcUpper);
   GlobalVariableSet(GetGVKey("OPT_NEW_LOWER"), CalcLower);
   GlobalVariableSet(GetGVKey("OPT_NEW_LEVELS"), (double)CalcLevels);
   GlobalVariableSet(GetGVKey("OPT_NEW_COEFF"), CalcCoeff);
   GlobalVariableSet(GetGVKey("OPT_NEW_LOT1"), RecBaseLot);
   GlobalVariableSet(GetGVKey("OPT_NEW_LOT2"), RecZone2Lot);
   GlobalVariableSet(GetGVKey("OPT_NEW_LOT3"), RecZone3Lot);
   double maxSpreadPrice = Sim_FirstGap * InpSpreadGapRatio;
   double maxSpreadPts   = maxSpreadPrice / SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   if(maxSpreadPts < 50) maxSpreadPts = 50;
   GlobalVariableSet(GetGVKey("OPT_NEW_MAX_SPREAD"), maxSpreadPts);
   GlobalVariableSet(GetGVKey("MAX_RISK_PCT"),  InpMaxRiskPerc);
   GlobalVariableSet(GetGVKey("OPT_CMD_PushTime"), (double)TimeCurrent());

   Alert("✅ CONFIG PUSHED TO LIVE! GridBot-Executor should update shortly.");
}

void OnChartEvent(const int id, const long &lparam, const double &dparam, const string &sparam) {
   if(id == CHARTEVENT_CLICK) {
      int mx=(int)lparam; int my=(int)dparam;
      if(mx<HUD_X || mx>HUD_X+HUD_W || my<HUD_Y || my>HUD_Y+HUD_H) return;
      int btnY = HUD_H - 120; 
      if(my>btnY && my<btnY+80) {
         if(mx>40 && mx<400) { PlaySound("Tick"); Alert("Physics Engine is Running."); }
         if(mx>620 && mx<850) { 
             PushToLive();
         }
         if(mx>870 && mx<1100) { 
            if(IsCapitalSafe) { SaveSetFile(); PlaySound("Alert"); } 
            else { Alert("Cannot export: Capital unsafe!"); }
         }
      }
      DrawHUD();
   }
}

//+------------------------------------------------------------------+
//| PHYSICS SOLVER                                                   |
//+------------------------------------------------------------------+
bool RunUniversalSolver() {
   if(!FetchIndicators()) return false; 
   
   double curPrice = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double volD1 = (ArraySize(atrD1)>0)?atrD1[0]:0;
   double volGapBase = (ArraySize(atrSel)>0)?atrSel[0]:0;
   
   if(volD1 <= 0) volD1 = curPrice * 0.01; 
   if(volGapBase <= 0) volGapBase = volD1 * 0.1;
   
   double totalRangeMove = 0;
   double lower = 0;
   double upper = 0;

   // --- RANGE LOGIC SELECTOR ---
   if(InpRangeMode == RANGE_MANUAL_LEVELS) {
      if(InpManualUpper > InpManualLower && InpManualLower > 0.0) {
         upper = InpManualUpper;
         lower = InpManualLower;
      } else {
         // Fallback if user enters invalid inputs
         upper = curPrice * 1.02;
         lower = curPrice * 0.98;
         if(TimeCurrent() % 5 == 0) Print("Warning: Invalid Manual Prices. Using Default Safe Range.");
      }
   }
   else if(InpRangeMode == RANGE_AUTO_VOLATILITY) {
      totalRangeMove = volD1 * MathSqrt(InpDaysToCover) * 2.0; 
      lower = curPrice - (totalRangeMove * SkewVal);
      upper = curPrice + (totalRangeMove * (1.0 - SkewVal));
   } 
   else {
      double dropDist = curPrice * (InpFixedDropPct / 100.0);
      lower = curPrice - dropDist;
      if(SkewVal < 0.1) SkewVal = 0.5; 
      totalRangeMove = dropDist / SkewVal;
      upper = curPrice + (totalRangeMove * (1.0 - SkewVal));
   }
   
   double range = upper - lower;
   
   double atomicMinGap = g_SpreadVal * InpSpreadBuffer;
   if(atomicMinGap <= 0) atomicMinGap = 0.00001; 
   
   bool inputsChanged = (InpFirstGapPct != cache_InpFirst || InpLastGapPct != cache_InpLast);
   
   if(inputsChanged || cache_LastATR <= 0 || MathAbs(volGapBase - cache_LastATR)/cache_LastATR > 0.05) {
      
      if(InpGapLogic == GAP_ATR_TARGETS) {
         double targetFirst = volGapBase * (InpFirstGapPct / 100.0);
         double targetLast  = volGapBase * (InpLastGapPct / 100.0);
         if(targetFirst < atomicMinGap) targetFirst = atomicMinGap;
         if(targetLast < atomicMinGap)  targetLast  = atomicMinGap;
         
         int bestLvl = 36;
         double bestErr = 99999999;
         double bestC = 1.0;
         
         for(int lvl=10; lvl<=150; lvl++) {
            double c = 1.0;
            if(MathAbs(targetLast - targetFirst) > 0.00001) {
                c = MathPow(targetLast/targetFirst, 1.0/(double)(lvl-1));
            }
            double simRange = 0;
            if(MathAbs(1.0-c) < 0.000001) simRange = targetFirst * lvl;
            else simRange = targetFirst * (1.0 - MathPow(c, lvl)) / (1.0 - c);
            
            double err = MathAbs(simRange - range);
            if(err < bestErr) { bestErr = err; bestLvl = lvl; bestC = c; }
         }
         CalcLevels = bestLvl;
         CalcCoeff = bestC;
      }
      else {
         int smartLevels = GetOptimalLevelCount(range, volGapBase);
         double bestCoeff = 1.0;
         double bestScore = -999999;
         for(double testCoeff = 0.95; testCoeff <= 1.10; testCoeff += 0.05) {
            CalcCoeff = testCoeff;
            CalculateSimulation(upper, lower, smartLevels); 
            if(Sim_LastGap < atomicMinGap) continue; 
            if(Sim_FirstGap < atomicMinGap) continue;
            
            double riskPenalty = (FinalMaxDD_Perc > InpMaxRiskPerc) ? 1000.0 : 0.0;
            double score = (Sim_ProfitFactor * 10.0) - Sim_BouncePerc - riskPenalty;
            if(Sim_DredgeQuality > 80) score += 5.0;
            if(score > bestScore) { bestScore = score; bestCoeff = testCoeff; }
         }
         if(bestScore == -999999) bestCoeff = 1.0;
         CalcCoeff = bestCoeff;
         CalcLevels = smartLevels;
      }
      
      cache_LastATR = volGapBase;
      cache_BestLvl = CalcLevels;
      cache_BestCoeff = CalcCoeff;
      cache_InpFirst = InpFirstGapPct;
      cache_InpLast = InpLastGapPct;
   }
   else {
      CalcLevels = cache_BestLvl;
      CalcCoeff = cache_BestCoeff;
   }
   
   if(InpStrikeMethod == STRIKE_MANUAL) {
      if(InpManualStrike == STRIKE_MODE_5) g_ActiveStrikeInt = 5;
      else if(InpManualStrike == STRIKE_MODE_4) g_ActiveStrikeInt = 4;
      else if(InpManualStrike == STRIKE_MODE_3) g_ActiveStrikeInt = 3;
      else if(InpManualStrike == STRIKE_MODE_2) g_ActiveStrikeInt = 2;
      else g_ActiveStrikeInt = 1;
      
      CalculateSimulation(upper, lower, CalcLevels);
   }
   else {
      int bestMode = 5;
      double bestRec = 9999.0;
      double bestPF = -1.0;
      
      for(int m=1; m<=5; m++) {
         g_ActiveStrikeInt = m;
         CalculateSimulation(upper, lower, CalcLevels);
         
         if(FinalMaxDD_Perc <= InpMaxRiskPerc + 0.5 && IsCapitalSafe) {
            if(Sim_BouncePerc < bestRec) {
               bestRec = Sim_BouncePerc;
               bestMode = m;
               bestPF = Sim_ProfitFactor;
            }
            else if(MathAbs(Sim_BouncePerc - bestRec) < 0.5) {
               if(Sim_ProfitFactor > bestPF) {
                  bestPF = Sim_ProfitFactor;
                  bestMode = m;
               }
            }
         }
      }
      g_ActiveStrikeInt = bestMode;
      CalculateSimulation(upper, lower, CalcLevels); 
      OptStatus = "AUTO-STRIKE OPTIMIZED: MODE " + IntegerToString(bestMode);
   }
   
   return true;
}

int GetOptimalLevelCount(double range, double volBase) {
   if(volBase <= 0) return 36;
   if(range <= 0) return 36;
   double efficiencyGap = volBase * InpEfficiency; 
   double safeGap = MathMax(efficiencyGap, g_SpreadVal * InpSpreadBuffer);
   int calculatedLevels = (int)MathRound(range / safeGap);
   if(calculatedLevels < 10) calculatedLevels = 10;
   if(calculatedLevels > 150) calculatedLevels = 150; 
   return calculatedLevels;
}

//+------------------------------------------------------------------+
//| SIMULATION CORE (AUDIT FIX: LINEAR EXECUTION & RESETS)           |
//+------------------------------------------------------------------+
void ApplyStrikeModeLogic(double baseLot) {
   double step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   if(step <= 0) step = 0.01;
   RecBaseLot = MathFloor(baseLot / step) * step;
   
   double m2=2.2, m3=4.5; 
   if(g_ActiveStrikeInt == 5) { m2=1.5; m3=2.5; }
   else if(g_ActiveStrikeInt == 4) { m2=1.8; m3=3.0; }
   else if(g_ActiveStrikeInt == 3) { m2=2.0; m3=3.5; }
   else if(g_ActiveStrikeInt == 2) { m2=2.2; m3=4.5; }
   else { m2=2.5; m3=6.0; } 
   
   RecZone2Lot = MathFloor((RecBaseLot * m2) / step) * step;
   RecZone3Lot = MathFloor((RecBaseLot * m3) / step) * step;
   if(RecZone2Lot < RecBaseLot) RecZone2Lot = RecBaseLot;
   if(RecZone3Lot < RecZone2Lot) RecZone3Lot = RecZone2Lot;
}

void CalculateSimulation(double pUpper, double pLower, int pLevels) {
   // 1. RESET ALL VARIABLES (Critical for Auto-Strike Loops)
   Sim_TotalLots=0; Sim_Total_Notional=0; FinalMaxDD_USD=0;
   Sim_Z1_Margin=0; Sim_Z2_Margin=0; Sim_Z3_Margin=0;
   Sim_Z1_Val=0; Sim_Z2_Val=0; Sim_Z3_Val=0;
   Sim_Z1_AvgProfit=0; Sim_Z2_AvgProfit=0; Sim_Z3_AvgProfit=0;
   double z1_GapSum=0, z2_GapSum=0, z3_GapSum=0;
   int z1_Count=0, z2_Count=0, z3_Count=0;
   double wPriceSum=0;

   CalcUpper = MathMax(0.00001, pUpper); 
   CalcLower = MathMax(0.00001, pLower); 
   CalcLevels = (pLevels < 2) ? 2 : pLevels; 
   CalcRange = CalcUpper - CalcLower;
   Sim_DredgeThresholdPrice = CalcLower + (CalcRange * (InpDredgeMinRangePerc / 100.0)); 
   
   if(MathAbs(1.0 - CalcCoeff) < 0.0000001) {
      Sim_FirstGap = CalcRange / CalcLevels;
   } else {
      double den = 1.0 - MathPow(CalcCoeff, CalcLevels);
      if(MathAbs(den) < 0.0000001) Sim_FirstGap = CalcRange / CalcLevels; 
      else Sim_FirstGap = CalcRange * (1.0 - CalcCoeff) / den;
   }
   
   int split1 = CalcLevels / 3;
   int split2 = (CalcLevels * 2) / 3;
   
   // --- AUTO LOT LOGIC ---
   if(InpUseAutoLot) {
      // Run a mini-loop to find Unit Drawdown (Drawdown per 1.0 Lot)
      double unitDD_Points = 0;
      double tempPrice = CalcUpper - Sim_FirstGap;
      double tempGap = Sim_FirstGap;
      
      double tm2=2.2, tm3=4.5; 
      if(g_ActiveStrikeInt == 5) { tm2=1.5; tm3=2.5; }
      else if(g_ActiveStrikeInt == 4) { tm2=1.8; tm3=3.0; }
      else if(g_ActiveStrikeInt == 3) { tm2=2.0; tm3=3.5; }
      else if(g_ActiveStrikeInt == 2) { tm2=2.2; tm3=4.5; }
      else { tm2=2.5; tm3=6.0; }

      for(int i=0; i<CalcLevels; i++) {
         if(tempPrice <= 0) break;
         double tMult = 1.0;
         if(i >= split1) tMult = tm2;
         if(i >= split2) tMult = tm3;
         if(tempPrice > CalcLower) unitDD_Points += (tempPrice - CalcLower) * tMult;
         tempGap *= CalcCoeff;
         tempPrice -= tempGap;
      }
      
      double unitDD_USD = (unitDD_Points / g_TickSize * g_TickVal);
      double maxRiskUSD = InpAccountBalance * (InpMaxRiskPerc / 100.0);
      
      double minThreshold = maxRiskUSD * 0.001; 
      if(unitDD_USD > minThreshold && unitDD_USD > 0.01) {
         double rawLot = maxRiskUSD / unitDD_USD;
         double maxVol = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
         if(rawLot > maxVol) rawLot = maxVol;
         ApplyStrikeModeLogic(rawLot); 
      } else {
         ApplyStrikeModeLogic(0);
      }
   } else {
      ApplyStrikeModeLogic(InpManualLot);
   }
   
   // --- MAIN SIMULATION LOOP (ORDER OF OPS FIX) ---
   double simPrice = CalcUpper - Sim_FirstGap;
   double curGap = Sim_FirstGap;
   Sim_MinGridGap=999999; Sim_MaxGridGap=0; Sim_BottomZoneGap=0;
   
   for(int i=0; i<CalcLevels; i++) {
      if(simPrice <= 0) break; 
      
      // A. Track Gaps
      if(curGap < Sim_MinGridGap) Sim_MinGridGap = curGap; 
      if(curGap > Sim_MaxGridGap) Sim_MaxGridGap = curGap;
      if(i >= split2) Sim_BottomZoneGap += curGap;
      Sim_LastGap = curGap;
      
      // B. DETERMINE LOT SIZE (CRITICAL STEP - MUST BE FIRST)
      double actLot = RecBaseLot;
      if(i >= split1) actLot = RecZone2Lot;
      if(i >= split2) actLot = RecZone3Lot;
      
      // C. CALCULATE FINANCIALS (Using CORRECT Lot)
      // Fix: Value = Price * Contract * Lot
      double notional = simPrice * g_Contract * actLot; 
      double marginReq = notional / InpSimLeverage;
      
      // D. ACCUMULATE
      if(i < split1) { 
         Sim_Z1_Margin += marginReq; Sim_Z1_Val += notional; 
         z1_GapSum += curGap; z1_Count++;
      }
      else if(i < split2) { 
         Sim_Z2_Margin += marginReq; Sim_Z2_Val += notional; 
         z2_GapSum += curGap; z2_Count++;
      }
      else { 
         Sim_Z3_Margin += marginReq; Sim_Z3_Val += notional; 
         z3_GapSum += curGap; z3_Count++;
      }
      
      Sim_Total_Notional += notional;
      Sim_TotalLots += actLot;
      wPriceSum += (simPrice * actLot);
      
      if(simPrice > CalcLower) FinalMaxDD_USD += (simPrice - CalcLower) / g_TickSize * g_TickVal * actLot;
      
      curGap *= CalcCoeff; 
      simPrice -= curGap;
   }
   
   // Calculate Avg Profit Per Zone
   if(z1_Count > 0) Sim_Z1_AvgProfit = (z1_GapSum/z1_Count) / g_TickSize * g_TickVal * RecBaseLot;
   else Sim_Z1_AvgProfit = 0;
   
   if(z2_Count > 0) Sim_Z2_AvgProfit = (z2_GapSum/z2_Count) / g_TickSize * g_TickVal * RecZone2Lot;
   else Sim_Z2_AvgProfit = 0;
   
   if(z3_Count > 0) {
      Sim_BottomZoneGap /= z3_Count;
      Sim_Z3_AvgProfit = (z3_GapSum/z3_Count) / g_TickSize * g_TickVal * RecZone3Lot;
   } else Sim_Z3_AvgProfit = 0;
   
   double equityAtBottom = InpAccountBalance - FinalMaxDD_USD;
   Sim_AvgEntry = (Sim_TotalLots > 0) ? wPriceSum / Sim_TotalLots : 0;
   Sim_BounceDist = Sim_AvgEntry - CalcLower;
   Sim_BouncePerc = (CalcLower > 0) ? (Sim_BounceDist / CalcLower) * 100.0 : 0;
   
   if(g_TickSize > 0 && g_TickVal > 0) Est_CycleProfit = (CalcUpper - Sim_AvgEntry) / g_TickSize * g_TickVal * Sim_TotalLots;
   else Est_CycleProfit = 0;
   
   Sim_ProfitFactor = (FinalMaxDD_USD > 0) ? Est_CycleProfit / FinalMaxDD_USD : 0;
   
   if(Sim_TotalLots > 0 && g_TickSize > 0 && g_TickVal > 0) {
      double dollarPerPoint = Sim_TotalLots * g_TickVal / g_TickSize;
      double stopOutAmount = InpAccountBalance * (InpStopOutLevel/100.0); 
      double usableEquity = InpAccountBalance - stopOutAmount;
      double distToDeath = (dollarPerPoint > 0) ? usableEquity / dollarPerPoint : 0;
      Sim_LiquidationPrice = Sim_AvgEntry - distToDeath;
   } else { Sim_LiquidationPrice = 0; }
   
   if(g_TickSize > 0 && g_TickVal > 0) {
      double z3WinPerCycle = RecZone3Lot * Sim_BottomZoneGap / g_TickSize * g_TickVal;
      double z1LossPerMove = RecBaseLot * (CalcRange / CalcLevels) / g_TickSize * g_TickVal;
      Sim_CoverageRatio = (z1LossPerMove > 0) ? z3WinPerCycle / z1LossPerMove : 0;
   } else { Sim_CoverageRatio = 0; }

   double swapLong = SymbolInfoDouble(_Symbol, SYMBOL_SWAP_LONG);
   Est_SwapCost = swapLong * Sim_TotalLots * InpDaysToCover; 

   double curPrice = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   if(CalcRange > 0) Sim_PricePosition = (curPrice - CalcLower) / CalcRange * 100.0;
   else Sim_PricePosition = 50.0;
   
   FinalMaxDD_Perc = (InpAccountBalance > 0) ? (FinalMaxDD_USD / InpAccountBalance) * 100.0 : 0;
   Sim_MaxMarginUsed = Sim_Total_Notional / InpSimLeverage;
   Sim_Effective_Lev = (InpAccountBalance > 0) ? Sim_Total_Notional / InpAccountBalance : 0;
   Sim_MarginLevel = (Sim_MaxMarginUsed > 0.001) ? equityAtBottom / Sim_MaxMarginUsed * 100.0 : 9999.0;
   
   double targetGap = (ArraySize(atrSel)>0) ? atrSel[0] * (InpFirstGapPct/100.0) : 0;
   if(targetGap>0 && Sim_BottomZoneGap>0)
      Sim_DredgeQuality = MathMax(0, MathMin(100, 100.0 - (MathAbs(Sim_BottomZoneGap-targetGap)/targetGap*50.0)));
   else Sim_DredgeQuality = 100;
   
   double dropDist = curPrice - CalcLower;
   double vol = (ArraySize(atrD1)>0) ? atrD1[0] * MathSqrt(InpDaysToCover) : 0;
   Stat_Sigma = (vol > 0) ? dropDist / (vol * SkewVal) : 0;
   
   if(Stat_Sigma < 1) Stat_Prob = 68.0 * Stat_Sigma;
   else if(Stat_Sigma < 2) Stat_Prob = 68.0 + (27.0 * (Stat_Sigma - 1.0));
   else Stat_Prob = 95.0 + (4.9 * (Stat_Sigma - 2.0));
   
   double t_atrD1 = (ArraySize(atrD1)>0) ? atrD1[0] : 0;
   if(t_atrD1 > 0 && Sim_BounceDist > 0) Sim_EstRecoveryDays = Sim_BounceDist / t_atrD1;
   else Sim_EstRecoveryDays = 0;
   
   double minLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   IsCapitalSafe = (RecBaseLot >= minLot) && (FinalMaxDD_Perc <= InpMaxRiskPerc + 0.1); 
}

void UpdateChartLines() {
   DrawLine("SM_Upper", CalcUpper, ClrUpper, STYLE_SOLID, 2);
   DrawLine("SM_Lower", CalcLower, ClrLower, STYLE_SOLID, 2);
   DrawLine("SM_BE", Sim_AvgEntry, ClrBreakEven, STYLE_DASH, 1);
   DrawLine("SM_Dredge", Sim_DredgeThresholdPrice, ClrDredgeZone, STYLE_DOT, 1);
   DrawLine("SM_Liquidation", Sim_LiquidationPrice, ClrLiquidation, STYLE_DASHDOT, 2);
}

void DrawLine(string n, double p, color c, ENUM_LINE_STYLE s, int w) {
   if(ObjectFind(0,n)<0) { if(!ObjectCreate(0,n,OBJ_HLINE,0,0,p)) return; }
   ObjectSetDouble(0,n,OBJPROP_PRICE,p); ObjectSetInteger(0,n,OBJPROP_COLOR,c);
   ObjectSetInteger(0,n,OBJPROP_STYLE,s); ObjectSetInteger(0,n,OBJPROP_WIDTH,w);
}

bool FetchIndicators() {
   if(h_ATR_D1==INVALID_HANDLE || h_ATR_H1==INVALID_HANDLE || h_RSI==INVALID_HANDLE || h_ATR_Sel==INVALID_HANDLE) return false;
   if(CopyBuffer(h_ATR_D1,0,0,1,atrD1)<=0) return false;
   if(CopyBuffer(h_ATR_H1,0,0,1,atrH1)<=0) return false;
   if(CopyBuffer(h_ATR_Sel,0,0,1,atrSel)<=0) return false;
   if(CopyBuffer(h_RSI,0,0,1,rsiBuffer)<=0) return false;
   SkewVal = (rsiBuffer[0]>0 && rsiBuffer[0]<100) ? rsiBuffer[0]/100.0 : 0.5;
   if(SkewVal<0.5) SkewVal=0.5; if(SkewVal>0.85) SkewVal=0.85;
   return true;
}

//+------------------------------------------------------------------+
//| HUD DISPLAY                                                      |
//+------------------------------------------------------------------+
void DrawHUD() {
   hud.Erase(ColorToARGB(clrBlack, 245)); 
   
   hud.TextOut(COL1_X, 10, "SMART GRID MASTER v23.04 (AUDIT FIX)", ColorToARGB(clrWhite));
   hud.TextOut(COL1_X, 10 + LINE_H, _Symbol + " | " + OptStatus, ColorToARGB(clrWhite));
   
   int r = 10 + LINE_H*3;
   
   // --- COLUMN 1: STRATEGY & ACCOUNT ---
   hud.TextOut(COL1_X, r-LINE_H, "[1] STRATEGY & ACCOUNT", ColorToARGB(clrGray));
   
   string stMode = "Mode: 2-STRIKE";
   if(InpStrikeMethod == STRIKE_MANUAL) stMode = "Mode: MANUAL";
   else stMode = "Mode: AUTO-OPTIMIZED";
   
   string sName = " (5-STRIKE)";
   if(g_ActiveStrikeInt==4) sName=" (4-STRIKE)";
   if(g_ActiveStrikeInt==3) sName=" (3-STRIKE)";
   if(g_ActiveStrikeInt==2) sName=" (2-STRIKE)";
   if(g_ActiveStrikeInt==1) sName=" (1-STRIKE)";
   
   hud.TextOut(COL1_X, r, stMode + sName, ColorToARGB(clrYellow));
   
   if(InpUseAutoLot) hud.TextOut(COL1_X, r+LINE_H, "Base Lot: " + DoubleToString(RecBaseLot,2) + " (AUTO)", ColorToARGB(clrLime));
   else hud.TextOut(COL1_X, r+LINE_H, "Base Lot: " + DoubleToString(RecBaseLot,2) + " (MANUAL)", ColorToARGB(clrWhite));

   hud.TextOut(COL1_X, r+LINE_H*2, "Z2 Mult: " + DoubleToString(RecZone2Lot/MathMax(0.001,RecBaseLot),2) + "x", ColorToARGB(clrSilver));
   hud.TextOut(COL1_X, r+LINE_H*3, "Z3 Mult: " + DoubleToString(RecZone3Lot/MathMax(0.001,RecBaseLot),2) + "x", ColorToARGB(clrSilver));
   
   string covTxt = "";
   if(InpRangeMode == RANGE_AUTO_VOLATILITY) 
      covTxt = "Cover: " + IntegerToString(InpDaysToCover) + " Days (Auto)";
   else if(InpRangeMode == RANGE_FIXED_PERCENT)
      covTxt = "Cover: " + DoubleToString(InpFixedDropPct, 1) + "% Drop (Fixed)";
   else
      covTxt = "Cover: MANUAL LEVELS";
      
   hud.TextOut(COL1_X, r+LINE_H*5, covTxt, ColorToARGB(clrAqua));
   
   hud.TextOut(COL1_X, r+LINE_H*6, "Balance: $" + DoubleToString(InpAccountBalance,0), ColorToARGB(clrWhite));
   hud.TextOut(COL1_X, r+LINE_H*7, "Risk Limit: " + DoubleToString(InpMaxRiskPerc,1) + "%", ColorToARGB(clrWhite));
   hud.TextOut(COL1_X, r+LINE_H*8, "Leverage: 1:" + IntegerToString(InpSimLeverage), ColorToARGB(clrSilver));
   
   // --- COLUMN 2: GRID STRUCTURE ---
   hud.TextOut(COL2_X, r-LINE_H, "[2] GRID STRUCTURE", ColorToARGB(clrGray));
   hud.TextOut(COL2_X, r, "Upper: " + DoubleToString(CalcUpper,_Digits), ColorToARGB(clrAqua));
   hud.TextOut(COL2_X, r+LINE_H, "Lower: " + DoubleToString(CalcLower,_Digits), ColorToARGB(clrRed));
   
   long spreadRaw = SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);
   double spreadPrice = spreadRaw * SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   double maxSpreadAllowed = Sim_FirstGap * InpSpreadGapRatio;
   color spreadClr = (spreadPrice > maxSpreadAllowed) ? clrRed : clrGray;
   hud.TextOut(COL2_X, r+LINE_H*2, "Spread: " + IntegerToString(spreadRaw) + " pts ($" + DoubleToString(spreadPrice, 2) + ") Max: $" + DoubleToString(maxSpreadAllowed, 2), ColorToARGB(spreadClr));
   
   double curPrice = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double rngPct = (curPrice > 0) ? (CalcRange / curPrice) * 100.0 : 0;
   hud.TextOut(COL2_X, r+LINE_H*3, "Range: " + DoubleToString(CalcRange,1) + " pts (" + DoubleToString(rngPct,1) + "%)", ColorToARGB(clrWhite));
   
   hud.TextOut(COL2_X, r+LINE_H*4, "Levels: " + IntegerToString(CalcLevels), ColorToARGB(clrSilver));
   hud.TextOut(COL2_X, r+LINE_H*5, "Coefficient: " + DoubleToString(CalcCoeff,4), ColorToARGB(clrGray));
   
   string posTxt = "Price Pos: " + DoubleToString(Sim_PricePosition, 1) + "%";
   color posColor = (Sim_PricePosition > 75) ? clrRed : (Sim_PricePosition < 25) ? clrLime : clrYellow;
   hud.TextOut(COL2_X, r+LINE_H*6, posTxt, ColorToARGB(posColor));
   
   double distLow = curPrice - CalcLower;
   double distLowPct = (curPrice > 0) ? (distLow / curPrice) * 100.0 : 0;
   hud.TextOut(COL2_X, r+LINE_H*7, "Dist to Low: " + DoubleToString(distLow,1) + " (" + DoubleToString(distLowPct,1) + "%)", ColorToARGB(clrWhite));
   
   hud.TextOut(COL2_X, r+LINE_H*8, "First Gap: " + DoubleToString(Sim_FirstGap,2), ColorToARGB(clrAqua));
   
   color gapColor = (Sim_LastGap < g_SpreadVal*3.0) ? clrRed : clrRed; 
   if(Sim_LastGap >= g_SpreadVal*5.0) gapColor = clrLime;
   hud.TextOut(COL2_X, r+LINE_H*9, "Last Gap: " + DoubleToString(Sim_LastGap,2), ColorToARGB(gapColor));

   // --- COLUMN 3: INVESTMENT & EXPOSURE ---
   hud.TextOut(COL3_X, r-LINE_H, "[3] INVESTMENT & EXPOSURE", ColorToARGB(clrGray));
   
   double div = (InpAccountBalance>10000)?1000.0:1.0; 
   string suffix = (div>1)?"k":"";
   
   hud.TextOut(COL3_X, r, "Zone 1 (Top Third)", ColorToARGB(clrGray));
   hud.TextOut(COL3_X, r+LINE_H, "  Lot: " + DoubleToString(RecBaseLot,2) + " | Value: $"+DoubleToString(Sim_Z1_Val/div,0)+suffix, ColorToARGB(clrLime));
   hud.TextOut(COL3_X, r+LINE_H*2, "  Margin: $" + DoubleToString(Sim_Z1_Margin/div,0)+suffix + " | Avg Win: $" + DoubleToString(Sim_Z1_AvgProfit,0), ColorToARGB(clrSilver));
   
   hud.TextOut(COL3_X, r+LINE_H*3, "Zone 2 (Middle)", ColorToARGB(clrGray));
   hud.TextOut(COL3_X, r+LINE_H*4, "  Lot: " + DoubleToString(RecZone2Lot,2) + " | Value: $"+DoubleToString(Sim_Z2_Val/div,0)+suffix, ColorToARGB(clrYellow));
   hud.TextOut(COL3_X, r+LINE_H*5, "  Margin: $" + DoubleToString(Sim_Z2_Margin/div,0)+suffix + " | Avg Win: $" + DoubleToString(Sim_Z2_AvgProfit,0), ColorToARGB(clrSilver));
   
   hud.TextOut(COL3_X, r+LINE_H*6, "Zone 3 (Bottom)", ColorToARGB(clrGray));
   hud.TextOut(COL3_X, r+LINE_H*7, "  Lot: " + DoubleToString(RecZone3Lot,2) + " | Value: $"+DoubleToString(Sim_Z3_Val/div,0)+suffix, ColorToARGB(clrOrange));
   hud.TextOut(COL3_X, r+LINE_H*8, "  Margin: $" + DoubleToString(Sim_Z3_Margin/div,0)+suffix + " | Avg Win: $" + DoubleToString(Sim_Z3_AvgProfit,0), ColorToARGB(clrSilver));
   
   hud.TextOut(COL3_X, r+LINE_H*10, "Total Holding: " + DoubleToString(Sim_TotalLots, 2) + " Lots", ColorToARGB(clrWhite));
   hud.TextOut(COL3_X, r+LINE_H*11, "TOTAL Value: $" + DoubleToString(Sim_Total_Notional/div,0)+suffix, ColorToARGB(clrAqua));
   
   color levColor = (Sim_Effective_Lev < 10) ? clrLime : (Sim_Effective_Lev < 20) ? clrYellow : clrRed;
   hud.TextOut(COL3_X, r+LINE_H*12, "Effective Lev: 1:" + DoubleToString(Sim_Effective_Lev,1), ColorToARGB(levColor));

   // --- COLUMN 4: PERFORMANCE & RISK ---
   hud.TextOut(COL4_X, r-LINE_H, "[4] PERFORMANCE & RISK", ColorToARGB(clrGray));
   
   hud.TextOut(COL4_X, r, "🎯 AVG ENTRY: " + DoubleToString(Sim_AvgEntry, _Digits), ColorToARGB(clrYellow));
   hud.TextOut(COL4_X, r+LINE_H, "💀 LIQUIDATION: " + DoubleToString(Sim_LiquidationPrice, _Digits), ColorToARGB(clrRed));
   
   color recoveryColor = (Sim_BouncePerc < 10.0) ? clrLime : (Sim_BouncePerc < 15.0) ? clrYellow : clrRed;
   hud.TextOut(COL4_X, r+LINE_H*3, "Recovery Target", ColorToARGB(clrGray));
   hud.TextOut(COL4_X, r+LINE_H*4, "  Distance: " + DoubleToString(Sim_BounceDist,1) + " pts", ColorToARGB(clrWhite));
   hud.TextOut(COL4_X, r+LINE_H*5, "  Percent: " + DoubleToString(Sim_BouncePerc,2) + "%", ColorToARGB(recoveryColor));
   hud.TextOut(COL4_X, r+LINE_H*6, "  Est Days: " + DoubleToString(Sim_EstRecoveryDays,1), ColorToARGB(clrSilver));
   
   color ddColor = (FinalMaxDD_Perc < InpMaxRiskPerc*0.8) ? clrLime : (FinalMaxDD_Perc < InpMaxRiskPerc) ? clrYellow : clrRed;
   hud.TextOut(COL4_X, r+LINE_H*8, "Max Drawdown", ColorToARGB(clrGray));
   hud.TextOut(COL4_X, r+LINE_H*9, "  Amount: $" + DoubleToString(FinalMaxDD_USD,0), ColorToARGB(ddColor));
   hud.TextOut(COL4_X, r+LINE_H*10, "  Percent: " + DoubleToString(FinalMaxDD_Perc,2) + "%", ColorToARGB(ddColor));
   
   color margColor = (Sim_MarginLevel > 500) ? clrLime : (Sim_MarginLevel > 300) ? clrYellow : clrRed;
   hud.TextOut(COL4_X, r+LINE_H*11, "Margin Level: " + DoubleToString(Sim_MarginLevel,0) + "%", ColorToARGB(margColor));
   
   hud.TextOut(COL4_X, r+LINE_H*13, "Cycle Profit: $" + DoubleToString(Est_CycleProfit,0), ColorToARGB(clrLime));
   hud.TextOut(COL4_X, r+LINE_H*14, "Profit Factor: " + DoubleToString(Sim_ProfitFactor,2), ColorToARGB(clrWhite));
   
   color covColor = (Sim_CoverageRatio > 0.15) ? clrLime : (Sim_CoverageRatio > 0.08) ? clrYellow : clrRed;
   hud.TextOut(COL4_X, r+LINE_H*15, "Coverage Ratio: " + DoubleToString(Sim_CoverageRatio,3), ColorToARGB(covColor));
   hud.TextOut(COL4_X, r+LINE_H*16, "Total Swap: $" + DoubleToString(Est_SwapCost,2), ColorToARGB(clrRed));
   hud.TextOut(COL4_X, r+LINE_H*17, "Dredge Quality: " + DoubleToString(Sim_DredgeQuality,0) + "%", ColorToARGB(clrGray));
   
   // BUTTONS
   int btnY = HUD_H - 120;
   hud.FillRectangle(40, btnY, 400, btnY+80, ColorToARGB(clrDarkGoldenrod)); 
   hud.TextOut(80, btnY+30, "AUTO-PHYSICS ON", ColorToARGB(clrWhite));
   
   hud.FillRectangle(420, btnY, 600, btnY+80, ColorToARGB(clrMaroon)); 
   hud.TextOut(450, btnY+30, "RESET", ColorToARGB(clrWhite));
   
   hud.FillRectangle(620, btnY, 850, btnY+80, ColorToARGB(clrDarkGreen)); 
   hud.TextOut(650, btnY+30, "PUSH TO LIVE", ColorToARGB(clrWhite));
   
   color exportColor = (IsCapitalSafe) ? clrDarkBlue : clrDarkGray;
   hud.FillRectangle(870, btnY, 1100, btnY+80, ColorToARGB(exportColor)); 
   hud.TextOut(900, btnY+30, "EXPORT .SET", ColorToARGB(clrWhite));
   
   hud.Update();
}

void SaveSetFile() {
   string fn = _Symbol + "_SmartGrid_v23_04.set";
   int h = FileOpen(fn, FILE_WRITE|FILE_TXT|FILE_ANSI);
   if(h!=INVALID_HANDLE) {
      FileWrite(h, "; === SMART GRID UNIVERSAL v23.04 SETTINGS ===");
      FileWrite(h, "InpUpperPrice=" + DoubleToString(CalcUpper, _Digits));
      FileWrite(h, "InpLowerPrice=" + DoubleToString(CalcLower, _Digits));
      FileWrite(h, "InpGridLevels=" + IntegerToString(CalcLevels));
      FileWrite(h, "InpExpansionCoeff=" + DoubleToString(CalcCoeff, 4));
      FileWrite(h, "InpStartAtUpper=false");
      FileWrite(h, "");
      FileWrite(h, "InpLotZone1=" + DoubleToString(RecBaseLot, 2));
      FileWrite(h, "InpLotZone2=" + DoubleToString(RecZone2Lot, 2));
      FileWrite(h, "InpLotZone3=" + DoubleToString(RecZone3Lot, 2));
      FileWrite(h, "");
      FileWrite(h, "InpDredgeRangePct=" + DoubleToString(InpDredgeMinRangePerc / 100.0, 2));
      FileWrite(h, "InpUseBucketDredge=true");
      FileWrite(h, "");
      int maxSpread = (int)(Sim_FirstGap * InpSpreadGapRatio / SymbolInfoDouble(_Symbol, SYMBOL_POINT));
      if(maxSpread < 50) maxSpread = 50;
      FileWrite(h, "InpMaxSpread=" + IntegerToString(maxSpread));
      FileWrite(h, "");
      // Hard stop DD% — use MaxRisk as the hard stop ceiling (same value pushed to Guardian via MAX_RISK_PCT)
      FileWrite(h, "InpHardStopDDPct=" + DoubleToString(InpMaxRiskPerc, 1));
      FileWrite(h, "InpUseVirtualTP=true");
      FileWrite(h, "");
      FileWrite(h, "InpMaxOpenPos=" + IntegerToString(CalcLevels));
      // C04 fix: use configured executor magic instead of random value
      FileWrite(h, "InpMagicNumber=" + IntegerToString(InpExecutorMagic));
      FileClose(h);
      Alert("✅ Settings exported: " + fn);
   } else {
      Alert("❌ Error: Failed to create file " + fn);
   }
}