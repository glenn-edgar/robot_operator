#!/usr/bin/env python3
"""
End-point analyzer over an arbitrary recent-hours window.

Same math as today_flow_endpoint.py, but the cutoff is now-MINUS-HOURS
instead of local midnight.

  python3 recent_end_score.py [hours]      # default: 12

Per bin we:
  1) pull past_actions IRRIGATION_STATION_START / IRRIGATION_STEP_COMPLETE
     pairs within the window
  2) walk that bin's TIME_HISTORY tail (newest N == the N runs we just
     identified in the window)
  3) for each: end_mean = mean of last 3 HUNTER_FLOW samples
     (skip first sample if len >= 4 — rise-from-zero transient)
  4) baseline = median + MAD of historic end-means (all runs BEFORE the
     window slice)
  5) flag if |end - baseline_med| > max(K_MAD * MAD, GPM_FLOOR)
       +Δ  → BREAK (over-flow: popped/broken/missing head)
       -Δ  → CLOG  (under-flow: clogged head / partial blockage)
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
MIN_HIST  = 4

ROOT = Path(__file__).parent

PULL_PAST_TEMPLATE = r"""
import redis, msgpack, json, sys, datetime as DT
PAST_DB = 4
PAST_KEY = ("[SYSTEM:main_operations][SITE:LaCima][APPLICATION_SUPPORT:APPLICATION_SUPPORT]"
            "[IRRIGIGATION_SCHEDULING_CONTROL:IRRIGIGATION_SCHEDULING_CONTROL]"
            "[PACKAGE:IRRIGIGATION_SCHEDULING_CONTROL_DATA][STREAM_REDIS:IRRIGATION_PAST_ACTIONS]")
HOURS = __HOURS__
cutoff = DT.datetime.now().astimezone() - DT.timedelta(hours=HOURS)
min_ms = int(cutoff.timestamp() * 1000)
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
sys.stdout.write(json.dumps({"runs": runs, "cutoff_iso": cutoff.isoformat()}, default=str))
"""

PULL_TH_TEMPLATE = r"""
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
    out[b] = [(run.get("HUNTER_FLOW_METER") or {}).get("data") or [] for run in runs]
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
    gate = max(K_MAD * mad, GPM_FLOOR) if (mad is not None and mad > 0) else GPM_FLOOR
    if abs(delta) <= gate: return ""
    return "BREAK" if delta > 0 else "CLOG"


def main():
    hours = float(sys.argv[1]) if len(sys.argv) > 1 else 12.0

    pull = PULL_PAST_TEMPLATE.replace("__HOURS__", str(hours))
    blob = json.loads(ssh_python(pull))
    runs = blob["runs"]
    print(f"Window: last {hours:g} h  (cutoff: {blob['cutoff_iso']})")
    print(f"Runs in window: {len(runs)}")
    if not runs:
        return

    for r in runs:
        r["bin_key"] = canonicalize_io(r["io_setup"])

    unique_bins = sorted({r["bin_key"] for r in runs})
    pull = PULL_TH_TEMPLATE.replace("__BINS_JSON__", json.dumps(unique_bins))
    th_flows = json.loads(ssh_python(pull))
    print(f"TIME_HISTORY bins fetched: {len(th_flows)}")

    per_bin = defaultdict(list)
    for r in runs:
        per_bin[r["bin_key"]].append(r)

    enriched, skipped = [], []
    for bin_key, win_runs in per_bin.items():
        all_flows = th_flows.get(bin_key, [])
        n_win = len(win_runs)
        if len(all_flows) < n_win:
            skipped.append((bin_key, f"only {len(all_flows)} TH runs for {n_win} window runs"))
            continue
        win_flows = all_flows[-n_win:]
        hist_flows = all_flows[:-n_win]
        hist_ends = [end_mean(f) for f in hist_flows]
        hist_ends = [e for e in hist_ends if e is not None]
        hist_med, hist_mad = (median_mad(hist_ends) if len(hist_ends) >= MIN_HIST else (None, None))

        win_runs_sorted = sorted(win_runs, key=lambda r: r["start_ms"])
        for pa, fl in zip(win_runs_sorted, win_flows):
            em = end_mean(fl)
            cls = classify(em, hist_med, hist_mad)
            delta = (em - hist_med) if (em is not None and hist_med is not None) else None
            z = (0.6745 * delta / hist_mad) if (delta is not None and hist_mad and hist_mad > 0) else None
            enriched.append({
                "schedule": pa["schedule"], "step": pa["step"],
                "bin_key": bin_key, "run_time_min": pa["run_time_min"],
                "fl_len": len(fl), "end_flow": em,
                "hist_n": len(hist_ends), "hist_med": hist_med, "hist_mad": hist_mad,
                "delta": delta, "z": z, "cls": cls,
                "start_ms": pa["start_ms"],
            })

    print()
    print(f"=== {len(enriched)} runs — end-flow GPM, end = mean of last {END_N} samples ===")
    print(f"    Skip first sample (rise transient) when len>=4. Flag if |Δ| > max({K_MAD}×MAD, {GPM_FLOOR} GPM)")
    print()
    hdr = (f"  {'schedule':<14s} {'step':>4s}  {'bin_key':<32s} "
           f"{'rt_m':>4s} {'fl_n':>4s}  {'end':>5s} {'med':>5s} {'MAD':>5s} {'n_h':>3s}  "
           f"{'Δ':>6s} {'z':>5s}  {'cls':<5s}")
    print(hdr)
    print("  " + "-" * (len(hdr) - 2))
    for r in sorted(enriched, key=lambda r: r["start_ms"]):
        end = f"{r['end_flow']:.1f}" if r['end_flow'] is not None else "  —"
        med = f"{r['hist_med']:.1f}" if r['hist_med'] is not None else "  —"
        mad = f"{r['hist_mad']:.1f}" if r['hist_mad'] is not None else "  —"
        delta = f"{r['delta']:+.1f}" if r['delta'] is not None else "    —"
        z = f"{r['z']:+.1f}" if r['z'] is not None else "  —"
        print(f"  {r['schedule']:<14s} {r['step']:>4d}  {r['bin_key']:<32s} "
              f"{r['run_time_min']:>4d} {r['fl_len']:>4d}  "
              f"{end:>5s} {med:>5s} {mad:>5s} {r['hist_n']:>3d}  "
              f"{delta:>6s} {z:>5s}  {r['cls']:<5s}")

    if skipped:
        print()
        print(f"=== Skipped ({len(skipped)}) — count mismatch (in-flight or rolled-off) ===")
        for bk, msg in skipped:
            print(f"  {bk:<32s} {msg}")

    flagged = [r for r in enriched if r["cls"]]
    print()
    print(f"=== Flagged runs ({len(flagged)}) ===")
    for r in sorted(flagged, key=lambda r: -abs(r["delta"] or 0)):
        print(f"  {r['schedule']:<14s} step={r['step']:>2d}  {r['bin_key']:<28s}  "
              f"end={r['end_flow']:.1f}  med={r['hist_med']:.1f}  "
              f"Δ={r['delta']:+.1f}  cls={r['cls']}")


if __name__ == "__main__":
    main()
