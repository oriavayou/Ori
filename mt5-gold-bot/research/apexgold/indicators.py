"""Indicator implementations that match MetaTrader's built-ins.

MetaTrader uses Wilder smoothing for ATR, ADX and RSI, which is an EMA
with alpha = 1/period rather than 2/(period+1). Getting this wrong makes
the Python results drift away from the terminal, so it is done
explicitly here.
"""

from __future__ import annotations

import numpy as np
import pandas as pd


def ema(series: pd.Series, period: int) -> pd.Series:
    return series.ewm(span=period, adjust=False).mean()


def wilder(series: pd.Series, period: int) -> pd.Series:
    return series.ewm(alpha=1.0 / period, adjust=False).mean()


def true_range(df: pd.DataFrame) -> pd.Series:
    prev_close = df["close"].shift(1)
    a = df["high"] - df["low"]
    b = (df["high"] - prev_close).abs()
    c = (df["low"] - prev_close).abs()
    return pd.concat([a, b, c], axis=1).max(axis=1)


def atr(df: pd.DataFrame, period: int = 14) -> pd.Series:
    return wilder(true_range(df), period)


def rsi(series: pd.Series, period: int = 14) -> pd.Series:
    delta = series.diff()
    gain = delta.clip(lower=0.0)
    loss = (-delta).clip(lower=0.0)
    avg_gain = wilder(gain, period)
    avg_loss = wilder(loss, period)
    rs = avg_gain / avg_loss.replace(0.0, np.nan)
    out = 100.0 - (100.0 / (1.0 + rs))
    return out.fillna(50.0)


def adx(df: pd.DataFrame, period: int = 14) -> pd.DataFrame:
    """Return a frame with adx, plus_di and minus_di, Wilder-smoothed."""
    up = df["high"].diff()
    down = -df["low"].diff()

    plus_dm = np.where((up > down) & (up > 0), up, 0.0)
    minus_dm = np.where((down > up) & (down > 0), down, 0.0)

    tr = true_range(df)
    atr_ = wilder(tr, period)

    plus_di = 100.0 * wilder(pd.Series(plus_dm, index=df.index), period) / atr_.replace(0.0, np.nan)
    minus_di = 100.0 * wilder(pd.Series(minus_dm, index=df.index), period) / atr_.replace(0.0, np.nan)

    denom = (plus_di + minus_di).replace(0.0, np.nan)
    dx = 100.0 * (plus_di - minus_di).abs() / denom
    adx_ = wilder(dx.fillna(0.0), period)

    return pd.DataFrame(
        {"adx": adx_, "plus_di": plus_di.fillna(0.0), "minus_di": minus_di.fillna(0.0)},
        index=df.index,
    )


def rolling_percentile_rank(series: pd.Series, window: int) -> pd.Series:
    """Percentile (0-100) of each value inside its own trailing window.

    Matches ApexPercentileRank in the EA: the fraction of the window that
    sits strictly below the current value.
    """
    def _rank(vals: np.ndarray) -> float:
        current = vals[-1]
        prior = vals[:-1]
        if prior.size == 0:
            return 50.0
        return 100.0 * float((prior < current).sum()) / float(prior.size)

    return series.rolling(window + 1, min_periods=window // 2).apply(_rank, raw=True)


def swing_low(low: pd.Series, strength: int) -> pd.Series:
    """True where a bar is the lowest of `strength` bars on both sides.

    The result is shifted so it is only True once the confirming bars
    exist, which is what the EA sees in real time.
    """
    n = 2 * strength + 1
    is_min = low.rolling(n, center=True).min() == low
    return is_min.shift(strength).fillna(False).astype(bool)


def swing_high(high: pd.Series, strength: int) -> pd.Series:
    n = 2 * strength + 1
    is_max = high.rolling(n, center=True).max() == high
    return is_max.shift(strength).fillna(False).astype(bool)


# ---------------------------------------------------------------------------
# Cutler variants: simple moving averages instead of Wilder smoothing.
# The forex RSI-Stretch spec defines its indicators this way. They are not
# interchangeable with the Wilder versions above - the same period gives
# different values and therefore different signals - so both live here side
# by side and each strategy names the one it means.
# ---------------------------------------------------------------------------

def cutler_rsi(close: pd.Series, period: int = 14) -> pd.Series:
    """RSI over a plain rolling window of gains and losses.

    Matches the reference implementation: sum the gains and losses of the
    last `period` differences, and return 100 when there were no losses.
    """
    diff = close.diff()
    gain = diff.clip(lower=0.0).rolling(period).sum()
    loss = (-diff.clip(upper=0.0)).rolling(period).sum()

    out = 100.0 - 100.0 / (1.0 + gain / loss)
    out = out.where(loss > 0, 100.0)
    out[gain.isna() | loss.isna()] = np.nan
    return out


def sma_atr(df: pd.DataFrame, period: int = 14) -> pd.Series:
    """ATR as a simple mean of true range, not a Wilder average."""
    return true_range(df).rolling(period).mean()
