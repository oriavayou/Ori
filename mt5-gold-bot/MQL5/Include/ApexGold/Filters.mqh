//+------------------------------------------------------------------+
//|                                                      Filters.mqh |
//|        Trading-session windows and economic-calendar blackouts    |
//+------------------------------------------------------------------+
#ifndef APEXGOLD_FILTERS_MQH
#define APEXGOLD_FILTERS_MQH

#include "Config.mqh"
#include "Utils.mqh"

//+------------------------------------------------------------------+
//| Session filter. All windows are configured in GMT and translated  |
//| to broker-server time with the configured offset, so the same     |
//| preset behaves identically on a GMT+2 and a GMT+3 server.         |
//+------------------------------------------------------------------+
class CSessionFilter
  {
private:
   SConfig           m_cfg;

   static bool       InWindow(const int hour, const int from, const int to)
     {
      if(from == to)
         return false;
      if(from < to)
         return (hour >= from && hour < to);
      return (hour >= from || hour < to);
     }

public:
   void              Init(const SConfig &cfg) { m_cfg = cfg; }

   //--- convert a server timestamp into GMT calendar fields
   void              GmtStruct(const datetime serverTime, MqlDateTime &dt) const
     {
      datetime gmt = (datetime)((long)serverTime - (long)m_cfg.gmtOffsetHours * 3600);
      TimeToStruct(gmt, dt);
     }

   bool              IsAsia(const datetime t) const
     {
      MqlDateTime dt; GmtStruct(t, dt);
      return InWindow(dt.hour, m_cfg.asiaStartGmt, m_cfg.asiaEndGmt);
     }

   bool              IsLondon(const datetime t) const
     {
      MqlDateTime dt; GmtStruct(t, dt);
      return InWindow(dt.hour, m_cfg.londonStartGmt, m_cfg.londonEndGmt);
     }

   bool              IsNewYork(const datetime t) const
     {
      MqlDateTime dt; GmtStruct(t, dt);
      return InWindow(dt.hour, m_cfg.nyStartGmt, m_cfg.nyEndGmt);
     }

   //--- the overlap is where gold moves; used as a scoring bonus
   bool              IsOverlap(const datetime t) const
     {
      return (IsLondon(t) && IsNewYork(t));
     }

   bool              DayAllowed(const datetime t) const
     {
      MqlDateTime dt; GmtStruct(t, dt);
      switch(dt.day_of_week)
        {
         case 1: return m_cfg.tradeMonday;
         case 2: return m_cfg.tradeTuesday;
         case 3: return m_cfg.tradeWednesday;
         case 4: return m_cfg.tradeThursday;
         case 5: return m_cfg.tradeFriday;
         default: return false;   // weekend
        }
     }

   //--- true once the Friday cut-off has passed; the EA flattens then
   bool              PastFridayCutoff(const datetime t) const
     {
      MqlDateTime dt; GmtStruct(t, dt);
      if(dt.day_of_week != 5)
         return false;
      return (dt.hour >= m_cfg.fridayCloseHourGmt);
     }

   //--- master gate for opening new risk
   bool              CanOpen(const datetime t, string &reason) const
     {
      if(!DayAllowed(t))
        {
         reason = "day blocked";
         return false;
        }
      if(PastFridayCutoff(t))
        {
         reason = "past Friday cutoff";
         return false;
        }
      if(!m_cfg.useSessionFilter)
         return true;

      if(IsLondon(t) || IsNewYork(t))
         return true;

      reason = "outside London/NY";
      return false;
     }
  };

//+------------------------------------------------------------------+
//| Economic-calendar blackout. Uses the terminal calendar when it is |
//| available; when it is not (some brokers/builds expose nothing in  |
//| the tester) the filter fails open and simply allows trading, so   |
//| the EA never silently stops working.                              |
//+------------------------------------------------------------------+
class CNewsFilter
  {
private:
   SConfig           m_cfg;
   CLogger          *m_log;
   string            m_currencies[4];
   int               m_currencyCount;
   datetime          m_cacheUntil;
   datetime          m_blockFrom;
   datetime          m_blockTo;
   bool              m_calendarWorks;

public:
                     CNewsFilter(void) { m_log = NULL; m_currencyCount = 0; m_cacheUntil = 0;
                                         m_blockFrom = 0; m_blockTo = 0; m_calendarWorks = true; }

   void              Init(const SConfig &cfg, const string symbol, CLogger *logger)
     {
      m_cfg = cfg;
      m_log = logger;
      m_currencyCount = 0;

      //--- the currencies whose releases move this instrument
      string base   = SymbolInfoString(symbol, SYMBOL_CURRENCY_BASE);
      string profit = SymbolInfoString(symbol, SYMBOL_CURRENCY_PROFIT);
      if(base != "")   { m_currencies[m_currencyCount] = base;   m_currencyCount++; }
      if(profit != "" && profit != base) { m_currencies[m_currencyCount] = profit; m_currencyCount++; }
      if(m_currencyCount == 0)
        {
         m_currencies[0] = "USD";
         m_currencyCount = 1;
        }
     }

   //--- true when `t` sits inside the blackout around a qualifying event
   bool              IsBlackout(const datetime t)
     {
      if(!m_cfg.useNewsFilter)
         return false;
      if(!m_calendarWorks)
         return false;

      if(t >= m_blockFrom && t <= m_blockTo && m_blockTo > 0)
         return true;

      if(t < m_cacheUntil)
         return false;

      //--- refresh the look-ahead window once every 15 minutes
      m_cacheUntil = t + 15 * 60;

      datetime from = t - (datetime)(m_cfg.newsMinutesAfter * 60) - 3600;
      datetime to   = t + (datetime)(m_cfg.newsMinutesBefore * 60) + 3600;

      bool anyData = false;
      for(int c = 0; c < m_currencyCount; c++)
        {
         MqlCalendarValue values[];
         int n = CalendarValueHistory(values, from, to, NULL, m_currencies[c]);
         if(n <= 0)
            continue;
         anyData = true;

         for(int i = 0; i < n; i++)
           {
            MqlCalendarEvent ev;
            if(!CalendarEventById(values[i].event_id, ev))
               continue;
            if(ev.importance == CALENDAR_IMPORTANCE_NONE)
               continue;
            if(m_cfg.newsHighOnly && ev.importance != CALENDAR_IMPORTANCE_HIGH)
               continue;

            datetime evTime = values[i].time;
            datetime bFrom  = evTime - (datetime)(m_cfg.newsMinutesBefore * 60);
            datetime bTo    = evTime + (datetime)(m_cfg.newsMinutesAfter * 60);
            if(t >= bFrom && t <= bTo)
              {
               m_blockFrom = bFrom;
               m_blockTo   = bTo;
               if(m_log != NULL)
                  m_log.Info(StringFormat("News blackout %s until %s (%s)",
                                          m_currencies[c], TimeToString(bTo, TIME_MINUTES), ev.name));
               return true;
              }
           }
        }

      if(!anyData && GetLastError() != 0)
        {
         ResetLastError();
         m_calendarWorks = false;
         if(m_log != NULL)
            m_log.Warn("Economic calendar unavailable; news filter disabled for this run");
        }
      return false;
     }
  };

#endif // APEXGOLD_FILTERS_MQH
//+------------------------------------------------------------------+
