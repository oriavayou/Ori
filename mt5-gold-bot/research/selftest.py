#!/usr/bin/env python3
"""Self-tests for the ApexGold research harness.

These check the things that quietly ruin backtests: look-ahead bias,
wrong cost accounting, wrong position sizing, and an optimistic
resolution of bars that contain both the stop and the target.

    python selftest.py
"""

from __future__ import annotations

import sys

import numpy as np
import pandas as pd

from apexgold import indicators as ind
from apexgold.backtest import Backtester, RiskSettings, SymbolSpec
from apexgold.data import synthetic, synthetic_fx_daily
from apexgold.forex_rsi import RsiStretchParams, run_portfolio, summarise
from apexgold.strategy import (Params, add_touch_flags, build_features,
                               generate_signals)

PASSED, FAILED = [], []


def check(name: str, condition: bool, detail: str = "") -> None:
    if condition:
        PASSED.append(name)
        print(f"  PASS  {name}")
    else:
        FAILED.append(name)
        print(f"  FAIL  {name}  {detail}")


# ---------------------------------------------------------------- indicators
def test_indicators() -> None:
    print("\nIndicators")
    close = pd.Series([10.0] * 20)
    df = pd.DataFrame({"open": close, "high": close, "low": close, "close": close})
    check("ATR of a flat series is zero", abs(ind.atr(df).iloc[-1]) < 1e-9)
    check("RSI of a flat series is neutral", abs(ind.rsi(close).iloc[-1] - 50.0) < 1e-6)

    rising = pd.Series(np.arange(1.0, 61.0))
    check("EMA of a rising series trails price",
          ind.ema(rising, 20).iloc[-1] < rising.iloc[-1])

    rdf = pd.DataFrame({"open": rising, "high": rising + 0.5,
                        "low": rising - 0.5, "close": rising})
    a = ind.adx(rdf)
    check("ADX is high in a pure uptrend", a["adx"].iloc[-1] > 40.0,
          f"got {a['adx'].iloc[-1]:.1f}")
    check("+DI dominates in a pure uptrend",
          a["plus_di"].iloc[-1] > a["minus_di"].iloc[-1])

    # a swing low must only be visible `strength` bars after it forms
    lows = pd.Series([5, 4, 3, 4, 5, 6, 7], dtype=float)
    sw = ind.swing_low(lows, 2)
    check("swing low is reported with a delay, not at the pivot",
          bool(sw.iloc[4]) and not bool(sw.iloc[2]))


# ---------------------------------------------------------------- lookahead
def test_no_lookahead() -> None:
    print("\nLook-ahead")
    data = synthetic(bars=12000, seed=3)
    p = Params()

    full = generate_signals(add_touch_flags(build_features(data, p)), p, 0.25)

    cut = 9000
    truncated = generate_signals(
        add_touch_flags(build_features(data.iloc[:cut], p)), p, 0.25)

    # compare the last 1000 bars of the truncated run against the same
    # timestamps in the full run: knowing the future must change nothing
    tail = truncated.index[-1000:]
    a = full.loc[tail]
    b = truncated.loc[tail]

    same_dir = (a["dir"].to_numpy() == b["dir"].to_numpy()).all()
    same_lvl = np.allclose(a[["sl", "tp"]].to_numpy(), b[["sl", "tp"]].to_numpy(),
                           rtol=1e-9, atol=1e-9, equal_nan=True)
    check("signals do not change when future bars are removed", same_dir,
          f"{int((a['dir'].to_numpy() != b['dir'].to_numpy()).sum())} differ")
    check("stop and target levels are identical on shared bars", same_lvl)

    n_sig = int((b["dir"] != 0).sum())
    check("the comparison window actually contained signals", n_sig > 0,
          f"only {n_sig}")


# ---------------------------------------------------------------- costs
def test_costs() -> None:
    print("\nCosts and sizing")
    spec = SymbolSpec(spread_points=25, slippage_points=10, commission_per_lot=7.0)
    check("value per price unit matches a 100 oz gold contract",
          abs(spec.value_per_price_unit - 100.0) < 1e-9)

    data = synthetic(bars=20000, seed=5)
    res = Backtester(spec, Params(), RiskSettings(risk_percent=0.5), 10000.0).run(data)
    t = res["trades"]
    check("the run produced trades", len(t) > 20, f"{len(t)}")

    if len(t):
        stops = t[t["reason"].str.startswith("sl")]["r_multiple"]
        targets = t[t["reason"].str.startswith("tp")]["r_multiple"]
        check("a stopped trade loses slightly more than 1R after costs",
              bool((stops < -1.0).all()) and bool((stops > -1.35).all()),
              f"range {stops.min():.3f}..{stops.max():.3f}")
        check("a target trade wins slightly less than 3R after costs",
              bool((targets < 3.0).all()) and bool((targets > 2.7).all()),
              f"range {targets.min():.3f}..{targets.max():.3f}")

        # sizing: money at risk should track the configured percentage
        risked = t["risk_price"] * t["lots"] * spec.value_per_price_unit
        prior_balance = t["balance_after"] - t["pnl"]
        pct = 100.0 * risked / prior_balance
        check("risk per trade stays near the configured 0.5 percent",
              bool(((pct > 0.30) & (pct < 0.55)).mean() > 0.9),
              f"median {pct.median():.3f}%")


# ---------------------------------------------------------------- pessimism
def test_ambiguous_bar() -> None:
    print("\nAmbiguous bars")
    data = synthetic(bars=20000, seed=5)
    spec, p, r = SymbolSpec(), Params(), RiskSettings()

    pess = Backtester(spec, p, r, 10000.0, pessimistic=True).run(data)
    opt = Backtester(spec, p, r, 10000.0, pessimistic=False).run(data)

    check("the optimistic run is never worse than the pessimistic one",
          opt["final_balance"] >= pess["final_balance"] - 1e-6,
          f"{opt['final_balance']:.2f} vs {pess['final_balance']:.2f}")

    amb = pess["trades"]["reason"].str.contains("ambiguous").sum()
    check("ambiguous bars are resolved as losses by default",
          bool((pess["trades"].loc[pess["trades"]["reason"].str.contains("ambiguous"),
                                   "r_multiple"] < 0).all()) if amb else True,
          f"{amb} ambiguous exits")


# ---------------------------------------------------------------- risk layer
def test_risk_limits() -> None:
    print("\nRisk limits")
    data = synthetic(bars=20000, seed=5)
    spec, p = SymbolSpec(), Params()

    capped = Backtester(spec, p, RiskSettings(max_trades_per_day=1), 10000.0).run(data)
    free = Backtester(spec, p, RiskSettings(max_trades_per_day=0), 10000.0).run(data)
    check("the daily trade cap reduces trade count",
          len(capped["trades"]) <= len(free["trades"]),
          f"{len(capped['trades'])} vs {len(free['trades'])}")

    if len(capped["trades"]):
        per_day = capped["trades"].groupby(
            capped["trades"]["entry_time"].dt.normalize()).size()
        check("never more than one entry on a capped day", bool((per_day <= 1).all()),
              f"max {per_day.max()}")

    tiny = Backtester(spec, p, RiskSettings(max_drawdown_pct=0.5), 10000.0).run(data)
    check("a tight drawdown guard halts the run", tiny["halted"] or len(tiny["trades"]) < 5)


# ------------------------------------------------------------ forex RSI
def test_forex_rsi_spec_parity() -> None:
    """The Cutler indicators must equal a direct transcription of the spec."""
    print("\nForex RSI Stretch, indicator parity")

    def ref_rsi(closes, period, end):
        if end < period:
            return None
        gain = loss = 0.0
        for i in range(end - period + 1, end + 1):
            d = closes[i] - closes[i - 1]
            if d >= 0:
                gain += d
            else:
                loss -= d
        if loss == 0:
            return 100.0
        return 100 - 100 / (1 + gain / loss)

    def ref_atr(h, l, c, end, period=14):
        if end < period:
            return None
        s = 0.0
        for i in range(end - period + 1, end + 1):
            s += max(h[i] - l[i], abs(h[i] - c[i - 1]), abs(l[i] - c[i - 1]))
        return s / period

    rng = np.random.default_rng(0)
    n = 120
    close = 100 + np.cumsum(rng.standard_normal(n))
    high = close + rng.uniform(0.1, 1.0, n)
    low = close - rng.uniform(0.1, 1.0, n)
    df = pd.DataFrame({"open": close, "high": high, "low": low, "close": close})

    mine_r = ind.cutler_rsi(df["close"], 14).to_numpy()
    mine_a = ind.sma_atr(df, 14).to_numpy()
    dr = max(abs(mine_r[i] - ref_rsi(close, 14, i)) for i in range(20, n))
    da = max(abs(mine_a[i] - ref_atr(high, low, close, i, 14)) for i in range(20, n))

    check("Cutler RSI matches the spec's reference code", dr < 1e-9, f"max diff {dr:.2e}")
    check("simple ATR matches the spec's reference code", da < 1e-9, f"max diff {da:.2e}")
    check("Cutler RSI differs from Wilder RSI, so they are not interchangeable",
          abs(ind.rsi(df["close"], 14).iloc[-1] - mine_r[-1]) > 0.5)


def test_forex_levels() -> None:
    print("\nForex RSI Stretch, level construction")
    data = synthetic_fx_daily(pairs=4, days=400, mean_reversion=0.05, seed=2)
    sig = run_portfolio(data, RsiStretchParams())
    check("signals were produced", len(sig) > 20, f"{len(sig)}")

    if len(sig):
        longs = sig[sig["direction"] > 0]
        shorts = sig[sig["direction"] < 0]
        check("longs are ordered stop < entry < target",
              bool(((longs["stop"] < longs["entry"]) & (longs["entry"] < longs["target"])).all()))
        check("shorts are ordered target < entry < stop",
              bool(((shorts["target"] < shorts["entry"]) & (shorts["entry"] < shorts["stop"])).all()))

        # rounding entry, stop and target to the pair's digits independently
        # means the ratio is 1.00 only to within a tick, not exactly
        rr = (sig["target"] - sig["entry"]).abs() / sig["risk"]
        worst = float((rr - 1.0).abs().max())
        check("reward to risk is 1:1 to within price rounding",
              worst < 0.005, f"max deviation {worst:.2e}")

        decided = sig[sig["outcome"].isin(["target", "stopped"])]
        check("a decided trade returns exactly plus or minus one R",
              bool(decided["r"].abs().sub(1.0).abs().max() < 1e-12))

        check("entries fire only outside the 35 to 65 band",
              bool(((sig["rsi"] < 35.0) | (sig["rsi"] > 65.0)).all()))


def test_forex_one_open_per_pair() -> None:
    print("\nForex RSI Stretch, position lock")
    data = synthetic_fx_daily(pairs=3, days=500, mean_reversion=0.05, seed=4)
    sig = run_portfolio(data, RsiStretchParams())
    overlaps = 0
    for _, grp in sig.groupby("symbol"):
        grp = grp.sort_values("entry_time")
        prev_exit = None
        for _, row in grp.iterrows():
            if prev_exit is not None and row["entry_time"] <= prev_exit:
                overlaps += 1
            prev_exit = row["exit_time"]
    check("a pair never holds two signals at once", overlaps == 0, f"{overlaps} overlaps")


def test_forex_control_and_edge_recovery() -> None:
    """A random walk must yield no edge; a known edge must be recovered."""
    print("\nForex RSI Stretch, control and edge recovery")
    results = {}
    for mr in (0.0, 0.05, 0.10):
        data = synthetic_fx_daily(pairs=12, days=750, mean_reversion=mr, seed=21)
        results[mr] = summarise(run_portfolio(data, RsiStretchParams()))

    check("no edge is reported on a random walk",
          results[0.0]["expectancy_r"] <= 0.02,
          f"expectancy {results[0.0]['expectancy_r']:.3f} R")
    check("expectancy rises with the injected mean reversion",
          results[0.0]["expectancy_r"] < results[0.05]["expectancy_r"] < results[0.10]["expectancy_r"],
          " -> ".join(f"{results[m]['expectancy_r']:.3f}" for m in (0.0, 0.05, 0.10)))
    check("hit rate rises with the injected mean reversion",
          results[0.0]["hit_rate"] < results[0.05]["hit_rate"] < results[0.10]["hit_rate"],
          " -> ".join(f"{results[m]['hit_rate']:.1f}%" for m in (0.0, 0.05, 0.10)))


def test_forex_expiry_and_bias() -> None:
    print("\nForex RSI Stretch, expiry behaviour")
    data = synthetic_fx_daily(pairs=12, days=750, mean_reversion=0.05, seed=21)

    base = summarise(run_portfolio(data, RsiStretchParams()))
    check("a working settlement engine expires almost nothing",
          base["expiry_rate"] < 10.0, f"{base['expiry_rate']:.1f}%")
    check("a 1 ATR barrier is usually reached within a few bars",
          base["median_bars_held"] <= 5, f"median {base['median_bars_held']:.0f} bars")

    skipped = summarise(run_portfolio(data, RsiStretchParams(skip_bars=8)))
    check("ignoring post-entry bars drives the expiry rate up",
          skipped["expiry_rate"] > base["expiry_rate"] * 3,
          f"{base['expiry_rate']:.1f}% -> {skipped['expiry_rate']:.1f}%")
    check("ignoring post-entry bars also inflates the measured hit rate",
          skipped["hit_rate"] > base["hit_rate"],
          f"{base['hit_rate']:.1f}% -> {skipped['hit_rate']:.1f}%")


def main() -> int:
    print("ApexGold self-test")
    print("==================")
    test_indicators()
    test_no_lookahead()
    test_costs()
    test_ambiguous_bar()
    test_risk_limits()
    test_forex_rsi_spec_parity()
    test_forex_levels()
    test_forex_one_open_per_pair()
    test_forex_control_and_edge_recovery()
    test_forex_expiry_and_bias()

    print(f"\n{len(PASSED)} passed, {len(FAILED)} failed")
    if FAILED:
        for f in FAILED:
            print(f"  failing: {f}")
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
