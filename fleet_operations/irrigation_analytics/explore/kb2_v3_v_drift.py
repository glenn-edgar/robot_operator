#!/usr/bin/env python3
"""
KB2 v3 — V-drift calibration.

Glenn 2026-06-01 confirmed field-meter values for all anchors:
  1:17 = 44 Ω, 1:43 = 33 Ω, 1:44 = 21.5 Ω, 2:13–17 = 43 Ω each

Linear gain+offset model (v2) cannot reconcile these — per-valve ratios
of measured/expected diverge too much. The actually-consistent model:

  - Chain: gain = 1.0 (unity), offset = median(null_anchors) per cycle
  - Each valve: R_total = R_coil + R_wire (wire R is constant, stable)
  - V_supply VARIES per cycle (the real "chain drift")

Calibration each cycle:
  1. offset = median of (3:1, 4:6) latest readings
  2. V_est = 44 * (I_1:17 - offset)        # assumes 1:17 wire ≈ 0
  3. R_total[v] = V_est / (I_v - offset)   # for every valve

This makes the ANCHOR sanity check simpler — measured R for 1:43 and 1:44
should be (R_nominal + small wire R) and STABLE cycle-to-cycle if model holds.
"""

import json
import glob
import statistics

V_NOMINAL = 15.7  # for reference only — actual V is estimated per cycle
NULL_ANCHORS = ('satellite_3:1', 'satellite_4:6')
R_REF_ANCHOR = ('satellite_1:17', 44.0)  # primary V-estimation anchor (low wire R)
KNOWN_COIL_R = {
    'satellite_1:17': 44.0,
    'satellite_1:43': 33.0,
    'satellite_1:44': 21.5,
    # All other named: 43 Ω each (unless 1:44-style parallel)
}
DEFAULT_COIL_R = 43.0  # all valves except master and parallel-pair


def latest_nonnull(readings, threshold=0.15):
    for r in reversed(readings or []):
        if r is not None and r >= threshold:
            return r
    return None


def calibrate(d):
    """Per-cycle calibration. Returns (offset, V_est, per_valve_R, diagnostics)."""
    # 1. Offset = median of null readings
    null_vals = []
    for v in NULL_ANCHORS:
        last = d.get(v, [None])[-1]
        if last is not None and last < 0.15:  # nulls are always < 0.15
            null_vals.append(last)
    if len(null_vals) < 1:
        return None, None, {}, {'error': 'no nulls'}
    offset = statistics.median(null_vals)

    # 2. V_est from 1:17
    ref_valve, ref_r = R_REF_ANCHOR
    i_ref = latest_nonnull(d.get(ref_valve, []))
    if i_ref is None:
        return None, None, {}, {'error': 'no 1:17 reading'}
    V_est = ref_r * (i_ref - offset)

    # 3. R_total per valve
    valves_r = {}
    for v, readings in d.items():
        i = latest_nonnull(readings)
        if i is None or i <= offset:
            continue
        valves_r[v] = V_est / (i - offset)

    return offset, V_est, valves_r, {'n_nulls': len(null_vals), 'i_ref': i_ref}


def main():
    paths = sorted(glob.glob('snapshots/*/valve_test.json'))
    # Skip disconnect-event snapshots
    good = []
    for p in paths:
        d = json.load(open(p))
        last17 = d.get('satellite_1:17', [None])[-1]
        if last17 is not None and last17 >= 0.15:
            good.append(p)
    print(f'analyzing {len(good)} snapshots\n')

    cycles = []
    results = []
    for p in good:
        d = json.load(open(p))
        cycle = p.split('/')[-2]
        offset, V_est, valves_r, diag = calibrate(d)
        if offset is None:
            print(f'{cycle}: SKIP ({diag.get("error")})')
            continue
        cycles.append(cycle)
        results.append({'cycle': cycle, 'offset': offset, 'V_est': V_est,
                        'valves_r': valves_r})

    # ===== Cycle-by-cycle calibration table =====
    print('=' * 78)
    print('Per-cycle calibration')
    print('=' * 78)
    print(f'{"cycle":<22} {"offset":>7} {"V_est":>7} '
          f'  {"1:17 R":>7} {"1:43 R":>7} {"1:44 R":>7}'
          f' {"2:13 R":>7} {"2:14 R":>7} {"2:17 R":>7}')
    for r in results:
        vr = r['valves_r']
        print(f'{r["cycle"]:<22} {r["offset"]:>7.3f} {r["V_est"]:>7.2f}'
              f'   {vr.get("satellite_1:17", 0):>7.2f}'
              f' {vr.get("satellite_1:43", 0):>7.2f}'
              f' {vr.get("satellite_1:44", 0):>7.2f}'
              f' {vr.get("satellite_2:13", 0):>7.2f}'
              f' {vr.get("satellite_2:14", 0):>7.2f}'
              f' {vr.get("satellite_2:17", 0):>7.2f}')

    # ===== Anchor consistency =====
    print()
    print('=' * 78)
    print('Anchor consistency — these should be ROUGHLY CONSTANT cycle-to-cycle')
    print('  measured R = coil + wire ; wire is fixed physical cable resistance')
    print('=' * 78)
    for vv, r_nom in [('satellite_1:17', 44), ('satellite_1:43', 33),
                      ('satellite_1:44', 21.5)]:
        rs = [r['valves_r'].get(vv) for r in results
              if r['valves_r'].get(vv) is not None]
        if not rs: continue
        wire = [x - r_nom for x in rs]
        print(f'  {vv} (coil={r_nom}): R_total {min(rs):.1f}-{max(rs):.1f} '
              f'median={statistics.median(rs):.2f}  '
              f'wire_R {min(wire):+.1f} to {max(wire):+.1f} '
              f'median={statistics.median(wire):+.2f}')
    # 2:13-17 — should be coil=43 + long wire run
    for vv in ['satellite_2:13', 'satellite_2:14', 'satellite_2:15',
               'satellite_2:16', 'satellite_2:17']:
        rs = [r['valves_r'].get(vv) for r in results
              if r['valves_r'].get(vv) is not None]
        if not rs: continue
        wire = [x - 43 for x in rs]
        print(f'  {vv} (coil=43):   R_total {min(rs):.1f}-{max(rs):.1f} '
              f'median={statistics.median(rs):.2f}  '
              f'wire_R {min(wire):+.1f} to {max(wire):+.1f} '
              f'median={statistics.median(wire):+.2f}')

    # ===== Per-valve R stability — should be stable if model holds =====
    print()
    print('=' * 78)
    print('Per-valve R (calibrated) — STABILITY indicates model is right')
    print('  CV (sd/median) < 5% → very stable, > 15% → model drift or aging')
    print('=' * 78)
    all_valves = sorted({v for r in results for v in r['valves_r']})
    rows = []
    for v in all_valves:
        rs = [r['valves_r'].get(v) for r in results
              if r['valves_r'].get(v) is not None]
        if len(rs) < 3 or not all(5 < x < 300 for x in rs):
            continue
        med = statistics.median(rs)
        sd = statistics.stdev(rs)
        cv = sd / med * 100
        first3 = statistics.median(rs[:3])
        last3 = statistics.median(rs[-3:])
        trend = last3 - first3
        rows.append((v, med, sd, cv, trend))

    rows.sort(key=lambda x: x[0])
    print(f'{"valve":<18} {"R_med":>7} {"sd":>5} {"CV%":>5} '
          f'{"trend(last-first)":>18}')
    for v, med, sd, cv, trend in rows:
        flag = '  <-- DRIFT' if abs(trend) > 4 else ('  <-- HIGH CV' if cv > 10 else '')
        print(f'{v:<18} {med:>7.2f} {sd:>5.2f} {cv:>5.1f} {trend:>+18.2f}{flag}')


if __name__ == '__main__':
    main()
