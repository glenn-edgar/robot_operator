#!/usr/bin/env python3
"""
Phase 5 — validate KB1 rules on real historical data.

Replays the universal + per-bin rules against:
  - LABELED failure runs (must fire):
      sat_1:27/1:39 run -2, -1 (mode-4 hard short, asym 7.33 A)
      sat_1:20/1:39 run 44     (mode-3 transition, peak 7.29 A)
      sat_1:20/1:39 run 45     (mode-4 dead-on)
  - ALL healthy historical runs across 96 active bins (must NOT fire)

Rules under test (from kb1_thresholds.json universal):
  R1 MODE_4_HARD:  any sample[i>0] > 5.0 A
  R2 MODE_4_DEAD:  I_asym > 2.0 × baseline.mu_i_asym
  R3 MODE_3_SPIKE: any sample[i>0] > 1.5 × baseline.mu_i_asym
  R4 OPEN_COIL:    I_asym < per-bin i_low_open
"""
import json
import statistics
from pathlib import Path


def asymptote(samples):
    n = len(samples)
    while n > 0 and samples[n - 1] <= 1e-6: n -= 1
    samples = samples[:n]
    if n < 4: return None
    return statistics.mean(samples[-3:])


def evaluate_run(samples, baseline_mu, i_low_open):
    asym = asymptote(samples)
    if asym is None: return []
    fires = []
    post0 = samples[1:] if len(samples) > 1 else []
    # R1
    if any(s > 5.0 for s in post0):
        fires.append("MODE_4_HARD")
    # R2
    if asym > 2.0 * baseline_mu:
        fires.append("MODE_4_DEAD")
    # R3
    if any(s > 1.5 * baseline_mu for s in post0):
        fires.append("MODE_3_SPIKE")
    # R4 — open coil
    if asym < i_low_open:
        fires.append("OPEN_COIL")
    return fires


def main():
    here = Path(__file__).parent
    th = json.loads((here / "data" / "time_history.json").read_text())
    bl = json.loads((here / "bin_baselines.json").read_text())
    tr = json.loads((here / "kb1_thresholds.json").read_text())

    # Build per-bin lookup of {mu_i_asym, i_low_open}, defaulting where bin
    # not baselined (retired bins) — use a generic 0.5 mu, 0.1 floor.
    bin_params = {}
    for bk, t in tr["per_bin"].items():
        if t["bimodal"]: continue
        bin_params[bk] = (t["mu_i_asym"], t["i_low_open"])
    # For retired bins we still want to test R1+R2+R3 against historical
    # asymptotes. Pull mu from their actual data (pre-failure stable runs).
    def fallback_mu(bin_key, runs):
        recent_asyms = []
        for run in runs:
            ic = run["IRRIGATION_CURRENT"]["data"]
            a = asymptote(ic)
            if a is not None and a < 2.0:  # healthy-only floor
                recent_asyms.append(a)
        if len(recent_asyms) >= 5:
            return statistics.mean(recent_asyms[-10:]), 0.1
        return None

    # ── Labeled failure events ──
    print(f"\n=== Phase 5 — KB1 validation ===\n")
    print(f"  LABELED failure runs (must fire):")
    print(f"  {'-'*72}")
    for bin_key, run_label, run_idx_expr in [
        ("satellite_1:27/satellite_1:39", "run -2", -2),
        ("satellite_1:27/satellite_1:39", "run -1", -1),
        ("satellite_1:20/satellite_1:39", "run 44 (mode-3)", 44),
        ("satellite_1:20/satellite_1:39", "run 45 (mode-4)", 45),
    ]:
        runs = th[bin_key]
        params = bin_params.get(bin_key) or fallback_mu(bin_key, runs[:-3])
        if not params:
            print(f"    {bin_key} {run_label} — no baseline available")
            continue
        mu, low = params
        run = runs[run_idx_expr]
        samples = run["IRRIGATION_CURRENT"]["data"]
        fires = evaluate_run(samples, mu, low)
        status = "✓" if fires else "✗ MISS"
        print(f"    {status} {bin_key:<32} {run_label:<18}  mu={mu:.2f}  fires={fires}")

    # ── False-positive sweep on healthy bins ──
    print(f"\n  FALSE-POSITIVE sweep across 96 active bins, all historical runs:")
    print(f"  {'-'*72}")
    fp_total = {"MODE_4_HARD": 0, "MODE_4_DEAD": 0, "MODE_3_SPIKE": 0, "OPEN_COIL": 0}
    fp_examples = {k: [] for k in fp_total}
    n_runs = 0
    for bin_key in bin_params:
        if bin_key not in th: continue
        mu, low = bin_params[bin_key]
        for i, run in enumerate(th[bin_key]):
            samples = run["IRRIGATION_CURRENT"]["data"]
            asym = asymptote(samples)
            if asym is None: continue
            n_runs += 1
            fires = evaluate_run(samples, mu, low)
            for rule in fires:
                fp_total[rule] += 1
                if len(fp_examples[rule]) < 3:
                    fp_examples[rule].append((bin_key, i, asym, max(samples[1:]) if len(samples)>1 else 0))

    print(f"    n_runs evaluated: {n_runs}")
    for rule, n in fp_total.items():
        rate = n / max(n_runs, 1)
        print(f"    {rule:<14}  fires: {n:>4}  rate: {rate*100:5.2f}%")
        for bk, idx, asym, peak in fp_examples[rule]:
            print(f"        eg: {bk:<48} run{idx:>3}  asym={asym:.2f}  peak[1:]={peak:.2f}")


if __name__ == "__main__":
    main()
