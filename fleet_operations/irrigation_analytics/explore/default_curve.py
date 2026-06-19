#!/usr/bin/env python3
"""
Build per-step reference curves for long-duration valves.

Strategy
--------
For each solo-valve bin whose historic median run-length is >= LONG_MIN_STEPS:
  for each step index i:
    samples[i] = [run.HUNTER_FLOW.data[i] for run in runs if len(run) > i]
    if len(samples[i]) >= MIN_N:
       median[i], mad[i]   # robust per-step expected band

Output
------
- JSON file:  data/default_curves.json
    { valve_id: { "n_runs_used": K,
                  "step_count": N,
                  "median":  [...],
                  "mad":     [...],
                  "n_samples_per_step": [...] } }
- Console: summary table + ASCII curve for top long-duration valves
- Residuals: shows how the newest (5/29) run compares to its own curve

Notes
-----
- Step 0 is included but typically reads 0 across all runs (controller
  off-time before energization). The "settled" portion starts at step 1
  with the startup transient, settling by step 3-5 typically.
- Median + MAD is robust to occasional anomalous runs (e.g., a 4:13-style
  burst). No outlier exclusion needed; median handles it.
- Reference uses ALL historic runs in the buffer (typically 49). For a
  recency-weighted version (post-repair sensitive), add a tail-window
  parameter later.
"""
import json
import statistics as st
from pathlib import Path

LONG_MIN_STEPS = 15      # only build curves for valves with med length >= this
MIN_N          = 5       # need this many samples per step for valid stats
ROOT = Path(__file__).parent


def median(xs):
    return st.median(xs) if xs else None


def mad(xs, m=None):
    if not xs:
        return None
    if m is None:
        m = st.median(xs)
    return st.median([abs(v - m) for v in xs])


def build_curve(runs):
    """For one valve's runs, returns per-step median/MAD/N."""
    flows = []
    for r in runs:
        s = r.get("HUNTER_FLOW_METER", {}).get("data")
        if s:
            flows.append(s)
    if not flows:
        return None
    max_len = max(len(f) for f in flows)
    medians, mads, ns = [], [], []
    for i in range(max_len):
        samples = [f[i] for f in flows if i < len(f)]
        if len(samples) < MIN_N:
            medians.append(None); mads.append(None); ns.append(len(samples))
            continue
        m = median(samples)
        medians.append(m)
        mads.append(mad(samples, m))
        ns.append(len(samples))
    return {
        "n_runs_used": len(flows),
        "step_count": max_len,
        "median": medians,
        "mad": mads,
        "n_samples_per_step": ns,
    }


def ascii_curve(curve, run=None, width=60, max_gpm=None):
    """One-char-per-step ASCII plot of the curve, optionally overlaying a run."""
    meds = curve["median"]
    valid = [m for m in meds if m is not None]
    if not valid:
        return ["(no valid steps)"]
    hi = max_gpm or max(valid) * 1.3
    lo = 0
    def y(v):
        if v is None:
            return None
        # Map [lo, hi] -> [0, width-1]
        return int(round((v - lo) / (hi - lo) * (width - 1)))
    lines = []
    lines.append(f"  scale: 0 |{'-' * (width-2)}| {hi:.1f} gpm")
    for i, m in enumerate(meds):
        if m is None:
            lines.append(f"  {i:>3d}: {'·' * 0}  n<{MIN_N}")
            continue
        ym = y(m)
        # Build line with median marker and optional MAD band
        ml = curve["mad"][i]
        lo_b = max(0, y(m - ml) if ml else ym)
        hi_b = min(width-1, y(m + ml) if ml else ym)
        chars = [' '] * width
        for j in range(lo_b, hi_b + 1):
            chars[j] = '·'
        chars[ym] = '*'
        # Overlay actual run sample if provided
        if run and i < len(run):
            yr = y(run[i])
            if yr is not None and 0 <= yr < width:
                chars[yr] = 'X' if yr != ym else '@'
        n = curve["n_samples_per_step"][i]
        n_marker = "" if n >= 20 else f" n={n}"
        lines.append(f"  {i:>3d}: |{''.join(chars)}|  med={m:>5.1f} ±{ml:>4.1f}{n_marker}")
    return lines


def main():
    p = ROOT / "data" / "time_history.json"
    d = json.loads(p.read_text())

    # Filter to solo bins with sufficient run length
    candidates = []
    for k, runs in d.items():
        if "/" in k:
            continue
        lens = [len(r.get("HUNTER_FLOW_METER", {}).get("data", [])) for r in runs]
        lens = [L for L in lens if L > 0]
        if not lens:
            continue
        med_len = st.median(lens)
        if med_len >= LONG_MIN_STEPS:
            candidates.append((k, med_len, len(lens), runs))

    candidates.sort(key=lambda x: -x[1])

    print(f"\n=== Long-duration valves (hist med length >= {LONG_MIN_STEPS}) ===\n")
    print(f"  {'valve':<22s} {'med_len':>7s} {'n_runs':>6s}")
    print("  " + "-" * 40)
    for k, ml, nr, _ in candidates:
        print(f"  {k:<22s} {ml:>7.0f} {nr:>6d}")

    # Build curves
    curves = {}
    for k, _, _, runs in candidates:
        c = build_curve(runs)
        if c:
            curves[k] = c

    # Save JSON
    out = ROOT / "data" / "default_curves.json"
    out.write_text(json.dumps(curves, indent=2))
    print(f"\nWrote {len(curves)} curves to {out}")

    # Show ASCII for top 5 valves by n_runs (filter ones with usable curves)
    print("\n=== Per-step reference curves (top 5 by n_runs) ===")
    display = sorted(
        [(k, ml, nr, runs) for k, ml, nr, runs in candidates if nr >= MIN_N + 3],
        key=lambda x: -x[2],
    )[:5]
    for k, ml, nr, runs in display:
        newest = runs[-1].get("HUNTER_FLOW_METER", {}).get("data", [])
        newest_total = sum(newest)
        c = curves[k]
        ref_total = sum(m for m in c["median"][:len(newest)] if m is not None)
        print(f"\n--- {k} (hist med_len={ml:.0f}, n_runs={nr}) ---")
        print(f"  newest run: {len(newest)} steps, total={newest_total:.0f} gpm-step")
        print(f"  reference total over same length: {ref_total:.0f} gpm-step")
        # Residual: sum(|newest - median|) over overlapping steps
        residual = sum(abs(newest[i] - c["median"][i])
                       for i in range(min(len(newest), c["step_count"]))
                       if c["median"][i] is not None)
        print(f"  L1 residual vs curve: {residual:.0f} gpm-step  ('X' = newest, '*' = ref median)")
        for line in ascii_curve(c, run=newest, width=50):
            print(line)


if __name__ == "__main__":
    main()
