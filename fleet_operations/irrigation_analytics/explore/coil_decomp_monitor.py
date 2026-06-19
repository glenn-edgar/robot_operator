#!/usr/bin/env python3
"""coil_decomp_monitor.py — cycle-grouped per-coil current monitor (read-time).

The real solenoid-health test (Glenn 2026-06-12): TIME_HISTORY during-run current,
offset-immune. IRRIGATION_CURRENT is a SUM = master(1:43, implicit) + the co-energized
coils in the bin. Each run is a linear equation  hold = I_master + Σ I_coil. Solving a
whole CYCLE's runs at once gives every coil's true operating current, offset removed.

Per-position ("last run of each bin") decomposition FAILS because bins don't fire in
lockstep — mixing cycles makes the system inconsistent (master blows up, coils go
negative). The fix is here: group runs into actual cycles by timestamp, decompose each
COMPLETE cycle, QC-reject ill-conditioned ones (which is itself an anomalous-cycle
flag), and trend each coil across the clean cycles.

Input: TSV of  ts_ms<TAB>bin_key<TAB>hold_amps<TAB>step<TAB>schedule  (kb4.db coil_onset).
A CYCLE boundary is a schedule change OR a step reset (step <= previous step) —
time-gaps don't work because irrigation runs near-continuously. Falls back to a
time-gap if step/schedule are absent (old rows).
This is MONITOR-ONLY analysis — reads recorded data, actuates nothing.
"""
import sys, datetime

CYCLE_GAP_MS = 3 * 3600 * 1000   # fallback only (rows with no step/schedule)
MIN_RUNS     = 6                 # a cycle needs at least this many runs to solve
# QC bounds for a trustworthy decomposition
MASTER_LO, MASTER_HI = 0.30, 0.70
MAX_RMS              = 0.15
MIN_COIL             = -0.06     # connected coils shouldn't solve materially negative


def pt(ms):
    return (datetime.datetime.utcfromtimestamp(ms/1000) -
            datetime.timedelta(hours=7)).strftime('%m-%d %H:%M')


def solve(eqs):
    """Weighted least-squares: hold = master + Σ coil. Normal equations + Gaussian
    elimination (mirrors server/application_gateway/lib/coil_solve.lua)."""
    idx = {}
    for members, _b, _w in eqs:
        for v in members:
            if v not in idx:
                idx[v] = len(idx)
    n = len(idx)
    N = n + 1                       # + master column (last)
    ATA = [[0.0]*N for _ in range(N)]
    ATb = [0.0]*N
    for members, b, w in eqs:
        cols = [idx[v] for v in members] + [n]   # master always present
        for i in cols:
            ATb[i] += w*b
            for j in cols:
                ATA[i][j] += w
    # Gaussian elimination with partial pivoting
    M = [row[:] + [ATb[i]] for i, row in enumerate(ATA)]
    for c in range(N):
        p = max(range(c, N), key=lambda r: abs(M[r][c]))
        if abs(M[p][c]) < 1e-12:
            return None, None, False
        M[c], M[p] = M[p], M[c]
        piv = M[c][c]
        for r in range(N):
            if r != c and M[r][c] != 0:
                f = M[r][c]/piv
                for k in range(c, N+1):
                    M[r][k] -= f*M[c][k]
    x = [M[i][N]/M[i][i] for i in range(N)]
    master = x[n]
    coil = {v: x[i] for v, i in idx.items()}
    # rms residual
    ss = 0.0; tot = 0.0
    for members, b, w in eqs:
        pred = master + sum(coil[v] for v in members)
        ss += w*(b-pred)**2; tot += w
    rms = (ss/tot)**0.5 if tot else 0.0
    return master, coil, rms, True


def main(path):
    rows = []
    for ln in open(path):
        p = ln.rstrip('\n').split('\t')
        if len(p) < 3:
            continue
        try:
            ts = int(p[0]); hold = float(p[2])
        except ValueError:
            continue
        step = None
        if len(p) >= 4 and p[3] not in ('', 'nil'):
            try: step = int(p[3])
            except ValueError: pass
        sched = p[4] if len(p) >= 5 else None
        bin_key = p[1]
        members = [v.replace('satellite_', '') for v in bin_key.split('/')]
        rows.append((ts, members, hold, step, sched))
    rows.sort(key=lambda r: r[0])
    if not rows:
        print("no data"); return

    # group into cycles: boundary = schedule change OR step reset (step<=prev).
    # fall back to a time-gap for rows lacking step/schedule (old backfill).
    cycles = []; cur = []
    prev_ts = prev_step = prev_sched = None
    for ts, members, hold, step, sched in rows:
        boundary = False
        if step is not None and sched is not None:
            if prev_step is None or sched != prev_sched or step <= prev_step:
                boundary = True
        elif prev_ts is not None and ts - prev_ts > CYCLE_GAP_MS:
            boundary = True
        if boundary and cur:
            cycles.append(cur); cur = []
        cur.append((ts, members, hold)); prev_ts = ts; prev_step = step; prev_sched = sched
    if cur:
        cycles.append(cur)

    # decompose each cycle, QC
    results = []   # (start_ts, ok, master, coil, rms, nruns, reason)
    for cyc in cycles:
        if len(cyc) < MIN_RUNS:
            results.append((cyc[0][0], False, None, None, None, len(cyc), "too few runs"))
            continue
        eqs = [(m, h, 1.0) for _ts, m, h in cyc]
        out = solve(eqs)
        if not out or not out[-1]:
            results.append((cyc[0][0], False, None, None, None, len(cyc), "singular"))
            continue
        master, coil, rms, _ = out
        reason = []
        if not (MASTER_LO <= master <= MASTER_HI): reason.append(f"master={master:.2f}")
        if rms > MAX_RMS: reason.append(f"rms={rms:.2f}")
        neg = [v for v, i in coil.items() if i < MIN_COIL]
        if neg: reason.append(f"neg:{','.join(neg[:3])}")
        ok = not reason
        results.append((cyc[0][0], ok, master, coil, rms, len(cyc), "; ".join(reason)))

    # report: cycle QC table
    print("=== cycle QC ===")
    for start, ok, master, coil, rms, nr, reason in results:
        tag = "OK " if ok else "REJECT"
        print(f"  {pt(start)} PT  n={nr:2d}  {tag}  " +
              (f"master={master:.3f} rms={rms:.3f}" if master else "") +
              (f"  ({reason})" if reason else ""))

    clean = [r for r in results if r[1]]
    if not clean:
        print("\nno clean cycles yet — trend builds as cycles accumulate")
        return

    # per-coil trend across clean cycles (oldest->newest)
    allcoils = set()
    for _s, _ok, _m, coil, _r, _n, _x in clean:
        allcoils.update(coil)
    print(f"\n=== per-coil current (A) across {len(clean)} clean cycle(s), oldest->newest ===")
    hdr = "coil".ljust(9) + "".join(pt(r[0]).split()[0].rjust(7) for r in clean) + "   trend"
    print(hdr)
    print("MASTER".ljust(9) + "".join(f"{r[2]:7.3f}" for r in clean))
    def newest_current(v):
        for r in reversed(clean):
            if v in r[3]: return r[3][v]
        return 0
    for v in sorted(allcoils, key=lambda v: -newest_current(v)):
        cur = [r[3].get(v) for r in clean]
        first = next((c for c in cur if c is not None), None)
        last = next((c for c in reversed(cur) if c is not None), None)
        trend = (last-first) if (first is not None and last is not None) else 0
        cells = "".join((f"{c:7.3f}" if c is not None else "   -  ") for c in cur)
        flag = ""
        if last is not None and last < 0.10: flag = " dead/open"
        elif abs(trend) > 0.08: flag = f" {'↑' if trend>0 else '↓'}TREND"
        print(f"{v:9}{cells}   {trend:+6.3f}{flag}")


if __name__ == "__main__":
    main(sys.argv[1] if len(sys.argv) > 1 else "var/coil_onset_holds.tsv")
