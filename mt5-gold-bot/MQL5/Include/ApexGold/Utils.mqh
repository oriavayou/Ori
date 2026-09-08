//+------------------------------------------------------------------+
//|                                                        Utils.mqh |
//|            Logging + broker/symbol normalisation for ApexGold     |
//+------------------------------------------------------------------+
#ifndef APEXGOLD_UTILS_MQH
#define APEXGOLD_UTILS_MQH

#include "Config.mqh"

//+------------------------------------------------------------------+
//| Logger. Writes to the Experts tab and, optionally, to a CSV file  |
//| under MQL5/Files so a live run can be audited after the fact.     |
//+------------------------------------------------------------------+
class CLogger
  {
private:
   ENUM_APEX_LOGLEVEL m_level;
   bool              m_toFile;
   int               m_handle;
   string            m_tag;

   void              Emit(const string sev, const string msg)
     {
      string line = TimeToString(TimeCurrent(), TIME_DATE|TIME_SECONDS) + " | " + sev + " | " + m_tag + " | " + msg;
      Print(line);
      if(m_toFile && m_handle != INVALID_HANDLE)
        {
         FileWrite(m_handle, TimeToString(TimeCurrent(), TIME_DATE|TIME_SECONDS), sev, m_tag, msg);
         FileFlush(m_handle);
        }
     }

public:
                     CLogger(void) { m_level = APEX_LOG_INFO; m_toFile = false; m_handle = INVALID_HANDLE; m_tag = "APEX"; }
                    ~CLogger(void) { Close(); }

   void              Init(const string tag, const ENUM_APEX_LOGLEVEL level, const bool toFile)
     {
      m_tag = tag;
      m_level = level;
      m_toFile = toFile;
      if(m_toFile)
        {
         string fname = StringFormat("ApexGold_%s_%s.csv", tag, TimeToString(TimeCurrent(), TIME_DATE));
         StringReplace(fname, ".", "-");
         StringReplace(fname, "-csv", ".csv");
         m_handle = FileOpen(fname, FILE_WRITE|FILE_CSV|FILE_ANSI, ',');
         if(m_handle == INVALID_HANDLE)
            m_toFile = false;
         else
            FileWrite(m_handle, "time", "severity", "tag", "message");
        }
     }

   void              Close(void)
     {
      if(m_handle != INVALID_HANDLE)
        {
         FileClose(m_handle);
         m_handle = INVALID_HANDLE;
        }
     }

   void              Error(const string msg) { Emit("ERROR", msg); }
   void              Warn(const string msg)  { if(m_level >= APEX_LOG_WARN)  Emit("WARN", msg); }
   void              Info(const string msg)  { if(m_level >= APEX_LOG_INFO)  Emit("INFO", msg); }
   void              Debug(const string msg) { if(m_level >= APEX_LOG_DEBUG) Emit("DEBUG", msg); }
  };

//+------------------------------------------------------------------+
//| Everything that differs between brokers lives here: the symbol    |
//| suffix, digits, tick size, stop distance rules, volume steps and  |
//| the supported order filling mode.                                 |
//+------------------------------------------------------------------+
class CSymbolCtx
  {
private:
   string            m_symbol;
   int               m_digits;
   double            m_point;
   double            m_tickSize;
   double            m_tickValue;
   double            m_contractSize;
   double            m_volMin;
   double            m_volMax;
   double            m_volStep;
   int               m_stopsLevel;
   int               m_freezeLevel;
   bool              m_ready;

public:
                     CSymbolCtx(void) { m_ready = false; m_symbol = ""; m_digits = 0; m_point = 0.0;
                                        m_tickSize = 0.0; m_tickValue = 0.0; m_contractSize = 0.0;
                                        m_volMin = 0.0; m_volMax = 0.0; m_volStep = 0.0;
                                        m_stopsLevel = 0; m_freezeLevel = 0; }

   //--- Resolve a symbol name against the Market Watch, tolerating broker
   //--- suffixes/prefixes such as XAUUSD.m, XAUUSDpro, #XAUUSD.
   static string     Resolve(const string wanted)
     {
      if(SymbolSelect(wanted, true) && SymbolInfoDouble(wanted, SYMBOL_POINT) > 0.0)
         return wanted;

      string core = wanted;
      StringToUpper(core);
      int total = SymbolsTotal(false);
      string bestExact = "";
      string bestLoose = "";
      for(int i = 0; i < total; i++)
        {
         string name = SymbolName(i, false);
         string up = name;
         StringToUpper(up);
         if(up == core)
            return name;
         if(StringFind(up, core) >= 0)
           {
            if(bestExact == "" && StringLen(up) <= StringLen(core) + 4)
               bestExact = name;
            if(bestLoose == "")
               bestLoose = name;
           }
        }
      if(bestExact != "") return bestExact;
      if(bestLoose != "") return bestLoose;
      return wanted;
     }

   bool              Init(const string symbol)
     {
      m_symbol = symbol;
      if(!SymbolSelect(m_symbol, true))
         return false;

      m_digits       = (int)SymbolInfoInteger(m_symbol, SYMBOL_DIGITS);
      m_point        = SymbolInfoDouble(m_symbol, SYMBOL_POINT);
      m_tickSize     = SymbolInfoDouble(m_symbol, SYMBOL_TRADE_TICK_SIZE);
      m_tickValue    = SymbolInfoDouble(m_symbol, SYMBOL_TRADE_TICK_VALUE);
      m_contractSize = SymbolInfoDouble(m_symbol, SYMBOL_TRADE_CONTRACT_SIZE);
      m_volMin       = SymbolInfoDouble(m_symbol, SYMBOL_VOLUME_MIN);
      m_volMax       = SymbolInfoDouble(m_symbol, SYMBOL_VOLUME_MAX);
      m_volStep      = SymbolInfoDouble(m_symbol, SYMBOL_VOLUME_STEP);
      m_stopsLevel   = (int)SymbolInfoInteger(m_symbol, SYMBOL_TRADE_STOPS_LEVEL);
      m_freezeLevel  = (int)SymbolInfoInteger(m_symbol, SYMBOL_TRADE_FREEZE_LEVEL);

      if(m_tickSize <= 0.0) m_tickSize = m_point;
      if(m_volStep <= 0.0)  m_volStep = 0.01;
      m_ready = (m_point > 0.0 && m_tickValue > 0.0 && m_volMin > 0.0);
      return m_ready;
     }

   bool              IsReady(void) const { return m_ready; }
   string            Name(void)    const { return m_symbol; }
   int               Digits(void)  const { return m_digits; }
   double            Point(void)   const { return m_point; }
   double            TickSize(void)const { return m_tickSize; }
   double            VolMin(void)  const { return m_volMin; }
   double            VolStep(void) const { return m_volStep; }

   double            Bid(void) const { return SymbolInfoDouble(m_symbol, SYMBOL_BID); }
   double            Ask(void) const { return SymbolInfoDouble(m_symbol, SYMBOL_ASK); }

   //--- current spread expressed in points
   int               SpreadPoints(void) const
     {
      double bid = Bid(), ask = Ask();
      if(bid <= 0.0 || ask <= 0.0 || m_point <= 0.0)
         return (int)SymbolInfoInteger(m_symbol, SYMBOL_SPREAD);
      return (int)MathRound((ask - bid) / m_point);
     }

   //--- minimum distance any stop must keep from the market, in price units.
   //--- A broker reporting zero still enforces a floor at execution time, so
   //--- we add a small safety pad of two spreads.
   double            MinStopDistance(void) const
     {
      double byLevel = m_stopsLevel * m_point;
      double pad     = 2.0 * SpreadPoints() * m_point;
      double floorPx = 10.0 * m_point;
      return MathMax(MathMax(byLevel, pad), floorPx);
     }

   double            FreezeDistance(void) const { return m_freezeLevel * m_point; }

   double            NormalizePrice(const double price) const
     {
      if(m_tickSize <= 0.0)
         return NormalizeDouble(price, m_digits);
      return NormalizeDouble(MathRound(price / m_tickSize) * m_tickSize, m_digits);
     }

   double            NormalizeVolume(const double volume) const
     {
      double v = volume;
      if(m_volStep > 0.0)
         v = MathFloor(v / m_volStep + 1e-8) * m_volStep;
      v = MathMax(v, m_volMin);
      v = MathMin(v, m_volMax);
      int volDigits = 0;
      double step = m_volStep;
      while(step < 1.0 && volDigits < 8)
        {
         step *= 10.0;
         volDigits++;
        }
      return NormalizeDouble(v, volDigits);
     }

   //--- money risked by `lots` if price travels `distance` (price units).
   //--- Uses tick value so it is correct for metals, indices and FX alike.
   double            MoneyForDistance(const double lots, const double distance) const
     {
      if(m_tickSize <= 0.0 || m_tickValue <= 0.0)
         return 0.0;
      return (distance / m_tickSize) * m_tickValue * lots;
     }

   double            LotsForRisk(const double riskMoney, const double distance) const
     {
      if(distance <= 0.0)
         return 0.0;
      double perLot = MoneyForDistance(1.0, distance);
      if(perLot <= 0.0)
         return 0.0;
      return riskMoney / perLot;
     }

   //--- pick a filling mode the broker actually accepts
   ENUM_ORDER_TYPE_FILLING FillingMode(void) const
     {
      int modes = (int)SymbolInfoInteger(m_symbol, SYMBOL_FILLING_MODE);
      if((modes & SYMBOL_FILLING_FOK) != 0)
         return ORDER_FILLING_FOK;
      if((modes & SYMBOL_FILLING_IOC) != 0)
         return ORDER_FILLING_IOC;
      return ORDER_FILLING_RETURN;
     }

   bool              IsTradeAllowed(void) const
     {
      ENUM_SYMBOL_TRADE_MODE mode = (ENUM_SYMBOL_TRADE_MODE)SymbolInfoInteger(m_symbol, SYMBOL_TRADE_MODE);
      return (mode == SYMBOL_TRADE_MODE_FULL || mode == SYMBOL_TRADE_MODE_LONGONLY || mode == SYMBOL_TRADE_MODE_SHORTONLY);
     }
  };

//+------------------------------------------------------------------+
//| Small helpers                                                     |
//+------------------------------------------------------------------+
string ApexDirToString(const ENUM_APEX_DIR dir)
  {
   if(dir == APEX_DIR_LONG)  return "LONG";
   if(dir == APEX_DIR_SHORT) return "SHORT";
   return "NONE";
  }

string ApexSetupToString(const ENUM_APEX_SETUP s)
  {
   switch(s)
     {
      case APEX_SETUP_PULLBACK: return "PULLBACK";
      case APEX_SETUP_SWEEP:    return "SWEEP";
      case APEX_SETUP_BREAKOUT: return "BREAKOUT";
      default:                  return "NONE";
     }
  }

string ApexRegimeToString(const ENUM_APEX_REGIME r)
  {
   switch(r)
     {
      case APEX_REGIME_TREND_UP:   return "TREND_UP";
      case APEX_REGIME_TREND_DOWN: return "TREND_DOWN";
      case APEX_REGIME_RANGE:      return "RANGE";
      case APEX_REGIME_CHOP:       return "CHOP";
      default:                     return "UNKNOWN";
     }
  }

//--- percentile of `value` inside `series` (0..100)
double ApexPercentileRank(const double &series[], const int count, const double value)
  {
   if(count <= 0)
      return 50.0;
   int below = 0;
   for(int i = 0; i < count; i++)
      if(series[i] < value)
         below++;
   return 100.0 * (double)below / (double)count;
  }

#endif // APEXGOLD_UTILS_MQH
//+------------------------------------------------------------------+
