#!/usr/bin/env python3
"""
KB3 curve-error analyzer.

For each LONG bin in baselines.json, walk the last N runs of TIME_HISTORY,
construct the expected curve (flat at ref for t >= 5), compute filtered
actual at each step, and report:
  - per-step error trace (filtered_actual[t] - ref)
  - cumulative-gallons error trajectory (sum_actual - sum_expected at each t)
  - run summary: mean_err, max_pos_err, max_neg_err, total_gal vs expected

Short bins skipped (end-point only, no curve).

Output:
  1. Summary table sorted by worst cumulative-gallons error
  2. Per-step trace for flagged or user-requested bins
"""
import argparse
import json
import statistics as st
from pathlib import Path

ROOT = Path(__file__).parent

FLOW_SKIP   = 5
TAIL_SKIP   = 2
MA_TAPS     = 5
# Flag thresholds (per-step instantaneous + cumulative gallons over the run)
K_MAD       = 3.0
ERR_FLOOR   = 0.5            # GPM per-step error floor
GAL_FLOOR   = 5.0            # cumulative gallons error floor (5 gal = ~0.5 min at 10 GPM)
GAL_REL     = 0.05           # OR 5% of expected total, whichever larger


def ma_filter(samples, taps=MA_TAPS):
    out = []
    for t, _ in enumerate(samples):
        if t < taps - 1:
            out.append(None)
        else:
            out.append(sum(samples[t - taps + 1 : t + 1]) / taps)
    return out


def analyze_run(samples, ref):
    """Return per-step + cumulative error summary for one run vs flat curve at ref.

    Curve definition:
       curve(t) = ref for t in [FLOW_SKIP, n - TAIL_SKIP)
                  undefined elsewhere

    Returns dict with:
      n, n_body, mean_err, max_pos_err, max_neg_err, max_abs_err,
      cum_actual, cum_expected, cum_err, cum_err_rel,
      per_step: [(t, filt, err, cum_err), ...]
    """
    n = len(samples)
    if n < FLOW_SKIP + TAIL_SKIP + 3:
        return None
    filt = ma_filter(samples)
    per_step = []
    cum_err = 0.0
    cum_actual = 0.0
    cum_expected = 0.0
    errs = []
    end = n - TAIL_SKIP
    for t in range(FLOW_SKIP, end):
        f = filt[t]
        if f is None: continue
        err = f - ref
        cum_actual   += f
        cum_expected += ref
        cum_err      += err
        per_step.append({"t": t, "filt": f, "err": err, "cum_err": cum_err})
        errs.append(err)
    if not errs: return None
    return {
        "n": n,
        "n_body": len(errs),
        "mean_err":    sum(errs) / len(errs),
        "max_pos_err": max(errs),
        "max_neg_err": min(errs),
        "max_abs_err": max(abs(e) for e in errs),
        "err_mad":     st.median([abs(e - st.median(errs)) for e in errs]),
        "cum_actual":  cum_actual,
        "cum_expected": cum_expected,
        "cum_err":     cum_err,
        "cum_err_rel": (cum_err / cum_expected) if cum_expected > 0 else 0.0,
        "per_step":    per_step,
    }


def classify(summary, ref_mad):
    """Return label string based on cumulative + max-instant error."""
    if summary is None: return "no_data"
    gate_inst = max(K_MAD * (ref_mad or 0), ERR_FLOOR)
    gate_cum  = max(GAL_FLOOR, GAL_REL * summary["cum_expected"])
    flags = []
    if abs(summary["cum_err"]) > gate_cum:
        flags.append(f"CUM_{('HIGH' if summary['cum_err']>0 else 'LOW')}")
    if summary["max_abs_err"] > gate_inst:
        sign = "+" if summary["max_pos_err"] >= -summary["max_neg_err"] else "-"
        flags.append(f"INST_{sign}")
    if not flags: return "OK"
    return "|".join(flags)


def main():
    ap = argparse.ArgumentParser()
    today = (ROOT / "snapshots").glob("*/time_history.json")
    snaps = sorted([p for p in today if p.parent.name >= "2026-05-31"])
    default_snap = snaps[-1] if snaps else (ROOT / "snapshots" / "2026-05-31" / "time_history.json")
    ap.add_argument("--baselines", default=str(ROOT / "baseline_state" / "baselines.json"))
    ap.add_argument("--snap",      default=str(default_snap))
    ap.add_argument("--last",      type=int, default=2,
                    help="analyze last N runs per bin (default 2)")
    ap.add_argument("--detail",
                    help="print per-step trace for bins whose key contains this substring")
    args = ap.parse_args()

    baselines = json.loads(Path(args.baselines).read_text())["bins"]
    th        = json.loads(Path(args.snap).read_text())

    print(f"baselines: {args.baselines}")
    print(f"snapshot:  {args.snap}")
    print(f"last {args.last} runs per bin, long bins only\n")

    results = []   # (bin_key, run_idx, summary, classification)
    for bin_key, base in baselines.items():
        if base["mode"] != "long": continue
        runs = th.get(bin_key, [])
        if len(runs) < args.last: continue
        ref     = base["ref"]
        ref_mad = base["ref_mad"]
        # The most recent `last` runs are also in the baseline window itself;
        # this means we're checking the runs against a baseline that INCLUDES
        # them — error magnitude is naturally biased low. (See note in
        # baseline-rot discussion 2026-05-31.) Acceptable for v1.
        for ri, r in enumerate(runs[-args.last:]):
            arr = (r.get("HUNTER_FLOW_METER") or {}).get("data") or []
            s = analyze_run(arr, ref)
            if s is None: continue
            label = classify(s, ref_mad)
            results.append({
                "bin": bin_key,
                "ref": ref,
                "ref_mad": ref_mad,
                "run_index": ri - args.last,   # -2, -1
                "summary":   s,
                "label":     label,
            })

    # ── 1) Summary table, sorted by |cum_err| desc ──
    print(f"=== Per-run curve-error summary ({len(results)} runs across "
          f"{len(set(r['bin'] for r in results))} long bins) ===")
    hdr = (f"  {'bin':<46s} {'run':>4s} {'n':>3s} {'ref':>6s} "
           f"{'mean_err':>8s} {'max_pos':>7s} {'max_neg':>7s} "
           f"{'cum_act':>7s} {'cum_exp':>7s} {'cum_err':>7s} {'rel':>6s}  {'label':<14s}")
    print(hdr); print("  " + "-" * (len(hdr) - 2))
    results.sort(key=lambda r: -abs(r["summary"]["cum_err"]))
    for r in results:
        s = r["summary"]
        print(f"  {r['bin']:<46s} {r['run_index']:>+4d} {s['n']:>3d} {r['ref']:>6.2f} "
              f"{s['mean_err']:>+8.3f} {s['max_pos_err']:>+7.2f} {s['max_neg_err']:>+7.2f} "
              f"{s['cum_actual']:>7.0f} {s['cum_expected']:>7.0f} {s['cum_err']:>+7.1f} "
              f"{s['cum_err_rel']*100:>+5.1f}%  {r['label']:<14s}")

    # ── 2) Flagged-only summary ──
    flagged = [r for r in results if r["label"] != "OK"]
    print(f"\n=== Flagged runs ({len(flagged)}) ===")
    if not flagged: print("  (none — all runs within gates)")
    for r in flagged:
        s = r["summary"]
        print(f"  {r['bin']:<46s} run[{r['run_index']:+d}]  {r['label']:<14s}  "
              f"cum_err={s['cum_err']:+.1f} gal ({s['cum_err_rel']*100:+.1f}%)  "
              f"inst peak ({s['max_pos_err']:+.2f}, {s['max_neg_err']:+.2f}) GPM")

    # ── 3) Optional per-step detail ──
    if args.detail:
        sel = [r for r in results if args.detail in r["bin"]]
        for r in sel:
            s = r["summary"]
            print(f"\n--- per-step trace: {r['bin']}  run[{r['run_index']:+d}]  ref={r['ref']:.2f} ---")
            print(f"    {'t':>3s}  {'filt':>6s}  {'err':>+7s}  {'cum_err':>8s}")
            for st_ in s["per_step"]:
                print(f"    {st_['t']:>3d}  {st_['filt']:>6.2f}  {st_['err']:>+7.2f}  {st_['cum_err']:>+8.2f}")


if __name__ == "__main__":
    main()
