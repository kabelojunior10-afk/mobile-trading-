//+------------------------------------------------------------------+
//|                                                EWMAC_BOT_DAY.mq5|
//|                 AMARE CAPITAL MANAGEMENT                         |
//|        EWMAC Day Trader - Shannon multi-timeframe alignment      |
//|        Version 5.00  (30M bias / 5M structure / 1M trigger)      |
//+------------------------------------------------------------------+
#property strict
#property version   "5.00"
#property description "EWMAC day trader: primary-trend bias, structure stops, R:R filter, scale-out, session flat."

#include <Trade/Trade.mqh>
CTrade trade;

enum ENUM_EWMAC_PAIR
{
   EWMAC_2_8 = 0,
   EWMAC_4_16,
   EWMAC_8_32,
   EWMAC_16_64,
   EWMAC_32_128,
   EWMAC_64_256
};

input group "EWMAC Strategy"
input ENUM_EWMAC_PAIR EWMACPair         = EWMAC_8_32;
input int    StdevWindow                = 50;
input double ForecastCapMin             = -20.0;
input double ForecastCapMax             =  20.0;
input int    WarmupBars                 = 1000;
input bool   UseCarverScalar            = true;

input group "Timeframes (4-6 rule)"
input ENUM_TIMEFRAMES PrimaryTF         = PERIOD_M30; // trend bias (Stage 2 / Stage 4)
input ENUM_TIMEFRAMES SecondaryTF       = PERIOD_M5;  // alignment, stop + target levels
input ENUM_TIMEFRAMES MinorTF           = PERIOD_M1;  // entry trigger, trail, exits
input double BiasMinForecast            = 2.0;        // |primary forecast| needed to allow trades
input bool   RequireMinorAlign          = true;       // minor forecast must agree at trigger
input bool   ExitOnBiasFlip             = true;       // exit if primary forecast flips against trade
input bool   ExitOnMinorCross           = true;       // exit if minor fast/slow crosses against (time correction)

input group "Structure and Risk/Reward"
input int    SwingK                     = 2;          // secondary fractal bars each side
input int    MinorSwingK                = 2;          // minor fractal bars each side
input int    SwingLookback              = 120;        // secondary bars scanned for stop/target
input double StopBufferATR              = 0.10;       // buffer beyond swing level (x ATR) + spread
input double MaxRiskATR                 = 3.0;        // skip if stop distance > this x ATR
input double MinRR                      = 1.5;        // minimum reward:risk to nearest resistance/support
input int    TriggerBufferPts           = 0;          // points beyond swing level to trigger

input group "Trade Management"
input bool   UseStructureTrail          = true;       // trail to minor higher lows / lower highs
input double PartialFraction            = 0.33;       // fraction of entry volume closed at +PartialR (0 = off)
input double PartialR                   = 1.0;
input double Partial2Fraction           = 0.33;       // fraction closed at target level (0 = off)

input group "Day Session (server time)"
input bool   UseSession                 = true;
input int    SessionStartHour           = 8;
input int    LastEntryHour              = 20;         // no new entries from this hour
input int    FlatHour                   = 21;         // close everything from this hour
input int    MaxTradesPerDay            = 6;          // 0 = unlimited
input double DailyLossPct               = 2.0;        // halt + flatten at this equity drawdown (0 = off)
input int    MaxSpreadPts               = 0;          // 0 = off

input group "Position Sizing"
input double FixedLots                  = 0.03;       // must be splittable for scale-outs

input group "ATR Trailing Stop"
input bool   UseATRTrail                = false;
input int    ATR_Period                 = 14;
input double ATR_Multiplier             = 2.0;
input bool   PlotTrailOnChart           = true;
input color  TrailColor                 = clrOrange;
input int    TrailWidth                 = 1;
input ENUM_LINE_STYLE TrailStyle        = STYLE_SOLID;

input group "ATR Trail History"
input color  TrailHistoryColor          = clrOrange;
input int    TrailHistoryWidth          = 1;
input ENUM_LINE_STYLE TrailHistoryStyle = STYLE_DOT;
input int    TrailHistoryMaxPoints      = 100;

input group "Execution"
input ulong  MagicNumber                = 20260102;
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
int      g_atr_handle      = INVALID_HANDLE;

datetime g_lastPrimaryBar   = 0;
datetime g_lastSecondaryBar = 0;
datetime g_lastMinorBar     = 0;
double   g_fPrimary   = 0.0;
double   g_fSecondary = 0.0;
double   g_fMinor     = 0.0;
int      g_biasSide   = 0;

string   g_setupState   = "INIT";
bool     g_armed        = false;
int      g_setupDir     = 0;
double   g_trigLevel    = 0.0;
double   g_stopLevel    = 0.0;
double   g_targetLevel  = 0.0;
double   g_rr           = 0.0;
datetime g_trigTime     = 0;
datetime g_lastUsedTrig = 0;
datetime LastAttempt    = 0;

ulong    g_mgmtTicket   = 0;
double   g_riskDist     = 0.0;
double   g_origVol      = 0.0;
double   g_posTarget    = 0.0;
bool     g_partial1Done = false;
bool     g_partial2Done = false;

int      g_dayKey         = 0;
double   g_dayStartEquity = 0.0;
int      g_tradesToday    = 0;
bool     g_dayHalted      = false;

string DashPrefix = "EWMAC_DASH_";
const int DASH_LINES = 17;

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
int OnInit()
{
   if(StdevWindow < 2) return INIT_PARAMETERS_INCORRECT;
   if(WarmupBars < 100) return INIT_PARAMETERS_INCORRECT;
   if(ForecastCapMin >= ForecastCapMax) return INIT_PARAMETERS_INCORRECT;
   if(FixedLots <= 0.0) return INIT_PARAMETERS_INCORRECT;
   if(UseATRTrail && (ATR_Period < 1 || ATR_Multiplier <= 0.0)) return INIT_PARAMETERS_INCORRECT;
   if(SwingK < 1 || MinorSwingK < 1 || SwingLookback < 20) return INIT_PARAMETERS_INCORRECT;
   if(MinRR <= 0.0 || MaxRiskATR <= 0.0 || ATR_Period < 1) return INIT_PARAMETERS_INCORRECT;
   if(PartialFraction < 0.0 || Partial2Fraction < 0.0 || PartialFraction + Partial2Fraction >= 1.0) return INIT_PARAMETERS_INCORRECT;
   if(PeriodSeconds(PrimaryTF) <= PeriodSeconds(SecondaryTF) || PeriodSeconds(SecondaryTF) <= PeriodSeconds(MinorTF))
   {
      Print("Timeframes must satisfy Primary > Secondary > Minor");
      return INIT_PARAMETERS_INCORRECT;
   }
   if(UseSession && !(SessionStartHour < LastEntryHour && LastEntryHour <= FlatHour && FlatHour <= 23))
   {
      Print("Session hours must satisfy Start < LastEntry <= Flat <= 23");
      return INIT_PARAMETERS_INCORRECT;
   }

   SetEWMACPeriods();
   SetForecastScalar();

   trade.SetExpertMagicNumber(MagicNumber);
   trade.SetDeviationInPoints(SlippagePts);
   trade.SetTypeFillingBySymbol(_Symbol);
   trade.SetAsyncMode(false);

   g_atr_handle = iATR(_Symbol, SecondaryTF, ATR_Period);
   if(g_atr_handle == INVALID_HANDLE)
   {
      Print("Failed to create ATR handle. Error: ", GetLastError());
      return INIT_FAILED;
   }

   Print("==================================================");
   Print("AMARE CAPITAL MANAGEMENT - EWMAC DAY EA v5.00");
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
bool CalcForecast(ENUM_TIMEFRAMES tf, double &forecastNow, double &forecastPrevious)
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
double GetATR()
{
   if(g_atr_handle == INVALID_HANDLE) return 0.0;
   double b[];
   if(CopyBuffer(g_atr_handle, 0, 1, 1, b) < 1) return 0.0;
   return b[0];
}

//+------------------------------------------------------------------+
int GetRates(ENUM_TIMEFRAMES tf, int count, MqlRates &r[])
{
   ArraySetAsSeries(r, false);
   int c = CopyRates(_Symbol, tf, 0, count, r);
   return (c > 0) ? c : 0;
}

//+------------------------------------------------------------------+
bool IsSwing(const MqlRates &r[], int i, int k, bool isHigh)
{
   for(int j = 1; j <= k; j++)
   {
      if(isHigh) { if(r[i].high <= r[i-j].high || r[i].high <= r[i+j].high) return false; }
      else       { if(r[i].low  >= r[i-j].low  || r[i].low  >= r[i+j].low)  return false; }
   }
   return true;
}

// mode 0: newest swing | 1: newest swing beyond ref (high>ref / low<ref) | 2: nearest such swing to ref
bool FindSwing(const MqlRates &r[], int n, int k, int maxBack, bool isHigh, int mode, double ref, double &level, datetime &t)
{
   level = 0.0; t = 0;
   bool found = false;
   int newest = n - 2 - k;
   int oldest = MathMax(k, newest - maxBack);
   for(int i = newest; i >= oldest; i--)
   {
      if(!IsSwing(r, i, k, isHigh)) continue;
      double v = isHigh ? r[i].high : r[i].low;
      if(mode == 0) { level = v; t = r[i].time; return true; }
      bool side = isHigh ? (v > ref) : (v < ref);
      if(!side) continue;
      if(mode == 1) { level = v; t = r[i].time; return true; }
      if(!found || (isHigh ? v < level : v > level)) { level = v; t = r[i].time; found = true; }
   }
   return found;
}

//+------------------------------------------------------------------+
bool GetOurPosition(ulong &ticket, int &dir, double &open, double &sl, double &vol, datetime &ptime)
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong tk = PositionGetTicket(i);
      if(tk == 0 || !PositionSelectByTicket(tk)) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol || (ulong)PositionGetInteger(POSITION_MAGIC) != MagicNumber) continue;
      ticket = tk;
      dir    = ((ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY) ? 1 : -1;
      open   = PositionGetDouble(POSITION_PRICE_OPEN);
      sl     = PositionGetDouble(POSITION_SL);
      vol    = PositionGetDouble(POSITION_VOLUME);
      ptime  = (datetime)PositionGetInteger(POSITION_TIME);
      return true;
   }
   return false;
}

//+------------------------------------------------------------------+
void CloseAllOurs(const string why)
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong tk = PositionGetTicket(i);
      if(tk == 0 || !PositionSelectByTicket(tk)) continue;
      if(PositionGetString(POSITION_SYMBOL) != _Symbol || (ulong)PositionGetInteger(POSITION_MAGIC) != MagicNumber) continue;
      if(trade.PositionClose(tk)) Print("Closed (", why, ") ticket ", tk);
      else ThrottledPrint("Close failed (" + why + "): " + trade.ResultRetcodeDescription());
   }
}

//+------------------------------------------------------------------+
void DayCheck()
{
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   int key = dt.year * 1000 + dt.day_of_year;
   double eq = AccountInfoDouble(ACCOUNT_EQUITY);
   if(key != g_dayKey)
   {
      g_dayKey = key;
      g_dayStartEquity = eq;
      g_tradesToday = 0;
      g_dayHalted = false;
   }
   if(DailyLossPct > 0.0 && !g_dayHalted && g_dayStartEquity > 0.0 && eq <= g_dayStartEquity * (1.0 - DailyLossPct / 100.0))
   {
      g_dayHalted = true;
      g_armed = false;
      Print("Daily loss limit hit. Flattening and halting until next day.");
      CloseAllOurs("daily loss limit");
   }
}

//+------------------------------------------------------------------+
void SessionFlat()
{
   if(!UseSession) return;
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   if(dt.hour < FlatHour) return;
   ulong tk; int dir; double o, s, v; datetime pt;
   if(GetOurPosition(tk, dir, o, s, v, pt)) CloseAllOurs("session end");
}

//+------------------------------------------------------------------+
bool EntryAllowed()
{
   if(g_dayHalted) return false;
   if(MaxTradesPerDay > 0 && g_tradesToday >= MaxTradesPerDay) return false;
   if(UseSession)
   {
      MqlDateTime dt;
      TimeToStruct(TimeCurrent(), dt);
      if(dt.hour < SessionStartHour || dt.hour >= LastEntryHour) return false;
   }
   if(MaxSpreadPts > 0 && SymbolInfoInteger(_Symbol, SYMBOL_SPREAD) > MaxSpreadPts) return false;
   return true;
}

//+------------------------------------------------------------------+
void OnTick()
{
   DayCheck();
   UpdateForecasts();
   SessionFlat();
   ManagePosition();
   CheckEntry();
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
void UpdateForecasts()
{
   double now = 0.0, prev = 0.0;

   datetime t = iTime(_Symbol, PrimaryTF, 0);
   if(t != 0 && t != g_lastPrimaryBar && CalcForecast(PrimaryTF, now, prev))
   {
      g_lastPrimaryBar = t;
      g_fPrimary = now;
      g_biasSide = (MathAbs(now) >= BiasMinForecast) ? (now > 0.0 ? 1 : -1) : 0;
   }

   t = iTime(_Symbol, SecondaryTF, 0);
   if(t != 0 && t != g_lastSecondaryBar && CalcForecast(SecondaryTF, now, prev))
   {
      g_lastSecondaryBar = t;
      g_fSecondary = now;
   }

   t = iTime(_Symbol, MinorTF, 0);
   if(t != 0 && t != g_lastMinorBar && CalcForecast(MinorTF, now, prev))
   {
      g_lastMinorBar = t;
      g_fMinor = now;
      ManageExitsOnBar();
      BuildSetup();
   }
}

//+------------------------------------------------------------------+
// Evaluated once per closed minor bar: alignment -> trigger level -> stop -> R:R
void BuildSetup()
{
   g_armed = false; g_setupDir = 0;
   g_trigLevel = 0.0; g_stopLevel = 0.0; g_targetLevel = 0.0; g_rr = 0.0;

   ulong tk; int pd; double po, ps, pv; datetime pt;
   if(GetOurPosition(tk, pd, po, ps, pv, pt)) { g_setupState = "IN TRADE"; return; }

   int dir = g_biasSide;
   if(dir == 0)                  { g_setupState = "NO BIAS (STAND ASIDE)"; return; }
   if(g_fSecondary * dir <= 0.0) { g_setupState = "WAIT SECONDARY ALIGN"; return; }
   if(RequireMinorAlign && g_fMinor * dir <= 0.0) { g_setupState = "STALK (MINOR AGAINST)"; return; }

   MqlRates m1[], m5[];
   int n1 = GetRates(MinorTF, 150, m1);
   int n5 = GetRates(SecondaryTF, SwingLookback + 2 * SwingK + 20, m5);
   if(n1 < 40 || n5 < 40) { g_setupState = "NO DATA"; return; }

   bool   isHigh = (dir == 1);
   double lvl, stopLvl, tgt;
   datetime lt, st, tt;

   if(!FindSwing(m1, n1, MinorSwingK, 100, isHigh, 0, 0.0, lvl, lt)) { g_setupState = "NO TRIGGER LEVEL"; return; }
   double lastClose = m1[n1-2].close;
   if((dir == 1 && lastClose > lvl) || (dir == -1 && lastClose < lvl)) { g_setupState = "LEVEL ALREADY BROKEN"; return; }
   if(lt <= g_lastUsedTrig) { g_setupState = "LEVEL USED"; return; }

   if(!FindSwing(m5, n5, SwingK, SwingLookback, !isHigh, 1, lvl, stopLvl, st)) { g_setupState = "NO STRUCTURE STOP"; return; }

   double atr      = GetATR();
   double spreadPx = (double)SymbolInfoInteger(_Symbol, SYMBOL_SPREAD) * _Point;
   stopLvl -= dir * (StopBufferATR * atr + spreadPx);

   double risk = (lvl - stopLvl) * dir;
   if(risk <= 0.0) { g_setupState = "BAD STOP"; return; }
   if(atr > 0.0 && risk > MaxRiskATR * atr) { g_setupState = "STOP TOO WIDE"; return; }

   double rr;
   if(FindSwing(m5, n5, SwingK, SwingLookback, isHigh, 2, lvl, tgt, tt))
      rr = ((tgt - lvl) * dir) / risk;
   else
   {
      tgt = lvl + dir * MinRR * risk;   // open air: minimum target beyond prior extreme
      rr  = MinRR;
   }

   g_trigLevel = lvl; g_stopLevel = stopLvl; g_targetLevel = tgt; g_rr = rr; g_trigTime = lt;
   if(rr < MinRR) { g_setupState = "RR TOO LOW"; return; }

   g_setupDir = dir;
   g_armed = true;
   g_setupState = "ARMED";
}

//+------------------------------------------------------------------+
void CheckEntry()
{
   if(!g_armed || g_setupDir == 0) return;
   if(!EntryAllowed()) return;

   MqlTick tick;
   if(!SymbolInfoTick(_Symbol, tick)) return;

   int dir = g_setupDir;
   double buf = TriggerBufferPts * _Point;
   double px  = (dir == 1) ? tick.ask : tick.bid;
   bool broke = (dir == 1) ? (px > g_trigLevel + buf) : (px < g_trigLevel - buf);
   if(!broke) return;

   double risk = (px - g_stopLevel) * dir;
   if(risk <= 0.0) return;
   double atr = GetATR();
   if(atr > 0.0 && risk > MaxRiskATR * atr) { g_armed = false; g_setupState = "STOP TOO WIDE"; return; }
   if(((g_targetLevel - px) * dir) / risk < MinRR) { g_armed = false; g_setupState = "RR LOST"; return; }

   if(TimeCurrent() == LastAttempt) return;
   LastAttempt = TimeCurrent();

   if(ExecuteSignal(dir, g_stopLevel, g_targetLevel, risk))
   {
      g_lastUsedTrig = g_trigTime;
      g_armed = false;
      g_setupState = "IN TRADE";
   }
}

//+------------------------------------------------------------------+
void ManageExitsOnBar()
{
   ulong tk; int dir; double open, sl, vol; datetime pt;
   if(!GetOurPosition(tk, dir, open, sl, vol, pt)) return;

   if(ExitOnBiasFlip && g_fPrimary * dir < 0.0)  { CloseAllOurs("primary bias flip"); return; }
   if(ExitOnMinorCross && g_fMinor * dir <= 0.0) { CloseAllOurs("minor MA cross"); return; }
   if(!UseStructureTrail) return;

   MqlRates m1[];
   int n = GetRates(MinorTF, 150, m1);
   if(n < 20) return;

   double lvl; datetime lt;
   if(!FindSwing(m1, n, MinorSwingK, 100, (dir == -1), 0, 0.0, lvl, lt)) return;
   if(lt < pt) return;   // only swings formed after entry

   double spreadPx = (double)SymbolInfoInteger(_Symbol, SYMBOL_SPREAD) * _Point;
   double newSL = lvl - dir * (StopBufferATR * GetATR() + spreadPx);
   if(sl > 0.0 && (newSL - sl) * dir <= 0.0) return;

   double px   = (dir == 1) ? SymbolInfoDouble(_Symbol, SYMBOL_BID) : SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double minD = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL) * _Point;
   if((px - newSL) * dir < minD) return;

   newSL = NormalizeDouble(newSL, (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS));
   if(!PositionSelectByTicket(tk)) return;
   if(!trade.PositionModify(tk, newSL, PositionGetDouble(POSITION_TP)))
      ThrottledPrint("Structure trail modify failed: " + trade.ResultRetcodeDescription());
}

//+------------------------------------------------------------------+
bool ClosePortion(ulong tk, double frac)
{
   if(!PositionSelectByTicket(tk)) return false;
   double vol  = PositionGetDouble(POSITION_VOLUME);
   double step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   double minL = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   if(step <= 0.0) return false;
   double cv = NormalizeDouble(MathFloor((g_origVol * frac + 1e-12) / step) * step, 8);
   if(cv < minL || vol - cv < minL) return false;   // too small to split: skip
   return trade.PositionClosePartial(tk, cv);
}

//+------------------------------------------------------------------+
void MoveToBreakeven(ulong tk, int dir, double open)
{
   if(!PositionSelectByTicket(tk)) return;
   double sl = PositionGetDouble(POSITION_SL), tp = PositionGetDouble(POSITION_TP);
   double be = open + dir * (double)SymbolInfoInteger(_Symbol, SYMBOL_SPREAD) * _Point;
   if(sl > 0.0 && (be - sl) * dir <= 0.0) return;
   double px   = (dir == 1) ? SymbolInfoDouble(_Symbol, SYMBOL_BID) : SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double minD = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL) * _Point;
   if((px - be) * dir < minD) return;
   be = NormalizeDouble(be, (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS));
   trade.PositionModify(tk, be, tp);
}

//+------------------------------------------------------------------+
void ManagePosition()
{
   ulong tk; int dir; double open, sl, vol; datetime pt;
   if(!GetOurPosition(tk, dir, open, sl, vol, pt)) { g_mgmtTicket = 0; return; }

   if(tk != g_mgmtTicket)   // position not opened by this session of the EA (e.g. restart): infer state
   {
      g_mgmtTicket   = tk;
      g_origVol      = vol;
      g_riskDist     = (sl > 0.0) ? MathAbs(open - sl) : 0.0;
      g_posTarget    = 0.0;
      g_partial1Done = (sl > 0.0 && (sl - open) * dir >= 0.0);
      g_partial2Done = true;
   }

   double px = (dir == 1) ? SymbolInfoDouble(_Symbol, SYMBOL_BID) : SymbolInfoDouble(_Symbol, SYMBOL_ASK);

   if(PartialFraction > 0.0 && !g_partial1Done && g_riskDist > 0.0 && (px - open) * dir >= PartialR * g_riskDist)
   {
      g_partial1Done = true;
      ClosePortion(tk, PartialFraction);
      MoveToBreakeven(tk, dir, open);
   }

   if(Partial2Fraction > 0.0 && !g_partial2Done && g_posTarget > 0.0 && (px - g_posTarget) * dir >= 0.0)
   {
      g_partial2Done = true;
      ClosePortion(tk, Partial2Fraction);
   }
}

//+------------------------------------------------------------------+
bool ExecuteSignal(int signal, double slPrice, double tgtPrice, double riskDist)
{
   if(signal != 1 && signal != -1) return false;

   ENUM_POSITION_TYPE targetType = (signal == 1) ? POSITION_TYPE_BUY  : POSITION_TYPE_SELL;
   ENUM_POSITION_TYPE oppType    = (signal == 1) ? POSITION_TYPE_SELL : POSITION_TYPE_BUY;

   if(HasPositionType(targetType) && !HasPositionType(oppType)) return true;

   if(!TerminalInfoInteger(TERMINAL_TRADE_ALLOWED) || !MQLInfoInteger(MQL_TRADE_ALLOWED) || !AccountInfoInteger(ACCOUNT_TRADE_ALLOWED))
   {
      ThrottledPrint("BLOCKED: trading not allowed");
      return false;
   }

   if(!SymbolSelect(_Symbol, true)) { ThrottledPrint("BLOCKED: SymbolSelect failed"); return false; }

   MqlTick tick;
   if(!SymbolInfoTick(_Symbol, tick)) { ThrottledPrint("BLOCKED: no tick"); return false; }

   if(!CloseOppositePositions(targetType))
   {
      ThrottledPrint("BLOCKED: failed to close opposite position");
      return false;
   }

   if(HasPositionType(targetType)) return true;

   double lots = NormalizeLots(FixedLots);
   if(lots <= 0.0)
   {
      ThrottledPrint("BLOCKED: invalid lot size after normalization");
      return false;
   }

   double price = (signal == 1) ? tick.ask : tick.bid;
   ENUM_ORDER_TYPE orderType = (signal == 1) ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;

   double minStopDist = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL) * _Point;
   if((price - slPrice) * signal < minStopDist) { ThrottledPrint("BLOCKED: stop inside broker stop level"); return false; }

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

   slPrice = NormalizeDouble(slPrice, (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS));

   bool ok = (signal == 1)
             ? trade.Buy(lots, _Symbol, 0.0, slPrice, 0.0, "EWMAC DAY BUY")
             : trade.Sell(lots, _Symbol, 0.0, slPrice, 0.0, "EWMAC DAY SELL");

   uint ret = trade.ResultRetcode();

   if(ok && (ret == TRADE_RETCODE_DONE || ret == TRADE_RETCODE_DONE_PARTIAL || ret == TRADE_RETCODE_PLACED))
   {
      string msg = "EWMAC DAY " + ((signal == 1) ? "BUY" : "SELL") + " | " + _Symbol + " | Lots " + DoubleToString(lots, 4) +
                   " | SL " + DoubleToString(slPrice, _Digits) + " | RR " + DoubleToString(g_rr, 2);
      Print(msg);
      if(SendPopup) Alert(msg);
      if(SendPush) SendNotification(msg);

      g_tradesToday++;

      ulong tk; int d; double o, s, v; datetime pt;
      if(GetOurPosition(tk, d, o, s, v, pt))
      {
         g_mgmtTicket   = tk;
         g_origVol      = v;
         g_riskDist     = MathAbs(o - slPrice);
         g_posTarget    = tgtPrice;
         g_partial1Done = false;
         g_partial2Done = false;

         if(g_currentTrailTicket != tk)
         {
            g_currentTrailTicket = tk;
            g_trailCount = 0;
            ObjectsDeleteAll(0, TrailHistPrefix);
            if(s > 0) AddTrailHistoryPoint(TimeCurrent(), s);
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

   string direction = "NEUTRAL";
   if(g_biasSide == 1)       direction = "BULLISH";
   else if(g_biasSide == -1) direction = "BEARISH";

   string positionText = "FLAT";
   bool hasBuy = HasPositionType(POSITION_TYPE_BUY), hasSell = HasPositionType(POSITION_TYPE_SELL);
   if(hasBuy && hasSell) positionText = "BUY + SELL";
   else if(hasBuy)       positionText = "BUY";
   else if(hasSell)      positionText = "SELL";

   string setupText = g_setupState;
   if(g_armed && !EntryAllowed()) setupText += " (BLOCKED)";

   string tfs = StringSubstr(EnumToString(PrimaryTF), 7) + "/" + StringSubstr(EnumToString(SecondaryTF), 7) + "/" + StringSubstr(EnumToString(MinorTF), 7);

   string lines[17];
   lines[0]  = "AMARE CAPITAL MANAGEMENT";
   lines[1]  = "EWMAC DAY v5.00";
   lines[2]  = "----------------------------------";
   lines[3]  = "Symbol:   " + _Symbol;
   lines[4]  = "TFs:      " + tfs;
   lines[5]  = "EWMAC:    " + IntegerToString(FastPeriod) + "/" + IntegerToString(SlowPeriod);
   lines[6]  = "Bias:     " + direction + " " + DoubleToString(g_fPrimary, 1);
   lines[7]  = "Fcst Sec: " + DoubleToString(g_fSecondary, 2);
   lines[8]  = "Fcst Min: " + DoubleToString(g_fMinor, 2);
   lines[9]  = "Setup:    " + setupText;
   lines[10] = "Trigger:  " + (g_trigLevel > 0.0 ? DoubleToString(g_trigLevel, _Digits) : "-");
   lines[11] = "Stop:     " + (g_stopLevel > 0.0 ? DoubleToString(g_stopLevel, _Digits) : "-");
   lines[12] = "Target:   " + (g_targetLevel > 0.0 ? DoubleToString(g_targetLevel, _Digits) + "  RR " + DoubleToString(g_rr, 2) : "-");
   lines[13] = "Position: " + positionText;
   lines[14] = "Trades:   " + IntegerToString(g_tradesToday) + (MaxTradesPerDay > 0 ? "/" + IntegerToString(MaxTradesPerDay) : "") + (g_dayHalted ? "  HALTED" : "");
   lines[15] = "Lots:     " + DoubleToString(FixedLots, 4);
   lines[16] = " ";

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

      if(i == 6)
      {
         color trendClr = neutralClr;
         if(direction == "BULLISH") trendClr = bullClr;
         else if(direction == "BEARISH") trendClr = bearClr;
         ObjectSetInteger(0, name, OBJPROP_COLOR, trendClr);
      }
      else if(i == 13)
         ObjectSetInteger(0, name, OBJPROP_COLOR, (positionText == "FLAT") ? textClr : posClr);
      else if(i == 0 || i == 1)
         ObjectSetInteger(0, name, OBJPROP_COLOR, headerClr);
      else
         ObjectSetInteger(0, name, OBJPROP_COLOR, textClr);
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
