#!/usr/bin/env python3
# Regenerate data/kb4_nonETO_baselines.json with CORRECT flow_med using the
# exact runtime metric (compute_flow_window: median-filter-3 then mean of
# samples 2..min(15,#)). The old seed had flow_med~0.2 + phantom (computed
# before we knew HUNTER_FLOW_METER.data is the right raw signal), which
# phantom-skipped every non-ETO valve. Glenn 2026-06-10.
import json, statistics as st, sys
TH = sys.argv[1] if len(sys.argv)>1 else "snapshots/2026-06-09/time_history.json"
ETO = {("satellite_2",x) for x in (13,14,15,16)} \
    | {("satellite_3",x) for x in (1,2,5,13,14,15,18)} \
    | {("satellite_4",x) for x in (1,3,4,6,7,9,10,11,12)}
def parse(k):
    out=[]
    for p in k.split("/"):
        if ":" in p:
            r,b=p.rsplit(":",1); out.append((r,int(b)))
    return out
def med3(xs):
    out=[]
    for i in range(len(xs)):
        s=sorted(xs[max(0,i-1):min(len(xs),i+2)])
        out.append(s[(len(s)-1)//2])
    return out
def flow_window(series):   # non-ETO = LAST VALUE of the run (Glenn 2026-06-10)
    s=[v for v in series if v is not None]
    if not s: return None
    return s[-1]
th=json.load(open(TH))
out={}
rows=[]
for k,runs in th.items():
    vs=parse(k)
    if not vs or any(v in ETO for v in vs): continue
    if k=="satellite_1:39": continue
    flows=[flow_window((r.get("HUNTER_FLOW_METER") or {}).get("data",[])) for r in runs]
    flows=[f for f in flows if f is not None and f>0.3]
    if len(flows)<3: continue
    currs=[(r.get("IRRIGATION_CURRENT") or {}).get("mean") for r in runs[-15:]]
    currs=[c for c in currs if c]
    recent=flows[-15:]
    fmed=round(st.median(recent),3)
    fmad=round(st.median([abs(f-fmed) for f in recent]),3)
    out[k]={"flow_med":fmed,"flow_mad":fmad,
            "curr_med":round(st.median(currs),3) if currs else 0.0,
            "leak_threshold":round(fmed+5.0,3),
            "warn_up":round(fmed+3.0,3),"warn_down":round(fmed-3.0,3),
            "n_all":len(runs),"n_kept":len(flows),"phantom":False}
    rows.append((k,fmed,fmad,len(flows)))
json.dump(out, open("../data/kb4_nonETO_baselines.json","w"), indent=2)
print(f"wrote {len(out)} non-ETO baselines -> data/kb4_nonETO_baselines.json (phantom=false)")
print(f"flow_med range: {min(r[1] for r in rows):.1f} .. {max(r[1] for r in rows):.1f} GPM")
print("sample (flowers/city_rose):")
for k,f,m,n in rows:
    if any(t in k for t in ("4:2","3:4","2:17","3:19","1:29")) and "/" not in k:
        print(f"  {k:<22} flow_med={f}  mad={m}  n={n}")
