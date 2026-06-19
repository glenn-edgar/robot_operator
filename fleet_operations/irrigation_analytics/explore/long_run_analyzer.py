#!/usr/bin/env python3
"""
Long-run within-run dual-stream analyzer (KB4 within-run scan foundation).

For every run with body length >= MIN_BODY samples (post-startup-skip), do a
split-point scan on BOTH HUNTER_FLOW_METER and IRRIGATION_CURRENT. Cross
correlate the sign and magnitude of the two streams to label the failure mode.

Per-stream scan:
  body = samples[STARTUP_SKIP:]
  for i in MIN_HALF..(len(body)-MIN_HALF):
      a = median(body[:i])
      b = median(body[i:])
  pick the split with max |b - a|

Two-stream label table (flow / current sign):
  flow Δ      current Δ      label                 physical hypothesis
  +           ~0             PIPE_BREAK            burst downstream of coil
  +           -              PIPE_BREAK_DROOP      burst + coil voltage sag
  -           ~0             CLOG                  emitter / head blockage
  -           +              VALVE_CLOSING         coil heating + flow loss = closing valve
  ~0          +              CURRENT_DRIFT         coil aging only, hydraulic OK
  ~0          -              CURRENT_RECOVER       coil cooled / contact improved
  ~0          ~0             STEADY                noise-floor only

Gates:
  flow:    |Δ_flow|    > max(K_FLOW    * MAD_step_hist_flow,    GPM_FLOOR)
  current: |Δ_current| > max(K_CURRENT * MAD_step_hist_current, A_FLOOR)
  Per-bin per-stream historic MAD computed from older runs in this bin.

For each bin's HISTORIC MAD we drop the newest run (avoid self-trigger).

Outputs:
  1. Per-bin summary: latest-run features, gate threshold, label
  2. Flagged-runs triage table: only runs with at least one stream over gate
  3. Top-N drift list: cross-bin ranking of |Δ| for both streams independently
"""
import json
import statistics as st
import sys
from pathlib import Path

STARTUP_SKIP    = 3          # drop first 3 min (rise + settle transient)
TAIL_SKIP       = 2          # drop last 2 min (bleed-down at valve close)
MIN_BODY        = 14         # need >=14 body samples (19-min run total)
MIN_HALF_FRAC   = 0.25       # each split half must be >=25% of body length
MIN_HALF_HARD   = 5          # hard min 5 samples per half regardless of body length
K_FLOW          = 3.0
K_CURRENT       = 3.0
GPM_FLOOR       = 1.5        # flow split-Δ gate floor (gal/min)
A_FLOOR         = 0.20       # current split-Δ gate floor (amps)
NEAR_ZERO_FLOW  = 0.6        # |Δ_flow| <= this is "~0"
NEAR_ZERO_CUR   = 0.10       # |Δ_current| <= this is "~0"

ROOT = Path(__file__).parent
DEFAULT_SNAP = ROOT / "snapshots" / "2026-05-30" / "time_history.json"


def median(xs):
    return st.median(xs) if xs else None


def split_features(samples):
    """Run split-point scan on body. Returns dict or None."""
    if not samples or len(samples) < STARTUP_SKIP + TAIL_SKIP + MIN_BODY:
        return None
    body = samples[STARTUP_SKIP:len(samples) - TAIL_SKIP]
    if len(body) < MIN_BODY:
        return None
    min_half = max(MIN_HALF_HARD, int(len(body) * MIN_HALF_FRAC))
    if len(body) < 2 * min_half:
        return None
    best_abs = -1.0
    best = None
    for i in range(min_half, len(body) - min_half + 1):
        a = median(body[:i])
        b = median(body[i:])
        gap = abs(b - a)
        if gap > best_abs:
            best_abs = gap
            best = (i + STARTUP_SKIP, a, b, b - a)
    if best is None:
        return None
    split_at, early, late, delta = best
    return {
        "n_body":   len(body),
        "split_at": split_at,
        "early":    early,
        "late":     late,
        "delta":    delta,
        "body_med": median(body),
        "body_mad": median([abs(v - median(body)) for v in body]),
        "min_half": min_half,
    }


def historic_mad(runs, stream_key, exclude_last=True):
    """MAD of split-deltas across this bin's historic runs (drop newest)."""
    deltas = []
    pool = runs[:-1] if (exclude_last and len(runs) > 1) else runs
    for r in pool:
        arr = (r.get(stream_key) or {}).get("data") or []
        f = split_features(arr)
        if f is None: continue
        deltas.append(f["delta"])
    if len(deltas) < 3:
        return None
    m = median(deltas)
    return median([abs(d - m) for d in deltas])


def classify(f_flow, f_cur, mad_flow, mad_cur):
    if f_flow is None or f_cur is None:
        return None
    flow_gate = max(K_FLOW * (mad_flow or 0), GPM_FLOOR)
    cur_gate  = max(K_CURRENT * (mad_cur  or 0), A_FLOOR)
    df = f_flow["delta"]
    dc = f_cur["delta"]
    flow_sig = ("+" if df >  flow_gate else
                "-" if df < -flow_gate else "0")
    cur_sig  = ("+" if dc >  cur_gate else
                "-" if dc < -cur_gate else "0")
    sigs = flow_sig + cur_sig
    label_map = {
        "+0": "PIPE_BREAK",
        "+-": "PIPE_BREAK_DROOP",
        "-0": "CLOG",
        "-+": "VALVE_CLOSING",
        "0+": "CURRENT_DRIFT",
        "0-": "CURRENT_RECOVER",
        "00": "STEADY",
        "++": "BREAK_CURRENT_RISE",   # rare; hose detachment + coil arc
        "--": "CLOG_AND_DROOP",       # rare; combined failure
    }
    return {
        "label":      label_map.get(sigs, "?"),
        "sigs":       sigs,
        "flow_gate":  flow_gate,
        "cur_gate":   cur_gate,
        "flow_delta": df,
        "cur_delta":  dc,
        "flagged":    sigs != "00",
    }


def main():
    snap = Path(sys.argv[1]) if len(sys.argv) > 1 else DEFAULT_SNAP
    print(f"snapshot: {snap}\n")
    d = json.loads(snap.read_text())

    per_bin = []
    for bin_key, runs in sorted(d.items()):
        if not runs:
            continue
        newest = runs[-1]
        flow_arr = (newest.get("HUNTER_FLOW_METER") or {}).get("data") or []
        cur_arr  = (newest.get("IRRIGATION_CURRENT") or {}).get("data") or []
        if len(flow_arr) < STARTUP_SKIP + MIN_BODY:
            continue
        f_flow = split_features(flow_arr)
        f_cur  = split_features(cur_arr)
        mad_flow = historic_mad(runs, "HUNTER_FLOW_METER")
        mad_cur  = historic_mad(runs, "IRRIGATION_CURRENT")
        cls = classify(f_flow, f_cur, mad_flow, mad_cur)
        per_bin.append({
            "bin":      bin_key,
            "n_runs":   len(runs),
            "n_body":   f_flow["n_body"],
            "f_flow":   f_flow,
            "f_cur":    f_cur,
            "mad_flow": mad_flow,
            "mad_cur":  mad_cur,
            "cls":      cls,
        })

    # ── 1) Per-bin newest-run table ──
    print(f"=== Newest-run within-run scan ({len(per_bin)} bins with body>={MIN_BODY}) ===")
    print(f"    flow-split gate = max(K={K_FLOW}*MAD, {GPM_FLOOR} GPM)   "
          f"cur-split gate = max(K={K_CURRENT}*MAD, {A_FLOOR} A)")
    hdr = (f"  {'bin':<42s} {'n_b':>3s} "
           f"{'flow med':>8s} {'fΔ':>6s} {'fgate':>6s} "
           f"{'cur med':>7s} {'cΔ':>6s} {'cgate':>6s}  {'label':<18s}")
    print(hdr); print("  " + "-" * (len(hdr) - 2))
    # Sort: flagged first (by |fΔ|+|cΔ|/A_FLOOR), then by bin
    def sk(r):
        if r["cls"] is None or not r["cls"]["flagged"]:
            return (1, r["bin"])
        ff = abs(r["cls"]["flow_delta"])
        cc = abs(r["cls"]["cur_delta"])
        return (0, -(ff/max(GPM_FLOOR,0.1) + cc/max(A_FLOOR,0.01)), r["bin"])
    per_bin.sort(key=sk)
    for r in per_bin:
        c = r["cls"]
        if c is None: continue
        b = r["bin"][:40]
        print(f"  {b:<42s} {r['n_body']:>3d} "
              f"{r['f_flow']['body_med']:>8.2f} {c['flow_delta']:>+6.2f} {c['flow_gate']:>6.2f} "
              f"{r['f_cur']['body_med']:>7.2f} {c['cur_delta']:>+6.2f} {c['cur_gate']:>6.2f}  "
              f"{c['label']:<18s}")

    # ── 2) Flagged-runs triage with full samples ──
    flagged = [r for r in per_bin if r["cls"] and r["cls"]["flagged"]]
    print(f"\n=== Flagged runs ({len(flagged)}) — within-run anomalies in newest run ===")
    for r in flagged:
        c, ff, fc = r["cls"], r["f_flow"], r["f_cur"]
        newest_runs = d[r["bin"]][-1]
        flow_arr = (newest_runs.get("HUNTER_FLOW_METER") or {}).get("data") or []
        cur_arr  = (newest_runs.get("IRRIGATION_CURRENT") or {}).get("data") or []
        print(f"\n  [{c['label']}] {r['bin']}   (n_body={r['n_body']}, hist runs={r['n_runs']-1})")
        print(f"    flow:  split@{ff['split_at']:>2d}  early={ff['early']:.2f} → late={ff['late']:.2f}  "
              f"Δ={c['flow_delta']:+.2f}  gate={c['flow_gate']:.2f}")
        print(f"    cur:   split@{fc['split_at']:>2d}  early={fc['early']:.3f} → late={fc['late']:.3f}  "
              f"Δ={c['cur_delta']:+.3f}  gate={c['cur_gate']:.3f}")
        # Trim large arrays for printing
        flow_str = "[" + ",".join(f"{v:.1f}" for v in flow_arr) + "]"
        cur_str  = "[" + ",".join(f"{v:.2f}" for v in cur_arr)  + "]"
        if len(flow_str) > 160: flow_str = flow_str[:157] + "...]"
        if len(cur_str)  > 160: cur_str  = cur_str[:157]  + "...]"
        print(f"    flow_data: {flow_str}")
        print(f"    cur_data:  {cur_str}")

    # ── 3) Top-N cross-bin drift ──
    print(f"\n=== Top 10 by |flow Δ| (any direction, gate-agnostic) ===")
    per_bin.sort(key=lambda r: -abs(r["f_flow"]["delta"]))
    for r in per_bin[:10]:
        c = r["cls"]
        print(f"  {r['bin']:<42s}  flow Δ={c['flow_delta']:+.2f}  "
              f"cur Δ={c['cur_delta']:+.3f}  → {c['label']}")

    print(f"\n=== Top 10 by |current Δ| (any direction, gate-agnostic) ===")
    per_bin.sort(key=lambda r: -abs(r["f_cur"]["delta"]))
    for r in per_bin[:10]:
        c = r["cls"]
        print(f"  {r['bin']:<42s}  cur Δ={c['cur_delta']:+.3f}  "
              f"flow Δ={c['flow_delta']:+.2f}  → {c['label']}")


if __name__ == "__main__":
    main()
