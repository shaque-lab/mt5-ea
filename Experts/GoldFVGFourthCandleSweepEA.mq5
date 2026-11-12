//+------------------------------------------------------------------+
//| GoldFVGFourthCandleSweepEA.mq5                                   |
//| Unfiltered 3-candle FVG + fourth-candle rejection sweep.          |
//| Attach to desired timeframe. Signals use CLOSED bars only.       |
//+------------------------------------------------------------------+
#property strict
#property version "1.00"
#include <Trade/Trade.mqh>
CTrade trade;
enum ENUM_FVG_SIDE { FVG_BOTH=0, FVG_BUY_ONLY=1, FVG_SELL_ONLY=2 };
input group "Strategy"
input ENUM_FVG_SIDE InpDirection=FVG_BOTH;
input double InpMinimumRR=1.20;
input group "Risk and execution"
input double InpRiskPercent=0.50;
input long InpMagic=26111204;
input int InpMaxSpreadPoints=0; // 0 = no spread filter
input int InpDeviationPoints=20;
input bool InpOnePositionPerSymbol=true;
input bool InpTradingEnabled=true;

datetime lastBar=0;
string symbolName;
bool enabled;
string toggleName;

void UpdateToggle()
{
   if(ObjectFind(0,toggleName)<0) return;
   ObjectSetString(0,toggleName,OBJPROP_TEXT,enabled?"FVG SWEEP: ON":"FVG SWEEP: OFF");
   ObjectSetInteger(0,toggleName,OBJPROP_BGCOLOR,enabled?clrForestGreen:clrFireBrick);
   ObjectSetInteger(0,toggleName,OBJPROP_COLOR,clrWhite);
   ObjectSetInteger(0,toggleName,OBJPROP_STATE,false);
}
void OnChartEvent(const int id,const long &lparam,const double &dparam,const string &sparam)
{
   if(id==CHARTEVENT_OBJECT_CLICK && sparam==toggleName)
   {
      enabled=!enabled;
      UpdateToggle();
   }
}
bool ExistingPosition()
{
   for(int i=PositionsTotal()-1;i>=0;i--)
   {
      ulong ticket=PositionGetTicket(i);
      if(ticket>0 && PositionGetString(POSITION_SYMBOL)==symbolName)
         return true;
   }
   return false;
}
bool CalculateLots(const ENUM_ORDER_TYPE type,const double entry,const double sl,double &lots)
{
   double lossOneLot=0.0;
   if(!OrderCalcProfit(type,symbolName,1.0,entry,sl,lossOneLot) || lossOneLot>=0.0)
      return false;
   double budget=AccountInfoDouble(ACCOUNT_EQUITY)*InpRiskPercent/100.0;
   double minVolume=SymbolInfoDouble(symbolName,SYMBOL_VOLUME_MIN);
   double maxVolume=SymbolInfoDouble(symbolName,SYMBOL_VOLUME_MAX);
   double step=SymbolInfoDouble(symbolName,SYMBOL_VOLUME_STEP);
   if(step<=0 || minVolume<=0 || maxVolume<minVolume) return false;
   double steps=MathFloor((budget/(-lossOneLot)+1e-10)/step);
   lots=NormalizeDouble(MathMin(maxVolume,steps*step),8);
   return lots>=minVolume;
}
void EvaluateClosedCandle()
{
   if(!enabled) return;
   // Series: [4]=first FVG candle, [3]=second, [2]=third,
   // [1]=fourth (sweep/entry signal), [0]=newly opened candle.
   MqlRates b[];
   ArraySetAsSeries(b,true);
   if(CopyRates(symbolName,_Period,0,5,b)!=5) return;
   bool bullishFVG=b[4].high<b[2].low;
   bool bearishFVG=b[4].low>b[2].high;
   // Strict rejection: fourth candle pierces third candle extreme,
   // and closes strictly INSIDE the entire third candle high-low range.
   bool buy=bullishFVG && b[1].low<b[2].low &&
            b[1].close>b[2].low && b[1].close<b[2].high;
   bool sell=bearishFVG && b[1].high>b[2].high &&
             b[1].close<b[2].high && b[1].close>b[2].low;
   if(InpDirection==FVG_BUY_ONLY) sell=false;
   if(InpDirection==FVG_SELL_ONLY) buy=false;
   if(buy==sell) return;
   if(InpOnePositionPerSymbol && ExistingPosition()) return;
   MqlTick tick;
   if(!SymbolInfoTick(symbolName,tick) || tick.ask<=0 || tick.bid<=0) return;
   double point=SymbolInfoDouble(symbolName,SYMBOL_POINT);
   if(point<=0) return;
   if(InpMaxSpreadPoints>0 && (tick.ask-tick.bid)/point>InpMaxSpreadPoints) return;
   // At candle 4 close the first executable price is the first tick of candle 5.
   // Include bid/ask spread in executable RR rather than using the signal close.
   double entry=buy?tick.ask:tick.bid;
   double sl=buy?b[1].low:b[1].high;
   double tp=buy?b[2].high:b[2].low;
   double risk=buy?entry-sl:sl-entry;
   double reward=buy?tp-entry:entry-tp;
   if(risk<=0 || reward<=0 || reward/risk+1e-10<InpMinimumRR) return;
   double stops=SymbolInfoInteger(symbolName,SYMBOL_TRADE_STOPS_LEVEL)*point;
   if(risk<stops || reward<stops) return;
   double lots=0;
   ENUM_ORDER_TYPE orderType=buy?ORDER_TYPE_BUY:ORDER_TYPE_SELL;
   if(!CalculateLots(orderType,entry,sl,lots)) return;
   int digits=(int)SymbolInfoInteger(symbolName,SYMBOL_DIGITS);
   sl=NormalizeDouble(sl,digits);
   tp=NormalizeDouble(tp,digits);
   bool sent=buy?trade.Buy(lots,symbolName,0,sl,tp,"FVG4 sweep BUY"):
                 trade.Sell(lots,symbolName,0,sl,tp,"FVG4 sweep SELL");
   if(!sent || (trade.ResultRetcode()!=TRADE_RETCODE_DONE &&
                 trade.ResultRetcode()!=TRADE_RETCODE_DONE_PARTIAL))
      Print("FVG sweep order rejected: ",trade.ResultRetcodeDescription());
   else
      Print("FVG sweep ",buy?"BUY":"SELL"," TF=",EnumToString(_Period),
            " RR=",DoubleToString(reward/risk,2)," lots=",lots,
            " SL=",sl," TP=",tp);
}
int OnInit()
{
   if(InpMinimumRR<=0 || InpRiskPercent<=0 || InpRiskPercent>10 ||
      InpMagic<=0 || InpMaxSpreadPoints<0 || InpDeviationPoints<0)
      return INIT_PARAMETERS_INCORRECT;
   symbolName=_Symbol;
   enabled=InpTradingEnabled;
   trade.SetExpertMagicNumber((ulong)InpMagic);
   trade.SetDeviationInPoints(InpDeviationPoints);
   trade.SetTypeFillingBySymbol(symbolName);
   toggleName="FVG4Toggle_"+IntegerToString((long)ChartID());
   ObjectCreate(0,toggleName,OBJ_BUTTON,0,0,0);
   ObjectSetInteger(0,toggleName,OBJPROP_CORNER,CORNER_LEFT_UPPER);
   ObjectSetInteger(0,toggleName,OBJPROP_XDISTANCE,15);
   ObjectSetInteger(0,toggleName,OBJPROP_YDISTANCE,30);
   ObjectSetInteger(0,toggleName,OBJPROP_XSIZE,155);
   ObjectSetInteger(0,toggleName,OBJPROP_YSIZE,30);
   UpdateToggle();
   lastBar=iTime(symbolName,_Period,0);
   Print("FVG 4th candle sweep V1 initialized on ",symbolName," ",EnumToString(_Period));
   return INIT_SUCCEEDED;
}
void OnTick()
{
   datetime bar=iTime(symbolName,_Period,0);
   if(bar==0 || bar==lastBar) return;
   lastBar=bar;
   EvaluateClosedCandle();
}
void OnDeinit(const int reason)
{
   ObjectDelete(0,toggleName);
}
