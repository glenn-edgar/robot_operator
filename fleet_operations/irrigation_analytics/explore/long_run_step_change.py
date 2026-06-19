#!/usr/bin/env python3
"""
Step-change detector for body_med across runs in a bin.

Distinguishes a TODAY-ANOMALY (today's run differs from recent 5 stable runs)
from a STEP-CHANGE (today is in line with a regime change that started N runs
ago). The KB4 adaptive baseline will use this distinction.

Algorithm per bin per stream:
  oldn = runs[-12:-5]   (older 7 runs)
  newn = runs[-5:]      (recent 5 runs, EXCLUDING today)
  today_body_med = body_med of runs[-1]

  old_med = median(body_med for oldn)
  new_med = median(body_med for newn)
  if |new_med - old_med| > STEP_GATE → STEP_CHANGE at ~5 runs ago
  elif |today - new_med| > TODAY_GATE → TODAY_ANOMALY (vs recent stable)
  else OK

Reports any STEP_CHANGE and any TODAY_ANOMALY found.
"""
import json
import statistics as st
import sys
from pathlib import Path

STARTUP_SKIP   = 3
TAIL_SKIP      = 2
MIN_BODY       = 14
OLD_WIN        = (-12, -5)      # runs[OLD_WIN[0]:OLD_WIN[1]]
NEW_WIN_SIZE   = 5              # runs[-NEW_WIN_SIZE - 1: -1]
STEP_GATE_FLOW = 2.5            # GPM — body_med change between epochs
STEP_GATE_CUR  = 0.05           # A
TODAY_GATE_FLOW_FRAC = 0.20     # |today - new_med| > 20% of new_med
TODAY_GATE_FLOW_MIN  = 1.5      # ...or this absolute GPM, whichever larger
TODAY_GATE_CUR_FRAC  = 0.05     # 5%
TODAY_GATE_CUR_MIN   = 0.05     # A

ROOT = Path(__file__).parent
DEFAULT_SNAP = ROOT / "snapshots" / "2026-05-30" / "time_history.json"


def median(xs):
    return st.median(xs) if xs else None


def body_med(samples):
    if not samples or len(samples) < STARTUP_SKIP + TAIL_SKIP + MIN_BODY:
        return None
    body = samples[STARTUP_SKIP: len(samples) - TAIL_SKIP]
    return median(body) if body else None


def analyze(runs, stream_key, step_gate, today_gate_frac, today_gate_min):
    """Returns dict with old_med, new_med, today, classification."""
    bms = []
    for r in runs:
        arr = (r.get(stream_key) or {}).get("data") or []
        bm = body_med(arr)
        bms.append(bm)
    if len(bms) < abs(OLD_WIN[0]) + 1:
        return {"status": "insufficient_history", "n_total": len(bms)}
    today = bms[-1]
    if today is None:
        return {"status": "today_short", "n_total": len(bms)}
    new_runs = bms[-NEW_WIN_SIZE - 1: -1]   # exclude today
    old_runs = bms[OLD_WIN[0]: OLD_WIN[1]]
    new_med = median([x for x in new_runs if x is not None])
    old_med = median([x for x in old_runs if x is not None])
    if new_med is None or old_med is None:
        return {"status": "epoch_short", "n_total": len(bms)}
    epoch_delta = new_med - old_med
    today_delta = today - new_med
    today_gate = max(today_gate_frac * new_med, today_gate_min)
    step_change = abs(epoch_delta) > step_gate
    today_anom  = abs(today_delta) > today_gate
    if step_change and today_anom:
        # Today is also outside the new epoch — actual new event
        status = "STEP_CHANGE_AND_TODAY"
    elif step_change:
        status = "STEP_CHANGE"
    elif today_anom:
        status = "TODAY_ANOMALY"
    else:
        status = "OK"
    return {
        "status":      status,
        "n_total":     len(bms),
        "old_med":     old_med,
        "new_med":     new_med,
        "today":       today,
        "epoch_delta": epoch_delta,
        "today_delta": today_delta,
        "today_gate":  today_gate,
        "step_dir":    "up" if epoch_delta > 0 else "down",
        "today_dir":   "up" if today_delta > 0 else "down",
        "recent_bms":  bms[-10:],
    }


def main():
    snap = Path(sys.argv[1]) if len(sys.argv) > 1 else DEFAULT_SNAP
    print(f"snapshot: {snap}\n")
    d = json.loads(snap.read_text())

    step_changes = []
    today_anoms  = []
    for bin_key, runs in sorted(d.items()):
        if len(runs) < abs(OLD_WIN[0]) + 1: continue
        flow_r = analyze(runs, "HUNTER_FLOW_METER",
                         STEP_GATE_FLOW, TODAY_GATE_FLOW_FRAC, TODAY_GATE_FLOW_MIN)
        cur_r  = analyze(runs, "IRRIGATION_CURRENT",
                         STEP_GATE_CUR,  TODAY_GATE_CUR_FRAC,  TODAY_GATE_CUR_MIN)
        for stream, r in [("FLOW", flow_r), ("CUR", cur_r)]:
            if r["status"] in ("STEP_CHANGE",):
                step_changes.append((bin_key, stream, r))
            elif r["status"] in ("TODAY_ANOMALY", "STEP_CHANGE_AND_TODAY"):
                today_anoms.append((bin_key, stream, r))

    print(f"=== STEP_CHANGE bins ({len(step_changes)}) — epoch shifted, today in line with new epoch ===")
    print(f"    (these are false positives for KB4 if not adaptive — already in the new normal)\n")
    for bin_key, stream, r in step_changes:
        units = "GPM" if stream == "FLOW" else "A"
        fmt = ".1f" if stream == "FLOW" else ".3f"
        print(f"  {bin_key:<42s} {stream:<5s}  "
              f"old={r['old_med']:{fmt}} {units} → new={r['new_med']:{fmt}} {units}  "
              f"(epochΔ={r['epoch_delta']:+{fmt}})  today={r['today']:{fmt}}")
        print(f"    recent body_meds: {[round(x, 2) if x else None for x in r['recent_bms']]}")

    print(f"\n=== TODAY_ANOMALY bins ({len(today_anoms)}) — today differs from recent 5 stable runs ===")
    print(f"    (these are the real candidate new events for triage)\n")
    for bin_key, stream, r in today_anoms:
        units = "GPM" if stream == "FLOW" else "A"
        fmt = ".1f" if stream == "FLOW" else ".3f"
        marker = " [+ EPOCH SHIFT]" if r["status"] == "STEP_CHANGE_AND_TODAY" else ""
        print(f"  {bin_key:<42s} {stream:<5s}  "
              f"today={r['today']:{fmt}} vs recent_med={r['new_med']:{fmt}} "
              f"(Δ={r['today_delta']:+{fmt}}, gate={r['today_gate']:{fmt}}){marker}")
        print(f"    recent body_meds: {[round(x, 2) if x else None for x in r['recent_bms']]}")


if __name__ == "__main__":
    main()
