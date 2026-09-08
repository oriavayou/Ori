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
from apexgold.data import synthetic
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


def main() -> int:
    print("ApexGold self-test")
    print("==================")
    test_indicators()
    test_no_lookahead()
    test_costs()
    test_ambiguous_bar()
    test_risk_limits()

    print(f"\n{len(PASSED)} passed, {len(FAILED)} failed")
    if FAILED:
        for f in FAILED:
            print(f"  failing: {f}")
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
