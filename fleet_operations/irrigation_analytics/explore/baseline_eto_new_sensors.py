#!/usr/bin/env python3
# Establish new ETO baseline from runs since 2026-06-08 17:00 PDT.
#
# Context (Glenn 2026-06-09): well-filter cleaning issue is fixed and the
# new flow sensor is operational. Old baselines were polluted by clogged
# filter + drifting sensor. Pull every ETO run since 5 PM yesterday and
# compute per-bin mean of:
#   - PLC main_flow_meter (well GPM, the new sensor)
#   - FILTERED_HUNTER_VALVE (zone-side smoothed GPM)
#
# Output: stdout table, plus JSON snapshot under snapshots/<today>/.
#
# Runs over SSH to pi@irrigation. PLC_MEASUREMENTS_STREAM is ~1 sample/min
# so a 50-min run yields ~50 PLC samples to average over.

import json
import subprocess
import sys
import os
import datetime

ETO_PINS = {
    "satellite_2:13", "satellite_2:14", "satellite_2:15", "satellite_2:16",
    "satellite_3:1",  "satellite_3:13", "satellite_3:14", "satellite_3:15",
    "satellite_3:18", "satellite_3:2",  "satellite_3:5",  "satellite_4:1",
    "satellite_4:10", "satellite_4:11", "satellite_4:12", "satellite_4:3",
    "satellite_4:4",  "satellite_4:6",  "satellite_4:7",  "satellite_4:9",
}

START_PDT = datetime.datetime(2026, 6, 8, 17, 0, 0,
                              tzinfo=datetime.timezone(datetime.timedelta(hours=-7)))
START_MS = int(START_PDT.timestamp() * 1000)

PY_REMOTE = r"""
import redis, msgpack, json, sys
START_MS = %d
r = redis.Redis(db=4)
PA_KEY = [k for k in r.scan_iter(match="*PAST_ACTIONS*")][0]
PLC_KEY = [k for k in r.scan_iter(match="*PLC_MEASUREMENTS_STREAM*")][0]
pa = r.xrange(PA_KEY, min="%%d-0" %% START_MS, max="+", count=10000)
plc = r.xrange(PLC_KEY, min="%%d-0" %% START_MS, max="+", count=10000)
def decode_ents(ents):
    out = []
    for sid, fields in ents:
        d = msgpack.unpackb(fields[b"data"], raw=False)
        out.append({"sid_ms": int(sid.decode().split("-")[0]), **d})
    return out
def decode_plc(ents):
    out = []
    for sid, fields in ents:
        d = msgpack.unpackb(fields[b"data"], raw=False)
        out.append({"sid_ms": int(sid.decode().split("-")[0]), **d})
    return out
sys.stdout.write(json.dumps({"pa": decode_ents(pa), "plc": decode_plc(plc)}))
""" % START_MS

def run_remote():
    cmd = ["ssh", "pi@irrigation", "python3 -"]
    p = subprocess.run(cmd, input=PY_REMOTE, capture_output=True, text=True, timeout=60)
    if p.returncode != 0:
        print(f"ssh error: {p.stderr}", file=sys.stderr)
        sys.exit(1)
    return json.loads(p.stdout)

def bin_key_of(details):
    valves = []
    for grp in details.get("io_setup", []) or []:
        rem = grp.get("remote", "")
        for bit in grp.get("bits", []) or []:
            valves.append(f"{rem}:{bit}")
    return "/".join(sorted(valves)), valves

def main():
    data = run_remote()
    pa, plc = data["pa"], data["plc"]
    print(f"loaded {len(pa)} past_actions, {len(plc)} PLC samples since "
          f"{START_PDT.strftime('%Y-%m-%d %H:%M %Z')}", file=sys.stderr)

    # Pair STATION_START -> STEP_COMPLETE per bin
    opens = {}
    runs = []
    for ev in pa:
        act = ev.get("action")
        det = ev.get("details", {}) or {}
        if not isinstance(det, dict):
            continue  # ETO_RESTRICTION carries a string
        bk, vs = bin_key_of(det)
        if act == "IRRIGATION_STATION_START":
            opens[bk] = ev["sid_ms"]
        elif act == "IRRIGATION_STEP_COMPLETE":
            is_eto = any(v in ETO_PINS for v in vs)
            if not is_eto:
                continue
            start_ms = opens.pop(bk, None) or (ev["sid_ms"] - (det.get("run_time", 0) or 0) * 60_000)
            runs.append({
                "bin": bk, "valves": vs,
                "start_ms": start_ms, "end_ms": ev["sid_ms"],
                "run_time_min": det.get("run_time"),
                "schedule": det.get("schedule_name"),
                "step": det.get("step"),
            })

    # Index PLC by ms for fast window lookup
    plc_sorted = sorted(plc, key=lambda x: x["sid_ms"])
    def window(s, e):
        return [p for p in plc_sorted if s <= p["sid_ms"] <= e]

    for run in runs:
        w = window(run["start_ms"], run["end_ms"])
        mflow = [p["main_flow_meter"] for p in w if p.get("main_flow_meter") is not None]
        fhv = [p["FILTERED_HUNTER_VALVE"] for p in w if p.get("FILTERED_HUNTER_VALVE") is not None]
        hhi = [p["HUNTER_HIRES_VALVE"] for p in w if p.get("HUNTER_HIRES_VALVE") is not None]
        run["n_plc"] = len(w)
        run["plc_mean"] = sum(mflow)/len(mflow) if mflow else None
        run["plc_max"]  = max(mflow) if mflow else None
        run["fhv_mean"] = sum(fhv)/len(fhv) if fhv else None
        run["fhv_max"]  = max(fhv) if fhv else None
        run["hhi_mean"] = sum(hhi)/len(hhi) if hhi else None

    runs.sort(key=lambda r: r["start_ms"])

    # Pretty print
    print()
    print(f"ETO RUNS  since 2026-06-08 17:00 PDT  ({len(runs)} runs)")
    print()
    hdr = (f"{'start':<14}  {'bin':<46}  {'min':>4}  "
           f"{'plc_avg':>8}  {'plc_max':>8}  {'fhv_avg':>8}  {'fhv_max':>8}  "
           f"{'hhi_avg':>8}  {'n':>3}")
    print(hdr)
    print("-" * len(hdr))
    for r in runs:
        s = datetime.datetime.fromtimestamp(
            r["start_ms"]/1000,
            tz=datetime.timezone(datetime.timedelta(hours=-7)))
        bin_s = r["bin"][:46]
        f = lambda v: f"{v:8.1f}" if v is not None else f"{'-':>8}"
        print(f"{s.strftime('%m-%d %H:%M'):<14}  {bin_s:<46}  {str(r['run_time_min']):>4}  "
              f"{f(r['plc_mean'])}  {f(r['plc_max'])}  {f(r['fhv_mean'])}  {f(r['fhv_max'])}  "
              f"{f(r['hhi_mean'])}  {r['n_plc']:>3}")

    # Per-bin aggregation (mean of means across all runs in window)
    from collections import defaultdict
    per_bin = defaultdict(lambda: {"plc": [], "fhv": [], "hhi": [], "n_runs": 0})
    for r in runs:
        for k in ("plc","fhv","hhi"):
            v = r[f"{k}_mean"]
            if v is not None:
                per_bin[r["bin"]][k].append(v)
        per_bin[r["bin"]]["n_runs"] += 1

    print()
    print(f"PER-BIN BASELINE (mean of run-means)")
    print()
    hdr = (f"{'bin':<46}  {'runs':>4}  {'plc_avg':>8}  {'fhv_avg':>8}  {'hhi_avg':>8}")
    print(hdr)
    print("-" * len(hdr))
    rows = []
    for bk, agg in per_bin.items():
        rows.append({
            "bin": bk,
            "n_runs": agg["n_runs"],
            "plc_avg": sum(agg["plc"])/len(agg["plc"]) if agg["plc"] else None,
            "fhv_avg": sum(agg["fhv"])/len(agg["fhv"]) if agg["fhv"] else None,
            "hhi_avg": sum(agg["hhi"])/len(agg["hhi"]) if agg["hhi"] else None,
        })
    rows.sort(key=lambda x: x["bin"])
    for r in rows:
        f = lambda v: f"{v:8.1f}" if v is not None else f"{'-':>8}"
        print(f"{r['bin'][:46]:<46}  {r['n_runs']:>4}  {f(r['plc_avg'])}  {f(r['fhv_avg'])}  {f(r['hhi_avg'])}")

    # Snapshot
    today = datetime.datetime.now().strftime("%Y-%m-%d")
    snap_dir = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                            "snapshots", today)
    os.makedirs(snap_dir, exist_ok=True)
    snap_path = os.path.join(snap_dir, "baseline_eto_new_sensors.json")
    with open(snap_path, "w") as f:
        json.dump({
            "schema": "baseline_eto_new_sensors/1",
            "since_pdt": START_PDT.strftime("%Y-%m-%d %H:%M %Z"),
            "n_runs": len(runs),
            "per_bin": rows,
            "runs": runs,
        }, f, indent=2, default=str)
    print()
    print(f"snapshot: {snap_path}", file=sys.stderr)

if __name__ == "__main__":
    main()
