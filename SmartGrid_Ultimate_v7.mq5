//+------------------------------------------------------------------+
//|                               SmartGrid_Ultimate_v7_2.mq5        |
//|      FIX: Removed Invalid CTrade Setters                         |
//|      Status: ERROR-FREE COMPILATION                              |
//|                                  Copyright 2026, Custom Strategy |
//+------------------------------------------------------------------+
#property copyright "Custom Strategy Team"
#property link      "https://www.exness.com"
#property version   "7.20" 
#property strict

#include <Trade\Trade.mqh>
#include <Canvas\Canvas.mqh>

//--- INPUT PARAMETERS ---
input group "=== 1. Condensing Grid Settings ==="
input double   InpUpperPrice     = 56.0;     // Zone Top Price ($)
input double   InpLowerPrice     = 44.0;     // Zone Bottom Price ($)
input int      InpGridLevels     = 36;       // Grid Density
input double   InpExpansionCoeff = 0.9791;   // Spacing Coeff
input bool     InpStartAtUpper   = false;    

input group "=== 2. Stepped Volume Zones ==="
input double   InpLotZone1       = 0.02;     
input double   InpLotZone2       = 0.04;     
input double   InpLotZone3       = 0.08;     

input group "=== 3. Cash Flow Engine (The Bucket) ==="
input bool     InpUseBucketDredge= true;     
input int      InpBucketRetentionHrs = 48;   
input double   InpSurvivalRatio  = 0.5;      
input double   InpDredgeRangePct = 0.5;      
input bool     InpUseVirtualTP   = true;     

input group "=== 4. Risk & Safety ==="
input double   InpEquityStopVal  = 143605.0; 
input int      InpMaxOpenPos     = 40;       
input int      InpMaxSpread      = 1000;     
input int      InpMagicNumber    = 205001;   

input group "=== 5. Dashboard Settings ==="
input bool     InpShowDashboard  = true;     
input bool     InpShowGhostLines = true;     
input color    InpColorZone1     = clrDodgerBlue; 
input color    InpColorZone2     = clrOrange;     
input color    InpColorZone3     = clrRed;        

//--- STRUCTURES ---
struct BucketItem {
   double   amount;  
   datetime time;    
};

//--- GLOBALS ---
CTrade         trade;
CCanvas        hud;
BucketItem     g_BucketQueue[]; 
double         GridPrices[];
double         GridTPs[];
double         GridLots[];
double         GridStepSize[];   
ulong          g_LevelTickets[]; 
bool           g_LevelLock[];    

int            DIGITS;
double         POINT;
double         STEP_LOT, MIN_LOT, MAX_LOT;
double         g_TotalRangeDist = 0.0; 
bool           IsTradingActive = true; 
bool           IsPaused = false;
double         g_InitialBalance = 0.0;
double         g_BucketTotal = 0.0;          
datetime       g_LastHistoryCheck;           
double         g_TotalDredged = 0.0;         
double         g_Zone1_Floor, g_Zone2_Floor; 

// Canvas Coordinates
int HUD_X = 20; int HUD_Y = 20; int HUD_W = 600; int HUD_H = 340; 

//--- PROTOTYPES ---
void MapSystemToGrid();
void SyncMemoryWithBroker(); 
void CalculateCondensingGrid();
void DrawGhostLines();
void CreateDashboard();
void UpdateDashboard();
void CloseAllPositions();
void DeleteAllOrders();
ENUM_ORDER_TYPE_FILLING GetFillingMode();
int GetLevelIndex(double price);
double NormalizeLot(double lot);
void ManageExits(double currentBid);
int GetZone(double price);
void ManageBucketDredging();
void RecalculateBucketTotal();
void SpendFromBucket(double requiredAmount);
void CleanExpiredBucketItems();
void AddToBucket(double amount, datetime dealTime);
void ScanForRealizedProfits();
void ManageGridEntry(double ask);
bool IsLevelActive(int idx, double price); 

//+------------------------------------------------------------------+
//| Initialization                                                   |
//+------------------------------------------------------------------+
int OnInit()
{
   if(InpUpperPrice <= InpLowerPrice) { Alert("Error: Upper < Lower"); return(INIT_PARAMETERS_INCORRECT); }
   if(InpGridLevels < 2 || InpGridLevels > 1000) { Alert("Error: Grid Levels must be 2-1000"); return(INIT_PARAMETERS_INCORRECT); }
   if(InpExpansionCoeff <= 0 || InpExpansionCoeff > 2.0) { Alert("Error: Expansion Coeff must be >0 and <=2.0"); return(INIT_PARAMETERS_INCORRECT); }
   if(InpEquityStopVal <= 0) { Alert("Error: Equity Stop must be positive"); return(INIT_PARAMETERS_INCORRECT); }
   
   DIGITS   = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   POINT    = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   STEP_LOT = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   MIN_LOT  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   MAX_LOT  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   
   double normLot1 = NormalizeLot(InpLotZone1);
   double normLot2 = NormalizeLot(InpLotZone2);
   double normLot3 = NormalizeLot(InpLotZone3);
   if(normLot1 < MIN_LOT || normLot2 < MIN_LOT || normLot3 < MIN_LOT) { Alert("Error: Lot size below minimum"); return(INIT_PARAMETERS_INCORRECT); }

   trade.SetExpertMagicNumber(InpMagicNumber);
   trade.SetDeviationInPoints(50); 
   trade.SetTypeFilling(GetFillingMode());
   trade.SetAsyncMode(false); 
   
   g_TotalRangeDist = InpUpperPrice - InpLowerPrice;
   g_Zone1_Floor = InpUpperPrice - (g_TotalRangeDist / 3.0);
   g_Zone2_Floor = InpUpperPrice - ((g_TotalRangeDist / 3.0) * 2.0);
   
   if(g_InitialBalance == 0) g_InitialBalance = AccountInfoDouble(ACCOUNT_BALANCE);
   g_LastHistoryCheck = TimeCurrent();
   
   CalculateCondensingGrid();
   
   ArrayResize(g_LevelTickets, InpGridLevels);
   ArrayInitialize(g_LevelTickets, 0);
   ArrayResize(g_LevelLock, InpGridLevels);
   ArrayInitialize(g_LevelLock, false);
   
   MapSystemToGrid();
   
   if(InpShowDashboard) CreateDashboard();
   if(InpShowGhostLines) DrawGhostLines();
   
   EventSetTimer(1);
   return(INIT_SUCCEEDED);
}

void OnDeinit(const int reason) {
   EventKillTimer();
   hud.Destroy();
   ObjectsDeleteAll(0, "GhostLine_");
}

void OnChartEvent(const int id, const long &lparam, const double &dparam, const string &sparam) {
   if(id == CHARTEVENT_CLICK) {
      int mouseX = (int)lparam; int mouseY = (int)dparam;
      if(mouseX >= HUD_X && mouseX <= HUD_X + HUD_W && mouseY >= HUD_Y && mouseY <= HUD_Y + HUD_H) {
         if(mouseX >= HUD_X+430 && mouseX <= HUD_X+500 && mouseY >= HUD_Y+10 && mouseY <= HUD_Y+35) {
            IsPaused = !IsPaused; PlaySound("Tick"); UpdateDashboard();
         }
         if(mouseX >= HUD_X+510 && mouseX <= HUD_X+580 && mouseY >= HUD_Y+10 && mouseY <= HUD_Y+35) {
            if(MessageBox("CLOSE ALL?","PANIC", MB_YESNO|MB_ICONWARNING)==IDYES) {
               IsPaused = true; CloseAllPositions(); PlaySound("Alert");
            }
         }
      }
   }
}

//+------------------------------------------------------------------+
//| Main Tick                                                        |
//+------------------------------------------------------------------+
void OnTick()
{
   if(!IsTradingActive) return;

   // 1. Equity Check (Highest Priority)
   if(AccountInfoDouble(ACCOUNT_EQUITY) < InpEquityStopVal) {
      CloseAllPositions(); IsTradingActive = false; Print("CRITICAL: Equity Stop Hit."); return;
   }
   
   // 2. Spread Check
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   bool spreadOK = ((ask-bid)/POINT <= InpMaxSpread);
   
   // 3. Maintenance
   SyncMemoryWithBroker();
   
   if(InpUseBucketDredge) {
      ScanForRealizedProfits();
      CleanExpiredBucketItems();
   }

   // 4. Execution
   if(spreadOK) {
      if(!IsPaused) ManageGridEntry(ask);
      ManageExits(bid); 
      
      if(InpUseBucketDredge) ManageBucketDredging();
   }
}

//+------------------------------------------------------------------+
//| GRID CALCULATION                                                 |
//+------------------------------------------------------------------+
void CalculateCondensingGrid()
{
   ArrayResize(GridPrices, InpGridLevels);
   ArrayResize(GridTPs, InpGridLevels);
   ArrayResize(GridLots, InpGridLevels);
   ArrayResize(GridStepSize, InpGridLevels); 
   
   double range = InpUpperPrice - InpLowerPrice;
   double firstGap = 0;
   
   if(MathAbs(1.0 - InpExpansionCoeff) < 0.0001) {
      firstGap = range / InpGridLevels; // Linear
   } else {
      double num = range * (1 - InpExpansionCoeff);
      double den = 1 - MathPow(InpExpansionCoeff, InpGridLevels);
      if(MathAbs(den) < 0.0000001) firstGap = range / InpGridLevels; 
      else firstGap = num / den;
   }
   
   double currentPrice = InpUpperPrice;
   if(!InpStartAtUpper) currentPrice -= firstGap;
   double currentGap = firstGap;
   int split = InpGridLevels / 3;
   
   for(int i=0; i<InpGridLevels; i++) {
      GridPrices[i] = NormalizeDouble(currentPrice, DIGITS);
      if(i==0) GridTPs[i] = NormalizeDouble(currentPrice + currentGap, DIGITS);
      else     GridTPs[i] = GridPrices[i-1];
      
      GridStepSize[i] = currentGap;
      
      double rawLot = InpLotZone1;
      if(i < split) rawLot = InpLotZone1;
      else if(i < split * 2) rawLot = InpLotZone2;
      else rawLot = InpLotZone3;
      GridLots[i] = NormalizeLot(rawLot);
      
      currentGap *= InpExpansionCoeff;
      currentPrice -= currentGap;
   }
}

//+------------------------------------------------------------------+
//| PROFIT SCANNING                                                  |
//+------------------------------------------------------------------+
void ScanForRealizedProfits()
{
   datetime now = TimeCurrent();
   if(!HistorySelect(g_LastHistoryCheck + 1, now)) return;
   
   int total = HistoryDealsTotal();
   for(int i=0; i<total; i++) {
      ulong ticket = HistoryDealGetTicket(i);
      if(ticket == 0) continue; 
      
      if(HistoryDealGetInteger(ticket, DEAL_MAGIC) != InpMagicNumber) continue;
      if(HistoryDealGetInteger(ticket, DEAL_ENTRY) != DEAL_ENTRY_OUT) continue; 
      
      double profit = HistoryDealGetDouble(ticket, DEAL_PROFIT) + 
                      HistoryDealGetDouble(ticket, DEAL_SWAP) + 
                      HistoryDealGetDouble(ticket, DEAL_COMMISSION);
                      
      if(profit > 0) {
         double price = HistoryDealGetDouble(ticket, DEAL_PRICE);
         datetime time = (datetime)HistoryDealGetInteger(ticket, DEAL_TIME);
         int zone = GetZone(price);
         if(zone >= 2) AddToBucket(profit, time);
      }
   }
   g_LastHistoryCheck = now;
}

//+------------------------------------------------------------------+
//| BUCKET MANAGEMENT                                                |
//+------------------------------------------------------------------+
void AddToBucket(double amount, datetime dealTime) {
   int size = ArraySize(g_BucketQueue);
   ArrayResize(g_BucketQueue, size + 1);
   g_BucketQueue[size].amount = amount;
   g_BucketQueue[size].time   = dealTime;
   RecalculateBucketTotal();
}

void SpendFromBucket(double requiredAmount) {
   double remainingToPay = requiredAmount;
   int deadEntries = 0;
   
   for(int i=0; i<ArraySize(g_BucketQueue); i++) {
      if(remainingToPay <= 0.001) break;
      
      if(g_BucketQueue[i].amount >= remainingToPay) {
         g_BucketQueue[i].amount -= remainingToPay;
         remainingToPay = 0;
      } else {
         remainingToPay -= g_BucketQueue[i].amount;
         g_BucketQueue[i].amount = 0; // Mark as dead
         deadEntries++;
      }
   }
   
   if(deadEntries > 0) {
      int writeIdx = 0;
      for(int i=0; i<ArraySize(g_BucketQueue); i++) {
         if(g_BucketQueue[i].amount > 0.001) {
            g_BucketQueue[writeIdx] = g_BucketQueue[i];
            writeIdx++;
         }
      }
      ArrayResize(g_BucketQueue, writeIdx);
   }
   
   RecalculateBucketTotal();
}

void RecalculateBucketTotal() {
   g_BucketTotal = 0.0;
   for(int i=0; i<ArraySize(g_BucketQueue); i++) g_BucketTotal += g_BucketQueue[i].amount;
}

//+------------------------------------------------------------------+
//| DREDGING LOGIC                                                   |
//+------------------------------------------------------------------+
void ManageBucketDredging() {
   if(g_BucketTotal <= 0.1) return; 
   
   double currentBal = AccountInfoDouble(ACCOUNT_BALANCE);
   double cashFactor = (currentBal > g_InitialBalance) ? 1.0 : InpSurvivalRatio;
   double availableCash = g_BucketTotal * cashFactor;
   
   if(availableCash < 0.1) return;

   int worstTicket = 0; double worstLoss = 0.0;
   double currentPrice = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double thresholdDist = g_TotalRangeDist * InpDredgeRangePct; 
   
   for(int i=PositionsTotal()-1; i>=0; i--) {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0) continue; 
      if(!PositionSelectByTicket(ticket)) continue; 
      
      if(PositionGetInteger(POSITION_MAGIC) != InpMagicNumber) continue;
      double profit = PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP);
      double openPrice = PositionGetDouble(POSITION_PRICE_OPEN);
      double dist = MathAbs(openPrice - currentPrice);
      
      if(dist > thresholdDist) {
         if(profit < worstLoss) { worstLoss = profit; worstTicket = (int)ticket; }
      }
   }
   
   if(worstTicket > 0) {
      double lossAbs = MathAbs(worstLoss);
      if(availableCash > lossAbs && g_BucketTotal > lossAbs) {
         if(trade.PositionClose(worstTicket)) {
            Print("DREDGED: $", DoubleToString(worstLoss,2));
            SpendFromBucket(lossAbs); 
            g_TotalDredged += lossAbs;
            
            if(HistoryOrderSelect(worstTicket)) { 
               for(int k=0; k<InpGridLevels; k++) {
                  if(g_LevelTickets[k] == (ulong)worstTicket) {
                     g_LevelTickets[k] = 0; break;
                  }
               }
            }
            Sleep(100);
         }
      }
   }
}

//+------------------------------------------------------------------+
//| ENTRY LOGIC                                                      |
//+------------------------------------------------------------------+
void ManageGridEntry(double ask)
{
   int totalExposure = PositionsTotal() + OrdersTotal();
   if(totalExposure >= InpMaxOpenPos) return;

   for(int i=0; i<InpGridLevels; i++)
   {
      if(g_LevelTickets[i] > 0) continue;
      if(g_LevelLock[i]) continue; 

      double target = GridPrices[i];
      if(target <= 0) continue;

      if(ask > target)
      {
         g_LevelLock[i] = true;
         double tp = InpUseVirtualTP ? 0 : GridTPs[i]; 
         string commentID = "SG_L"+IntegerToString(i+1);
         
         // --- FIXED: Removed invalid SetResultRetcode/SetResultOrder calls ---
         
         bool res = trade.BuyLimit(GridLots[i], target, _Symbol, 0, tp, ORDER_TIME_GTC, 0, commentID);
         
         if(res && (trade.ResultRetcode() == TRADE_RETCODE_DONE || trade.ResultRetcode() == TRADE_RETCODE_PLACED)) {
            ulong ticket = trade.ResultOrder();
            if(ticket > 0) g_LevelTickets[i] = ticket;
         }
         
         g_LevelLock[i] = false;
         if(res) return;
      }
      else {
         g_LevelLock[i] = false;
      }
   }
}

//+------------------------------------------------------------------+
//| MEMORY SYNC                                                      |
//+------------------------------------------------------------------+
void SyncMemoryWithBroker()
{
   HistorySelect(0, TimeCurrent());
   
   for(int i=0; i<InpGridLevels; i++) 
   {
      ulong ticket = g_LevelTickets[i];
      if(ticket == 0) continue; 
      
      bool found = false;
      
      if(OrderSelect(ticket)) {
         if(OrderGetInteger(ORDER_STATE) == ORDER_STATE_PLACED) found = true;
      }
      
      if(!found) {
         if(PositionSelectByTicket(ticket)) {
            if(PositionGetInteger(POSITION_MAGIC) == InpMagicNumber) found = true;
         }
      }
      
      if(!found) {
         if(HistoryOrderSelect(ticket)) {
            long state = HistoryOrderGetInteger(ticket, ORDER_STATE);
            if(state == ORDER_STATE_FILLED) {
               long posID = HistoryOrderGetInteger(ticket, ORDER_POSITION_ID);
               if(PositionSelectByTicket(posID)) {
                  g_LevelTickets[i] = posID; 
                  found = true;
               }
            }
         }
      }
      
      if(!found) g_LevelTickets[i] = 0; 
   }
}

//+------------------------------------------------------------------+
//| MAPPING                                                          |
//+------------------------------------------------------------------+
void MapSystemToGrid()
{
   for(int i=0; i<InpGridLevels; i++) {
      double target = GridPrices[i];
      double step = (GridStepSize[i] > 0) ? GridStepSize[i] : 1.0;
      double tol = step * 0.20; 
      
      for(int k=OrdersTotal()-1; k>=0; k--) {
         ulong t = OrderGetTicket(k);
         if(t==0 || !OrderSelect(t)) continue;
         
         if(OrderGetInteger(ORDER_MAGIC)==InpMagicNumber) {
            if(MathAbs(OrderGetDouble(ORDER_PRICE_OPEN)-target) < tol) {
               g_LevelTickets[i] = t; break;
            }
         }
      }
      if(g_LevelTickets[i] > 0) continue;
      
      for(int k=PositionsTotal()-1; k>=0; k--) {
         ulong t = PositionGetTicket(k);
         if(t==0 || !PositionSelectByTicket(t)) continue;
         
         if(PositionGetInteger(POSITION_MAGIC)==InpMagicNumber) {
            if(MathAbs(PositionGetDouble(POSITION_PRICE_OPEN)-target) < tol) {
               g_LevelTickets[i] = t; break;
            }
         }
      }
   }
}

//+------------------------------------------------------------------+
//| EXITS                                                            |
//+------------------------------------------------------------------+
void ManageExits(double currentBid) {
   if(!InpUseVirtualTP) return;
   
   for(int i=PositionsTotal()-1; i>=0; i--) {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0 || !PositionSelectByTicket(ticket)) continue; 
      
      if(PositionGetInteger(POSITION_MAGIC) != InpMagicNumber) continue;
      
      double openPrice = PositionGetDouble(POSITION_PRICE_OPEN);
      int levelIdx = GetLevelIndex(openPrice);
      
      if(levelIdx >= 0) {
         double targetTP = GridTPs[levelIdx];
         if(currentBid >= targetTP) { 
            if(trade.PositionClose(ticket)) {
               g_LevelTickets[levelIdx] = 0;
               Sleep(100); 
            }
         }
      }
   }
}

//+------------------------------------------------------------------+
//| Helpers                                                          |
//+------------------------------------------------------------------+
int GetLevelIndex(double price) {
   for(int i=0; i<InpGridLevels; i++) {
      double step = (GridStepSize[i] > 0) ? GridStepSize[i] : 1.0;
      double tol = step * 0.20;
      if(MathAbs(price-GridPrices[i]) < tol) return i;
   }
   return -1;
}

void CleanExpiredBucketItems() {
   if(ArraySize(g_BucketQueue) == 0) return;
   datetime cutoffTime = TimeCurrent() - (InpBucketRetentionHrs * 3600);
   int itemsToRemove = 0;
   for(int i=0; i<ArraySize(g_BucketQueue); i++) {
      if(g_BucketQueue[i].time < cutoffTime) itemsToRemove++;
      else break; 
   }
   if(itemsToRemove > 0) {
      if(itemsToRemove == ArraySize(g_BucketQueue)) ArrayFree(g_BucketQueue);
      else ArrayRemove(g_BucketQueue, 0, itemsToRemove);
      RecalculateBucketTotal();
   }
}

int GetZone(double price) {
   if(price > g_Zone1_Floor) return 1; 
   if(price > g_Zone2_Floor) return 2; 
   return 3;                           
}

double NormalizeLot(double lot) {
   double n = MathFloor(lot/STEP_LOT)*STEP_LOT;
   if(n<MIN_LOT) n=MIN_LOT; if(n>MAX_LOT) n=MAX_LOT;
   return NormalizeDouble(n, 2);
}

ENUM_ORDER_TYPE_FILLING GetFillingMode() {
   int f = (int)SymbolInfoInteger(_Symbol, SYMBOL_FILLING_MODE);
   if((f&SYMBOL_FILLING_FOK)==SYMBOL_FILLING_FOK) return ORDER_FILLING_FOK;
   if((f&SYMBOL_FILLING_IOC)==SYMBOL_FILLING_IOC) return ORDER_FILLING_IOC;
   return ORDER_FILLING_RETURN;
}

bool IsLevelActive(int idx, double price) {
   // Legacy check preserved for safety, though mapped memory is primary
   return (g_LevelTickets[idx] > 0);
}

void CloseAllPositions() {
   for(int i=PositionsTotal()-1; i>=0; i--) {
      ulong t=PositionGetTicket(i);
      if(PositionGetInteger(POSITION_MAGIC)==InpMagicNumber) trade.PositionClose(t);
   }
   for(int i=OrdersTotal()-1; i>=0; i--) {
      ulong t=OrderGetTicket(i);
      if(OrderGetInteger(ORDER_MAGIC)==InpMagicNumber) trade.OrderDelete(t);
   }
}

void DeleteAllOrders() {
   for(int i=OrdersTotal()-1; i>=0; i--) {
      ulong t=OrderGetTicket(i);
      if(OrderGetInteger(ORDER_MAGIC)==InpMagicNumber) trade.OrderDelete(t);
   }
}

void OnTimer() {
   if(InpShowDashboard) UpdateDashboard();
}

void UpdateDashboard() {
   if(!InpShowDashboard) return;
   hud.Erase(ColorToARGB(clrBlack, 220)); 
   
   double bal = AccountInfoDouble(ACCOUNT_BALANCE);
   double eq  = AccountInfoDouble(ACCOUNT_EQUITY);
   double ddPerc = (bal > 0) ? ((bal-eq)/bal)*100 : 0;
   
   hud.TextOut(15, 10, "SMART GRID v7.2 - COMPILATION FIX", ColorToARGB(clrWhite));
   string status = IsTradingActive ? (IsPaused ? "[PAUSED]" : "[RUNNING]") : "[STOPPED]";
   hud.TextOut(350, 10, status, ColorToARGB(IsPaused ? clrGold : clrLime));

   hud.FillRectangle(430, 10, 500, 35, ColorToARGB(IsPaused?clrGold:clrDimGray));
   hud.TextOut(445, 13, IsPaused?"GO":"PAUSE", ColorToARGB(clrBlack));
   hud.FillRectangle(510, 10, 580, 35, ColorToARGB(clrRed));
   hud.TextOut(525, 13, "CLOSE", ColorToARGB(clrWhite));

   hud.TextOut(15, 50, "CASH FLOW (Rolling " + IntegerToString(InpBucketRetentionHrs) + "h)", ColorToARGB(clrWhite));
   color bucketCol = (g_BucketTotal > 0) ? clrLime : clrSilver;
   hud.TextOut(15, 75, "Bucket Cash: $" + DoubleToString(g_BucketTotal, 2), ColorToARGB(bucketCol));
   
   double curPrice = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   int curZone = GetZone(curPrice);
   string zStr = "ZONE " + IntegerToString(curZone);
   color zCol = (curZone==1)?InpColorZone1 : (curZone==2)?InpColorZone2 : InpColorZone3;
   hud.TextOut(15, 140, "CURRENT LOCATION: " + zStr, ColorToARGB(zCol));
   
   hud.TextOut(15, 275, "DD: "+DoubleToString(ddPerc,2)+"%", ColorToARGB((ddPerc<10)?clrLime:clrRed));
   
   hud.Update();
}

void CreateDashboard() {
   if(!hud.CreateBitmapLabel("SmartHUDv7_2", HUD_X, HUD_Y, HUD_W, HUD_H, COLOR_FORMAT_ARGB_NORMALIZE)) return;
   hud.FontSet("Calibri", 18); UpdateDashboard();
}

void DrawGhostLines() {
   for(int i=0; i<InpGridLevels; i++) {
      string name = "GhostLine_" + IntegerToString(i);
      ObjectCreate(0, name, OBJ_HLINE, 0, 0, GridPrices[i]);
      color lc = InpColorZone1;
      if(GridPrices[i] <= g_Zone1_Floor) lc = InpColorZone2;
      if(GridPrices[i] <= g_Zone2_Floor) lc = InpColorZone3;
      ObjectSetInteger(0, name, OBJPROP_COLOR, lc);
      ObjectSetInteger(0, name, OBJPROP_STYLE, STYLE_DOT);
      ObjectSetInteger(0, name, OBJPROP_WIDTH, 1);
      ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
   }
}