#!/usr/bin/env python3
"""
Phase 3 — KB1 threshold table from bin baselines.

Per active bin, derives:
  i_high_trip   = max(5.0,  μ + 5σ)   — mode-4 hard short or overshoot
  i_low_open    = max(0.10, μ - 4σ)   — open coil / valve not energized
  flow_low_mech = max(0.0,  μ_flow - 4σ_flow)  — mechanical/head fault
  spike_thresh  = 1.5 × μ_asym        — mode-3 detector (post-sample[0])

Plus the universal MODE_4 rules from failure_signatures.md:
  any sample[i>0] > 5.0 A      → MODE_4_HARD (instant trip)
  I_asym > 2.0 × baseline_mu   → MODE_4_DEAD (1-confirm trip)

Output: kb1_thresholds.json
"""
import json
import statistics
from pathlib import Path


def derive(entry: dict) -> dict:
    if entry["bimodal"]:
        # Two modes — pump-on / pump-off thresholds. Not present in current
        # active schedule; supported for future readiness.
        return {
            "bimodal": True,
            "pump_off": _from_baseline(entry["pump_off"]),
            "pump_on":  _from_baseline(entry["pump_on"]),
            "split_at_asym": entry["split_at_asym"],
        }
    return {"bimodal": False, **_from_baseline(entry["baseline"])}


def _from_baseline(b: dict) -> dict:
    mu_i = b["i_asym"]["mu"]
    sd_i = b["i_asym"]["sd"]
    mu_f = b["flow_total"]["mu"]
    sd_f = b["flow_total"]["sd"]
    return {
        "i_high_trip":     round(max(5.0, mu_i + 5 * sd_i), 3),
        "i_low_open":      round(max(0.10, mu_i - 4 * sd_i), 3),
        "flow_low_mech":   round(max(0.0, mu_f - 4 * sd_f), 3),
        "spike_thresh":    round(1.5 * mu_i, 3),
        "mu_i_asym":       mu_i,
        "sd_i_asym":       sd_i,
        "mu_flow_total":   mu_f,
        "sd_flow_total":   sd_f,
    }


def main():
    here = Path(__file__).parent
    baselines = json.loads((here / "bin_baselines.json").read_text())

    universal = {
        "any_sample_gt_amps":      5.0,    # MODE_4_HARD instant trip
        "asym_over_baseline_ratio": 2.0,   # MODE_4_DEAD (1-confirm)
        "sample0_skip":            True,
    }

    # Canonicalize compound bin_keys before writing. Defensive guard —
    # bin_baselines.json should already be canonical (extract_bin_baselines.py
    # canonicalizes), but apply here too so this file is correct even if a
    # hand-edited / stale baselines file slips in.
    def canonical(k):
        return "/".join(sorted(k.split("/"))) if "/" in k else k

    out = {"universal": universal, "per_bin": {}}
    for bin_key, entry in baselines.items():
        out["per_bin"][canonical(bin_key)] = derive(entry)

    out_path = here / "kb1_thresholds.json"
    out_path.write_text(json.dumps(out, indent=2))

    # Distribution report
    print(f"\n=== Phase 3 — KB1 thresholds ===")
    print(f"  Universal trip rules:")
    print(f"    any_sample > 5.0 A          → MODE_4_HARD (instant SKIP_STATION)")
    print(f"    I_asym > 2.0 × baseline_μ   → MODE_4_DEAD (1-confirm SKIP_STATION)")
    print(f"    sample[0] skipped (timing race)")

    print(f"\n  Per-bin thresholds derived for {len(out['per_bin'])} bins")

    # Sanity check: for any bin, derived i_high_trip should not be < I_asym_max_observed
    # That would mean a real run would trip the rule.
    print(f"\n  Sanity: per-bin i_high_trip vs observed max-asym:")
    # baselines may still be keyed pre-canonical (if extract step hasn't been
    # re-run); build a canonical-keyed view for the lookup.
    baselines_canon = {canonical(k): v for k, v in baselines.items()}
    flagged = []
    for bin_key, t in out["per_bin"].items():
        if t["bimodal"]: continue
        b = baselines_canon[bin_key]["baseline"]
        if b["i_asym"]["max"] >= t["i_high_trip"]:
            flagged.append((bin_key, b["i_asym"]["max"], t["i_high_trip"]))
    print(f"    bins where observed max ≥ i_high_trip: {len(flagged)}")
    for k, mx, th in flagged[:10]:
        print(f"      {k}  max={mx:.2f}A  trip={th:.2f}A  ← FALSE POSITIVE on real run")

    # Spread of i_high_trip and i_low_open
    highs = [t["i_high_trip"] for t in out["per_bin"].values() if not t["bimodal"]]
    lows  = [t["i_low_open"]  for t in out["per_bin"].values() if not t["bimodal"]]
    spike = [t["spike_thresh"] for t in out["per_bin"].values() if not t["bimodal"]]
    print(f"\n  i_high_trip:   min={min(highs):.2f}  median={statistics.median(highs):.2f}  max={max(highs):.2f}")
    print(f"  i_low_open:    min={min(lows):.2f}  median={statistics.median(lows):.2f}  max={max(lows):.2f}")
    print(f"  spike_thresh:  min={min(spike):.2f}  median={statistics.median(spike):.2f}  max={max(spike):.2f}")

    print(f"\n  → {out_path}")


if __name__ == "__main__":
    main()
