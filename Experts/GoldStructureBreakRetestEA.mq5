//+------------------------------------------------------------------+
//| Gold Structure Breakout + Retest EA (research prototype)         |
//| H1 confirmed pivots -> H1 close breakout -> M5 retest/confirmation|
//| No claim of profitability. Backtest with real ticks.             |
//+------------------------------------------------------------------+
#property strict
#property version "1.00"
#include <Trade/Trade.mqh>
enum ENUM_STRUCTURE_SIDE { STRUCT_BOTH=0, STRUCT_BUY_ONLY=1, STRUCT_SELL_ONLY=2 };
input group "Market and structure"
input string InpSymbol = "";                   // Blank = chart symbol; XAUUSD intended
input ENUM_STRUCTURE_SIDE InpDirection = STRUCT_BOTH;
input int InpPivotLeft = 2;                    // H1 older bars
input int InpPivotRight = 2;                   // H1 newer CLOSED bars
input int InpPivotLookback = 160;
input double InpBreakBufferATR = 0.05;         // H1 close must clear pivot by this H1 ATR multiple
input int InpATRH1Period = 14;
input int InpATRM5Period = 14;
input group "M5 retest and continuation"
input int InpMaxRetestBars = 24;               // M5 bars after H1 breakout close
input double InpRetestToleranceATR = 0.20;     // M5 ATR around broken H1 level
input bool InpRequirePriorCandleBreak = true; // M5 confirmation close past prior high/low
input double InpSLBufferATR = 0.20;            // M5 ATR beyond retest extreme
input double InpTargetR = 2.0;
input double InpMinRiskATR = 0.30;             // Minimum SL distance in M5 ATR
input double InpMaxRiskATR = 4.0;              // Maximum SL distance in M5 ATR
input group "Execution and risk"
input double InpRiskPct = 0.5;
input int InpMaxSpreadPoints = 50;
input int InpSlippagePoints = 20;
input long InpMagic = 26061101;
input bool InpEnableTradingOnStart = true;    // For Strategy Tester; disable for live chart until ready
input bool InpOnePositionAtATime = true;

CTrade trade;
string tradeSymbol;
int hATRH1=INVALID_HANDLE,hATRM5=INVALID_HANDLE;
datetime lastH1=0,lastM5=0,breakTime=0;
double breakLevel=0,retestExtreme=0;
int breakDirection=0,elapsedM5=0;
bool touched=false,enabled=false;
string buttonName;

bool BufferValue(int handle,int shift,double &v)
{
   double a[];
   if(CopyBuffer(handle,0,shift,1,a)!=1) return false;
   v=a[0];
   return v!=EMPTY_VALUE && v>0;
}
void ClearSetup()
{
   breakDirection=0;breakTime=0;breakLevel=0;elapsedM5=0;touched=false;retestExtreme=0;
}
bool HasPosition()
{
   for(int i=PositionsTotal()-1;i>=0;i--)
   {
      ulong ticket=PositionGetTicket(i);
      if(ticket>0 && PositionGetString(POSITION_SYMBOL)==tradeSymbol &&
         PositionGetInteger(POSITION_MAGIC)==InpMagic) return true;
   }
   return false;
}
bool PivotLevels(double &highLevel,double &lowLevel)
{
   // Series indexing: shift 1 = most recent CLOSED H1 candle.
   // The pivot must have InpPivotRight newer CLOSED bars, so start at shift Right+1.
   MqlRates bars[];
   ArraySetAsSeries(bars,true);
   int n=InpPivotLookback+InpPivotLeft+InpPivotRight+4;
   if(CopyRates(tradeSymbol,PERIOD_H1,0,n,bars)!=n) return false;
   highLevel=0;lowLevel=0;
   for(int k=InpPivotRight+1;k<InpPivotLookback+InpPivotRight+1;k++)
   {
      bool hi=true,lo=true;
      for(int j=1;j<=InpPivotLeft;j++)
      {
         if(bars[k].high<=bars[k+j].high) hi=false;
         if(bars[k].low>=bars[k+j].low) lo=false;
      }
      for(int j=1;j<=InpPivotRight;j++)
      {
         if(bars[k].high<=bars[k-j].high) hi=false;
         if(bars[k].low>=bars[k-j].low) lo=false;
      }
      if(hi && highLevel==0) highLevel=bars[k].high;
      if(lo && lowLevel==0) lowLevel=bars[k].low;
      if(highLevel>0 && lowLevel>0) break;
   }
   return highLevel>0 && lowLevel>0;
}
void DetectBreakout()
{
   MqlRates h[];
   ArraySetAsSeries(h,true);
   if(CopyRates(tradeSymbol,PERIOD_H1,0,3,h)!=3) return;
   double highLevel,lowLevel,atr;
   if(!PivotLevels(highLevel,lowLevel) || !BufferValue(hATRH1,1,atr)) return;
   double buffer=InpBreakBufferATR*atr;
   bool up=h[1].close>highLevel+buffer && h[2].close<=highLevel+buffer;
   bool down=h[1].close<lowLevel-buffer && h[2].close>=lowLevel-buffer;
   if(InpDirection==STRUCT_BUY_ONLY) down=false;
   if(InpDirection==STRUCT_SELL_ONLY) up=false;
   if(up==down) return;
   ClearSetup();
   breakDirection=up?1:-1;
   breakLevel=up?highLevel:lowLevel;
   breakTime=h[1].time+PeriodSeconds(PERIOD_H1);
   Print("H1 structural breakout ",up?"BUY":"SELL"," level=",DoubleToString(breakLevel,_Digits),
         " confirmed=",TimeToString(breakTime,TIME_DATE|TIME_MINUTES));
}
bool RiskLots(bool buy,double price,double sl,double &lots)
{
   double oneLotPnl=0;
   if(!OrderCalcProfit(buy?ORDER_TYPE_BUY:ORDER_TYPE_SELL,tradeSymbol,1.0,price,sl,oneLotPnl)
      || oneLotPnl>=0) return false;
   double step=SymbolInfoDouble(tradeSymbol,SYMBOL_VOLUME_STEP);
   double minLot=SymbolInfoDouble(tradeSymbol,SYMBOL_VOLUME_MIN);
   double maxLot=SymbolInfoDouble(tradeSymbol,SYMBOL_VOLUME_MAX);
   if(step<=0 || minLot<=0 || maxLot<=0) return false;
   double budget=AccountInfoDouble(ACCOUNT_EQUITY)*InpRiskPct/100.0;
   lots=NormalizeDouble(MathMin(maxLot,MathFloor(budget/(-oneLotPnl)/step)*step),8);
   return lots>=minLot;
}
void ProcessM5()
{
   if(breakDirection==0 || !enabled) return;
   MqlRates m[];
   ArraySetAsSeries(m,true);
   if(CopyRates(tradeSymbol,PERIOD_M5,0,3,m)!=3) return;
   if(m[1].time<breakTime) return;
   elapsedM5++;
   if(elapsedM5>InpMaxRetestBars) { ClearSetup();return; }
   double atr;
   if(!BufferValue(hATRM5,1,atr)) return;
   double tol=InpRetestToleranceATR*atr;
   bool buy=breakDirection==1;
   // Touch must occur after the breakout. Track the extreme across the retest.
   bool touches=buy?(m[1].low<=breakLevel+tol && m[1].high>=breakLevel-tol):
                    (m[1].high>=breakLevel-tol && m[1].low<=breakLevel+tol);
   if(touches)
   {
      if(!touched) retestExtreme=buy?m[1].low:m[1].high;
      touched=true;
   }
   if(!touched) return;
   retestExtreme=buy?MathMin(retestExtreme,m[1].low):MathMax(retestExtreme,m[1].high);
   bool confirmation=buy?(m[1].close>m[1].open && m[1].close>breakLevel):
                         (m[1].close<m[1].open && m[1].close<breakLevel);
   if(InpRequirePriorCandleBreak)
      confirmation=confirmation && (buy?m[1].close>m[2].high:m[1].close<m[2].low);
   if(!confirmation) return;
   // One attempt per structural break, even if an order is rejected.
   int side=breakDirection;
   double level=breakLevel,extreme=retestExtreme;
   ClearSetup();
   if(InpOnePositionAtATime && HasPosition()) return;
   MqlTick tick;
   if(!SymbolInfoTick(tradeSymbol,tick) || tick.ask<=0 || tick.bid<=0) return;
   double point=SymbolInfoDouble(tradeSymbol,SYMBOL_POINT);
   if(point<=0 || (tick.ask-tick.bid)/point>InpMaxSpreadPoints) return;
   double price=side==1?tick.ask:tick.bid;
   double sl=side==1?extreme-InpSLBufferATR*atr:extreme+InpSLBufferATR*atr;
   double risk=side==1?price-sl:sl-price;
   int stops=(int)SymbolInfoInteger(tradeSymbol,SYMBOL_TRADE_STOPS_LEVEL);
   if(risk<=0 || risk<InpMinRiskATR*atr || risk>InpMaxRiskATR*atr ||
      risk<stops*point || InpTargetR*risk<stops*point) return;
   double tp=side==1?price+InpTargetR*risk:price-InpTargetR*risk;
   double lots;
   if(!RiskLots(side==1,price,sl,lots)) return;
   int digits=(int)SymbolInfoInteger(tradeSymbol,SYMBOL_DIGITS);
   sl=NormalizeDouble(sl,digits);tp=NormalizeDouble(tp,digits);
   bool ok=side==1?trade.Buy(lots,tradeSymbol,0,sl,tp,"H1 break M5 retest"):
                   trade.Sell(lots,tradeSymbol,0,sl,tp,"H1 break M5 retest");
   if(!ok || (trade.ResultRetcode()!=TRADE_RETCODE_DONE &&
               trade.ResultRetcode()!=TRADE_RETCODE_DONE_PARTIAL))
      Print("Structure order failed: ",trade.ResultRetcodeDescription());
   else
      Print("Structure trade ",side==1?"BUY":"SELL"," level=",level,
            " lots=",lots," SL=",sl," TP=",tp);
}
void UpdateButton()
{
   if(ObjectFind(0,buttonName)<0) return;
   ObjectSetString(0,buttonName,OBJPROP_TEXT,enabled?"STRUCT EA: ON":"STRUCT EA: OFF");
   ObjectSetInteger(0,buttonName,OBJPROP_BGCOLOR,enabled?clrForestGreen:clrFireBrick);
   ObjectSetInteger(0,buttonName,OBJPROP_COLOR,clrWhite);
   ObjectSetInteger(0,buttonName,OBJPROP_STATE,false);
}
void OnChartEvent(const int id,const long &lp,const double &dp,const string &sp)
{
   if(id==CHARTEVENT_OBJECT_CLICK && sp==buttonName)
   {
      enabled=!enabled;
      if(!enabled) ClearSetup();
      UpdateButton();
   }
}
int OnInit()
{
   if(InpPivotLeft<1 || InpPivotRight<1 || InpPivotLookback<10 ||
      InpPivotLookback<=InpPivotLeft+InpPivotRight ||
      InpATRH1Period<2 || InpATRM5Period<2 || InpMaxRetestBars<1 ||
      InpRiskPct<=0 || InpRiskPct>10 || InpTargetR<=0 ||
      InpBreakBufferATR<0 || InpRetestToleranceATR<0 || InpSLBufferATR<0 ||
      InpMinRiskATR<0 || InpMaxRiskATR<=InpMinRiskATR || InpMagic<=0)
      return INIT_PARAMETERS_INCORRECT;
   tradeSymbol=InpSymbol==""?_Symbol:InpSymbol;
   if(!SymbolSelect(tradeSymbol,true)) return INIT_FAILED;
   hATRH1=iATR(tradeSymbol,PERIOD_H1,InpATRH1Period);
   hATRM5=iATR(tradeSymbol,PERIOD_M5,InpATRM5Period);
   if(hATRH1==INVALID_HANDLE || hATRM5==INVALID_HANDLE) return INIT_FAILED;
   trade.SetExpertMagicNumber((ulong)InpMagic);
   trade.SetDeviationInPoints(InpSlippagePoints);
   trade.SetTypeFillingBySymbol(tradeSymbol);
   enabled=InpEnableTradingOnStart;
   buttonName="StructureToggle_"+IntegerToString((long)ChartID());
   ObjectCreate(0,buttonName,OBJ_BUTTON,0,0,0);
   ObjectSetInteger(0,buttonName,OBJPROP_CORNER,CORNER_LEFT_UPPER);
   ObjectSetInteger(0,buttonName,OBJPROP_XDISTANCE,15);
   ObjectSetInteger(0,buttonName,OBJPROP_YDISTANCE,30);
   ObjectSetInteger(0,buttonName,OBJPROP_XSIZE,150);
   ObjectSetInteger(0,buttonName,OBJPROP_YSIZE,30);
   UpdateButton();
   lastH1=iTime(tradeSymbol,PERIOD_H1,0);
   lastM5=iTime(tradeSymbol,PERIOD_M5,0);
   Print("Structure breakout/retest research EA initialized. H1 -> M5.");
   return INIT_SUCCEEDED;
}
void OnTick()
{
   datetime h1=iTime(tradeSymbol,PERIOD_H1,0);
   if(h1!=0 && h1!=lastH1)
   {
      lastH1=h1;
      if(enabled) DetectBreakout();
   }
   datetime m5=iTime(tradeSymbol,PERIOD_M5,0);
   if(m5!=0 && m5!=lastM5)
   {
      lastM5=m5;
      ProcessM5();
   }
}
void OnDeinit(const int reason)
{
   ObjectDelete(0,buttonName);
   if(hATRH1!=INVALID_HANDLE) IndicatorRelease(hATRH1);
   if(hATRM5!=INVALID_HANDLE) IndicatorRelease(hATRM5);
}
