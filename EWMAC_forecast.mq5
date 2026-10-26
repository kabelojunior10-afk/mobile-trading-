//+------------------------------------------------------------------+
//|                                            EWMAC_Forecast.mq5    |
//|            Carver Starter System — Forecast Pane (subwindow)     |
//|         Mirrors the TradingView Pine "EWMAC" indicator exactly   |
//|  v1.08: fully configurable inputs                                |
//+------------------------------------------------------------------+
#property copyright   "Amare Capital Management"
#property description "EWMAC forecast, capped ±20. Matches the EWMAC_EA."
#property version     "1.08"
#property indicator_separate_window
#property indicator_buffers 5
#property indicator_plots   3

// Forecast line
#property indicator_label1  "Forecast"
#property indicator_type1   DRAW_LINE
#property indicator_color1  clrDodgerBlue
#property indicator_style1  STYLE_SOLID
#property indicator_width1  2

// Buy arrow
#property indicator_label2  "Buy"
#property indicator_type2   DRAW_ARROW
#property indicator_color2  clrLime
#property indicator_width2  2

// Sell arrow
#property indicator_label3  "Sell"
#property indicator_type3   DRAW_ARROW
#property indicator_color3  clrRed
#property indicator_width3  2

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
input ENUM_EWMAC_PAIR Pair           = PAIR_8_32;   // EWMAC pair
input int             StdevWindow    = 50;          // StdDev window of price changes (bars)
input double          CapMin         = -20.0;       // Forecast cap min
input double          CapMax         =  20.0;       // Forecast cap max
input double          BuyThreshold   =   0.0;       // Buy signal threshold
input double          SellThreshold  =   0.0;       // Sell signal threshold
input bool            UseCarverScalar = true;       // true = Carver scalars, false = 10/sqrt(fast)

input group "Display"
input bool            ShowHUD        = true;        // Show on-chart HUD label
input int             HUD_Y          = 120;         // HUD vertical offset (pixels)

//--- buffers
double ForecastBuffer[];
double BuyBuffer[];
double SellBuffer[];
double FastEma[];
double SlowEma[];

//--- resolved parameters
int    fast_period = 8;
int    slow_period = 32;
double scalar      = 5.3;

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
//| Incremental EMA (SMA seed)                                       |
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
    if(BuyThreshold  < CapMin)       return INIT_PARAMETERS_INCORRECT;
    if(SellThreshold > CapMax)       return INIT_PARAMETERS_INCORRECT;
    if(BuyThreshold < SellThreshold) return INIT_PARAMETERS_INCORRECT;

    SetIndexBuffer(0, ForecastBuffer, INDICATOR_DATA);
    SetIndexBuffer(1, BuyBuffer,      INDICATOR_DATA);
    SetIndexBuffer(2, SellBuffer,     INDICATOR_DATA);
    SetIndexBuffer(3, FastEma,        INDICATOR_CALCULATIONS);
    SetIndexBuffer(4, SlowEma,        INDICATOR_CALCULATIONS);

    PlotIndexSetInteger(1, PLOT_ARROW, 233);
    PlotIndexSetInteger(2, PLOT_ARROW, 234);

    PlotIndexSetDouble(0, PLOT_EMPTY_VALUE, EMPTY_VALUE);
    PlotIndexSetDouble(1, PLOT_EMPTY_VALUE, EMPTY_VALUE);
    PlotIndexSetDouble(2, PLOT_EMPTY_VALUE, EMPTY_VALUE);

    IndicatorSetInteger(INDICATOR_LEVELS, 5);
    IndicatorSetDouble(INDICATOR_LEVELVALUE, 0, 0.0);
    IndicatorSetDouble(INDICATOR_LEVELVALUE, 1, CapMax);
    IndicatorSetDouble(INDICATOR_LEVELVALUE, 2, CapMin);
    IndicatorSetDouble(INDICATOR_LEVELVALUE, 3, BuyThreshold);
    IndicatorSetDouble(INDICATOR_LEVELVALUE, 4, SellThreshold);

    IndicatorSetInteger(INDICATOR_LEVELCOLOR, 0, clrGray);
    IndicatorSetInteger(INDICATOR_LEVELCOLOR, 1, clrDimGray);
    IndicatorSetInteger(INDICATOR_LEVELCOLOR, 2, clrDimGray);
    IndicatorSetInteger(INDICATOR_LEVELCOLOR, 3, clrSeaGreen);
    IndicatorSetInteger(INDICATOR_LEVELCOLOR, 4, clrIndianRed);

    IndicatorSetInteger(INDICATOR_LEVELSTYLE, 0, STYLE_DOT);
    IndicatorSetInteger(INDICATOR_LEVELSTYLE, 1, STYLE_DASHDOT);
    IndicatorSetInteger(INDICATOR_LEVELSTYLE, 2, STYLE_DASHDOT);
    IndicatorSetInteger(INDICATOR_LEVELSTYLE, 3, STYLE_DOT);
    IndicatorSetInteger(INDICATOR_LEVELSTYLE, 4, STYLE_DOT);

    IndicatorSetDouble(INDICATOR_MINIMUM, CapMin - 5);
    IndicatorSetDouble(INDICATOR_MAXIMUM, CapMax + 5);

    IndicatorSetString(INDICATOR_SHORTNAME,
        StringFormat("EWMAC %d/%d Forecast (σ=%d)",
                     fast_period, slow_period, StdevWindow));

    return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
double RollingStdev(const double &close[], int i)
{
    if(i < 1) return EMPTY_VALUE;
    double sum   = 0.0;
    double sumSq = 0.0;
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

    CalcEMA(close, FastEma, fast_period, rates_total, prev_calculated);
    CalcEMA(close, SlowEma, slow_period, rates_total, prev_calculated);

    int start;
    if(prev_calculated < min_bars)
    {
        start = min_bars - 1;
        for(int i = 0; i < min_bars; i++)
        {
            ForecastBuffer[i] = EMPTY_VALUE;
            BuyBuffer[i]      = EMPTY_VALUE;
            SellBuffer[i]     = EMPTY_VALUE;
        }
    }
    else
    {
        start = prev_calculated - 1;
        if(start < min_bars) start = min_bars - 1;
    }

    for(int i = start; i < rates_total; i++)
    {
        if(FastEma[i] == EMPTY_VALUE || SlowEma[i] == EMPTY_VALUE)
        {
            ForecastBuffer[i] = EMPTY_VALUE;
            BuyBuffer[i]      = EMPTY_VALUE;
            SellBuffer[i]     = EMPTY_VALUE;
            continue;
        }

        double stdev = RollingStdev(close, i);
        if(stdev == EMPTY_VALUE || stdev < _Point * 0.1)
            stdev = close[i] * 0.002;
        if(stdev <= 0)
        {
            ForecastBuffer[i] = EMPTY_VALUE;
            BuyBuffer[i]      = EMPTY_VALUE;
            SellBuffer[i]     = EMPTY_VALUE;
            continue;
        }

        double raw_ewmac = FastEma[i] - SlowEma[i];
        double forecast  = raw_ewmac / stdev * scalar;
        double capped    = MathMax(CapMin, MathMin(CapMax, forecast));
        ForecastBuffer[i] = capped;

        bool buy = false, sell = false;
        if(i > 0 && ForecastBuffer[i-1] != EMPTY_VALUE)
        {
            double prev = ForecastBuffer[i-1];
            if(prev <= BuyThreshold  && capped > BuyThreshold)  buy  = true;
            if(prev >= SellThreshold && capped < SellThreshold) sell = true;
        }

        // arrows only on closed bars
        bool closed = (i < rates_total - 1);
        BuyBuffer[i]  = (buy  && closed) ? -CapMax - 2.5 : EMPTY_VALUE;
        SellBuffer[i] = (sell && closed) ?  CapMax + 2.5 : EMPTY_VALUE;
    }

    if(ShowHUD) DrawHUD(rates_total);
    return rates_total;
}

//+------------------------------------------------------------------+
void DrawHUD(int rates_total)
{
    if(rates_total < 1) return;
    int    last = rates_total - 1;
    double f    = ForecastBuffer[last];

    bool isLight = IsLightChart();
    string label = "—";
    color  col   = isLight ? clrBlack : clrWhite;

    if(f != EMPTY_VALUE)
    {
        if(f >= 17.5)       { label = "VERY STRONG BUY";  col = isLight ? clrGreen : clrLime; }
        else if(f >= 12.5)  { label = "STRONG BUY";       col = isLight ? clrGreen : clrLime; }
        else if(f >= 7.5)   { label = "BUY";              col = isLight ? clrDarkGreen : clrLimeGreen; }
        else if(f >= 2.5)   { label = "WEAK BUY";         col = isLight ? clrForestGreen : clrLimeGreen; }
        else if(f > -2.5)   { label = "NEUTRAL";          col = isLight ? clrDarkOrange : clrYellow; }
        else if(f > -7.5)   { label = "WEAK SELL";        col = isLight ? clrChocolate : clrOrange; }
        else if(f > -12.5)  { label = "SELL";             col = isLight ? clrFireBrick : clrOrangeRed; }
        else if(f > -17.5)  { label = "STRONG SELL";      col = isLight ? clrRed : clrRed; }
        else                { label = "VERY STRONG SELL"; col = isLight ? clrRed : clrRed; }
    }

    string txt = StringFormat("EWMAC %d/%d  |  scalar %.2f  |  forecast %s  |  %s",
                              fast_period, slow_period, scalar,
                              (f == EMPTY_VALUE ? "—" : DoubleToString(f, 2)),
                              label);

    if(ObjectFind(0, "EWMAC_HUD") < 0)
        ObjectCreate(0, "EWMAC_HUD", OBJ_LABEL, 0, 0, 0);

    ObjectSetInteger(0, "EWMAC_HUD", OBJPROP_CORNER,     CORNER_LEFT_UPPER);
    ObjectSetInteger(0, "EWMAC_HUD", OBJPROP_XDISTANCE,  10);
    ObjectSetInteger(0, "EWMAC_HUD", OBJPROP_YDISTANCE,  HUD_Y);
    ObjectSetString (0, "EWMAC_HUD", OBJPROP_TEXT,       txt);
    ObjectSetInteger(0, "EWMAC_HUD", OBJPROP_COLOR,      col);
    ObjectSetInteger(0, "EWMAC_HUD", OBJPROP_FONTSIZE,   10);
    ObjectSetString (0, "EWMAC_HUD", OBJPROP_FONT,       "Consolas");
    ObjectSetInteger(0, "EWMAC_HUD", OBJPROP_SELECTABLE, false);
    ObjectSetInteger(0, "EWMAC_HUD", OBJPROP_BACK,       false);
    ObjectSetInteger(0, "EWMAC_HUD", OBJPROP_HIDDEN,     true);
}

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
    ObjectDelete(0, "EWMAC_HUD");
}
//+------------------------------------------------------------------+