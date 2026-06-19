#!/usr/bin/env python3
"""
Mine the stitched R-history for replacement events.

Signature of a replacement (solenoid swap):
  - R_after lands in the "new-install" band [38, 48]Ω
  - R_after − min(R[window before]) ≥ ΔR_threshold
  - The drop-before-jump pattern: prior readings were depressed (below baseline)

Trigger rule (v2, baseline-relative — tuned 2026-05-27 after v1 over-fired
347×):
  Per-valve baseline = median of its full R history. A replacement is a step
  UP from that baseline into the new-install band, with the pre-window
  genuinely depressed (sustained, not single-point dip).

  For each reading at position k (k ≥ LOOKBACK):
    pre_window = R[k-LOOKBACK..k-1]
    pre_median = median(pre_window)
    if R[k] − pre_median ≥ DELTA_R_MIN          # real jump
       and R[k] − valve_baseline ≥ UPLIFT_MIN   # meaningful vs own history
       and NEW_BAND_LOW ≤ R[k] ≤ NEW_BAND_HIGH  # absolute new-install
       and pre_median < (R[k] − DELTA_R_MIN)    # pre was sustained-low
       and ord != ord_min_in_series             # not data-edge
       → flag as candidate replacement at ord=k

Output: replacements_detected.json
  [{"valve": "sat_X:Y", "ord_event": int, "r_before": float, "r_after": float,
    "pre_window": [...], "source": "cold|hot|mixed"}, ...]

Sat_2:4 will only be flagged AFTER today's fetch (replacement is in field, not
yet in the cold-R series of yesterday's snapshot).
"""
import json
import statistics
from pathlib import Path

DELTA_R_MIN   = 6.0    # jump (R_after − pre_median) ≥ this
UPLIFT_MIN    = 4.0    # R_after must be ≥ valve-baseline + this
NEW_BAND_LOW  = 40.0   # post in new-install band (raised from 38 — noise crosses 38)
NEW_BAND_HIGH = 48.0
LOOKBACK = 5           # pre-window size
PRE_LOW_FRAC  = 0.6    # ≥60% of pre-window must be < (R_after − DELTA_R_MIN);
                       # daily R noise is ±5Ω so single high readings in pre
                       # window are common and shouldn't disqualify a real jump
POST_CONFIRM  = True   # require R[k+1] ≥ NEW_BAND_LOW (if available)


def detect(series: list[dict]) -> list[dict]:
    """series: stitched list of {"ord", "r", "source"}, oldest first."""
    if len(series) < LOOKBACK + 1:
        return []
    valve_baseline = statistics.median(e["r"] for e in series)
    events = []
    for k in range(LOOKBACK, len(series)):
        window = series[k - LOOKBACK:k]
        r_after = series[k]["r"]
        pre_median = statistics.median(w["r"] for w in window)
        # pre-window mostly-low gate
        thresh = r_after - DELTA_R_MIN
        n_low = sum(1 for w in window if w["r"] < thresh)
        if n_low / LOOKBACK < PRE_LOW_FRAC:
            continue
        # post-confirmation gate (if next reading exists)
        if POST_CONFIRM and k + 1 < len(series):
            if series[k + 1]["r"] < NEW_BAND_LOW:
                continue
        if (r_after - pre_median >= DELTA_R_MIN
                and r_after - valve_baseline >= UPLIFT_MIN
                and NEW_BAND_LOW <= r_after <= NEW_BAND_HIGH
                and pre_median < r_after - DELTA_R_MIN):
            events.append({
                "ord_event": series[k]["ord"],
                "r_before_median": round(pre_median, 2),
                "r_after": round(r_after, 2),
                "delta_r": round(r_after - pre_median, 2),
                "valve_baseline": round(valve_baseline, 2),
                "uplift": round(r_after - valve_baseline, 2),
                "pre_window": [round(w["r"], 2) for w in window],
                "post_source": series[k]["source"],
            })
    return events


def main():
    here = Path(__file__).parent
    h = json.loads((here / "stitched_r_history.json").read_text())

    all_events = []
    for valve, info in h.items():
        events = detect(info["stitched"])
        for ev in events:
            ev["valve"] = valve
            all_events.append(ev)

    # Multi-valve same-day filter: if ≥3 valves trigger at the same ordinal,
    # treat as a system event (wire terminal fix, supply change, sensor
    # recalibration). Also expand to ±1 day to catch the carryover echo where
    # a system event on day K leaves valves still elevated on day K+1.
    from collections import Counter
    ord_counts = Counter(ev["ord_event"] for ev in all_events)
    core_ords = {o for o, c in ord_counts.items() if c >= 3}
    system_ords = core_ords | {o+1 for o in core_ords} | {o-1 for o in core_ords}
    filtered = [ev for ev in all_events if ev["ord_event"] not in system_ords]
    system_events = [ev for ev in all_events if ev["ord_event"] in system_ords]

    out = here / "replacements_detected.json"
    out.write_text(json.dumps(filtered, indent=2))
    if system_events:
        (here / "system_events_detected.json").write_text(
            json.dumps(system_events, indent=2))

    print(f"\n=== replacement-event detection ===")
    print(f"  Rule: ΔR≥{DELTA_R_MIN}Ω vs pre-median, uplift≥{UPLIFT_MIN}Ω vs "
          f"valve-baseline, post in [{NEW_BAND_LOW},{NEW_BAND_HIGH}]Ω, "
          f"lookback={LOOKBACK}")
    print(f"  Replacement events: {len(filtered)}")
    print(f"  System events filtered: {len(system_events)} "
          f"({len(system_ords)} ordinal{'s' if len(system_ords)!=1 else ''})")
    if system_ords:
        print(f"    system ordinals: {sorted(system_ords)}")
    if not filtered:
        print("  (no replacements flagged in this window)")
        return

    # Group by valve for readability
    by_valve = {}
    for ev in filtered:
        by_valve.setdefault(ev["valve"], []).append(ev)
    print(f"  Distinct valves: {len(by_valve)}\n")

    for valve, evs in sorted(by_valve.items()):
        print(f"  {valve}  (baseline={evs[0]['valve_baseline']:.1f}Ω):")
        for ev in evs:
            pre = ", ".join(f"{r:.1f}" for r in ev["pre_window"])
            print(f"    ord={ev['ord_event']:>4}  "
                  f"R: {ev['r_before_median']:.1f} → {ev['r_after']:.1f} "
                  f"(Δ{ev['delta_r']:+.1f}, uplift{ev['uplift']:+.1f})  "
                  f"pre=[{pre}]  src={ev['post_source']}")
    print(f"\n  → {out}")


if __name__ == "__main__":
    main()
