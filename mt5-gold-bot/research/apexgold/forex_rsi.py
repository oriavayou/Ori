"""RSI Stretch: daily mean reversion on FX pairs, ported from the spec.

Rules implemented exactly as written in the source document:

    entry long   RSI-14 (Cutler) < 35
    entry short  RSI-14 (Cutler) > 65
    entry price  the close of the bar that triggered
    target       1.0 x ATR-14 (simple mean) from entry
    stop         1.0 x ATR-14 from entry
    expiry       15 calendar days
    settlement   per bar after entry, priority expiry -> stop -> target
    lock         one open signal per pair at a time

Two settlement modes are provided. `spec` is the document's engine
verbatim. `corrected` checks the levels before declaring expiry on the
same bar, which is the difference that turns an expiry into a result.

`skip_bars` models the publication-lag guard from section 6 of the spec:
bars whose price action is considered to predate publication are not
examined. It exists so the observed expiry rate can be reproduced and
attributed, rather than argued about.
"""

from __future__ import annotations

from dataclasses import dataclass

import numpy as np
import pandas as pd

from . import indicators as ind

LONG, SHORT = 1, -1

OUTCOME_TARGET = "target"
OUTCOME_STOP = "stopped"
OUTCOME_EXPIRED = "expired"
OUTCOME_OPEN = "open"


@dataclass
class RsiStretchParams:
    rsi_period: int = 14
    atr_period: int = 14
    long_below: float = 35.0
    short_above: float = 65.0
    strong_long_below: float = 30.0
    strong_short_above: float = 70.0

    target_atr: float = 1.0
    stop_atr: float = 1.0
    expiry_days: int = 15
    min_history: int = 60

    # settlement behaviour
    mode: str = "spec"          # "spec" or "corrected"
    skip_bars: int = 0          # bars after entry ignored, models publication lag
    stop_wins_ties: bool = True

    # confidence score inputs, reporting only, they do not filter entries
    sma_fast: int = 20
    sma_slow: int = 50


def build_features(bars: pd.DataFrame, p: RsiStretchParams) -> pd.DataFrame:
    """Attach the indicators the rules read. Daily bars in, daily bars out."""
    df = bars.copy()
    df["rsi"] = ind.cutler_rsi(df["close"], p.rsi_period)
    df["atr"] = ind.sma_atr(df, p.atr_period)
    df["sma_fast"] = df["close"].rolling(p.sma_fast).mean()
    df["sma_slow"] = df["close"].rolling(p.sma_slow).mean()
    df["sma_slow_slope"] = df["sma_slow"].diff(5)
    return df


def _confidence(rsi_value: float, direction: int, row, p: RsiStretchParams) -> int:
    strong = (rsi_value < p.strong_long_below) if direction == LONG else (rsi_value > p.strong_short_above)
    with_trend = False
    if np.isfinite(row["sma_fast"]) and np.isfinite(row["sma_slow"]) and np.isfinite(row["sma_slow_slope"]):
        if direction == LONG:
            with_trend = row["sma_fast"] > row["sma_slow"] and row["sma_slow_slope"] > 0
        else:
            with_trend = row["sma_fast"] < row["sma_slow"] and row["sma_slow_slope"] < 0
    return int(min(3, 2 + int(strong) + int(with_trend)))


def settle_one(bars: pd.DataFrame, entry_idx: int, direction: int,
               entry: float, stop: float, target: float,
               p: RsiStretchParams) -> dict:
    """Walk forward from the bar after entry and resolve the signal."""
    risk = abs(entry - stop)
    entry_time = bars.index[entry_idx]
    deadline = entry_time + pd.Timedelta(days=p.expiry_days)

    first = entry_idx + 1 + p.skip_bars
    for j in range(first, len(bars)):
        bar = bars.iloc[j]
        t = bars.index[j]

        hit_stop = (bar["low"] <= stop) if direction == LONG else (bar["high"] >= stop)
        hit_target = (bar["high"] >= target) if direction == LONG else (bar["low"] <= target)
        expired = t > deadline

        if p.mode == "spec":
            # expiry is evaluated before the levels, exactly as documented
            if expired:
                r = ((bar["close"] - entry) if direction == LONG else (entry - bar["close"])) / risk
                return {"outcome": OUTCOME_EXPIRED, "r": float(r), "exit_idx": j,
                        "exit_time": t, "exit_price": float(bar["close"])}
            if hit_stop and p.stop_wins_ties:
                return {"outcome": OUTCOME_STOP, "r": -1.0, "exit_idx": j,
                        "exit_time": t, "exit_price": float(stop)}
            if hit_target:
                return {"outcome": OUTCOME_TARGET, "r": 1.0, "exit_idx": j,
                        "exit_time": t, "exit_price": float(target)}
            if hit_stop:
                return {"outcome": OUTCOME_STOP, "r": -1.0, "exit_idx": j,
                        "exit_time": t, "exit_price": float(stop)}
        else:
            # levels first: a bar that reaches a level resolved the trade,
            # whether or not that bar also crossed the expiry date
            if hit_stop and (p.stop_wins_ties or not hit_target):
                return {"outcome": OUTCOME_STOP, "r": -1.0, "exit_idx": j,
                        "exit_time": t, "exit_price": float(stop)}
            if hit_target:
                return {"outcome": OUTCOME_TARGET, "r": 1.0, "exit_idx": j,
                        "exit_time": t, "exit_price": float(target)}
            if expired:
                r = ((bar["close"] - entry) if direction == LONG else (entry - bar["close"])) / risk
                return {"outcome": OUTCOME_EXPIRED, "r": float(r), "exit_idx": j,
                        "exit_time": t, "exit_price": float(bar["close"])}

    return {"outcome": OUTCOME_OPEN, "r": 0.0, "exit_idx": len(bars) - 1,
            "exit_time": bars.index[-1], "exit_price": float(bars.iloc[-1]["close"])}


def run_pair(bars: pd.DataFrame, symbol: str, p: RsiStretchParams,
             digits: int = 5) -> pd.DataFrame:
    """Generate and settle every signal for one pair. One open signal at a time."""
    df = build_features(bars, p)
    rows = []
    blocked_until = -1

    for i in range(p.min_history, len(df)):
        if i <= blocked_until:
            continue

        rsi_value = df["rsi"].iat[i]
        atr_value = df["atr"].iat[i]
        if not np.isfinite(rsi_value) or not np.isfinite(atr_value) or atr_value <= 0:
            continue

        if rsi_value < p.long_below:
            direction = LONG
        elif rsi_value > p.short_above:
            direction = SHORT
        else:
            continue

        entry = float(df["close"].iat[i])
        target = entry + direction * p.target_atr * atr_value
        stop = entry - direction * p.stop_atr * atr_value

        entry = round(entry, digits)
        target = round(target, digits)
        stop = round(stop, digits)

        risk = abs(entry - stop)
        if risk <= 0:
            continue
        # the spec's ordering sanity check
        ordered = (stop < entry < target) if direction == LONG else (target < entry < stop)
        if not ordered:
            continue

        res = settle_one(df, i, direction, entry, stop, target, p)
        rows.append({
            "symbol": symbol,
            "entry_time": df.index[i],
            "direction": direction,
            "rsi": float(rsi_value),
            "atr": float(atr_value),
            "entry": entry, "stop": stop, "target": target,
            "risk": risk,
            "confidence": _confidence(rsi_value, direction, df.iloc[i], p),
            "outcome": res["outcome"],
            "r": res["r"],
            "exit_time": res["exit_time"],
            "exit_price": res["exit_price"],
            "bars_held": res["exit_idx"] - i,
        })
        blocked_until = res["exit_idx"]

    return pd.DataFrame(rows)


def run_portfolio(data: dict, p: RsiStretchParams, digits: int = 5) -> pd.DataFrame:
    """Run every pair and stack the results into one signal ledger."""
    frames = [run_pair(bars, symbol, p, digits) for symbol, bars in data.items()]
    frames = [f for f in frames if not f.empty]
    if not frames:
        return pd.DataFrame()
    out = pd.concat(frames, ignore_index=True)
    return out.sort_values("entry_time").reset_index(drop=True)


def summarise(signals: pd.DataFrame) -> dict:
    """Headline numbers, using the spec's own definition of hit rate."""
    if signals.empty:
        return {"signals": 0}

    decided = signals[signals["outcome"].isin([OUTCOME_TARGET, OUTCOME_STOP])]
    expired = signals[signals["outcome"] == OUTCOME_EXPIRED]
    n_targets = int((signals["outcome"] == OUTCOME_TARGET).sum())
    n_stops = int((signals["outcome"] == OUTCOME_STOP).sum())

    span_days = max((signals["entry_time"].max() - signals["entry_time"].min()).days, 1)
    months = span_days / 30.4

    return {
        "signals": int(len(signals)),
        "targets": n_targets,
        "stops": n_stops,
        "expired": int(len(expired)),
        "open": int((signals["outcome"] == OUTCOME_OPEN).sum()),
        "hit_rate": 100.0 * n_targets / max(n_targets + n_stops, 1),
        "decision_rate": 100.0 * len(decided) / len(signals),
        "expiry_rate": 100.0 * len(expired) / len(signals),
        "total_r": float(signals["r"].sum()),
        "r_from_decided": float(decided["r"].sum()) if len(decided) else 0.0,
        "r_from_expired": float(expired["r"].sum()) if len(expired) else 0.0,
        "r_per_month": float(signals["r"].sum()) / months,
        "expectancy_r": float(signals["r"].mean()),
        "median_bars_held": float(signals["bars_held"].median()),
        "months": months,
    }
