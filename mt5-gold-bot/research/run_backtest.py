#!/usr/bin/env python3
"""Command line entry point for the ApexGold research harness.

Examples
--------
    # plumbing check on synthetic data
    python run_backtest.py --synthetic --bars 40000

    # real history exported from MetaTrader 5 (M15, GMT+2 server)
    python run_backtest.py --csv XAUUSD_M15.csv --broker-gmt-offset 2 \
        --spread-points 25 --commission 7 --risk 0.5

    # walk-forward validation
    python run_backtest.py --csv XAUUSD_M15.csv --walk-forward
"""

from __future__ import annotations

import argparse
import sys

import pandas as pd

from apexgold.analysis import breakdown, metrics, monte_carlo, walk_forward
from apexgold.backtest import Backtester, RiskSettings, SymbolSpec
from apexgold.data import load_csv, synthetic
from apexgold.strategy import Params


def fmt(value: float, digits: int = 2) -> str:
    if value == float("inf"):
        return "inf"
    return f"{value:,.{digits}f}"


def print_report(title: str, m: dict) -> None:
    print(f"\n{title}")
    print("-" * len(title))
    rows = [
        ("Trades", f"{m['trades']}"),
        ("Net profit", fmt(m["net_profit"])),
        ("Return", f"{fmt(m['return_pct'])} %"),
        ("CAGR", f"{fmt(m['cagr_pct'])} %"),
        ("Win rate", f"{fmt(m['win_rate'])} %"),
        ("Expectancy", f"{fmt(m['expectancy_r'], 3)} R"),
        ("Profit factor", fmt(m["profit_factor"])),
        ("Max drawdown", f"{fmt(m['max_dd_pct'])} %"),
        ("Longest losing streak", f"{m['max_losing_streak']}"),
        ("Trades per month", fmt(m["trades_per_month"], 1)),
    ]
    width = max(len(a) for a, _ in rows)
    for a, b in rows:
        print(f"  {a.ljust(width)} : {b}")


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description="ApexGold backtest and validation")
    src = ap.add_mutually_exclusive_group(required=True)
    src.add_argument("--csv", help="M15 OHLC export from MetaTrader")
    src.add_argument("--synthetic", action="store_true", help="use generated data (plumbing test only)")

    ap.add_argument("--bars", type=int, default=40000, help="synthetic bar count")
    ap.add_argument("--seed", type=int, default=7)
    ap.add_argument("--broker-gmt-offset", type=int, default=0,
                    help="hours to subtract so the index becomes GMT")

    ap.add_argument("--balance", type=float, default=10000.0)
    ap.add_argument("--risk", type=float, default=0.5, help="percent risked per trade")
    ap.add_argument("--reward-r", type=float, default=3.0)
    ap.add_argument("--min-score", type=float, default=62.0)

    ap.add_argument("--spread-points", type=float, default=25.0)
    ap.add_argument("--slippage-points", type=float, default=10.0)
    ap.add_argument("--commission", type=float, default=7.0, help="per lot, round turn")
    ap.add_argument("--point", type=float, default=0.01)
    ap.add_argument("--tick-value", type=float, default=1.0)

    ap.add_argument("--optimistic", action="store_true",
                    help="resolve ambiguous bars as target-first (do not trust the result)")
    ap.add_argument("--walk-forward", action="store_true")
    ap.add_argument("--folds", type=int, default=5)
    ap.add_argument("--mc-paths", type=int, default=5000)
    ap.add_argument("--save-trades", help="write the trade list to this csv")

    args = ap.parse_args(argv)

    if args.synthetic:
        data = synthetic(bars=args.bars, seed=args.seed)
        print(f"Synthetic data: {len(data):,} M15 bars "
              f"({data.index[0].date()} to {data.index[-1].date()})")
        print("NOTE: synthetic results test the code, not the edge.")
    else:
        data = load_csv(args.csv, tz_shift_hours=args.broker_gmt_offset)
        print(f"Loaded {len(data):,} bars from {args.csv} "
              f"({data.index[0]} to {data.index[-1]}, GMT)")

    spec = SymbolSpec(
        point=args.point, tick_size=args.point, tick_value=args.tick_value,
        spread_points=args.spread_points, slippage_points=args.slippage_points,
        commission_per_lot=args.commission,
    )
    params = Params(reward_r=args.reward_r, min_score=args.min_score)
    risk = RiskSettings(risk_percent=args.risk)

    bt = Backtester(spec, params, risk, args.balance, pessimistic=not args.optimistic)
    result = bt.run(data)
    m = metrics(result)

    print_report("Backtest result", m)

    bd = breakdown(result["trades"])
    if not bd.empty:
        print("\nBreakdown")
        print("---------")
        print(bd.to_string(index=False,
                           formatters={"win_rate": lambda v: f"{v:.1f}",
                                       "expectancy_r": lambda v: f"{v:.3f}",
                                       "net_profit": lambda v: f"{v:,.2f}"}))

    if not result["trades"].empty:
        mc = monte_carlo(result["trades"], args.risk, args.balance, n_paths=args.mc_paths)
        print("\nMonte Carlo (trade order reshuffled)")
        print("-----------------------------------")
        print(f"  Paths                  : {mc['paths']:,}")
        print(f"  Median final balance   : {fmt(mc['median_final'])}")
        print(f"  5th / 95th percentile  : {fmt(mc['p05_final'])} / {fmt(mc['p95_final'])}")
        print(f"  Probability of profit  : {fmt(mc['prob_profit'], 1)} %")
        print(f"  Median max drawdown    : {fmt(mc['median_max_dd_pct'], 1)} %")
        print(f"  95th pct max drawdown  : {fmt(mc['p95_max_dd_pct'], 1)} %")
        print(f"  Chance of losing half  : {fmt(mc['prob_50pct_loss'], 1)} %")

    if args.walk_forward:
        grid = {"min_score": [58.0, 62.0, 66.0, 70.0],
                "max_stop_atr_mult": [2.0, 2.5, 3.0]}
        wf = walk_forward(data, spec, params, risk, grid, folds=args.folds,
                          initial_balance=args.balance)
        print("\nWalk-forward (out-of-sample only)")
        print("---------------------------------")
        if wf["folds"].empty:
            print("  not enough data for the requested number of folds")
        else:
            print(wf["folds"].to_string(index=False))
            if wf["summary"]:
                s = wf["summary"]
                print(f"\n  Combined OOS trades     : {s['oos_trades']}")
                print(f"  Combined OOS win rate   : {fmt(s['oos_win_rate'], 1)} %")
                print(f"  Combined OOS expectancy : {fmt(s['oos_expectancy_r'], 3)} R")
                print(f"  Combined OOS total      : {fmt(s['oos_total_r'], 1)} R")

    if args.save_trades and not result["trades"].empty:
        result["trades"].to_csv(args.save_trades, index=False)
        print(f"\nTrade list written to {args.save_trades}")

    if result["skipped_small_lot"]:
        print(f"\n{result['skipped_small_lot']} signals skipped: "
              f"computed lot below the broker minimum (account too small for that stop)")
    if result["halted"]:
        print("\nRun halted early by the maximum-drawdown guard.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
