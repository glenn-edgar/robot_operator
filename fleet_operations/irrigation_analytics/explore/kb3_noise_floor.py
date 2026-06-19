#!/usr/bin/env python3
"""
KB3 per-step noise-floor analyzer.

For each LONG bin, walk all HISTORIC runs (excluding the last two —
those are the ones the detector would evaluate), compute the filtered
GPM error trace `err[t] = MA5(samples)[t] - ref` for t in body window,
and report the per-step error distribution.

Output:
  1. Per-bin: count of samples, p50/p95/p99/max |err|, recommended
     per-bin threshold (= max(K * mad, abs(p99))).
  2. Overall: aggregate distribution across all bins.
  3. False-trigger budget calculation at proposed thresholds.

This is the data needed to lock KB3's BREAK_or_DROPOUT threshold so it
doesn't false-trigger.
"""
import argparse
import json
import math
import statistics as st
from pathlib import Path
from collections import defaultdict

ROOT = Path(__file__).parent

FLOW_SKIP   = 5
TAIL_SKIP   = 2
MA_TAPS     = 5
HOLDOUT     = 2     # leave out last 2 runs (those are the eval set)

def ma_filter(samples, taps=MA_TAPS):
    out = []
    for t, _ in enumerate(samples):
        if t < taps - 1:
            out.append(None)
        else:
            out.append(sum(samples[t - taps + 1 : t + 1]) / taps)
    return out


def quantiles(xs, ps):
    """Quantiles (p50/p95/p99) of a list, robust to small lists."""
    if not xs: return [None]*len(ps)
    xs2 = sorted(xs)
    out = []
    for p in ps:
        if len(xs2) == 1:
            out.append(xs2[0]); continue
        idx = p * (len(xs2) - 1)
        lo, hi = int(idx), min(int(idx)+1, len(xs2)-1)
        frac = idx - lo
        out.append(xs2[lo] + frac * (xs2[hi] - xs2[lo]))
    return out


def per_step_errs(samples, ref):
    n = len(samples)
    if n < FLOW_SKIP + TAIL_SKIP + 3: return []
    filt = ma_filter(samples)
    out = []
    end = n - TAIL_SKIP
    for t in range(FLOW_SKIP, end):
        f = filt[t]
        if f is None: continue
        out.append(f - ref)
    return out


def consec_above(errs, thresh, min_consec):
    """Return True if at least min_consec consecutive |errs| > thresh."""
    cnt = 0
    for e in errs:
        if abs(e) > thresh:
            cnt += 1
            if cnt >= min_consec: return True
        else:
            cnt = 0
    return False


def main():
    ap = argparse.ArgumentParser()
    today_snap = ROOT / "snapshots" / "2026-05-31" / "time_history.json"
    ap.add_argument("--snap", default=str(today_snap))
    ap.add_argument("--baselines", default=str(ROOT / "baseline_state" / "baselines.json"))
    args = ap.parse_args()

    baselines = json.loads(Path(args.baselines).read_text())["bins"]
    th        = json.loads(Path(args.snap).read_text())

    per_bin    = []
    all_errs   = []     # pooled across bins
    all_errs_normalized = []  # err / ref_mad (where mad valid)

    for bin_key, base in sorted(baselines.items()):
        if base["mode"] != "long": continue
        runs = th.get(bin_key, [])
        if len(runs) < HOLDOUT + 2: continue   # need at least 2 historic runs
        # Use runs EXCLUDING the last HOLDOUT
        hist_runs = runs[:-HOLDOUT]
        ref     = base["ref"]
        ref_mad = base["ref_mad"]

        bin_errs = []
        for r in hist_runs:
            arr = (r.get("HUNTER_FLOW_METER") or {}).get("data") or []
            bin_errs.extend(per_step_errs(arr, ref))
        if not bin_errs: continue

        abs_errs = [abs(e) for e in bin_errs]
        p50, p95, p99 = quantiles(abs_errs, [0.50, 0.95, 0.99])
        per_bin.append({
            "bin":       bin_key,
            "ref":       ref,
            "ref_mad":   ref_mad,
            "n_hist_runs": len(hist_runs),
            "n_samples": len(bin_errs),
            "p50_abs":   p50,
            "p95_abs":   p95,
            "p99_abs":   p99,
            "max_abs":   max(abs_errs),
            "stdev":     st.pstdev(bin_errs) if len(bin_errs) > 1 else 0,
        })
        all_errs.extend(bin_errs)
        if ref_mad > 0.01:
            all_errs_normalized.extend([e / ref_mad for e in bin_errs])

    # ── 1) Per-bin table sorted by ref ──
    print(f"=== Per-bin filtered-GPM error distribution ===")
    print(f"    historic runs only (excluding last {HOLDOUT}), body window t in [{FLOW_SKIP}, n-{TAIL_SKIP})\n")
    hdr = (f"  {'bin':<46s} {'ref':>6s} {'mad':>5s} {'runs':>4s} {'n_s':>5s} "
           f"{'stdev':>6s} {'p50':>5s} {'p95':>5s} {'p99':>5s} {'max':>5s}")
    print(hdr); print("  " + "-" * (len(hdr) - 2))
    per_bin.sort(key=lambda b: -b["ref"])
    for b in per_bin:
        print(f"  {b['bin']:<46s} {b['ref']:>6.2f} {b['ref_mad']:>5.2f} {b['n_hist_runs']:>4d} "
              f"{b['n_samples']:>5d} {b['stdev']:>6.3f} {b['p50_abs']:>5.2f} "
              f"{b['p95_abs']:>5.2f} {b['p99_abs']:>5.2f} {b['max_abs']:>5.2f}")

    # ── 2) Overall pooled distribution ──
    print(f"\n=== Pooled distribution across {len(per_bin)} bins, "
          f"{len(all_errs)} samples ===")
    abs_all = [abs(e) for e in all_errs]
    p50, p90, p95, p99, p999 = quantiles(abs_all, [0.50, 0.90, 0.95, 0.99, 0.999])
    print(f"  mean |err|: {st.fmean(abs_all):.3f} GPM")
    print(f"  stdev err:  {st.pstdev(all_errs):.3f} GPM")
    print(f"  p50  |err|: {p50:.3f}")
    print(f"  p90  |err|: {p90:.3f}")
    print(f"  p95  |err|: {p95:.3f}")
    print(f"  p99  |err|: {p99:.3f}")
    print(f"  p99.9|err|: {p999:.3f}")
    print(f"  max  |err|: {max(abs_all):.3f}")

    # ── 3) False-trigger budget at candidate thresholds ──
    # Total per-day eval samples ≈ n_bins × ~2 runs × ~30 body samples × 5 = ~30000
    print(f"\n=== False-trigger rates for KB3 BREAK_or_DROPOUT @ candidate thresholds ===")
    print(f"    rule: any |err[t]| > thresh for >= 2 consecutive steps fires alert")
    print(f"    (per-step samples within a run are correlated; consecutive rule is strong FP filter)")
    print(f"  {'thresh (GPM)':>14s}  {'p(single >)':>11s}  {'p(2-consec)':>11s}  {'n_bins fire':>11s}  {'n_runs fire':>11s}")

    # Build per-run, per-bin firing simulation for thresholds
    for thresh in [1.0, 1.5, 2.0, 2.5, 3.0, 4.0, 5.0]:
        single = sum(1 for e in abs_all if e > thresh)
        # Simulate per-run 2-consecutive firing
        bin_runs_fired = 0
        bins_fired = set()
        # Re-walk runs per bin
        for b in per_bin:
            bin_key = b["bin"]
            ref = b["ref"]
            runs = th.get(bin_key, [])
            hist_runs = runs[:-HOLDOUT]
            bin_fired_any = False
            for r in hist_runs:
                arr = (r.get("HUNTER_FLOW_METER") or {}).get("data") or []
                errs = per_step_errs(arr, ref)
                if consec_above(errs, thresh, 2):
                    bin_runs_fired += 1
                    bin_fired_any = True
            if bin_fired_any:
                bins_fired.add(bin_key)
        total_hist_runs = sum(b["n_hist_runs"] for b in per_bin)
        print(f"  {thresh:>14.2f}  "
              f"{single/len(abs_all)*100:>9.3f}%  "
              f"{bin_runs_fired/max(1,total_hist_runs)*100:>9.3f}%  "
              f"{len(bins_fired):>8d}/{len(per_bin):<2d}  "
              f"{bin_runs_fired:>5d}/{total_hist_runs:<5d}")

    print(f"\n  total historic runs analyzed: {total_hist_runs}")
    print(f"  (false-trigger rate per run is what matters; at 2 runs/bin/day, "
          f"rate × n_bins × 2 = alerts/day)")

    # ── 4) Recommended thresholds ──
    print(f"\n=== Recommended KB3 BREAK_or_DROPOUT thresholds ===")
    rec_universal = max(3.0, math.ceil(2 * p99 * 2) / 2)   # 2× p99, rounded up to 0.5
    print(f"  universal:    {rec_universal:.1f} GPM  (≈ 2× p99 of pooled noise, rounded)")
    print(f"  per-bin:      max(5.0 × ref_mad, 1.0 GPM)  if ref_mad available")
    print(f"  consecutive rule: 2 steps (filters single-sample spikes)")

    # ── 5) Effect of the consecutive rule on real noise ──
    # How many bins would fire ZERO false alarms at 1.5 GPM with 2-consec?
    bins_quiet_at_1p5 = sum(1 for b in per_bin
                            if all(not consec_above(per_step_errs(
                                (r.get("HUNTER_FLOW_METER") or {}).get("data") or [],
                                b["ref"]), 1.5, 2)
                                for r in th[b["bin"]][:-HOLDOUT]))
    print(f"\n  bins with ZERO 2-consec >1.5 GPM in all history: {bins_quiet_at_1p5}/{len(per_bin)}")


if __name__ == "__main__":
    main()
