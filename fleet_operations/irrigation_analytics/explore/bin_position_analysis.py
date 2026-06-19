#!/usr/bin/env python3
"""
Bin-position median analysis.

For each target bin:
  - rows = runs, cols = sample position k
  - per-position median + MAD across all runs
  - per-run anomaly score (mean |z| using MAD-normalized deviation)
  - rank runs, look for outlier clusters (expected: pipe-break episodes
    spanning multiple consecutive runs)

Run with:
  ./bin_position_analysis.py
"""
import json
import statistics
import math
from pathlib import Path

HERE = Path(__file__).parent
TIME_HISTORY = HERE / "data" / "time_history.json"

SAMPLE0_SKIP = True   # known timing race (σ_s0=0.153 vs σ_s1=0.005)
START_K = 2 if SAMPLE0_SKIP else 0   # "from 2 .. N" per user spec
MIN_RUNS_AT_K = 5     # need at least this many runs covering position k
                      # to trust the median there
TAIL_TRIM = True      # drop trailing-zero close-out samples per run

TARGET_BINS = {
    "bin_A_4_11_alone":     ["satellite_4:11"],
    "bin_B_4_11_with_139":  ["satellite_1:39/satellite_4:11",
                             "satellite_4:11/satellite_1:39"],
    "bin_C_3_5_alone":      ["satellite_3:5"],
    "bin_D_3_5_with_139":   ["satellite_1:39/satellite_3:5",
                             "satellite_3:5/satellite_1:39"],
    "bin_E_4_12_alone":     ["satellite_4:12"],
    "bin_F_4_12_with_139":  ["satellite_1:39/satellite_4:12",
                             "satellite_4:12/satellite_1:39"],
    "bin_G_4_10_alone":     ["satellite_4:10"],
    "bin_H_4_10_with_139":  ["satellite_1:39/satellite_4:10"],
}


def trim_run(samples):
    """Drop trailing near-zero samples (post-close) and return active part."""
    if not TAIL_TRIM:
        return samples
    n = len(samples)
    while n > 0 and samples[n - 1] <= 1e-6:
        n -= 1
    return samples[:n]


def mad(values, med):
    if not values:
        return 0.0
    return statistics.median([abs(v - med) for v in values])


def per_position_stats(runs, signal="IRRIGATION_CURRENT", sd_floor=0.005):
    """For each k starting at START_K, gather all run values at that position.
       Return list of dicts: k, n, median, mad, p25, p75.
       Signal can be IRRIGATION_CURRENT or HUNTER_FLOW_METER."""
    # Track active-run length by current (not flow), so flow stats only count
    # positions where the run was actually running.
    max_len = max((len(trim_run(r['IRRIGATION_CURRENT']['data']))
                   for r in runs), default=0)
    stats = []
    for k in range(START_K, max_len):
        vals = []
        for r in runs:
            active = trim_run(r['IRRIGATION_CURRENT']['data'])
            if k >= len(active):
                continue
            d = r.get(signal, {}).get('data', [])
            if k < len(d):
                vals.append(d[k])
        if len(vals) < MIN_RUNS_AT_K:
            continue
        vs = sorted(vals)
        med = statistics.median(vs)
        m = mad(vs, med)
        sd_robust = max(m * 1.4826, sd_floor)
        n = len(vs)
        p25 = vs[int(n * 0.25)]
        p75 = vs[int(n * 0.75)]
        stats.append({
            "k":          k,
            "n":          n,
            "median":     med,
            "mad":        m,
            "sd_robust":  sd_robust,
            "p25":        p25,
            "p75":        p75,
        })
    return stats


def per_run_score(runs, pos_stats, flow_pos_stats=None):
    """Score each run: mean |z| over its valid positions, and count of |z|>3.
    Also report flow-mean to detect pipe-break signature (elevated flow).
    If flow_pos_stats given, also compute per-position flow z."""
    by_k = {s["k"]: s for s in pos_stats}
    by_k_f = {s["k"]: s for s in (flow_pos_stats or [])}
    out = []
    for idx, r in enumerate(runs):
        d = trim_run(r['IRRIGATION_CURRENT']['data'])
        hf = r.get('HUNTER_FLOW_METER', {}).get('data', [])
        # flow-mean over the run, ignoring zero edges
        hf_active = [v for v in hf[:len(d)] if v > 0]
        flow_mean = statistics.mean(hf_active) if hf_active else 0.0
        flow_total = sum(hf[:len(d)])
        zs = []
        zs_f = []
        for k in range(START_K, len(d)):
            s = by_k.get(k)
            if s is not None:
                z = (d[k] - s["median"]) / s["sd_robust"]
                zs.append(z)
            sf = by_k_f.get(k)
            if sf is not None and k < len(hf):
                zf = (hf[k] - sf["median"]) / sf["sd_robust"]
                zs_f.append(zf)
        # asymptote of this run for context
        asym = statistics.mean(d[-3:]) if len(d) >= 3 else None
        entry = {
            "idx":            idx,
            "n_pts":          len(zs),
            "mean_abs_z":     statistics.mean([abs(z) for z in zs]) if zs else 0,
            "max_abs_z":      max((abs(z) for z in zs), default=0),
            "n_z_gt3":        sum(1 for z in zs if abs(z) > 3),
            "n_z_gt2":        sum(1 for z in zs if abs(z) > 2),
            "signed_mean_z":  statistics.mean(zs) if zs else 0,
            "run_len":        len(d),
            "asym":           asym,
            "flow_mean":      flow_mean,
            "flow_total":     flow_total,
            # flow per-position z
            "flow_mean_abs_z":    statistics.mean([abs(z) for z in zs_f]) if zs_f else 0,
            "flow_max_abs_z":     max((abs(z) for z in zs_f), default=0),
            "flow_n_z_gt2":       sum(1 for z in zs_f if abs(z) > 2),
            "flow_signed_mean_z": statistics.mean(zs_f) if zs_f else 0,
        }
        out.append(entry)
    return out


def cluster_outliers(scores, threshold=2.0):
    """Find contiguous outlier runs (run-index clusters)."""
    flagged = [i for i, s in enumerate(scores) if s["mean_abs_z"] > threshold]
    if not flagged:
        return []
    clusters = []
    cur = [flagged[0]]
    for i in flagged[1:]:
        if i - cur[-1] <= 2:    # allow gap of 1 healthy run between bad runs
            cur.append(i)
        else:
            clusters.append(cur)
            cur = [i]
    clusters.append(cur)
    return clusters


def analyze_bin(name, runs):
    print(f"\n{'='*78}")
    print(f"BIN: {name}   ({len(runs)} runs)")
    print('=' * 78)
    pos = per_position_stats(runs, signal="IRRIGATION_CURRENT", sd_floor=0.005)
    pos_f = per_position_stats(runs, signal="HUNTER_FLOW_METER", sd_floor=0.5)
    if not pos:
        print("  no positions met MIN_RUNS_AT_K — skip")
        return None
    print(f"  current positions: k = {pos[0]['k']} .. {pos[-1]['k']}   "
          f"(n_pos={len(pos)})")
    if pos_f:
        print(f"  flow positions:    k = {pos_f[0]['k']} .. {pos_f[-1]['k']}   "
              f"(n_pos={len(pos_f)})")
    # show median curve compressed
    print(f"\n  per-position median (every 5th):")
    print(f"    {'k':>4}  {'n':>4}  {'median':>7}  {'MAD':>6}  {'σ_rob':>6}")
    for s in pos[::5]:
        print(f"    {s['k']:>4}  {s['n']:>4}  "
              f"{s['median']:>7.3f}  {s['mad']:>6.3f}  {s['sd_robust']:>6.3f}")
    # last position too if not caught
    if pos[-1]['k'] % 5 != 0:
        s = pos[-1]
        print(f"    {s['k']:>4}  {s['n']:>4}  "
              f"{s['median']:>7.3f}  {s['mad']:>6.3f}  {s['sd_robust']:>6.3f}")

    scores = per_run_score(runs, pos, flow_pos_stats=pos_f)
    # flow baseline (median across all runs, mean of active samples)
    flow_means = [s["flow_mean"] for s in scores if s["flow_mean"] > 0]
    flow_baseline = statistics.median(flow_means) if flow_means else 0.0

    # use whichever is bigger: current or flow per-position score
    for s in scores:
        s["combined_z"] = max(s["mean_abs_z"], s["flow_mean_abs_z"])

    print(f"\n  per-run scores — sorted by max(current_meanZ, flow_meanZ) — top 15:")
    print(f"    flow baseline (median of run flow_mean): {flow_baseline:.3f}")
    print(f"    {'#':>3} {'idx':>4} {'len':>4} {'asym':>6}    "
          f"{'curZ':>6} {'cMaxZ':>6} {'csgnZ':>6}    "
          f"{'flwZ':>6} {'fMaxZ':>6} {'fsgnZ':>6} {'flowM':>6}")
    sorted_scores = sorted(scores, key=lambda s: s["combined_z"], reverse=True)
    for rank, s in enumerate(sorted_scores[:15], 1):
        asym_s = f"{s['asym']:.3f}" if s['asym'] is not None else "  -- "
        print(f"    {rank:>3} {s['idx']:>4} {s['run_len']:>4} {asym_s:>6}    "
              f"{s['mean_abs_z']:>6.2f} {s['max_abs_z']:>6.2f} "
              f"{s['signed_mean_z']:>+6.2f}    "
              f"{s['flow_mean_abs_z']:>6.2f} {s['flow_max_abs_z']:>6.2f} "
              f"{s['flow_signed_mean_z']:>+6.2f} {s['flow_mean']:>6.2f}")

    # Always show the LAST run too (catches recent operator-missed leaks)
    last = scores[-1]
    print(f"\n  *** MOST-RECENT RUN (idx={last['idx']}):")
    print(f"      current meanZ={last['mean_abs_z']:.2f}  signZ={last['signed_mean_z']:+.2f}  asym={last['asym']:.3f}")
    print(f"      flow    meanZ={last['flow_mean_abs_z']:.2f}  signZ={last['flow_signed_mean_z']:+.2f}  flow_mean={last['flow_mean']:.2f}")

    # cluster detection on CURRENT
    print(f"\n  outlier clusters by run-index (current, consecutive bad runs):")
    for thresh in (2.0, 1.5, 1.0):
        clusters = cluster_outliers(scores, threshold=thresh)
        if clusters:
            print(f"    current mean|z| > {thresh}:")
            for c in clusters:
                signs = [scores[i]["signed_mean_z"] for i in c]
                avg_sign = statistics.mean(signs)
                direction = "HIGH" if avg_sign > 0 else "LOW"
                print(f"      idx {c[0]}..{c[-1]}  (n={len(c)})  "
                      f"avg_signed_z={avg_sign:+.2f}  ({direction})")

    # cluster detection on FLOW
    print(f"\n  outlier clusters by run-index (flow, consecutive bad runs):")
    for thresh in (2.0, 1.5, 1.0):
        # use flow_mean_abs_z
        flagged = [i for i, s in enumerate(scores) if s["flow_mean_abs_z"] > thresh]
        if not flagged:
            continue
        clusters = []
        cur = [flagged[0]]
        for i in flagged[1:]:
            if i - cur[-1] <= 2:
                cur.append(i)
            else:
                clusters.append(cur)
                cur = [i]
        clusters.append(cur)
        if clusters:
            print(f"    flow mean|z| > {thresh}:")
            for c in clusters:
                signs = [scores[i]["flow_signed_mean_z"] for i in c]
                avg_sign = statistics.mean(signs)
                direction = "HIGH" if avg_sign > 0 else "LOW"
                print(f"      idx {c[0]}..{c[-1]}  (n={len(c)})  "
                      f"avg_flow_signed_z={avg_sign:+.2f}  ({direction})")
    return {"name": name, "pos": pos, "pos_f": pos_f, "scores": scores}


def plot_bin(name, runs, pos, scores, out_dir):
    """Three panels: median ± MAD + outlier runs overlaid; per-run scores;
       flow_mean vs run idx."""
    try:
        import matplotlib
        matplotlib.use("Agg")
        import matplotlib.pyplot as plt
    except ImportError:
        return None

    fig, axes = plt.subplots(3, 1, figsize=(12, 11))

    # --- panel 1: per-position median + healthy band + bad runs overlaid
    ks = [s["k"] for s in pos]
    meds = [s["median"] for s in pos]
    p25s = [s["p25"] for s in pos]
    p75s = [s["p75"] for s in pos]

    ax = axes[0]
    ax.fill_between(ks, p25s, p75s, alpha=0.25, label="p25-p75 band")
    ax.plot(ks, meds, lw=2, label="median", color="black")
    # overlay top-5 deviated runs
    top5 = sorted(scores, key=lambda s: s["mean_abs_z"], reverse=True)[:5]
    for s in top5:
        r = runs[s["idx"]]
        d = trim_run(r['IRRIGATION_CURRENT']['data'])
        xs = list(range(START_K, len(d)))
        ys = d[START_K:]
        ax.plot(xs, ys, alpha=0.7,
                label=f"idx={s['idx']} z̄={s['mean_abs_z']:.2f}")
    ax.set_xlabel("sample position k (1-min)")
    ax.set_ylabel("IRRIGATION_CURRENT (A)")
    ax.set_title(f"{name} — per-position median (n={len(runs)} runs) + top-5 outlier runs")
    ax.legend(loc="best", fontsize=8)
    ax.grid(True, alpha=0.3)

    # --- panel 2: per-run mean |z| in run-index order
    ax = axes[1]
    by_idx = sorted(scores, key=lambda s: s["idx"])
    ax.bar([s["idx"] for s in by_idx],
           [s["signed_mean_z"] for s in by_idx],
           color=["red" if s["signed_mean_z"] > 0 else "blue" for s in by_idx])
    ax.axhline(2.0, color="gray", linestyle="--", alpha=0.5)
    ax.axhline(-2.0, color="gray", linestyle="--", alpha=0.5)
    ax.axhline(1.0, color="gray", linestyle=":", alpha=0.5)
    ax.axhline(-1.0, color="gray", linestyle=":", alpha=0.5)
    ax.set_xlabel("run index (storage order — chronology unknown)")
    ax.set_ylabel("signed mean z")
    ax.set_title("per-run signed-mean-z (red = current ABOVE median, blue = BELOW)")
    ax.grid(True, alpha=0.3)

    # --- panel 3: flow_mean vs run idx
    ax = axes[2]
    flow_means = [s["flow_mean"] for s in by_idx]
    fb = statistics.median([f for f in flow_means if f > 0]) if flow_means else 0
    ax.bar([s["idx"] for s in by_idx], flow_means,
           color=["red" if s["flow_mean"] > 1.3 * fb else "gray" for s in by_idx])
    ax.axhline(fb, color="black", linestyle="-", alpha=0.5, label=f"median flow = {fb:.2f}")
    ax.axhline(1.3 * fb, color="red", linestyle="--", alpha=0.5, label="1.3× median (break candidate)")
    ax.set_xlabel("run index")
    ax.set_ylabel("HUNTER_FLOW mean over run")
    ax.set_title(f"flow_mean per run — pipe-break signature is flow >> baseline")
    ax.legend(loc="best", fontsize=8)
    ax.grid(True, alpha=0.3)

    plt.tight_layout()
    p = out_dir / f"{name}.png"
    plt.savefig(p, dpi=100)
    plt.close()
    return p


def write_csv(name, runs, pos, scores, out_dir):
    """Per-run summary + per-position median for later plotting."""
    # per-run summary
    p = out_dir / f"{name}_runs.csv"
    with open(p, "w") as f:
        f.write("idx,run_len,asym,mean_abs_z,max_abs_z,n_z_gt2,n_z_gt3,signed_mean_z\n")
        for s in scores:
            asym = f"{s['asym']:.4f}" if s['asym'] is not None else ""
            f.write(f"{s['idx']},{s['run_len']},{asym},"
                    f"{s['mean_abs_z']:.3f},{s['max_abs_z']:.3f},"
                    f"{s['n_z_gt2']},{s['n_z_gt3']},{s['signed_mean_z']:.3f}\n")
    # per-position median
    p = out_dir / f"{name}_median.csv"
    with open(p, "w") as f:
        f.write("k,n,median,mad,sd_robust,p25,p75\n")
        for s in pos:
            f.write(f"{s['k']},{s['n']},{s['median']:.4f},{s['mad']:.4f},"
                    f"{s['sd_robust']:.4f},{s['p25']:.4f},{s['p75']:.4f}\n")


def main():
    th = json.loads(TIME_HISTORY.read_text())
    out_dir = HERE / "var"
    out_dir.mkdir(exist_ok=True)
    results = {}
    for name, keys in TARGET_BINS.items():
        runs = []
        for k in keys:
            if k in th:
                runs.extend(th[k])
        if not runs:
            print(f"  bin {name}: no runs found")
            continue
        r = analyze_bin(name, runs)
        if r:
            write_csv(name, runs, r["pos"], r["scores"], out_dir)
            png = plot_bin(name, runs, r["pos"], r["scores"], out_dir)
            results[name] = {"n_runs": len(runs),
                              "n_positions": len(r["pos"]),
                              "plot": str(png) if png else None}
            if png:
                print(f"  plot → {png}")
    print(f"\n\nCSVs written to: {out_dir}/")
    print("  *_runs.csv      per-run scores")
    print("  *_median.csv    per-position median curve")


if __name__ == "__main__":
    main()
