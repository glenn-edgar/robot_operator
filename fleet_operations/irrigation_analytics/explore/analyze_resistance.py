#!/usr/bin/env python3
"""
KB2-daily resistance analyzer — standalone explore.

Reads:
  data/valve_test.json    — {"satellite_X:pin": [I_A, ...×20]} for 49 valves
  data/valve_groups.json  — 10 sun-exposure groups for sat_1/2/3

Pipeline:
  1. ACS712 per-cycle offset from disconnect-outlier valves (median of latest I)
  2. R_raw = V_supply / (I_latest − offset);  V_supply = 15.5 V
  3. Wire constants: sat_2:13..17 subtract 7 Ω;  sat_1:44 multiply R by 2 (parallel)
  4. Cohort assignment: sat_1/2/3 from JSON + operator's sun-map;
                        sat_4 1..8 shade / 9..16 sun
  5. Cohort z-score on R_corrected
  6. Mann-Kendall trend on each valve's 20-element series (raw I, monotone same as R)
  7. Classification: DEAD / DISCONNECTED / INOPERABLE / PRE_SHORT / AGING_OPEN /
                     IMPENDING_OPEN / STABLE / UNKNOWN_COHORT
  8. Tabular report to stdout
"""

import argparse
import datetime as DT
import json
import math
import statistics
import subprocess
import sys
from pathlib import Path

V_SUPPLY = 15.5
# NONEXISTENT — phantom pins. No wire/valve at all on site. Controller still
# scans them and returns a null measure. SIX CURRENT-NULL ANCHORS confirmed
# by operator 2026-05-27 — the I they report each day is
# (ACS712_OFFSET + system_noise_floor), so the median across them is the
# daily drift indicator. Reliable, identical-by-physics. Filtered out
# before classification — they have no semantic status.
NONEXISTENT = {"satellite_1:1", "satellite_1:28", "satellite_1:38",
               "satellite_1:40", "satellite_3:1", "satellite_4:6"}
DISCONNECTS = set()  # no real disconnected valves on this site
# CALIBRATION (2026-05-26 anchored to physical measurements):
#   New-install solenoid: 43 Ω
#   Anchor A: sat_2:4 physical = 35 Ω (no wire) → ACS712 offset = 0.0133 A
#   Anchor B: sat_2:13..17 physical = 42 Ω (with trunk wire) → wire = 10.07 Ω median
# Disconnect valves are NOT zero-current — they are ~200 Ω high-impedance leakage
# paths that pass ~0.077 A. Use them for daily-drift detection only, not as offset.
ACS712_OFFSET = 0.0133
# Phantom-pin offset normalization (backlog item 1 from daily-review-workflow).
# The fixed ACS712_OFFSET above was anchored once to sat_2:4 = 35 Ω; the actual
# null drifts cycle-to-cycle and adds ±2-3 Ω systematic bias to every valve
# when comparing across days. The 6 NONEXISTENT phantom pins measure
#   I_phantom = LEAKAGE_THROUGH_200OHM + ACS712_NULL ≈ 0.0775 + null
# so their per-ordinal median is the cleanest within-buffer drift indicator.
# REF_PHANTOM = phantom median at the calibration anchor point (0.0775 leakage
# + 0.0133 null = 0.0908). Per-ord effective offset is
#   ACS712_OFFSET + (phantom_at_ord − REF_PHANTOM)
# which centres the rolling MK series on the calibration anchor and removes
# drift. Applied in BOTH the rolling series (MK basis) and today's reading.
REF_PHANTOM = 0.0908
WIRE_OFFSET_OHMS = {**{f"satellite_2:{p}": 10.0 for p in (13, 14, 15, 16, 17)},
                    **{f"satellite_3:{p}":  3.0 for p in (11, 12, 13, 14, 15, 16, 17, 18)}}
PARALLEL_PAIRS = {"satellite_1:44"}  # apparent R × 2 = per-coil R

# Wire/cohort families for residual-MK trend test. All five members of a wire
# family share a common trunk path, so they share environmental drift (supply
# voltage shifts, terminal corrosion at trunk end, temperature). Running MK on
# raw R against a noisy shared baseline produces spurious individual flags
# (sat_2:13/14 flagged 2026-05-27 — false positives, see family table in
# session log). Solution: MK on the residual = R - family_median_per_ord.
WIRE_FAMILIES = {
    "sat_2_13_17": {"satellite_2:13", "satellite_2:14", "satellite_2:15",
                    "satellite_2:16", "satellite_2:17"},
    "sat_3_11_18": {"satellite_3:11", "satellite_3:12", "satellite_3:13",
                    "satellite_3:14", "satellite_3:15", "satellite_3:16",
                    "satellite_3:17", "satellite_3:18"},
}
# Valves outside wire families fall back to sun/shade cohort as the reference
# group; if cohort is "unknown" the test falls back to raw R MK.
MASTER_DEAD = set()  # sat_1:38 removed (no longer exists on site, 2026-05-27)
# Heavier-duty solenoids with legitimately lower R — bigger coils.
# Empirical: sat_1:43 R = 33–37 Ω across both old and replacement coils.
# Heavy-master new-install spec ≈ 35 Ω, NOT the standard 43 Ω. Replacement
# events in heavy-master coils are invisible at R level — they live in the
# same 33-37 Ω band before and after. Skip absolute thresholds; only trend
# matters, and even trend is dominated by noise on this small range.
MASTER_HEAVY = {"satellite_1:43"}    # working master, larger valve w/ filtering
# Operator-confirmed replacement events:
#   satellite_1:43 — MECHANICAL replacement (sand in valve body), 2026-05-14 or 21.
#     Coil was NOT swapped → R unchanged → not visible to our detector (correct).
#   satellite_2:4  — SOLENOID replacement, 2026-05-27. Will jump from ~35Ω to
#     new-install band (≥40Ω) in tomorrow's R-scan; detector primed to fire.

# operator sun-map (group index 1-based per his enumeration):
SUN_MAP = {1: "sun", 2: "sun", 3: "shade", 4: "sun", 5: "sun",
           6: "sun", 7: "sun", 8: "sun", 9: "shade", 10: "shade"}

R_NEW_SPEC    = 43.0   # new-install solenoid baseline
R_INOPERABLE  = 34.0   # ≈ cohort μ − 3σ; below this = physically inoperable
R_IMPENDING   = 47.0   # ≈ cohort μ + 5σ; above this = trending open
TREND_P_THRESHOLD = 0.10  # loose for baseline characterization
# Minimum |R movement| over the trend window to call an AGING_OPEN / PRE_SHORT.
# ACS712 noise + drive-voltage variation + phantom-offset residual together
# floor at ~±1.5–2Ω per reading. Field DMM with finger-bridging adds another
# ±1Ω. So anything under ~3Ω of movement is in the noise band — confirmed
# 2026-06-01 against Glenn's bench measurements (sat_2:3 at 43Ω stable,
# sat_3:11 fine, sat_2:7 at 44Ω = +1Ω above baseline = noise). Tighten if
# field experience shows we miss real failures; relax if it lets noise in.
R_TREND_MIN_DELTA = 3.0

# "Today's reading" averaging window. The controller runs the resistance
# check 1-2× per day; both go into the rolling-20 IRRIGATION_VALVE_TEST
# history. Using only series[-1] (the very last cycle) inherits one cycle's
# sensor null noise. Averaging the most recent N cycles cuts that within-day
# noise — same valve, two reads within hours, the ACS712 null drift between
# them is small. Set to 1 to revert to series[-1]-only behavior.
RECENT_N = 2


def recent_median(series, n=RECENT_N):
    """Median of the last min(n, len(series)) entries. Robust to single
    outliers; for n=2 it's just the mean. Series is the rolling-20 list
    of latest currents from IRRIGATION_VALVE_TEST."""
    if not series or not isinstance(series, list):
        return None
    tail = [x for x in series[-n:] if x is not None]
    if not tail:
        return None
    return statistics.median(tail)


def phantom_offsets(valve_test: dict, n: int) -> list[float]:
    """Per-ordinal effective offset, length n. Median across the 6 phantom
    pins per ordinal, recentered on REF_PHANTOM and added to ACS712_OFFSET.
    Falls back to ACS712_OFFSET when an ordinal has no phantom samples."""
    out: list[float] = []
    for k in range(n):
        vals = [valve_test[v][k] for v in NONEXISTENT
                if valve_test.get(v) and len(valve_test[v]) > k
                and valve_test[v][k] is not None]
        if vals:
            out.append(ACS712_OFFSET + (statistics.median(vals) - REF_PHANTOM))
        else:
            out.append(ACS712_OFFSET)
    return out


def load() -> tuple[dict, list]:
    here = Path(__file__).parent
    valve_test = json.loads((here / "data" / "valve_test.json").read_text())
    valve_groups = json.loads((here / "data" / "valve_groups.json").read_text())
    return valve_test, valve_groups


def fetch_fresh(timeout_s: int = 20) -> None:
    """Run fetch_data.sh to pull fresh valve_test + valve_groups from the Pi.
    Used by the robot before --json analysis so each KB2 run gets current data.
    """
    here = Path(__file__).parent
    script = here / "fetch_data.sh"
    if not script.exists():
        raise RuntimeError(f"fetch_data.sh not found at {script}")
    p = subprocess.run(["bash", str(script)],
                       capture_output=True, timeout=timeout_s, cwd=str(here))
    if p.returncode != 0:
        raise RuntimeError("fetch_data failed: " + p.stderr.decode()[:200])


def build_cohorts(valve_groups: list) -> dict[str, str]:
    cohort: dict[str, str] = {}
    for idx, g in enumerate(valve_groups, start=1):
        sun = SUN_MAP.get(idx, "unknown")
        for io in g.get("io", []):
            ctl = io.get("controller", "")
            pin = io.get("pin")
            if pin is None: continue
            cohort[f"{ctl}:{pin}"] = sun
    # sat_4 cohort: PREVIOUS naive 1..8 shade / 9..16 sun rule was WRONG per
    # operator (2026-05-27). Actual physical adjacency groups (incomplete):
    #   Group A: 4:9, 4:10, 4:11, 4:12     (same group)
    #   Group B: 4:7, 4:3                  (physically adjacent)
    #   Group C: 4:8, 4:4                  (physically adjacent)
    # Until full adjacency map + per-group sun exposure are known, leave sat_4
    # valves at "unknown" cohort so they get STABLE_UNK_COHORT classification
    # instead of false z-score outliers from a wrong cohort assignment.
    for p in range(1, 17):
        key = f"satellite_4:{p}"
        if key not in cohort:
            cohort[key] = "unknown"
    return cohort


def drift_from_phantoms(valve_test: dict) -> float:
    """Return median of latest phantom-pin (NONEXISTENT) I values — clean
    null anchors. This is the daily DRIFT INDICATOR (sensor-null + system
    noise floor). Not the calibration offset — for that see ACS712_OFFSET
    which is physically anchored to sat_2:4 = 35 Ω.
    """
    latest = []
    for v in NONEXISTENT:
        series = valve_test.get(v)
        m = recent_median(series)
        if m is not None:
            latest.append(m)
    if not latest:
        raise RuntimeError("no phantom-pin values found")
    return statistics.median(latest)


def corrected_r(valve: str, i_latest: float, offset: float) -> float | None:
    i_true = i_latest - offset
    if i_true <= 1e-4:
        return None  # effectively no current → disconnected
    r = V_SUPPLY / i_true
    r -= WIRE_OFFSET_OHMS.get(valve, 0.0)
    if valve in PARALLEL_PAIRS:
        r *= 2.0
    return r


def post_disruption_start(rs: list[float | None],
                          min_gap: int = 3) -> int:
    """Return index at which to START taking samples — drops everything
    before the LAST contiguous run of `None` of length ≥ `min_gap`.

    Controller resets / sensor-recalibration events show up as a 3-4 ord
    contiguous block of bogus readings (R > 100 Ω → filtered to None).
    Pre-reset and post-reset baselines often differ by 3-5 Ω, which makes
    Mann-Kendall on the combined series report a spurious upward trend
    (most of the 11 AGING_OPEN flags as of 2026-05-30 are this artifact).
    Truncating to the post-reset segment removes the discontinuity.

    Returns 0 if no qualifying disruption gap is found.
    """
    n = len(rs)
    gap_end = 0
    i = 0
    while i < n:
        if rs[i] is None:
            j = i
            while j < n and rs[j] is None:
                j += 1
            if j - i >= min_gap:
                gap_end = j  # drop everything UP TO and INCLUDING the gap
            i = j
        else:
            i += 1
    return gap_end


def mann_kendall(series: list[float]) -> tuple[float, float, float]:
    """Returns (tau, z, p_two_tailed). p via standard normal approx."""
    n = len(series)
    s = 0
    for i in range(n - 1):
        for j in range(i + 1, n):
            d = series[j] - series[i]
            s += (1 if d > 0 else (-1 if d < 0 else 0))
    var_s = n * (n - 1) * (2 * n + 5) / 18.0
    if s > 0: z = (s - 1) / math.sqrt(var_s)
    elif s < 0: z = (s + 1) / math.sqrt(var_s)
    else: z = 0.0
    p = math.erfc(abs(z) / math.sqrt(2))
    tau = s / (n * (n - 1) / 2.0) if n > 1 else 0.0
    return tau, z, p


def classify(valve: str, r_corr: float | None, cohort: str,
             z_score: float | None, mk_p: float, mk_tau: float,
             mk_delta: float = 0.0) -> str:
    if valve in MASTER_DEAD: return "DEAD_MASTER"
    if valve in DISCONNECTS: return "DISCONNECTED"
    if r_corr is None:       return "OPEN_CIRCUIT"
    if valve in MASTER_HEAVY:
        # Heavy-master coils: empirical R = 33–37 Ω, replacement-invariant.
        # MK on this narrow noisy range produces noise-level p-values.
        # Always classify STABLE_HEAVY — see [[irrigation-site-facts-2026-05-27]].
        return "STABLE_HEAVY"
    if r_corr < R_INOPERABLE:    return "INOPERABLE"
    # Trend-based classifications require BOTH a statistically meaningful
    # Mann-Kendall result AND a real-world magnitude of movement. Without
    # the magnitude gate, ~1Ω noise drift in the "right direction" produces
    # 50% FP rate on AGING_OPEN (sat_2:3, sat_3:11 both at baseline R but
    # tagged on 2026-05-31 with tau=+0.44/+0.49 — bench-confirmed false).
    if mk_p < TREND_P_THRESHOLD and abs(mk_delta) >= R_TREND_MIN_DELTA:
        if mk_tau > 0:                          return "AGING_OPEN"   # R rising
        if mk_tau < 0 and r_corr < R_IMPENDING: return "PRE_SHORT"    # R falling
    if r_corr > R_IMPENDING:     return "IMPENDING_OPEN"
    if cohort == "unknown":      return "STABLE_UNK_COHORT"
    if z_score is not None and abs(z_score) > 2.0:  return "COHORT_OUTLIER"
    return "STABLE"


BAD_STATUSES      = {"DEAD", "OPEN_CIRCUIT", "INOPERABLE", "PRE_SHORT"}
MARGINAL_STATUSES = {"AGING_OPEN", "IMPENDING_OPEN", "COHORT_OUTLIER"}


def emit_json(rows, cohort_stats, offsets, offset_today, phantom_drift) -> None:
    """JSON-mode output for robot consumer (kb2_post.lua)."""
    def row_repr(r):
        return {
            "valve":   r["valve"],
            "status":  r["status"],
            "r_corr":  round(r["r_corr"], 3) if r["r_corr"] is not None else None,
            "latest_A": round(r["latest_A"], 4),
            "cohort":  r["cohort"],
            "z":       round(r["z"], 3) if r["z"] is not None else None,
            "mk_tau":  round(r["mk_tau"], 3),
            "mk_p":    round(r["mk_p"], 4),
            "mk_delta": round(r.get("mk_delta", 0.0), 3),
            "mk_basis": r.get("mk_basis", "raw_R"),
            "mk_n":    r["mk_n"],
        }
    bad      = sorted([row_repr(r) for r in rows if r["status"] in BAD_STATUSES],
                      key=lambda x: x["valve"])
    marginal = sorted([row_repr(r) for r in rows if r["status"] in MARGINAL_STATUSES],
                      key=lambda x: x["valve"])
    n_stable = sum(1 for r in rows
                   if r["status"] in ("STABLE", "STABLE_UNK_COHORT", "STABLE_HEAVY"))
    summary = {
        "n_valves":       len(rows),
        "n_stable":       n_stable,
        "n_marginal":     len(marginal),
        "n_bad":          len(bad),
        "n_dead_master":  sum(1 for r in rows if r["status"] == "DEAD_MASTER"),
        "n_disconnect":   sum(1 for r in rows if r["status"] == "DISCONNECTED"),
        "offset_today":   round(offset_today, 4),
        "phantom_drift":  round(phantom_drift, 4),
        "ord_offset_span": round(max(offsets) - min(offsets), 4) if offsets else 0,
    }
    cohorts = {c: {"mu": round(mu, 3), "sd": round(sd, 3), "n": n}
               for c, (mu, sd, n) in cohort_stats.items()}
    payload = {
        "schema":       "kb2_resistance.v1",
        "generated_at": DT.datetime.now().astimezone().isoformat(timespec="seconds"),
        "summary":      summary,
        "cohort_stats": cohorts,
        "bad":          bad,
        "marginal":     marginal,
    }
    sys.stdout.write(json.dumps(payload, indent=2))


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--json", action="store_true",
                    help="emit structured JSON instead of human-readable text")
    ap.add_argument("--fetch", action="store_true",
                    help="fetch fresh valve_test+valve_groups via SSH before analyzing")
    args = ap.parse_args()
    if args.fetch:
        try:
            fetch_fresh()
        except Exception as e:
            if args.json:
                sys.stdout.write(json.dumps({
                    "schema": "kb2_resistance.v1",
                    "error":  f"fetch_fresh: {e}",
                }))
                sys.exit(0)
            else:
                raise

    valve_test, valve_groups = load()
    cohort_map = build_cohorts(valve_groups)
    phantom_drift = drift_from_phantoms(valve_test)  # drift indicator (phantom-pin median)
    n_buf = max((len(s) for s in valve_test.values() if s), default=0)
    offsets = phantom_offsets(valve_test, n_buf)  # per-ord effective offset
    offset_today = (statistics.median(offsets[-RECENT_N:])
                    if len(offsets) >= 1 else ACS712_OFFSET)

    # ── Pass 1: build per-valve R series with None for invalid points ──
    # Each ordinal k uses offsets[k] so cross-cycle ACS712 null drift is
    # removed from the MK trend basis.
    # Range cap 100 Ω drops disruption-window samples (controller-reset cycles
    # that read ~200 Ω like phantom pins). Real coil R is 30–50 Ω; anything
    # above 100 Ω is a sensor-recalibration artifact, not a coil value.
    valve_r_full: dict[str, list[float | None]] = {}
    for valve, series in valve_test.items():
        if not series or valve in NONEXISTENT: continue
        rs = []
        for k, i in enumerate(series):
            off_k = offsets[k] if k < len(offsets) else ACS712_OFFSET
            ri = corrected_r(valve, i, off_k)
            rs.append(ri if (ri is not None and 5.0 < ri < 100.0) else None)
        valve_r_full[valve] = rs

    # ── Family assignment: wire family first, then cohort, else None ──
    def family_of(valve: str, cohort: str) -> str | None:
        for fam_name, members in WIRE_FAMILIES.items():
            if valve in members: return fam_name
        if cohort in ("sun", "shade"): return f"cohort_{cohort}"
        return None  # falls through to raw-R MK

    # ── Per-family median per ordinal (for residual computation) ──
    families: dict[str, list[str]] = {}
    for v in valve_r_full:
        fam = family_of(v, cohort_map.get(v, "unknown"))
        if fam: families.setdefault(fam, []).append(v)

    n_ord = max((len(rs) for rs in valve_r_full.values()), default=0)
    family_median: dict[str, list[float | None]] = {}
    for fam, members in families.items():
        meds = []
        for k in range(n_ord):
            vals = [valve_r_full[v][k] for v in members
                    if k < len(valve_r_full[v]) and valve_r_full[v][k] is not None]
            meds.append(statistics.median(vals) if vals else None)
        family_median[fam] = meds

    # ── Pass 2: per-valve, run MK on family-residual series (or raw if no family) ──
    rows = []
    for valve, series in sorted(valve_test.items()):
        if not series or valve in NONEXISTENT: continue
        latest = recent_median(series)   # median of last N cycles (within-day noise cut)
        if latest is None: continue
        cohort = cohort_map.get(valve, "unknown")
        r = corrected_r(valve, latest, offset_today)
        rs_full = valve_r_full[valve]
        # Drop everything before the controller-reset disruption window;
        # MK on the combined pre/post series produces spurious trend flags.
        k_start = post_disruption_start(rs_full)
        rs_trim = rs_full[k_start:]
        fam = family_of(valve, cohort)
        if fam and fam in family_median:
            meds = family_median[fam][k_start:]
            # residual is meaningful only at ordinals where BOTH the valve and
            # the family median are valid
            residuals = [rs_trim[k] - meds[k] for k in range(min(len(rs_trim), len(meds)))
                         if rs_trim[k] is not None and meds[k] is not None]
            mk_series = residuals
            mk_basis = f"residual_vs_{fam}"
        else:
            mk_series = [x for x in rs_trim if x is not None]
            mk_basis = "raw_R"
        if len(mk_series) >= 5:
            tau, z, p = mann_kendall(mk_series)
            # Magnitude-of-movement over the trend window. For raw_R basis
            # this is ΔR; for residual basis this is the change in detrended
            # residual. Either way, |this| < R_TREND_MIN_DELTA means the
            # trend is below measurement noise floor → suppress trend label.
            mk_delta = mk_series[-1] - mk_series[0]
        else:
            tau, z, p = 0.0, 0.0, 1.0
            mk_delta = 0.0
        rows.append({"valve": valve, "latest_A": latest, "r_corr": r,
                     "cohort": cohort, "mk_tau": tau, "mk_p": p,
                     "mk_delta": mk_delta,
                     "mk_basis": mk_basis, "mk_n": len(mk_series),
                     "k_start": k_start, "series": series})

    # cohort stats over non-disconnect, non-special valves
    skip = (DISCONNECTS | MASTER_DEAD | MASTER_HEAVY | PARALLEL_PAIRS
            | set(WIRE_OFFSET_OHMS))
    cohort_stats: dict[str, tuple[float, float, int]] = {}
    for cname in ("sun", "shade"):
        rs = [r["r_corr"] for r in rows
              if r["cohort"] == cname and r["r_corr"] is not None
              and r["valve"] not in skip]
        if len(rs) >= 2:
            mu = statistics.mean(rs); sd = statistics.pstdev(rs)
            cohort_stats[cname] = (mu, sd, len(rs))

    for r in rows:
        c = r["cohort"]; rv = r["r_corr"]
        if c in cohort_stats and rv is not None and r["valve"] not in skip:
            mu, sd, _ = cohort_stats[c]
            r["z"] = (rv - mu) / sd if sd > 1e-6 else 0.0
        else:
            r["z"] = None
        r["status"] = classify(r["valve"], rv, c, r["z"], r["mk_p"], r["mk_tau"],
                               r.get("mk_delta", 0.0))

    # ── REPORT ────────────────────────────────────────────────────────────
    if args.json:
        emit_json(rows, cohort_stats, offsets, offset_today, phantom_drift)
        return
    print(f"\n=== IRRIGATION VALVE RESISTANCE — KB2-daily baseline ===")
    print(f"  Per-day reading:      median of last {RECENT_N} cycles (within-day noise cut)")
    print(f"  ACS712 offset:        {ACS712_OFFSET:.4f} A  (calibration anchor; sat_2:4=35Ω)")
    print(f"  REF_PHANTOM:          {REF_PHANTOM:.4f} A  (anchor-time phantom median)")
    print(f"  Phantom-pin today:    {phantom_drift:.4f} A  (recent {RECENT_N}-cycle median)")
    print(f"  Effective offset      today: {offset_today:.4f}  "
          f"(Δ vs anchor {offset_today-ACS712_OFFSET:+.4f})")
    print(f"  Per-ord offset range: [{min(offsets):.4f}, {max(offsets):.4f}]  "
          f"(Δ-span {max(offsets)-min(offsets):.4f})")
    print(f"  V_supply:             {V_SUPPLY} V")
    print(f"  New-install spec:     {R_NEW_SPEC} Ω")
    print(f"  Trend threshold:      p < {TREND_P_THRESHOLD}")
    for c, (mu, sd, n) in cohort_stats.items():
        print(f"  Cohort {c:<5}    μ={mu:6.2f}Ω  σ={sd:5.2f}Ω  n={n}")

    print("\n  valve              I_latest   R_corr   cohort  z      MK_tau  MK_p   MK_n MK_basis              status")
    print("  " + "─" * 116)
    by_status = sorted(rows, key=lambda r: (
        0 if r["status"] not in ("STABLE", "STABLE_UNK_COHORT") else 1,
        r["valve"]))
    for r in by_status:
        rv = f"{r['r_corr']:6.2f}" if r["r_corr"] is not None else "  ---"
        zv = f"{r['z']:+5.2f}" if r["z"] is not None else "  ---"
        basis = r.get("mk_basis", "raw_R")
        print(f"  {r['valve']:<18} {r['latest_A']:7.4f}  {rv}    "
              f"{r['cohort']:<6} {zv}  {r['mk_tau']:+5.2f}  {r['mk_p']:5.3f}  "
              f"{r['mk_n']:>3}  {basis:<22} {r['status']}")

    # anomaly summary
    anomalies = [r for r in rows if r["status"] not in
                 ("STABLE", "STABLE_UNK_COHORT", "STABLE_HEAVY",
                  "DISCONNECTED", "DEAD_MASTER")]
    print(f"\n  → {len(anomalies)} anomalies of {len(rows)} valves")
    print(f"  → {sum(1 for r in rows if r['status']=='DISCONNECTED')} disconnects (offset refs)")
    print(f"  → {sum(1 for r in rows if r['status']=='DEAD_MASTER')} dead master(s)\n")


if __name__ == "__main__":
    main()
