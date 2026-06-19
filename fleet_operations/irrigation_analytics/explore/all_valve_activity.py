#!/usr/bin/env python3
# All valve activity (ETO + non-ETO + city + maintenance) since a cutoff.
# Pulls STATION_START / STEP_COMPLETE pairs, then averages
# PLC main_flow_meter and FILTERED_HUNTER_VALVE per run window.

import json
import subprocess
import sys
import datetime

ETO_PINS = {
    "satellite_2:13", "satellite_2:14", "satellite_2:15", "satellite_2:16",
    "satellite_3:1",  "satellite_3:13", "satellite_3:14", "satellite_3:15",
    "satellite_3:18", "satellite_3:2",  "satellite_3:5",  "satellite_4:1",
    "satellite_4:10", "satellite_4:11", "satellite_4:12", "satellite_4:3",
    "satellite_4:4",  "satellite_4:6",  "satellite_4:7",  "satellite_4:9",
}
CITY_VALVE = "satellite_1:39"

# 2026-06-08 18:00 PDT
START_PDT = datetime.datetime(2026, 6, 8, 18, 0, 0,
                              tzinfo=datetime.timezone(datetime.timedelta(hours=-7)))
START_MS = int(START_PDT.timestamp() * 1000)

PY_REMOTE = r"""
import redis, msgpack, json, sys
START_MS = %d
r = redis.Redis(db=4)
PA_KEY  = [k for k in r.scan_iter(match="*PAST_ACTIONS*")][0]
PLC_KEY = [k for k in r.scan_iter(match="*PLC_MEASUREMENTS_STREAM*")][0]
pa = r.xrange(PA_KEY, min="%%d-0" %% START_MS, max="+", count=10000)
plc = r.xrange(PLC_KEY, min="%%d-0" %% START_MS, max="+", count=20000)
def dec(ents):
    out = []
    for sid, fields in ents:
        d = msgpack.unpackb(fields[b"data"], raw=False)
        out.append({"sid_ms": int(sid.decode().split("-")[0]), **d})
    return out
sys.stdout.write(json.dumps({"pa": dec(pa), "plc": dec(plc)}))
""" % START_MS

def run_remote():
    p = subprocess.run(["ssh", "pi@irrigation", "python3 -"],
                       input=PY_REMOTE, capture_output=True, text=True, timeout=60)
    if p.returncode != 0:
        print(p.stderr, file=sys.stderr); sys.exit(1)
    return json.loads(p.stdout)

def bin_key_of(details):
    if not isinstance(details, dict): return None, []
    vs = []
    for grp in details.get("io_setup", []) or []:
        rem = grp.get("remote", "")
        for bit in grp.get("bits", []) or []:
            vs.append(f"{rem}:{bit}")
    return "/".join(sorted(vs)), vs

def main():
    data = run_remote()
    pa, plc = data["pa"], data["plc"]
    plc_sorted = sorted(plc, key=lambda x: x["sid_ms"])

    opens = {}
    runs = []
    skips = 0
    for ev in pa:
        act = ev.get("action")
        det = ev.get("details", {}) or {}
        if not isinstance(det, dict): continue
        bk, vs = bin_key_of(det)
        if not bk: continue
        if act == "IRRIGATION_STATION_START":
            opens[bk] = ev["sid_ms"]
        elif act == "IRRIGATION_STEP_COMPLETE":
            start_ms = opens.pop(bk, None) or (ev["sid_ms"] - (det.get("run_time", 0) or 0) * 60_000)
            is_eto = any(v in ETO_PINS for v in vs)
            is_city = CITY_VALVE in vs
            runs.append({
                "bin": bk, "valves": vs,
                "is_eto": is_eto, "is_city": is_city,
                "start_ms": start_ms, "end_ms": ev["sid_ms"],
                "run_time_min": det.get("run_time"),
                "schedule": det.get("schedule_name"),
                "step": det.get("step"),
            })
        elif act == "SKIP_OPERATION":
            skips += 1

    def window(s, e):
        return [p for p in plc_sorted if s <= p["sid_ms"] <= e]

    for run in runs:
        w = window(run["start_ms"], run["end_ms"])
        mflow = [p["main_flow_meter"] for p in w if p.get("main_flow_meter") is not None]
        fhv   = [p["FILTERED_HUNTER_VALVE"] for p in w if p.get("FILTERED_HUNTER_VALVE") is not None]
        run["n"] = len(w)
        run["plc_avg"] = sum(mflow)/len(mflow) if mflow else None
        run["plc_max"] = max(mflow) if mflow else None
        run["fhv_avg"] = sum(fhv)/len(fhv) if fhv else None
        run["fhv_max"] = max(fhv) if fhv else None

    runs.sort(key=lambda r: r["start_ms"])

    # Classify
    def tag(r):
        bits = []
        if r["is_eto"]: bits.append("ETO")
        else:           bits.append("non-ETO")
        if r["is_city"]: bits.append("city")
        # Short flushes / maintenance
        rt = r["run_time_min"] or 0
        if rt <= 5: bits.append("short")
        return "/".join(bits)

    print(f"\nALL VALVE ACTIVITY since {START_PDT.strftime('%Y-%m-%d %H:%M %Z')}  "
          f"({len(runs)} runs, {skips} SKIP_OPERATION events)\n")

    hdr = (f"{'#':>3}  {'start':<14}  {'bin':<46}  {'min':>4}  "
           f"{'tag':<18}  {'plc_avg':>8}  {'plc_max':>8}  "
           f"{'fhv_avg':>8}  {'fhv_max':>8}  {'sched':<22}")
    print(hdr); print("-" * len(hdr))
    for i, r in enumerate(runs, 1):
        s = datetime.datetime.fromtimestamp(
            r["start_ms"]/1000,
            tz=datetime.timezone(datetime.timedelta(hours=-7)))
        bin_s = r["bin"][:46]
        f = lambda v: f"{v:8.1f}" if v is not None else f"{'-':>8}"
        sched = (r["schedule"] or "")[:22]
        print(f"{i:>3}  {s.strftime('%m-%d %H:%M'):<14}  {bin_s:<46}  "
              f"{str(r['run_time_min']):>4}  {tag(r):<18}  "
              f"{f(r['plc_avg'])}  {f(r['plc_max'])}  "
              f"{f(r['fhv_avg'])}  {f(r['fhv_max'])}  {sched:<22}")

    # Summary by tag
    from collections import Counter
    by_tag = Counter(tag(r) for r in runs)
    print()
    print("Summary by classification:")
    for t, n in sorted(by_tag.items(), key=lambda kv: (-kv[1], kv[0])):
        print(f"  {n:>3}  {t}")

    # Summary by schedule
    by_sched = Counter((r["schedule"] or "(none)") for r in runs)
    print()
    print("Summary by schedule:")
    for s, n in sorted(by_sched.items(), key=lambda kv: (-kv[1], kv[0])):
        print(f"  {n:>3}  {s}")

if __name__ == "__main__":
    main()
