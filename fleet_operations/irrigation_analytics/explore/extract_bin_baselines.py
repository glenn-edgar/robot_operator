#!/usr/bin/env python3
"""
Phase 1 — Per-bin baseline extraction from TIME_HISTORY.

For each ACTIVE bin (all member valves in valve_test.json):
  - I_asym μ/σ (mean of last-3 samples per run, skip sample[0] timing race)
  - HUNTER_FLOW μ/σ for total and steady-state rate
  - Run-length distribution (min, p25, median, p75, max)
  - Bimodal detection → split into pump-on / pump-off baselines if found

Output: bin_baselines.json — keyed by bin_key.
"""
import json
import statistics
from pathlib import Path


SAMPLE0_SKIP = True       # known timing race (σ_s0=0.153 vs σ_s1=0.005)
ASYM_TAIL_N  = 3          # last N non-zero samples for asymptote
BIMODAL_GAP_FRAC = 0.5    # gap > 0.5 × median splits clusters
BIMODAL_MIN_CLUSTER = 5   # each cluster needs ≥ this many runs


def asymptote(samples: list[float]) -> float | None:
    n = len(samples)
    while n > 0 and samples[n - 1] <= 1e-6:
        n -= 1
    samples = samples[:n]
    start = 1 if SAMPLE0_SKIP else 0
    if n - start < ASYM_TAIL_N:
        return None
    return statistics.mean(samples[-ASYM_TAIL_N:])


def steady_rate(samples: list[float]) -> float | None:
    """Per-minute rate from middle of the run (not edges)."""
    n = len(samples)
    while n > 0 and samples[n - 1] <= 1e-6:
        n -= 1
    samples = samples[:n]
    if n < 4:
        return None
    # Drop first 1 (ramp-up) and last 1 (close), mean middle
    mid = samples[1:-1]
    return statistics.mean(mid) if mid else None


def detect_bimodal(values: list[float]) -> tuple[bool, float | None]:
    """Find biggest gap in sorted values; split if gap > frac × median.
    Returns (is_bimodal, split_value)."""
    if len(values) < 2 * BIMODAL_MIN_CLUSTER:
        return False, None
    s = sorted(values)
    med = statistics.median(s)
    gaps = [(s[i+1] - s[i], (s[i] + s[i+1]) / 2) for i in range(len(s) - 1)]
    if not gaps:
        return False, None
    max_gap, split = max(gaps, key=lambda x: x[0])
    if max_gap < BIMODAL_GAP_FRAC * med:
        return False, None
    low = [v for v in s if v < split]
    high = [v for v in s if v >= split]
    if len(low) < BIMODAL_MIN_CLUSTER or len(high) < BIMODAL_MIN_CLUSTER:
        return False, None
    return True, split


def stats_of(values: list[float]) -> dict:
    if not values:
        return {"n": 0}
    return {
        "n":     len(values),
        "mu":    round(statistics.mean(values), 4),
        "sd":    round(statistics.pstdev(values), 4),
        "min":   round(min(values), 4),
        "max":   round(max(values), 4),
    }


def baseline_for(asyms: list[float], flows_total: list[float],
                 flows_rate: list[float], lengths: list[int]) -> dict:
    cv = stats_of(asyms)["sd"] / stats_of(asyms)["mu"] if asyms and stats_of(asyms)["mu"] > 1e-6 else 0
    return {
        "i_asym":     stats_of(asyms),
        "flow_total": stats_of(flows_total),
        "flow_rate":  stats_of(flows_rate),
        "run_len_n":  len(lengths),
        "run_len_p":  {
            "min":    min(lengths) if lengths else None,
            "median": statistics.median(lengths) if lengths else None,
            "max":    max(lengths) if lengths else None,
        },
        "cv_i_asym":  round(cv, 4),
    }


def main():
    here = Path(__file__).parent
    th = json.loads((here / "data" / "time_history.json").read_text())
    vt = json.loads((here / "data" / "valve_test.json").read_text())
    active_valves = set(vt.keys())

    # Controller stores compound bins in BOTH valve orderings (e.g.
    # sat_1:39/sat_4:12 AND sat_4:12/sat_1:39 — same physical bin, both
    # 49-run buffers). Canonicalize at READ and MERGE the runs so the
    # baseline uses all observations of the physical bin.
    def canonical(k):
        return "/".join(sorted(k.split("/"))) if "/" in k else k

    th_canonical = {}
    merged_count = 0
    for k, runs in th.items():
        ck = canonical(k)
        if ck in th_canonical:
            th_canonical[ck] = th_canonical[ck] + runs
            merged_count += 1
        else:
            th_canonical[ck] = runs
    if merged_count:
        print(f"  merged {merged_count} duplicate non-canonical bins "
              f"({len(th)} → {len(th_canonical)})")
    th = th_canonical

    out = {}
    skipped_retired = []
    skipped_short = []
    for bin_key, runs in th.items():
        valves = bin_key.split("/")
        if not all(v in active_valves for v in valves):
            skipped_retired.append(bin_key)
            continue
        # extract per-run metrics
        records = []
        for run in runs:
            ic = run.get("IRRIGATION_CURRENT", {}).get("data", [])
            hf = run.get("HUNTER_FLOW_METER", {}).get("data", [])
            a = asymptote(ic)
            r = steady_rate(ic)
            if a is None:
                continue
            run_len = sum(1 for s in ic if s > 1e-6)
            records.append({
                "asym": a,
                "rate": r if r is not None else 0.0,
                "flow_total": sum(hf),
                "flow_rate": statistics.mean(hf[1:-1]) if len(hf) >= 4 else 0.0,
                "length": run_len,
            })
        if len(records) < 5:
            skipped_short.append((bin_key, len(records)))
            continue

        asyms = [r["asym"] for r in records]
        flows_t = [r["flow_total"] for r in records]
        flows_r = [r["flow_rate"]  for r in records]
        lengths = [r["length"]     for r in records]

        entry = {
            "bin_key":   bin_key,
            "n_valves":  len(valves),
            "n_runs":    len(records),
        }

        is_bi, split = detect_bimodal(asyms)
        if is_bi:
            # split records by asymptote vs split
            low_recs  = [r for r in records if r["asym"] <  split]
            high_recs = [r for r in records if r["asym"] >= split]
            entry["bimodal"] = True
            entry["split_at_asym"] = round(split, 3)
            entry["pump_off"] = baseline_for(
                [r["asym"] for r in low_recs],
                [r["flow_total"] for r in low_recs],
                [r["flow_rate"]  for r in low_recs],
                [r["length"]     for r in low_recs])
            entry["pump_on"] = baseline_for(
                [r["asym"] for r in high_recs],
                [r["flow_total"] for r in high_recs],
                [r["flow_rate"]  for r in high_recs],
                [r["length"]     for r in high_recs])
        else:
            entry["bimodal"] = False
            entry["baseline"] = baseline_for(asyms, flows_t, flows_r, lengths)

        out[bin_key] = entry

    # Canonicalize compound bin_keys (sort components) before writing.
    # time_history.json keys inherit the controller's natural valve order
    # from past_actions; the robot canonicalizes by sorting on lookup.
    # See generate_curves.py for the same pattern.
    def canonical(k):
        return "/".join(sorted(k.split("/"))) if "/" in k else k

    out_canonical = {canonical(k): v for k, v in out.items()}
    if len(out_canonical) != len(out):
        print(f"  collapsed {len(out) - len(out_canonical)} duplicate non-canonical bins")
    out = out_canonical

    out_path = here / "bin_baselines.json"
    out_path.write_text(json.dumps(out, indent=2))

    print(f"\n=== Phase 1 — bin baseline extraction ===")
    print(f"  Active bins baselined: {len(out)}")
    print(f"  Skipped (retired):     {len(skipped_retired)}")
    print(f"  Skipped (<5 runs):     {len(skipped_short)}")
    if skipped_short:
        for k, n in skipped_short[:5]:
            print(f"      {k}  (n={n})")

    bi = [e for e in out.values() if e["bimodal"]]
    print(f"\n  Bimodal bins (pump-on/pump-off split): {len(bi)}")
    for e in bi:
        print(f"    {e['bin_key']:<48} split@{e['split_at_asym']:5.2f}A  "
              f"off={e['pump_off']['i_asym']['mu']:.2f}±{e['pump_off']['i_asym']['sd']:.2f}A  "
              f"on={e['pump_on']['i_asym']['mu']:.2f}±{e['pump_on']['i_asym']['sd']:.2f}A")

    print(f"\n  → {out_path}")


if __name__ == "__main__":
    main()
