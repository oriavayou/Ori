//+------------------------------------------------------------------+
//|                                                       Config.mqh |
//|                      ApexGold - shared enums and configuration    |
//+------------------------------------------------------------------+
#ifndef APEXGOLD_CONFIG_MQH
#define APEXGOLD_CONFIG_MQH

#define APEX_VERSION "1.0.0"

//--- log verbosity
enum ENUM_APEX_LOGLEVEL
  {
   APEX_LOG_ERROR = 0,   // Errors only
   APEX_LOG_WARN  = 1,   // Errors + warnings
   APEX_LOG_INFO  = 2,   // Normal
   APEX_LOG_DEBUG = 3    // Verbose (research only)
  };

//--- how the lot size is derived
enum ENUM_APEX_RISKMODE
  {
   APEX_RISK_PERCENT_BALANCE = 0, // Percent of balance
   APEX_RISK_PERCENT_EQUITY  = 1, // Percent of equity
   APEX_RISK_FIXED_MONEY     = 2, // Fixed money amount
   APEX_RISK_FIXED_LOT       = 3  // Fixed lot (testing only)
  };

//--- market regime as classified on the context timeframe
enum ENUM_APEX_REGIME
  {
   APEX_REGIME_UNKNOWN = 0,
   APEX_REGIME_TREND_UP = 1,
   APEX_REGIME_TREND_DOWN = 2,
   APEX_REGIME_RANGE = 3,
   APEX_REGIME_CHOP = 4      // unusable: no directional persistence
  };

//--- volatility bucket derived from the ATR percentile
enum ENUM_APEX_VOLSTATE
  {
   APEX_VOL_DEAD = 0,   // too quiet, 3R is unlikely to be reached
   APEX_VOL_LOW = 1,
   APEX_VOL_NORMAL = 2,
   APEX_VOL_HIGH = 3,
   APEX_VOL_EXTREME = 4 // news-like expansion, stand aside
  };

//--- which setup families are allowed
enum ENUM_APEX_STRATSET
  {
   APEX_STRAT_ALL = 0,          // Adaptive: regime picks the setup
   APEX_STRAT_PULLBACK = 1,     // Trend pullback continuation only
   APEX_STRAT_SWEEP = 2,        // Session liquidity sweep only
   APEX_STRAT_BREAKOUT = 3      // Compression breakout only
  };

//--- setup family that produced a signal
enum ENUM_APEX_SETUP
  {
   APEX_SETUP_NONE = 0,
   APEX_SETUP_PULLBACK = 1,
   APEX_SETUP_SWEEP = 2,
   APEX_SETUP_BREAKOUT = 3
  };

//--- direction
enum ENUM_APEX_DIR
  {
   APEX_DIR_NONE = 0,
   APEX_DIR_LONG = 1,
   APEX_DIR_SHORT = -1
  };

//+------------------------------------------------------------------+
//| A fully specified trade candidate produced by the signal engine.  |
//| Prices are raw here; the executor normalises them to the symbol.  |
//+------------------------------------------------------------------+
struct SSignal
  {
   ENUM_APEX_DIR     dir;
   ENUM_APEX_SETUP   setup;
   double            entry;       // reference entry price (market)
   double            sl;          // protective stop
   double            tp;          // target at the configured R multiple
   double            riskPoints;  // |entry-sl| in points
   double            score;       // confluence score, 0..100
   string            reason;      // human readable audit trail
   datetime          barTime;     // signal bar open time
  };

//+------------------------------------------------------------------+
//| Runtime configuration. Filled once from the EA inputs in OnInit.  |
//| Kept as a plain struct so every module reads the same values.     |
//+------------------------------------------------------------------+
struct SConfig
  {
   //--- identity
   long              magic;
   string            comment;
   ENUM_APEX_LOGLEVEL logLevel;
   bool              logToFile;

   //--- timeframes
   ENUM_TIMEFRAMES   tfBias;      // highest: directional bias
   ENUM_TIMEFRAMES   tfContext;   // regime + structure
   ENUM_TIMEFRAMES   tfEntry;     // trigger timeframe

   //--- risk
   ENUM_APEX_RISKMODE riskMode;
   double            riskValue;        // percent or money or lots
   double            rewardR;          // target R multiple (3.0)
   double            maxLot;
   double            maxRiskPerTradePct;// hard ceiling regardless of mode

   //--- capital protection
   double            dailyLossLimitPct;
   double            weeklyLossLimitPct;
   double            maxDrawdownPct;
   double            profitLockPct;     // stop trading after +X% on the day
   int               maxTradesPerDay;
   int               maxConsecutiveLosses;
   int               cooldownMinutes;
   int               maxOpenPositions;

   //--- execution guards
   int               maxSpreadPoints;
   double            maxSpreadVsRisk;   // spread must be <= this fraction of SL distance
   int               slippagePoints;
   int               maxRetries;
   int               retryDelayMs;

   //--- stop construction
   double            atrSlMult;         // buffer beyond structure, in ATR
   double            minStopAtrMult;    // floor on SL distance
   double            maxStopAtrMult;    // ceiling on SL distance
   int               structureLookback; // bars scanned for swings

   //--- filters
   double            adxTrendMin;
   double            adxRangeMax;
   double            volPctLow;         // ATR percentile below which we stand aside
   double            volPctHigh;        // ATR percentile above which we stand aside
   double            minScore;          // confluence threshold

   //--- sessions (broker-server hours, converted from GMT by the EA)
   int               gmtOffsetHours;
   bool              useSessionFilter;
   int               asiaStartGmt;
   int               asiaEndGmt;
   int               londonStartGmt;
   int               londonEndGmt;
   int               nyStartGmt;
   int               nyEndGmt;
   bool              tradeMonday;
   bool              tradeTuesday;
   bool              tradeWednesday;
   bool              tradeThursday;
   bool              tradeFriday;
   int               fridayCloseHourGmt;

   //--- news
   bool              useNewsFilter;
   int               newsMinutesBefore;
   int               newsMinutesAfter;
   bool              newsHighOnly;

   //--- position management
   double            breakEvenAtR;      // 0 = disabled
   double            breakEvenOffsetR;
   double            partialAtR;        // 0 = disabled
   double            partialPercent;
   double            trailStartR;       // 0 = disabled
   double            trailAtrMult;
   int               timeStopBars;      // 0 = disabled
   double            timeStopMinR;

   //--- strategy selection
   ENUM_APEX_STRATSET stratSet;
   bool              allowLongs;
   bool              allowShorts;
  };

#endif // APEXGOLD_CONFIG_MQH
//+------------------------------------------------------------------+
