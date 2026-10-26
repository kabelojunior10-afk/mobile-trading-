//+------------------------------------------------------------------+
//|                                                   EWMAC_EA.mq5   |
//|                 AMARE CAPITAL MANAGEMENT                         |
//|                 EWMAC Stop-and-Reverse at forecast 0             |
//|                 Version 3.00 (ATR trailing stop)                 |
//|                 Forecast math MATCHES EWMAC_Forecast.mq5         |
//|                                                                  |
//|  Rules:                                                          |
//|   - forecast > 0 = long, forecast < 0 = short (reverse at 0)     |
//|   - broker-side ATR trailing stop                                |
//|   - if the stop is hit, stay flat until the forecast crosses 0   |
//|   - signal timeframe is an input (independent of chart timeframe)|
//|   - VPS algorithm                                                |
//+------------------------------------------------------------------+
#property strict
#property version   "3.00"
#property description "EWMAC stop-and-reverse at 0 with ATR trailing stop."
#include <Trade/Trade.mqh>
CTrade trade;

//+------------------------------------------------------------------+
//| ENUMERATIONS                                                     |
//+------------------------------------------------------------------+
enum ENUM_EWMAC_PAIR
{
   EWMAC_2_8 = 0,
   EWMAC_4_16,
   EWMAC_8_32,
   EWMAC_16_64,
   EWMAC_32_128,
   EWMAC_64_256
};

enum ENUM_POSITION_SIZING
{
   SIZE_FIXED_LOT = 0,
   SIZE_EQUITY_RISK_REFERENCE = 1
};

//+------------------------------------------------------------------+
//| INPUTS                                                           |
//+------------------------------------------------------------------+
input group "EWMAC Strategy"
input ENUM_EWMAC_PAIR EWMACPair         = EWMAC_8_32;
input ENUM_TIMEFRAMES SignalTimeframe   = PERIOD_M1;   // timeframe the forecast/ATR are computed on (any chart)
input int    StdevWindow                = 50;
input double ForecastCapMin             = -20.0;
input double ForecastCapMax             =  20.0;
input int    WarmupBars                 = 1000;
input bool   TradeCurrentTrend          = true;   // true = enter immediately in the current forecast direction on attach
input bool   UseCarverScalar            = true;

input group "ATR Trailing Stop"
input bool   UseATRTrail                = true;   // broker-side SL, ratcheted with ATR
input int    ATRPeriod                  = 14;     // ATR on SignalTimeframe, last closed bar
input double ATRMultiplier              = 3.0;    // stop distance = ATR * multiplier
input double TrailStartATR              = 1.0;    // trailing starts after profit >= this many ATR
input double TrailStepATR               = 0.1;    // min SL improvement per modify (in ATR)
input bool   ShowTrailOnChart           = true;   // draw SL line, label and trail dots

input group "Position Sizing"
input ENUM_POSITION_SIZING SizingMode   = SIZE_FIXED_LOT;
input double FixedLots                  = 0.01;
input double RiskPercent                = 1.0;
input int    SizingReferencePoints      = 1000;
input bool   UseForecastSizing          = true;
input bool   UseMinLotIfBelow           = true;
input double MaxLots                    = 1.0;

input group "Execution"
input ulong  MagicNumber                = 20260101;
input int    SlippagePts                = 50;

input group "Notifications and Display"
input bool SendPush                     = true;
input bool SendPopup                    = false;
input bool ShowComment                  = true;

//+------------------------------------------------------------------+
//| GLOBAL STATE                                                     |
//+------------------------------------------------------------------+
int      FastPeriod        = 8;
int      SlowPeriod        = 32;
double   ForecastScalar    = 5.3;
datetime LastProcessedBar  = 0;
double   LastForecast      = 0.0;
double   PreviousForecast  = 0.0;
bool     ForecastAvailable = false;

int      TargetSide        = 0;      // side the forecast wants (1 / -1 / 0 = none yet)
int      BlockedSide       = 0;      // side blocked after a stop-out until the next zero-cross
int      TrackedSide       = 0;      // last seen open position side
datetime LastAttempt       = 0;      // order retry throttle (1 per second)

int      hATR              = INVALID_HANDLE;
double   LastATR           = 0.0;
bool     TrailHadPos       = false;
double   LastDrawnSL       = 0.0;
int      TrailDotCount     = 0;

string DashPrefix  = "EWMAC_DASH_";
string TrailPrefix = "EWMAC_TRAIL_";
const int DASH_LINES = 16;

//+------------------------------------------------------------------+
//| Print the same message at most once every 30 seconds             |
//+------------------------------------------------------------------+
void ThrottledPrint(const string msg)
{
   static string   lastMsg = "";
   static datetime lastT   = 0;
   if(msg == lastMsg && TimeCurrent() - lastT < 30) return;
   lastMsg = msg;
   lastT   = TimeCurrent();
   Print(msg);
}

//+------------------------------------------------------------------+
//| INITIALIZE                                                       |
//+------------------------------------------------------------------+
int OnInit()
{
   if(StdevWindow < 2) return INIT_PARAMETERS_INCORRECT;
   if(WarmupBars < 100) return INIT_PARAMETERS_INCORRECT;
   if(ForecastCapMin >= ForecastCapMax) return INIT_PARAMETERS_INCORRECT;
   if(FixedLots <= 0.0 || RiskPercent <= 0.0 || SizingReferencePoints <= 0 || MaxLots <= 0.0) return INIT_PARAMETERS_INCORRECT;
   if(UseATRTrail && (ATRPeriod < 1 || ATRMultiplier <= 0.0 || TrailStartATR < 0.0 || TrailStepATR < 0.0)) return INIT_PARAMETERS_INCORRECT;

   SetEWMACPeriods();
   SetForecastScalar();

   trade.SetExpertMagicNumber(MagicNumber);
   trade.SetDeviationInPoints(SlippagePts);
   trade.SetTypeFillingBySymbol(_Symbol);
   trade.SetAsyncMode(false);

   if(UseATRTrail)
   {
      hATR = iATR(_Symbol, SignalTimeframe, ATRPeriod);
      if(hATR == INVALID_HANDLE) return INIT_FAILED;
   }

   Print("==================================================");
   Print("AMARE CAPITAL - EWMAC EA v3.00");
   Print("Symbol: ", _Symbol, "  Signal TF: ", EnumToString(SignalTimeframe));
   Print("EWMAC: ", FastPeriod, "/", SlowPeriod, "  Scalar: ", DoubleToString(ForecastScalar, 2));
   Print("Stop-and-reverse at forecast 0. No filters.");
   Print("ATR trail: ", (UseATRTrail ? "ON  ATR(" + IntegerToString(ATRPeriod) + ") x" + DoubleToString(ATRMultiplier, 2)
                                      + "  start " + DoubleToString(TrailStartATR, 2) + " ATR" : "OFF"));
   Print("==================================================");

   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
void SetEWMACPeriods()
{
   switch(EWMACPair)
   {
      case EWMAC_2_8:    FastPeriod = 2;  SlowPeriod = 8;   break;
      case EWMAC_4_16:   FastPeriod = 4;  SlowPeriod = 16;  break;
      case EWMAC_8_32:   FastPeriod = 8;  SlowPeriod = 32;  break;
      case EWMAC_16_64:  FastPeriod = 16; SlowPeriod = 64;  break;
      case EWMAC_32_128: FastPeriod = 32; SlowPeriod = 128; break;
      case EWMAC_64_256: FastPeriod = 64; SlowPeriod = 256; break;
   }
}

//+------------------------------------------------------------------+
void SetForecastScalar()
{
   if(!UseCarverScalar) { ForecastScalar = 10.0 / MathSqrt((double)FastPeriod); return; }
   switch(EWMACPair)
   {
      case EWMAC_2_8:    ForecastScalar = 10.6; break;
      case EWMAC_4_16:   ForecastScalar = 7.5;  break;
      case EWMAC_8_32:   ForecastScalar = 5.3;  break;
      case EWMAC_16_64:  ForecastScalar = 3.75; break;
      case EWMAC_32_128: ForecastScalar = 2.65; break;
      case EWMAC_64_256: ForecastScalar = 1.87; break;
      default:           ForecastScalar = 5.3;  break;
   }
}

//+------------------------------------------------------------------+
double RollingStdev(const MqlRates &rates[], int i)
{
   if(i < 1) return EMPTY_VALUE;
   double sum = 0.0, sumSq = 0.0;
   int count = 0;
   for(int j = 0; j < StdevWindow; j++)
   {
      int idx = i - j;
      if(idx < 1) break;
      double diff = rates[idx].close - rates[idx-1].close;
      sum += diff; sumSq += diff * diff; count++;
   }
   if(count < StdevWindow) return EMPTY_VALUE;
   double mean = sum / StdevWindow;
   double var  = sumSq / StdevWindow - mean * mean;
   return MathSqrt(MathMax(var, 0.0));
}

//+------------------------------------------------------------------+
//| Detect a position that vanished without us closing it (SL hit    |
//| or manual close): block same-side re-entry until the next cross. |
//+------------------------------------------------------------------+
void TrackPosition()
{
   bool b = HasPositionType(POSITION_TYPE_BUY);
   bool s = HasPositionType(POSITION_TYPE_SELL);
   int side = 0;
   if(b && !s) side = 1;
   else if(s && !b) side = -1;

   if(TrackedSide != 0 && !b && !s && TrackedSide == TargetSide)
   {
      BlockedSide = TrackedSide;
      Print("Position closed by stop. Waiting for the next zero-cross before re-entering.");
   }

   TrackedSide = side;
}

//+------------------------------------------------------------------+
void OnTick()
{
   TrackPosition();
   if(UseATRTrail) ManageTrailingStop();

   UpdateTarget();      // once per new closed bar
   SyncPosition();      // every tick: retries until the position matches the target

   static datetime lastDash = 0;
   if(TimeCurrent() != lastDash)
   {
      lastDash = TimeCurrent();
      UpdateDashboard();
   }
}

//+------------------------------------------------------------------+
//| New closed bar: recompute forecast and set the target side       |
//+------------------------------------------------------------------+
void UpdateTarget()
{
   datetime barTime = iTime(_Symbol, SignalTimeframe, 0);
   if(barTime == 0 || barTime == LastProcessedBar) return;

   double now = 0.0, prev = 0.0;
   if(!CalculateForecasts(now, prev)) return;

   LastProcessedBar  = barTime;
   PreviousForecast  = prev;
   LastForecast      = now;
   ForecastAvailable = true;

   int s = (now > 0.0) ? 1 : ((now < 0.0) ? -1 : 0);
   if(s != 0 && s != TargetSide)
   {
      bool crossed = (prev <= 0.0 && now > 0.0) || (prev >= 0.0 && now < 0.0);
      if(TargetSide != 0 || TradeCurrentTrend || crossed)
      {
         TargetSide  = s;
         BlockedSide = 0;     // a fresh crossover always clears the stop-out block
         Print("Forecast ", DoubleToString(now, 2), " -> target ", (s == 1 ? "BUY" : "SELL"));
      }
   }
}

//+------------------------------------------------------------------+
//| Make the open position match the target side                     |
//+------------------------------------------------------------------+
void SyncPosition()
{
   if(TargetSide == 0) return;
   if(BlockedSide == TargetSide) return;   // stopped out: wait for the next cross

   ENUM_POSITION_TYPE targetType = (TargetSide == 1) ? POSITION_TYPE_BUY  : POSITION_TYPE_SELL;
   ENUM_POSITION_TYPE oppType    = (TargetSide == 1) ? POSITION_TYPE_SELL : POSITION_TYPE_BUY;
   if(HasPositionType(targetType) && !HasPositionType(oppType)) return;

   if(TimeCurrent() == LastAttempt) return;  // at most one attempt per second
   LastAttempt = TimeCurrent();

   ExecuteSignal(TargetSide);
}

//+------------------------------------------------------------------+
bool CalculateForecasts(double &forecastNow, double &forecastPrevious)
{
   forecastNow = 0.0; forecastPrevious = 0.0;
   int barsNeeded = MathMax(WarmupBars, SlowPeriod + StdevWindow + 50);

   MqlRates rates[];
   ArraySetAsSeries(rates, false);
   int copied = CopyRates(_Symbol, SignalTimeframe, 0, barsNeeded, rates);
   if(copied <= 0 || copied < SlowPeriod + StdevWindow + 10) return false;

   int n = copied;
   double fastEMA[], slowEMA[];
   ArrayResize(fastEMA, n); ArrayResize(slowEMA, n);
   ArrayInitialize(fastEMA, 0.0); ArrayInitialize(slowEMA, 0.0);

   double fseed = 0.0, sseed = 0.0;
   for(int i = 0; i < FastPeriod; i++) fseed += rates[i].close;
   for(int i = 0; i < SlowPeriod; i++) sseed += rates[i].close;
   fseed /= (double)FastPeriod; sseed /= (double)SlowPeriod;

   double alphaFast = 2.0 / (FastPeriod + 1.0);
   double alphaSlow = 2.0 / (SlowPeriod + 1.0);

   fastEMA[FastPeriod - 1] = fseed;
   for(int i = FastPeriod; i < n; i++) fastEMA[i] = alphaFast * rates[i].close + (1.0 - alphaFast) * fastEMA[i-1];
   slowEMA[SlowPeriod - 1] = sseed;
   for(int i = SlowPeriod; i < n; i++) slowEMA[i] = alphaSlow * rates[i].close + (1.0 - alphaSlow) * slowEMA[i-1];

   int latestClosed   = n - 2;
   int previousClosed = n - 3;
   if(previousClosed < SlowPeriod) return false;

   double stdevNow  = RollingStdev(rates, latestClosed);
   double stdevPrev = RollingStdev(rates, previousClosed);

   if(stdevNow == EMPTY_VALUE || stdevNow < _Point * 0.1) stdevNow = rates[latestClosed].close * 0.002;
   if(stdevPrev == EMPTY_VALUE || stdevPrev < _Point * 0.1) stdevPrev = rates[previousClosed].close * 0.002;
   if(stdevNow <= 0.0 || stdevPrev <= 0.0) return false;

   double rawNow  = fastEMA[latestClosed] - slowEMA[latestClosed];
   double rawPrev = fastEMA[previousClosed] - slowEMA[previousClosed];

   forecastNow      = MathMax(ForecastCapMin, MathMin(ForecastCapMax, (rawNow / stdevNow) * ForecastScalar));
   forecastPrevious = MathMax(ForecastCapMin, MathMin(ForecastCapMax, (rawPrev / stdevPrev) * ForecastScalar));
   return true;
}

//+------------------------------------------------------------------+
//| ATR helpers                                                      |
//+------------------------------------------------------------------+
double GetATR()
{
   if(hATR == INVALID_HANDLE) return 0.0;
   double b[1];
   if(CopyBuffer(hATR, 0, 1, 1, b) != 1) return 0.0;
   if(b[0] > 0.0) LastATR = b[0];
   return b[0];
}

double NormalizePrice(double p)
{
   double tick = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   if(tick > 0.0) p = MathRound(p / tick) * tick;
   return NormalizeDouble(p, _Digits);
}

double MinStopDist()
{
   long stops  = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
   long freeze = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_FREEZE_LEVEL);
   return (double)MathMax(stops, freeze) * _Point;
}

// Initial stop for a new order, measured from the closing side of the market
double InitialStop(int signal, const MqlTick &tk)
{
   if(!UseATRTrail) return 0.0;
   double atr = GetATR();
   if(atr <= 0.0) return 0.0;                       // ManageTrailingStop() sets it on the next tick
   double dist = MathMax(ATRMultiplier * atr, MinStopDist() + 2.0 * _Point);
   double sl = (signal == 1) ? tk.bid - dist : tk.ask + dist;
   return NormalizePrice(sl);
}

//+------------------------------------------------------------------+
//| Ratchet the broker-side SL: only ever moves in our favour        |
//+------------------------------------------------------------------+
void ManageTrailingStop()
{
   if(PositionsTotal() == 0) return;
   double atr = GetATR();
   if(atr <= 0.0) return;
   MqlTick tk; if(!SymbolInfoTick(_Symbol, tk)) return;

   double minD = MinStopDist();
   double dist = MathMax(ATRMultiplier * atr, minD + 2.0 * _Point);
   double step = MathMax(TrailStepATR * atr, _Point);

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0 || !PositionSelectByTicket(ticket)) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol || (ulong)PositionGetInteger(POSITION_MAGIC) != MagicNumber) continue;

      ENUM_POSITION_TYPE pt = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
      double open = PositionGetDouble(POSITION_PRICE_OPEN);
      double sl   = PositionGetDouble(POSITION_SL);
      double tp   = PositionGetDouble(POSITION_TP);
      double newSL = 0.0;
      bool   modify = false;

      if(pt == POSITION_TYPE_BUY)
      {
         if(sl <= 0.0)
         {
            newSL = MathMin(open, tk.bid) - dist;                    // no stop yet -> initial stop
            modify = true;
         }
         else if(tk.bid - open >= TrailStartATR * atr)
         {
            double cand = tk.bid - dist;
            if(cand > sl + step) { newSL = cand; modify = true; }    // ratchet up
         }
         if(modify)
         {
            if(tk.bid - newSL < minD) newSL = tk.bid - minD;
            newSL = NormalizePrice(newSL);
            if(sl > 0.0 && newSL <= sl) modify = false;
         }
      }
      else
      {
         if(sl <= 0.0)
         {
            newSL = MathMax(open, tk.ask) + dist;
            modify = true;
         }
         else if(open - tk.ask >= TrailStartATR * atr)
         {
            double cand = tk.ask + dist;
            if(cand < sl - step) { newSL = cand; modify = true; }    // ratchet down
         }
         if(modify)
         {
            if(newSL - tk.ask < minD) newSL = tk.ask + minD;
            newSL = NormalizePrice(newSL);
            if(sl > 0.0 && newSL >= sl) modify = false;
         }
      }

      if(modify && !trade.PositionModify(ticket, newSL, tp))
         ThrottledPrint("TRAIL MODIFY FAILED retcode=" + IntegerToString(trade.ResultRetcode()) + " " + trade.ResultRetcodeDescription());
   }
}

//+------------------------------------------------------------------+
//| Close the opposite side (if any) and open the target side        |
//+------------------------------------------------------------------+
bool ExecuteSignal(int signal)
{
   if(signal != 1 && signal != -1) return false;

   ENUM_POSITION_TYPE targetType = (signal == 1) ? POSITION_TYPE_BUY  : POSITION_TYPE_SELL;
   ENUM_POSITION_TYPE oppType    = (signal == 1) ? POSITION_TYPE_SELL : POSITION_TYPE_BUY;

   if(HasPositionType(targetType) && !HasPositionType(oppType)) return true;

   if(!TerminalInfoInteger(TERMINAL_TRADE_ALLOWED) || !MQLInfoInteger(MQL_TRADE_ALLOWED) || !AccountInfoInteger(ACCOUNT_TRADE_ALLOWED))
   {
      ThrottledPrint("BLOCKED: trading not allowed (check AutoTrading button / EA 'Allow Algo Trading' / account)");
      return false;
   }
   if(!SymbolSelect(_Symbol, true)) { ThrottledPrint("BLOCKED: SymbolSelect failed"); return false; }

   MqlTick tick; if(!SymbolInfoTick(_Symbol, tick)) { ThrottledPrint("BLOCKED: no tick"); return false; }

   if(!CloseOppositePositions(targetType))
   {
      ThrottledPrint("BLOCKED: failed to close opposite position retcode=" + IntegerToString(trade.ResultRetcode()) + " " + trade.ResultRetcodeDescription());
      return false;
   }
   if(HasPositionType(targetType)) return true;

   double lots = CalculateLots();
   if(lots <= 0.0) { ThrottledPrint("BLOCKED: lot size is 0 (check MaxLots / min lot / sizing inputs)"); return false; }

   if(!SymbolInfoTick(_Symbol, tick)) return false;
   double price = (signal == 1) ? tick.ask : tick.bid;
   ENUM_ORDER_TYPE orderType = (signal == 1) ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;

   double marginRequired = 0.0;
   if(!OrderCalcMargin(orderType, _Symbol, lots, price, marginRequired))
   {
      ThrottledPrint("BLOCKED: OrderCalcMargin failed");
      return false;
   }
   if(marginRequired > AccountInfoDouble(ACCOUNT_MARGIN_FREE))
   {
      ThrottledPrint("BLOCKED: not enough free margin. Required " + DoubleToString(marginRequired, 2)
                     + " free " + DoubleToString(AccountInfoDouble(ACCOUNT_MARGIN_FREE), 2));
      return false;
   }

   double sl = InitialStop(signal, tick);

   bool ok = (signal == 1) ? trade.Buy(lots, _Symbol, 0.0, sl, 0.0, "EWMAC BUY") : trade.Sell(lots, _Symbol, 0.0, sl, 0.0, "EWMAC SELL");
   uint ret = trade.ResultRetcode();

   // broker rejected the stop distance: open without SL, ManageTrailingStop() attaches it next tick
   if(!ok && sl > 0.0 && ret == TRADE_RETCODE_INVALID_STOPS)
   {
      ok  = (signal == 1) ? trade.Buy(lots, _Symbol, 0.0, 0.0, 0.0, "EWMAC BUY") : trade.Sell(lots, _Symbol, 0.0, 0.0, 0.0, "EWMAC SELL");
      ret = trade.ResultRetcode();
   }

   if(ok && (ret == TRADE_RETCODE_DONE || ret == TRADE_RETCODE_DONE_PARTIAL || ret == TRADE_RETCODE_PLACED))
   {
      string msg = "EWMAC " + ((signal == 1) ? "BUY" : "SELL") + " | " + _Symbol + " | Lots " + DoubleToString(lots, 4)
                 + (sl > 0.0 ? " | SL " + DoubleToString(sl, _Digits) : "");
      Print(msg); if(SendPopup) Alert(msg); if(SendPush) SendNotification(msg);
      return true;
   }
   ThrottledPrint("ORDER FAILED retcode=" + IntegerToString(ret) + " " + trade.ResultRetcodeDescription());
   return false;
}

//+------------------------------------------------------------------+
double CalculateLots()
{
   double lots = (SizingMode == SIZE_FIXED_LOT) ? FixedLots : 0.0;
   if(SizingMode == SIZE_EQUITY_RISK_REFERENCE)
   {
      double equity = AccountInfoDouble(ACCOUNT_EQUITY), riskMoney = equity * (RiskPercent / 100.0);
      double tickSize = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE), tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
      if(equity <= 0 || riskMoney <= 0 || tickSize <= 0 || tickValue <= 0) return 0.0;
      double lossPerLot = (SizingReferencePoints * _Point / tickSize) * tickValue;
      if(lossPerLot <= 0) return 0.0;
      lots = riskMoney / lossPerLot;
   }
   if(UseForecastSizing)
      lots *= MathMax(0.5, MathMin(2.0, MathAbs(LastForecast) / 10.0));
   return NormalizeLotsDown(MathMin(lots, MaxLots));
}

//+------------------------------------------------------------------+
double NormalizeLotsDown(double lots)
{
   double minLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN), maxLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX), lotStep = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   if(minLot <= 0 || maxLot <= 0 || lotStep <= 0) return 0.0;
   double permittedMax = MathMin(maxLot, MaxLots);
   if(permittedMax < minLot) return 0.0;
   lots = MathMin(lots, permittedMax);
   if(lots < minLot) { if(UseMinLotIfBelow && minLot <= permittedMax) lots = minLot; else return 0.0; }
   lots = MathFloor((lots + 1e-12) / lotStep) * lotStep;
   int digits = 0; double s = lotStep;
   while(digits < 8 && MathAbs(s - MathRound(s)) > 1e-8) { s *= 10.0; digits++; }
   lots = NormalizeDouble(lots, digits);
   return (lots < minLot || lots > permittedMax) ? 0.0 : lots;
}

//+------------------------------------------------------------------+
bool CloseOppositePositions(ENUM_POSITION_TYPE targetType)
{
   bool allClosed = true;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0 || !PositionSelectByTicket(ticket)) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol || (ulong)PositionGetInteger(POSITION_MAGIC) != MagicNumber) continue;
      if((ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE) == targetType) continue;
      if(!trade.PositionClose(ticket)) allClosed = false;
   }
   return allClosed;
}

//+------------------------------------------------------------------+
bool HasPositionType(ENUM_POSITION_TYPE requestedType)
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0 || !PositionSelectByTicket(ticket)) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol || (ulong)PositionGetInteger(POSITION_MAGIC) != MagicNumber) continue;
      if((ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE) == requestedType) return true;
   }
   return false;
}

//+------------------------------------------------------------------+
//| First position of ours: returns its SL and type                  |
//+------------------------------------------------------------------+
bool GetOurPosition(double &sl, ENUM_POSITION_TYPE &pt)
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0 || !PositionSelectByTicket(ticket)) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol || (ulong)PositionGetInteger(POSITION_MAGIC) != MagicNumber) continue;
      sl = PositionGetDouble(POSITION_SL);
      pt = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
      return true;
   }
   sl = 0.0;
   return false;
}

//+------------------------------------------------------------------+
//| Chart drawing of the trailing stop                               |
//+------------------------------------------------------------------+
void DrawTrail()
{
   if(!ShowTrailOnChart || !UseATRTrail)
   {
      ObjectsDeleteAll(0, TrailPrefix);
      TrailHadPos = false; LastDrawnSL = 0.0;
      return;
   }

   string lineName = TrailPrefix + "LINE";
   string txtName  = TrailPrefix + "TXT";

   double sl = 0.0;
   ENUM_POSITION_TYPE pt = POSITION_TYPE_BUY;
   bool has = GetOurPosition(sl, pt);

   if(!has)
   {
      ObjectDelete(0, lineName);
      ObjectDelete(0, txtName);
      TrailHadPos = false; LastDrawnSL = 0.0;
      return;                                   // dots of the last trade stay until the next position opens
   }
   if(sl <= 0.0)
   {
      ObjectDelete(0, lineName);
      ObjectDelete(0, txtName);
      return;
   }

   if(!TrailHadPos)                             // new position: clear the previous trade's dots
   {
      ObjectsDeleteAll(0, TrailPrefix + "D");
      TrailDotCount = 0;
      TrailHadPos   = true;
      LastDrawnSL   = 0.0;
   }

   color trailClr = clrOrangeRed;

   if(ObjectFind(0, lineName) < 0)
   {
      ObjectCreate(0, lineName, OBJ_HLINE, 0, 0, sl);
      ObjectSetInteger(0, lineName, OBJPROP_COLOR, trailClr);
      ObjectSetInteger(0, lineName, OBJPROP_STYLE, STYLE_DASH);
      ObjectSetInteger(0, lineName, OBJPROP_WIDTH, 1);
      ObjectSetInteger(0, lineName, OBJPROP_SELECTABLE, false);
      ObjectSetInteger(0, lineName, OBJPROP_BACK, false);
      ObjectSetInteger(0, lineName, OBJPROP_HIDDEN, true);
   }
   ObjectSetDouble(0, lineName, OBJPROP_PRICE, sl);

   datetime t0 = iTime(_Symbol, _Period, 0);
   if(ObjectFind(0, txtName) < 0)
   {
      ObjectCreate(0, txtName, OBJ_TEXT, 0, t0, sl);
      ObjectSetInteger(0, txtName, OBJPROP_COLOR, trailClr);
      ObjectSetInteger(0, txtName, OBJPROP_FONTSIZE, 8);
      ObjectSetString (0, txtName, OBJPROP_FONT, "Consolas");
      ObjectSetInteger(0, txtName, OBJPROP_SELECTABLE, false);
      ObjectSetInteger(0, txtName, OBJPROP_HIDDEN, true);
   }
   ObjectMove(0, txtName, 0, t0, sl);
   ObjectSetInteger(0, txtName, OBJPROP_ANCHOR, (pt == POSITION_TYPE_BUY) ? ANCHOR_RIGHT_UPPER : ANCHOR_RIGHT_LOWER);
   ObjectSetString (0, txtName, OBJPROP_TEXT, "ATR TRAIL SL " + DoubleToString(sl, _Digits));

   if(sl != LastDrawnSL)                        // SL moved: leave a dot on the trail path
   {
      TrailDotCount++;
      string dotName = TrailPrefix + "D" + IntegerToString(TrailDotCount);
      ObjectCreate(0, dotName, OBJ_ARROW, 0, t0, sl);
      ObjectSetInteger(0, dotName, OBJPROP_ARROWCODE, 158);
      ObjectSetInteger(0, dotName, OBJPROP_COLOR, trailClr);
      ObjectSetInteger(0, dotName, OBJPROP_WIDTH, 1);
      ObjectSetInteger(0, dotName, OBJPROP_SELECTABLE, false);
      ObjectSetInteger(0, dotName, OBJPROP_HIDDEN, true);
      if(TrailDotCount > 400) ObjectDelete(0, TrailPrefix + "D" + IntegerToString(TrailDotCount - 400));
      LastDrawnSL = sl;
   }
}

//+------------------------------------------------------------------+
//| Detect if the chart background is light or dark                  |
//+------------------------------------------------------------------+
bool IsLightChart()
{
   color bg = (color)ChartGetInteger(0, CHART_COLOR_BACKGROUND);
   uint argb = ColorToARGB(bg, 255);
   uchar r = (uchar)((argb >> 16) & 0xFF);
   uchar g = (uchar)((argb >> 8) & 0xFF);
   uchar b = (uchar)(argb & 0xFF);
   double lum = 0.299 * r + 0.587 * g + 0.114 * b;
   return (lum > 128.0);
}

//+------------------------------------------------------------------+
//| DASHBOARD (DYNAMIC COLORS FOR LIGHT/DARK CHARTS)                 |
//+------------------------------------------------------------------+
void UpdateDashboard()
{
   DrawTrail();

   if(!ShowComment)
   {
      ObjectsDeleteAll(0, DashPrefix);
      return;
   }

   bool isLight = IsLightChart();

   color bgClr     = isLight ? C'245,245,245' : C'15,15,15';
   color borderClr = isLight ? clrGray : clrDimGray;
   color textClr   = isLight ? clrBlack : clrWhite;
   color headerClr = isLight ? clrSaddleBrown : clrGold;
   color bullClr   = isLight ? clrGreen : clrLime;
   color bearClr   = clrRed;
   color neutralClr= isLight ? clrDarkOrange : clrYellow;
   color posClr    = isLight ? clrBlue : clrAqua;

   string direction = "CALCULATING";
   if(ForecastAvailable)
   {
      if(LastForecast > 0.0)       direction = "BULLISH";
      else if(LastForecast < 0.0)  direction = "BEARISH";
      else                         direction = "NEUTRAL";
   }

   string positionText = "FLAT";
   bool hasBuy = HasPositionType(POSITION_TYPE_BUY), hasSell = HasPositionType(POSITION_TYPE_SELL);
   if(hasBuy && hasSell) positionText = "BUY + SELL";
   else if(hasBuy)       positionText = "BUY";
   else if(hasSell)      positionText = "SELL";

   string targetText = (TargetSide == 1) ? "BUY" : (TargetSide == -1 ? "SELL" : "NONE");
   if(TargetSide != 0 && BlockedSide == TargetSide) targetText += " (WAIT CROSS)";
   string sizingText = (SizingMode == SIZE_FIXED_LOT) ? "Fixed " + DoubleToString(FixedLots, 4) : "Risk " + DoubleToString(RiskPercent, 2) + "%";

   double curSL = 0.0; ENUM_POSITION_TYPE curType = POSITION_TYPE_BUY;
   GetOurPosition(curSL, curType);
   string atrText = UseATRTrail ? DoubleToString(LastATR, _Digits) + " x" + DoubleToString(ATRMultiplier, 1) : "OFF";
   string slText  = !UseATRTrail ? "DISABLED" : (curSL > 0.0 ? DoubleToString(curSL, _Digits) : "NONE");

   string lines[16];
   lines[0]  = "AMARE CAPITAL - EWMAC v3.00";
   lines[1]  = "----------------------------------";
   lines[2]  = "Symbol:   " + _Symbol;
   lines[3]  = "TF:       " + EnumToString(SignalTimeframe);
   lines[4]  = "EWMAC:    " + IntegerToString(FastPeriod) + "/" + IntegerToString(SlowPeriod);
   lines[5]  = "Scalar:   " + DoubleToString(ForecastScalar, 2);
   lines[6]  = "Forecast: " + DoubleToString(LastForecast, 2);
   lines[7]  = "Previous: " + DoubleToString(PreviousForecast, 2);
   lines[8]  = "Trend:    " + direction;
   lines[9]  = "Position: " + positionText;
   lines[10] = "Target:   " + targetText;
   lines[11] = "Sizing:   " + sizingText;
   lines[12] = "Max lots: " + DoubleToString(MaxLots, 4);
   lines[13] = "ATR:      " + atrText;
   lines[14] = "Trail SL: " + slText;
   lines[15] = "----------------------------------";

   string bgName = DashPrefix + "BG";
   if(ObjectFind(0, bgName) < 0)
   {
      ObjectCreate(0, bgName, OBJ_RECTANGLE_LABEL, 0, 0, 0);
      ObjectSetInteger(0, bgName, OBJPROP_CORNER, CORNER_RIGHT_UPPER);
      ObjectSetInteger(0, bgName, OBJPROP_XDISTANCE, 10);
      ObjectSetInteger(0, bgName, OBJPROP_YDISTANCE, 20);
      ObjectSetInteger(0, bgName, OBJPROP_BORDER_TYPE, BORDER_FLAT);
      ObjectSetInteger(0, bgName, OBJPROP_BACK, false);
      ObjectSetInteger(0, bgName, OBJPROP_SELECTABLE, false);
   }
   ObjectSetInteger(0, bgName, OBJPROP_XSIZE, 220);
   ObjectSetInteger(0, bgName, OBJPROP_YSIZE, 20 + DASH_LINES * 15);
   ObjectSetInteger(0, bgName, OBJPROP_BGCOLOR, bgClr);
   ObjectSetInteger(0, bgName, OBJPROP_COLOR, borderClr);

   for(int i = 0; i < DASH_LINES; i++)
   {
      string name = DashPrefix + "L" + IntegerToString(i);
      if(ObjectFind(0, name) < 0)
      {
         ObjectCreate(0, name, OBJ_LABEL, 0, 0, 0);
         ObjectSetInteger(0, name, OBJPROP_CORNER, CORNER_RIGHT_UPPER);
         ObjectSetInteger(0, name, OBJPROP_ANCHOR, ANCHOR_RIGHT_UPPER);
         ObjectSetInteger(0, name, OBJPROP_XDISTANCE, 220);
         ObjectSetString(0, name, OBJPROP_FONT, "Consolas");
         ObjectSetInteger(0, name, OBJPROP_FONTSIZE, 9);
         ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
         ObjectSetInteger(0, name, OBJPROP_BACK, false);
      }

      ObjectSetInteger(0, name, OBJPROP_YDISTANCE, 30 + (i * 15));
      ObjectSetString(0, name, OBJPROP_TEXT, lines[i]);

      if(i == 8) // Trend
      {
         color trendClr = textClr;
         if(direction == "BULLISH") trendClr = bullClr;
         else if(direction == "BEARISH") trendClr = bearClr;
         else if(direction == "NEUTRAL") trendClr = neutralClr;
         ObjectSetInteger(0, name, OBJPROP_COLOR, trendClr);
      }
      else if(i == 9) // Position
      {
         ObjectSetInteger(0, name, OBJPROP_COLOR, (positionText == "FLAT") ? textClr : posClr);
      }
      else if(i == 14) // Trail SL
      {
         ObjectSetInteger(0, name, OBJPROP_COLOR, (curSL > 0.0) ? clrOrangeRed : textClr);
      }
      else if(i == 0) // Header
      {
         ObjectSetInteger(0, name, OBJPROP_COLOR, headerClr);
      }
      else
      {
         ObjectSetInteger(0, name, OBJPROP_COLOR, textClr);
      }
   }
}

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   if(hATR != INVALID_HANDLE) IndicatorRelease(hATR);
   ObjectsDeleteAll(0, DashPrefix);
   ObjectsDeleteAll(0, TrailPrefix);
   Comment("");
   Print("EWMAC EA stopped. Reason: ", reason);
}
//+------------------------------------------------------------------+