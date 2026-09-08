#!/usr/bin/env python3
"""Backtest and diagnose the RSI Stretch daily forex strategy.

Examples
--------
    # control run: no edge exists in the data, so none should be reported
    python run_forex.py --synthetic --mean-reversion 0.0

    # edge recovery check
    python run_forex.py --synthetic --mean-reversion 0.05

    # real daily bars, one csv per pair in a directory
    python run_forex.py --dir ./daily_bars

    # why are signals expiring? sweep the publication-lag hypothesis
    python run_forex.py --dir ./daily_bars --expiry-sweep

    # re-settle a live signal ledger against the bars and report disagreements
    python run_forex.py --dir ./daily_bars --diagnose live_signals.csv
"""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

import numpy as np
import pandas as pd

from apexgold.data import load_csv, synthetic_fx_daily
from apexgold.forex_rsi import (OUTCOME_EXPIRED, OUTCOME_OPEN, OUTCOME_STOP,
                                OUTCOME_TARGET, RsiStretchParams,
                                build_features, run_portfolio, settle_one,
                                summarise)


def load_directory(path: str, tz_shift: int = 0) -> dict:
    """Read one csv per pair. The file stem becomes the symbol name."""
    files = sorted(Path(path).glob("*.csv")) + sorted(Path(path).glob("*.txt"))
    if not files:
        raise SystemExit(f"no csv files found in {path}")
    out = {}
    for f in files:
        df = load_csv(f, tz_shift_hours=tz_shift)
        if len(df) < 80:
            print(f"  skipping {f.name}: only {len(df)} bars")
            continue
        out[f.stem.upper()] = df
    if not out:
        raise SystemExit("no pair had enough history")
    return out


def print_summary(title: str, s: dict) -> None:
    print(f"\n{title}")
    print("-" * len(title))
    if not s.get("signals"):
        print("  no signals")
        return
    rows = [
        ("Signals", f"{s['signals']}"),
        ("Targets / stops", f"{s['targets']} / {s['stops']}"),
        ("Expired", f"{s['expired']}  ({s['expiry_rate']:.1f} %)"),
        ("Still open", f"{s['open']}"),
        ("Hit rate, decided only", f"{s['hit_rate']:.1f} %"),
        ("Decision rate", f"{s['decision_rate']:.1f} %"),
        ("Expectancy per signal", f"{s['expectancy_r']:.3f} R"),
        ("Total R", f"{s['total_r']:.1f}"),
        ("R per month", f"{s['r_per_month']:.2f}"),
        ("R from decided / expired", f"{s['r_from_decided']:.1f} / {s['r_from_expired']:.1f}"),
        ("Median bars held", f"{s['median_bars_held']:.0f}"),
    ]
    width = max(len(a) for a, _ in rows)
    for a, b in rows:
        print(f"  {a.ljust(width)} : {b}")


def expiry_sweep(data: dict, base: RsiStretchParams) -> None:
    """How many ignored post-entry bars would explain a given expiry rate?"""
    print("\nExpiry sweep: post-entry bars ignored by the settlement engine")
    print("-------------------------------------------------------------")
    print(f"{'skipped':>8} {'expiry rate':>12} {'decided':>8} {'hit rate':>9} {'R/month':>9}")
    for skip in (0, 1, 2, 3, 5, 8, 10, 12, 14):
        p = RsiStretchParams(**{**base.__dict__, "skip_bars": skip})
        s = summarise(run_portfolio(data, p))
        if not s.get("signals"):
            continue
        print(f"{skip:>8} {s['expiry_rate']:>11.1f}% {s['targets'] + s['stops']:>8} "
              f"{s['hit_rate']:>8.1f}% {s['r_per_month']:>9.2f}")
    print("\n  A high expiry rate cannot come from the market: with a 1 ATR barrier")
    print("  and a 15 day window, price reaches one side almost every time. Read")
    print("  off how many bars the engine must be missing to produce yours, and")
    print("  note that skipping bars also inflates the measured hit rate, because")
    print("  the trades that resolve fastest are the ones that resolve against you.")


def diagnose(data: dict, ledger_path: str, base: RsiStretchParams) -> None:
    """Re-settle a live ledger against the bars and report every disagreement."""
    led = pd.read_csv(ledger_path)
    led.columns = [c.strip().lower() for c in led.columns]

    required = {"symbol", "entry_time", "direction", "entry", "stop", "target"}
    missing = required - set(led.columns)
    if missing:
        raise SystemExit(f"ledger is missing columns: {sorted(missing)}")

    led["entry_time"] = pd.to_datetime(led["entry_time"], format="mixed")
    if led["direction"].dtype == object:
        led["direction"] = led["direction"].str.lower().map(
            {"bullish": 1, "long": 1, "buy": 1, "bearish": -1, "short": -1, "sell": -1})

    rows = []
    for _, sig in led.iterrows():
        symbol = str(sig["symbol"]).upper().replace("/", "")
        bars = data.get(symbol)
        if bars is None:
            rows.append({**sig.to_dict(), "recomputed": "no bars", "r_recomputed": np.nan,
                         "bars_to_resolve": np.nan})
            continue

        feat = build_features(bars, base)
        pos = feat.index.searchsorted(sig["entry_time"])
        if pos >= len(feat):
            rows.append({**sig.to_dict(), "recomputed": "entry after data", "r_recomputed": np.nan,
                         "bars_to_resolve": np.nan})
            continue

        res = settle_one(feat, int(pos), int(sig["direction"]),
                         float(sig["entry"]), float(sig["stop"]), float(sig["target"]),
                         RsiStretchParams(**{**base.__dict__, "mode": "corrected", "skip_bars": 0}))
        rows.append({
            "symbol": symbol,
            "entry_time": sig["entry_time"],
            "reported": str(sig.get("outcome", "")).lower(),
            "recomputed": res["outcome"],
            "r_reported": sig.get("r", np.nan),
            "r_recomputed": res["r"],
            "bars_to_resolve": res["exit_idx"] - int(pos),
        })

    out = pd.DataFrame(rows)
    print("\nLedger diagnosis")
    print("----------------")
    print(f"  signals checked : {len(out)}")

    checkable = out[out["recomputed"].isin([OUTCOME_TARGET, OUTCOME_STOP, OUTCOME_EXPIRED, OUTCOME_OPEN])]
    if checkable.empty:
        print("  none could be re-settled, check that the pair names match the csv file names")
        return

    print("\n  reported outcome versus recomputed outcome")
    if "reported" in checkable.columns and checkable["reported"].notna().any():
        print(pd.crosstab(checkable["reported"], checkable["recomputed"]).to_string())

    wrongly_expired = checkable[(checkable["reported"] == OUTCOME_EXPIRED) &
                                (checkable["recomputed"].isin([OUTCOME_TARGET, OUTCOME_STOP]))]
    if len(wrongly_expired):
        print(f"\n  {len(wrongly_expired)} signals were reported as expired but actually")
        print("  reached a level inside the window. This is the bug.")
        print(f"  median bars until they resolved: {wrongly_expired['bars_to_resolve'].median():.0f}")
        recovered = wrongly_expired["r_recomputed"].sum()
        print(f"  R that was thrown away by mis-settling them: {recovered:+.1f}")
        print("\n  first ten:")
        print(wrongly_expired.head(10).to_string(index=False))

    out.to_csv("ledger_diagnosis.csv", index=False)
    print("\n  full result written to ledger_diagnosis.csv")


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description="RSI Stretch daily forex research")
    src = ap.add_mutually_exclusive_group(required=True)
    src.add_argument("--dir", help="directory of daily OHLC csv files, one per pair")
    src.add_argument("--synthetic", action="store_true")

    ap.add_argument("--pairs", type=int, default=12)
    ap.add_argument("--days", type=int, default=750)
    ap.add_argument("--mean-reversion", type=float, default=0.05,
                    help="synthetic only: 0.0 is a random walk with no edge to find")
    ap.add_argument("--seed", type=int, default=21)
    ap.add_argument("--tz-shift", type=int, default=0)

    ap.add_argument("--long-below", type=float, default=35.0)
    ap.add_argument("--short-above", type=float, default=65.0)
    ap.add_argument("--target-atr", type=float, default=1.0)
    ap.add_argument("--stop-atr", type=float, default=1.0)
    ap.add_argument("--expiry-days", type=int, default=15)
    ap.add_argument("--mode", choices=["spec", "corrected"], default="spec")

    ap.add_argument("--expiry-sweep", action="store_true")
    ap.add_argument("--threshold-scan", action="store_true")
    ap.add_argument("--diagnose", help="csv ledger of live signals to re-settle")
    ap.add_argument("--save-signals")

    args = ap.parse_args(argv)

    if args.synthetic:
        data = synthetic_fx_daily(pairs=args.pairs, days=args.days,
                                  mean_reversion=args.mean_reversion, seed=args.seed)
        print(f"Synthetic: {args.pairs} pairs, {args.days} daily bars, "
              f"mean reversion {args.mean_reversion}")
        if args.mean_reversion == 0.0:
            print("Control case: the data is a random walk, so a correct engine "
                  "must NOT find an edge here.")
    else:
        data = load_directory(args.dir, args.tz_shift)
        first = next(iter(data.values()))
        print(f"Loaded {len(data)} pairs, {len(first)} bars on the first "
              f"({first.index[0].date()} to {first.index[-1].date()})")

    base = RsiStretchParams(
        long_below=args.long_below, short_above=args.short_above,
        target_atr=args.target_atr, stop_atr=args.stop_atr,
        expiry_days=args.expiry_days, mode=args.mode,
    )

    if args.diagnose:
        diagnose(data, args.diagnose, base)
        return 0

    signals = run_portfolio(data, base)
    print_summary("Backtest result", summarise(signals))

    if not signals.empty:
        print("\nBy confidence score")
        print("-------------------")
        g = signals.groupby("confidence").agg(
            signals=("r", "size"),
            hit_rate=("outcome", lambda s: 100.0 * (s == OUTCOME_TARGET).sum()
                      / max((s.isin([OUTCOME_TARGET, OUTCOME_STOP])).sum(), 1)),
            expectancy_r=("r", "mean"))
        print(g.round(3).to_string())

        # correlation: how much of the risk is really one bet?
        daily = signals.set_index("entry_time").resample("D").size()
        clustered = 100.0 * daily[daily > 1].sum() / max(daily.sum(), 1)
        print(f"\n  share of signals opened on a day that produced more than one: "
              f"{clustered:.1f} %")
        print("  those are not independent bets, they are one macro view sized several times")

    if args.expiry_sweep:
        expiry_sweep(data, base)

    if args.threshold_scan:
        print("\nThreshold scan")
        print("--------------")
        print(f"{'long<':>6} {'short>':>7} {'signals':>8} {'hit rate':>9} {'expectancy':>11} {'R/month':>9}")
        for lo, hi in ((40, 60), (35, 65), (30, 70), (25, 75), (20, 80)):
            p = RsiStretchParams(**{**base.__dict__, "long_below": float(lo), "short_above": float(hi)})
            s = summarise(run_portfolio(data, p))
            if not s.get("signals"):
                continue
            print(f"{lo:>6} {hi:>7} {s['signals']:>8} {s['hit_rate']:>8.1f}% "
                  f"{s['expectancy_r']:>11.3f} {s['r_per_month']:>9.2f}")

    if args.save_signals and not signals.empty:
        signals.to_csv(args.save_signals, index=False)
        print(f"\nSignal ledger written to {args.save_signals}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
