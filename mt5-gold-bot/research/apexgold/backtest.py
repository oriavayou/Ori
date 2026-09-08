"""Bar-by-bar backtest engine with realistic costs and the EA's risk layer.

Modelling choices, stated openly because they decide whether the result
means anything:

* Fills happen at the NEXT bar's open after a decision bar, plus spread
  and slippage. Nothing is filled at the price that produced the signal.
* When a bar's range contains both the stop and the target, the stop is
  taken. Without tick data the order is unknowable, and the optimistic
  assumption is how backtests learn to lie.
* Gaps through a level fill at the open, not at the level.
* Spread is charged on entry and exit, commission per lot round turn.
* The daily loss limit, trade cap, losing-streak cooldown and drawdown
  halt all run exactly as they do in the EA.
"""

from __future__ import annotations

from dataclasses import dataclass, field

import numpy as np
import pandas as pd

from .strategy import Params, build_features, add_touch_flags, generate_signals


@dataclass
class SymbolSpec:
    """Contract details. Defaults describe a typical XAUUSD CFD."""

    name: str = "XAUUSD"
    point: float = 0.01
    tick_size: float = 0.01
    tick_value: float = 1.0        # account currency per tick per lot
    vol_min: float = 0.01
    vol_step: float = 0.01
    vol_max: float = 50.0

    spread_points: float = 25.0    # 25 points = $0.25 on a 2-digit gold feed
    slippage_points: float = 10.0
    commission_per_lot: float = 7.0  # round turn, account currency

    @property
    def value_per_price_unit(self) -> float:
        """Account currency per 1.0 of price movement, per lot."""
        return self.tick_value / self.tick_size

    @property
    def spread_price(self) -> float:
        return self.spread_points * self.point

    @property
    def slippage_price(self) -> float:
        return self.slippage_points * self.point


@dataclass
class RiskSettings:
    risk_percent: float = 0.5
    max_risk_percent: float = 1.0
    max_lot: float = 5.0

    daily_loss_limit_pct: float = 3.0
    weekly_loss_limit_pct: float = 6.0
    max_drawdown_pct: float = 12.0
    max_trades_per_day: int = 4
    max_consec_losses: int = 3
    cooldown_minutes: int = 240

    break_even_at_r: float = 0.0
    break_even_offset_r: float = 0.05
    partial_at_r: float = 0.0
    partial_percent: float = 50.0
    trail_start_r: float = 0.0
    trail_atr_mult: float = 1.5
    time_stop_bars: int = 0
    time_stop_min_r: float = 0.5


@dataclass
class Trade:
    entry_time: pd.Timestamp
    exit_time: pd.Timestamp
    direction: int
    setup: int
    entry: float
    exit: float
    sl: float
    tp: float
    lots: float
    risk_price: float
    r_multiple: float
    pnl: float
    reason: str
    score: float
    balance_after: float


class Backtester:
    def __init__(self, spec: SymbolSpec, params: Params, risk: RiskSettings,
                 initial_balance: float = 10_000.0, pessimistic: bool = True):
        self.spec = spec
        self.p = params
        self.risk = risk
        self.initial_balance = initial_balance
        self.pessimistic = pessimistic

    # ------------------------------------------------------------------
    def _lots_for(self, balance: float, risk_price: float) -> float:
        risk_money = balance * self.risk.risk_percent / 100.0
        ceiling = balance * self.risk.max_risk_percent / 100.0
        risk_money = min(risk_money, ceiling)

        per_lot = risk_price * self.spec.value_per_price_unit
        if per_lot <= 0:
            return 0.0
        lots = risk_money / per_lot
        lots = min(lots, self.spec.vol_max, self.risk.max_lot)
        lots = np.floor(lots / self.spec.vol_step + 1e-9) * self.spec.vol_step
        if lots < self.spec.vol_min - 1e-12:
            return 0.0
        return round(lots, 8)

    def _pnl(self, direction: int, entry: float, exit_: float, lots: float) -> float:
        gross = (exit_ - entry) * direction * lots * self.spec.value_per_price_unit
        return gross - self.spec.commission_per_lot * lots

    # ------------------------------------------------------------------
    def run(self, m15: pd.DataFrame) -> dict:
        p, spec, rs = self.p, self.spec, self.risk

        feat = add_touch_flags(build_features(m15, p))
        sig = generate_signals(feat, p, spread_price=spec.spread_price)

        idx = feat.index
        o = feat["open"].to_numpy(float)
        h = feat["high"].to_numpy(float)
        l = feat["low"].to_numpy(float)
        c = feat["close"].to_numpy(float)
        atr_arr = feat["atr"].to_numpy(float)

        s_dir = sig["dir"].to_numpy(float)
        s_sl = sig["sl"].to_numpy(float)
        s_tp = sig["tp"].to_numpy(float)
        s_setup = sig["setup"].to_numpy(float)
        s_score = sig["score"].to_numpy(float)

        in_london = feat["in_london"].to_numpy(bool)
        in_ny = feat["in_ny"].to_numpy(bool)
        hours = idx.hour.to_numpy()
        dows = idx.dayofweek.to_numpy()
        days = idx.normalize()
        weeks = idx.to_period("W")

        balance = self.initial_balance
        peak_equity = balance
        equity_curve = np.empty(len(idx))
        trades: list[Trade] = []

        pos = None
        day_start_balance = balance
        week_start_balance = balance
        cur_day = days[0]
        cur_week = weeks[0]
        trades_today = 0
        consec_losses = 0
        cooldown_until = None
        halted_day = False
        halted_perm = False
        skipped_small_lot = 0

        for i in range(len(idx)):
            now = idx[i]

            # ---- roll the day / week buckets ---------------------------
            if days[i] != cur_day:
                cur_day = days[i]
                day_start_balance = balance
                trades_today = 0
                halted_day = False
            if weeks[i] != cur_week:
                cur_week = weeks[i]
                week_start_balance = balance

            # ---- manage an open position inside this bar ---------------
            if pos is not None:
                exit_price = None
                reason = ""
                d = pos["dir"]

                hit_sl = (l[i] <= pos["sl"]) if d > 0 else (h[i] >= pos["sl"])
                hit_tp = (h[i] >= pos["tp"]) if d > 0 else (l[i] <= pos["tp"])

                if hit_sl and hit_tp:
                    if self.pessimistic:
                        exit_price, reason = pos["sl"], "sl (ambiguous bar)"
                    else:
                        exit_price, reason = pos["tp"], "tp (ambiguous bar)"
                elif hit_sl:
                    exit_price, reason = pos["sl"], "sl"
                elif hit_tp:
                    exit_price, reason = pos["tp"], "tp"

                # a gap through the level fills at the open, not the level
                if exit_price is not None:
                    if d > 0 and reason.startswith("sl") and o[i] < pos["sl"]:
                        exit_price = o[i]
                        reason = "sl (gap)"
                    if d < 0 and reason.startswith("sl") and o[i] > pos["sl"]:
                        exit_price = o[i]
                        reason = "sl (gap)"
                    if d > 0 and reason.startswith("tp") and o[i] > pos["tp"]:
                        exit_price = o[i]
                    if d < 0 and reason.startswith("tp") and o[i] < pos["tp"]:
                        exit_price = o[i]

                # Friday flat-out overrides anything still open
                if exit_price is None and dows[i] == 4 and hours[i] >= p.friday_close_hour_gmt:
                    exit_price, reason = c[i], "friday close"

                # time stop
                if exit_price is None and rs.time_stop_bars > 0:
                    held = i - pos["bar"]
                    r_now = ((c[i] - pos["entry"]) * d) / pos["risk"]
                    if held >= rs.time_stop_bars and r_now < rs.time_stop_min_r:
                        exit_price, reason = c[i], "time stop"

                if exit_price is not None:
                    slip = spec.slippage_price if reason.startswith("sl") else 0.0
                    fill = exit_price - slip * d
                    # closing a long sells at bid, closing a short buys at ask
                    if d < 0:
                        fill += spec.spread_price
                    pnl = self._pnl(d, pos["entry"], fill, pos["lots"])
                    balance += pnl
                    r_mult = pnl / pos["risk_money"] if pos["risk_money"] > 0 else 0.0

                    trades.append(Trade(
                        entry_time=pos["time"], exit_time=now, direction=d,
                        setup=int(pos["setup"]), entry=pos["entry"], exit=fill,
                        sl=pos["sl"], tp=pos["tp"], lots=pos["lots"],
                        risk_price=pos["risk"], r_multiple=r_mult, pnl=pnl,
                        reason=reason, score=pos["score"], balance_after=balance,
                    ))

                    if pnl < 0:
                        consec_losses += 1
                        if rs.max_consec_losses > 0 and consec_losses >= rs.max_consec_losses:
                            cooldown_until = now + pd.Timedelta(minutes=rs.cooldown_minutes)
                    else:
                        consec_losses = 0
                    pos = None
                else:
                    # break-even and trailing, evaluated on the bar close
                    r_now = ((c[i] - pos["entry"]) * d) / pos["risk"]
                    new_sl = pos["sl"]
                    if rs.break_even_at_r > 0 and r_now >= rs.break_even_at_r:
                        be = pos["entry"] + d * rs.break_even_offset_r * pos["risk"]
                        new_sl = max(new_sl, be) if d > 0 else min(new_sl, be)
                    if rs.trail_start_r > 0 and r_now >= rs.trail_start_r and np.isfinite(atr_arr[i]):
                        tr = c[i] - d * rs.trail_atr_mult * atr_arr[i]
                        new_sl = max(new_sl, tr) if d > 0 else min(new_sl, tr)
                    pos["sl"] = new_sl

            # ---- mark to market ----------------------------------------
            floating = 0.0
            if pos is not None:
                floating = self._pnl(pos["dir"], pos["entry"], c[i], pos["lots"])
            equity = balance + floating
            equity_curve[i] = equity
            peak_equity = max(peak_equity, equity)

            if rs.max_drawdown_pct > 0 and peak_equity > 0:
                dd = 100.0 * (peak_equity - equity) / peak_equity
                if dd >= rs.max_drawdown_pct:
                    halted_perm = True

            # ---- consider a new entry ----------------------------------
            if halted_perm or pos is not None or i + 1 >= len(idx):
                continue
            if s_dir[i] == 0:
                continue
            if halted_day:
                continue
            if dows[i] == 4 and hours[i] >= p.friday_close_hour_gmt:
                continue
            if p.use_session_filter and not (in_london[i] or in_ny[i]):
                continue
            if rs.max_trades_per_day > 0 and trades_today >= rs.max_trades_per_day:
                continue
            if cooldown_until is not None and now < cooldown_until:
                continue

            day_pnl = balance - day_start_balance
            if rs.daily_loss_limit_pct > 0 and day_start_balance > 0:
                if day_pnl <= -day_start_balance * rs.daily_loss_limit_pct / 100.0:
                    halted_day = True
                    continue
            week_pnl = balance - week_start_balance
            if rs.weekly_loss_limit_pct > 0 and week_start_balance > 0:
                if week_pnl <= -week_start_balance * rs.weekly_loss_limit_pct / 100.0:
                    continue

            # fill at the next bar's open, paying spread and slippage
            d = int(s_dir[i])
            raw_open = o[i + 1]
            fill = raw_open + d * (spec.spread_price if d > 0 else 0.0) + d * spec.slippage_price

            sl, tp = s_sl[i], s_tp[i]
            risk_price = abs(fill - sl)
            if risk_price <= 0:
                continue
            # keep the R multiple honest after slippage moved the entry
            tp = fill + d * p.reward_r * risk_price

            lots = self._lots_for(balance, risk_price)
            if lots <= 0:
                skipped_small_lot += 1
                continue

            risk_money = risk_price * spec.value_per_price_unit * lots
            pos = {
                "dir": d, "entry": fill, "sl": sl, "tp": tp, "lots": lots,
                "risk": risk_price, "risk_money": risk_money,
                "time": idx[i + 1], "bar": i + 1,
                "setup": s_setup[i], "score": s_score[i],
            }
            trades_today += 1

        eq = pd.Series(equity_curve, index=idx, name="equity")
        tdf = pd.DataFrame([t.__dict__ for t in trades])
        return {
            "trades": tdf,
            "equity": eq,
            "final_balance": balance,
            "initial_balance": self.initial_balance,
            "skipped_small_lot": skipped_small_lot,
            "halted": halted_perm,
        }
