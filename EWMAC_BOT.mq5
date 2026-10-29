//+------------------------------------------------------------------+
//|                                                   EWMAC_BOT.mq5  |
//|                 AMARE CAPITAL MANAGEMENT                         |
//|                 Exponentially Weighted Moving Average Crossover  |
//|                 Version 5.00                                     |
//+------------------------------------------------------------------+
#property strict
#property version   "5.00"
#property description "EWMAC EA: entry/exit/trail."

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
input group "Timeframe"
input ENUM_TIMEFRAMES EntryTimeframe    = PERIOD_M1;  // entry, exit and trail
input bool   ExitOnEntryTFFlip          = true;       // close when forecast flips against trade
input bool   TradeCurrentTrend          = true;       // on attach, treat current direction as armed

input group "EWMAC Strategy"
input ENUM_EWMAC_PAIR EWMACPair         = EWMAC_8_32;
input int    StdevWindow                = 50;
input double ForecastCapMin             = -20.0;
input double ForecastCapMax             =  20.0;
input int    WarmupBars                 = 1000;
input bool   UseCarverScalar            = true;

input group "Position Sizing"
input double FixedLots                  = 0.01;

input group "ATR Trailing Stop (on Entry Timeframe)"
input bool   UseATRTrail                = true;  // true = enable ATR trailing stop
input int    ATR_Period                 = 14;     // ATR period
input double ATR_Multiplier             = 3.0;    // ATR multiplier for trail distance
input bool   PlotTrailOnChart           = true;   // draw current trail level on chart
input color  TrailColor                 = clrOrange;
input int    TrailWidth                 = 1;
input ENUM_LINE_STYLE TrailStyle        = STYLE_SOLID;

input group "ATR Trail History"
input color  TrailHistoryColor          = clrOrange;
input int    TrailHistoryWidth          = 1;
input ENUM_LINE_STYLE TrailHistoryStyle = STYLE_DOT;
input int    TrailHistoryMaxPoints      = 100;

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
struct TFState
{
   ENUM_TIMEFRAMES tf;
   datetime        lastBar;
   double          now;       // forecast on last closed bar
   double          prev;      // forecast on bar before
   bool            ready;
   int             side;      // +1 / -1 / 0
};

TFState  g_entry;

int      FastPeriod        = 8;
int      SlowPeriod        = 32;
double   ForecastScalar    = 5.3;

int      ArmedSide         = 0;      // entry TF cross waiting to be used
int      EntrySideSeen     = 0;      // last known entry TF sign
int      TrackedSide       = 0;
bool     g_closedByEA      = false;
datetime LastAttempt       = 0;
datetime LastCloseAttempt  = 0;
int      g_atr_handle      = INVALID_HANDLE;

string DashPrefix = "EWMAC_DASH_";
const int DASH_LINES = 13;

string TrailObjName = "EWMAC_ATR_TRAIL";
string TrailHistPrefix = "EWMAC_TRAIL_HIST_";

datetime g_trailTimes[];
double   g_trailPrices[];
int      g_trailCount = 0;
ulong    g_currentTrailTicket = 0;

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
void AddTrailHistoryPoint(datetime t, double price)
{
    if(g_trailCount > 0 && g_trailPrices[g_trailCount-1] == price) return;

    if(g_trailCount >= TrailHistoryMaxPoints)
    {
        for(int i = 1; i < TrailHistoryMaxPoints; i++)
        {
            g_trailTimes[i-1]  = g_trailTimes[i];
            g_trailPrices[i-1] = g_trailPrices[i];
        }
        g_trailCount--;
    }

    ArrayResize(g_trailTimes, g_trailCount + 1);
    ArrayResize(g_trailPrices, g_trailCount + 1);
    g_trailTimes[g_trailCount]  = t;
    g_trailPrices[g_trailCount] = price;
    g_trailCount++;
}

//+------------------------------------------------------------------+
void InitTF(TFState &st, ENUM_TIMEFRAMES tf)
{
   st.tf      = tf;
   st.lastBar = 0;
   st.now     = 0.0;
   st.prev    = 0.0;
   st.ready   = false;
   st.side    = 0;
}

//+------------------------------------------------------------------+
int OnInit()
{
   if(StdevWindow < 2) return INIT_PARAMETERS_INCORRECT;
   if(WarmupBars < 100) return INIT_PARAMETERS_INCORRECT;
   if(ForecastCapMin >= ForecastCapMax) return INIT_PARAMETERS_INCORRECT;
   if(FixedLots <= 0.0) return INIT_PARAMETERS_INCORRECT;
   if(UseATRTrail && (ATR_Period < 1 || ATR_Multiplier <= 0.0)) return INIT_PARAMETERS_INCORRECT;

   SetEWMACPeriods();
   SetForecastScalar();

   InitTF(g_entry, EntryTimeframe);
   ArmedSide = 0; EntrySideSeen = 0; TrackedSide = 0; g_closedByEA = false;

   trade.SetExpertMagicNumber(MagicNumber);
   trade.SetDeviationInPoints(SlippagePts);
   trade.SetTypeFillingBySymbol(_Symbol);
   trade.SetAsyncMode(false);

   g_atr_handle = iATR(_Symbol, EntryTimeframe, ATR_Period);
   if(g_atr_handle == INVALID_HANDLE)
   {
      Print("Failed to create ATR handle. Error: ", GetLastError());
      return INIT_FAILED;
   }

   Print("==================================================");
   Print("AMARE CAPITAL MANAGEMENT - EWMAC EA v5.00");
   Print("Entry ", TFName(EntryTimeframe));
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
string TFName(ENUM_TIMEFRAMES tf)
{
   return StringSubstr(EnumToString(tf), 7);
}

//+------------------------------------------------------------------+
int SignOf(double v)
{
   return (v > 0.0) ? 1 : ((v < 0.0) ? -1 : 0);
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
void TrackPosition()
{
   bool b = HasPositionType(POSITION_TYPE_BUY);
   bool s = HasPositionType(POSITION_TYPE_SELL);
   int side = 0;
   if(b && !s) side = 1;
   else if(s && !b) side = -1;

   // Position vanished without the EA closing it (SL / manual): wait for next entry-TF cross
   if(TrackedSide != 0 && !b && !s)
   {
      if(!g_closedByEA)
      {
         ArmedSide = 0;
         Print("Position closed externally. Waiting for next ", TFName(EntryTimeframe), " zero-cross.");
      }
      g_closedByEA = false;
   }
   if(side != 0) g_closedByEA = false;
   TrackedSide = side;
}

//+------------------------------------------------------------------+
void OnTick()
{
   TrackPosition();
   UpdateSignals();
   ManageExit();
   TryEntry();
   ManageATRTrail();
   UpdateTrailPlot();

   static datetime lastDash = 0;
   if(TimeCurrent() != lastDash)
   {
      lastDash = TimeCurrent();
      UpdateDashboard();
   }
}

//+------------------------------------------------------------------+
// Refresh timeframe on its own new bar. Returns true when a new bar was processed.
bool RefreshTF(TFState &st)
{
   datetime barTime = iTime(_Symbol, st.tf, 0);
   if(barTime == 0 || barTime == st.lastBar) return false;

   double now = 0.0, prev = 0.0;
   if(!CalculateForecasts(st.tf, now, prev)) return false;

   st.lastBar = barTime;
   st.prev    = prev;
   st.now     = now;
   st.ready   = true;
   st.side    = SignOf(now);
   return true;
}

//+------------------------------------------------------------------+
void UpdateSignals()
{
   if(RefreshTF(g_entry)) ArmEntrySignal();
}

//+------------------------------------------------------------------+
// Entry TF zero-cross arms a trade for that side (one use per cross)
void ArmEntrySignal()
{
   int s = g_entry.side;
   if(s == 0 || s == EntrySideSeen) return;

   bool crossed = (g_entry.prev <= 0.0 && g_entry.now > 0.0) || (g_entry.prev >= 0.0 && g_entry.now < 0.0);
   if(EntrySideSeen != 0 || TradeCurrentTrend || crossed)
   {
      ArmedSide = s;
      Print(TFName(EntryTimeframe), " forecast ", DoubleToString(g_entry.now, 2), " -> armed ", (s == 1 ? "BUY" : "SELL"));
   }
   EntrySideSeen = s;
}

//+------------------------------------------------------------------+
void ManageExit()
{
   bool hb = HasPositionType(POSITION_TYPE_BUY);
   bool hs = HasPositionType(POSITION_TYPE_SELL);
   if(!hb && !hs) return;

   int p = (hb && !hs) ? 1 : ((hs && !hb) ? -1 : 0);

   bool exitEntry = (p != 0) && ExitOnEntryTFFlip && g_entry.ready && g_entry.side == -p;
   if(p != 0 && !exitEntry) return;

   if(TimeCurrent() == LastCloseAttempt) return;
   LastCloseAttempt = TimeCurrent();

   if(CloseAllPositions())
   {
      g_closedByEA = true;
      string why = (p == 0) ? "conflicting positions" : TFName(EntryTimeframe) + " flip";
      string msg = "EWMAC EXIT | " + _Symbol + " | " + why;
      Print(msg);
      if(SendPopup) Alert(msg);
      if(SendPush) SendNotification(msg);
   }
}

//+------------------------------------------------------------------+
void TryEntry()
{
   if(!g_entry.ready || g_entry.side == 0) return;
   if(ArmedSide != g_entry.side) return;
   if(HasPositionType(POSITION_TYPE_BUY) || HasPositionType(POSITION_TYPE_SELL)) return;

   if(TimeCurrent() == LastAttempt) return;
   LastAttempt = TimeCurrent();

   if(ExecuteSignal(g_entry.side)) ArmedSide = 0;
}

//+------------------------------------------------------------------+
bool CalculateForecasts(ENUM_TIMEFRAMES tf, double &forecastNow, double &forecastPrevious)
{
   forecastNow = 0.0; forecastPrevious = 0.0;
   int barsNeeded = MathMax(WarmupBars, SlowPeriod + StdevWindow + 50);
   MqlRates rates[];
   ArraySetAsSeries(rates, false);
   int copied = CopyRates(_Symbol, tf, 0, barsNeeded, rates);
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
bool ExecuteSignal(int signal)
{
   if(signal != 1 && signal != -1) return false;

   ENUM_POSITION_TYPE targetType = (signal == 1) ? POSITION_TYPE_BUY  : POSITION_TYPE_SELL;

   if(HasPositionType(targetType)) return true;

   if(!TerminalInfoInteger(TERMINAL_TRADE_ALLOWED) || !MQLInfoInteger(MQL_TRADE_ALLOWED) || !AccountInfoInteger(ACCOUNT_TRADE_ALLOWED))
   {
      ThrottledPrint("BLOCKED: trading not allowed");
      return false;
   }

   if(!SymbolSelect(_Symbol, true)) { ThrottledPrint("BLOCKED: SymbolSelect failed"); return false; }

   MqlTick tick;
   if(!SymbolInfoTick(_Symbol, tick)) { ThrottledPrint("BLOCKED: no tick"); return false; }

   double lots = NormalizeLots(FixedLots);
   if(lots <= 0.0)
   {
      ThrottledPrint("BLOCKED: invalid lot size after normalization");
      return false;
   }

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
      ThrottledPrint("BLOCKED: not enough free margin");
      return false;
   }

   double initialSL = 0.0;
   if(UseATRTrail && g_atr_handle != INVALID_HANDLE)
   {
      double atrBuf[];
      if(CopyBuffer(g_atr_handle, 0, 0, 1, atrBuf) > 0 && atrBuf[0] > 0.0)
      {
         double trailDist = atrBuf[0] * ATR_Multiplier;
         double minStopDist = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL) * _Point;
         if(minStopDist <= 0) minStopDist = _Point * 2;

         if(signal == 1)
         {
            initialSL = price - trailDist;
            if(initialSL > price - minStopDist) initialSL = price - minStopDist;
         }
         else
         {
            initialSL = price + trailDist;
            if(initialSL < price + minStopDist) initialSL = price + minStopDist;
         }
         initialSL = NormalizeDouble(initialSL, (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS));
      }
   }

   bool ok = (signal == 1)
             ? trade.Buy(lots, _Symbol, 0.0, initialSL, 0.0, "EWMAC BUY")
             : trade.Sell(lots, _Symbol, 0.0, initialSL, 0.0, "EWMAC SELL");

   uint ret = trade.ResultRetcode();

   if(ok && (ret == TRADE_RETCODE_DONE || ret == TRADE_RETCODE_DONE_PARTIAL || ret == TRADE_RETCODE_PLACED))
   {
      string msg = "EWMAC " + ((signal == 1) ? "BUY" : "SELL") + " | " + _Symbol + " | Lots " + DoubleToString(lots, 4) +
                   " | " + TFName(EntryTimeframe);
      Print(msg);
      if(SendPopup) Alert(msg);
      if(SendPush) SendNotification(msg);

      for(int i = PositionsTotal() - 1; i >= 0; i--)
      {
         ulong tk = PositionGetTicket(i);
         if(tk > 0 && PositionSelectByTicket(tk))
         {
            if(PositionGetString(POSITION_SYMBOL) == _Symbol && (ulong)PositionGetInteger(POSITION_MAGIC) == MagicNumber)
            {
               if(g_currentTrailTicket != tk) {
                   g_currentTrailTicket = tk;
                   g_trailCount = 0;
                   ObjectsDeleteAll(0, TrailHistPrefix);
                   double sl = PositionGetDouble(POSITION_SL);
                   if(sl > 0) AddTrailHistoryPoint(TimeCurrent(), sl);
               }
               break;
            }
         }
      }
      return true;
   }

   ThrottledPrint("ORDER FAILED retcode=" + IntegerToString(ret) + " " + trade.ResultRetcodeDescription());
   return false;
}

//+------------------------------------------------------------------+
void ManageATRTrail()
{
   if(!UseATRTrail) return;
   if(g_atr_handle == INVALID_HANDLE) return;

   double atrBuf[];
   if(CopyBuffer(g_atr_handle, 0, 0, 1, atrBuf) < 1 || atrBuf[0] <= 0.0)
      return;
   double atr = atrBuf[0];

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0 || !PositionSelectByTicket(ticket)) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      if((ulong)PositionGetInteger(POSITION_MAGIC) != MagicNumber) continue;

      ENUM_POSITION_TYPE ptype = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);
      double openPrice = PositionGetDouble(POSITION_PRICE_OPEN);
      double currentSL = PositionGetDouble(POSITION_SL);
      double currentTP = PositionGetDouble(POSITION_TP);

      double minStopDist = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL) * _Point;
      double point       = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
      if(minStopDist <= 0) minStopDist = point * 2;

      double trailDist = atr * ATR_Multiplier;
      double newSL     = 0.0;

      if(ptype == POSITION_TYPE_BUY)
      {
         newSL = SymbolInfoDouble(_Symbol, SYMBOL_BID) - trailDist;
         if(currentSL > 0.0 && newSL <= currentSL) continue;
         double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
         if(newSL > bid - minStopDist) newSL = bid - minStopDist;
         if(newSL <= openPrice) continue;
      }
      else
      {
         newSL = SymbolInfoDouble(_Symbol, SYMBOL_ASK) + trailDist;
         if(currentSL > 0.0 && newSL >= currentSL) continue;
         double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
         if(newSL < ask + minStopDist) newSL = ask + minStopDist;
         if(newSL >= openPrice) continue;
      }

      newSL = NormalizeDouble(newSL, (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS));
      if(trade.PositionModify(ticket, newSL, currentTP))
      {
          if(g_currentTrailTicket != ticket) {
              g_currentTrailTicket = ticket;
              g_trailCount = 0;
              ObjectsDeleteAll(0, TrailHistPrefix);
          }
          AddTrailHistoryPoint(TimeCurrent(), newSL);
      }
      else
         ThrottledPrint("ATR Trail modify failed: " + trade.ResultRetcodeDescription());
   }
}

//+------------------------------------------------------------------+
void UpdateTrailPlot()
{
   if(!UseATRTrail || !PlotTrailOnChart)
   {
      ObjectDelete(0, TrailObjName);
      ObjectsDeleteAll(0, TrailHistPrefix);
      g_currentTrailTicket = 0;
      g_trailCount = 0;
      return;
   }

   double trailPrice = 0.0;
   bool found = false;
   ulong currentTicket = 0;

   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0 || !PositionSelectByTicket(ticket)) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;
      if((ulong)PositionGetInteger(POSITION_MAGIC) != MagicNumber) continue;

      double sl = PositionGetDouble(POSITION_SL);
      if(sl > 0.0)
      {
         trailPrice = sl;
         found = true;
         currentTicket = ticket;
         break;
      }
   }

   if(!found)
   {
      ObjectDelete(0, TrailObjName);
      ObjectsDeleteAll(0, TrailHistPrefix);
      g_currentTrailTicket = 0;
      g_trailCount = 0;
      return;
   }

   if(g_currentTrailTicket != currentTicket) {
       g_currentTrailTicket = currentTicket;
       g_trailCount = 0;
       ObjectsDeleteAll(0, TrailHistPrefix);
       AddTrailHistoryPoint(TimeCurrent(), trailPrice);
   }

   if(ObjectFind(0, TrailObjName) < 0)
   {
      ObjectCreate(0, TrailObjName, OBJ_HLINE, 0, 0, trailPrice);
      ObjectSetInteger(0, TrailObjName, OBJPROP_SELECTABLE, false);
      ObjectSetInteger(0, TrailObjName, OBJPROP_BACK, true);
      ObjectSetInteger(0, TrailObjName, OBJPROP_HIDDEN, true);
   }
   ObjectSetDouble(0, TrailObjName, OBJPROP_PRICE, trailPrice);
   ObjectSetInteger(0, TrailObjName, OBJPROP_COLOR, TrailColor);
   ObjectSetInteger(0, TrailObjName, OBJPROP_WIDTH, TrailWidth);
   ObjectSetInteger(0, TrailObjName, OBJPROP_STYLE, TrailStyle);
   ObjectSetString(0, TrailObjName, OBJPROP_TEXT, " ");

   for(int i = 0; i < g_trailCount - 1; i++)
   {
       string name = TrailHistPrefix + IntegerToString(i);
       if(ObjectFind(0, name) < 0)
       {
           ObjectCreate(0, name, OBJ_TREND, 0, g_trailTimes[i], g_trailPrices[i], g_trailTimes[i+1], g_trailPrices[i+1]);
           ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
           ObjectSetInteger(0, name, OBJPROP_BACK, true);
           ObjectSetInteger(0, name, OBJPROP_RAY_RIGHT, false);
           ObjectSetInteger(0, name, OBJPROP_COLOR, TrailHistoryColor);
           ObjectSetInteger(0, name, OBJPROP_WIDTH, TrailHistoryWidth);
           ObjectSetInteger(0, name, OBJPROP_STYLE, TrailHistoryStyle);
           ObjectSetInteger(0, name, OBJPROP_HIDDEN, true);
       }
       else
       {
           ObjectMove(0, name, 0, g_trailTimes[i], g_trailPrices[i]);
           ObjectMove(0, name, 1, g_trailTimes[i+1], g_trailPrices[i+1]);
       }
       ObjectSetString(0, name, OBJPROP_TEXT, " ");
   }

   if(g_trailCount > 0)
   {
       string name = TrailHistPrefix + "CURRENT";
       if(ObjectFind(0, name) < 0)
       {
           ObjectCreate(0, name, OBJ_TREND, 0, g_trailTimes[g_trailCount-1], g_trailPrices[g_trailCount-1], TimeCurrent(), trailPrice);
           ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
           ObjectSetInteger(0, name, OBJPROP_BACK, true);
           ObjectSetInteger(0, name, OBJPROP_RAY_RIGHT, false);
           ObjectSetInteger(0, name, OBJPROP_COLOR, TrailHistoryColor);
           ObjectSetInteger(0, name, OBJPROP_WIDTH, TrailHistoryWidth);
           ObjectSetInteger(0, name, OBJPROP_STYLE, TrailHistoryStyle);
           ObjectSetInteger(0, name, OBJPROP_HIDDEN, true);
       }
       else
       {
           ObjectMove(0, name, 0, g_trailTimes[g_trailCount-1], g_trailPrices[g_trailCount-1]);
           ObjectMove(0, name, 1, TimeCurrent(), trailPrice);
       }
       ObjectSetString(0, name, OBJPROP_TEXT, " ");
   }
}

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
bool CloseAllPositions()
{
   bool allClosed = true;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0 || !PositionSelectByTicket(ticket)) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol || (ulong)PositionGetInteger(POSITION_MAGIC) != MagicNumber) continue;
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
string SideText(int side)
{
   return (side == 1) ? "BUY" : ((side == -1) ? "SELL" : "NONE");
}

//+------------------------------------------------------------------+
string TFLine(const string label, const TFState &st)
{
   string fc  = st.ready ? StringFormat("%+.2f", st.now) : "--";
   string dir = !st.ready ? "CALC" : (st.now > 0.0 ? "BULL" : (st.now < 0.0 ? "BEAR" : "NEUT"));
   return label + " " + TFName(st.tf) + ": " + fc + " " + dir;
}

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

   string positionText = "FLAT";
   bool hasBuy = HasPositionType(POSITION_TYPE_BUY), hasSell = HasPositionType(POSITION_TYPE_SELL);
   if(hasBuy && hasSell) positionText = "BUY + SELL";
   else if(hasBuy)       positionText = "BUY";
   else if(hasSell)      positionText = "SELL";

   string statusText;
   int sig = g_entry.ready ? g_entry.side : 0;
   if(hasBuy || hasSell)                 statusText = "IN TRADE";
   else if(sig == 0)                     statusText = "WAIT SIGNAL";
   else if(ArmedSide != sig)             statusText = "WAIT " + TFName(EntryTimeframe) + " CROSS";
   else                                  statusText = "READY";

   string trailText = UseATRTrail ? "ON (" + IntegerToString(ATR_Period) + "x" + DoubleToString(ATR_Multiplier,1) + ")" : "OFF";

   string lines[13];
   lines[0]  = "AMARE CAPITAL MANAGEMENT";
   lines[1]  = "EWMAC v5.00";
   lines[2]  = "----------------------------------";
   lines[3]  = "Symbol:   " + _Symbol;
   lines[4]  = "EWMAC:    " + IntegerToString(FastPeriod) + "/" + IntegerToString(SlowPeriod) + " Scalar " + DoubleToString(ForecastScalar, 2);
   lines[5]  = TFLine("Entry", g_entry);
   lines[6]  = "Signal:   " + SideText(sig);
   lines[7]  = "Armed:    " + SideText(ArmedSide);
   lines[8]  = "Position: " + positionText;
   lines[9]  = "Status:   " + statusText;
   lines[10] = "Lots:     " + DoubleToString(FixedLots, 4);
   lines[11] = "ATR Trail: " + trailText;
   lines[12] = " ";

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
   ObjectSetInteger(0, bgName, OBJPROP_XSIZE, 230);
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
         ObjectSetInteger(0, name, OBJPROP_XDISTANCE, 230);
         ObjectSetString(0, name, OBJPROP_FONT, "Consolas");
         ObjectSetInteger(0, name, OBJPROP_FONTSIZE, 9);
         ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
         ObjectSetInteger(0, name, OBJPROP_BACK, false);
      }
      ObjectSetInteger(0, name, OBJPROP_YDISTANCE, 30 + (i * 15));
      ObjectSetString(0, name, OBJPROP_TEXT, lines[i]);

      color c = textClr;
      if(i == 0 || i == 1) c = headerClr;
      else if(i == 5)
         c = !g_entry.ready ? textClr : (g_entry.side == 1 ? bullClr : (g_entry.side == -1 ? bearClr : neutralClr));
      else if(i == 6) c = (sig == 1) ? bullClr : ((sig == -1) ? bearClr : neutralClr);
      else if(i == 7) c = (ArmedSide == 1) ? bullClr : ((ArmedSide == -1) ? bearClr : textClr);
      else if(i == 8) c = (positionText == "FLAT") ? textClr : posClr;
      ObjectSetInteger(0, name, OBJPROP_COLOR, c);
   }
}

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   if(g_atr_handle != INVALID_HANDLE)
   {
      IndicatorRelease(g_atr_handle);
      g_atr_handle = INVALID_HANDLE;
   }

   ObjectsDeleteAll(0, DashPrefix);
   ObjectsDeleteAll(0, TrailHistPrefix);
   ObjectDelete(0, TrailObjName);
   Comment("");
   Print("EWMAC EA stopped. Reason: ", reason);
}
//+------------------------------------------------------------------+
