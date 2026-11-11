//+------------------------------------------------------------------+
//| Shinvest Secondary Structure EA (MT5)                            |
//| Ported from shinvest_secondary_trades_backtest.pine              |
//| Signals: HH -> HL BUY, LL -> LH SELL, next-bar market execution. |
//+------------------------------------------------------------------+
#property strict
#property version "1.00"
#include <Trade/Trade.mqh>

enum ENUM_TRADE_SIDE { TRADE_BOTH=0, TRADE_LONG_ONLY=1, TRADE_SHORT_ONLY=2 };
input group "Strategy"
input string InpSymbol = "XAUUSD";          // Blank = chart symbol (supports broker suffixes)
input ENUM_TIMEFRAMES InpTimeframe = PERIOD_M1;
input ENUM_TRADE_SIDE InpDirection = TRADE_LONG_ONLY;
input double InpMinimumRR = 5.0;
input double InpMinimumSLPips = 19.0;
input double InpPipSize = 0.01;
input int InpHistoryBars = 3000;           // Replay once at startup
input group "Entry time filters (broker server time)"
input bool InpUseHourFilter = true;           // Inclusive hours, entry bar time
input int InpStartHour = 9;                  // 09:00
input int InpEndHour = 16;                   // Through 16:59
input bool InpUseWeekdayFilter = true;
input bool InpTradeMonday = false;
input bool InpTradeTuesday = false;
input bool InpTradeWednesday = true;
input bool InpTradeThursday = true;
input bool InpTradeFriday = true;
input bool InpTradeSaturday = false;
input bool InpTradeSunday = false;
input group "Execution"
input double InpRiskPercent = 0.1;
input int InpMaxPositions = 1;
input int InpMaxSpreadPoints = 30;         // Points, not pips
input int InpDeviationPoints = 20;
input long InpMagic = 26011101;
input bool InpBlockOtherSymbolPositions = false; // Enforce account-wide one-position policy
input group "Loss guards"
input bool InpEnableDailyCutoff = true;
input double InpDailyLossPercent = 2.0;
input bool InpEnableOverallCutoff = true;
input double InpOverallDrawdownPercent = 5.0;
input bool InpClosePositionsAtCutoff = false; // Otherwise block new positions only

CTrade trade;
string sym;
datetime lastBar = 0, lastDay = 0;
double initialBalance = 0.0, dayStartEquity = 0.0;
bool dayLocked = false, overallLocked = false;
bool tradingEnabled = false; // Always OFF when EA starts/restarts.
string toggleButton;

// Historical Pine zigzag has exactly one point per alternating swing,
// replacing its last point with a more extreme same-type fractal.
// Completed swing references are updated ONLY when a new opposite swing arrives.
double zzPrice[];
int zzType[];
datetime zzTime[];
double prevHigh = 0, lastHigh = 0, prevLow = 0, lastLow = 0;
bool hasPrevHigh = false, hasPrevLow = false;
int pendingDir = 0;
double pendingSL = 0, pendingTP = 0;
datetime pendingBar = 0;

string Key(const string suffix) { return "ShinvestEA." + (string)AccountInfoInteger(ACCOUNT_LOGIN) + "." + (string)InpMagic + "." + suffix; }

void RefreshTradingButton()
{
   if(ObjectFind(0,toggleButton)<0) return;
   ObjectSetString(0,toggleButton,OBJPROP_TEXT,tradingEnabled ? "EA TRADING: ON" : "EA TRADING: OFF");
   ObjectSetInteger(0,toggleButton,OBJPROP_BGCOLOR,tradingEnabled ? clrForestGreen : clrFireBrick);
   ObjectSetInteger(0,toggleButton,OBJPROP_COLOR,clrWhite);
   ObjectSetInteger(0,toggleButton,OBJPROP_STATE,false);
   ChartRedraw(0);
}
bool CreateTradingButton()
{
   toggleButton="ShinvestToggle_"+IntegerToString((long)ChartID())+"_"+IntegerToString(InpMagic);
   ObjectDelete(0,toggleButton);
   if(!ObjectCreate(0,toggleButton,OBJ_BUTTON,0,0,0)) return false;
   ObjectSetInteger(0,toggleButton,OBJPROP_CORNER,CORNER_LEFT_UPPER);
   ObjectSetInteger(0,toggleButton,OBJPROP_XDISTANCE,16);
   ObjectSetInteger(0,toggleButton,OBJPROP_YDISTANCE,30);
   ObjectSetInteger(0,toggleButton,OBJPROP_XSIZE,155);
   ObjectSetInteger(0,toggleButton,OBJPROP_YSIZE,32);
   ObjectSetInteger(0,toggleButton,OBJPROP_FONTSIZE,10);
   ObjectSetInteger(0,toggleButton,OBJPROP_SELECTABLE,false);
   ObjectSetInteger(0,toggleButton,OBJPROP_HIDDEN,true);
   RefreshTradingButton();
   return true;
}
void OnChartEvent(const int id,const long &lparam,const double &dparam,const string &sparam)
{
   if(id!=CHARTEVENT_OBJECT_CLICK || sparam!=toggleButton) return;
   tradingEnabled=!tradingEnabled;
   RefreshTradingButton();
   Print("Shinvest EA automated entries ",tradingEnabled ? "ENABLED" : "DISABLED");
}
void SaveGuardState()
{
   GlobalVariableSet(Key("initial_balance"), initialBalance);
   GlobalVariableSet(Key("day_start_equity"), dayStartEquity);
   GlobalVariableSet(Key("day_start_time"), (double)lastDay);
   GlobalVariableSet(Key("day_locked"), dayLocked ? 1.0 : 0.0);
   GlobalVariableSet(Key("overall_locked"), overallLocked ? 1.0 : 0.0);
}
void InitGuardState()
{
   datetime now = TimeTradeServer();
   if(now <= 0) now = TimeCurrent();
   MqlDateTime dt; TimeToStruct(now, dt);
   dt.hour = 0; dt.min = 0; dt.sec = 0;
   datetime midnight = StructToTime(dt);
   initialBalance = GlobalVariableCheck(Key("initial_balance")) ? GlobalVariableGet(Key("initial_balance")) : AccountInfoDouble(ACCOUNT_BALANCE);
   lastDay = (datetime)(GlobalVariableCheck(Key("day_start_time")) ? (long)GlobalVariableGet(Key("day_start_time")) : 0);
   dayStartEquity = GlobalVariableCheck(Key("day_start_equity")) ? GlobalVariableGet(Key("day_start_equity")) : AccountInfoDouble(ACCOUNT_EQUITY);
   dayLocked = GlobalVariableCheck(Key("day_locked")) && GlobalVariableGet(Key("day_locked")) > 0.5;
   overallLocked = GlobalVariableCheck(Key("overall_locked")) && GlobalVariableGet(Key("overall_locked")) > 0.5;
   if(lastDay != midnight)
   {
      lastDay = midnight;
      dayStartEquity = AccountInfoDouble(ACCOUNT_EQUITY);
      dayLocked = false;
   }
   SaveGuardState();
}
void UpdateGuards()
{
   datetime now = TimeTradeServer();
   if(now <= 0) now = TimeCurrent();
   MqlDateTime dt; TimeToStruct(now, dt);
   dt.hour = 0; dt.min = 0; dt.sec = 0;
   datetime midnight = StructToTime(dt);
   if(lastDay != midnight)
   {
      lastDay = midnight;
      dayStartEquity = AccountInfoDouble(ACCOUNT_EQUITY);
      dayLocked = false;
   }
   const double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   if(InpEnableDailyCutoff && dayStartEquity > 0.0 && equity <= dayStartEquity*(1.0-InpDailyLossPercent/100.0))
      dayLocked = true;
   if(InpEnableOverallCutoff && initialBalance > 0.0 && equity <= initialBalance*(1.0-InpOverallDrawdownPercent/100.0))
      overallLocked = true;
   SaveGuardState();
   if(InpClosePositionsAtCutoff && (dayLocked || overallLocked))
   {
      for(int i=PositionsTotal()-1; i>=0; --i)
      {
         ulong ticket = PositionGetTicket(i);
         if(ticket == 0) continue;
         if(PositionGetString(POSITION_SYMBOL) != sym || PositionGetInteger(POSITION_MAGIC) != InpMagic) continue;
         if(!trade.PositionClose(ticket)) Print("Guard close failed ",ticket," : ",trade.ResultRetcodeDescription());
      }
   }
}
int ActivePositions()
{
   int n=0;
   for(int i=PositionsTotal()-1; i>=0; --i)
   {
      ulong ticket=PositionGetTicket(i);
      if(ticket==0) continue;
      if(InpBlockOtherSymbolPositions || PositionGetString(POSITION_SYMBOL)==sym) ++n;
   }
   return n;
}
void ClearStructure()
{
   ArrayResize(zzPrice,0); ArrayResize(zzType,0); ArrayResize(zzTime,0);
   prevHigh=0; lastHigh=0; prevLow=0; lastLow=0;
   hasPrevHigh=false; hasPrevLow=false;
   pendingDir=0; pendingSL=0; pendingTP=0; pendingBar=0;
}
void AddPoint(const double price,const datetime at,const int kind,const double confirmHigh,const double confirmLow)
{
   int n=ArraySize(zzType);
   if(n>0 && zzType[n-1]==kind)
   {
      if((kind==1 && price>zzPrice[n-1]) || (kind==-1 && price<zzPrice[n-1]))
      {
         zzPrice[n-1]=price; zzTime[n-1]=at;
      }
      return;
   }
   ArrayResize(zzPrice,n+1); ArrayResize(zzType,n+1); ArrayResize(zzTime,n+1);
   zzPrice[n]=price; zzType[n]=kind; zzTime[n]=at;
   // The previous endpoint has become completed, matching Pine's newSwing event.
   if(n>=1)
   {
      int completedKind=zzType[n-1];
      double completedPrice=zzPrice[n-1];
      if(completedKind==1)
      {
         prevHigh=lastHigh; lastHigh=completedPrice;
         hasPrevHigh=true;
      }
      else
      {
         prevLow=lastLow; lastLow=completedPrice;
         hasPrevLow=true;
      }
   }
   if(n<2) return;
   // n is the index of the newly appended endpoint.
   if(kind==-1)
   {
      const double low=zzPrice[n], high=zzPrice[n-1], oldLow=zzPrice[n-2];
      const bool isHL=low>oldLow;
      // Pine previousCompletedHigh contains the completed high BEFORE the just-completed HH.
      const bool isHH=hasPrevHigh && prevHigh>0 && high>prevHigh;
      if(isHL && isHH && zzTime[n-1]!=zzTime[n] && confirmHigh<high)
      {
         pendingDir=1; pendingSL=low; pendingTP=high; pendingBar=at;
      }
   }
   else
   {
      const double high=zzPrice[n], low=zzPrice[n-1], oldHigh=zzPrice[n-2];
      const bool isLH=high<oldHigh;
      const bool isLL=hasPrevLow && prevLow>0 && low<prevLow;
      if(isLH && isLL && zzTime[n-1]!=zzTime[n] && confirmLow>low)
      {
         pendingDir=-1; pendingSL=high; pendingTP=low; pendingBar=at;
      }
   }
}
// bar 0 = current confirmation candle (closed), bar 1 = potential pivot,
// bar 2 = earlier candle. Call in chronological order.
void ProcessTriple(const MqlRates &earlier,const MqlRates &pivot,const MqlRates &confirm)
{
   const bool upper=earlier.high<pivot.high && confirm.high<pivot.high;
   const bool lower=earlier.low>pivot.low && confirm.low>pivot.low;
   int first=0, second=0;
   if(upper && lower)
   {
      int n=ArraySize(zzType);
      int lastKind=n>0 ? zzType[n-1] : 0;
      first=lastKind==1 ? -1 : lastKind==-1 ? 1 : -1;
      second=-first;
   }
   else if(upper) first=1;
   else if(lower) first=-1;
   if(first!=0) AddPoint(first==1 ? pivot.high : pivot.low,pivot.time,first,confirm.high,confirm.low);
   if(second!=0) AddPoint(second==1 ? pivot.high : pivot.low,pivot.time,second,confirm.high,confirm.low);
}
bool ValidDirection(const int dir)
{
   return (InpDirection==TRADE_BOTH || (InpDirection==TRADE_LONG_ONLY && dir==1) || (InpDirection==TRADE_SHORT_ONLY && dir==-1));
}
bool AllowedEntryTime(const datetime entryBarTime)
{
   if(!InpUseHourFilter && !InpUseWeekdayFilter) return true;
   MqlDateTime dt;
   TimeToStruct(entryBarTime,dt);
   if(InpUseHourFilter)
   {
      if(InpStartHour<=InpEndHour)
      {
         if(dt.hour<InpStartHour || dt.hour>InpEndHour) return false;
      }
      else if(dt.hour<InpStartHour && dt.hour>InpEndHour) return false; // Overnight window
   }
   if(!InpUseWeekdayFilter) return true;
   switch(dt.day_of_week)
   {
      case 0: return InpTradeSunday;
      case 1: return InpTradeMonday;
      case 2: return InpTradeTuesday;
      case 3: return InpTradeWednesday;
      case 4: return InpTradeThursday;
      case 5: return InpTradeFriday;
      case 6: return InpTradeSaturday;
   }
   return false;
}
bool CalculateLots(const int dir,const double entry,const double sl,double &lots)
{
   const double budget=AccountInfoDouble(ACCOUNT_EQUITY)*InpRiskPercent/100.0;
   if(budget<=0) return false;
   double pnl=0.0;
   if(!OrderCalcProfit(dir==1 ? ORDER_TYPE_BUY : ORDER_TYPE_SELL,sym,1.0,entry,sl,pnl)) return false;
   const double lossPerLot=-pnl;
   if(lossPerLot<=0) return false;
   const double desired=budget/lossPerLot;
   const double step=SymbolInfoDouble(sym,SYMBOL_VOLUME_STEP);
   const double vmin=SymbolInfoDouble(sym,SYMBOL_VOLUME_MIN);
   const double vmax=SymbolInfoDouble(sym,SYMBOL_VOLUME_MAX);
   if(step<=0 || vmin<=0 || vmax<vmin || desired<vmin) return false; // Never round risk UP to min lot.
   lots=MathFloor((desired+1e-12)/step)*step;
   lots=MathMin(lots,vmax);
   lots=NormalizeDouble(lots,8);
   if(lots<vmin) return false;
   double normalizedLoss=0;
   if(!OrderCalcProfit(dir==1 ? ORDER_TYPE_BUY : ORDER_TYPE_SELL,sym,lots,entry,sl,normalizedLoss)) return false;
   if(-normalizedLoss>budget*(1.0+1e-8)) return false;
   return true;
}
void TryEntry()
{
   if(pendingDir==0) return;
   const int dir=pendingDir;
   const double sl=pendingSL,tp=pendingTP;
   // Signal is single-use regardless of eligibility.
   pendingDir=0; pendingSL=0; pendingTP=0; pendingBar=0;
   if(!tradingEnabled || !ValidDirection(dir) || !AllowedEntryTime(lastBar) || dayLocked || overallLocked || ActivePositions()>=InpMaxPositions) return;
   MqlTick tick;
   if(!SymbolInfoTick(sym,tick) || tick.ask<=0 || tick.bid<=0) return;
   const double point=SymbolInfoDouble(sym,SYMBOL_POINT);
   const double spreadPoints=(tick.ask-tick.bid)/point;
   if(spreadPoints>InpMaxSpreadPoints) { Print("Skipped: spread ",spreadPoints); return; }
   const double price=dir==1?tick.ask:tick.bid;
   const double risk=dir==1?price-sl:sl-price;
   const double reward=dir==1?tp-price:price-tp;
   if(risk<=0 || reward<=0 || risk/InpPipSize<InpMinimumSLPips || reward/risk<InpMinimumRR) return;
   const int stopsLevel=(int)SymbolInfoInteger(sym,SYMBOL_TRADE_STOPS_LEVEL);
   if(risk<stopsLevel*point || reward<stopsLevel*point) { Print("Skipped: broker stop level"); return; }
   double lots=0;
   if(!CalculateLots(dir,price,sl,lots)) { Print("Skipped: size below minimum or invalid symbol P/L"); return; }
   const int digits=(int)SymbolInfoInteger(sym,SYMBOL_DIGITS);
   double nsl=NormalizeDouble(sl,digits), ntp=NormalizeDouble(tp,digits);
   // Recheck after rounding SL/TP to instrument digits.
   if((dir==1 && (nsl>=price || ntp<=price)) || (dir==-1 && (nsl<=price || ntp>=price))) return;
   bool ok = dir==1 ? trade.Buy(lots,sym,0,nsl,ntp,"Shinvest HL") : trade.Sell(lots,sym,0,nsl,ntp,"Shinvest LH");
   if(!ok || (trade.ResultRetcode()!=TRADE_RETCODE_DONE && trade.ResultRetcode()!=TRADE_RETCODE_DONE_PARTIAL))
      Print("Order failed: ",trade.ResultRetcode()," ",trade.ResultRetcodeDescription());
   else Print("Entry ",dir==1?"BUY":"SELL"," lots=",lots," SL=",nsl," TP=",ntp);
}
int OnInit()
{
   if(InpRiskPercent<=0 || InpRiskPercent>100 || InpMinimumRR<=0 || InpMinimumSLPips<0 || InpPipSize<=0 || InpMaxPositions<1 || InpMaxSpreadPoints<0 || InpDailyLossPercent<=0 || InpOverallDrawdownPercent<=0 || InpHistoryBars<20 || InpMagic<=0 || InpStartHour<0 || InpStartHour>23 || InpEndHour<0 || InpEndHour>23)
      return INIT_PARAMETERS_INCORRECT;
   sym=InpSymbol=="" ? _Symbol : InpSymbol;
   if(!SymbolSelect(sym,true)) { Print("Symbol unavailable: ",sym); return INIT_FAILED; }
   trade.SetExpertMagicNumber((ulong)InpMagic);
   trade.SetDeviationInPoints(InpDeviationPoints);
   trade.SetTypeFillingBySymbol(sym);
   tradingEnabled=false;
   if(!CreateTradingButton()) { Print("Cannot create trading toggle button"); return INIT_FAILED; }
   InitGuardState();
   ClearStructure();
   // Bootstrap confirmed fractals chronologically using closed bars only.
   MqlRates bars[];
   int got=CopyRates(sym,InpTimeframe,1,InpHistoryBars,bars);
   if(got<3) { Print("Not enough history"); return INIT_FAILED; }
   for(int i=2;i<got;++i) ProcessTriple(bars[i-2],bars[i-1],bars[i]);
   // Do not trade a stale signal produced during historical reconstruction.
   pendingDir=0; pendingSL=0; pendingTP=0; pendingBar=0;
   lastBar=iTime(sym,InpTimeframe,0);
   Print("Shinvest EA ready ",sym," ",EnumToString(InpTimeframe)," replayed ",got," closed candles");
   return INIT_SUCCEEDED;
}
void OnTick()
{
   UpdateGuards();
   datetime bar=iTime(sym,InpTimeframe,0);
   if(bar==0 || bar==lastBar) return;
   // For EA attached to a different chart, OnTick follows chart ticks;
   // attach to the same trade symbol to minimize delay.
   lastBar=bar;
   MqlRates bars[];
   if(CopyRates(sym,InpTimeframe,1,3,bars)!=3) return;
   ProcessTriple(bars[0],bars[1],bars[2]);
   TryEntry();
}
void OnDeinit(const int reason) { SaveGuardState(); ObjectDelete(0,toggleButton); }
