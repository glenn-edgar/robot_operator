#!/usr/bin/env python3
# Per-minute trace of a single run window.
# Usage: ./inspect_run.py "2026-06-08 20:57" [duration_min]

import sys, subprocess, json, datetime

if len(sys.argv) < 2:
    print("usage: inspect_run.py 'YYYY-MM-DD HH:MM' [duration_min]"); sys.exit(1)

PDT = datetime.timezone(datetime.timedelta(hours=-7))
start_dt = datetime.datetime.strptime(sys.argv[1], "%Y-%m-%d %H:%M").replace(tzinfo=PDT)
duration = int(sys.argv[2]) if len(sys.argv) > 2 else 90
start_ms = int(start_dt.timestamp() * 1000)
end_ms = start_ms + duration * 60_000

PY = r"""
import redis, msgpack, json, sys
START_MS = %d; END_MS = %d
r = redis.Redis(db=4)
PA = [k for k in r.scan_iter(match="*PAST_ACTIONS*")][0]
PLC = [k for k in r.scan_iter(match="*PLC_MEASUREMENTS_STREAM*")][0]
pa = r.xrange(PA, min=f"{START_MS}-0", max=f"{END_MS}-0", count=2000)
plc = r.xrange(PLC, min=f"{START_MS}-0", max=f"{END_MS}-0", count=2000)
def dec(ents):
    out=[]
    for sid,fields in ents:
        d=msgpack.unpackb(fields[b"data"],raw=False)
        out.append({"sid_ms":int(sid.decode().split("-")[0]),**d})
    return out
sys.stdout.write(json.dumps({"pa":dec(pa),"plc":dec(plc)}))
""" % (start_ms, end_ms)

p = subprocess.run(["ssh","pi@irrigation","python3 -"],input=PY,capture_output=True,text=True,timeout=60)
if p.returncode != 0:
    print(p.stderr); sys.exit(1)
data = json.loads(p.stdout)
pa, plc = data["pa"], sorted(data["plc"], key=lambda x: x["sid_ms"])

print(f"\nRUN INSPECTION  starting {start_dt.strftime('%Y-%m-%d %H:%M PDT')}  window {duration} min\n")
print("Past actions in window:")
for ev in pa:
    s = datetime.datetime.fromtimestamp(ev["sid_ms"]/1000, tz=PDT)
    det = ev.get("details", {})
    bk = ""
    if isinstance(det, dict):
        vs=[]
        for grp in det.get("io_setup") or []:
            for bit in grp.get("bits") or []:
                vs.append(f"{grp.get('remote')}:{bit}")
        bk = "/".join(sorted(vs))
    print(f"  {s.strftime('%H:%M:%S')}  {ev.get('action')}  bin={bk}  "
          f"sched={det.get('schedule_name') if isinstance(det,dict) else ''}  "
          f"step={det.get('step') if isinstance(det,dict) else ''}  "
          f"rt={det.get('run_time') if isinstance(det,dict) else ''}")

print()
print(f"PLC samples ({len(plc)}):")
print(f"  {'time':<10}  {'min':>3}  {'PLC':>6}  {'FHV':>6}  {'HHI':>6}  "
      f"{'delta':>7}  {'IRR_I':>6}  {'EQ_I':>6}")
print("  " + "-" * 70)
t0 = plc[0]["sid_ms"] if plc else start_ms
for p_ in plc:
    s = datetime.datetime.fromtimestamp(p_["sid_ms"]/1000, tz=PDT)
    minute = (p_["sid_ms"] - t0) // 60_000
    plc_v = p_.get("main_flow_meter")
    fhv = p_.get("FILTERED_HUNTER_VALVE")
    hhi = p_.get("HUNTER_HIRES_VALVE")
    delta = (fhv - plc_v) if (fhv is not None and plc_v is not None) else None
    irr = p_.get("plc_irrigation_1")
    eq  = p_.get("plc_slave_1")
    def f(v, w=6, d=1):
        return f"{v:{w}.{d}f}" if isinstance(v,(int,float)) else f"{'-':>{w}}"
    print(f"  {s.strftime('%H:%M:%S')}  {minute:>3}  "
          f"{f(plc_v)}  {f(fhv)}  {f(hhi)}  "
          f"{f(delta, 7, 1) if delta is not None else f'{chr(45):>7}'}  "
          f"{f(irr,6,2)}  {f(eq,6,2)}")
