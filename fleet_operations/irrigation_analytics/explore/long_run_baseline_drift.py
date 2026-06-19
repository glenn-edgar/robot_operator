#!/usr/bin/env python3
"""
Long-run BASELINE-DRIFT analyzer (complement to within-run scan).

For each bin with a long run in today's snapshot, compute the steady-state
body median for the NEWEST run, compare it to the historic baseline (median
of body_med across older runs in the same bin), and flag drift.

Outputs:
  1. Per-bin: newest body_med vs historic median ± MAD (Iglewicz-Hoaglin z)
  2. Flagged drift table sorted by |z|
  3. Cohort scan: which satellites have ≥3 bins with same-sign drift today

This is the cross-night equivalent of today_flow_endpoint.py but for LONG
runs where steady-state can be averaged over many samples (less noise than
end-mean of 3).
"""
import json
import statistics as st
import sys
from pathlib import Path
from collections import defaultdict

STARTUP_SKIP = 3
TAIL_SKIP    = 2
MIN_BODY     = 14
K_MAD        = 3.5
GPM_FLOOR    = 1.0
A_FLOOR      = 0.03
MIN_HIST     = 4

ROOT = Path(__file__).parent
DEFAULT_SNAP = ROOT / "snapshots" / "2026-05-30" / "time_history.json"


def median(xs):
    return st.median(xs) if xs else None


def mad(xs, m=None):
    if not xs: return None
    if m is None: m = median(xs)
    return median([abs(v - m) for v in xs])


def body_med(samples):
    if not samples or len(samples) < STARTUP_SKIP + TAIL_SKIP + MIN_BODY:
        return None
    body = samples[STARTUP_SKIP: len(samples) - TAIL_SKIP]
    return median(body) if body else None


def historic_baseline(runs, stream_key, exclude_last=True):
    pool = runs[:-1] if (exclude_last and len(runs) > 1) else runs
    bms = []
    for r in pool:
        arr = (r.get(stream_key) or {}).get("data") or []
        bm = body_med(arr)
        if bm is not None:
            bms.append(bm)
    if len(bms) < MIN_HIST:
        return None
    m = median(bms)
    return {
        "n":   len(bms),
        "med": m,
        "mad": mad(bms, m),
        "all": bms,
    }


def iglew_z(v, m, m_mad):
    if m_mad is None or m_mad < 1e-9:
        return None
    return 0.6745 * (v - m) / m_mad


def classify_drift(today, base, floor):
    if today is None or base is None: return None
    z = iglew_z(today, base["med"], base["mad"])
    delta = today - base["med"]
    gate = max(K_MAD * (base["mad"] or 0), floor)
    flagged = abs(delta) > gate
    if not flagged: return {"z": z, "delta": delta, "gate": gate, "flagged": False, "label": "OK"}
    if delta > 0: label = "ABOVE_BASELINE"
    else:         label = "BELOW_BASELINE"
    return {"z": z, "delta": delta, "gate": gate, "flagged": True, "label": label}


def parse_satellite(bin_key):
    """Returns sat number if bin is solo or sat_1:39+sat_X paired; else None."""
    parts = bin_key.split("/")
    sats = set()
    for p in parts:
        # sat_1:39 master is ignored when paired with another sat
        if p == "satellite_1:39": continue
        s = p.split(":")[0]  # 'satellite_X'
        sats.add(s)
    if len(sats) == 1:
        return next(iter(sats))
    return None


def main():
    snap = Path(sys.argv[1]) if len(sys.argv) > 1 else DEFAULT_SNAP
    print(f"snapshot: {snap}\n")
    d = json.loads(snap.read_text())

    per_bin = []
    for bin_key, runs in sorted(d.items()):
        if not runs: continue
        newest = runs[-1]
        flow_today = body_med((newest.get("HUNTER_FLOW_METER") or {}).get("data") or [])
        cur_today  = body_med((newest.get("IRRIGATION_CURRENT") or {}).get("data") or [])
        if flow_today is None and cur_today is None: continue
        flow_base = historic_baseline(runs, "HUNTER_FLOW_METER")
        cur_base  = historic_baseline(runs, "IRRIGATION_CURRENT")
        flow_drift = classify_drift(flow_today, flow_base, GPM_FLOOR)
        cur_drift  = classify_drift(cur_today,  cur_base,  A_FLOOR)
        per_bin.append({
            "bin":        bin_key,
            "n_runs":     len(runs),
            "sat":        parse_satellite(bin_key),
            "flow_today": flow_today,
            "cur_today":  cur_today,
            "flow_base":  flow_base,
            "cur_base":   cur_base,
            "flow_drift": flow_drift,
            "cur_drift":  cur_drift,
        })

    # ── 1) Per-bin table ──
    print(f"=== Long-run baseline-drift scan ({len(per_bin)} bins; body>={MIN_BODY}) ===")
    print(f"    flow gate: |Δ| > max(K={K_MAD}*MAD, {GPM_FLOOR} GPM)   "
          f"cur gate: |Δ| > max(K={K_MAD}*MAD, {A_FLOOR} A)\n")
    hdr = (f"  {'bin':<42s} {'nh':>2s}  "
           f"{'F now':>5s} {'F base':>6s}±{'mad':<4s} {'fΔ':>5s} {'fz':>5s} {'fcls':<14s}  "
           f"{'C now':>5s} {'C base':>6s}±{'mad':<4s} {'cΔ':>6s} {'cz':>5s} {'ccls':<14s}")
    print(hdr); print("  " + "-" * (len(hdr) - 2))

    def sk(r):
        z = 0
        if r["flow_drift"] and r["flow_drift"].get("z") is not None:
            z = max(z, abs(r["flow_drift"]["z"]))
        if r["cur_drift"] and r["cur_drift"].get("z") is not None:
            z = max(z, abs(r["cur_drift"]["z"]))
        return -z
    per_bin.sort(key=sk)

    for r in per_bin:
        b = r["bin"][:40]
        ft = f"{r['flow_today']:.1f}" if r['flow_today'] is not None else "  —"
        ct = f"{r['cur_today']:.2f}" if r['cur_today']  is not None else "  —"
        fb = r["flow_base"]
        cb = r["cur_base"]
        fbm  = f"{fb['med']:.1f}" if fb else "  —"
        fbmd = f"{fb['mad']:.2f}" if fb else "—"
        cbm  = f"{cb['med']:.2f}" if cb else "  —"
        cbmd = f"{cb['mad']:.3f}" if cb else "—"
        fd = r["flow_drift"]
        cd = r["cur_drift"]
        fd_s = (f"{fd['delta']:+5.1f} {fd['z'] or 0:>5.1f} {fd['label']:<14s}" if fd
                else f"   —    —   {'no_hist':<14s}")
        cd_s = (f"{cd['delta']:+6.2f} {cd['z'] or 0:>5.1f} {cd['label']:<14s}" if cd
                else f"    —    —   {'no_hist':<14s}")
        nh = f"{(fb and fb['n']) or 0:>2d}"
        print(f"  {b:<42s} {nh}  "
              f"{ft:>5s} {fbm:>6s}±{fbmd:<4s} {fd_s}  "
              f"{ct:>5s} {cbm:>6s}±{cbmd:<4s} {cd_s}")

    # ── 2) Flagged bins ──
    flagged = [r for r in per_bin
               if (r["flow_drift"] and r["flow_drift"]["flagged"])
               or (r["cur_drift"]  and r["cur_drift"]["flagged"])]
    def zstr(z):
        return f"{z:+.2f}" if z is not None else "  n/a"

    print(f"\n=== Flagged drift bins ({len(flagged)}) ===")
    for r in flagged:
        fd = r["flow_drift"]; cd = r["cur_drift"]
        print(f"\n  {r['bin']}")
        if fd and fd["flagged"]:
            fb = r["flow_base"]
            print(f"    FLOW {fd['label']}  today={r['flow_today']:.1f} "
                  f"base={fb['med']:.1f}±{fb['mad']:.2f}  "
                  f"Δ={fd['delta']:+.2f}  z={zstr(fd['z'])}  "
                  f"(n_hist={fb['n']})")
        if cd and cd["flagged"]:
            cb = r["cur_base"]
            print(f"    CUR  {cd['label']}  today={r['cur_today']:.3f} "
                  f"base={cb['med']:.3f}±{cb['mad']:.4f}  "
                  f"Δ={cd['delta']:+.3f}  z={zstr(cd['z'])}  "
                  f"(n_hist={cb['n']})")

    # ── 3) Cohort scan ──
    print(f"\n=== Per-satellite cohort drift (today's runs only) ===")
    by_sat = defaultdict(lambda: {"flow_neg": 0, "flow_pos": 0, "cur_neg": 0, "cur_pos": 0,
                                  "bins": [], "flow_dz_sum": 0.0, "cur_dz_sum": 0.0,
                                  "n_bins": 0})
    for r in per_bin:
        if r["sat"] is None: continue
        s = by_sat[r["sat"]]
        s["bins"].append(r["bin"])
        s["n_bins"] += 1
        if r["flow_drift"] and r["flow_drift"].get("z") is not None:
            z = r["flow_drift"]["z"]
            s["flow_dz_sum"] += z
            if z < -0.5: s["flow_neg"] += 1
            if z > +0.5: s["flow_pos"] += 1
        if r["cur_drift"] and r["cur_drift"].get("z") is not None:
            z = r["cur_drift"]["z"]
            s["cur_dz_sum"] += z
            if z < -0.5: s["cur_neg"] += 1
            if z > +0.5: s["cur_pos"] += 1

    print(f"  {'sat':<14s} {'#bins':>5s}  "
          f"{'F-':>3s} {'F+':>3s} {'avg fz':>7s}  "
          f"{'C-':>3s} {'C+':>3s} {'avg cz':>7s}")
    print("  " + "-" * 60)
    for sat, s in sorted(by_sat.items()):
        n = s["n_bins"]
        avg_fz = s["flow_dz_sum"] / n if n else 0
        avg_cz = s["cur_dz_sum"]  / n if n else 0
        print(f"  {sat:<14s} {n:>5d}  "
              f"{s['flow_neg']:>3d} {s['flow_pos']:>3d} {avg_fz:>+7.2f}  "
              f"{s['cur_neg']:>3d} {s['cur_pos']:>3d} {avg_cz:>+7.2f}")


if __name__ == "__main__":
    main()
