#!/usr/bin/env python3
# Backfill the coil_onset / coil_onset_baseline tables from a TIME_HISTORY
# snapshot so the dashboard "Coil onset" page is populated immediately, rather
# than waiting days for every valve to re-run. Logic mirrors lib/coil_onset.lua
# exactly. Emits self-contained SQL (schema + rows) to stdout or a file.
#
# Synthesized ts_ms are well in the past and monotonic per valve, so real
# live runs (now) always sort as newer and push these out of the 12-run window.
import json, sys, statistics as st

ACTIVE_A, RAMP_MIN_A = 0.10, 0.40
SPIKE_MIN_DELTA, SPIKE_STRONG, SPIKE_SEVERE = 0.05, 0.15, 0.30
MIN_ACTIVE_N, BASELINE_WIN = 8, 12
BASE_MS, STEP_MS = 1_748_000_000_000, 3_600_000   # ~2025-05-23, +1h per run

def group_of(hold, delta):
    # spike group only (within-run; co-energized additions cancel)
    if delta is None: return None
    if delta >= SPIKE_SEVERE: return "SPIKE_SEVERE"
    if delta >= SPIKE_STRONG: return "SPIKE_STRONG"
    if delta >= SPIKE_MIN_DELTA: return "SPIKE_MILD"
    return "FLAT"

def extract(curr):
    a = [float(x or 0) for x in (curr or [])]
    i, j = 0, len(a) - 1
    while i < len(a) and a[i] < ACTIVE_A: i += 1
    while j >= i and a[j] < ACTIVE_A: j -= 1
    n = j - i + 1
    if n < MIN_ACTIVE_N: return None
    act = a[i:j+1]
    first = act[0]
    if first < RAMP_MIN_A and len(act) > 1: first = act[1]
    start = max(2, n // 3)              # 0-based; matches Lua max(3, floor(n/3))
    hold = st.median(act[start:])
    if hold < 0.05: return None
    delta = first - hold
    return dict(first=first, hold=hold, delta=delta,
                ratio=first/hold, n=n, group=group_of(hold, delta))

def q(s): return "'" + str(s).replace("'", "''") + "'"

def main():
    snap = sys.argv[1] if len(sys.argv) > 1 else "snapshots/2026-06-09/time_history.json"
    d = json.load(open(snap))
    out = []
    out.append("BEGIN;")
    out.append("""CREATE TABLE IF NOT EXISTS coil_onset (
  id INTEGER PRIMARY KEY AUTOINCREMENT, ts_ms INTEGER NOT NULL, sid TEXT,
  valve TEXT NOT NULL, n_active INTEGER, first_a REAL, hold_a REAL,
  spike_delta REAL, spike_ratio REAL, sig_group TEXT, UNIQUE(sid, valve));""")
    out.append("CREATE INDEX IF NOT EXISTS idx_coil_onset_valve ON coil_onset(valve, ts_ms);")
    out.append("""CREATE TABLE IF NOT EXISTS coil_onset_baseline (
  valve TEXT PRIMARY KEY, n INTEGER DEFAULT 0, first_med REAL, hold_med REAL,
  spike_delta_med REAL, sig_group TEXT, last_ms INTEGER);""")

    nrun = nval = 0
    grp_count = {}
    for valve, runs in d.items():
        sigs = []
        for idx, rec in enumerate(runs):
            ic = (rec.get("IRRIGATION_CURRENT") or {}).get("data") or []
            sig = extract(ic)
            if not sig: continue
            ts = BASE_MS + idx * STEP_MS
            sid = f"backfill:{valve}:{idx}"
            out.append("INSERT OR IGNORE INTO coil_onset "
                "(ts_ms,sid,valve,n_active,first_a,hold_a,spike_delta,spike_ratio,sig_group) "
                f"VALUES ({ts},{q(sid)},{q(valve)},{sig['n']},{sig['first']:.4f},"
                f"{sig['hold']:.4f},{sig['delta']:.4f},{sig['ratio']:.4f},{q(sig['group'])});")
            sigs.append((ts, sig)); nrun += 1
        if not sigs: continue
        win = sigs[-BASELINE_WIN:]
        fm = st.median([s['first'] for _, s in win])
        hm = st.median([s['hold']  for _, s in win])
        dm = st.median([s['delta'] for _, s in win])
        grp = group_of(hm, dm)
        last_ms = win[-1][0]
        out.append("INSERT INTO coil_onset_baseline "
            "(valve,n,first_med,hold_med,spike_delta_med,sig_group,last_ms) "
            f"VALUES ({q(valve)},{len(win)},{fm:.4f},{hm:.4f},{dm:.4f},{q(grp)},{last_ms}) "
            "ON CONFLICT(valve) DO UPDATE SET n=excluded.n,first_med=excluded.first_med,"
            "hold_med=excluded.hold_med,spike_delta_med=excluded.spike_delta_med,"
            "sig_group=excluded.sig_group,last_ms=excluded.last_ms;")
        nval += 1
        if "/" not in valve:
            grp_count[grp] = grp_count.get(grp, 0) + 1
    out.append("COMMIT;")

    dest = None
    for a in sys.argv[2:]:
        if a.startswith("--out="): dest = a.split("=", 1)[1]
    sql = "\n".join(out) + "\n"
    if dest:
        open(dest, "w").write(sql)
        sys.stderr.write(f"wrote {dest}\n")
    else:
        sys.stdout.write(sql)
    sys.stderr.write(f"valves={nval} runs={nrun}  single-valve groups: "
                     + ", ".join(f"{k}={v}" for k, v in sorted(grp_count.items())) + "\n")

if __name__ == "__main__":
    main()
