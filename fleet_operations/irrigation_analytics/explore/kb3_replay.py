#!/usr/bin/env python3
# Replay the new KB3 algorithm against past ETO runs.
#
# Sensor strategy (Glenn 2026-06-09 PM):
#   - trip = PLC main_flow_meter > 15 GPM × 3 consecutive minutes (after 5-min warmup)
#   - on city bins (sat_1:39 in io_setup): also report city_delta = FHV - PLC
#
# Source data: PLC_MEASUREMENTS_STREAM samples (1/min) within each run window.
# Window per run derived from STATION_START + STEP_COMPLETE past_actions events.

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

GPM_THRESHOLD       = 15.0
WARMUP_MINUTES      = 5
CONSECUTIVE_REQUIRED = 3

# Start: 2026-06-08 18:00 PDT == 2026-06-09 01:00 UTC
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
def decode_ents(ents):
    out = []
    for sid, fields in ents:
        d = msgpack.unpackb(fields[b"data"], raw=False)
        out.append({"sid_ms": int(sid.decode().split("-")[0]), **d})
    return out
sys.stdout.write(json.dumps({"pa": decode_ents(pa), "plc": decode_ents(plc)}))
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

def replay_run(run, plc_window):
    """Simulate the KB3 evaluate_step algorithm minute by minute."""
    consecutive = 0
    fired = False
    fire_minute = None
    fire_plc = None
    fire_hunter = None
    timeline = []

    # Each PLC sample = one "minute" tick (controller's ELASPED_TIME)
    for minute, p in enumerate(plc_window):
        plc    = p.get("main_flow_meter")
        hunter = p.get("FILTERED_HUNTER_VALVE")
        is_warmup = minute < WARMUP_MINUTES
        city_delta = (hunter - plc) if (plc is not None and hunter is not None) else None

        if is_warmup:
            consecutive = 0
            action = "warmup"
        elif fired:
            action = "fired_already"
        else:
            trip = (plc or 0) > GPM_THRESHOLD
            if trip:
                consecutive += 1
            else:
                consecutive = 0
            if consecutive >= CONSECUTIVE_REQUIRED:
                fired = True
                fire_minute = minute
                fire_plc = plc
                fire_hunter = hunter
                action = "FIRE"
            else:
                action = "checked"

        timeline.append({
            "minute": minute, "plc": plc, "hunter": hunter,
            "city_delta": city_delta, "action": action,
            "consecutive": consecutive,
        })

    return {
        "fired": fired,
        "fire_minute": fire_minute,
        "fire_plc": fire_plc,
        "fire_hunter": fire_hunter,
        "n_minutes": len(plc_window),
        "timeline": timeline,
    }

def main():
    data = run_remote()
    pa, plc = data["pa"], data["plc"]
    plc_sorted = sorted(plc, key=lambda x: x["sid_ms"])

    # Pair STATION_START -> STEP_COMPLETE per bin
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
            is_eto = any(v in ETO_PINS for v in vs)
            if not is_eto: continue
            start_ms = opens.pop(bk, None) or (ev["sid_ms"] - (det.get("run_time", 0) or 0) * 60_000)
            is_city = CITY_VALVE in vs
            runs.append({
                "bin": bk, "valves": vs, "is_city": is_city,
                "start_ms": start_ms, "end_ms": ev["sid_ms"],
                "run_time_min": det.get("run_time"),
                "schedule": det.get("schedule_name"),
                "step": det.get("step"),
            })

    # PLC window per run
    def window(s, e):
        return [p for p in plc_sorted if s <= p["sid_ms"] <= e]

    print(f"\nKB3 REPLAY  (threshold={GPM_THRESHOLD} GPM, warmup={WARMUP_MINUTES} min, "
          f"consec={CONSECUTIVE_REQUIRED}) since {START_PDT.strftime('%Y-%m-%d %H:%M %Z')}\n")

    results = []
    for run in sorted(runs, key=lambda r: r["start_ms"]):
        w = window(run["start_ms"], run["end_ms"])
        sim = replay_run(run, w)
        sim["bin"] = run["bin"]
        sim["is_city"] = run["is_city"]
        sim["start_ms"] = run["start_ms"]
        sim["run_time_min"] = run["run_time_min"]
        sim["schedule"] = run["schedule"]
        results.append(sim)

    # Top-level table
    hdr = f"{'start':<14}  {'bin':<46}  {'min':>4}  {'city?':<6}  {'PLC>15 min':<14}  {'verdict':<10}  {'when':<12}"
    print(hdr); print("-" * len(hdr))
    for r in results:
        s = datetime.datetime.fromtimestamp(
            r["start_ms"]/1000,
            tz=datetime.timezone(datetime.timedelta(hours=-7)))
        bin_s = r["bin"][:46]
        # Count minutes where PLC > threshold (post warmup)
        over_min = [t for t in r["timeline"]
                    if t["minute"] >= WARMUP_MINUTES and t["plc"] is not None and t["plc"] > GPM_THRESHOLD]
        # Longest streak of consecutive over-threshold (post warmup)
        max_streak = 0; cur = 0
        for t in r["timeline"]:
            if t["minute"] < WARMUP_MINUTES: continue
            if t["plc"] is not None and t["plc"] > GPM_THRESHOLD:
                cur += 1
                if cur > max_streak: max_streak = cur
            else:
                cur = 0
        verdict = "FIRE" if r["fired"] else "ok"
        when = f"min {r['fire_minute']}" if r["fired"] else ""
        plc_summary = f"{len(over_min)} of {r['n_minutes']-WARMUP_MINUTES} (run≤{max_streak})"
        print(f"{s.strftime('%m-%d %H:%M'):<14}  {bin_s:<46}  {str(r['run_time_min']):>4}  "
              f"{('city' if r['is_city'] else 'no'):<6}  {plc_summary:<14}  {verdict:<10}  {when:<12}")

    # Per-FIRE detail
    print()
    fires = [r for r in results if r["fired"]]
    print(f"FIRES: {len(fires)} run(s) would have tripped KB3\n")
    for r in fires:
        s = datetime.datetime.fromtimestamp(
            r["start_ms"]/1000,
            tz=datetime.timezone(datetime.timedelta(hours=-7)))
        print(f"  {r['bin']} starting {s.strftime('%m-%d %H:%M')} — FIRE at minute {r['fire_minute']}")
        print(f"    PLC at fire: {r['fire_plc']:.1f} GPM   FHV: {r['fire_hunter']:.1f} GPM")
        # show window minutes 0..fire+2
        end = min(r['fire_minute'] + 3, len(r['timeline']))
        for t in r['timeline'][:end]:
            cd = f"  cd={t['city_delta']:+.1f}" if r["is_city"] and t["city_delta"] is not None else ""
            plc_s = f"{t['plc']:.1f}" if t['plc'] is not None else "—"
            fhv_s = f"{t['hunter']:.1f}" if t['hunter'] is not None else "—"
            print(f"     min {t['minute']:>2}  PLC={plc_s:>5}  FHV={fhv_s:>5}  cons={t['consecutive']}  {t['action']}{cd}")
        print()

    # City-bin diagnostic — show city_delta over the run
    city_runs = [r for r in results if r["is_city"]]
    if city_runs:
        print(f"CITY BIN DIAGNOSTIC: city_delta = FHV - PLC (positive ⇒ city water flowing)\n")
        for r in city_runs:
            s = datetime.datetime.fromtimestamp(
                r["start_ms"]/1000,
                tz=datetime.timezone(datetime.timedelta(hours=-7)))
            deltas = [t["city_delta"] for t in r["timeline"] if t["city_delta"] is not None]
            if not deltas: continue
            mean = sum(deltas)/len(deltas)
            mx = max(deltas)
            mn = min(deltas)
            pos = sum(1 for d in deltas if d > 1.0)
            print(f"  {r['bin']} starting {s.strftime('%m-%d %H:%M')}")
            print(f"    city_delta:  mean={mean:+.1f}  min={mn:+.1f}  max={mx:+.1f}  "
                  f"({pos}/{len(deltas)} min with delta > +1.0 GPM)")

if __name__ == "__main__":
    main()
