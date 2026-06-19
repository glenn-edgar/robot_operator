#!/usr/bin/env python3
# Replay KB4_v2 against past runs (mirror of the Lua algorithm).
# Validates: per-bin baseline building, leak detection at +2 GPM,
# separate baselines for city bins.

import json, subprocess, sys, datetime
from collections import defaultdict
from statistics import median

ETO_PINS = {
    "satellite_2:13","satellite_2:14","satellite_2:15","satellite_2:16",
    "satellite_3:1","satellite_3:13","satellite_3:14","satellite_3:15",
    "satellite_3:18","satellite_3:2","satellite_3:5","satellite_4:1",
    "satellite_4:10","satellite_4:11","satellite_4:12","satellite_4:3",
    "satellite_4:4","satellite_4:6","satellite_4:7","satellite_4:9",
}
CITY_VALVE = "satellite_1:39"

WINDOW_START_MIN = 5
WINDOW_END_MIN   = 15
MIN_RUN_DURATION = 16
NON_ETO_END_WIN  = 3
ROLLING_N        = 7
LEAK_DELTA_GPM   = 2.0

START_PDT = datetime.datetime(2026, 6, 8, 18, 0, 0,
                              tzinfo=datetime.timezone(datetime.timedelta(hours=-7)))
START_MS = int(START_PDT.timestamp() * 1000)

PY = r"""
import redis, msgpack, json, sys
START_MS = %d
r = redis.Redis(db=4)
PA  = [k for k in r.scan_iter(match="*PAST_ACTIONS*")][0]
PLC = [k for k in r.scan_iter(match="*PLC_MEASUREMENTS_STREAM*")][0]
pa = r.xrange(PA, min=f"{START_MS}-0", max="+", count=10000)
plc = r.xrange(PLC, min=f"{START_MS}-0", max="+", count=20000)
def dec(es):
    out=[]
    for sid,fields in es:
        d=msgpack.unpackb(fields[b"data"],raw=False)
        out.append({"sid_ms":int(sid.decode().split("-")[0]),**d})
    return out
sys.stdout.write(json.dumps({"pa":dec(pa),"plc":dec(plc)}))
""" % START_MS

def fetch():
    p = subprocess.run(["ssh","pi@irrigation","python3 -"], input=PY,
                       capture_output=True, text=True, timeout=60)
    if p.returncode: sys.exit(p.stderr)
    return json.loads(p.stdout)

def bin_key_of(d):
    if not isinstance(d,dict): return None,[]
    vs=[]
    for g in d.get("io_setup",[]) or []:
        for b in g.get("bits",[]) or []:
            vs.append(f"{g.get('remote')}:{b}")
    return "/".join(sorted(vs)), vs

def compute_window_stats(plc_samples, start_ms, end_ms):
    run_min = (end_ms - start_ms) / 60000.0
    if run_min < MIN_RUN_DURATION:
        return None, f"run too short ({run_min:.1f} min)"
    win_start = start_ms + WINDOW_START_MIN * 60000
    win_end   = start_ms + WINDOW_END_MIN * 60000
    end_start = end_ms - NON_ETO_END_WIN * 60000
    win = [s for s in plc_samples if win_start <= s["sid_ms"] <= win_end and s.get("main_flow_meter") is not None]
    end = [s for s in plc_samples if end_start <= s["sid_ms"] <= end_ms and s.get("main_flow_meter") is not None]
    if not win:
        return None, "no PLC samples in 5-15 window"
    win_flow = sum(s["main_flow_meter"] for s in win) / len(win)
    win_gallons = 0
    for i, s in enumerate(win):
        if i < len(win)-1:
            dt = win[i+1]["sid_ms"] - s["sid_ms"]
        else:
            dt = min(60000, win_end - s["sid_ms"])
        win_gallons += s["main_flow_meter"] * (dt/1000) / 60.0
    end_flow = sum(s["main_flow_meter"] for s in end)/len(end) if end else None
    return {"win_flow":win_flow,"win_gallons":win_gallons,
            "end_flow":end_flow,"n":len(win)}, None

def classify(is_eto, stats, baseline):
    if not stats: return "skip", None, None
    if not is_eto: return "non_eto_collected", None, "no threshold yet"
    if not baseline: return "first_run", None, "seeding"
    delta = stats["win_flow"] - baseline["base_flow"]
    if delta > LEAK_DELTA_GPM:
        return "LEAK_ALERT", delta, f"win {stats['win_flow']:.1f} > base {baseline['base_flow']:.1f} + {LEAK_DELTA_GPM}"
    return "OK", delta, None

def main():
    data = fetch()
    pa, plc = data["pa"], sorted(data["plc"], key=lambda x: x["sid_ms"])

    opens = {}
    runs = []
    for ev in pa:
        act = ev.get("action")
        det = ev.get("details", {}) or {}
        if not isinstance(det, dict): continue
        bk, vs = bin_key_of(det)
        if not bk: continue
        if act == "IRRIGATION_STATION_START":
            opens[bk] = ev["sid_ms"]
        elif act == "IRRIGATION_STEP_COMPLETE":
            start_ms = opens.pop(bk, None) or (ev["sid_ms"] - (det.get("run_time") or 0) * 60_000)
            runs.append({
                "bin": bk, "valves": vs,
                "is_eto": any(v in ETO_PINS for v in vs),
                "is_city": CITY_VALVE in vs,
                "start_ms": start_ms, "end_ms": ev["sid_ms"],
                "run_time_min": det.get("run_time"),
                "schedule": det.get("schedule_name"),
                "step": det.get("step"),
            })

    runs.sort(key=lambda r: r["start_ms"])

    print(f"\nKB4_v2 REPLAY  threshold=+{LEAK_DELTA_GPM} GPM, window={WINDOW_START_MIN}-{WINDOW_END_MIN} min, "
          f"rolling={ROLLING_N}  since {START_PDT.strftime('%Y-%m-%d %H:%M %Z')}\n")

    # Per-bin baseline state (mimics kb4v2.lua)
    baselines = {}  # bin -> {ring_flow, ring_gal, ring_end, base_flow, base_gal, base_end, n_clean}

    hdr = f"{'#':>3}  {'start':<14}  {'bin':<46}  {'min':>4}  {'tag':<12}  {'win_flow':>9}  {'win_gal':>8}  {'base_flow':>9}  {'delta':>7}  {'cls':<18}"
    print(hdr); print("-" * len(hdr))

    for i, run in enumerate(runs, 1):
        s_pdt = datetime.datetime.fromtimestamp(
            run["start_ms"]/1000,
            tz=datetime.timezone(datetime.timedelta(hours=-7)))
        win = [p for p in plc if run["start_ms"] <= p["sid_ms"] <= run["end_ms"]]
        stats, err = compute_window_stats(win, run["start_ms"], run["end_ms"])

        if not stats:
            tag = "skip"
            print(f"{i:>3}  {s_pdt.strftime('%m-%d %H:%M'):<14}  {run['bin'][:46]:<46}  "
                  f"{str(run['run_time_min']):>4}  {tag:<12}  {'-':>9}  {'-':>8}  "
                  f"{'-':>9}  {'-':>7}  {'(skip)':<18} {err}")
            continue

        baseline = baselines.get(run["bin"])
        cls, delta, note = classify(run["is_eto"], stats, baseline)

        if cls != "LEAK_ALERT":
            b = baselines.setdefault(run["bin"], {"ring_flow":[],"ring_gal":[],"ring_end":[],"n_clean":0})
            b["ring_flow"].append(stats["win_flow"])
            b["ring_gal"].append(stats["win_gallons"])
            if stats["end_flow"]: b["ring_end"].append(stats["end_flow"])
            for k in ("ring_flow","ring_gal","ring_end"):
                while len(b[k]) > ROLLING_N: b[k].pop(0)
            b["base_flow"] = median(b["ring_flow"])
            b["base_gal"]  = median(b["ring_gal"])
            if b["ring_end"]: b["base_end"] = median(b["ring_end"])
            b["n_clean"]   = b["n_clean"] + 1

        tag = ("ETO/city" if run["is_city"] else "ETO") if run["is_eto"] else "non-ETO"
        base_flow_str = f"{baseline['base_flow']:9.1f}" if baseline else f"{'-':>9}"
        delta_str = f"{delta:+7.1f}" if delta is not None else f"{'-':>7}"
        print(f"{i:>3}  {s_pdt.strftime('%m-%d %H:%M'):<14}  {run['bin'][:46]:<46}  "
              f"{str(run['run_time_min']):>4}  {tag:<12}  "
              f"{stats['win_flow']:9.1f}  {stats['win_gallons']:8.0f}  "
              f"{base_flow_str}  {delta_str}  {cls:<18}")

    print()
    print(f"FINAL BASELINES ({len(baselines)} bins)\n")
    hdr = f"{'bin':<46}  {'n_clean':>7}  {'base_flow':>9}  {'base_gal':>8}  {'base_end':>8}"
    print(hdr); print("-" * len(hdr))
    for bk in sorted(baselines):
        b = baselines[bk]
        be = f"{b.get('base_end',0):8.1f}" if b.get("base_end") else f"{'-':>8}"
        print(f"{bk:<46}  {b['n_clean']:>7}  {b.get('base_flow',0):9.1f}  {b.get('base_gal',0):8.0f}  {be}")

if __name__ == "__main__":
    main()
