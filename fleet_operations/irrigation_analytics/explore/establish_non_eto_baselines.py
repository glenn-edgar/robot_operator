#!/usr/bin/env python3
# Establish per-valve NON-ETO end-of-step baselines from TIME_HISTORY (Glenn
# 2026-06-10). Uses the RAW HUNTER_FLOW_METER.data arrays (the FHV-smoothed
# stream + the TH 'mean' field read 0 on these short low-flow runs). End-of-step
# = mean of the last 3 raw samples with the minute-1 onset dropped. Baseline =
# median over the bin's recent runs. Excludes ETO valves and the sat_1:39 solo
# delay. Writes data/non_eto_baselines.json.
import json, statistics as st, sys
TH = sys.argv[1] if len(sys.argv) > 1 else "snapshots/2026-06-09/time_history.json"
ETO = {("satellite_2", x) for x in (13,14,15,16)} \
    | {("satellite_3", x) for x in (1,2,5,13,14,15,18)} \
    | {("satellite_4", x) for x in (1,3,4,6,7,9,10,11,12)}
def parse(k):
    vs=[]
    for p in k.split("/"):
        if ":" in p:
            r,b=p.rsplit(":",1); vs.append((r,int(b)))
    return vs
def end_of_step(data):
    d=[v for v in data if v is not None]
    if len(d) < 2: return None
    body=d[1:]
    tail=body[-3:]
    return sum(tail)/len(tail)
th=json.load(open(TH))
out={}
rows=[]
for k,runs in th.items():
    vs=parse(k)
    if not vs: continue
    if any(v in ETO for v in vs): continue       # ETO handled by KB3/KB4
    if k == "satellite_1:39": continue            # solo delay — don't track
    eos=[end_of_step((r.get("HUNTER_FLOW_METER") or {}).get("data",[])) for r in runs]
    eos=[e for e in eos if e is not None and e>0.3]
    if len(eos) < 3: continue                      # need a few real runs
    recent=eos[-15:]                               # last ~15 runs
    base=round(st.median(recent),2)
    mad=round(st.median([abs(e-base) for e in recent]),2)
    out[k]={"base_end_hunter_gpm":base,"mad":mad,"n_runs":len(eos)}
    rows.append((k,base,mad,len(eos)))
json.dump(out, open("../data/non_eto_baselines.json","w"), indent=2)
rows.sort(key=lambda r:-r[1])
print(f"established {len(out)} non-ETO baselines -> data/non_eto_baselines.json\n")
print(f"{'bin':<40}{'base_end_HUN':>13}{'mad':>7}{'n':>5}")
print("-"*65)
for k,b,m,n in rows: print(f"{k:<40}{b:>13}{m:>7}{n:>5}")
