//+------------------------------------------------------------------+
//|                                                    Execution.mqh |
//|      Order placement, retries and open-position management        |
//+------------------------------------------------------------------+
#ifndef APEXGOLD_EXECUTION_MQH
#define APEXGOLD_EXECUTION_MQH

#include "Config.mqh"
#include "Utils.mqh"
#include "Market.mqh"

//+------------------------------------------------------------------+
//| Thin, explicit wrapper over OrderSend. Kept hand-rolled so the    |
//| filling mode, deviation and retry policy are all visible.         |
//+------------------------------------------------------------------+
class CExecutor
  {
private:
   SConfig           m_cfg;
   CSymbolCtx       *m_sym;
   CLogger          *m_log;

   //--- retcodes worth trying again
   static bool       Retryable(const uint code)
     {
      return (code == TRADE_RETCODE_REQUOTE ||
              code == TRADE_RETCODE_PRICE_CHANGED ||
              code == TRADE_RETCODE_PRICE_OFF ||
              code == TRADE_RETCODE_TIMEOUT ||
              code == TRADE_RETCODE_CONNECTION ||
              code == TRADE_RETCODE_TOO_MANY_REQUESTS);
     }

   //--- push stops out to a legal distance from the current market
   void              EnforceStopDistance(const ENUM_APEX_DIR dir, double &sl, double &tp) const
     {
      double minDist = m_sym.MinStopDistance();
      double bid = m_sym.Bid();
      double ask = m_sym.Ask();

      if(dir == APEX_DIR_LONG)
        {
         if(sl > 0.0 && bid - sl < minDist) sl = bid - minDist;
         if(tp > 0.0 && tp - ask < minDist) tp = ask + minDist;
        }
      else
        {
         if(sl > 0.0 && sl - ask < minDist) sl = ask + minDist;
         if(tp > 0.0 && bid - tp < minDist) tp = bid - minDist;
        }
      sl = m_sym.NormalizePrice(sl);
      tp = m_sym.NormalizePrice(tp);
     }

public:
                     CExecutor(void) { m_sym = NULL; m_log = NULL; }

   void              Init(const SConfig &cfg, CSymbolCtx *sym, CLogger *logger)
     {
      m_cfg = cfg;
      m_sym = sym;
      m_log = logger;
     }

   //+---------------------------------------------------------------+
   //| Market entry with stop and target attached to the same request.|
   //+---------------------------------------------------------------+
   bool              OpenMarket(const SSignal &sig, const double lots, ulong &ticketOut)
     {
      ticketOut = 0;
      if(lots <= 0.0)
         return false;

      double sl = sig.sl;
      double tp = sig.tp;
      EnforceStopDistance(sig.dir, sl, tp);

      for(int attempt = 0; attempt <= m_cfg.maxRetries; attempt++)
        {
         MqlTradeRequest req;
         MqlTradeResult  res;
         ZeroMemory(req);
         ZeroMemory(res);

         double price = (sig.dir == APEX_DIR_LONG ? m_sym.Ask() : m_sym.Bid());
         if(price <= 0.0)
            return false;

         req.action       = TRADE_ACTION_DEAL;
         req.symbol       = m_sym.Name();
         req.volume       = lots;
         req.type         = (sig.dir == APEX_DIR_LONG ? ORDER_TYPE_BUY : ORDER_TYPE_SELL);
         req.price        = m_sym.NormalizePrice(price);
         req.sl           = sl;
         req.tp           = tp;
         req.deviation    = (ulong)m_cfg.slippagePoints;
         req.magic        = (ulong)m_cfg.magic;
         req.comment      = m_cfg.comment + "|" + ApexSetupToString(sig.setup);
         req.type_filling = m_sym.FillingMode();
         req.type_time    = ORDER_TIME_GTC;

         if(OrderSend(req, res))
           {
            if(res.retcode == TRADE_RETCODE_DONE || res.retcode == TRADE_RETCODE_PLACED ||
               res.retcode == TRADE_RETCODE_DONE_PARTIAL)
              {
               ticketOut = res.order;
               if(m_log != NULL)
                  m_log.Info(StringFormat("OPEN %s %.2f lots @ %.*f SL %.*f TP %.*f | %s | score %.0f | %s",
                                          ApexDirToString(sig.dir), res.volume,
                                          m_sym.Digits(), res.price,
                                          m_sym.Digits(), sl,
                                          m_sym.Digits(), tp,
                                          ApexSetupToString(sig.setup), sig.score, sig.reason));
               return true;
              }
           }

         uint code = res.retcode;
         if(!Retryable(code))
           {
            if(m_log != NULL)
               m_log.Error(StringFormat("OrderSend failed, retcode %u (%s)", code, res.comment));
            return false;
           }

         if(m_log != NULL)
            m_log.Warn(StringFormat("OrderSend retry %d/%d, retcode %u", attempt + 1, m_cfg.maxRetries, code));
         Sleep(m_cfg.retryDelayMs);
        }

      if(m_log != NULL)
         m_log.Error("OrderSend exhausted retries");
      return false;
     }

   //+---------------------------------------------------------------+
   //| Move stop and/or target on an open position.                   |
   //+---------------------------------------------------------------+
   bool              ModifyPosition(const ulong ticket, const double newSl, const double newTp)
     {
      if(!PositionSelectByTicket(ticket))
         return false;

      ENUM_APEX_DIR dir = (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY ? APEX_DIR_LONG : APEX_DIR_SHORT);
      double sl = newSl;
      double tp = newTp;
      EnforceStopDistance(dir, sl, tp);

      //--- nothing to do
      double curSl = PositionGetDouble(POSITION_SL);
      double curTp = PositionGetDouble(POSITION_TP);
      if(MathAbs(curSl - sl) < m_sym.TickSize() * 0.5 && MathAbs(curTp - tp) < m_sym.TickSize() * 0.5)
         return true;

      //--- respect the freeze level
      double freeze = m_sym.FreezeDistance();
      if(freeze > 0.0)
        {
         double price = (dir == APEX_DIR_LONG ? m_sym.Bid() : m_sym.Ask());
         if(MathAbs(price - sl) < freeze || (tp > 0.0 && MathAbs(price - tp) < freeze))
            return false;
        }

      for(int attempt = 0; attempt <= m_cfg.maxRetries; attempt++)
        {
         MqlTradeRequest req;
         MqlTradeResult  res;
         ZeroMemory(req);
         ZeroMemory(res);

         req.action   = TRADE_ACTION_SLTP;
         req.symbol   = m_sym.Name();
         req.position = ticket;
         req.sl       = sl;
         req.tp       = tp;
         req.magic    = (ulong)m_cfg.magic;

         if(OrderSend(req, res) &&
            (res.retcode == TRADE_RETCODE_DONE || res.retcode == TRADE_RETCODE_PLACED))
            return true;

         if(!Retryable(res.retcode))
           {
            if(m_log != NULL)
               m_log.Warn(StringFormat("Modify #%I64u failed, retcode %u (%s)", ticket, res.retcode, res.comment));
            return false;
           }
         Sleep(m_cfg.retryDelayMs);
        }
      return false;
     }

   //+---------------------------------------------------------------+
   //| Close all or part of a position at market.                     |
   //+---------------------------------------------------------------+
   bool              ClosePosition(const ulong ticket, const double volume = 0.0)
     {
      if(!PositionSelectByTicket(ticket))
         return false;

      double posVol = PositionGetDouble(POSITION_VOLUME);
      double vol = (volume <= 0.0 ? posVol : MathMin(volume, posVol));
      vol = m_sym.NormalizeVolume(vol);
      if(vol <= 0.0)
         return false;

      //--- never leave a remainder smaller than the broker minimum
      if(posVol - vol > 0.0 && posVol - vol < m_sym.VolMin())
         vol = posVol;

      bool isBuy = (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY);

      for(int attempt = 0; attempt <= m_cfg.maxRetries; attempt++)
        {
         MqlTradeRequest req;
         MqlTradeResult  res;
         ZeroMemory(req);
         ZeroMemory(res);

         req.action       = TRADE_ACTION_DEAL;
         req.symbol       = m_sym.Name();
         req.position     = ticket;
         req.volume       = vol;
         req.type         = (isBuy ? ORDER_TYPE_SELL : ORDER_TYPE_BUY);
         req.price        = m_sym.NormalizePrice(isBuy ? m_sym.Bid() : m_sym.Ask());
         req.deviation    = (ulong)m_cfg.slippagePoints;
         req.magic        = (ulong)m_cfg.magic;
         req.comment      = m_cfg.comment + "|close";
         req.type_filling = m_sym.FillingMode();

         if(OrderSend(req, res) &&
            (res.retcode == TRADE_RETCODE_DONE || res.retcode == TRADE_RETCODE_DONE_PARTIAL))
           {
            if(m_log != NULL)
               m_log.Info(StringFormat("CLOSE #%I64u volume %.2f", ticket, vol));
            return true;
           }

         if(!Retryable(res.retcode))
           {
            if(m_log != NULL)
               m_log.Warn(StringFormat("Close #%I64u failed, retcode %u (%s)", ticket, res.retcode, res.comment));
            return false;
           }
         Sleep(m_cfg.retryDelayMs);
        }
      return false;
     }
  };

//+------------------------------------------------------------------+
//| Manages positions after entry: break-even, partials, trailing and |
//| the time stop. State is inferred from the position and its deal   |
//| history, so a terminal restart does not confuse it.               |
//+------------------------------------------------------------------+
class CPositionManager
  {
private:
   SConfig           m_cfg;
   CSymbolCtx       *m_sym;
   CExecutor        *m_exec;
   CMarket          *m_mkt;
   CLogger          *m_log;

   //--- has this position already been partially closed?
   bool              PartialTaken(const ulong ticket) const
     {
      datetime from = (datetime)PositionGetInteger(POSITION_TIME) - 60;
      if(!HistorySelect(from, TimeCurrent() + 60))
         return false;
      int total = HistoryDealsTotal();
      for(int i = 0; i < total; i++)
        {
         ulong dt = HistoryDealGetTicket(i);
         if(dt == 0)
            continue;
         if((ulong)HistoryDealGetInteger(dt, DEAL_POSITION_ID) != ticket)
            continue;
         ENUM_DEAL_ENTRY e = (ENUM_DEAL_ENTRY)HistoryDealGetInteger(dt, DEAL_ENTRY);
         if(e == DEAL_ENTRY_OUT || e == DEAL_ENTRY_OUT_BY)
            return true;
        }
      return false;
     }

public:
                     CPositionManager(void) { m_sym = NULL; m_exec = NULL; m_mkt = NULL; m_log = NULL; }

   void              Init(const SConfig &cfg, CSymbolCtx *sym, CExecutor *exec, CMarket *mkt, CLogger *logger)
     {
      m_cfg  = cfg;
      m_sym  = sym;
      m_exec = exec;
      m_mkt  = mkt;
      m_log  = logger;
     }

   //+---------------------------------------------------------------+
   //| Walk this EA's positions and apply the management rules.       |
   //+---------------------------------------------------------------+
   void              Manage(void)
     {
      int total = PositionsTotal();
      for(int i = total - 1; i >= 0; i--)
        {
         ulong ticket = PositionGetTicket(i);
         if(ticket == 0)
            continue;
         if(!PositionSelectByTicket(ticket))
            continue;
         if(PositionGetInteger(POSITION_MAGIC) != m_cfg.magic)
            continue;
         if(PositionGetString(POSITION_SYMBOL) != m_sym.Name())
            continue;

         ManageOne(ticket);
        }
     }

   void              ManageOne(const ulong ticket)
     {
      bool   isBuy   = (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY);
      double open    = PositionGetDouble(POSITION_PRICE_OPEN);
      double sl      = PositionGetDouble(POSITION_SL);
      double tp      = PositionGetDouble(POSITION_TP);
      double volume  = PositionGetDouble(POSITION_VOLUME);
      datetime otime = (datetime)PositionGetInteger(POSITION_TIME);
      double cur     = (isBuy ? m_sym.Bid() : m_sym.Ask());

      if(sl <= 0.0)
         return;   // an unprotected position is left alone rather than guessed at

      //--- the original risk, reconstructed from the initial stop.
      //--- Once break-even has moved the stop this understates R, so the
      //--- R multiple is measured against the distance still on record.
      double riskDist = MathAbs(open - sl);
      if(riskDist <= 0.0)
         return;

      double moved = (isBuy ? cur - open : open - cur);
      double rNow  = moved / riskDist;

      //--- 1) partial profit taking -----------------------------------
      if(m_cfg.partialAtR > 0.0 && m_cfg.partialPercent > 0.0 && rNow >= m_cfg.partialAtR)
        {
         if(!PartialTaken(ticket))
           {
            double part = m_sym.NormalizeVolume(volume * m_cfg.partialPercent / 100.0);
            if(part > 0.0 && part < volume)
              {
               if(m_exec.ClosePosition(ticket, part))
                 {
                  if(m_log != NULL)
                     m_log.Info(StringFormat("Partial %.0f%% at %.2fR on #%I64u",
                                             m_cfg.partialPercent, rNow, ticket));
                  if(!PositionSelectByTicket(ticket))
                     return;
                  volume = PositionGetDouble(POSITION_VOLUME);
                 }
              }
           }
        }

      double newSl = sl;

      //--- 2) break-even ----------------------------------------------
      if(m_cfg.breakEvenAtR > 0.0 && rNow >= m_cfg.breakEvenAtR)
        {
         double offset = m_cfg.breakEvenOffsetR * riskDist;
         double beLevel = (isBuy ? open + offset : open - offset);
         if(isBuy && beLevel > newSl) newSl = beLevel;
         if(!isBuy && beLevel < newSl) newSl = beLevel;
        }

      //--- 3) ATR trailing --------------------------------------------
      if(m_cfg.trailStartR > 0.0 && rNow >= m_cfg.trailStartR)
        {
         double atr = m_mkt.EntryAtr(1);
         if(atr > 0.0)
           {
            double trail = (isBuy ? cur - m_cfg.trailAtrMult * atr : cur + m_cfg.trailAtrMult * atr);
            if(isBuy && trail > newSl)  newSl = trail;
            if(!isBuy && trail < newSl) newSl = trail;
           }
        }

      if(MathAbs(newSl - sl) > m_sym.TickSize() * 0.5)
        {
         if(m_exec.ModifyPosition(ticket, newSl, tp))
            if(m_log != NULL)
               m_log.Info(StringFormat("Stop moved to %.*f on #%I64u (%.2fR)",
                                       m_sym.Digits(), newSl, ticket, rNow));
        }

      //--- 4) time stop: an idea that has not worked is dead money ----
      if(m_cfg.timeStopBars > 0)
        {
         int secs = PeriodSeconds(m_cfg.tfEntry);
         if(secs > 0)
           {
            int barsHeld = (int)((TimeCurrent() - otime) / secs);
            if(barsHeld >= m_cfg.timeStopBars && rNow < m_cfg.timeStopMinR)
              {
               if(m_log != NULL)
                  m_log.Info(StringFormat("Time stop on #%I64u after %d bars at %.2fR", ticket, barsHeld, rNow));
               m_exec.ClosePosition(ticket, 0.0);
              }
           }
        }
     }

   //--- flatten everything this EA owns on this symbol
   void              CloseAll(const string why)
     {
      int total = PositionsTotal();
      for(int i = total - 1; i >= 0; i--)
        {
         ulong ticket = PositionGetTicket(i);
         if(ticket == 0)
            continue;
         if(!PositionSelectByTicket(ticket))
            continue;
         if(PositionGetInteger(POSITION_MAGIC) != m_cfg.magic)
            continue;
         if(PositionGetString(POSITION_SYMBOL) != m_sym.Name())
            continue;

         if(m_log != NULL)
            m_log.Info(StringFormat("Closing #%I64u: %s", ticket, why));
         m_exec.ClosePosition(ticket, 0.0);
        }
     }
  };

#endif // APEXGOLD_EXECUTION_MQH
//+------------------------------------------------------------------+
