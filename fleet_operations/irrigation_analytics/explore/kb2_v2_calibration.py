#!/usr/bin/env python3
"""
KB2 v2 calibration analyzer.

New approach per 2026-06-01 design dialog:
  - Per-cycle calibration of ACS712 chain (gain + offset)
  - Anchors:
      offset (zero current):  sat_3:1 + sat_4:6 (open lines, no valves)
      gain (known R):         sat_1:17 (44 Ω), sat_1:43 (33 Ω), sat_1:44 (21.5 Ω)
                              all three close to control station, minimal wire R
  - Sanity-check anchors against each other; drop a bad one before fit.
  - Apply calibration: I_true = (I_measured - offset) / gain
  - Compute per-valve R = V / I_true   with V = 15.7
  - Wire R is constant per valve; coil aging shows as drift over cycles.

Run across the ~10 most-recent VALVE_TEST snapshots.
"""

import json
import os
import glob
import statistics
from collections import defaultdict

V_SUPPLY = 15.7

# Anchor truth.
GAIN_ANCHORS = {
    'satellite_1:17': 44.0,
    'satellite_1:43': 33.0,
    'satellite_1:44': 21.5,   # two parallel 43 Ω coils
}
NULL_ANCHORS = ('satellite_3:1', 'satellite_4:6')

# Threshold for detecting a "disconnect / null event" reading on an anchor.
# Null lines read ~0.09 A; healthy anchor reads 0.36-0.73 A; gap is wide.
NULL_EVENT_THRESHOLD_A = 0.15


def get_latest_nonnull(readings, threshold=None):
    """Return the most-recent reading; if threshold given and last is below
    threshold, walk backward to find the last value above threshold."""
    if not readings:
        return None
    if threshold is None:
        return readings[-1]
    for v in reversed(readings):
        if v is None:
            continue
        if v >= threshold:
            return v
    return readings[-1]


def fit_calibration(anchor_readings):
    """Fit I_measured = a + b * I_true given a dict of {valve: (R_nominal, I_meas)}.

    Returns (offset_a, gain_b, residuals_per_anchor).
    Uses ordinary least-squares.
    """
    pts = []
    for valve, (r_nom, i_meas) in anchor_readings.items():
        i_true = V_SUPPLY / r_nom if r_nom > 0 else 0.0
        pts.append((i_true, i_meas, valve))

    n = len(pts)
    if n < 2:
        return None, None, {}

    sx = sum(p[0] for p in pts)
    sy = sum(p[1] for p in pts)
    sxx = sum(p[0] * p[0] for p in pts)
    sxy = sum(p[0] * p[1] for p in pts)
    denom = n * sxx - sx * sx
    if abs(denom) < 1e-12:
        return None, None, {}
    b = (n * sxy - sx * sy) / denom
    a = (sy - b * sx) / n

    residuals = {}
    for x, y, valve in pts:
        y_pred = a + b * x
        residuals[valve] = y - y_pred

    return a, b, residuals


def analyze_snapshot(path):
    """Analyze one VALVE_TEST snapshot. Returns dict with per-valve R + diagnostics."""
    d = json.load(open(path))
    cycle = path.split('/')[-2]

    # Step 1: extract latest nonnull reading per anchor.
    null_readings = {}
    for v in NULL_ANCHORS:
        if v in d:
            # Nulls are ALWAYS ~0.09; just take the latest.
            null_readings[v] = d[v][-1] if d[v] else None

    gain_readings = {}
    for v in GAIN_ANCHORS:
        if v in d:
            gain_readings[v] = get_latest_nonnull(d[v], NULL_EVENT_THRESHOLD_A)

    # Step 2: provisional offset from nulls.
    null_vals = [v for v in null_readings.values() if v is not None]
    if len(null_vals) < 2:
        return {'cycle': cycle, 'error': 'no null anchors'}
    offset_provisional = statistics.median(null_vals)

    # Step 3: anchor sanity check — fit using all 3 gain anchors + provisional
    # offset, look at residuals. Anchor with worst residual gets dropped.
    healthy_anchors = dict(gain_readings)
    dropped = []

    anchor_input = {v: (GAIN_ANCHORS[v], healthy_anchors[v])
                    for v in healthy_anchors if healthy_anchors[v] is not None}

    a_fit, b_fit, residuals = fit_calibration(anchor_input)

    # If we have all 3, check residuals. Drop worst-residual anchor if its
    # absolute residual exceeds 0.02 A (≈ 2.4 Ω at the 44 Ω point).
    if a_fit is not None and len(residuals) >= 3:
        worst = max(residuals.items(), key=lambda kv: abs(kv[1]))
        if abs(worst[1]) > 0.02:
            dropped.append((worst[0], worst[1]))
            del anchor_input[worst[0]]
            a_fit, b_fit, residuals = fit_calibration(anchor_input)

    if a_fit is None or b_fit is None or b_fit <= 0:
        return {'cycle': cycle, 'error': 'fit failed', 'gain_readings': gain_readings,
                'offset_provisional': offset_provisional}

    # Step 4: apply calibration to every valve.
    valves_r = {}
    for valve, readings in d.items():
        if not readings:
            continue
        # Use latest nonnull (skip disconnect events) for cross-snapshot trend.
        i_meas = get_latest_nonnull(readings, NULL_EVENT_THRESHOLD_A)
        if i_meas is None:
            continue
        i_true = (i_meas - a_fit) / b_fit
        if i_true <= 0:
            valves_r[valve] = None
            continue
        r = V_SUPPLY / i_true
        valves_r[valve] = r

    # Step 5: verify nominal anchors come out close to nominal post-calibration.
    anchor_check = {}
    for v, r_nom in GAIN_ANCHORS.items():
        r_measured = valves_r.get(v)
        if r_measured is not None:
            anchor_check[v] = {'nominal': r_nom, 'measured': r_measured,
                               'delta': r_measured - r_nom}

    return {
        'cycle': cycle,
        'offset_a': a_fit,
        'gain_b': b_fit,
        'null_provisional': offset_provisional,
        'dropped_anchors': dropped,
        'anchor_check': anchor_check,
        'valves_r': valves_r,
    }


def main():
    snaps = sorted(glob.glob('snapshots/*/valve_test.json'))

    # Filter to the "good" snapshots — drop the 5/28 scan1-4 disconnect events.
    # Detection: any cycle where all 3 gain anchors' last reading is < 0.15.
    good_snaps = []
    for p in snaps:
        d = json.load(open(p))
        all_null = True
        for v in GAIN_ANCHORS:
            last = d.get(v, [None])[-1]
            if last is not None and last >= NULL_EVENT_THRESHOLD_A:
                all_null = False
                break
        if not all_null:
            good_snaps.append(p)
        else:
            print(f"SKIP {p.split('/')[-2]} — all-anchor null event")

    print(f"\nAnalyzing {len(good_snaps)} good snapshots\n")

    results = [analyze_snapshot(p) for p in good_snaps]

    # ===== Calibration table =====
    print("=" * 78)
    print("PER-CYCLE CALIBRATION FIT (offset_a, gain_b) + anchor consistency")
    print("=" * 78)
    print(f"{'cycle':<22} {'offset':>8} {'gain':>7}   "
          f"{'1:17 R':>8} {'1:43 R':>8} {'1:44 R':>8}  dropped")
    for r in results:
        if 'error' in r:
            print(f"{r['cycle']:<22}  ERROR: {r['error']}")
            continue
        ac = r['anchor_check']
        r17 = ac.get('satellite_1:17', {}).get('measured', float('nan'))
        r43 = ac.get('satellite_1:43', {}).get('measured', float('nan'))
        r44 = ac.get('satellite_1:44', {}).get('measured', float('nan'))
        drop = ','.join(f"{v.split(':')[-1]}({d:+.3f})"
                        for v, d in r['dropped_anchors']) or '-'
        print(f"{r['cycle']:<22} {r['offset_a']:>8.4f} {r['gain_b']:>7.4f}   "
              f"{r17:>8.2f} {r43:>8.2f} {r44:>8.2f}  {drop}")

    # ===== Per-valve R across cycles =====
    print()
    print("=" * 78)
    print("PER-VALVE R ACROSS CYCLES (calibrated)")
    print("=" * 78)

    all_valves = sorted({v for r in results if 'valves_r' in r
                         for v in r['valves_r']})
    cycles = [r['cycle'] for r in results if 'valves_r' in r]

    # Wide table — print short column heads.
    short_cycles = [c.replace('2026-', '').replace('_scan', 's') for c in cycles]
    head = f"{'valve':<18}  " + ' '.join(f"{c:>7}" for c in short_cycles) + \
           f"  {'median':>7} {'sd':>6} {'trend':>7}"
    print(head)

    summary_rows = []
    for v in all_valves:
        rs = []
        for r in results:
            if 'valves_r' not in r:
                continue
            rs.append(r['valves_r'].get(v))
        if not any(x is not None for x in rs):
            continue
        valid = [x for x in rs if x is not None and 5 < x < 200]
        if not valid:
            continue
        med = statistics.median(valid)
        sd = statistics.stdev(valid) if len(valid) >= 2 else 0.0
        trend = valid[-1] - valid[0] if len(valid) >= 2 else 0.0
        summary_rows.append((v, med, sd, trend, rs))

    # Print by satellite group, with anchor + null rows tagged.
    def tag(v):
        if v in GAIN_ANCHORS: return '*GAIN'
        if v in NULL_ANCHORS: return '*NULL'
        return ''

    for v, med, sd, trend, rs in summary_rows:
        cells = ' '.join(f"{x:>7.2f}" if x is not None else f"{'  -':>7}"
                         for x in rs)
        line = f"{v + ' ' + tag(v):<18}  {cells}  " \
               f"{med:>7.2f} {sd:>6.2f} {trend:>+7.2f}"
        print(line)

    # ===== Changes — valves whose R drifted most =====
    print()
    print("=" * 78)
    print("VALVES WITH LARGEST R CHANGE (last cycle vs first cycle)")
    print("=" * 78)
    deltas = []
    for v, med, sd, trend, rs in summary_rows:
        valid = [x for x in rs if x is not None and 5 < x < 200]
        if len(valid) < 4:
            continue
        first = statistics.median(valid[:3])
        last = statistics.median(valid[-3:])
        deltas.append((v, first, last, last - first, sd))
    deltas.sort(key=lambda x: -abs(x[3]))
    print(f"{'valve':<18} {'first_R':>8} {'last_R':>8} {'delta':>8} {'sd':>6}")
    for v, first, last, delta, sd in deltas[:15]:
        print(f"{v:<18} {first:>8.2f} {last:>8.2f} {delta:>+8.2f} {sd:>6.2f}")


if __name__ == '__main__':
    main()
