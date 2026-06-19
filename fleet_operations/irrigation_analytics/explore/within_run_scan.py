#!/usr/bin/env python3
"""
Within-run regime-shift scan.

For each solo-valve bin's newest run in two snapshots (5/28 night-before,
5/29 last-night), find the strongest internal level change:

  body = run[1:]                       # drop step 0 (startup transient)
  for split in 2..len(body)-1:
      a = median(body[:split])
      b = median(body[split:])
      track max |b - a|
  best_split = (idx, a, b, b-a)

Sign convention:
   b > a  →  mid-run BREAK   (pipe rupture / popped head / valve change)
   b < a  →  mid-run CLOG    (head plug developing)

Flag rule (within-run):
   |Δ| > max(K_WITHIN * MAD_step_historic, gpm_floor_within)
   K_WITHIN = 3.0
   gpm_floor_within = 1.5

Cross-comparison: 5/28 vs 5/29 side-by-side so corrective effect and
new-event differences are obvious.

User framing 2026-05-29: last night IS the post-repair baseline; any
within-run anomaly in last-night's data is a candidate new event
(mid-run pipe break or fresh mid-run clog).
"""
import json
import statistics as st
from pathlib import Path

K_WITHIN         = 1.5
GPM_FLOOR_WITHIN = 0.5
STARTUP_SKIP     = 2     # drop step 0 + step 1 (startup pressure transient)
MIN_BODY_LEN     = 6     # need at least 6 samples post-startup for split scan
MIN_HALF         = 3     # each split half needs >= MIN_HALF samples

ROOT = Path(__file__).parent
SNAP_28 = ROOT / "snapshots" / "2026-05-28" / "time_history.json"
SNAP_29 = ROOT / "snapshots" / "2026-05-29" / "time_history.json"


def median(xs):
    return st.median(xs) if xs else None


def within_features(steps):
    """Drop startup window; compute strongest split-point regime shift in body."""
    if not steps or len(steps) < STARTUP_SKIP + MIN_BODY_LEN:
        return None
    body = steps[STARTUP_SKIP:]
    if len(body) < MIN_BODY_LEN:
        return None
    best_split = None
    best_abs = -1.0
    # Require both halves >= MIN_HALF samples so a single outlier can't dominate
    for i in range(MIN_HALF, len(body) - MIN_HALF + 1):
        a = median(body[:i])
        b = median(body[i:])
        gap = abs(b - a)
        if gap > best_abs:
            best_abs = gap
            best_split = (i, a, b, b - a)
    if best_split is None:
        return None
    idx, a, b, delta = best_split
    body_med = median(body)
    body_mad = median([abs(v - body_med) for v in body])
    excursion = max(body) - min(body)
    return {
        "n_body": len(body),
        "body_med": body_med,
        "body_mad": body_mad,
        "excursion": excursion,
        # split_idx is offset within body; report as absolute step in original run
        "split_idx": idx + STARTUP_SKIP,
        "split_early_med": a,
        "split_late_med": b,
        "split_delta": delta,
        "newest_steps": steps,
    }


def historic_step_mad(runs):
    """MAD of split-deltas across historic runs (excluding newest)."""
    if len(runs) < 4:
        return None
    deltas = []
    for r in runs[:-1]:
        steps = r.get("HUNTER_FLOW_METER", {}).get("data")
        f = within_features(steps)
        if f and f["body_mad"] is not None:
            deltas.append(f["split_delta"])
    if len(deltas) < 3:
        return None
    med = median(deltas)
    return median([abs(d - med) for d in deltas])


def classify(features, mad_step_historic):
    if features is None:
        return ""
    if features["split_delta"] is None:
        return ""
    if mad_step_historic and mad_step_historic > 0:
        gate = max(K_WITHIN * mad_step_historic, GPM_FLOOR_WITHIN)
    else:
        gate = GPM_FLOOR_WITHIN
    d = features["split_delta"]
    if abs(d) <= gate:
        return ""
    return "BREAK" if d > 0 else "CLOG"


def main():
    d28 = json.loads(SNAP_28.read_text())
    d29 = json.loads(SNAP_29.read_text())

    solo_keys = sorted(k for k in d29 if "/" not in k)

    rows = []
    for k in solo_keys:
        runs28 = d28.get(k, [])
        runs29 = d29[k]
        if not runs29:
            continue
        # Newest run in each snapshot
        newest28 = runs28[-1].get("HUNTER_FLOW_METER", {}).get("data") if runs28 else None
        newest29 = runs29[-1].get("HUNTER_FLOW_METER", {}).get("data")
        f28 = within_features(newest28) if newest28 else None
        f29 = within_features(newest29) if newest29 else None
        # Historic split-delta MAD from the 5/29 snapshot history
        mad_hist = historic_step_mad(runs29)
        cls28 = classify(f28, mad_hist)
        cls29 = classify(f29, mad_hist)
        same_run = (newest28 == newest29)
        rows.append({
            "bin": k,
            "f28": f28,
            "f29": f29,
            "cls28": cls28,
            "cls29": cls29,
            "mad_hist": mad_hist,
            "same_run": same_run,
        })

    # Sort by 5/29 |split_delta| descending so new events float to the top
    def sort_key(r):
        if r["f29"] is None:
            return 0
        return -abs(r["f29"]["split_delta"])

    rows.sort(key=sort_key)

    print(f"\n=== Within-run regime scan (drop step 0; K={K_WITHIN}, floor={GPM_FLOOR_WITHIN}) ===")
    print("    early/late from best split-point (drift inside the run, not start vs end)\n")
    hdr = (f"  {'bin':<18s} {'mad':>5s}  "
           f"{'5/28 run (drop s0)':<32s} {'idx':>3s} {'Δ':>5s} {'cls':<5s}  "
           f"{'5/29 run (drop s0)':<32s} {'idx':>3s} {'Δ':>5s} {'cls':<5s}")
    print(hdr)
    print("  " + "-" * (len(hdr) - 2))
    for r in rows:
        b = r["bin"][-9:]
        mh = f"{r['mad_hist']:.2f}" if r['mad_hist'] else "  —"
        def fmt(steps, f):
            if not f:
                short = "[" + ",".join(f"{int(v)}" for v in (steps or [])) + "]"
                if len(short) > 30:
                    short = short[:27] + "...]"
                return (short or "              —              ", "  —", "   —")
            body = steps[STARTUP_SKIP:]
            s = "[" + ",".join(f"{int(v)}" for v in body) + "]"
            if len(s) > 30:
                s = s[:27] + "...]"
            idx = f["split_idx"]
            d = f["split_delta"]
            return (s, f"{idx:>3d}", f"{d:+.1f}")
        steps28 = r["f28"]["newest_steps"] if r["f28"] else []
        steps29 = r["f29"]["newest_steps"] if r["f29"] else []
        s28, i28, d28v = fmt(steps28, r["f28"])
        s29, i29, d29v = fmt(steps29, r["f29"])
        mark = "*same" if r["same_run"] else ""
        print(f"  {b:<18s} {mh:>5s}  "
              f"{s28:<32s} {i28:>3s} {d28v:>5s} {r['cls28']:<5s}  "
              f"{s29:<32s} {i29:>3s} {d29v:>5s} {r['cls29']:<5s} {mark}")

    # Summary of 5/29 flags (new candidate events)
    flags_29 = [r for r in rows if r["cls29"] and not r["same_run"]]
    print(f"\n=== 5/29 within-run flags ({len(flags_29)}) — candidate new mid-run events ===")
    for r in flags_29:
        f = r["f29"]
        body = f["newest_steps"][1:]
        kind = r["cls29"]
        print(f"  {r['bin']:<22s} {kind:<6s} step_at={f['split_idx']:<2d}  "
              f"early_med={f['split_early_med']:.1f}  late_med={f['split_late_med']:.1f}  "
              f"Δ={f['split_delta']:+.1f}")
        print(f"    body: {body}")

    # 5/28-only flags that cleared (corrective effect)
    cleared = [r for r in rows
               if r["cls28"] and not r["cls29"] and not r["same_run"]]
    print(f"\n=== Cleared by last night's cycle ({len(cleared)}) ===")
    for r in cleared:
        f28 = r["f28"]
        f29 = r["f29"]
        print(f"  {r['bin']:<22s} 5/28: {r['cls28']:<5s} Δ={f28['split_delta']:+.1f}"
              f"   →  5/29: clean Δ={f29['split_delta']:+.1f}")


if __name__ == "__main__":
    main()
