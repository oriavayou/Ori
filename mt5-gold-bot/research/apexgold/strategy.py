"""Python port of the ApexGold MQL5 signal engine.

Every rule here mirrors MQL5/Include/ApexGold/Signals.mqh and Market.mqh.
When one side changes the other must change with it, otherwise the
backtest stops describing the thing that will actually trade.

No-lookahead discipline
-----------------------
A decision on row i uses only bars up to and including i, and the
backtester fills it at the open of row i+1. Higher timeframe values are
attached with merge_asof against the higher timeframe bar's CLOSE time,
so an H4 bar that is still forming is never visible.
"""

from __future__ import annotations

from dataclasses import dataclass, field

import numpy as np
import pandas as pd

from . import indicators as ind
from .data import resample

EMA_FAST, EMA_SLOW, EMA_BASE = 20, 50, 200
ATR_PERIOD = ADX_PERIOD = RSI_PERIOD = 14
VOL_WINDOW = 120
SWING_STRENGTH = 2
BOS_LOOKBACK = 40
SWEEP_LOOKBACK = 6
COMPRESS_BARS = 12

LONG, SHORT, FLAT = 1, -1, 0
SETUP_NAMES = {0: "none", 1: "pullback", 2: "sweep", 3: "breakout"}


@dataclass
class Params:
    """Mirror of the EA inputs that affect signal generation."""

    reward_r: float = 3.0

    tf_context: str = "1h"
    tf_bias: str = "4h"

    adx_trend_min: float = 22.0
    adx_range_max: float = 18.0
    min_score: float = 62.0

    atr_sl_mult: float = 0.35
    min_stop_atr_mult: float = 0.60
    max_stop_atr_mult: float = 2.50

    use_session_filter: bool = True
    asia_start_gmt: int = 0
    asia_end_gmt: int = 7
    london_start_gmt: int = 7
    london_end_gmt: int = 16
    ny_start_gmt: int = 12
    ny_end_gmt: int = 20
    friday_close_hour_gmt: int = 19

    allow_longs: bool = True
    allow_shorts: bool = True
    strategies: tuple = ("pullback", "sweep", "breakout")

    # execution assumptions used when validating a candidate
    max_spread_vs_risk: float = 0.10


def _in_window(hour: np.ndarray, start: int, end: int) -> np.ndarray:
    if start == end:
        return np.zeros_like(hour, dtype=bool)
    if start < end:
        return (hour >= start) & (hour < end)
    return (hour >= start) | (hour < end)


def _merge_htf(base: pd.DataFrame, htf: pd.DataFrame, rule: str, prefix: str) -> pd.DataFrame:
    """Attach higher timeframe columns using only bars that have closed."""
    period = pd.tseries.frequencies.to_offset(rule)
    htf = htf.copy()
    htf["_close_time"] = htf.index + period
    htf = htf.sort_values("_close_time")

    merged = pd.merge_asof(
        base.reset_index().sort_values("time"),
        htf.reset_index(drop=True).sort_values("_close_time"),
        left_on="time",
        right_on="_close_time",
        direction="backward",
        allow_exact_matches=True,
        suffixes=("", f"_{prefix}"),
    )
    merged = merged.set_index("time")
    return merged.drop(columns=["_close_time"])


def _session_day(index: pd.DatetimeIndex, start: int, end: int) -> pd.Series:
    """Label each bar with the calendar day its session block belongs to."""
    day = pd.Series(index.normalize(), index=index)
    if start >= end:  # window wraps past midnight
        wrap = index.hour >= start
        day = day.where(~wrap, day + pd.Timedelta(days=1))
    return day


def build_features(m15: pd.DataFrame, p: Params) -> pd.DataFrame:
    """Compute every column the signal rules read."""
    df = m15.copy()

    # --- entry timeframe -------------------------------------------------
    df["ema_f"] = ind.ema(df["close"], EMA_FAST)
    df["ema_s"] = ind.ema(df["close"], EMA_SLOW)
    df["ema_b"] = ind.ema(df["close"], EMA_BASE)
    df["atr"] = ind.atr(df, ATR_PERIOD)
    df["rsi"] = ind.rsi(df["close"], RSI_PERIOD)

    df["body"] = (df["close"] - df["open"]).abs()
    df["bar_range"] = df["high"] - df["low"]
    df["is_bull"] = df["close"] > df["open"]
    df["is_bear"] = df["close"] < df["open"]
    body_top = df[["open", "close"]].max(axis=1)
    body_bot = df[["open", "close"]].min(axis=1)
    df["upper_wick"] = df["high"] - body_top
    df["lower_wick"] = body_bot - df["low"]

    # --- structure -------------------------------------------------------
    sw_hi = ind.swing_high(df["high"], SWING_STRENGTH)
    sw_lo = ind.swing_low(df["low"], SWING_STRENGTH)
    df["last_swing_high"] = df["high"].where(sw_hi).ffill()
    df["last_swing_low"] = df["low"].where(sw_lo).ffill()

    broke_up = df["close"] > df["last_swing_high"]
    broke_dn = df["close"] < df["last_swing_low"]
    df["bos_up"] = broke_up.rolling(BOS_LOOKBACK, min_periods=1).max().astype(bool)
    df["bos_dn"] = broke_dn.rolling(BOS_LOOKBACK, min_periods=1).max().astype(bool)

    # stop reference: the protective swing, falling back to a short extreme
    df["stop_ref_long"] = np.minimum(
        df["last_swing_low"].fillna(df["low"].rolling(6, min_periods=1).min()),
        df["low"].rolling(3, min_periods=1).min(),
    )
    df["stop_ref_short"] = np.maximum(
        df["last_swing_high"].fillna(df["high"].rolling(6, min_periods=1).max()),
        df["high"].rolling(3, min_periods=1).max(),
    )

    df["hh60"] = df["high"].rolling(60, min_periods=10).max()
    df["ll60"] = df["low"].rolling(60, min_periods=10).min()

    # --- compression range formed before the trigger bar -----------------
    df["range_hi"] = df["high"].rolling(COMPRESS_BARS, min_periods=COMPRESS_BARS).max().shift(1)
    df["range_lo"] = df["low"].rolling(COMPRESS_BARS, min_periods=COMPRESS_BARS).min().shift(1)

    # --- session clocks --------------------------------------------------
    hour = df.index.hour.to_numpy()
    df["in_asia"] = _in_window(hour, p.asia_start_gmt, p.asia_end_gmt)
    df["in_london"] = _in_window(hour, p.london_start_gmt, p.london_end_gmt)
    df["in_ny"] = _in_window(hour, p.ny_start_gmt, p.ny_end_gmt)
    df["in_overlap"] = df["in_london"] & df["in_ny"]

    # --- Asian range, visible only after the Asian window closes ---------
    sday = _session_day(df.index, p.asia_start_gmt, p.asia_end_gmt)
    asia = df.loc[df["in_asia"].values]
    if len(asia):
        aday = _session_day(asia.index, p.asia_start_gmt, p.asia_end_gmt)
        grp_hi = asia["high"].groupby(aday.values).max()
        grp_lo = asia["low"].groupby(aday.values).min()
        df["asia_high"] = pd.Series(sday.map(grp_hi).values, index=df.index)
        df["asia_low"] = pd.Series(sday.map(grp_lo).values, index=df.index)
    else:
        df["asia_high"] = np.nan
        df["asia_low"] = np.nan
    df.loc[df["in_asia"].values, ["asia_high", "asia_low"]] = np.nan

    df["sweep_low"] = df["low"].rolling(SWEEP_LOOKBACK, min_periods=1).min()
    df["sweep_high"] = df["high"].rolling(SWEEP_LOOKBACK, min_periods=1).max()

    # --- context timeframe ----------------------------------------------
    ctx = resample(m15, p.tf_context)
    ctx_feat = pd.DataFrame(index=ctx.index)
    ctx_feat["ctx_ema_f"] = ind.ema(ctx["close"], EMA_FAST)
    ctx_feat["ctx_ema_s"] = ind.ema(ctx["close"], EMA_SLOW)
    ctx_feat["ctx_close"] = ctx["close"]
    ctx_feat["ctx_atr"] = ind.atr(ctx, ATR_PERIOD)
    adx_ctx = ind.adx(ctx, ADX_PERIOD)
    ctx_feat["ctx_adx"] = adx_ctx["adx"]
    ctx_feat["ctx_plus"] = adx_ctx["plus_di"]
    ctx_feat["ctx_minus"] = adx_ctx["minus_di"]
    ctx_feat["ctx_adx_prev2"] = adx_ctx["adx"].shift(2)
    ctx_feat["atr_pct"] = ind.rolling_percentile_rank(ctx_feat["ctx_atr"], VOL_WINDOW)

    # --- bias timeframe --------------------------------------------------
    bias = resample(m15, p.tf_bias)
    bias_feat = pd.DataFrame(index=bias.index)
    bias_feat["bias_ema_f"] = ind.ema(bias["close"], EMA_FAST)
    bias_feat["bias_ema_s"] = ind.ema(bias["close"], EMA_SLOW)
    bias_feat["bias_ema_b"] = ind.ema(bias["close"], EMA_BASE)
    bias_feat["bias_ema_b_prev"] = bias_feat["bias_ema_b"].shift(10)
    bias_feat["bias_close"] = bias["close"]

    df = _merge_htf(df, ctx_feat, p.tf_context, "ctx")
    df = _merge_htf(df, bias_feat, p.tf_bias, "bias")

    # --- derived regime / bias / volatility state ------------------------
    slope_up = df["bias_ema_b"] > df["bias_ema_b_prev"]
    slope_dn = df["bias_ema_b"] < df["bias_ema_b_prev"]
    stack_up = (df["bias_ema_f"] > df["bias_ema_s"]) & (df["bias_ema_s"] > df["bias_ema_b"]) & (df["bias_close"] > df["bias_ema_s"])
    stack_dn = (df["bias_ema_f"] < df["bias_ema_s"]) & (df["bias_ema_s"] < df["bias_ema_b"]) & (df["bias_close"] < df["bias_ema_s"])
    soft_up = (df["bias_ema_f"] > df["bias_ema_s"]) & (df["bias_close"] > df["bias_ema_b"])
    soft_dn = (df["bias_ema_f"] < df["bias_ema_s"]) & (df["bias_close"] < df["bias_ema_b"])

    bias_dir = np.where((stack_up | soft_up) & slope_up, LONG,
                np.where((stack_dn | soft_dn) & slope_dn, SHORT, FLAT))
    df["bias_dir"] = bias_dir

    trending = df["ctx_adx"] >= p.adx_trend_min
    ranging = df["ctx_adx"] <= p.adx_range_max
    ctx_up = (df["ctx_ema_f"] > df["ctx_ema_s"]) & (df["ctx_close"] > df["ctx_ema_s"])
    ctx_dn = (df["ctx_ema_f"] < df["ctx_ema_s"]) & (df["ctx_close"] < df["ctx_ema_s"])
    df["ctx_up"] = ctx_up
    df["ctx_dn"] = ctx_dn

    regime = np.where(trending & ctx_up & (df["ctx_plus"] > df["ctx_minus"]), 1,
              np.where(trending & ctx_dn & (df["ctx_minus"] > df["ctx_plus"]), 2,
               np.where(ranging, 3, 4)))
    df["regime"] = regime  # 1 up, 2 down, 3 range, 4 chop

    pct = df["atr_pct"]
    df["vol_state"] = np.select(
        [pct < 15.0, pct < 35.0, pct < 75.0, pct < 93.0],
        [0, 1, 2, 3],
        default=4,
    )  # 0 dead, 1 low, 2 normal, 3 high, 4 extreme

    return df


def _score(row, direction: int, setup: int, base: float, entry: float,
           sl: float, tp: float, atr_v: float) -> float:
    """Confluence score, identical in structure to CSignalEngine::Score."""
    sc = base

    if row["bias_dir"] == direction:
        sc += 12.0
    elif row["bias_dir"] == FLAT:
        sc += 2.0
    else:
        sc -= 8.0

    regime = row["regime"]
    if (direction > 0 and regime == 1) or (direction < 0 and regime == 2):
        sc += 8.0
    elif regime == 3 and setup == 2:
        sc += 8.0
    elif regime == 4:
        sc -= 6.0

    vol = row["vol_state"]
    sc += {2: 10.0, 3: 6.0, 1: 2.0}.get(vol, -5.0)

    if row["in_overlap"]:
        sc += 8.0
    elif row["in_london"]:
        sc += 5.0
    elif row["in_ny"]:
        sc += 4.0

    if atr_v > 0:
        body_ratio = row["body"] / atr_v
        if body_ratio > 0.9:
            sc += 8.0
        elif body_ratio > 0.5:
            sc += 4.0

    if row["ctx_adx"] > row["ctx_adx_prev2"]:
        sc += 4.0

    tp_dist = abs(tp - entry)
    room = (row["hh60"] - entry) if direction > 0 else (entry - row["ll60"])
    if room >= tp_dist:
        sc += 6.0
    elif row["bias_dir"] == direction:
        sc += 3.0
    else:
        sc -= 4.0

    if atr_v > 0:
        stretch = abs(entry - row["ema_s"]) / atr_v
        if stretch > 3.0:
            sc -= 10.0
        elif stretch > 2.0:
            sc -= 4.0

    return float(min(max(sc, 0.0), 100.0))


def _build(direction: int, setup: int, raw_stop: float, base: float,
           row, p: Params, entry_price: float, spread_price: float):
    """Apply the stop envelope and project the target. Returns None if rejected."""
    atr_v = row["atr"]
    if not np.isfinite(atr_v) or atr_v <= 0 or not np.isfinite(raw_stop):
        return None

    buffer = p.atr_sl_mult * atr_v
    sl = raw_stop - buffer if direction > 0 else raw_stop + buffer
    risk = abs(entry_price - sl)

    min_risk = p.min_stop_atr_mult * atr_v
    max_risk = p.max_stop_atr_mult * atr_v

    if risk < min_risk:
        sl = entry_price - min_risk if direction > 0 else entry_price + min_risk
        risk = min_risk
    if risk > max_risk:
        return None
    if spread_price > p.max_spread_vs_risk * risk:
        return None

    tp = entry_price + p.reward_r * risk if direction > 0 else entry_price - p.reward_r * risk
    score = _score(row, direction, setup, base, entry_price, sl, tp, atr_v)
    return {"dir": direction, "setup": setup, "sl": sl, "tp": tp,
            "risk": risk, "score": score}


def generate_signals(feat: pd.DataFrame, p: Params, spread_price: float = 0.0) -> pd.DataFrame:
    """One row per decision bar. `dir` of 0 means stand aside.

    The entry price used for construction is the decision bar's close; the
    backtester re-derives the real fill from the next bar's open, which is
    the same relationship the EA has between a closed bar and the market
    order it then sends.
    """
    cols = ["dir", "setup", "sl", "tp", "risk", "score"]
    out = pd.DataFrame(0.0, index=feat.index, columns=cols)

    want_pullback = "pullback" in p.strategies
    want_sweep = "sweep" in p.strategies
    want_breakout = "breakout" in p.strategies

    records = feat.to_dict("records")
    times = feat.index

    results = []
    for i, row in enumerate(records):
        atr_v = row["atr"]
        if not np.isfinite(atr_v) or atr_v <= 0 or not np.isfinite(row.get("ctx_adx", np.nan)):
            results.append(None)
            continue

        vol = row["vol_state"]
        if vol in (0, 4):
            results.append(None)
            continue

        regime = row["regime"]
        p_ok, s_ok, b_ok = want_pullback, want_sweep, want_breakout
        if regime == 4:
            results.append(None)
            continue
        if regime == 3:
            p_ok = False

        entry = row["close"]
        best = None

        # --- setup A: trend pullback continuation ------------------------
        if p_ok:
            if (p.allow_longs and row["bias_dir"] >= 0 and row["ctx_up"]
                    and row["ema_f"] > row["ema_s"]
                    and row["touch_long"] and row["is_bull"] and entry > row["ema_f"]
                    and row["body"] > 0.25 * atr_v
                    and 40.0 < row["rsi"] < 72.0 and row["bos_up"]):
                best = _build(LONG, 1, row["stop_ref_long"], 40.0, row, p, entry, spread_price)

            if (p.allow_shorts and row["bias_dir"] <= 0 and row["ctx_dn"]
                    and row["ema_f"] < row["ema_s"]
                    and row["touch_short"] and row["is_bear"] and entry < row["ema_f"]
                    and row["body"] > 0.25 * atr_v
                    and 28.0 < row["rsi"] < 60.0 and row["bos_dn"]):
                cand = _build(SHORT, 1, row["stop_ref_short"], 40.0, row, p, entry, spread_price)
                if cand and (best is None or cand["score"] > best["score"]):
                    best = cand

        # --- setup B: Asian range liquidity sweep ------------------------
        if s_ok and (row["in_london"] or row["in_ny"]):
            a_hi, a_lo = row["asia_high"], row["asia_low"]
            ctx_atr = row["ctx_atr"]
            if np.isfinite(a_hi) and np.isfinite(a_lo) and np.isfinite(ctx_atr) and ctx_atr > 0:
                width = a_hi - a_lo
                if 0.25 * ctx_atr <= width <= 3.0 * ctx_atr:
                    min_sweep, max_sweep = 0.10 * atr_v, 1.20 * atr_v

                    if p.allow_longs:
                        depth = a_lo - row["sweep_low"]
                        if (depth > min_sweep and depth <= max_sweep
                                and entry > a_lo
                                and (row["is_bull"] or row["lower_wick"] > 0.5 * row["bar_range"])):
                            cand = _build(LONG, 2, row["sweep_low"], 40.0, row, p, entry, spread_price)
                            if cand and (best is None or cand["score"] > best["score"]):
                                best = cand

                    if p.allow_shorts:
                        depth = row["sweep_high"] - a_hi
                        if (depth > min_sweep and depth <= max_sweep
                                and entry < a_hi
                                and (row["is_bear"] or row["upper_wick"] > 0.5 * row["bar_range"])):
                            cand = _build(SHORT, 2, row["sweep_high"], 40.0, row, p, entry, spread_price)
                            if cand and (best is None or cand["score"] > best["score"]):
                                best = cand

        # --- setup C: compression breakout -------------------------------
        if b_ok:
            hi, lo = row["range_hi"], row["range_lo"]
            if np.isfinite(hi) and np.isfinite(lo) and (hi - lo) > 0 and (hi - lo) <= 2.2 * atr_v:
                strong = row["body"] > 0.55 * atr_v
                if p.allow_longs and entry > hi and strong and row["is_bull"] and row["bias_dir"] >= 0:
                    cand = _build(LONG, 3, lo, 38.0, row, p, entry, spread_price)
                    if cand and (best is None or cand["score"] > best["score"]):
                        best = cand
                if p.allow_shorts and entry < lo and strong and row["is_bear"] and row["bias_dir"] <= 0:
                    cand = _build(SHORT, 3, hi, 38.0, row, p, entry, spread_price)
                    if cand and (best is None or cand["score"] > best["score"]):
                        best = cand

        if best is not None and best["score"] < p.min_score:
            best = None
        results.append(best)

    for i, r in enumerate(results):
        if r is None:
            continue
        out.iat[i, 0] = r["dir"]
        out.iat[i, 1] = r["setup"]
        out.iat[i, 2] = r["sl"]
        out.iat[i, 3] = r["tp"]
        out.iat[i, 4] = r["risk"]
        out.iat[i, 5] = r["score"]

    return out


def add_touch_flags(feat: pd.DataFrame) -> pd.DataFrame:
    """Did price visit the moving-average value zone in the last four bars?"""
    band = 0.25 * feat["atr"]
    feat["touch_long"] = (feat["low"] <= feat["ema_f"] + band).rolling(4, min_periods=1).max().astype(bool)
    feat["touch_short"] = (feat["high"] >= feat["ema_f"] - band).rolling(4, min_periods=1).max().astype(bool)
    return feat
