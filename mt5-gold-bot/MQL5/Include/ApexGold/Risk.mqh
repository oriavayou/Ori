//+------------------------------------------------------------------+
//|                                                         Risk.mqh |
//|   Position sizing and the capital-protection layer for ApexGold   |
//+------------------------------------------------------------------+
#ifndef APEXGOLD_RISK_MQH
#define APEXGOLD_RISK_MQH

#include "Config.mqh"
#include "Utils.mqh"

//+------------------------------------------------------------------+
//| Owns every question of "how much" and "may I trade at all".       |
//| All limits are evaluated against realised plus floating money so  |
//| an open loser cannot walk the account past the daily stop.        |
//+------------------------------------------------------------------+
class CRiskManager
  {
private:
   SConfig           m_cfg;
   CSymbolCtx       *m_sym;
   CLogger          *m_log;

   datetime          m_dayStart;      // server midnight of the current day
   datetime          m_weekStart;
   double            m_peakEquity;
   int               m_tradesToday;
   int               m_consecLosses;
   datetime          m_cooldownUntil;
   bool              m_halted;
   string            m_haltReason;
   string            m_gvPeak;

   static datetime   StartOfDay(const datetime t)
     {
      MqlDateTime dt;
      TimeToStruct(t, dt);
      dt.hour = 0; dt.min = 0; dt.sec = 0;
      return StructToTime(dt);
     }

   static datetime   StartOfWeek(const datetime t)
     {
      MqlDateTime dt;
      TimeToStruct(t, dt);
      int dow = dt.day_of_week;          // 0 = Sunday
      datetime day0 = StartOfDay(t);
      return (datetime)((long)day0 - (long)dow * 86400);
     }

   //--- realised money from closed deals of this EA since `from`
   double            RealisedSince(const datetime from) const
     {
      double sum = 0.0;
      if(!HistorySelect(from, TimeCurrent() + 60))
         return 0.0;

      int total = HistoryDealsTotal();
      for(int i = 0; i < total; i++)
        {
         ulong ticket = HistoryDealGetTicket(i);
         if(ticket == 0)
            continue;
         if(HistoryDealGetInteger(ticket, DEAL_MAGIC) != m_cfg.magic)
            continue;
         if(HistoryDealGetString(ticket, DEAL_SYMBOL) != m_sym.Name())
            continue;
         ENUM_DEAL_ENTRY entry = (ENUM_DEAL_ENTRY)HistoryDealGetInteger(ticket, DEAL_ENTRY);
         if(entry != DEAL_ENTRY_OUT && entry != DEAL_ENTRY_OUT_BY && entry != DEAL_ENTRY_INOUT)
            continue;

         sum += HistoryDealGetDouble(ticket, DEAL_PROFIT);
         sum += HistoryDealGetDouble(ticket, DEAL_SWAP);
         sum += HistoryDealGetDouble(ticket, DEAL_COMMISSION);
        }
      return sum;
     }

public:
                     CRiskManager(void) { m_sym = NULL; m_log = NULL; m_dayStart = 0; m_weekStart = 0;
                                          m_peakEquity = 0.0; m_tradesToday = 0; m_consecLosses = 0;
                                          m_cooldownUntil = 0; m_halted = false; m_haltReason = ""; m_gvPeak = ""; }

   void              Init(const SConfig &cfg, CSymbolCtx *sym, CLogger *logger)
     {
      m_cfg = cfg;
      m_sym = sym;
      m_log = logger;

      m_dayStart  = StartOfDay(TimeCurrent());
      m_weekStart = StartOfWeek(TimeCurrent());
      m_gvPeak    = StringFormat("ApexGold_%d_peak", (int)cfg.magic);

      double equity = AccountInfoDouble(ACCOUNT_EQUITY);
      if(GlobalVariableCheck(m_gvPeak))
         m_peakEquity = GlobalVariableGet(m_gvPeak);
      if(m_peakEquity < equity || m_peakEquity <= 0.0)
        {
         m_peakEquity = equity;
         GlobalVariableSet(m_gvPeak, m_peakEquity);
        }

      RefreshCounters();
     }

   double            PeakEquity(void)  const { return m_peakEquity; }
   int               TradesToday(void) const { return m_tradesToday; }
   int               ConsecLosses(void)const { return m_consecLosses; }
   bool              IsHalted(void)    const { return m_halted; }
   string            HaltReason(void)  const { return m_haltReason; }

   double            RealisedToday(void) const { return RealisedSince(m_dayStart); }
   double            RealisedThisWeek(void) const { return RealisedSince(m_weekStart); }

   //--- floating result of this EA's open positions on this symbol
   double            FloatingPnL(void) const
     {
      double sum = 0.0;
      int total = PositionsTotal();
      for(int i = 0; i < total; i++)
        {
         ulong ticket = PositionGetTicket(i);
         if(ticket == 0)
            continue;
         if(PositionGetInteger(POSITION_MAGIC) != m_cfg.magic)
            continue;
         if(PositionGetString(POSITION_SYMBOL) != m_sym.Name())
            continue;
         sum += PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP);
        }
      return sum;
     }

   int               OpenPositions(void) const
     {
      int count = 0;
      int total = PositionsTotal();
      for(int i = 0; i < total; i++)
        {
         ulong ticket = PositionGetTicket(i);
         if(ticket == 0)
            continue;
         if(PositionGetInteger(POSITION_MAGIC) == m_cfg.magic &&
            PositionGetString(POSITION_SYMBOL) == m_sym.Name())
            count++;
        }
      return count;
     }

   //+---------------------------------------------------------------+
   //| Roll the day/week buckets and recount trades and losing runs.  |
   //| Called on every new bar and after every fill.                  |
   //+---------------------------------------------------------------+
   void              RefreshCounters(void)
     {
      datetime now = TimeCurrent();
      datetime today = StartOfDay(now);
      if(today != m_dayStart)
        {
         m_dayStart = today;
         m_halted = false;
         m_haltReason = "";
         if(m_log != NULL)
            m_log.Info("New trading day - daily limits reset");
        }
      datetime week = StartOfWeek(now);
      if(week != m_weekStart)
         m_weekStart = week;

      double equity = AccountInfoDouble(ACCOUNT_EQUITY);
      if(equity > m_peakEquity)
        {
         m_peakEquity = equity;
         GlobalVariableSet(m_gvPeak, m_peakEquity);
        }

      CountTradesAndLosses();
     }

   void              CountTradesAndLosses(void)
     {
      m_tradesToday  = 0;
      m_consecLosses = 0;

      //--- look back far enough to rebuild a losing streak after a restart
      datetime from = (datetime)((long)m_dayStart - 14L * 86400L);
      if(!HistorySelect(from, TimeCurrent() + 60))
         return;

      int total = HistoryDealsTotal();
      double closedProfit[];
      datetime closedTime[];
      ArrayResize(closedProfit, 0);
      ArrayResize(closedTime, 0);

      for(int i = 0; i < total; i++)
        {
         ulong ticket = HistoryDealGetTicket(i);
         if(ticket == 0)
            continue;
         if(HistoryDealGetInteger(ticket, DEAL_MAGIC) != m_cfg.magic)
            continue;
         if(HistoryDealGetString(ticket, DEAL_SYMBOL) != m_sym.Name())
            continue;

         ENUM_DEAL_ENTRY entry = (ENUM_DEAL_ENTRY)HistoryDealGetInteger(ticket, DEAL_ENTRY);
         datetime dtime = (datetime)HistoryDealGetInteger(ticket, DEAL_TIME);

         if(entry == DEAL_ENTRY_IN && dtime >= m_dayStart)
            m_tradesToday++;

         if(entry == DEAL_ENTRY_OUT || entry == DEAL_ENTRY_OUT_BY)
           {
            double p = HistoryDealGetDouble(ticket, DEAL_PROFIT)
                     + HistoryDealGetDouble(ticket, DEAL_SWAP)
                     + HistoryDealGetDouble(ticket, DEAL_COMMISSION);
            int k = ArraySize(closedProfit);
            ArrayResize(closedProfit, k + 1);
            ArrayResize(closedTime, k + 1);
            closedProfit[k] = p;
            closedTime[k] = dtime;
           }
        }

      //--- history is chronological, so walk it backwards
      for(int i = ArraySize(closedProfit) - 1; i >= 0; i--)
        {
         if(closedProfit[i] < 0.0)
            m_consecLosses++;
         else
            break;
        }

      if(m_consecLosses >= m_cfg.maxConsecutiveLosses && m_cfg.maxConsecutiveLosses > 0)
        {
         int last = ArraySize(closedTime) - 1;
         if(last >= 0)
           {
            datetime until = closedTime[last] + (datetime)(m_cfg.cooldownMinutes * 60);
            if(until > m_cooldownUntil)
               m_cooldownUntil = until;
           }
        }
     }

   //+---------------------------------------------------------------+
   //| Hard gates. Anything returning false here means no new risk.   |
   //+---------------------------------------------------------------+
   bool              CanTrade(string &reason)
     {
      RefreshCounters();

      if(m_halted)
        {
         reason = m_haltReason;
         return false;
        }

      double balance = AccountInfoDouble(ACCOUNT_BALANCE);
      double equity  = AccountInfoDouble(ACCOUNT_EQUITY);
      if(balance <= 0.0)
        {
         reason = "no balance";
         return false;
        }

      //--- day-start balance reconstructed from realised results
      double realisedDay  = RealisedSince(m_dayStart);
      double realisedWeek = RealisedSince(m_weekStart);
      double dayOpenBalance = balance - realisedDay;
      double weekOpenBalance = balance - realisedWeek;
      double floating = FloatingPnL();

      //--- daily loss limit, counting open risk
      if(m_cfg.dailyLossLimitPct > 0.0 && dayOpenBalance > 0.0)
        {
         double dayPnL = realisedDay + floating;
         double limit  = -dayOpenBalance * m_cfg.dailyLossLimitPct / 100.0;
         if(dayPnL <= limit)
           {
            m_halted = true;
            m_haltReason = StringFormat("daily loss limit hit (%.2f <= %.2f)", dayPnL, limit);
            reason = m_haltReason;
            if(m_log != NULL) m_log.Warn(m_haltReason);
            return false;
           }
        }

      //--- daily profit lock: bank the day rather than give it back
      if(m_cfg.profitLockPct > 0.0 && dayOpenBalance > 0.0)
        {
         double dayPnL = realisedDay + floating;
         double target = dayOpenBalance * m_cfg.profitLockPct / 100.0;
         if(dayPnL >= target)
           {
            m_halted = true;
            m_haltReason = StringFormat("daily profit target reached (%.2f >= %.2f)", dayPnL, target);
            reason = m_haltReason;
            if(m_log != NULL) m_log.Info(m_haltReason);
            return false;
           }
        }

      //--- weekly loss limit
      if(m_cfg.weeklyLossLimitPct > 0.0 && weekOpenBalance > 0.0)
        {
         double weekPnL = realisedWeek + floating;
         double limit = -weekOpenBalance * m_cfg.weeklyLossLimitPct / 100.0;
         if(weekPnL <= limit)
           {
            reason = StringFormat("weekly loss limit hit (%.2f <= %.2f)", weekPnL, limit);
            if(m_log != NULL) m_log.Warn(reason);
            return false;
           }
        }

      //--- absolute drawdown from the equity peak
      if(m_cfg.maxDrawdownPct > 0.0 && m_peakEquity > 0.0)
        {
         double dd = 100.0 * (m_peakEquity - equity) / m_peakEquity;
         if(dd >= m_cfg.maxDrawdownPct)
           {
            m_halted = true;
            m_haltReason = StringFormat("max drawdown %.2f%% >= %.2f%%", dd, m_cfg.maxDrawdownPct);
            reason = m_haltReason;
            if(m_log != NULL) m_log.Error(m_haltReason);
            return false;
           }
        }

      if(m_cfg.maxTradesPerDay > 0 && m_tradesToday >= m_cfg.maxTradesPerDay)
        {
         reason = StringFormat("daily trade cap reached (%d)", m_tradesToday);
         return false;
        }

      if(m_cooldownUntil > TimeCurrent())
        {
         reason = StringFormat("cooldown after %d losses until %s",
                               m_consecLosses, TimeToString(m_cooldownUntil, TIME_MINUTES));
         return false;
        }

      if(m_cfg.maxOpenPositions > 0 && OpenPositions() >= m_cfg.maxOpenPositions)
        {
         reason = "max open positions reached";
         return false;
        }

      if(!m_sym.IsTradeAllowed())
        {
         reason = "symbol not tradable";
         return false;
        }

      if(!TerminalInfoInteger(TERMINAL_TRADE_ALLOWED) || !AccountInfoInteger(ACCOUNT_TRADE_ALLOWED))
        {
         reason = "trading disabled by terminal or account";
         return false;
        }

      if(m_sym.SpreadPoints() > m_cfg.maxSpreadPoints)
        {
         reason = StringFormat("spread %d > %d points", m_sym.SpreadPoints(), m_cfg.maxSpreadPoints);
         return false;
        }

      reason = "";
      return true;
     }

   //+---------------------------------------------------------------+
   //| Lot size for a given stop distance. Never exceeds the hard     |
   //| per-trade ceiling, the configured max lot, or free margin.     |
   //+---------------------------------------------------------------+
   double            LotsFor(const double stopDistance, string &note)
     {
      note = "";
      if(stopDistance <= 0.0)
         return 0.0;

      double balance = AccountInfoDouble(ACCOUNT_BALANCE);
      double equity  = AccountInfoDouble(ACCOUNT_EQUITY);
      double riskMoney = 0.0;
      double lots = 0.0;

      switch(m_cfg.riskMode)
        {
         case APEX_RISK_FIXED_LOT:
            lots = m_cfg.riskValue;
            break;
         case APEX_RISK_FIXED_MONEY:
            riskMoney = m_cfg.riskValue;
            break;
         case APEX_RISK_PERCENT_EQUITY:
            riskMoney = equity * m_cfg.riskValue / 100.0;
            break;
         default:
            riskMoney = balance * m_cfg.riskValue / 100.0;
            break;
        }

      //--- hard ceiling applies to every mode
      double ceiling = balance * m_cfg.maxRiskPerTradePct / 100.0;
      if(m_cfg.riskMode != APEX_RISK_FIXED_LOT)
        {
         if(riskMoney > ceiling)
           {
            riskMoney = ceiling;
            note = "risk capped by maxRiskPerTradePct";
           }
         lots = m_sym.LotsForRisk(riskMoney, stopDistance);
        }
      else
        {
         double implied = m_sym.MoneyForDistance(lots, stopDistance);
         if(implied > ceiling && ceiling > 0.0)
           {
            lots = m_sym.LotsForRisk(ceiling, stopDistance);
            note = "fixed lot reduced to respect risk ceiling";
           }
        }

      if(m_cfg.maxLot > 0.0 && lots > m_cfg.maxLot)
        {
         lots = m_cfg.maxLot;
         if(note == "") note = "capped by maxLot";
        }

      lots = m_sym.NormalizeVolume(lots);

      //--- margin check with a 20% headroom
      double margin = 0.0;
      double price = m_sym.Ask();
      if(OrderCalcMargin(ORDER_TYPE_BUY, m_sym.Name(), lots, price, margin))
        {
         double freeMargin = AccountInfoDouble(ACCOUNT_MARGIN_FREE);
         if(margin > freeMargin * 0.8 && margin > 0.0)
           {
            double scaled = lots * (freeMargin * 0.8) / margin;
            lots = m_sym.NormalizeVolume(scaled);
            note = "reduced for available margin";
           }
        }

      if(lots < m_sym.VolMin())
        {
         note = StringFormat("computed lot %.4f below broker minimum %.2f", lots, m_sym.VolMin());
         return 0.0;
        }
      return lots;
     }

   void              ResetHalt(void) { m_halted = false; m_haltReason = ""; }
  };

#endif // APEXGOLD_RISK_MQH
//+------------------------------------------------------------------+
