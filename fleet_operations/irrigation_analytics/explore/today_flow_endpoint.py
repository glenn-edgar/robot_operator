#!/usr/bin/env python3
"""
Today's-runs HUNTER_FLOW_METER end-point analyzer.

Companion to today_last_sample.py. Same indexing approach:
  past_actions today  →  take last-N TIME_HISTORY runs per bin  →
  compute end-flow (mean of last 3 flow samples) for each.

Per-bin baseline: median + MAD of historic end-flow values (the
TIME_HISTORY runs BEFORE today's slice). This is intentionally per-bin
because flow depends entirely on head count + nozzle size per zone.

Flag rule:
  |end_flow - baseline_median| > max(K_MAD * MAD, GPM_FLOOR)
  K_MAD     = 3.5
  GPM_FLOOR = 2.0
Sign:
  +Δ → over-flow → broken / popped / missing head (or new head added)
  -Δ → under-flow → clogged head / partial blockage / valve restriction

Notes on short runs (this is today's data — 5–45 min, NOT seconds —
TIME_HISTORY samples are 1/min):
  - First sample is rise-from-0 transient. Skip if len ≥ 4.
  - End-3 mean is steady-state for runs ≥ 4 samples.

Units: GPM (HUNTER_FLOW_METER native).

Run via:  python3 today_flow_endpoint.py
"""
import json
import statistics as st
import subprocess
import sys
from collections import defaultdict
from pathlib import Path

K_MAD     = 3.5
GPM_FLOOR = 2.0
END_N     = 3
MIN_HIST  = 4    # need ≥ 4 historic runs for baseline

ROOT = Path(__file__).parent

PULL_PAST_PY = r"""
import redis, msgpack, json, sys, datetime as DT
PAST_DB = 4
PAST_KEY = ("[SYSTEM:main_operations][SITE:LaCima][APPLICATION_SUPPORT:APPLICATION_SUPPORT]"
            "[IRRIGIGATION_SCHEDULING_CONTROL:IRRIGIGATION_SCHEDULING_CONTROL]"
            "[PACKAGE:IRRIGIGATION_SCHEDULING_CONTROL_DATA][STREAM_REDIS:IRRIGATION_PAST_ACTIONS]")
today = DT.datetime.now().astimezone().date()
midnight = DT.datetime.combine(today, DT.time(0,0)).astimezone()
min_ms = int(midnight.timestamp() * 1000)
r = redis.Redis(db=PAST_DB)
ents = r.xrange(PAST_KEY, min=f"{min_ms}-0", max='+', count=10000)
runs, opens = [], []
for sid, fields in ents:
    rec = {}
    for k, v in fields.items():
        ks = k.decode()
        try: rec[ks] = msgpack.unpackb(v, raw=False)
        except Exception:
            try: rec[ks] = v.decode()
            except: rec[ks] = repr(v)
    data = rec.get("data", {})
    act = data.get("action"); det = data.get("details", {})
    if act == "IRRIGATION_STATION_START":
        opens.append((sid.decode(), det))
    elif act == "IRRIGATION_STEP_COMPLETE":
        for i in range(len(opens)-1, -1, -1):
            ssid, sdet = opens[i]
            if sdet.get("step") == det.get("step") and sdet.get("schedule_name") == det.get("schedule_name"):
                runs.append({
                    "start_id": ssid,
                    "start_ms": int(ssid.split("-")[0]),
                    "schedule": det.get("schedule_name"),
                    "step": det.get("step"),
                    "run_time_min": det.get("run_time"),
                    "io_setup": det.get("io_setup"),
                })
                opens.pop(i); break
sys.stdout.write(json.dumps(runs, default=str))
"""

PULL_TH_PY_TEMPLATE = r"""
import redis, msgpack, json, sys
TH_DB = 4
TH_KEY = ("[SYSTEM:main_operations][SITE:LaCima][APPLICATION_SUPPORT:APPLICATION_SUPPORT]"
          "[IRRIGIGATION_SCHEDULING_CONTROL:IRRIGIGATION_SCHEDULING_CONTROL]"
          "[PACKAGE:IRRIGIGATION_SCHEDULING_CONTROL_DATA][HASH:IRRIGATION_TIME_HISTORY]")
bins = __BINS_JSON__
r = redis.Redis(db=TH_DB)
out = {}
for b in bins:
    v = r.hget(TH_KEY, b)
    if not v: continue
    runs = msgpack.unpackb(v, raw=False)
    slim = []
    for run in runs:
        fl = (run.get("HUNTER_FLOW_METER") or {}).get("data") or []
        slim.append(fl)
    out[b] = slim
sys.stdout.write(json.dumps(out, default=str))
"""


def ssh_python(code, timeout=30):
    r = subprocess.run(
        ["ssh", "-o", "ConnectTimeout=8", "-o", "BatchMode=yes",
         "pi@irrigation", "python3", "-"],
        input=code, capture_output=True, text=True, timeout=timeout,
    )
    if r.returncode != 0:
        sys.stderr.write(f"ssh failed: {r.stderr}\n"); sys.exit(2)
    return r.stdout


def canonicalize_io(io_setup):
    if not io_setup: return "?"
    parts = []
    for s in io_setup:
        rem = s.get("remote", "?")
        for b in (s.get("bits") or []):
            parts.append(f"{rem}:{b}")
    parts.sort()
    return "/".join(parts)


def end_mean(samples, n=END_N):
    """End-mean. Drops first sample (rise transient) when run is long enough."""
    if not samples: return None
    body = samples[1:] if len(samples) >= 4 else samples
    tail = body[-n:] if len(body) >= n else body
    if not tail: return None
    return sum(tail) / len(tail)


def median_mad(values):
    if not values: return None, None
    med = st.median(values)
    mad = st.median([abs(v - med) for v in values])
    return med, mad


def classify(end, med, mad):
    if end is None or med is None: return ""
    delta = end - med
    if mad is not None and mad > 0:
        gate = max(K_MAD * mad, GPM_FLOOR)
    else:
        gate = GPM_FLOOR
    if abs(delta) <= gate: return ""
    return "BREAK" if delta > 0 else "CLOG"


def main():
    # 1) Today's runs
    runs = json.loads(ssh_python(PULL_PAST_PY))
    print(f"Today's runs: {len(runs)}")
    for r in runs:
        r["bin_key"] = canonicalize_io(r["io_setup"])

    # 2) TIME_HISTORY flows for all unique bins (full history)
    unique_bins = sorted({r["bin_key"] for r in runs})
    pull_code = PULL_TH_PY_TEMPLATE.replace("__BINS_JSON__", json.dumps(unique_bins))
    th_flows = json.loads(ssh_python(pull_code))
    print(f"TIME_HISTORY bins fetched: {len(th_flows)}")

    # 3) Per-bin: split into history vs today
    today_per_bin = defaultdict(list)
    for r in runs:
        today_per_bin[r["bin_key"]].append(r)

    enriched = []
    skipped = []
    for bin_key, today_runs in today_per_bin.items():
        all_flows = th_flows.get(bin_key, [])
        n_today = len(today_runs)
        if len(all_flows) < n_today:
            skipped.append((bin_key, f"only {len(all_flows)} TH runs for {n_today} past_action runs"))
            continue
        today_flows = all_flows[-n_today:]
        hist_flows  = all_flows[:-n_today]
        # Baseline from historic end-means
        hist_ends = [end_mean(f) for f in hist_flows]
        hist_ends = [e for e in hist_ends if e is not None]
        hist_med, hist_mad = (median_mad(hist_ends) if len(hist_ends) >= MIN_HIST else (None, None))

        today_runs_sorted = sorted(today_runs, key=lambda r: r["start_ms"])
        for pa, fl in zip(today_runs_sorted, today_flows):
            em = end_mean(fl)
            cls = classify(em, hist_med, hist_mad)
            delta = (em - hist_med) if (em is not None and hist_med is not None) else None
            z = None
            if delta is not None and hist_mad is not None and hist_mad > 0:
                # Iglewicz-Hoaglin-equivalent z (0.6745 / MAD)
                z = 0.6745 * delta / hist_mad
            enriched.append({
                "schedule": pa["schedule"],
                "step": pa["step"],
                "bin_key": bin_key,
                "run_time_min": pa["run_time_min"],
                "fl_len": len(fl),
                "end_flow": em,
                "hist_n": len(hist_ends),
                "hist_med": hist_med,
                "hist_mad": hist_mad,
                "delta": delta,
                "z": z,
                "cls": cls,
            })

    enriched_sorted = sorted(enriched, key=lambda r: (r["schedule"], r["step"]))

    print()
    print(f"=== Today's {len(enriched)} runs: end-flow (GPM) — baseline = bin's historic end-flow med ± MAD ===")
    print(f"    Skip first sample (rise transient); end = mean of last {END_N} samples; K_MAD={K_MAD}; floor={GPM_FLOOR} GPM")
    print()
    hdr = (f"  {'schedule':<14s} {'step':>4s}  {'bin_key':<32s} "
           f"{'rt_m':>4s} {'fl_n':>4s}  "
           f"{'end':>5s} {'med':>5s} {'MAD':>5s} {'n_h':>3s}  "
           f"{'Δ':>6s} {'z':>5s}  {'cls':<5s}")
    print(hdr)
    print("  " + "-" * (len(hdr) - 2))
    for r in enriched_sorted:
        end = f"{r['end_flow']:.1f}" if r['end_flow'] is not None else "  —"
        med = f"{r['hist_med']:.1f}" if r['hist_med'] is not None else "  —"
        mad = f"{r['hist_mad']:.1f}" if r['hist_mad'] is not None else "  —"
        delta = f"{r['delta']:+.1f}" if r['delta'] is not None else "    —"
        z = f"{r['z']:+.1f}" if r['z'] is not None else "  —"
        print(f"  {r['schedule']:<14s} {r['step']:>4d}  {r['bin_key']:<32s} "
              f"{r['run_time_min']:>4d} {r['fl_len']:>4d}  "
              f"{end:>5s} {med:>5s} {mad:>5s} {r['hist_n']:>3d}  "
              f"{delta:>6s} {z:>5s}  {r['cls']:<5s}")

    # Skipped
    if skipped:
        print()
        print(f"=== Skipped ({len(skipped)}) — past_action vs TIME_HISTORY count mismatch ===")
        for bk, msg in skipped:
            print(f"  {bk:<32s} {msg}")

    # Per-bin summary, sorted by max |z|
    by_bin = defaultdict(list)
    for r in enriched:
        by_bin[r["bin_key"]].append(r)
    print()
    print(f"=== Per-bin summary across today's repeats (sorted by max |z|) ===")
    rows = []
    for bk, rs in by_bin.items():
        ends = [r["end_flow"] for r in rs if r["end_flow"] is not None]
        zs   = [r["z"] for r in rs if r["z"] is not None]
        if not ends: continue
        rows.append({
            "bin_key": bk, "n": len(rs),
            "end_med": st.median(ends), "end_min": min(ends), "end_max": max(ends),
            "hist_med": rs[0]["hist_med"], "hist_mad": rs[0]["hist_mad"],
            "hist_n": rs[0]["hist_n"],
            "z_max": max((abs(z) for z in zs), default=None),
            "any_flag": any(r["cls"] for r in rs),
        })
    rows.sort(key=lambda r: -(r["z_max"] or 0))
    print(f"  {'bin_key':<32s} {'n':>2s}  "
          f"{'end_med':>7s} {'h_med':>5s} {'h_MAD':>5s} {'h_n':>3s}  "
          f"{'|z|max':>6s}  flag")
    print("  " + "-" * 80)
    for r in rows:
        hm = f"{r['hist_med']:.1f}" if r['hist_med'] is not None else "  —"
        hmad = f"{r['hist_mad']:.1f}" if r['hist_mad'] is not None else "  —"
        zm = f"{r['z_max']:.1f}" if r['z_max'] is not None else "   —"
        flag = "FLAG" if r["any_flag"] else ""
        print(f"  {r['bin_key']:<32s} {r['n']:>2d}  "
              f"{r['end_med']:>7.1f} {hm:>5s} {hmad:>5s} {r['hist_n']:>3d}  "
              f"{zm:>6s}  {flag}")

    # Flagged-only list (for fast triage)
    flagged = [r for r in enriched if r["cls"]]
    print()
    print(f"=== Flagged runs ({len(flagged)}) — Δ exceeds max(K_MAD×MAD, {GPM_FLOOR} GPM) ===")
    for r in flagged:
        print(f"  {r['schedule']:<14s} step={r['step']:>2d}  {r['bin_key']:<28s}  "
              f"end={r['end_flow']:.1f}  med={r['hist_med']:.1f}  "
              f"Δ={r['delta']:+.1f}  cls={r['cls']}")


if __name__ == "__main__":
    main()
