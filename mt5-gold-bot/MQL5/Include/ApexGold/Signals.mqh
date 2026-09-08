//+------------------------------------------------------------------+
//|                                                      Signals.mqh |
//|   Setup detection and confluence scoring for the ApexGold engine  |
//+------------------------------------------------------------------+
#ifndef APEXGOLD_SIGNALS_MQH
#define APEXGOLD_SIGNALS_MQH

#include "Config.mqh"
#include "Utils.mqh"
#include "Market.mqh"
#include "Filters.mqh"

#define APEX_SWING_STRENGTH   2
#define APEX_BOS_LOOKBACK    40
#define APEX_SWEEP_LOOKBACK   6
#define APEX_COMPRESS_BARS   12

//+------------------------------------------------------------------+
//| Turns market context into at most one fully specified trade idea  |
//| per closed entry bar. Every rejection is recorded so the log      |
//| explains why the EA stayed flat.                                  |
//+------------------------------------------------------------------+
class CSignalEngine
  {
private:
   SConfig           m_cfg;
   CMarket          *m_mkt;
   CSymbolCtx       *m_sym;
   CSessionFilter   *m_ses;
   CLogger          *m_log;
   string            m_lastReject;

   //--- candle helpers on the entry feed -------------------------------
   double            Body(const int i)
     {
      return MathAbs(m_mkt.entry.rates[i].close - m_mkt.entry.rates[i].open);
     }
   double            RangeOf(const int i)
     {
      return m_mkt.entry.rates[i].high - m_mkt.entry.rates[i].low;
     }
   bool              IsBull(const int i)
     {
      return m_mkt.entry.rates[i].close > m_mkt.entry.rates[i].open;
     }
   bool              IsBear(const int i)
     {
      return m_mkt.entry.rates[i].close < m_mkt.entry.rates[i].open;
     }
   double            LowerWick(const int i)
     {
      double lo = m_mkt.entry.rates[i].low;
      double body = MathMin(m_mkt.entry.rates[i].open, m_mkt.entry.rates[i].close);
      return body - lo;
     }
   double            UpperWick(const int i)
     {
      double hi = m_mkt.entry.rates[i].high;
      double body = MathMax(m_mkt.entry.rates[i].open, m_mkt.entry.rates[i].close);
      return hi - body;
     }

   //+---------------------------------------------------------------+
   //| Assemble a candidate: buffer the raw stop, enforce the distance|
   //| envelope, and project the target at the configured R multiple. |
   //+---------------------------------------------------------------+
   bool              Build(const ENUM_APEX_DIR dir, const ENUM_APEX_SETUP setup,
                           const double rawStop, const double baseScore,
                           const string reason, SSignal &out)
     {
      double atr = m_mkt.EntryAtr(1);
      if(atr <= 0.0)
        {
         m_lastReject = "ATR unavailable";
         return false;
        }

      double entryPx = (dir == APEX_DIR_LONG ? m_sym.Ask() : m_sym.Bid());
      if(entryPx <= 0.0)
        {
         m_lastReject = "no quote";
         return false;
        }

      double buffer = m_cfg.atrSlMult * atr;
      double stop   = (dir == APEX_DIR_LONG ? rawStop - buffer : rawStop + buffer);
      double risk   = MathAbs(entryPx - stop);

      double minByAtr  = m_cfg.minStopAtrMult * atr;
      double minByBrok = m_sym.MinStopDistance() * 1.5;
      double minRisk   = MathMax(minByAtr, minByBrok);
      double maxRisk   = m_cfg.maxStopAtrMult * atr;

      if(risk < minRisk)
        {
         //--- widen to the floor rather than discarding a good read
         stop = (dir == APEX_DIR_LONG ? entryPx - minRisk : entryPx + minRisk);
         risk = minRisk;
        }
      if(risk > maxRisk)
        {
         m_lastReject = StringFormat("stop too wide (%.1f > %.1f pts)",
                                     risk / m_sym.Point(), maxRisk / m_sym.Point());
         return false;
        }

      //--- the spread must be a small fraction of what we risk
      double spreadPx = m_sym.SpreadPoints() * m_sym.Point();
      if(spreadPx > m_cfg.maxSpreadVsRisk * risk)
        {
         m_lastReject = StringFormat("spread %.1f pts too large vs stop %.1f pts",
                                     spreadPx / m_sym.Point(), risk / m_sym.Point());
         return false;
        }

      double target = (dir == APEX_DIR_LONG ? entryPx + m_cfg.rewardR * risk
                                            : entryPx - m_cfg.rewardR * risk);

      out.dir        = dir;
      out.setup      = setup;
      out.entry      = m_sym.NormalizePrice(entryPx);
      out.sl         = m_sym.NormalizePrice(stop);
      out.tp         = m_sym.NormalizePrice(target);
      out.riskPoints = risk / m_sym.Point();
      out.barTime    = m_mkt.entry.rates[1].time;
      out.reason     = reason;
      out.score      = Score(out, baseScore);
      return true;
     }

   //+---------------------------------------------------------------+
   //| Confluence score. Nothing here is a hard gate on its own; the  |
   //| sum has to clear the configured threshold.                     |
   //+---------------------------------------------------------------+
   double            Score(const SSignal &s, const double baseScore)
     {
      double sc = baseScore;
      int d = (int)s.dir;

      //--- higher timeframe agreement
      if(m_mkt.BiasDir() == d)        sc += 12.0;
      else if(m_mkt.BiasDir() == 0)   sc += 2.0;
      else                            sc -= 8.0;

      //--- regime agreement
      ENUM_APEX_REGIME rg = m_mkt.Regime();
      if((d > 0 && rg == APEX_REGIME_TREND_UP) || (d < 0 && rg == APEX_REGIME_TREND_DOWN))
         sc += 8.0;
      else if(rg == APEX_REGIME_RANGE && s.setup == APEX_SETUP_SWEEP)
         sc += 8.0;
      else if(rg == APEX_REGIME_CHOP)
         sc -= 6.0;

      //--- volatility suitability for a 3R target
      switch(m_mkt.VolState())
        {
         case APEX_VOL_NORMAL:  sc += 10.0; break;
         case APEX_VOL_HIGH:    sc += 6.0;  break;
         case APEX_VOL_LOW:     sc += 2.0;  break;
         default:               sc -= 5.0;  break;
        }

      //--- session quality
      datetime now = TimeCurrent();
      if(m_ses.IsOverlap(now))       sc += 8.0;
      else if(m_ses.IsLondon(now))   sc += 5.0;
      else if(m_ses.IsNewYork(now))  sc += 4.0;

      //--- momentum on the trigger bar
      double atr = m_mkt.EntryAtr(1);
      if(atr > 0.0)
        {
         double bodyRatio = Body(1) / atr;
         if(bodyRatio > 0.9)      sc += 8.0;
         else if(bodyRatio > 0.5) sc += 4.0;
        }

      //--- ADX expanding on the context timeframe
      if(ArraySize(m_mkt.ctx.adx) > 3 && m_mkt.ctx.adx[1] > m_mkt.ctx.adx[3])
         sc += 4.0;

      //--- room to the target: is there liquidity between here and 3R?
      double tpDist = MathAbs(s.tp - s.entry);
      double swingRoom = (d > 0 ? m_mkt.HighestHigh(1, 60) - s.entry
                                : s.entry - m_mkt.LowestLow(1, 60));
      if(swingRoom >= tpDist)                       sc += 6.0;
      else if(m_mkt.BiasDir() == d)                 sc += 3.0;  // trend can make new extremes
      else                                          sc -= 4.0;

      //--- do not chase price that is already extended from value
      if(ArraySize(m_mkt.entry.emaS) > 2 && atr > 0.0)
        {
         double stretch = MathAbs(s.entry - m_mkt.entry.emaS[1]) / atr;
         if(stretch > 3.0)      sc -= 10.0;
         else if(stretch > 2.0) sc -= 4.0;
        }

      if(sc < 0.0)   sc = 0.0;
      if(sc > 100.0) sc = 100.0;
      return sc;
     }

   //+---------------------------------------------------------------+
   //| Setup A - trend pullback continuation.                         |
   //| The dominant edge on gold: enter with the higher timeframe     |
   //| after a controlled retracement into the moving-average value   |
   //| zone, once structure has already broken in that direction.     |
   //+---------------------------------------------------------------+
   bool              TryPullback(SSignal &out)
     {
      int n = ArraySize(m_mkt.entry.rates);
      if(n < APEX_BOS_LOOKBACK + 10)
         return false;

      double atr = m_mkt.EntryAtr(1);
      if(atr <= 0.0)
         return false;

      double ef = m_mkt.entry.emaF[1];
      double es = m_mkt.entry.emaS[1];
      double c  = m_mkt.entry.rates[1].close;
      double rsi = m_mkt.entry.rsi[1];

      bool ctxUp   = (m_mkt.ctx.emaF[1] > m_mkt.ctx.emaS[1] && m_mkt.ctx.rates[1].close > m_mkt.ctx.emaS[1]);
      bool ctxDown = (m_mkt.ctx.emaF[1] < m_mkt.ctx.emaS[1] && m_mkt.ctx.rates[1].close < m_mkt.ctx.emaS[1]);

      //--- LONG -------------------------------------------------------
      if(m_cfg.allowLongs && m_mkt.BiasDir() >= 0 && ctxUp && ef > es)
        {
         bool touchedValue = false;
         for(int i = 1; i <= 4 && i < n; i++)
            if(m_mkt.entry.rates[i].low <= ef + 0.25 * atr)
               touchedValue = true;

         bool trigger = IsBull(1) && c > ef && Body(1) > 0.25 * atr;
         bool momentumOk = (rsi > 40.0 && rsi < 72.0);
         bool structureOk = m_mkt.BullishBOS(APEX_BOS_LOOKBACK, APEX_SWING_STRENGTH);

         if(touchedValue && trigger && momentumOk && structureOk)
           {
            SSwing sl = m_mkt.FindSwingLow(1, 12, APEX_SWING_STRENGTH);
            double raw = (sl.valid ? sl.price : m_mkt.LowestLow(1, 6));
            raw = MathMin(raw, m_mkt.LowestLow(1, 3));
            if(raw > 0.0)
               return Build(APEX_DIR_LONG, APEX_SETUP_PULLBACK, raw, 40.0,
                            "trend pullback into value + BOS", out);
           }
         else if(!touchedValue) m_lastReject = "pullback: no retest of value zone";
         else if(!trigger)      m_lastReject = "pullback: no bullish trigger bar";
         else if(!momentumOk)   m_lastReject = "pullback: RSI out of band";
         else                   m_lastReject = "pullback: no break of structure";
        }

      //--- SHORT ------------------------------------------------------
      if(m_cfg.allowShorts && m_mkt.BiasDir() <= 0 && ctxDown && ef < es)
        {
         bool touchedValue = false;
         for(int i = 1; i <= 4 && i < n; i++)
            if(m_mkt.entry.rates[i].high >= ef - 0.25 * atr)
               touchedValue = true;

         bool trigger = IsBear(1) && c < ef && Body(1) > 0.25 * atr;
         bool momentumOk = (rsi < 60.0 && rsi > 28.0);
         bool structureOk = m_mkt.BearishBOS(APEX_BOS_LOOKBACK, APEX_SWING_STRENGTH);

         if(touchedValue && trigger && momentumOk && structureOk)
           {
            SSwing sh = m_mkt.FindSwingHigh(1, 12, APEX_SWING_STRENGTH);
            double raw = (sh.valid ? sh.price : m_mkt.HighestHigh(1, 6));
            raw = MathMax(raw, m_mkt.HighestHigh(1, 3));
            if(raw > 0.0)
               return Build(APEX_DIR_SHORT, APEX_SETUP_PULLBACK, raw, 40.0,
                            "trend pullback into value + BOS", out);
           }
        }

      return false;
     }

   //+---------------------------------------------------------------+
   //| Setup B - session liquidity sweep.                             |
   //| Price takes out the Asian range extreme during London, fails,  |
   //| and closes back inside. The stop sits just beyond the sweep,   |
   //| which is what makes a 3R target reachable from a tight risk.   |
   //+---------------------------------------------------------------+
   bool              TrySweep(SSignal &out)
     {
      datetime now = TimeCurrent();
      if(!(m_ses.IsLondon(now) || m_ses.IsNewYork(now)))
        {
         m_lastReject = "sweep: outside London/NY";
         return false;
        }

      SSessionRange asia = m_mkt.SessionRange(m_cfg.asiaStartGmt, m_cfg.asiaEndGmt, 200);
      if(!asia.valid)
        {
         m_lastReject = "sweep: no Asian range";
         return false;
        }

      double atr = m_mkt.EntryAtr(1);
      double atrCtx = m_mkt.CtxAtr(1);
      if(atr <= 0.0 || atrCtx <= 0.0)
         return false;

      double width = asia.high - asia.low;
      if(width < 0.25 * atrCtx || width > 3.0 * atrCtx)
        {
         m_lastReject = "sweep: Asian range width out of band";
         return false;
        }

      double minSweep = 0.10 * atr;
      double maxSweep = 1.20 * atr;

      //--- bullish sweep of the range low
      if(m_cfg.allowLongs)
        {
         double deepest = DBL_MAX;
         bool swept = false;
         for(int i = 1; i <= APEX_SWEEP_LOOKBACK; i++)
           {
            double lo = m_mkt.entry.rates[i].low;
            if(lo < asia.low - minSweep)
              {
               swept = true;
               deepest = MathMin(deepest, lo);
              }
           }
         double depth = (swept ? asia.low - deepest : 0.0);
         bool reclaimed = (m_mkt.entry.rates[1].close > asia.low);
         bool rejection = IsBull(1) || LowerWick(1) > 0.5 * RangeOf(1);

         if(swept && depth <= maxSweep && reclaimed && rejection)
            return Build(APEX_DIR_LONG, APEX_SETUP_SWEEP, deepest, 40.0,
                         "Asian low swept and reclaimed", out);
        }

      //--- bearish sweep of the range high
      if(m_cfg.allowShorts)
        {
         double highest = -DBL_MAX;
         bool swept = false;
         for(int i = 1; i <= APEX_SWEEP_LOOKBACK; i++)
           {
            double hi = m_mkt.entry.rates[i].high;
            if(hi > asia.high + minSweep)
              {
               swept = true;
               highest = MathMax(highest, hi);
              }
           }
         double depth = (swept ? highest - asia.high : 0.0);
         bool reclaimed = (m_mkt.entry.rates[1].close < asia.high);
         bool rejection = IsBear(1) || UpperWick(1) > 0.5 * RangeOf(1);

         if(swept && depth <= maxSweep && reclaimed && rejection)
            return Build(APEX_DIR_SHORT, APEX_SETUP_SWEEP, highest, 40.0,
                         "Asian high swept and reclaimed", out);
        }

      m_lastReject = "sweep: no qualifying sweep";
      return false;
     }

   //+---------------------------------------------------------------+
   //| Setup C - volatility compression breakout.                     |
   //| Gold spends long stretches coiling before an expansion. A      |
   //| decisive close out of a tight range gives a small stop and a   |
   //| target that the expansion itself tends to reach.               |
   //+---------------------------------------------------------------+
   bool              TryBreakout(SSignal &out)
     {
      int n = ArraySize(m_mkt.entry.rates);
      if(n < APEX_COMPRESS_BARS + 30)
         return false;

      double atr = m_mkt.EntryAtr(1);
      if(atr <= 0.0)
         return false;

      //--- measure the range formed before the trigger bar
      double hi = -DBL_MAX, lo = DBL_MAX;
      for(int i = 2; i <= APEX_COMPRESS_BARS + 1; i++)
        {
         hi = MathMax(hi, m_mkt.entry.rates[i].high);
         lo = MathMin(lo, m_mkt.entry.rates[i].low);
        }
      double width = hi - lo;
      if(width <= 0.0)
         return false;

      //--- compression test: the whole range is worth only a couple of ATRs
      if(width > 2.2 * atr)
        {
         m_lastReject = "breakout: range not compressed";
         return false;
        }

      double c = m_mkt.entry.rates[1].close;
      bool strongBody = Body(1) > 0.55 * atr;

      if(m_cfg.allowLongs && c > hi && strongBody && IsBull(1) && m_mkt.BiasDir() >= 0)
         return Build(APEX_DIR_LONG, APEX_SETUP_BREAKOUT, lo, 38.0,
                      "expansion out of compression (up)", out);

      if(m_cfg.allowShorts && c < lo && strongBody && IsBear(1) && m_mkt.BiasDir() <= 0)
         return Build(APEX_DIR_SHORT, APEX_SETUP_BREAKOUT, hi, 38.0,
                      "expansion out of compression (down)", out);

      m_lastReject = "breakout: no expansion close";
      return false;
     }

public:
                     CSignalEngine(void) { m_mkt = NULL; m_sym = NULL; m_ses = NULL; m_log = NULL; m_lastReject = ""; }

   void              Init(const SConfig &cfg, CMarket *mkt, CSymbolCtx *sym,
                          CSessionFilter *ses, CLogger *logger)
     {
      m_cfg = cfg;
      m_mkt = mkt;
      m_sym = sym;
      m_ses = ses;
      m_log = logger;
     }

   string            LastReject(void) const { return m_lastReject; }

   //+---------------------------------------------------------------+
   //| Evaluate the closed entry bar. Returns the single best idea    |
   //| that clears the score threshold.                               |
   //+---------------------------------------------------------------+
   bool              Evaluate(SSignal &out)
     {
      m_lastReject = "";

      if(m_mkt.VolState() == APEX_VOL_DEAD)
        {
         m_lastReject = StringFormat("volatility too low (ATR pct %.0f)", m_mkt.AtrPercentile());
         return false;
        }
      if(m_mkt.VolState() == APEX_VOL_EXTREME)
        {
         m_lastReject = StringFormat("volatility extreme (ATR pct %.0f)", m_mkt.AtrPercentile());
         return false;
        }

      SSignal best;
      best.dir        = APEX_DIR_NONE;
      best.setup      = APEX_SETUP_NONE;
      best.entry      = 0.0;
      best.sl         = 0.0;
      best.tp         = 0.0;
      best.riskPoints = 0.0;
      best.score      = -1.0;
      best.reason     = "";
      best.barTime    = 0;
      SSignal cand = best;

      bool wantPullback = (m_cfg.stratSet == APEX_STRAT_ALL || m_cfg.stratSet == APEX_STRAT_PULLBACK);
      bool wantSweep    = (m_cfg.stratSet == APEX_STRAT_ALL || m_cfg.stratSet == APEX_STRAT_SWEEP);
      bool wantBreakout = (m_cfg.stratSet == APEX_STRAT_ALL || m_cfg.stratSet == APEX_STRAT_BREAKOUT);

      //--- the regime decides which family is even worth testing
      ENUM_APEX_REGIME rg = m_mkt.Regime();
      if(m_cfg.stratSet == APEX_STRAT_ALL)
        {
         if(rg == APEX_REGIME_CHOP)
           {
            m_lastReject = "regime is chop";
            return false;
           }
         if(rg == APEX_REGIME_RANGE)
            wantPullback = false;                       // no trend to continue
        }

      if(wantPullback && TryPullback(cand) && cand.score > best.score) best = cand;
      if(wantSweep    && TrySweep(cand)    && cand.score > best.score) best = cand;
      if(wantBreakout && TryBreakout(cand) && cand.score > best.score) best = cand;

      if(best.dir == APEX_DIR_NONE)
         return false;

      if(best.score < m_cfg.minScore)
        {
         m_lastReject = StringFormat("%s scored %.0f < %.0f",
                                     ApexSetupToString(best.setup), best.score, m_cfg.minScore);
         return false;
        }

      out = best;
      return true;
     }
  };

#endif // APEXGOLD_SIGNALS_MQH
//+------------------------------------------------------------------+
