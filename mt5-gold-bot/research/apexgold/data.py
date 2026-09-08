"""Loading price history, and a synthetic generator for plumbing tests.

The synthetic series exists so the whole pipeline can be exercised without
a broker export. It is NOT evidence of an edge: numbers produced on
synthetic data say only that the code runs, never that the strategy works.
"""

from __future__ import annotations

from pathlib import Path

import numpy as np
import pandas as pd

REQUIRED = ["open", "high", "low", "close"]


def load_csv(path: str | Path, tz_shift_hours: int = 0) -> pd.DataFrame:
    """Read a MetaTrader export or a generic OHLC csv into a UTC-indexed frame.

    Handles the two shapes people actually have:
      * MT5 "Save as file" export - tab separated, <DATE> <TIME> <OPEN> ...
      * generic csv with a time/date column and open/high/low/close columns

    `tz_shift_hours` subtracts the broker's GMT offset so the index is GMT,
    which is what every session rule in this project assumes.
    """
    path = Path(path)
    sep = "\t" if path.suffix.lower() in {".tsv", ".txt"} else None
    raw = pd.read_csv(path, sep=sep, engine="python")

    cols = {c: c.strip().strip("<>").lower() for c in raw.columns}
    raw = raw.rename(columns=cols)

    if "date" in raw.columns and "time" in raw.columns:
        stamp = pd.to_datetime(raw["date"].astype(str) + " " + raw["time"].astype(str),
                               format="mixed", dayfirst=False)
    elif "time" in raw.columns:
        stamp = pd.to_datetime(raw["time"], format="mixed")
    elif "datetime" in raw.columns:
        stamp = pd.to_datetime(raw["datetime"], format="mixed")
    else:
        stamp = pd.to_datetime(raw.iloc[:, 0], format="mixed")

    df = pd.DataFrame(index=pd.DatetimeIndex(stamp))
    for col in REQUIRED:
        if col not in raw.columns:
            raise ValueError(f"column '{col}' missing from {path.name}")
        df[col] = pd.to_numeric(raw[col].values, errors="coerce")

    if "tickvol" in raw.columns:
        df["volume"] = pd.to_numeric(raw["tickvol"].values, errors="coerce")
    elif "volume" in raw.columns:
        df["volume"] = pd.to_numeric(raw["volume"].values, errors="coerce")
    else:
        df["volume"] = 0.0

    if "spread" in raw.columns:
        df["spread"] = pd.to_numeric(raw["spread"].values, errors="coerce")

    df = df.dropna(subset=REQUIRED).sort_index()
    df = df[~df.index.duplicated(keep="last")]

    if tz_shift_hours:
        df.index = df.index - pd.Timedelta(hours=tz_shift_hours)
    df.index.name = "time"
    return df


def resample(df: pd.DataFrame, rule: str) -> pd.DataFrame:
    """Aggregate to a higher timeframe, dropping incomplete buckets."""
    agg = {"open": "first", "high": "max", "low": "min", "close": "last"}
    if "volume" in df.columns:
        agg["volume"] = "sum"
    out = df.resample(rule, label="left", closed="left").agg(agg).dropna(subset=["open"])
    return out


def synthetic(
    bars: int = 40_000,
    start: str = "2021-01-04 00:00",
    freq: str = "15min",
    seed: int = 7,
    start_price: float = 1800.0,
) -> pd.DataFrame:
    """Regime-switching synthetic gold series with volatility clustering.

    Three hidden states (trend up, trend down, range) with sticky
    transitions, a GARCH-like volatility process, and an intraday
    seasonality bump across the London and New York hours. Weekends are
    removed so the session logic sees a realistic calendar.
    """
    rng = np.random.default_rng(seed)
    idx = pd.date_range(start=start, periods=int(bars * 1.45), freq=freq)
    idx = idx[idx.dayofweek < 5]
    idx = idx[:bars]
    n = len(idx)

    # hidden regime chain: mostly persistent
    trans = np.array([[0.9970, 0.0005, 0.0025],
                      [0.0005, 0.9970, 0.0025],
                      [0.0015, 0.0015, 0.9970]])
    states = np.zeros(n, dtype=int)
    states[0] = 2
    for i in range(1, n):
        states[i] = rng.choice(3, p=trans[states[i - 1]])

    drift = np.array([0.9, -0.9, 0.0])[states] * 1e-5

    # intraday volatility seasonality, peaking over the London/NY overlap
    hour = idx.hour.to_numpy()
    season = 0.55 + 0.85 * np.exp(-0.5 * ((hour - 14.0) / 4.0) ** 2) \
                  + 0.35 * np.exp(-0.5 * ((hour - 8.0) / 2.5) ** 2)

    # GARCH(1,1)-ish variance so quiet and violent stretches cluster
    omega, alpha, beta = 2.0e-9, 0.07, 0.90
    var = np.zeros(n)
    var[0] = omega / max(1e-12, (1 - alpha - beta))
    shock = rng.standard_normal(n)
    ret = np.zeros(n)
    for i in range(1, n):
        var[i] = omega + alpha * ret[i - 1] ** 2 + beta * var[i - 1]
        ret[i] = drift[i] + np.sqrt(var[i]) * season[i] * shock[i]

    close = start_price * np.exp(np.cumsum(ret))

    # build bars: open at the previous close, wick proportional to bar volatility
    open_ = np.concatenate([[start_price], close[:-1]])
    body_vol = np.abs(close - open_)
    wick = (np.sqrt(var) * season * close) * rng.uniform(0.4, 1.6, n)
    high = np.maximum(open_, close) + wick * rng.uniform(0.2, 1.0, n)
    low = np.minimum(open_, close) - wick * rng.uniform(0.2, 1.0, n)

    df = pd.DataFrame(
        {"open": open_, "high": high, "low": low, "close": close,
         "volume": (body_vol / body_vol.mean() * 500).round()},
        index=idx,
    )
    df.index.name = "time"
    return df.round(2)
