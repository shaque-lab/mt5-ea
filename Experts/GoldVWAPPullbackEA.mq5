//+------------------------------------------------------------------+
//| Gold VWAP EMA Pullback EA - research implementation              |
//| Source: Bhatti (2026), SSRN 6650958. NOT historically validated. |
//+------------------------------------------------------------------+
#property strict
#property version "1.00"
#include <Trade/Trade.mqh>
enum ENUM_VWAP_SIDE { VWAP_BOTH=0, VWAP_BUY_ONLY=1, VWAP_SELL_ONLY=2 };
input group "Market / strategy"
input string InpSymbol = "";                  // Blank = chart tradeSymbol; attach to XAUUSD M15
input ENUM_VWAP_SIDE InpDirection = VWAP_BOTH;
input int InpEMARegime = 200;
input int InpEMAPullback = 50;
input int InpEMATight = 20;
input int InpATRPeriod = 14;
input int InpVolumeMAPeriod = 20;
input double InpRegimeDeadZonePct = 0.1;
input double InpVolumeFactor = 1.1;
input double InpRangeATRFactor = 0.8;
input double InpSLBufferATR = 0.5;
input double InpTargetR = 3.0;
input double InpTightenAtR = 2.5;
input group "Session VWAP"
input int InpServerUTCOffsetHours = 0;       // Configure broker SERVER time relative to UTC; DST manually
input int InpSessionStartHourUTC = 13;
input int InpSessionStartMinuteUTC = 30;
input int InpSessionEndHourUTC = 20;
input int InpSessionEndMinuteUTC = 0;
input bool InpUseTickVolume = true;           // Spot gold typically has no exchange real volume
input group "Execution and risk"
input double InpRiskPct = 0.1;
input int InpMaxSpreadPoints = 50;
input int InpSlippagePoints = 20;
input long InpMagic = 26042601;
input bool InpEnableDailyLossLimit = true;
input double InpDailyLossLimitR = 3.0;        // Paper: 3x risk fraction, e.g. 0.3% at 0.1% risk
input bool InpPauseAfter3Losses = true;
input bool InpEnableManualNewsBlackout = false;
input datetime InpNewsEventServerTime = D'2026.01.01 00:00'; // One manually specified event; server time
input int InpNewsBlackoutMinutes = 15;
input group "Optional VWAP management"
input bool InpEnableVWAPPartial = false;      // OFF: VWAP entry filter already requires price beyond VWAP
input double InpPartialCloseFraction = 0.5;
input bool InpEnableTradingOnStart = false;   // Strategy Tester automation; use false on live charts

CTrade trade;
string tradeSymbol;
int h200=INVALID_HANDLE,h50=INVALID_HANDLE,h20=INVALID_HANDLE,hATR=INVALID_HANDLE;
datetime lastBar=0,dayAnchor=0;
double dayStartEquity=0;
int lossesToday=0;
bool locked=false;
bool reduced=false;
ulong trackedTicket=0;
double entryPrice=0,initialRisk=0;
bool enabled=false;
string buttonName="GoldVWAPToggle";

datetime ToUTC(datetime serverTime) { return serverTime-InpServerUTCOffsetHours*3600; }
datetime ToServer(datetime utcTime) { return utcTime+InpServerUTCOffsetHours*3600; }
double Vol(const MqlRates &r) { return InpUseTickVolume ? (double)r.tick_volume : (double)r.real_volume; }
bool ReadBuffer(const int handle,const int shift,double &value)
{
   double a[];
   if(CopyBuffer(handle,0,shift,1,a)!=1) return false;
   value=a[0];
   return value!=EMPTY_VALUE;
}
datetime UTCMidnight(datetime utc)
{
   MqlDateTime d; TimeToStruct(utc,d); d.hour=0;d.min=0;d.sec=0;
   return StructToTime(d);
}
bool SessionBounds(datetime barServer,datetime &startServer,datetime &endServer)
{
   datetime midnight=UTCMidnight(ToUTC(barServer));
   datetime a=midnight+InpSessionStartHourUTC*3600+InpSessionStartMinuteUTC*60;
   datetime b=midnight+InpSessionEndHourUTC*3600+InpSessionEndMinuteUTC*60;
   if(b<=a) b+=86400;
   datetime utc=ToUTC(barServer);
   if(utc<a) return false;
   if(utc>=b) return false;
   startServer=ToServer(a);endServer=ToServer(b);
   return true;
}
bool SessionVWAP(datetime barServer,double &vwap)
{
   datetime start,end;
   if(!SessionBounds(barServer,start,end)) return false;
   // Calculate from closed bars only, including the signal bar.
   MqlRates r[];
   int count=CopyRates(tradeSymbol,PERIOD_M15,start,barServer+PERIOD_M15*60-1,r);
   if(count<1) return false;
   double pv=0,volume=0;
   for(int i=0;i<count;i++)
   {
      if(r[i].time<start || r[i].time>barServer) continue;
      double v=Vol(r[i]);
      if(v<=0) continue;
      pv+=((r[i].high+r[i].low+r[i].close)/3.0)*v;
      volume+=v;
   }
   if(volume<=0) return false;
   vwap=pv/volume;return true;
}
bool Rejection(const MqlRates &prev,const MqlRates &sig,const bool buy)
{
   double body=MathAbs(sig.close-sig.open);
   double lower=MathMin(sig.open,sig.close)-sig.low;
   double upper=sig.high-MathMax(sig.open,sig.close);
   if(buy)
   {
      bool pin=sig.close>sig.open && lower>=2.0*body && upper<=0.5*lower;
      bool engulf=prev.close<prev.open && sig.close>sig.open && sig.close>prev.open && sig.open<prev.close;
      return pin || engulf;
   }
   bool pin=sig.close<sig.open && upper>=2.0*body && lower<=0.5*upper;
   bool engulf=prev.close>prev.open && sig.close<sig.open && sig.close<prev.open && sig.open>prev.close;
   return pin || engulf;
}
bool PositionExists()
{
   for(int i=PositionsTotal()-1;i>=0;i--)
   {
      ulong t=PositionGetTicket(i);
      if(t>0 && PositionGetString(POSITION_SYMBOL)==tradeSymbol && PositionGetInteger(POSITION_MAGIC)==InpMagic) return true;
   }
   return false;
}
void RefreshButton()
{
   if(ObjectFind(0,buttonName)<0) return;
   ObjectSetString(0,buttonName,OBJPROP_TEXT,enabled?"VWAP EA: ON":"VWAP EA: OFF");
   ObjectSetInteger(0,buttonName,OBJPROP_BGCOLOR,enabled?clrForestGreen:clrFireBrick);
   ObjectSetInteger(0,buttonName,OBJPROP_COLOR,clrWhite);
   ObjectSetInteger(0,buttonName,OBJPROP_STATE,false);
}
void OnChartEvent(const int id,const long &lp,const double &dp,const string &sp)
{
   if(id==CHARTEVENT_OBJECT_CLICK && sp==buttonName) { enabled=!enabled;RefreshButton(); }
}
void RefreshDay()
{
   datetime today=UTCMidnight(ToUTC(TimeCurrent()));
   if(today!=dayAnchor)
   {
      dayAnchor=today;dayStartEquity=AccountInfoDouble(ACCOUNT_EQUITY);
      lossesToday=0;locked=false;
   }
   if(InpEnableDailyLossLimit && dayStartEquity>0 &&
      AccountInfoDouble(ACCOUNT_EQUITY)<=dayStartEquity*(1.0-InpDailyLossLimitR*InpRiskPct/100.0)) locked=true;
   if(InpPauseAfter3Losses && lossesToday>=3) locked=true;
}
void OnTradeTransaction(const MqlTradeTransaction &trans,const MqlTradeRequest &req,const MqlTradeResult &res)
{
   if(trans.type!=TRADE_TRANSACTION_DEAL_ADD || !HistoryDealSelect(trans.deal)) return;
   if(HistoryDealGetString(trans.deal,DEAL_SYMBOL)!=tradeSymbol ||
      HistoryDealGetInteger(trans.deal,DEAL_MAGIC)!=InpMagic) return;
   long entry=(long)HistoryDealGetInteger(trans.deal,DEAL_ENTRY);
   if(entry==DEAL_ENTRY_OUT || entry==DEAL_ENTRY_OUT_BY)
   {
      double net=HistoryDealGetDouble(trans.deal,DEAL_PROFIT)+HistoryDealGetDouble(trans.deal,DEAL_SWAP)+HistoryDealGetDouble(trans.deal,DEAL_COMMISSION);
      if(net<0) lossesToday++;
   }
}
bool LotsForRisk(const bool buy,const double price,const double sl,double &lots)
{
   double pnl;
   if(!OrderCalcProfit(buy?ORDER_TYPE_BUY:ORDER_TYPE_SELL,tradeSymbol,1.0,price,sl,pnl) || pnl>=0) return false;
   double budget=AccountInfoDouble(ACCOUNT_EQUITY)*InpRiskPct/100.0;
   double step=SymbolInfoDouble(tradeSymbol,SYMBOL_VOLUME_STEP);
   double minv=SymbolInfoDouble(tradeSymbol,SYMBOL_VOLUME_MIN);
   double maxv=SymbolInfoDouble(tradeSymbol,SYMBOL_VOLUME_MAX);
   if(step<=0 || budget<=0) return false;
   lots=NormalizeDouble(MathMin(maxv,MathFloor(budget/(-pnl)/step)*step),8);
   return lots>=minv;
}
void Enter(const MqlRates &sig,const MqlRates &prev)
{
   if(!enabled || locked || PositionExists()) return;
   datetime start,end;
   if(!SessionBounds(sig.time,start,end)) return;
   if(InpEnableManualNewsBlackout &&
      MathAbs((long)(sig.time-InpNewsEventServerTime))<=InpNewsBlackoutMinutes*60) return;
   double ema200,ema50,atr;
   if(!ReadBuffer(h200,1,ema200) || !ReadBuffer(h50,1,ema50) || !ReadBuffer(hATR,1,atr) || atr<=0) return;
   if(MathAbs(sig.close-ema200)/ema200<=InpRegimeDeadZonePct/100.0) return;
   double vwap;
   if(!SessionVWAP(sig.time,vwap)) return;
   MqlRates vols[];
   int need=InpVolumeMAPeriod+1;
   if(CopyRates(tradeSymbol,PERIOD_M15,1,need,vols)!=need) return;
   double sum=0;
   for(int i=0;i<need-1;i++) sum+=Vol(vols[i]); // excludes signal bar
   if(Vol(sig)<=InpVolumeFactor*sum/(need-1)) return;
   if(sig.high-sig.low<InpRangeATRFactor*atr) return;
   bool buy=sig.close>ema200 && sig.close>vwap &&
      MathMin(sig.low,prev.low)<=ema50 && ema50<=sig.close &&
      Rejection(prev,sig,true);
   bool sell=sig.close<ema200 && sig.close<vwap &&
      MathMax(sig.high,prev.high)>=ema50 && ema50>=sig.close &&
      Rejection(prev,sig,false);
   if(InpDirection==VWAP_BUY_ONLY) sell=false;
   if(InpDirection==VWAP_SELL_ONLY) buy=false;
   if(!buy && !sell) return;
   MqlTick tick;
   if(!SymbolInfoTick(tradeSymbol,tick) || tick.ask<=0 || tick.bid<=0) return;
   double point=SymbolInfoDouble(tradeSymbol,SYMBOL_POINT);
   if((tick.ask-tick.bid)/point>InpMaxSpreadPoints) return;
   double price=buy?tick.ask:tick.bid;
   double sl=buy?sig.low-InpSLBufferATR*atr:sig.high+InpSLBufferATR*atr;
   double risk=buy?price-sl:sl-price;
   if(risk<=0) return;
   double tp=buy?price+InpTargetR*risk:price-InpTargetR*risk;
   int stops=(int)SymbolInfoInteger(tradeSymbol,SYMBOL_TRADE_STOPS_LEVEL);
   if(risk<stops*point || InpTargetR*risk<stops*point) return;
   double lots;
   if(!LotsForRisk(buy,price,sl,lots)) return;
   int digits=(int)SymbolInfoInteger(tradeSymbol,SYMBOL_DIGITS);
   sl=NormalizeDouble(sl,digits);tp=NormalizeDouble(tp,digits);
   bool ok=buy?trade.Buy(lots,tradeSymbol,0,sl,tp,"VWAP EMA pullback"):
               trade.Sell(lots,tradeSymbol,0,sl,tp,"VWAP EMA pullback");
   if(ok && (trade.ResultRetcode()==TRADE_RETCODE_DONE || trade.ResultRetcode()==TRADE_RETCODE_DONE_PARTIAL))
   {
      entryPrice=price;initialRisk=risk;reduced=false;
      Print("VWAP entry ",buy?"BUY":"SELL"," @",price," SL=",sl," TP=",tp);
   }
   else Print("VWAP order rejected: ",trade.ResultRetcodeDescription());
}
void ManagePosition(const MqlRates &closed)
{
   for(int i=PositionsTotal()-1;i>=0;i--)
   {
      ulong ticket=PositionGetTicket(i);
      if(ticket==0 || PositionGetString(POSITION_SYMBOL)!=tradeSymbol || PositionGetInteger(POSITION_MAGIC)!=InpMagic) continue;
      bool buy=PositionGetInteger(POSITION_TYPE)==POSITION_TYPE_BUY;
      double price=PositionGetDouble(POSITION_PRICE_OPEN);
      double sl=PositionGetDouble(POSITION_SL);
      double tp=PositionGetDouble(POSITION_TP);
      double risk=initialRisk;
      if(risk<=0) risk=buy?price-sl:sl-price; // Recovery after restart; not exact if SL changed
      if(risk<=0) return;
      double r=buy?(closed.close-price)/risk:(price-closed.close)/risk;
      double trail;
      int handle=r>=InpTightenAtR?h20:h50;
      if(!ReadBuffer(handle,1,trail)) return;
      if((buy && closed.close<trail) || (!buy && closed.close>trail))
      {
         if(!trade.PositionClose(ticket)) Print("EMA close exit failed: ",trade.ResultRetcodeDescription());
         return;
      }
      // Optional paper VWAP compressed-approach partial management.
      // Disabled by default: entry requires price already beyond VWAP.
      if(InpEnableVWAPPartial && !reduced)
      {
         double vwap;
         if(SessionVWAP(closed.time,vwap) && MathAbs(closed.close-vwap)/vwap<=0.0015 &&
            closed.high-closed.low<=0.6*MathAbs(closed.close-price))
         {
            double vol=PositionGetDouble(POSITION_VOLUME);
            double step=SymbolInfoDouble(tradeSymbol,SYMBOL_VOLUME_STEP);
            double part=MathFloor(vol*InpPartialCloseFraction/step)*step;
            if(part>=SymbolInfoDouble(tradeSymbol,SYMBOL_VOLUME_MIN) && vol-part>=SymbolInfoDouble(tradeSymbol,SYMBOL_VOLUME_MIN))
            {
               if(trade.PositionClosePartial(ticket,part)) reduced=true;
            }
         }
      }
      return;
   }
   entryPrice=0;initialRisk=0;reduced=false;
}
int OnInit()
{
   if(InpEMARegime<2 || InpEMAPullback<2 || InpEMATight<2 || InpATRPeriod<2 ||
      InpVolumeMAPeriod<2 || InpRiskPct<=0 || InpRiskPct>100 ||
      InpTargetR<=0 || InpSLBufferATR<0 || InpServerUTCOffsetHours< -12 ||
      InpServerUTCOffsetHours>14 || InpSessionStartHourUTC<0 || InpSessionStartHourUTC>23 ||
      InpSessionEndHourUTC<0 || InpSessionEndHourUTC>23 || InpSessionStartMinuteUTC<0 ||
      InpSessionStartMinuteUTC>59 || InpSessionEndMinuteUTC<0 || InpSessionEndMinuteUTC>59 ||
      InpPartialCloseFraction<=0 || InpPartialCloseFraction>=1 || InpMagic<=0) return INIT_PARAMETERS_INCORRECT;
   tradeSymbol=InpSymbol==""?_Symbol:InpSymbol;
   if(!SymbolSelect(tradeSymbol,true)) return INIT_FAILED;
   h200=iMA(tradeSymbol,PERIOD_M15,InpEMARegime,0,MODE_EMA,PRICE_CLOSE);
   h50=iMA(tradeSymbol,PERIOD_M15,InpEMAPullback,0,MODE_EMA,PRICE_CLOSE);
   h20=iMA(tradeSymbol,PERIOD_M15,InpEMATight,0,MODE_EMA,PRICE_CLOSE);
   hATR=iATR(tradeSymbol,PERIOD_M15,InpATRPeriod);
   if(h200==INVALID_HANDLE || h50==INVALID_HANDLE || h20==INVALID_HANDLE || hATR==INVALID_HANDLE) return INIT_FAILED;
   trade.SetExpertMagicNumber((ulong)InpMagic);
   trade.SetDeviationInPoints(InpSlippagePoints);
   trade.SetTypeFillingBySymbol(tradeSymbol);
   enabled=InpEnableTradingOnStart;
   buttonName="GoldVWAPToggle_"+IntegerToString((long)ChartID());
   ObjectCreate(0,buttonName,OBJ_BUTTON,0,0,0);
   ObjectSetInteger(0,buttonName,OBJPROP_CORNER,CORNER_LEFT_UPPER);
   ObjectSetInteger(0,buttonName,OBJPROP_XDISTANCE,15);
   ObjectSetInteger(0,buttonName,OBJPROP_YDISTANCE,30);
   ObjectSetInteger(0,buttonName,OBJPROP_XSIZE,150);
   ObjectSetInteger(0,buttonName,OBJPROP_YSIZE,30);
   RefreshButton();
   dayAnchor=UTCMidnight(ToUTC(TimeCurrent()));
   dayStartEquity=AccountInfoDouble(ACCOUNT_EQUITY);
   lastBar=iTime(tradeSymbol,PERIOD_M15,0);
   Print("Gold VWAP EMA research EA ready. Confirm server UTC offset and test with real ticks.");
   return INIT_SUCCEEDED;
}
void OnTick()
{
   RefreshDay();
   datetime bar=iTime(tradeSymbol,PERIOD_M15,0);
   if(bar==0 || bar==lastBar) return;
   lastBar=bar;
   MqlRates r[];
   if(CopyRates(tradeSymbol,PERIOD_M15,1,2,r)!=2) return;
   ManagePosition(r[1]);
   Enter(r[1],r[0]);
}
void OnDeinit(const int reason)
{
   ObjectDelete(0,buttonName);
   if(h200!=INVALID_HANDLE) IndicatorRelease(h200);
   if(h50!=INVALID_HANDLE) IndicatorRelease(h50);
   if(h20!=INVALID_HANDLE) IndicatorRelease(h20);
   if(hATR!=INVALID_HANDLE) IndicatorRelease(hATR);
}
