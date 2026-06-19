#!/usr/bin/env python3
"""
KB3 false-trigger simulator using per-bin threshold + 5-consec rule.

Reads baselines.json (with kb3_stdev / kb3_threshold / kb3_eligible
populated by generate_curves.py) and time_history.json. For each
eligible long bin, walks all historic runs (excluding last 2 = the
detector's eval set) and counts how many would have fired under:

  rule: at least 5 consecutive |MA5(samples)[t] - ref| > kb3_threshold[bin]
        within the body window (t in [5, n-2))

Reports per-bin false-fire count + aggregate FP rate per day.
"""
import argparse, json
from pathlib import Path

ROOT = Path(__file__).parent
FLOW_SKIP, TAIL_SKIP, MA_TAPS, HOLDOUT, CONSEC = 5, 2, 5, 2, 5


def ma_filter(samples, taps=MA_TAPS):
    out = []
    for t, _ in enumerate(samples):
        if t < taps - 1: out.append(None)
        else: out.append(sum(samples[t - taps + 1: t + 1]) / taps)
    return out


def consec_above(errs, thresh, k):
    """True if k consecutive |errs| > thresh."""
    cnt = 0
    for e in errs:
        if abs(e) > thresh:
            cnt += 1
            if cnt >= k: return True
        else:
            cnt = 0
    return False


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--baselines", default=str(ROOT / "baseline_state" / "baselines.json"))
    ap.add_argument("--snap",      default=str(ROOT / "snapshots" / "2026-05-31" / "time_history.json"))
    ap.add_argument("--consec",    type=int, default=CONSEC)
    args = ap.parse_args()

    baselines = json.loads(Path(args.baselines).read_text())["bins"]
    th        = json.loads(Path(args.snap).read_text())

    print(f"KB3 FP simulator")
    print(f"  rule: |filt[t] - ref| > kb3_threshold[bin] for {args.consec} consecutive steps")
    print(f"  per-bin threshold from baselines.json (5 * historic_stdev, floor 1.5 GPM)")
    print(f"  ineligible bins (5 * stdev > 3.0 GPM) are SKIPPED entirely\n")

    elig_bins = []
    ineligible = []
    no_data = []
    for k, v in baselines.items():
        if v["mode"] != "long": continue
        if v.get("kb3_stdev") is None: no_data.append(k); continue
        if v.get("kb3_eligible"): elig_bins.append(k)
        else: ineligible.append(k)

    print(f"  53 long bins → {len(elig_bins)} eligible, {len(ineligible)} ineligible (noisy), "
          f"{len(no_data)} no-noise-data\n")

    # Per-bin firing count
    rows = []
    total_hist_runs = 0
    total_fires     = 0
    for bk in elig_bins:
        v = baselines[bk]
        runs = th.get(bk, [])
        if len(runs) < HOLDOUT + 2: continue
        hist = runs[:-HOLDOUT]
        thresh = v["kb3_threshold"]
        ref    = v["ref"]
        fires = 0
        for r in hist:
            arr = (r.get("HUNTER_FLOW_METER") or {}).get("data") or []
            n = len(arr)
            if n < FLOW_SKIP + TAIL_SKIP + args.consec: continue
            filt = ma_filter(arr)
            errs = [filt[t] - ref for t in range(FLOW_SKIP, n - TAIL_SKIP)
                    if filt[t] is not None]
            if consec_above(errs, thresh, args.consec):
                fires += 1
        rows.append({
            "bin": bk, "ref": ref, "stdev": v["kb3_stdev"], "thresh": thresh,
            "n_hist": len(hist), "fires": fires,
        })
        total_hist_runs += len(hist)
        total_fires     += fires

    # Sort by fires desc
    rows.sort(key=lambda r: -r["fires"])
    print(f"=== Per-eligible-bin false-fire counts ===")
    print(f"  {'bin':<46s} {'ref':>6s} {'stdev':>6s} {'thresh':>7s} {'n_hist':>6s} {'fires':>6s} {'rate':>6s}")
    print(f"  " + "-" * 95)
    for r in rows:
        rate = r["fires"] / r["n_hist"] * 100
        print(f"  {r['bin']:<46s} {r['ref']:>6.2f} {r['stdev']:>6.3f} {r['thresh']:>7.2f} "
              f"{r['n_hist']:>6d} {r['fires']:>6d} {rate:>5.2f}%")

    fp_per_run = total_fires / max(1, total_hist_runs)
    print(f"\n=== Aggregate ===")
    print(f"  total historic runs (eligible bins): {total_hist_runs}")
    print(f"  total runs that would fire:          {total_fires}  ({fp_per_run*100:.3f}%)")
    # Daily traffic estimate: 32 eligible bins × ~2 runs/day = ~64 runs/day
    daily_runs = len(elig_bins) * 2
    daily_alerts = fp_per_run * daily_runs
    print(f"  expected daily false-alerts: {daily_alerts:.2f}  "
          f"(assuming {daily_runs} run-checks/day on eligible bins)")

    # Show ineligible bins so we know what we're NOT monitoring
    print(f"\n=== Ineligible bins (KB3 disabled, KB4-only) ===")
    ineligible_sorted = sorted(ineligible, key=lambda k: -baselines[k]["kb3_stdev"])
    for k in ineligible_sorted:
        v = baselines[k]
        print(f"  {k:<46s} ref={v['ref']:>6.2f}  stdev={v['kb3_stdev']:>5.2f}  "
              f"would-be-thresh={v['kb3_threshold']:>5.2f}")


if __name__ == "__main__":
    main()
