//+------------------------------------------------------------------+
//|                                                   EWMAC_EA.mq5   |
//|                 AMARE CAPITAL MANAGEMENT                         |
//|                 EWMAC Stop-and-Reverse at forecast 0             |
//|                 Version 4.00 (Fixed lot)                         |
//|                 Forecast math MATCHES EWMAC_Forecast.mq5         |
//|                                                                  |
//|  Rules:                                                          |
//|   - forecast > 0 = long, forecast < 0 = short (reverse at 0)     |
//|   - pure stop-and-reverse                                        |
//|   - if stopped out manually, waits for next zero-cross           |
//|   - signal timeframe is an input (independent of chart TF)       |
//|   - fixed lot size                                               |
//+------------------------------------------------------------------+
#property strict
#property version   "4.00"
#property description "EWMAC pure stop-and-reverse."
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

//+------------------------------------------------------------------+
//| INPUTS                                                           |
//+------------------------------------------------------------------+
input group "EWMAC Strategy"
input ENUM_EWMAC_PAIR EWMACPair         = EWMAC_8_32;
input ENUM_TIMEFRAMES SignalTimeframe   = PERIOD_M1;   // timeframe the forecast is computed on
input int    StdevWindow                = 50;
input double ForecastCapMin             = -20.0;
input double ForecastCapMax             =  20.0;
input int    WarmupBars                 = 1000;
input bool   TradeCurrentTrend          = true;   // true = enter immediately in current forecast direction on attach
input bool   UseCarverScalar            = true;

input group "Position Sizing"
input double FixedLots                  = 0.01;   // only lot size control

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

string DashPrefix = "EWMAC_DASH_";
const int DASH_LINES = 13;

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
   if(FixedLots <= 0.0) return INIT_PARAMETERS_INCORRECT;

   SetEWMACPeriods();
   SetForecastScalar();

   trade.SetExpertMagicNumber(MagicNumber);
   trade.SetDeviationInPoints(SlippagePts);
   trade.SetTypeFillingBySymbol(_Symbol);
   trade.SetAsyncMode(false);

   Print("==================================================");
   Print("AMARE CAPITAL - EWMAC EA v4.00");
   Print("Symbol: ", _Symbol, "  Signal TF: ", EnumToString(SignalTimeframe));
   Print("EWMAC: ", FastPeriod, "/", SlowPeriod, "  Scalar: ", DoubleToString(ForecastScalar, 2));
   Print("Stop-and-reverse at forecast 0. Fixed lot size only.");
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
//| Detect a position that vanished without us closing it (manual    |
//| close or external SL): block same-side re-entry until next cross |
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
      Print("Position closed externally. Waiting for the next zero-cross before re-entering.");
   }
   TrackedSide = side;
}

//+------------------------------------------------------------------+
void OnTick()
{
   TrackPosition();
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
         BlockedSide = 0;     // a fresh crossover always clears the block
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
   for(int i = FastPeriod; i < n; i++)
      fastEMA[i] = alphaFast * rates[i].close + (1.0 - alphaFast) * fastEMA[i-1];

   slowEMA[SlowPeriod - 1] = sseed;
   for(int i = SlowPeriod; i < n; i++)
      slowEMA[i] = alphaSlow * rates[i].close + (1.0 - alphaSlow) * slowEMA[i-1];

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

   MqlTick tick;
   if(!SymbolInfoTick(_Symbol, tick)) { ThrottledPrint("BLOCKED: no tick"); return false; }

   if(!CloseOppositePositions(targetType))
   {
      ThrottledPrint("BLOCKED: failed to close opposite position retcode=" + IntegerToString(trade.ResultRetcode()) + " " + trade.ResultRetcodeDescription());
      return false;
   }

   if(HasPositionType(targetType)) return true;

   double lots = NormalizeLots(FixedLots);
   if(lots <= 0.0)
   {
      ThrottledPrint("BLOCKED: invalid lot size after normalization");
      return false;
   }

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

   bool ok = (signal == 1)
             ? trade.Buy(lots, _Symbol, 0.0, 0.0, 0.0, "EWMAC BUY")
             : trade.Sell(lots, _Symbol, 0.0, 0.0, 0.0, "EWMAC SELL");

   uint ret = trade.ResultRetcode();

   if(ok && (ret == TRADE_RETCODE_DONE || ret == TRADE_RETCODE_DONE_PARTIAL || ret == TRADE_RETCODE_PLACED))
   {
      string msg = "EWMAC " + ((signal == 1) ? "BUY" : "SELL") + " | " + _Symbol + " | Lots " + DoubleToString(lots, 4);
      Print(msg);
      if(SendPopup) Alert(msg);
      if(SendPush) SendNotification(msg);
      return true;
   }

   ThrottledPrint("ORDER FAILED retcode=" + IntegerToString(ret) + " " + trade.ResultRetcodeDescription());
   return false;
}

//+------------------------------------------------------------------+
//| Simple lot normalization (broker min/step/max only)              |
//+------------------------------------------------------------------+
double NormalizeLots(double lots)
{
   double minLot  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxLot  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double lotStep = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);

   if(minLot <= 0 || maxLot <= 0 || lotStep <= 0) return 0.0;

   lots = MathMax(minLot, MathMin(lots, maxLot));
   lots = MathFloor((lots + 1e-12) / lotStep) * lotStep;

   int digits = 0;
   double s = lotStep;
   while(digits < 8 && MathAbs(s - MathRound(s)) > 1e-8) { s *= 10.0; digits++; }

   lots = NormalizeDouble(lots, digits);
   return (lots < minLot || lots > maxLot) ? 0.0 : lots;
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
//| DASHBOARD                                                        |
//+------------------------------------------------------------------+
void UpdateDashboard()
{
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

   string lines[13];
   lines[0]  = "AMARE CAPITAL - EWMAC v4.00";
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
   lines[11] = "Lots:     " + DoubleToString(FixedLots, 4);
   lines[12] = "----------------------------------";

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
   ObjectsDeleteAll(0, DashPrefix);
   Comment("");
   Print("EWMAC EA stopped. Reason: ", reason);
}
//+------------------------------------------------------------------+