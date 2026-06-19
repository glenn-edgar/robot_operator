#!/usr/bin/env python3
"""
Scaffold peeker for IRRIGATION_TIME_HISTORY.

Reads data/time_history.json and prints:
  - per-bin: run count, sample-length, latest IRRIGATION_CURRENT asymptote,
    flow total, equipment current baseline
  - sorted: bins with most runs first
  - per-measurement: which slots are alive vs dead (always-zero)

This is the input to KB2-runs' per-run thermal analyzer. Today's job is
just to characterize what's in the data, not classify. Tomorrow we
layer in:
  - asymptote-R extraction (per solo-zone step)
  - step decomposition (per-valve I from aggregate stream)
  - spike count, slope, heat-margin
  - flow × current cross-check
"""
import json
import statistics
from pathlib import Path

MEASUREMENTS = ("IRRIGATION_CURRENT", "EQUIPMENT_CURRENT", "HUNTER_FLOW_METER",
                "CLEANING_FLOW_METER", "WELL_PRESSURE", "INPUT_PUMP_CURRENT",
                "OUTPUT_PUMP_CURRENT")
KNOWN_DEAD = {"WELL_PRESSURE", "INPUT_PUMP_CURRENT", "OUTPUT_PUMP_CURRENT"}


def load():
    p = Path(__file__).parent / "data" / "time_history.json"
    return json.loads(p.read_text())


def asymptote(samples: list[float]) -> float | None:
    """Mean of last 3 nonzero samples — proxy for steady-state."""
    nz = [s for s in samples if s > 1e-6]
    if len(nz) < 3: return None
    return statistics.mean(nz[-3:])


def initial(samples: list[float]) -> float | None:
    """Sample index 1 (skip the timing-race sample 0)."""
    if len(samples) < 2: return None
    return samples[1] if samples[1] > 1e-6 else None


def main():
    th = load()
    print(f"\n=== IRRIGATION_TIME_HISTORY — bins={len(th)} ===\n")

    # bin summary
    bin_summary = []
    for bin_key, runs in th.items():
        if not runs: continue
        # Use the most-recent run for "today's values"
        latest = runs[-1]
        ic = latest.get("IRRIGATION_CURRENT", {}).get("data", [])
        eq = latest.get("EQUIPMENT_CURRENT", {}).get("data", [])
        hf = latest.get("HUNTER_FLOW_METER", {}).get("data", [])
        bin_summary.append({
            "bin": bin_key,
            "n_valves": bin_key.count("/") + 1,
            "n_runs": len(runs),
            "n_samples_latest": len(ic),
            "ic_initial": initial(ic),
            "ic_asymptote": asymptote(ic),
            "eq_mean": statistics.mean([x for x in eq if x > 0]) if any(x > 0 for x in eq) else None,
            "flow_total": sum(hf) if hf else 0.0,
        })

    # sort: most runs first
    bin_summary.sort(key=lambda r: (-r["n_runs"], r["bin"]))

    print(f"  {'bin':<48} {'#vlv':>4} {'#run':>4} {'#smp':>4}  {'I_init':>6} {'I_asym':>6} {'EQ':>5} {'flow':>6}")
    print("  " + "─" * 96)
    for r in bin_summary[:30]:  # top 30 by run count
        f = lambda x: f"{x:6.3f}" if x is not None else "  ---"
        print(f"  {r['bin']:<48} {r['n_valves']:>4} {r['n_runs']:>4} {r['n_samples_latest']:>4}"
              f"  {f(r['ic_initial'])} {f(r['ic_asymptote'])} {f(r['eq_mean']) if r['eq_mean'] else '  ---'} {r['flow_total']:>6.1f}")

    if len(bin_summary) > 30:
        print(f"  ... ({len(bin_summary)-30} more bins)")

    # per-measurement aliveness check
    print(f"\n=== Per-measurement aliveness (across all bins, latest run) ===\n")
    for m in MEASUREMENTS:
        nz_count = 0; zero_count = 0; total_samples = 0
        for runs in th.values():
            if not runs: continue
            data = runs[-1].get(m, {}).get("data", [])
            for s in data:
                total_samples += 1
                if s > 1e-6: nz_count += 1
                else: zero_count += 1
        alive = "ALIVE" if nz_count > 0 else "DEAD "
        known = " (known-dead)" if m in KNOWN_DEAD else ""
        print(f"  {m:<22} {alive}  nz={nz_count}/{total_samples}{known}")

    # solo-zone bins (where decomposition is unnecessary — direct I per valve)
    solo = [r for r in bin_summary if r["n_valves"] == 1 and r["ic_asymptote"] is not None]
    print(f"\n=== Solo-zone bins (direct per-valve I) — {len(solo)} of {len(bin_summary)} ===")
    print(f"  Useful for day-1 asymptote-R baseline without step-decomp.\n")

    # cohort of solo asymptotes — what does the population look like?
    asyms = [r["ic_asymptote"] for r in solo]
    if asyms:
        print(f"  solo asymptote I:  min={min(asyms):.3f}  μ={statistics.mean(asyms):.3f}  max={max(asyms):.3f}  σ={statistics.pstdev(asyms):.3f}")


if __name__ == "__main__":
    main()
