//+------------------------------------------------------------------+
//|                                             EWMAC_Overlay.mq5    |
//|             Carver Starter System — EWMA lines + signals         |
//|        Mirror of the Pine "force_overlay" EWMA lines & arrows    |
//|                                                                  |
//|  v1.03: incremental EMAs (stored in FastBuf/SlowBuf, no extra    |
//|  buffers), signals only on closed bars, zero-cross thresholds.   |
//|  Lines tagged [CHG] were changed vs v1.02.                       |
//+------------------------------------------------------------------+
#property copyright   "Amare Capital Management"
#property description "EWMAC EWMA overlay with colour-flip, arrows and ATR trailing stop."
#property version     "1.03"
#property indicator_chart_window
#property indicator_buffers 12
#property indicator_plots   7

// Fast EWMA — colour-flips green/red based on sign of the crossover
#property indicator_label1  "Fast EWMA"
#property indicator_type1   DRAW_COLOR_LINE
#property indicator_color1  clrLime, clrRed
#property indicator_width1  2

// Slow EWMA
#property indicator_label2  "Slow EWMA"
#property indicator_type2   DRAW_LINE
#property indicator_color2  clrDodgerBlue
#property indicator_style2  STYLE_SOLID
#property indicator_width2  2

// Buy arrow
#property indicator_label3  "Long Signal"
#property indicator_type3   DRAW_ARROW
#property indicator_color3  clrLime
#property indicator_width3  3

// Sell arrow
#property indicator_label4  "Short Signal"
#property indicator_type4   DRAW_ARROW
#property indicator_color4  clrRed
#property indicator_width4  3

// ATR trailing stop of a long position (below price)
#property indicator_label5  "ATR Trail SL (Long)"
#property indicator_type5   DRAW_LINE
#property indicator_color5  clrOrangeRed
#property indicator_style5  STYLE_DASH
#property indicator_width5  1

// ATR trailing stop of a short position (above price)
#property indicator_label6  "ATR Trail SL (Short)"
#property indicator_type6   DRAW_LINE
#property indicator_color6  clrOrangeRed
#property indicator_style6  STYLE_DASH
#property indicator_width6  1

// Stop-out marker
#property indicator_label7  "Stop Hit"
#property indicator_type7   DRAW_ARROW
#property indicator_color7  clrOrangeRed
#property indicator_width7  2

//------------------------------------------------------------------|
enum ENUM_EWMAC_PAIR
{
    PAIR_2_8    = 0,
    PAIR_4_16   = 1,
    PAIR_8_32   = 2,
    PAIR_16_64  = 3,
    PAIR_32_128 = 4,
    PAIR_64_256 = 5
};

input ENUM_EWMAC_PAIR Pair     = PAIR_8_32;
input int     StdevWindow     = 50;
input double  CapMin          = -20.0;
input double  CapMax          =  20.0;
input double  BuyThreshold    =   0.0;   // [CHG] was 5.0
input double  SellThreshold   =   0.0;   // [CHG] was -5.0
input int     ArrowOffsetPts  = 5;    // arrow distance from candle (points)

// keep these equal to the EA inputs
input bool    UseATRTrail     = true;   // draw simulated ATR trailing stop
input int     ATRPeriod       = 14;     // ATR (SMA of true range, same as iATR)
input double  ATRMultiplier   = 3.0;    // stop distance = ATR * multiplier
input double  TrailStartATR   = 1.0;    // trailing starts after profit >= this many ATR
input double  TrailStepATR    = 0.1;    // min SL improvement per move (in ATR)

//--- buffers
double FastBuf[];         // plot + EMA storage
double FastColor[];
double SlowBuf[];         // plot + EMA storage
double BuyBuf[];
double SellBuf[];
double TrailLongBuf[];
double TrailShortBuf[];
double StopHitBuf[];
double FcBuf[];           // calc: capped forecast per bar
double SideBuf[];         // calc: simulated position side (1 / -1 / 0)
double OpenBuf[];         // calc: simulated entry price
double SLBuf[];           // calc: simulated stop price

int    fast_period = 8;
int    slow_period = 32;
double scalar      = 5.3;

//+------------------------------------------------------------------+
//| [CHG] Incremental EMA (SMA seed, same as EA)                     |
//+------------------------------------------------------------------+
void CalcEMA(const double &close[], double &ema[], int period, int total, int prev)
{
   double a = 2.0 / (period + 1);
   int s;
   if(prev <= 0)
   {
      for(int i = 0; i < period - 1; i++) ema[i] = EMPTY_VALUE;
      double seed = 0.0;
      for(int i = 0; i < period; i++) seed += close[i];
      ema[period - 1] = seed / period;
      s = period;
   }
   else s = prev - 1;
   for(int i = s; i < total; i++) ema[i] = a * close[i] + (1.0 - a) * ema[i - 1];
}

//+------------------------------------------------------------------+
int OnInit()
{
    switch(Pair)
    {
        case PAIR_2_8:    fast_period=2;  slow_period=8;   scalar=10.6; break;
        case PAIR_4_16:   fast_period=4;  slow_period=16;  scalar=7.5;  break;
        case PAIR_8_32:   fast_period=8;  slow_period=32;  scalar=5.3;  break;
        case PAIR_16_64:  fast_period=16; slow_period=64;  scalar=3.75; break;
        case PAIR_32_128: fast_period=32; slow_period=128; scalar=2.65; break;
        case PAIR_64_256: fast_period=64; slow_period=256; scalar=1.87; break;
    }
    if(StdevWindow < 2)              return INIT_PARAMETERS_INCORRECT;
    if(CapMax <= CapMin)             return INIT_PARAMETERS_INCORRECT;
    if(BuyThreshold < SellThreshold) return INIT_PARAMETERS_INCORRECT;
    if(UseATRTrail && (ATRPeriod < 1 || ATRMultiplier <= 0.0 ||
                       TrailStartATR < 0.0 || TrailStepATR < 0.0))
                                     return INIT_PARAMETERS_INCORRECT;

    SetIndexBuffer(0, FastBuf,       INDICATOR_DATA);
    SetIndexBuffer(1, FastColor,     INDICATOR_COLOR_INDEX);
    SetIndexBuffer(2, SlowBuf,       INDICATOR_DATA);
    SetIndexBuffer(3, BuyBuf,        INDICATOR_DATA);
    SetIndexBuffer(4, SellBuf,       INDICATOR_DATA);
    SetIndexBuffer(5, TrailLongBuf,  INDICATOR_DATA);
    SetIndexBuffer(6, TrailShortBuf, INDICATOR_DATA);
    SetIndexBuffer(7, StopHitBuf,    INDICATOR_DATA);
    SetIndexBuffer(8, FcBuf,         INDICATOR_CALCULATIONS);
    SetIndexBuffer(9, SideBuf,       INDICATOR_CALCULATIONS);
    SetIndexBuffer(10, OpenBuf,      INDICATOR_CALCULATIONS);
    SetIndexBuffer(11, SLBuf,        INDICATOR_CALCULATIONS);

    PlotIndexSetInteger(2, PLOT_ARROW, 233); // up
    PlotIndexSetInteger(3, PLOT_ARROW, 234); // down
    PlotIndexSetInteger(6, PLOT_ARROW, 251); // stop-out cross

    // plot indices: 0 fast, 1 slow, 2 buy, 3 sell, 4 trail long, 5 trail short, 6 stop hit
    for(int p = 0; p < 7; p++)
        PlotIndexSetDouble(p, PLOT_EMPTY_VALUE, EMPTY_VALUE);

    IndicatorSetString(INDICATOR_SHORTNAME,
        StringFormat("EWMAC Overlay %d/%d", fast_period, slow_period));
    return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
double RollingStdev(const double &close[], int i)
{
    if(i < 1) return EMPTY_VALUE;
    double sum = 0.0, sumSq = 0.0;
    int    count = 0;
    for(int j = 0; j < StdevWindow; j++)
    {
        int idx = i - j;
        if(idx < 1) break;
        double diff = close[idx] - close[idx - 1];
        sum   += diff;
        sumSq += diff * diff;
        count++;
    }
    if(count < StdevWindow) return EMPTY_VALUE;
    double mean = sum / StdevWindow;
    double var  = sumSq / StdevWindow - mean * mean;
    return MathSqrt(MathMax(var, 0.0));
}

//+------------------------------------------------------------------+
double ComputeCappedForecast(const double &close[], int i,
                             const double &fast[], const double &slow[])
{
    if(i < 1) return EMPTY_VALUE;
    if(fast[i] == EMPTY_VALUE || slow[i] == EMPTY_VALUE) return EMPTY_VALUE;
    double stdev = RollingStdev(close, i);
    if(stdev == EMPTY_VALUE || stdev < _Point * 0.1)
        stdev = close[i] * 0.002;
    if(stdev <= 0) return EMPTY_VALUE;
    double raw = fast[i] - slow[i];
    double f   = raw / stdev * scalar;
    return MathMax(CapMin, MathMin(CapMax, f));
}

//+------------------------------------------------------------------+
//| ATR at bar i = SMA of true range (identical to iATR)             |
//+------------------------------------------------------------------+
double AtrAt(const double &high[], const double &low[], const double &close[], int i)
{
    if(!UseATRTrail || i < ATRPeriod) return 0.0;
    double sum = 0.0;
    for(int j = 0; j < ATRPeriod; j++)
    {
        int k = i - j;
        double tr = MathMax(high[k] - low[k],
                    MathMax(MathAbs(high[k] - close[k-1]),
                            MathAbs(low[k]  - close[k-1])));
        sum += tr;
    }
    return sum / ATRPeriod;
}

//+------------------------------------------------------------------+
int OnCalculate(const int rates_total,
                const int prev_calculated,
                const datetime &time[],
                const double &open[],
                const double &high[],
                const double &low[],
                const double &close[],
                const long &tick_volume[],
                const long &volume[],
                const int &spread[])
{
    int min_bars = StdevWindow + slow_period + 5;
    if(rates_total < min_bars) return 0;

    //--- [CHG] incremental EMAs written straight into the plot buffers
    CalcEMA(close, FastBuf, fast_period, rates_total, prev_calculated);
    CalcEMA(close, SlowBuf, slow_period, rates_total, prev_calculated);

    //--- Start bar
    int start;
    if(prev_calculated < min_bars)
    {
        start = min_bars - 1;
        for(int i = 0; i < min_bars; i++)
        {
            // [CHG] FastBuf / SlowBuf are NOT wiped here (they hold the EMAs)
            FastColor[i]     = 0;
            BuyBuf[i]        = EMPTY_VALUE;
            SellBuf[i]       = EMPTY_VALUE;
            TrailLongBuf[i]  = EMPTY_VALUE;
            TrailShortBuf[i] = EMPTY_VALUE;
            StopHitBuf[i]    = EMPTY_VALUE;
            FcBuf[i]         = EMPTY_VALUE;
            SideBuf[i]       = 0.0;
            OpenBuf[i]       = 0.0;
            SLBuf[i]         = 0.0;
        }
    }
    else
    {
        start = prev_calculated - 1;
        if(start < min_bars) start = min_bars - 1;
    }

    double offset = ArrowOffsetPts * _Point;

    for(int i = start; i < rates_total; i++)
    {
        // [CHG] FastBuf[i]/SlowBuf[i] already set by CalcEMA
        FastColor[i] = (FastBuf[i] != EMPTY_VALUE &&
                        SlowBuf[i] != EMPTY_VALUE &&
                        FastBuf[i] > SlowBuf[i]) ? 0 : 1; // 0=green, 1=red
        BuyBuf[i]    = EMPTY_VALUE;
        SellBuf[i]   = EMPTY_VALUE;

        double capped = ComputeCappedForecast(close, i, FastBuf, SlowBuf);   // [CHG]
        double prev_forecast = (i > 0) ? FcBuf[i-1] : EMPTY_VALUE;
        FcBuf[i] = capped;

        bool buySig = false, sellSig = false;
        if(capped != EMPTY_VALUE && prev_forecast != EMPTY_VALUE)
        {
            if(prev_forecast <= BuyThreshold  && capped > BuyThreshold)  buySig  = true;
            if(prev_forecast >= SellThreshold && capped < SellThreshold) sellSig = true;
        }

        // [CHG] closed bars only (EA acts on closed bars)
        if(i >= rates_total - 1) { buySig = false; sellSig = false; }

        if(buySig)  BuyBuf[i]  = low[i]  - offset;
        if(sellSig) SellBuf[i] = high[i] + offset;

        //--- simulated ATR trailing stop (state carried from bar i-1)
        TrailLongBuf[i]  = EMPTY_VALUE;
        TrailShortBuf[i] = EMPTY_VALUE;
        StopHitBuf[i]    = EMPTY_VALUE;

        double side  = SideBuf[i-1];
        double openP = OpenBuf[i-1];
        double sl    = SLBuf[i-1];

        if(UseATRTrail)
        {
            double atr  = AtrAt(high, low, close, i);
            double dist = ATRMultiplier * atr;
            double step = MathMax(TrailStepATR * atr, _Point);

            // 1) was the stop (set at the previous bar) hit during this bar?
            if(side != 0.0 && sl > 0.0)
            {
                if(side > 0.0 && low[i] <= sl)
                {
                    StopHitBuf[i]   = sl;
                    TrailLongBuf[i] = sl;
                    side = 0.0; sl = 0.0;
                }
                else if(side < 0.0 && high[i] >= sl)
                {
                    StopHitBuf[i]    = sl;
                    TrailShortBuf[i] = sl;
                    side = 0.0; sl = 0.0;
                }
            }

            // 2) new signal: enter / reverse with initial stop
            if(buySig && side <= 0.0)
            {
                side = 1.0;  openP = close[i];
                sl = (atr > 0.0) ? close[i] - dist : 0.0;
            }
            else if(sellSig && side >= 0.0)
            {
                side = -1.0; openP = close[i];
                sl = (atr > 0.0) ? close[i] + dist : 0.0;
            }
            // 3) otherwise manage the open position
            else if(side != 0.0 && atr > 0.0)
            {
                if(side > 0.0)
                {
                    if(sl <= 0.0) sl = MathMin(openP, close[i]) - dist;
                    else if(close[i] - openP >= TrailStartATR * atr)
                    {
                        double cand = close[i] - dist;
                        if(cand > sl + step) sl = cand;
                    }
                }
                else
                {
                    if(sl <= 0.0) sl = MathMax(openP, close[i]) + dist;
                    else if(openP - close[i] >= TrailStartATR * atr)
                    {
                        double cand = close[i] + dist;
                        if(cand < sl - step) sl = cand;
                    }
                }
            }

            // plot the live stop
            if(side > 0.0 && sl > 0.0)       TrailLongBuf[i]  = sl;
            else if(side < 0.0 && sl > 0.0)  TrailShortBuf[i] = sl;
        }

        SideBuf[i] = side;
        OpenBuf[i] = openP;
        SLBuf[i]   = sl;
    }

    return rates_total;
}

//+------------------------------------------------------------------+
void OnDeinit(const int reason) { }
//+------------------------------------------------------------------+