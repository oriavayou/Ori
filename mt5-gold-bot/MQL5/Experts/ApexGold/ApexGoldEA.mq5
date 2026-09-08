//+------------------------------------------------------------------+
//|                                                    ApexGoldEA.mq5|
//|            Adaptive multi-setup 1:3 expert advisor for MetaTrader 5|
//|                                                                   |
//| Designed for XAUUSD but symbol-agnostic: every distance is scaled |
//| by ATR and every broker constraint is read from the symbol, so    |
//| the same code runs on EURUSD, GBPJPY or an index CFD.             |
//+------------------------------------------------------------------+
#property copyright "ApexGold"
#property link      ""
#property version   "1.00"
#property description "Adaptive trend-pullback / liquidity-sweep / compression-breakout engine with a fixed R multiple target and a hard capital-protection layer."

#include <ApexGold/Config.mqh>
#include <ApexGold/Utils.mqh>
#include <ApexGold/Market.mqh>
#include <ApexGold/Filters.mqh>
#include <ApexGold/Signals.mqh>
#include <ApexGold/Risk.mqh>
#include <ApexGold/Execution.mqh>

//+------------------------------------------------------------------+
//| Inputs                                                            |
//+------------------------------------------------------------------+
input group "=== Instrument and identity ==="
input string            InpSymbol             = "";        // Symbol ("" = chart symbol, suffixes auto-resolved)
input long              InpMagic              = 730115;    // Magic number
input string            InpComment            = "ApexGold";// Order comment
input ENUM_APEX_LOGLEVEL InpLogLevel          = APEX_LOG_INFO; // Log level
input bool              InpLogToFile          = false;     // Also write a CSV log
input bool              InpShowPanel          = true;      // Show status panel on chart

input group "=== Timeframes ==="
input ENUM_TIMEFRAMES   InpTfBias             = PERIOD_H4; // Bias timeframe
input ENUM_TIMEFRAMES   InpTfContext          = PERIOD_H1; // Context / regime timeframe
input ENUM_TIMEFRAMES   InpTfEntry            = PERIOD_M15;// Entry timeframe

input group "=== Risk per trade ==="
input ENUM_APEX_RISKMODE InpRiskMode          = APEX_RISK_PERCENT_BALANCE; // Sizing mode
input double            InpRiskValue          = 0.5;       // Risk value (percent, money, or lots)
input double            InpRewardR            = 3.0;       // Target as a multiple of risk
input double            InpMaxRiskPerTradePct = 1.0;       // Hard ceiling, percent of balance
input double            InpMaxLot             = 5.0;       // Maximum lots (0 = no cap)

input group "=== Capital protection ==="
input double            InpDailyLossLimitPct  = 3.0;       // Stop for the day after this loss, percent (0 = off)
input double            InpWeeklyLossLimitPct = 6.0;       // Stop for the week after this loss, percent (0 = off)
input double            InpMaxDrawdownPct     = 12.0;      // Halt after this drawdown from equity peak (0 = off)
input double            InpProfitLockPct      = 0.0;       // Stop for the day after this gain, percent (0 = off)
input int               InpMaxTradesPerDay    = 4;         // Maximum entries per day (0 = unlimited)
input int               InpMaxConsecLosses    = 3;         // Losing streak that triggers a cooldown (0 = off)
input int               InpCooldownMinutes    = 240;       // Cooldown length in minutes
input int               InpMaxOpenPositions   = 1;         // Concurrent positions on this symbol

input group "=== Execution guards ==="
input int               InpMaxSpreadPoints    = 350;       // Reject entries above this spread, in points
input double            InpMaxSpreadVsRisk    = 0.10;      // Spread must be under this fraction of the stop
input int               InpSlippagePoints     = 30;        // Maximum deviation
input int               InpMaxRetries         = 3;         // Retries on requote / off-quotes
input int               InpRetryDelayMs       = 300;       // Delay between retries

input group "=== Stop construction ==="
input double            InpAtrSlMult          = 0.35;      // Buffer beyond structure, in ATR
input double            InpMinStopAtrMult     = 0.60;      // Minimum stop distance, in ATR
input double            InpMaxStopAtrMult     = 2.50;      // Maximum stop distance, in ATR

input group "=== Filters ==="
input ENUM_APEX_STRATSET InpStrategySet       = APEX_STRAT_ALL; // Which setup families to run
input bool              InpAllowLongs         = true;      // Allow long trades
input bool              InpAllowShorts        = true;      // Allow short trades
input double            InpAdxTrendMin        = 22.0;      // ADX above this means trending
input double            InpAdxRangeMax        = 18.0;      // ADX below this means ranging
input double            InpMinScore           = 62.0;      // Confluence score needed to trade

input group "=== Sessions (GMT hours) ==="
input int               InpGmtOffsetHours     = 2;         // Broker server time minus GMT
input bool              InpUseSessionFilter   = true;      // Only trade London / New York
input int               InpAsiaStartGmt       = 0;         // Asian range start
input int               InpAsiaEndGmt         = 7;         // Asian range end
input int               InpLondonStartGmt     = 7;         // London start
input int               InpLondonEndGmt       = 16;        // London end
input int               InpNyStartGmt         = 12;        // New York start
input int               InpNyEndGmt           = 20;        // New York end
input bool              InpTradeMonday        = true;      // Trade Monday
input bool              InpTradeTuesday       = true;      // Trade Tuesday
input bool              InpTradeWednesday     = true;      // Trade Wednesday
input bool              InpTradeThursday      = true;      // Trade Thursday
input bool              InpTradeFriday        = true;      // Trade Friday
input int               InpFridayCloseHourGmt = 19;        // Flatten and stop at this hour on Friday

input group "=== News filter ==="
input bool              InpUseNewsFilter      = true;      // Use the terminal economic calendar
input bool              InpNewsHighOnly       = true;      // Only high-importance events
input int               InpNewsMinutesBefore  = 20;        // Blackout before an event
input int               InpNewsMinutesAfter   = 20;        // Blackout after an event

input group "=== Position management ==="
input double            InpBreakEvenAtR       = 0.0;       // Move stop to break-even at this R (0 = off)
input double            InpBreakEvenOffsetR   = 0.05;      // Offset past entry when moving to break-even
input double            InpPartialAtR         = 0.0;       // Take a partial at this R (0 = off)
input double            InpPartialPercent     = 50.0;      // Percent closed at the partial
input double            InpTrailStartR        = 0.0;       // Start ATR trailing at this R (0 = off)
input double            InpTrailAtrMult       = 1.5;       // Trailing distance, in ATR
input int               InpTimeStopBars       = 0;         // Close a stalled trade after N bars (0 = off)
input double            InpTimeStopMinR       = 0.5;       // Only if it has not reached this R

//+------------------------------------------------------------------+
//| Globals                                                           |
//+------------------------------------------------------------------+
SConfig          g_cfg;
CLogger          g_log;
CSymbolCtx       g_sym;
CMarket          g_mkt;
CSessionFilter   g_ses;
CNewsFilter      g_news;
CSignalEngine    g_signals;
CRiskManager     g_risk;
CExecutor        g_exec;
CPositionManager g_pos;

datetime         g_lastBarTime = 0;
datetime         g_lastSignalBar = 0;
string           g_status = "starting";
bool             g_ready = false;

//+------------------------------------------------------------------+
//| Copy inputs into the shared configuration struct                  |
//+------------------------------------------------------------------+
void BuildConfig()
  {
   g_cfg.magic    = InpMagic;
   g_cfg.comment  = InpComment;
   g_cfg.logLevel = InpLogLevel;
   g_cfg.logToFile= InpLogToFile;

   g_cfg.tfBias    = InpTfBias;
   g_cfg.tfContext = InpTfContext;
   g_cfg.tfEntry   = (InpTfEntry == PERIOD_CURRENT ? (ENUM_TIMEFRAMES)Period() : InpTfEntry);

   g_cfg.riskMode  = InpRiskMode;
   g_cfg.riskValue = InpRiskValue;
   g_cfg.rewardR   = InpRewardR;
   g_cfg.maxLot    = InpMaxLot;
   g_cfg.maxRiskPerTradePct = InpMaxRiskPerTradePct;

   g_cfg.dailyLossLimitPct  = InpDailyLossLimitPct;
   g_cfg.weeklyLossLimitPct = InpWeeklyLossLimitPct;
   g_cfg.maxDrawdownPct     = InpMaxDrawdownPct;
   g_cfg.profitLockPct      = InpProfitLockPct;
   g_cfg.maxTradesPerDay    = InpMaxTradesPerDay;
   g_cfg.maxConsecutiveLosses = InpMaxConsecLosses;
   g_cfg.cooldownMinutes    = InpCooldownMinutes;
   g_cfg.maxOpenPositions   = InpMaxOpenPositions;

   g_cfg.maxSpreadPoints = InpMaxSpreadPoints;
   g_cfg.maxSpreadVsRisk = InpMaxSpreadVsRisk;
   g_cfg.slippagePoints  = InpSlippagePoints;
   g_cfg.maxRetries      = InpMaxRetries;
   g_cfg.retryDelayMs    = InpRetryDelayMs;

   g_cfg.atrSlMult      = InpAtrSlMult;
   g_cfg.minStopAtrMult = InpMinStopAtrMult;
   g_cfg.maxStopAtrMult = InpMaxStopAtrMult;
   g_cfg.structureLookback = APEX_BOS_LOOKBACK;

   g_cfg.adxTrendMin = InpAdxTrendMin;
   g_cfg.adxRangeMax = InpAdxRangeMax;
   g_cfg.volPctLow   = 15.0;
   g_cfg.volPctHigh  = 93.0;
   g_cfg.minScore    = InpMinScore;

   g_cfg.gmtOffsetHours   = InpGmtOffsetHours;
   g_cfg.useSessionFilter = InpUseSessionFilter;
   g_cfg.asiaStartGmt     = InpAsiaStartGmt;
   g_cfg.asiaEndGmt       = InpAsiaEndGmt;
   g_cfg.londonStartGmt   = InpLondonStartGmt;
   g_cfg.londonEndGmt     = InpLondonEndGmt;
   g_cfg.nyStartGmt       = InpNyStartGmt;
   g_cfg.nyEndGmt         = InpNyEndGmt;
   g_cfg.tradeMonday      = InpTradeMonday;
   g_cfg.tradeTuesday     = InpTradeTuesday;
   g_cfg.tradeWednesday   = InpTradeWednesday;
   g_cfg.tradeThursday    = InpTradeThursday;
   g_cfg.tradeFriday      = InpTradeFriday;
   g_cfg.fridayCloseHourGmt = InpFridayCloseHourGmt;

   g_cfg.useNewsFilter     = InpUseNewsFilter;
   g_cfg.newsMinutesBefore = InpNewsMinutesBefore;
   g_cfg.newsMinutesAfter  = InpNewsMinutesAfter;
   g_cfg.newsHighOnly      = InpNewsHighOnly;

   g_cfg.breakEvenAtR     = InpBreakEvenAtR;
   g_cfg.breakEvenOffsetR = InpBreakEvenOffsetR;
   g_cfg.partialAtR       = InpPartialAtR;
   g_cfg.partialPercent   = InpPartialPercent;
   g_cfg.trailStartR      = InpTrailStartR;
   g_cfg.trailAtrMult     = InpTrailAtrMult;
   g_cfg.timeStopBars     = InpTimeStopBars;
   g_cfg.timeStopMinR     = InpTimeStopMinR;

   g_cfg.stratSet    = InpStrategySet;
   g_cfg.allowLongs  = InpAllowLongs;
   g_cfg.allowShorts = InpAllowShorts;
  }

//+------------------------------------------------------------------+
//| Validate inputs that could silently produce nonsense              |
//+------------------------------------------------------------------+
bool ValidateInputs(string &problem)
  {
   if(InpRewardR < 1.0)
     { problem = "RewardR must be at least 1.0"; return false; }
   if(InpRiskValue <= 0.0)
     { problem = "RiskValue must be positive"; return false; }
   if(InpMaxRiskPerTradePct <= 0.0)
     { problem = "MaxRiskPerTradePct must be positive"; return false; }
   if(InpMinStopAtrMult >= InpMaxStopAtrMult)
     { problem = "MinStopAtrMult must be below MaxStopAtrMult"; return false; }
   if(PeriodSeconds(InpTfEntry) > PeriodSeconds(InpTfContext))
     { problem = "Entry timeframe must not be higher than the context timeframe"; return false; }
   if(PeriodSeconds(InpTfContext) > PeriodSeconds(InpTfBias))
     { problem = "Context timeframe must not be higher than the bias timeframe"; return false; }
   if(InpGmtOffsetHours < -12 || InpGmtOffsetHours > 14)
     { problem = "GmtOffsetHours out of range"; return false; }
   if(InpMaxSpreadVsRisk <= 0.0 || InpMaxSpreadVsRisk > 1.0)
     { problem = "MaxSpreadVsRisk must be between 0 and 1"; return false; }
   problem = "";
   return true;
  }

//+------------------------------------------------------------------+
//| Expert initialization                                             |
//+------------------------------------------------------------------+
int OnInit()
  {
   BuildConfig();
   g_log.Init("ApexGold", InpLogLevel, InpLogToFile);

   string problem = "";
   if(!ValidateInputs(problem))
     {
      g_log.Error("Invalid inputs: " + problem);
      return INIT_PARAMETERS_INCORRECT;
     }

   string wanted = (InpSymbol == "" ? _Symbol : InpSymbol);
   string resolved = CSymbolCtx::Resolve(wanted);
   if(resolved != wanted)
      g_log.Info(StringFormat("Symbol '%s' resolved to '%s'", wanted, resolved));

   if(!g_sym.Init(resolved))
     {
      g_log.Error("Cannot initialise symbol " + resolved);
      return INIT_FAILED;
     }

   if(!g_mkt.Init(g_sym.Name(), g_cfg, GetPointer(g_log)))
     {
      g_log.Error("Cannot create indicator handles");
      return INIT_FAILED;
     }

   g_ses.Init(g_cfg);
   g_news.Init(g_cfg, g_sym.Name(), GetPointer(g_log));
   g_signals.Init(g_cfg, GetPointer(g_mkt), GetPointer(g_sym), GetPointer(g_ses), GetPointer(g_log));
   g_risk.Init(g_cfg, GetPointer(g_sym), GetPointer(g_log));
   g_exec.Init(g_cfg, GetPointer(g_sym), GetPointer(g_log));
   g_pos.Init(g_cfg, GetPointer(g_sym), GetPointer(g_exec), GetPointer(g_mkt), GetPointer(g_log));

   g_ready = true;
   g_lastBarTime = 0;

   g_log.Info(StringFormat("ApexGold %s ready on %s | entry %s / context %s / bias %s | target %.1fR | risk %.2f",
                           APEX_VERSION, g_sym.Name(),
                           EnumToString(g_cfg.tfEntry), EnumToString(g_cfg.tfContext), EnumToString(g_cfg.tfBias),
                           g_cfg.rewardR, g_cfg.riskValue));

   if(!MQLInfoInteger(MQL_TESTER))
      EventSetTimer(30);

   return INIT_SUCCEEDED;
  }

//+------------------------------------------------------------------+
//| Expert deinitialization                                           |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   EventKillTimer();
   g_mkt.Deinit();
   if(InpShowPanel)
      Comment("");
   g_log.Info(StringFormat("ApexGold stopped (reason %d)", reason));
   g_log.Close();
  }

//+------------------------------------------------------------------+
//| New bar detection on the entry timeframe                          |
//+------------------------------------------------------------------+
bool IsNewEntryBar()
  {
   datetime t = iTime(g_sym.Name(), g_cfg.tfEntry, 0);
   if(t == 0)
      return false;
   if(t == g_lastBarTime)
      return false;
   g_lastBarTime = t;
   return true;
  }

//+------------------------------------------------------------------+
//| Main loop                                                         |
//+------------------------------------------------------------------+
void OnTick()
  {
   if(!g_ready)
      return;

   //--- open positions are managed on every tick, always
   g_pos.Manage();

   datetime now = TimeCurrent();

   //--- weekend protection takes priority over everything else
   if(g_ses.PastFridayCutoff(now))
     {
      g_pos.CloseAll("Friday cutoff");
      g_status = "flat for the weekend";
      UpdatePanel();
      return;
     }

   if(!IsNewEntryBar())
      return;

   if(!g_mkt.Refresh())
     {
      g_status = "waiting for history";
      UpdatePanel();
      return;
     }

   g_risk.RefreshCounters();

   //--- do not stack a second idea on the same bar
   datetime signalBar = iTime(g_sym.Name(), g_cfg.tfEntry, 1);
   if(signalBar == g_lastSignalBar)
      return;

   string reason = "";
   if(!g_risk.CanTrade(reason))
     {
      g_status = "no new risk: " + reason;
      UpdatePanel();
      return;
     }

   if(!g_ses.CanOpen(now, reason))
     {
      g_status = "no new risk: " + reason;
      UpdatePanel();
      return;
     }

   if(g_news.IsBlackout(now))
     {
      g_status = "news blackout";
      UpdatePanel();
      return;
     }

   SSignal sig;
   if(!g_signals.Evaluate(sig))
     {
      g_status = "no setup (" + g_signals.LastReject() + ")";
      UpdatePanel();
      return;
     }

   double stopDistance = MathAbs(sig.entry - sig.sl);
   string note = "";
   double lots = g_risk.LotsFor(stopDistance, note);
   if(lots <= 0.0)
     {
      g_log.Warn("Signal skipped: " + (note == "" ? "lot size resolved to zero" : note));
      g_status = "signal skipped: " + note;
      UpdatePanel();
      return;
     }
   if(note != "")
      g_log.Info("Sizing note: " + note);

   ulong ticket = 0;
   if(g_exec.OpenMarket(sig, lots, ticket))
     {
      g_lastSignalBar = signalBar;
      g_status = StringFormat("in trade %s %s", ApexDirToString(sig.dir), ApexSetupToString(sig.setup));
      g_risk.RefreshCounters();
     }
   else
     {
      g_status = "entry rejected by broker";
     }

   UpdatePanel();
  }

//+------------------------------------------------------------------+
//| Timer: keeps the panel alive on quiet symbols                     |
//+------------------------------------------------------------------+
void OnTimer()
  {
   if(!g_ready)
      return;
   UpdatePanel();
  }

//+------------------------------------------------------------------+
//| Status panel                                                      |
//+------------------------------------------------------------------+
void UpdatePanel()
  {
   if(!InpShowPanel)
      return;

   double realised = g_risk.RealisedToday();
   double floating = g_risk.FloatingPnL();
   double balance  = AccountInfoDouble(ACCOUNT_BALANCE);
   double equity   = AccountInfoDouble(ACCOUNT_EQUITY);
   double ddPct    = (g_risk.PeakEquity() > 0.0 ? 100.0 * (g_risk.PeakEquity() - equity) / g_risk.PeakEquity() : 0.0);

   string txt = StringFormat(
      "ApexGold %s  |  %s\n"
      "-------------------------------------------\n"
      "Regime      : %s   (ATR pct %.0f, %s)\n"
      "Bias        : %s\n"
      "Spread      : %d points   Open: %d\n"
      "Status      : %s\n"
      "-------------------------------------------\n"
      "Balance     : %.2f    Equity: %.2f\n"
      "Today       : realised %.2f, floating %.2f\n"
      "Trades today: %d      Losing streak: %d\n"
      "Drawdown    : %.2f%% of peak %.2f\n"
      "Target      : %.1fR   Risk: %.2f (%s)",
      APEX_VERSION, g_sym.Name(),
      ApexRegimeToString(g_mkt.Regime()), g_mkt.AtrPercentile(), EnumToString(g_mkt.VolState()),
      (g_mkt.BiasDir() > 0 ? "UP" : (g_mkt.BiasDir() < 0 ? "DOWN" : "NEUTRAL")),
      g_sym.SpreadPoints(), g_risk.OpenPositions(),
      g_status,
      balance, equity,
      realised, floating,
      g_risk.TradesToday(), g_risk.ConsecLosses(),
      ddPct, g_risk.PeakEquity(),
      g_cfg.rewardR, g_cfg.riskValue, EnumToString(g_cfg.riskMode));

   Comment(txt);
  }

//+------------------------------------------------------------------+
//| Trade transactions: keep the counters honest immediately          |
//+------------------------------------------------------------------+
void OnTradeTransaction(const MqlTradeTransaction &trans,
                        const MqlTradeRequest &request,
                        const MqlTradeResult &result)
  {
   if(!g_ready)
      return;
   if(trans.type != TRADE_TRANSACTION_DEAL_ADD)
      return;
   if(trans.symbol != g_sym.Name())
      return;

   g_risk.RefreshCounters();
   UpdatePanel();
  }

//+------------------------------------------------------------------+
//| Optimisation criterion: reward stability, not raw profit.         |
//| Used by the strategy tester in "Custom max" mode.                 |
//+------------------------------------------------------------------+
double OnTester()
  {
   double profit   = TesterStatistics(STAT_PROFIT);
   double trades   = TesterStatistics(STAT_TRADES);
   double maxDd    = TesterStatistics(STAT_EQUITYDD_PERCENT);
   double profitF  = TesterStatistics(STAT_PROFIT_FACTOR);
   double expected = TesterStatistics(STAT_EXPECTED_PAYOFF);

   //--- refuse to reward curve-fitted runs with too few observations
   if(trades < 40.0)
      return 0.0;
   if(profit <= 0.0)
      return 0.0;
   if(maxDd <= 0.0)
      maxDd = 0.01;

   //--- profit per unit of drawdown, damped by trade count and payoff
   double recovery = profit / maxDd;
   double pfTerm   = MathMin(profitF, 4.0);
   double sample   = MathSqrt(trades / 100.0);

   double score = recovery * pfTerm * sample;
   if(expected <= 0.0)
      score *= 0.5;
   return score;
  }
//+------------------------------------------------------------------+
