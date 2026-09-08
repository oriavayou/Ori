"""Performance metrics, Monte Carlo robustness and walk-forward validation.

The point of this module is to make it hard to fool yourself. A single
equity curve is one sample from a distribution; these routines describe
the distribution instead.
"""

from __future__ import annotations

import itertools

import numpy as np
import pandas as pd

from .backtest import Backtester, RiskSettings, SymbolSpec
from .strategy import Params, SETUP_NAMES


def metrics(result: dict) -> dict:
    trades: pd.DataFrame = result["trades"]
    eq: pd.Series = result["equity"]
    start = result["initial_balance"]
    end = result["final_balance"]

    out = {
        "trades": int(len(trades)),
        "net_profit": end - start,
        "return_pct": 100.0 * (end - start) / start if start else 0.0,
    }
    if trades.empty:
        out.update({"win_rate": 0.0, "profit_factor": 0.0, "expectancy_r": 0.0,
                    "avg_win_r": 0.0, "avg_loss_r": 0.0, "max_dd_pct": 0.0,
                    "max_losing_streak": 0, "sharpe": 0.0, "cagr_pct": 0.0,
                    "trades_per_month": 0.0})
        return out

    r = trades["r_multiple"].to_numpy(float)
    wins = r[r > 0]
    losses = r[r <= 0]

    gross_win = trades.loc[trades["pnl"] > 0, "pnl"].sum()
    gross_loss = -trades.loc[trades["pnl"] <= 0, "pnl"].sum()

    # longest run of consecutive losers
    streak = best = 0
    for v in r:
        if v <= 0:
            streak += 1
            best = max(best, streak)
        else:
            streak = 0

    peak = eq.cummax()
    dd = (peak - eq) / peak.replace(0.0, np.nan)
    max_dd = float(np.nanmax(dd.to_numpy())) * 100.0 if len(dd) else 0.0

    span_days = max((eq.index[-1] - eq.index[0]).days, 1)
    years = span_days / 365.25
    cagr = ((end / start) ** (1 / years) - 1) * 100.0 if years > 0 and end > 0 else 0.0

    out.update({
        "win_rate": 100.0 * len(wins) / len(r),
        "profit_factor": float(gross_win / gross_loss) if gross_loss > 0 else float("inf"),
        "expectancy_r": float(r.mean()),
        "avg_win_r": float(wins.mean()) if len(wins) else 0.0,
        "avg_loss_r": float(losses.mean()) if len(losses) else 0.0,
        "max_dd_pct": max_dd,
        "max_losing_streak": int(best),
        "sharpe": float(r.mean() / r.std(ddof=1) * np.sqrt(len(r))) if len(r) > 2 and r.std(ddof=1) > 0 else 0.0,
        "cagr_pct": cagr,
        "trades_per_month": len(r) / max(span_days / 30.4, 0.1),
    })
    return out


def breakdown(trades: pd.DataFrame) -> pd.DataFrame:
    """Per-setup and per-direction summary, so one family cannot hide behind another."""
    if trades.empty:
        return pd.DataFrame()
    t = trades.copy()
    t["setup_name"] = t["setup"].map(SETUP_NAMES)
    t["side"] = np.where(t["direction"] > 0, "long", "short")

    rows = []
    for keys, grp in itertools.chain(
        ((("setup", k), g) for k, g in t.groupby("setup_name")),
        ((("side", k), g) for k, g in t.groupby("side")),
        ((("all", "all"), t),),
    ):
        rows.append({
            "group": keys[0], "value": keys[1], "trades": len(grp),
            "win_rate": 100.0 * (grp["r_multiple"] > 0).mean(),
            "expectancy_r": grp["r_multiple"].mean(),
            "net_profit": grp["pnl"].sum(),
        })
    return pd.DataFrame(rows)


def monte_carlo(trades: pd.DataFrame, risk_percent: float, initial_balance: float = 10_000.0,
                n_paths: int = 5000, seed: int = 11) -> dict:
    """Bootstrap the trade sequence to see the range of plausible outcomes.

    Resampling with replacement destroys the specific order of trades,
    which is the part of a backtest that is pure luck. What survives is
    the distribution the edge implies.
    """
    if trades.empty:
        return {}

    r = trades["r_multiple"].to_numpy(float)
    n = len(r)
    rng = np.random.default_rng(seed)
    draws = rng.choice(r, size=(n_paths, n), replace=True)

    finals = np.empty(n_paths)
    max_dds = np.empty(n_paths)
    ruined = 0

    for k in range(n_paths):
        bal = initial_balance
        peak = bal
        worst = 0.0
        for x in draws[k]:
            bal += bal * (risk_percent / 100.0) * x
            if bal <= initial_balance * 0.5:
                ruined += 1
                bal = max(bal, 1.0)
                break
            peak = max(peak, bal)
            worst = max(worst, (peak - bal) / peak)
        finals[k] = bal
        max_dds[k] = worst * 100.0

    return {
        "paths": n_paths,
        "median_final": float(np.median(finals)),
        "p05_final": float(np.percentile(finals, 5)),
        "p95_final": float(np.percentile(finals, 95)),
        "prob_profit": float((finals > initial_balance).mean() * 100.0),
        "median_max_dd_pct": float(np.median(max_dds)),
        "p95_max_dd_pct": float(np.percentile(max_dds, 95)),
        "prob_50pct_loss": 100.0 * ruined / n_paths,
    }


def walk_forward(m15: pd.DataFrame, spec: SymbolSpec, base_params: Params,
                 risk: RiskSettings, grid: dict, folds: int = 5,
                 initial_balance: float = 10_000.0) -> dict:
    """Anchored walk-forward: optimise on everything before a fold, test on it.

    Only the out-of-sample segments are reported. In-sample numbers from a
    parameter search are a measure of the search, not of the strategy.
    """
    idx = m15.index
    bounds = np.linspace(0, len(idx), folds + 2).astype(int)
    keys = list(grid.keys())
    combos = list(itertools.product(*[grid[k] for k in keys]))

    oos_trades = []
    fold_rows = []

    for f in range(1, folds + 1):
        is_end = bounds[f]
        oos_end = bounds[f + 1]
        if is_end < 2000 or oos_end - is_end < 500:
            continue

        is_data = m15.iloc[:is_end]
        oos_data = m15.iloc[max(0, is_end - 400):oos_end]  # warm-up for indicators

        best_score, best_combo = -np.inf, None
        for combo in combos:
            p = Params(**{**base_params.__dict__, **dict(zip(keys, combo))})
            res = Backtester(spec, p, risk, initial_balance).run(is_data)
            m = metrics(res)
            if m["trades"] < 20:
                continue
            # reward return per unit of drawdown, not raw return
            score = m["return_pct"] / max(m["max_dd_pct"], 1.0)
            if m["expectancy_r"] <= 0:
                score = -abs(score)
            if score > best_score:
                best_score, best_combo = score, combo

        if best_combo is None:
            continue

        p = Params(**{**base_params.__dict__, **dict(zip(keys, best_combo))})
        res = Backtester(spec, p, risk, initial_balance).run(oos_data)
        m = metrics(res)
        t = res["trades"]
        if not t.empty:
            t = t[t["entry_time"] >= idx[is_end]]
            oos_trades.append(t)

        fold_rows.append({
            "fold": f,
            "is_end": str(idx[is_end - 1].date()),
            "oos_end": str(idx[oos_end - 1].date()),
            "params": dict(zip(keys, best_combo)),
            "oos_trades": m["trades"],
            "oos_return_pct": m["return_pct"],
            "oos_expectancy_r": m["expectancy_r"],
            "oos_win_rate": m["win_rate"],
            "oos_max_dd_pct": m["max_dd_pct"],
        })

    combined = pd.concat(oos_trades) if oos_trades else pd.DataFrame()
    summary = {}
    if not combined.empty:
        r = combined["r_multiple"].to_numpy(float)
        summary = {
            "oos_trades": len(r),
            "oos_win_rate": 100.0 * (r > 0).mean(),
            "oos_expectancy_r": float(r.mean()),
            "oos_total_r": float(r.sum()),
        }
    return {"folds": pd.DataFrame(fold_rows), "combined": combined, "summary": summary}
