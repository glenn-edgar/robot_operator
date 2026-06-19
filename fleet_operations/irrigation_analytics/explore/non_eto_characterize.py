#!/usr/bin/env python3
# Characterize NON-ETO valve runs (Glenn 2026-06-10) — the short bins (city
# dwells, sat_1:17, flowers, landscape pulses) that the ETO 5-15 window doesn't
# fit. For each non-ETO STATION_START -> STEP_COMPLETE in the window, pulls the
# per-minute PLC (well) + Hunter (delivered) and reports:
#   - duration, which meter carries the flow (PLC well-fed vs Hunter city-fed)
#   - end-of-run mean (last 3 min) on BOTH meters  <- the end-of-step metric
#   - per-minute trace so we can see the shape (onset, steady, decay)
#
# This is the field characterization that has to precede a non-ETO end-of-step
# DETECTOR: it tells us the right signal per bin and a baseline end value.

import json, subprocess, sys, datetime

ETO = {("satellite_2", x) for x in (13, 14, 15, 16)} \
    | {("satellite_3", x) for x in (1, 2, 5, 13, 14, 15, 18)} \
    | {("satellite_4", x) for x in (1, 3, 4, 6, 7, 9, 10, 11, 12)}
END_WIN_MIN = 3

# Default window: since 6:00 PM yesterday PDT (matches the daily cadence).
START_PDT = datetime.datetime(2026, 6, 9, 18, 0, 0,
                              tzinfo=datetime.timezone(datetime.timedelta(hours=-7)))
if len(sys.argv) > 1:  # optional override: "YYYY-MM-DDTHH:MM" PDT
    START_PDT = datetime.datetime.fromisoformat(sys.argv[1]).replace(
        tzinfo=datetime.timezone(datetime.timedelta(hours=-7)))
START_MS = int(START_PDT.timestamp() * 1000)

PY_REMOTE = r"""
import redis, msgpack, json, sys
START_MS = %d
r = redis.Redis(db=4)
PA  = [k for k in r.scan_iter(match="*PAST_ACTIONS*")][0]
PLC = [k for k in r.scan_iter(match="*PLC_MEASUREMENTS_STREAM*")][0]
pa  = r.xrange(PA,  min="%%d-0" %% START_MS, max="+", count=10000)
plc = r.xrange(PLC, min="%%d-0" %% START_MS, max="+", count=40000)
def dec(ents):
    out = []
    for sid, f in ents:
        d = msgpack.unpackb(f[b"data"], raw=False)
        out.append({"sid_ms": int(sid.decode().split("-")[0]), **(d if isinstance(d, dict) else {})})
    return out
sys.stdout.write(json.dumps({"pa": dec(pa), "plc": dec(plc)}))
""" % START_MS


def run_remote():
    p = subprocess.run(["ssh", "pi@irrigation", "python3 -"],
                       input=PY_REMOTE, capture_output=True, text=True, timeout=60)
    if p.returncode != 0:
        print(p.stderr, file=sys.stderr); sys.exit(1)
    return json.loads(p.stdout)


def bin_of(det):
    vs = []
    for g in (det.get("io_setup") or []):
        rem = g.get("remote", "")
        for b in (g.get("bits") or []):
            vs.append((rem, int(b)))
    return vs


def mean(xs):
    xs = [x for x in xs if x is not None]
    return sum(xs) / len(xs) if xs else 0.0


def main():
    data = run_remote()
    pa, plc = data["pa"], sorted(data["plc"], key=lambda x: x["sid_ms"])
    opens, runs = {}, []
    for ev in pa:
        det = ev.get("details") or {}
        if not isinstance(det, dict):
            continue
        vs = bin_of(det)
        if not vs:
            continue
        key = "/".join(sorted(f"{r}:{b}" for r, b in vs))
        act = ev.get("action")
        if act == "IRRIGATION_STATION_START":
            opens[key] = (ev["sid_ms"], det)
        elif act == "IRRIGATION_STEP_COMPLETE":
            is_eto = any((r, b) in ETO for r, b in vs)
            if is_eto:
                opens.pop(key, None); continue
            # sat_1:39 SOLO is a delay/dwell (protocol), not an irrigation
            # event — don't track (Glenn 2026-06-10). Keep it when combined
            # with a real valve. Target non-ETO schedules: flowers/house/city_rose.
            if key == "satellite_1:39":
                continue
            o = opens.pop(key, None)
            start = o[0] if o else ev["sid_ms"] - (det.get("run_time", 0) or 0) * 60000
            runs.append({"bin": key, "start": start, "end": ev["sid_ms"],
                         "sched": det.get("schedule_name"), "rt": det.get("run_time")})

    print(f"\nNON-ETO characterization since {START_PDT.strftime('%Y-%m-%d %H:%M %Z')}  "
          f"({len(runs)} non-ETO runs)\n")
    hdr = (f"{'start':<14} {'bin':<34} {'min':>4} {'sched':<16} "
           f"{'PLC_mean':>8} {'PLC_end':>7} {'HUN_mean':>8} {'HUN_end':>7}  carries")
    print(hdr); print("-" * len(hdr))
    for run in sorted(runs, key=lambda r: r["start"]):
        w = [p for p in plc if run["start"] <= p["sid_ms"] <= run["end"]]
        end_cut = run["end"] - END_WIN_MIN * 60000
        we = [p for p in w if p["sid_ms"] >= end_cut]
        plc_mean = mean([p.get("main_flow_meter") for p in w])
        hun_mean = mean([p.get("FILTERED_HUNTER_VALVE") for p in w])
        plc_end = mean([p.get("main_flow_meter") for p in we])
        hun_end = mean([p.get("FILTERED_HUNTER_VALVE") for p in we])
        carries = "PLC(well)" if plc_mean > hun_mean + 1 else \
                  ("HUNTER(city/zone)" if hun_mean > plc_mean + 0.5 else "both~equal")
        s = datetime.datetime.fromtimestamp(run["start"]/1000,
                tz=datetime.timezone(datetime.timedelta(hours=-7)))
        print(f"{s.strftime('%m-%d %H:%M'):<14} {run['bin'][:34]:<34} "
              f"{str(run['rt']):>4} {str(run['sched'])[:16]:<16} "
              f"{plc_mean:>8.1f} {plc_end:>7.1f} {hun_mean:>8.1f} {hun_end:>7.1f}  {carries}")


if __name__ == "__main__":
    main()
