#!/usr/bin/env python3
"""
Characterize the TIME_HISTORY run data — what does it actually look like?

Questions answered here:
  1. Run-shape: is I(t) monotone-down toward asymptote (thermal-decay model)?
  2. Sample[0] validity: how often is sample[0] anomalous vs sample[1+]?
  3. Run length distribution: variable within a bin? across bins?
  4. Run-over-run reproducibility: same valve set, different days — how stable?
  5. The 7.3 A outlier bin (sat_1:27/sat_1:39) — what's actually there?
  6. EQUIPMENT_CURRENT ↔ IRRIGATION_CURRENT coupling (supply sag detection)
  7. Flow × current cross-correlation
  8. Spike presence in historical data
"""
import json, statistics, math
from pathlib import Path

OFFSET = 0.0767  # ACS712 null from daily disconnect refs


def load():
    p = Path(__file__).parent / "data" / "time_history.json"
    return json.loads(p.read_text())


def nonzero_prefix(samples):
    """Trim trailing zeros (post-valve-close)."""
    n = len(samples)
    while n > 0 and samples[n-1] <= 1e-6: n -= 1
    return samples[:n]


def section(title):
    print(f"\n{'='*4} {title} {'='*(75-len(title))}\n")


def main():
    th = load()

    # ── Q1+Q2: monotone-decay + sample[0] validity ─────────────────────
    section("Q1+Q2: Run shape (monotone? sample[0] valid?)")
    # Pick a clean solo-zone bin with reasonable run length
    candidates = []
    for bin_key, runs in th.items():
        if "/" in bin_key: continue
        if not runs: continue
        avg_len = statistics.mean(len(nonzero_prefix(r["IRRIGATION_CURRENT"]["data"])) for r in runs)
        if avg_len >= 8: candidates.append((bin_key, avg_len, len(runs)))
    candidates.sort(key=lambda x: -x[1])
    print(f"  solo bins with avg run-length ≥ 8 min: {len(candidates)}")
    for bin_key, avg_len, n_runs in candidates[:4]:
        print(f"    {bin_key:<20}  avg_len={avg_len:.1f}  n_runs={n_runs}")

    # Look at a single clean bin in depth
    if candidates:
        bin_key = candidates[0][0]
        print(f"\n  Deep look at: {bin_key}")
        runs = th[bin_key]
        # Show last 5 runs as I(t)
        print(f"  Last 5 runs (samples shown):")
        for i, run in enumerate(runs[-5:]):
            ic = nonzero_prefix(run["IRRIGATION_CURRENT"]["data"])
            print(f"    run -{5-i}: ", " ".join(f"{x:.3f}" for x in ic))

        # Sample[0] vs sample[1] vs asymptote across all 49 runs
        s0s, s1s, asyms, sdiffs01 = [], [], [], []
        for run in runs:
            ic = nonzero_prefix(run["IRRIGATION_CURRENT"]["data"])
            if len(ic) >= 3:
                s0s.append(ic[0]); s1s.append(ic[1])
                asyms.append(statistics.mean(ic[-3:]))
                sdiffs01.append(ic[1] - ic[0])
        print(f"\n  Across 49 runs for {bin_key}:")
        print(f"    sample[0]:   μ={statistics.mean(s0s):.3f}  σ={statistics.pstdev(s0s):.3f}  min/max={min(s0s):.3f}/{max(s0s):.3f}")
        print(f"    sample[1]:   μ={statistics.mean(s1s):.3f}  σ={statistics.pstdev(s1s):.3f}  min/max={min(s1s):.3f}/{max(s1s):.3f}")
        print(f"    asymptote:   μ={statistics.mean(asyms):.3f}  σ={statistics.pstdev(asyms):.3f}")
        print(f"    s[1]-s[0]:   μ={statistics.mean(sdiffs01):+.3f}  σ={statistics.pstdev(sdiffs01):.3f}")
        print(f"    → if s[0] is invalid, expect large σ on s[0] vs s[1], or s[0]≠s[1] consistently.")

    # ── Q3: run-length distribution ────────────────────────────────────
    section("Q3: Run length distribution")
    lens = []
    for bin_key, runs in th.items():
        for run in runs:
            ic = nonzero_prefix(run["IRRIGATION_CURRENT"]["data"])
            if ic: lens.append(len(ic))
    lens.sort()
    print(f"  All runs: n={len(lens)}")
    print(f"    min={lens[0]}  p25={lens[len(lens)//4]}  median={lens[len(lens)//2]}  p75={lens[3*len(lens)//4]}  max={lens[-1]}")
    # buckets
    from collections import Counter
    buckets = Counter()
    for L in lens:
        if L <= 2: buckets["1-2 (too short)"] += 1
        elif L <= 5: buckets["3-5"] += 1
        elif L <= 10: buckets["6-10"] += 1
        elif L <= 20: buckets["11-20"] += 1
        elif L <= 60: buckets["21-60"] += 1
        else: buckets["61+"] += 1
    for k, v in [("1-2 (too short)","1-2 (too short)"),("3-5","3-5"),("6-10","6-10"),
                 ("11-20","11-20"),("21-60","21-60"),("61+","61+")]:
        print(f"    {k:<18} {buckets.get(k, 0):>5}")

    # ── Q4: run-over-run reproducibility ──────────────────────────────
    section("Q4: Same-bin run-over-run reproducibility")
    # For each bin, compute asymptote across all 49 runs; report bins with widest spread
    spreads = []
    for bin_key, runs in th.items():
        asyms = []
        for run in runs:
            ic = nonzero_prefix(run["IRRIGATION_CURRENT"]["data"])
            if len(ic) >= 3: asyms.append(statistics.mean(ic[-3:]))
        if len(asyms) >= 5:
            spreads.append((bin_key, statistics.mean(asyms), statistics.pstdev(asyms),
                           min(asyms), max(asyms), len(asyms)))
    print(f"  {'bin':<48} {'μ_asym':>7} {'σ':>6} {'min':>6} {'max':>6} {'n':>3}")
    # most stable (smallest σ)
    spreads.sort(key=lambda r: r[2])
    print(f"\n  ── 5 most stable bins (smallest σ across 49 runs) ──")
    for r in spreads[:5]:
        print(f"  {r[0]:<48} {r[1]:7.3f} {r[2]:6.3f} {r[3]:6.3f} {r[4]:6.3f} {r[5]:>3}")
    print(f"\n  ── 5 most variable bins (largest σ) ──")
    for r in spreads[-5:]:
        print(f"  {r[0]:<48} {r[1]:7.3f} {r[2]:6.3f} {r[3]:6.3f} {r[4]:6.3f} {r[5]:>3}")

    # ── Q5: the 7.3 A outlier bin ─────────────────────────────────────
    section("Q5: The 7.3 A outlier bin")
    target = "satellite_1:27/satellite_1:39"
    if target in th:
        runs = th[target]
        print(f"  bin: {target}  n_runs: {len(runs)}")
        asyms = []
        for i, run in enumerate(runs):
            ic = nonzero_prefix(run["IRRIGATION_CURRENT"]["data"])
            if not ic: continue
            asym = statistics.mean(ic[-3:]) if len(ic) >= 3 else ic[-1]
            asyms.append(asym)
            if i < 3 or i >= len(runs)-3:
                print(f"    run {i:>2}: len={len(ic)} I=", " ".join(f"{x:.3f}" for x in ic))
        print(f"  asymptote across all runs: μ={statistics.mean(asyms):.3f}  σ={statistics.pstdev(asyms):.3f}")
        print(f"                             min={min(asyms):.3f}  max={max(asyms):.3f}")
        print(f"  → if ALL runs ≈ 7.3 A, it's a real measurement (not a one-shot fault)")
        print(f"  → likely well-pump fired with this valve combo and is counted in IRRIGATION_CURRENT")

    # ── Q6: EQUIPMENT_CURRENT coupling ─────────────────────────────────
    section("Q6: EQUIPMENT_CURRENT ↔ IRRIGATION_CURRENT coupling (supply sag)")
    pairs = []
    for bin_key, runs in th.items():
        for run in runs:
            ic = nonzero_prefix(run["IRRIGATION_CURRENT"]["data"])
            eq = nonzero_prefix(run["EQUIPMENT_CURRENT"]["data"])
            if len(ic) >= 3 and len(eq) >= 3:
                pairs.append((statistics.mean(ic[-3:]), statistics.mean(eq[-3:])))
    if pairs:
        # quick Pearson r
        n = len(pairs)
        xs = [p[0] for p in pairs]; ys = [p[1] for p in pairs]
        mx, my = statistics.mean(xs), statistics.mean(ys)
        num = sum((x-mx)*(y-my) for x, y in pairs)
        den = math.sqrt(sum((x-mx)**2 for x in xs) * sum((y-my)**2 for y in ys))
        r = num/den if den > 1e-9 else 0.0
        print(f"  n={n} (run, asymptote pairs)")
        print(f"  IRRIGATION_CURRENT μ={mx:.3f}  σ={statistics.pstdev(xs):.3f}  range={min(xs):.3f}..{max(xs):.3f}")
        print(f"  EQUIPMENT_CURRENT  μ={my:.3f}  σ={statistics.pstdev(ys):.3f}  range={min(ys):.3f}..{max(ys):.3f}")
        print(f"  Pearson r = {r:+.3f}  (|r|>0.3 = real coupling; supply sag suspected if r>0)")

    # ── Q7: Flow × current cross-correlation ──────────────────────────
    section("Q7: Flow × current cross-correlation")
    pairs = []
    for bin_key, runs in th.items():
        for run in runs:
            ic = nonzero_prefix(run["IRRIGATION_CURRENT"]["data"])
            hf = run["HUNTER_FLOW_METER"]["data"]
            if len(ic) >= 3:
                ic_asym = statistics.mean(ic[-3:])
                flow_total = sum(hf)
                pairs.append((ic_asym, flow_total))
    if pairs:
        n = len(pairs)
        xs = [p[0] for p in pairs]; ys = [p[1] for p in pairs]
        mx, my = statistics.mean(xs), statistics.mean(ys)
        num = sum((x-mx)*(y-my) for x, y in pairs)
        den = math.sqrt(sum((x-mx)**2 for x in xs) * sum((y-my)**2 for y in ys))
        r = num/den if den > 1e-9 else 0.0
        print(f"  n={n} (asymptote I, total flow gal) pairs")
        print(f"  Pearson r (I_asym, flow_total) = {r:+.3f}")
        # Categorize: I_asym normal but flow_total = 0
        zero_flow_count = sum(1 for ic, fl in pairs if ic > 0.4 and fl < 1.0)
        print(f"  Pairs with I>0.4 but flow≈0: {zero_flow_count}  (well-mode runs OR mechanical-fault candidates)")

    # ── Q8: Spike detection in historical data ────────────────────────
    section("Q8: Historical spikes (sample > 1.5× expected)")
    spike_count = 0; total_runs = 0
    spike_examples = []
    for bin_key, runs in th.items():
        n_valves = bin_key.count("/") + 1
        for i, run in enumerate(runs):
            ic = nonzero_prefix(run["IRRIGATION_CURRENT"]["data"])
            if len(ic) < 3: continue
            total_runs += 1
            asym = statistics.mean(ic[-3:])
            # spike: any sample > 1.5 × asymptote
            spikes = [(j, s) for j, s in enumerate(ic) if s > 1.5 * asym and asym > 0.1]
            if spikes:
                spike_count += 1
                if len(spike_examples) < 5:
                    spike_examples.append((bin_key, i, len(runs)-1-i, asym, spikes))
    print(f"  Runs with spikes: {spike_count}/{total_runs}  ({100*spike_count/max(total_runs,1):.1f}%)")
    for bin_key, idx, age_ago, asym, spikes in spike_examples:
        print(f"    {bin_key:<40} (run {idx}, {age_ago} ago)  asym={asym:.3f}  spikes at: {[(j, f'{s:.3f}') for j,s in spikes][:3]}")


if __name__ == "__main__":
    main()
