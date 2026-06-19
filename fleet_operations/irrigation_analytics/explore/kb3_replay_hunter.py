#!/usr/bin/env python3
# KB3 leak model on the FILTERED_HUNTER_VALVE (smooth Hunter) — the GPM curve.
#
# Model split (Glenn 2026-06-10):
#   - LEAK  -> KB3 -> filtered Hunter, GPM curve (this script)
#   - BLOCK -> KB4 -> PLC well meter, gallons curve (separate)
# Hunter measures water actually delivered to irrigation; it never sees the
# house draw that pollutes the PLC well meter, so no house correction is
# needed on the leak path. No PLC median filtering (a glitchy PLC = a valve
# to fix on the Thursday maintenance run, not something to smooth over).
#
# Trip: Hunter > THRESHOLD for CONSECUTIVE_REQUIRED minutes after WARMUP.
# This sweep reports the verdict at several thresholds and shows the
# per-run post-warmup max for BOTH meters so we can pick the Hunter
# threshold against the known sat_3:5 leak (2026-06-09 04:32) ground truth.

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

WARMUP_MINUTES       = 5
CONSECUTIVE_REQUIRED = 3
THRESHOLDS           = [13.0, 14.0, 15.0]   # Hunter-GPM sweep

# Valid test window: 6:00 PM last Monday (2026-06-08) PDT — contains the
# known sat_3:5 leak plus the clean overnight ETO runs.
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


def trip_on(window, signal_key, threshold):
    """Return (fired, fire_minute, fire_val, max_streak) for one signal."""
    consecutive = 0; fired = False; fire_minute = None; fire_val = None
    max_streak = 0; cur = 0
    for minute, p in enumerate(window):
        if minute < WARMUP_MINUTES:
            consecutive = 0
            continue
        v = p.get(signal_key)
        if v is not None and v > threshold:
            cur += 1; max_streak = max(max_streak, cur)
            if not fired:
                consecutive += 1
                if consecutive >= CONSECUTIVE_REQUIRED:
                    fired = True; fire_minute = minute; fire_val = v
        else:
            cur = 0; consecutive = 0
    return fired, fire_minute, fire_val, max_streak


def post_warmup_max(window, key):
    vals = [p.get(key) for i, p in enumerate(window)
            if i >= WARMUP_MINUTES and p.get(key) is not None]
    return max(vals) if vals else None


def main():
    data = run_remote()
    pa, plc = data["pa"], data["plc"]
    plc_sorted = sorted(plc, key=lambda x: x["sid_ms"])

    opens = {}; runs = []
    for ev in pa:
        act = ev.get("action"); det = ev.get("details", {}) or {}
        if not isinstance(det, dict): continue
        bk, vs = bin_key_of(det)
        if not bk: continue
        if act == "IRRIGATION_STATION_START":
            opens[bk] = ev["sid_ms"]
        elif act == "IRRIGATION_STEP_COMPLETE":
            if not any(v in ETO_PINS for v in vs): continue
            start_ms = opens.pop(bk, None) or (ev["sid_ms"] - (det.get("run_time", 0) or 0) * 60_000)
            runs.append({"bin": bk, "valves": vs, "is_city": CITY_VALVE in vs,
                         "start_ms": start_ms, "end_ms": ev["sid_ms"],
                         "run_time_min": det.get("run_time")})

    def window(s, e):
        return [p for p in plc_sorted if s <= p["sid_ms"] <= e]

    print(f"\nKB3 HUNTER LEAK MODEL  (warmup={WARMUP_MINUTES} min, consec={CONSECUTIVE_REQUIRED}, "
          f"signal=FILTERED_HUNTER_VALVE)  since {START_PDT.strftime('%Y-%m-%d %H:%M %Z')}")
    print(f"Threshold sweep: {THRESHOLDS}  (PLC shown for comparison only)\n")

    thr_cols = "  ".join(f"H>{int(t)}" for t in THRESHOLDS)
    hdr = (f"{'start':<14}  {'bin':<42}  {'min':>4}  {'plcMax':>7}  {'hunMax':>7}   {thr_cols}")
    print(hdr); print("-" * len(hdr))

    fire_counts = {t: [] for t in THRESHOLDS}
    for run in sorted(runs, key=lambda r: r["start_ms"]):
        w = window(run["start_ms"], run["end_ms"])
        s = datetime.datetime.fromtimestamp(
            run["start_ms"]/1000, tz=datetime.timezone(datetime.timedelta(hours=-7)))
        pmax = post_warmup_max(w, "main_flow_meter")
        hmax = post_warmup_max(w, "FILTERED_HUNTER_VALVE")
        cells = []
        for t in THRESHOLDS:
            fired, fmin, fval, streak = trip_on(w, "FILTERED_HUNTER_VALVE", t)
            if fired:
                cells.append(f"FIRE@{fmin}")
                fire_counts[t].append((run["bin"], s.strftime('%m-%d %H:%M'), fmin, fval))
            else:
                cells.append(f"ok({streak})")
        flag = "  <== sat_3:5" if "satellite_3:5" in run["valves"] else ""
        print(f"{s.strftime('%m-%d %H:%M'):<14}  {run['bin'][:42]:<42}  "
              f"{str(run['run_time_min']):>4}  "
              f"{(f'{pmax:.1f}' if pmax is not None else '-'):>7}  "
              f"{(f'{hmax:.1f}' if hmax is not None else '-'):>7}   "
              f"{'  '.join(f'{c:<8}' for c in cells)}{flag}")

    print("\nFIRE SUMMARY by Hunter threshold:")
    for t in THRESHOLDS:
        fs = fire_counts[t]
        print(f"  H>{int(t)} GPM: {len(fs)} fire(s)")
        for bin_s, when, fmin, fval in fs:
            print(f"      {when}  {bin_s}  min {fmin}  ({fval:.1f} GPM)")


if __name__ == "__main__":
    main()
