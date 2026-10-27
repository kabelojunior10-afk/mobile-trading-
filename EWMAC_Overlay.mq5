//+------------------------------------------------------------------+
//|                                             EWMAC_Overlay.mq5    |
//|             Carver Starter System — EWMA lines + signals         |
//|  v1.05: fully configurable inputs                                |
//+------------------------------------------------------------------+
#property copyright   "Amare Capital Management"
#property description "EWMAC EWMA overlay with colour-flip and arrows."
#property version     "1.05"
#property indicator_chart_window
#property indicator_buffers 6
#property indicator_plots   4

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

input group "EWMAC Core"
input ENUM_EWMAC_PAIR Pair           = PAIR_8_32;
input int             StdevWindow    = 50;
input double          CapMin         = -20.0;
input double          CapMax         =  20.0;
input double          BuyThreshold   =   0.0;
input double          SellThreshold  =   0.0;
input bool            UseCarverScalar = true;

input group "Display"
input int             ArrowOffsetPts = 5;    // arrow distance from candle (points)

//--- buffers
double FastBuf[];
double FastColor[];
double SlowBuf[];
double BuyBuf[];
double SellBuf[];
double FcBuf[];

int    fast_period = 8;
int    slow_period = 32;
double scalar      = 5.3;

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

   for(int i = s; i < total; i++)
      ema[i] = a * close[i] + (1.0 - a) * ema[i - 1];
}

//+------------------------------------------------------------------+
int OnInit()
{
    switch(Pair)
    {
        case PAIR_2_8:    fast_period=2;  slow_period=8;   break;
        case PAIR_4_16:   fast_period=4;  slow_period=16;  break;
        case PAIR_8_32:   fast_period=8;  slow_period=32;  break;
        case PAIR_16_64:  fast_period=16; slow_period=64;  break;
        case PAIR_32_128: fast_period=32; slow_period=128; break;
        case PAIR_64_256: fast_period=64; slow_period=256; break;
    }

    if(UseCarverScalar)
    {
        switch(Pair)
        {
            case PAIR_2_8:    scalar=10.6; break;
            case PAIR_4_16:   scalar=7.5;  break;
            case PAIR_8_32:   scalar=5.3;  break;
            case PAIR_16_64:  scalar=3.75; break;
            case PAIR_32_128: scalar=2.65; break;
            case PAIR_64_256: scalar=1.87; break;
        }
    }
    else
        scalar = 10.0 / MathSqrt((double)fast_period);

    if(StdevWindow < 2)              return INIT_PARAMETERS_INCORRECT;
    if(CapMax <= CapMin)             return INIT_PARAMETERS_INCORRECT;
    if(BuyThreshold < SellThreshold) return INIT_PARAMETERS_INCORRECT;

    SetIndexBuffer(0, FastBuf,   INDICATOR_DATA);
    SetIndexBuffer(1, FastColor, INDICATOR_COLOR_INDEX);
    SetIndexBuffer(2, SlowBuf,   INDICATOR_DATA);
    SetIndexBuffer(3, BuyBuf,    INDICATOR_DATA);
    SetIndexBuffer(4, SellBuf,   INDICATOR_DATA);
    SetIndexBuffer(5, FcBuf,     INDICATOR_CALCULATIONS);

    PlotIndexSetInteger(2, PLOT_ARROW, 233);
    PlotIndexSetInteger(3, PLOT_ARROW, 234);

    for(int p = 0; p < 4; p++)
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

    CalcEMA(close, FastBuf, fast_period, rates_total, prev_calculated);
    CalcEMA(close, SlowBuf, slow_period, rates_total, prev_calculated);

    int start;
    if(prev_calculated < min_bars)
    {
        start = min_bars - 1;
        for(int i = 0; i < min_bars; i++)
        {
            FastColor[i] = 0;
            BuyBuf[i]    = EMPTY_VALUE;
            SellBuf[i]   = EMPTY_VALUE;
            FcBuf[i]     = EMPTY_VALUE;
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
        FastColor[i] = (FastBuf[i] != EMPTY_VALUE &&
                        SlowBuf[i] != EMPTY_VALUE &&
                        FastBuf[i] > SlowBuf[i]) ? 0 : 1;

        BuyBuf[i]  = EMPTY_VALUE;
        SellBuf[i] = EMPTY_VALUE;

        double capped = ComputeCappedForecast(close, i, FastBuf, SlowBuf);
        double prev_forecast = (i > 0) ? FcBuf[i-1] : EMPTY_VALUE;
        FcBuf[i] = capped;

        bool buySig = false, sellSig = false;
        if(capped != EMPTY_VALUE && prev_forecast != EMPTY_VALUE)
        {
            if(prev_forecast <= BuyThreshold  && capped > BuyThreshold)  buySig  = true;
            if(prev_forecast >= SellThreshold && capped < SellThreshold) sellSig = true;
        }

        // closed bars only
        if(i >= rates_total - 1)
        {
            buySig  = false;
            sellSig = false;
        }

        if(buySig)  BuyBuf[i]  = low[i]  - offset;
        if(sellSig) SellBuf[i] = high[i] + offset;
    }

    return rates_total;
}

//+------------------------------------------------------------------+
void OnDeinit(const int reason) { }
//+------------------------------------------------------------------+
