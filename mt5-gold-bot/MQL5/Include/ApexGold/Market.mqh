//+------------------------------------------------------------------+
//|                                                       Market.mqh |
//|   Timeframe feeds, market structure, regime and volatility state  |
//+------------------------------------------------------------------+
#ifndef APEXGOLD_MARKET_MQH
#define APEXGOLD_MARKET_MQH

#include "Config.mqh"
#include "Utils.mqh"

//--- shared indicator periods (kept central so research and EA agree)
#define APEX_EMA_FAST   20
#define APEX_EMA_SLOW   50
#define APEX_EMA_BASE   200
#define APEX_ATR_PERIOD 14
#define APEX_ADX_PERIOD 14
#define APEX_RSI_PERIOD 14
#define APEX_VOL_WINDOW 120   // bars used for the ATR percentile
#define APEX_MAX_BARS   600   // bars copied per timeframe

//+------------------------------------------------------------------+
//| One timeframe worth of prices and indicators, series-ordered      |
//| (index 0 is the newest bar).                                      |
//+------------------------------------------------------------------+
class CTfFeed
  {
private:
   string            m_symbol;
   ENUM_TIMEFRAMES   m_tf;
   int               m_hEmaF, m_hEmaS, m_hEmaB, m_hAtr, m_hAdx, m_hRsi;
   int               m_bars;
   bool              m_ok;

public:
   MqlRates          rates[];
   double            emaF[];
   double            emaS[];
   double            emaB[];
   double            atr[];
   double            adx[];
   double            adxPlus[];
   double            adxMinus[];
   double            rsi[];

                     CTfFeed(void) { m_hEmaF = INVALID_HANDLE; m_hEmaS = INVALID_HANDLE; m_hEmaB = INVALID_HANDLE;
                                     m_hAtr = INVALID_HANDLE; m_hAdx = INVALID_HANDLE; m_hRsi = INVALID_HANDLE;
                                     m_bars = 0; m_ok = false; m_tf = PERIOD_CURRENT; m_symbol = ""; }
                    ~CTfFeed(void) { Deinit(); }

   bool              Init(const string symbol, const ENUM_TIMEFRAMES tf, const int bars)
     {
      m_symbol = symbol;
      m_tf     = tf;
      m_bars   = (int)MathMax(bars, APEX_EMA_BASE + APEX_VOL_WINDOW + 20);

      m_hEmaF = iMA(m_symbol, m_tf, APEX_EMA_FAST, 0, MODE_EMA, PRICE_CLOSE);
      m_hEmaS = iMA(m_symbol, m_tf, APEX_EMA_SLOW, 0, MODE_EMA, PRICE_CLOSE);
      m_hEmaB = iMA(m_symbol, m_tf, APEX_EMA_BASE, 0, MODE_EMA, PRICE_CLOSE);
      m_hAtr  = iATR(m_symbol, m_tf, APEX_ATR_PERIOD);
      m_hAdx  = iADX(m_symbol, m_tf, APEX_ADX_PERIOD);
      m_hRsi  = iRSI(m_symbol, m_tf, APEX_RSI_PERIOD, PRICE_CLOSE);

      m_ok = (m_hEmaF != INVALID_HANDLE && m_hEmaS != INVALID_HANDLE && m_hEmaB != INVALID_HANDLE &&
              m_hAtr  != INVALID_HANDLE && m_hAdx  != INVALID_HANDLE && m_hRsi  != INVALID_HANDLE);

      ArraySetAsSeries(rates, true);
      ArraySetAsSeries(emaF, true);
      ArraySetAsSeries(emaS, true);
      ArraySetAsSeries(emaB, true);
      ArraySetAsSeries(atr, true);
      ArraySetAsSeries(adx, true);
      ArraySetAsSeries(adxPlus, true);
      ArraySetAsSeries(adxMinus, true);
      ArraySetAsSeries(rsi, true);
      return m_ok;
     }

   void              Deinit(void)
     {
      if(m_hEmaF != INVALID_HANDLE) { IndicatorRelease(m_hEmaF); m_hEmaF = INVALID_HANDLE; }
      if(m_hEmaS != INVALID_HANDLE) { IndicatorRelease(m_hEmaS); m_hEmaS = INVALID_HANDLE; }
      if(m_hEmaB != INVALID_HANDLE) { IndicatorRelease(m_hEmaB); m_hEmaB = INVALID_HANDLE; }
      if(m_hAtr  != INVALID_HANDLE) { IndicatorRelease(m_hAtr);  m_hAtr  = INVALID_HANDLE; }
      if(m_hAdx  != INVALID_HANDLE) { IndicatorRelease(m_hAdx);  m_hAdx  = INVALID_HANDLE; }
      if(m_hRsi  != INVALID_HANDLE) { IndicatorRelease(m_hRsi);  m_hRsi  = INVALID_HANDLE; }
     }

   //--- returns false when the terminal has not finished loading history
   bool              Update(void)
     {
      if(!m_ok)
         return false;

      int got = CopyRates(m_symbol, m_tf, 0, m_bars, rates);
      if(got < APEX_EMA_BASE + 10)
         return false;

      int n = got;
      if(CopyBuffer(m_hEmaF, 0, 0, n, emaF) < n) return false;
      if(CopyBuffer(m_hEmaS, 0, 0, n, emaS) < n) return false;
      if(CopyBuffer(m_hEmaB, 0, 0, n, emaB) < n) return false;
      if(CopyBuffer(m_hAtr,  0, 0, n, atr)  < n) return false;
      if(CopyBuffer(m_hAdx,  0, 0, n, adx)  < n) return false;
      if(CopyBuffer(m_hAdx,  1, 0, n, adxPlus)  < n) return false;
      if(CopyBuffer(m_hAdx,  2, 0, n, adxMinus) < n) return false;
      if(CopyBuffer(m_hRsi,  0, 0, n, rsi)  < n) return false;
      return true;
     }

   int               Bars(void) const { return ArraySize(rates); }
   ENUM_TIMEFRAMES   Tf(void)   const { return m_tf; }
  };

//+------------------------------------------------------------------+
//| Swing point                                                       |
//+------------------------------------------------------------------+
struct SSwing
  {
   int               index;
   double            price;
   datetime          time;
   bool              valid;
  };

//+------------------------------------------------------------------+
//| Session window in GMT hours, resolved against a bar timestamp     |
//+------------------------------------------------------------------+
struct SSessionRange
  {
   double            high;
   double            low;
   int               bars;
   bool              valid;
  };

//+------------------------------------------------------------------+
//| Market context: owns the three feeds and derives regime, volatility|
//| state, structure and the session ranges the setups need.          |
//+------------------------------------------------------------------+
class CMarket
  {
private:
   string            m_symbol;
   SConfig           m_cfg;
   CLogger          *m_log;

   ENUM_APEX_REGIME  m_regime;
   ENUM_APEX_VOLSTATE m_volState;
   double            m_atrPct;      // ATR percentile on the context timeframe
   int               m_biasDir;     // +1 / -1 / 0

public:
   CTfFeed           bias;
   CTfFeed           ctx;
   CTfFeed           entry;

                     CMarket(void) { m_log = NULL; m_regime = APEX_REGIME_UNKNOWN;
                                     m_volState = APEX_VOL_NORMAL; m_atrPct = 50.0; m_biasDir = 0; m_symbol = ""; }

   bool              Init(const string symbol, const SConfig &cfg, CLogger *logger)
     {
      m_symbol = symbol;
      m_cfg    = cfg;
      m_log    = logger;

      if(!bias.Init(symbol, cfg.tfBias, APEX_MAX_BARS))    return false;
      if(!ctx.Init(symbol, cfg.tfContext, APEX_MAX_BARS))  return false;
      if(!entry.Init(symbol, cfg.tfEntry, APEX_MAX_BARS))  return false;
      return true;
     }

   void              Deinit(void)
     {
      bias.Deinit();
      ctx.Deinit();
      entry.Deinit();
     }

   bool              Refresh(void)
     {
      if(!bias.Update())  return false;
      if(!ctx.Update())   return false;
      if(!entry.Update()) return false;

      ClassifyBias();
      ClassifyVolatility();
      ClassifyRegime();
      return true;
     }

   ENUM_APEX_REGIME  Regime(void)   const { return m_regime; }
   ENUM_APEX_VOLSTATE VolState(void)const { return m_volState; }
   double            AtrPercentile(void) const { return m_atrPct; }
   int               BiasDir(void)  const { return m_biasDir; }
   double            EntryAtr(const int shift = 1)
     {
      int n = ArraySize(entry.atr);
      if(shift < 0 || shift >= n) return 0.0;
      return entry.atr[shift];
     }
   double            CtxAtr(const int shift = 1)
     {
      int n = ArraySize(ctx.atr);
      if(shift < 0 || shift >= n) return 0.0;
      return ctx.atr[shift];
     }

   //+---------------------------------------------------------------+
   //| Directional bias from the highest timeframe. Requires both the |
   //| moving-average stack and price position to agree, so a flat    |
   //| market yields no bias rather than a coin flip.                 |
   //+---------------------------------------------------------------+
   void              ClassifyBias(void)
     {
      m_biasDir = 0;
      int n = ArraySize(bias.rates);
      if(n < 3 || ArraySize(bias.emaB) < 3)
         return;

      double c  = bias.rates[1].close;
      double ef = bias.emaF[1];
      double es = bias.emaS[1];
      double eb = bias.emaB[1];
      int prevIdx = (int)MathMin(10, n - 1);
      double ebPrev = bias.emaB[prevIdx];

      bool slopeUp   = (eb > ebPrev);
      bool slopeDown = (eb < ebPrev);

      if(ef > es && es > eb && c > es && slopeUp)
         m_biasDir = 1;
      else if(ef < es && es < eb && c < es && slopeDown)
         m_biasDir = -1;
      else if(ef > es && c > eb && slopeUp)
         m_biasDir = 1;
      else if(ef < es && c < eb && slopeDown)
         m_biasDir = -1;
     }

   //+---------------------------------------------------------------+
   //| Volatility bucket from the ATR percentile. A 1:3 target needs  |
   //| room to run: too quiet and the target never prints, too wild   |
   //| and the stop is noise.                                         |
   //+---------------------------------------------------------------+
   void              ClassifyVolatility(void)
     {
      m_volState = APEX_VOL_NORMAL;
      m_atrPct   = 50.0;

      int n = ArraySize(ctx.atr);
      int window = (int)MathMin(APEX_VOL_WINDOW, n - 2);
      if(window < 20)
         return;

      double hist[];
      ArrayResize(hist, window);
      for(int i = 0; i < window; i++)
         hist[i] = ctx.atr[i + 1];

      m_atrPct = ApexPercentileRank(hist, window, ctx.atr[1]);

      if(m_atrPct < 15.0)      m_volState = APEX_VOL_DEAD;
      else if(m_atrPct < 35.0) m_volState = APEX_VOL_LOW;
      else if(m_atrPct < 75.0) m_volState = APEX_VOL_NORMAL;
      else if(m_atrPct < 93.0) m_volState = APEX_VOL_HIGH;
      else                     m_volState = APEX_VOL_EXTREME;
     }

   //+---------------------------------------------------------------+
   //| Regime on the context timeframe. ADX supplies persistence, the |
   //| moving averages supply direction, and everything else is chop. |
   //+---------------------------------------------------------------+
   void              ClassifyRegime(void)
     {
      m_regime = APEX_REGIME_UNKNOWN;
      int n = ArraySize(ctx.rates);
      if(n < 30 || ArraySize(ctx.adx) < 3)
         return;

      double adxv  = ctx.adx[1];
      double plus  = ctx.adxPlus[1];
      double minus = ctx.adxMinus[1];
      double ef    = ctx.emaF[1];
      double es    = ctx.emaS[1];
      double c     = ctx.rates[1].close;

      bool trending = (adxv >= m_cfg.adxTrendMin);
      bool ranging  = (adxv <= m_cfg.adxRangeMax);

      if(trending && ef > es && c > es && plus > minus)
         m_regime = APEX_REGIME_TREND_UP;
      else if(trending && ef < es && c < es && minus > plus)
         m_regime = APEX_REGIME_TREND_DOWN;
      else if(ranging)
         m_regime = APEX_REGIME_RANGE;
      else
         m_regime = APEX_REGIME_CHOP;
     }

   //+---------------------------------------------------------------+
   //| Fractal swing search on the entry feed. `strength` bars must be|
   //| lower (higher) on both sides for the pivot to count.           |
   //+---------------------------------------------------------------+
   SSwing            FindSwingLow(const int from, const int to, const int strength)
     {
      SSwing s;
      s.valid = false; s.index = -1; s.price = 0.0; s.time = 0;
      int n = ArraySize(entry.rates);
      int hi = (int)MathMin(to, n - strength - 1);
      int lo = (int)MathMax(from, strength);
      for(int i = lo; i <= hi; i++)
        {
         bool ok = true;
         for(int k = 1; k <= strength && ok; k++)
           {
            if(entry.rates[i].low > entry.rates[i - k].low) ok = false;
            if(entry.rates[i].low > entry.rates[i + k].low) ok = false;
           }
         if(ok)
           {
            s.valid = true; s.index = i; s.price = entry.rates[i].low; s.time = entry.rates[i].time;
            return s;
           }
        }
      return s;
     }

   SSwing            FindSwingHigh(const int from, const int to, const int strength)
     {
      SSwing s;
      s.valid = false; s.index = -1; s.price = 0.0; s.time = 0;
      int n = ArraySize(entry.rates);
      int hi = (int)MathMin(to, n - strength - 1);
      int lo = (int)MathMax(from, strength);
      for(int i = lo; i <= hi; i++)
        {
         bool ok = true;
         for(int k = 1; k <= strength && ok; k++)
           {
            if(entry.rates[i].high < entry.rates[i - k].high) ok = false;
            if(entry.rates[i].high < entry.rates[i + k].high) ok = false;
           }
         if(ok)
           {
            s.valid = true; s.index = i; s.price = entry.rates[i].high; s.time = entry.rates[i].time;
            return s;
           }
        }
      return s;
     }

   //--- lowest low / highest high over a window of the entry feed
   double            LowestLow(const int from, const int count)
     {
      int n = ArraySize(entry.rates);
      double v = DBL_MAX;
      int last = (int)MathMin(from + count, n);
      for(int i = from; i < last; i++)
         v = MathMin(v, entry.rates[i].low);
      return (v == DBL_MAX ? 0.0 : v);
     }

   double            HighestHigh(const int from, const int count)
     {
      int n = ArraySize(entry.rates);
      double v = -DBL_MAX;
      int last = (int)MathMin(from + count, n);
      for(int i = from; i < last; i++)
         v = MathMax(v, entry.rates[i].high);
      return (v == -DBL_MAX ? 0.0 : v);
     }

   //+---------------------------------------------------------------+
   //| Break of structure: has the most recent closed bar taken out   |
   //| the last opposing swing? Used to confirm continuation entries. |
   //+---------------------------------------------------------------+
   bool              BullishBOS(const int lookback, const int strength)
     {
      SSwing sh = FindSwingHigh(2, lookback, strength);
      if(!sh.valid)
         return false;
      for(int i = 1; i < sh.index; i++)
         if(entry.rates[i].close > sh.price)
            return true;
      return false;
     }

   bool              BearishBOS(const int lookback, const int strength)
     {
      SSwing sl = FindSwingLow(2, lookback, strength);
      if(!sl.valid)
         return false;
      for(int i = 1; i < sl.index; i++)
         if(entry.rates[i].close < sl.price)
            return true;
      return false;
     }

   //+---------------------------------------------------------------+
   //| Session range on the entry feed, for the GMT window [h1,h2) of |
   //| the most recently completed occurrence of that window.         |
   //+---------------------------------------------------------------+
   SSessionRange     SessionRange(const int gmtFrom, const int gmtTo, const int maxBarsBack)
     {
      SSessionRange r;
      r.valid = false; r.high = 0.0; r.low = 0.0; r.bars = 0;

      int n = ArraySize(entry.rates);
      int limit = (int)MathMin(maxBarsBack, n - 1);
      double hi = -DBL_MAX, lo = DBL_MAX;
      int count = 0;
      bool started = false;

      for(int i = 1; i <= limit; i++)
        {
         datetime gmt = (datetime)((long)entry.rates[i].time - (long)m_cfg.gmtOffsetHours * 3600);
         MqlDateTime dt;
         TimeToStruct(gmt, dt);
         bool inWindow = InHourWindow(dt.hour, gmtFrom, gmtTo);

         if(inWindow)
           {
            hi = MathMax(hi, entry.rates[i].high);
            lo = MathMin(lo, entry.rates[i].low);
            count++;
            started = true;
           }
         else if(started)
            break;   // walked past the start of that session block
        }

      if(count >= 2 && hi > lo)
        {
         r.valid = true;
         r.high  = hi;
         r.low   = lo;
         r.bars  = count;
        }
      return r;
     }

   //--- window that may wrap past midnight, e.g. 23 -> 06
   static bool       InHourWindow(const int hour, const int from, const int to)
     {
      if(from == to)
         return false;
      if(from < to)
         return (hour >= from && hour < to);
      return (hour >= from || hour < to);
     }
  };

#endif // APEXGOLD_MARKET_MQH
//+------------------------------------------------------------------+
