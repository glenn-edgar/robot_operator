#!/usr/bin/env python3
"""
Build per-bin "last week" curve profiles for the Thursday bad-head comparison.

For each unique valve set (combining multiple key orderings if present):
  - take the most-recent LAST_N runs from each contributing key
  - compute per-position (k=2..K) median + MAD over IRRIGATION_CURRENT
    and HUNTER_FLOW_METER
  - per-run linear fit (slope + intercept) — the 2-param shape model
  - flag with_139 (city-water-stabilized) vs not, since their statistics
    are categorically different

Output: weekly_profiles_YYYY-MM-DD.json (current date)

Tomorrow (Thursday) usage:
  - operator labels bad heads
  - for each labeled valve, fresh-run that night
  - new run vs profile → fault signature

Cadence note: We don't have per-run timestamps in time_history.json. The
"last N runs per key" proxy assumes ~daily irrigation cadence, so N=7 ≈
one week. Sparse bins get all available runs.
"""
import json
import statistics
import math
from pathlib import Path
from datetime import date
from collections import defaultdict


HERE = Path(__file__).parent
TIME_HISTORY = HERE / "data" / "time_history.json"

LAST_N = 7              # runs per key to keep (≈ one week assuming daily cadence)
SAMPLE0_SKIP = True
START_K = 2 if SAMPLE0_SKIP else 0
MIN_RUNS_AT_K = 2       # tolerate small samples — these are SNAPSHOTS, not baselines
TAIL_TRIM = True

CITY_WATER_VALVE = "satellite_1:39"

# Bimodal split: well-mode runs draw 5-10× normal current.
# If max(asym)/min(asym) > BIMODAL_RATIO and a gap exists, split into pump_off
# and pump_on sub-profiles (mirrors bin_baselines.py).
BIMODAL_RATIO = 2.5
BIMODAL_GAP_FRAC = 0.5


def trim_run(samples):
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


def per_position(runs, signal, sd_floor):
    """For each k, gather all values where the run was active. Min 2 to record."""
    max_len = max((len(trim_run(r['IRRIGATION_CURRENT']['data']))
                   for r in runs), default=0)
    out = []
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
        med = statistics.median(vals)
        m   = mad(vals, med)
        sd_robust = max(m * 1.4826, sd_floor)
        out.append({
            "k":         k,
            "n":         len(vals),
            "median":    round(med, 4),
            "mad":       round(m, 4),
            "sd_robust": round(sd_robust, 4),
        })
    return out


def asymptote(samples):
    """Mean of last 3 active samples — coil at steady state."""
    n = len(samples)
    while n > 0 and samples[n - 1] <= 1e-6:
        n -= 1
    return statistics.mean(samples[max(0, n-3):n]) if n >= 3 else None


def detect_bimodal_runs(runs):
    """Find largest gap in asymptote distribution.
    Returns (is_bimodal, split_at, pump_off_runs, pump_on_runs)."""
    a_pairs = []
    for r in runs:
        a = asymptote(r['IRRIGATION_CURRENT']['data'])
        if a is not None:
            a_pairs.append((a, r))
    if len(a_pairs) < 4:
        return False, None, [], []
    a_pairs.sort(key=lambda p: p[0])
    asyms = [p[0] for p in a_pairs]
    if asyms[-1] / max(asyms[0], 1e-3) < BIMODAL_RATIO:
        return False, None, [], []
    # Find biggest gap
    med = statistics.median(asyms)
    gaps = [(asyms[i+1] - asyms[i], (asyms[i] + asyms[i+1]) / 2)
            for i in range(len(asyms) - 1)]
    max_gap, split = max(gaps, key=lambda x: x[0])
    if max_gap < BIMODAL_GAP_FRAC * med:
        return False, None, [], []
    off = [p[1] for p in a_pairs if p[0] <  split]
    on  = [p[1] for p in a_pairs if p[0] >= split]
    if len(off) < 2 or len(on) < 2:
        return False, None, [], []
    return True, split, off, on


def linear_fit(samples):
    """Skip k=0,1; OLS slope + intercept against k. Return None if too few."""
    pts = [(k, v) for k, v in enumerate(samples) if k >= START_K and v > 1e-6]
    n = len(pts)
    if n < 4:
        return None
    xs = [p[0] for p in pts]; ys = [p[1] for p in pts]
    mx, my = statistics.mean(xs), statistics.mean(ys)
    num = sum((x - mx) * (y - my) for x, y in pts)
    den = sum((x - mx) ** 2 for x in xs)
    if den < 1e-9:
        return None
    slope = num / den
    intercept = my - slope * mx
    return {"slope": round(slope, 6),
            "intercept": round(intercept, 4),
            "n_pts": n,
            "first_k": pts[0][0],
            "last_k":  pts[-1][0]}


def agg(vs):
    if len(vs) < 2:
        return None
    return {"mu": round(statistics.mean(vs), 6),
            "sd": round(statistics.pstdev(vs), 6), "n": len(vs)}


def build_sub_profile(runs):
    """Build the stats dict for a set of runs (already split if bimodal)."""
    pos_c = per_position(runs, "IRRIGATION_CURRENT", sd_floor=0.005)
    pos_f = per_position(runs, "HUNTER_FLOW_METER",  sd_floor=0.5)
    if not pos_c:
        return None
    fits = []
    for i, r in enumerate(runs):
        cf = linear_fit(r['IRRIGATION_CURRENT']['data'])
        ff = linear_fit(r['HUNTER_FLOW_METER']['data'])
        run_len = len(trim_run(r['IRRIGATION_CURRENT']['data']))
        asym = asymptote(r['IRRIGATION_CURRENT']['data'])
        fits.append({
            "in_window_idx":  i,
            "run_len":        run_len,
            "asym":           round(asym, 4) if asym else None,
            "current_fit":    cf,
            "flow_fit":       ff,
        })
    c_slopes     = [f["current_fit"]["slope"]     for f in fits if f["current_fit"]]
    c_intercepts = [f["current_fit"]["intercept"] for f in fits if f["current_fit"]]
    f_slopes     = [f["flow_fit"]["slope"]        for f in fits if f["flow_fit"]]
    f_intercepts = [f["flow_fit"]["intercept"]    for f in fits if f["flow_fit"]]
    return {
        "n_runs":        len(runs),
        "current": {
            "per_position": pos_c,
            "linear":       {"slope": agg(c_slopes), "intercept": agg(c_intercepts)},
        },
        "flow": {
            "per_position": pos_f,
            "linear":       {"slope": agg(f_slopes), "intercept": agg(f_intercepts)},
        },
        "per_run_fits":  fits,
    }


def main():
    th = json.loads(TIME_HISTORY.read_text())

    # Group bin keys by sorted valve set
    sets = defaultdict(list)
    for k in th:
        valve_set = tuple(sorted(k.split('/')))
        sets[valve_set].append(k)

    today = date.today().isoformat()
    profiles = {}
    summary_rows = []
    skipped = []
    bimodal_bins = []

    for valve_set, keys in sorted(sets.items()):
        # Last LAST_N from each contributing key
        runs = []
        per_key_n = {}
        for k in keys:
            tail = th[k][-LAST_N:]
            per_key_n[k] = len(tail)
            runs.extend(tail)

        if not runs:
            skipped.append((valve_set, "no runs"))
            continue
        if len(runs) < 2:
            skipped.append((valve_set, f"only {len(runs)} run"))
            continue

        bin_id = "+".join(valve_set)
        bimodal, split_at, off_runs, on_runs = detect_bimodal_runs(runs)

        profile = {
            "bin_id":           bin_id,
            "valve_set":        list(valve_set),
            "with_city_water":  CITY_WATER_VALVE in valve_set,
            "source_keys":      keys,
            "runs_per_key":     per_key_n,
            "n_runs_in_window": len(runs),
            "last_n_per_key":   LAST_N,
            "k_skip":           START_K,
            "captured_at":      today,
            "bimodal":          bimodal,
        }
        if bimodal:
            bimodal_bins.append((bin_id, split_at, len(off_runs), len(on_runs)))
            profile["split_at_asym"] = round(split_at, 3)
            profile["pump_off"] = build_sub_profile(off_runs)
            profile["pump_on"]  = build_sub_profile(on_runs)
            if not profile["pump_off"] or not profile["pump_on"]:
                skipped.append((valve_set, "bimodal sub-profile failed"))
                continue
        else:
            sub = build_sub_profile(runs)
            if not sub:
                skipped.append((valve_set, "no current positions met MIN_RUNS_AT_K"))
                continue
            # flatten the unimodal case
            profile["n_runs"]       = sub["n_runs"]
            profile["current"]      = sub["current"]
            profile["flow"]         = sub["flow"]
            profile["per_run_fits"] = sub["per_run_fits"]

        profiles[bin_id] = profile

        # summary row — pick pump_off as the "normal" view for bimodal bins
        src = profile["pump_off"] if profile["bimodal"] else profile
        pos_c = src["current"]["per_position"]
        pos_f = src["flow"]["per_position"]
        fits = src["per_run_fits"]
        c_med = pos_c[0]["median"] if pos_c else None
        f_med = pos_f[0]["median"] if pos_f else None
        run_lens = [f["run_len"] for f in fits]
        c_int = src["current"]["linear"]["intercept"]
        c_slp = src["current"]["linear"]["slope"]
        summary_rows.append({
            "bin_id":        bin_id,
            "n":             src["n_runs"],
            "with_139":      profile["with_city_water"],
            "bimodal":       profile["bimodal"],
            "I_med_k2":      c_med,
            "F_med_k2":      f_med,
            "len_med":       int(statistics.median(run_lens)) if run_lens else 0,
            "I_int_mu":      c_int["mu"] if c_int else None,
            "I_int_sd":      c_int["sd"] if c_int else None,
            "I_slope_mu":    c_slp["mu"] if c_slp else None,
        })

    out_path = HERE / f"weekly_profiles_{today}.json"
    out_path.write_text(json.dumps(profiles, indent=2))

    # Summary
    print(f"\n=== weekly profile build {today} ===")
    print(f"  bins (valve sets) found:    {len(sets)}")
    print(f"  profiles built:             {len(profiles)}")
    print(f"  bimodal (pump-on detected): {len(bimodal_bins)}")
    print(f"  skipped (too sparse):       {len(skipped)}")
    print(f"  LAST_N per key:             {LAST_N}")
    print(f"  output:                     {out_path}")
    if bimodal_bins:
        print(f"\n  bimodal bins (pump_off / pump_on split):")
        for bid, split, n_off, n_on in bimodal_bins:
            print(f"    {bid:<55} split@{split:>5.2f}A  off={n_off}  on={n_on}")
    if skipped:
        print(f"\n  skipped detail (first 10):")
        for vs, reason in skipped[:10]:
            print(f"    {'+'.join(vs):<60}  {reason}")

    # Per-bin one-liner — sort by descending interest (with-139 first by I_int_mu)
    print(f"\n  per-bin snapshot (sorted by I_intercept_mu, with_139 only):")
    print(f"    {'bin_id':<50} {'n':>3} {'I_k2':>6} {'I_int_μ':>8} "
          f"{'I_int_σ':>8} {'I_slope_μ':>10} {'F_k2':>5} {'len':>4}")
    with_139 = [r for r in summary_rows if r["with_139"]]
    with_139.sort(key=lambda r: -(r["I_int_mu"] or 0))
    for r in with_139[:20]:
        slope_s = f"{r['I_slope_mu']:+10.5f}" if r['I_slope_mu'] is not None else "       --"
        print(f"    {r['bin_id']:<50} {r['n']:>3} {r['I_med_k2']:>6.3f} "
              f"{r['I_int_mu']:>8.3f} {r['I_int_sd']:>8.4f} {slope_s} "
              f"{r['F_med_k2']:>5.1f} {r['len_med']:>4}")

    print(f"\n  per-bin snapshot (without_139, sorted by I_intercept_mu):")
    print(f"    {'bin_id':<50} {'n':>3} {'I_k2':>6} {'I_int_μ':>8} "
          f"{'I_int_σ':>8} {'I_slope_μ':>10} {'F_k2':>5} {'len':>4}")
    without = [r for r in summary_rows if not r["with_139"]]
    without.sort(key=lambda r: -(r["I_int_mu"] or 0))
    for r in without[:20]:
        slope_s = f"{r['I_slope_mu']:+10.5f}" if r['I_slope_mu'] is not None else "       --"
        i_int   = f"{r['I_int_mu']:>8.3f}"     if r['I_int_mu']   is not None else "      --"
        i_sd    = f"{r['I_int_sd']:>8.4f}"     if r['I_int_sd']   is not None else "      --"
        f_k2    = f"{r['F_med_k2']:>5.1f}"     if r['F_med_k2']   is not None else "   --"
        print(f"    {r['bin_id']:<50} {r['n']:>3} {r['I_med_k2']:>6.3f} "
              f"{i_int} {i_sd} {slope_s} {f_k2} {r['len_med']:>4}")


if __name__ == "__main__":
    main()
