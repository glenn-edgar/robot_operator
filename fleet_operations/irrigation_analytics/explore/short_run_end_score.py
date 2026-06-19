#!/usr/bin/env python3
"""
Short-run end-only failure-score analyzer.

For each solo-valve bin in time_history.json:
  end_mean(run) = mean(run.flow.data[-3:])      # last 3 of 5 steps
  baseline      = median + MAD over historic runs (all but newest)
  newest_score  = end_mean(newest)
  flag if |newest_score - median| > max(K * MAD, gpm_floor)
    K        = 3.5    (Iglewicz-Hoaglin equivalent threshold ~2.3σ)
    gpm_floor = 2.0  (suppress tight-MAD false-positive)

Sign convention:
  Δ > 0 → over-flow → broken / missing / stuck-open head
  Δ < 0 → under-flow → clogged / partially blocked head

Cross-validates against today's operator labels.
"""
import json
import statistics as st
from pathlib import Path

K_MAD       = 3.5
GPM_FLOOR   = 2.0
END_STEPS   = 3

# Today's operator labels (2026-05-28).
# Tree-irrigation cohort: 17 bad heads across 14 valves; 6 clean valves with 0 bad.
# Plus today's three-valve test: 4:13 + 2:2 fail, 2:6 clean.
LABELED_BAD = {
    # tree-irrigation bad-head counts
    "satellite_4:10": 2, "satellite_4:12": 1, "satellite_4:9": 1, "satellite_4:1": 1,
    "satellite_4:4": 2, "satellite_4:7": 1, "satellite_4:3": 1,
    "satellite_3:5": 1, "satellite_2:14": 1, "satellite_2:13": 1,
    "satellite_2:16": 1, "satellite_3:14": 2, "satellite_3:15": 1,
    # today's three-valve test
    "satellite_4:13": "fail", "satellite_2:2": "fail",
}
LABELED_CLEAN = {
    "satellite_4:11", "satellite_3:2", "satellite_2:15", "satellite_3:18", "satellite_3:13",
    "satellite_2:6",
}
# Compound-zone labels (skip from single-valve scoring — need pairing)
LABELED_COMPOUND = {"satellite_4:6/satellite_4:8", "satellite_3:1/satellite_3:7"}


def end_mean(steps, n=END_STEPS):
    if len(steps) < n:
        return None
    return sum(steps[-n:]) / n


def median_and_mad(values):
    if not values:
        return None, None
    med = st.median(values)
    mad = st.median([abs(v - med) for v in values])
    return med, mad


def score_bin(runs):
    """Returns dict with end-only stats for this bin, or None if too few runs."""
    ends = [end_mean(r["HUNTER_FLOW_METER"]["data"]) for r in runs]
    ends = [e for e in ends if e is not None]
    if len(ends) < 8:
        return None
    newest = ends[-1]
    hist = ends[:-1]
    med, mad = median_and_mad(hist)
    delta = newest - med
    # Iglewicz-Hoaglin z (0.6745 / MAD scaling): equivalent σ ≈ MAD / 0.6745
    z = (0.6745 * delta / mad) if mad and mad > 0 else (float("inf") if delta != 0 else 0.0)
    flag_z = abs(z) > K_MAD * 0.6745  # K_MAD on the σ-equivalent scale
    # Simpler: |Δ| > K_MAD * MAD  AND  |Δ| > floor
    flag_mad = abs(delta) > K_MAD * mad if mad and mad > 0 else True
    flag = flag_mad and abs(delta) > GPM_FLOOR
    return {
        "n_runs": len(ends),
        "newest_end": newest,
        "hist_median": med,
        "hist_mad": mad,
        "delta": delta,
        "z": z,
        "flag": flag,
    }


def label_for(bin_name):
    if bin_name in LABELED_BAD:
        v = LABELED_BAD[bin_name]
        return f"BAD ({v})" if isinstance(v, int) else f"BAD ({v})"
    if bin_name in LABELED_CLEAN:
        return "CLEAN"
    return ""


def main():
    p = Path(__file__).parent / "data" / "time_history.json"
    data = json.loads(p.read_text())

    # Solo-valve bins only (no slash in key).
    solo = {k: v for k, v in data.items() if "/" not in k}

    results = []
    for binname, runs in sorted(solo.items()):
        s = score_bin(runs)
        if s is None:
            continue
        s["bin"] = binname
        s["label"] = label_for(binname)
        results.append(s)

    # Print sorted by |delta| descending.
    results.sort(key=lambda r: -abs(r["delta"]))

    print(f"\n=== Short-run end-only score (end = last {END_STEPS} steps; "
          f"K_MAD={K_MAD}, gpm_floor={GPM_FLOOR}) ===\n")
    print(f"  {'bin':<22s} {'n':>3s}  {'newest':>7s} {'med':>6s} {'MAD':>5s}  "
          f"{'Δ gpm':>7s} {'z':>6s}  {'flag':>5s}  label")
    print("  " + "-" * 88)
    for r in results:
        flag_mark = "FAIL" if r["flag"] else ""
        zstr = f"{r['z']:+.1f}" if r['z'] != float('inf') else "  inf"
        print(f"  {r['bin']:<22s} {r['n_runs']:>3d}  {r['newest_end']:>7.2f} "
              f"{r['hist_median']:>6.2f} {r['hist_mad']:>5.2f}  "
              f"{r['delta']:>+7.2f} {zstr:>6s}  {flag_mark:>5s}  {r['label']}")

    # Confusion vs labels.
    print("\n=== Confusion vs operator labels ===")
    tp = fn = fp = tn = 0
    for r in results:
        is_bad = r["bin"] in LABELED_BAD
        is_clean = r["bin"] in LABELED_CLEAN
        flagged = r["flag"]
        if is_bad and flagged: tp += 1
        elif is_bad and not flagged: fn += 1
        elif is_clean and flagged: fp += 1
        elif is_clean and not flagged: tn += 1
    print(f"  labeled-bad  / flagged     (TP): {tp:>2d}")
    print(f"  labeled-bad  / not flagged (FN): {fn:>2d}")
    print(f"  labeled-clean/ flagged     (FP): {fp:>2d}")
    print(f"  labeled-clean/ not flagged (TN): {tn:>2d}")
    if tp + fn > 0:
        print(f"  recall:   {tp/(tp+fn):.2f}")
    if tp + fp > 0:
        print(f"  precision:{tp/(tp+fp):.2f}")


if __name__ == "__main__":
    main()
