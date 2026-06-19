#!/usr/bin/env python3
"""
In-cycle long-run analyzer — applies the Glenn 2026-05-30 rule:

    "Only analyze bins that fired in the current cycle."

Pipeline:
  1. SSH to irrigation Pi, pull past_actions records since CYCLE_START.
  2. Extract the canonical bin_key for every IRRIGATION_STEP_COMPLETE.
  3. Build the in-cycle bin set.
  4. Load TIME_HISTORY snapshot (from local explore/snapshots/<date>/).
  5. For each in-cycle bin, run:
       - body-median baseline drift (today vs historic median+MAD)
       - within-run dual-stream split scan (flow + current)
  6. Print a compact triage table.

Usage:
  python3 in_cycle_long_run.py
       --since '2026-05-29 18:00'              (Pacific, default = yesterday 18:00)
       --snap  snapshots/2026-05-30/time_history.json   (default = newest)

All bins NOT in the in-cycle set are simply skipped (no analysis, no
report). This eliminates the entire false-positive class where the
analyzer compared an old/stale "newest" entry of an edited-out
schedule bin to its own stale historic.
"""
import argparse
import datetime as DT
import json
import os
import shlex
import statistics as st
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).parent

# ── analysis tuning ──
STARTUP_SKIP    = 3        # current stream: 3-step skip
FLOW_SKIP       = 5        # flow stream: 5-step skip (filter warm-up + valve settle)
MA_TAPS         = 5        # matches controller's 5-tap MA on HUNTER_VALVE
TAIL_SKIP       = 2
MIN_BODY        = 14       # current stream
MIN_BODY_FLOW   = 5        # filtered flow body needs only 5 samples (was 14 raw)
K_MAD           = 3.5
GPM_FLOOR       = 1.0
A_FLOOR         = 0.03
MIN_HIST        = 4
MIN_HALF_FRAC   = 0.25
MIN_HALF_HARD   = 5
K_FLOW          = 3.0
K_CURRENT       = 3.0
GPM_SPLIT_FLOOR = 1.5
A_SPLIT_FLOOR   = 0.20
# Short-term-mode analysis (Glenn 2026-05-30 EOD)
GPM_SHORT_FLOOR = 1.0       # flow gate floor for short bins (last-sample method)
A_SHORT_FLOOR   = 0.05      # current gate floor for short bins
MIN_HIST_SHORT  = 2         # short-term comparison possible with just 2 historic runs

# ETO-managed valves (per irrigation_schedule_taxonomy_2026-05-29 memory).
# A bin = short-term if ALL its valves are non-ETO, else long-term.
ETO_VALVES = {
    ("satellite_2", 13), ("satellite_2", 14), ("satellite_2", 15), ("satellite_2", 16),
    ("satellite_3", 1),  ("satellite_3", 2),  ("satellite_3", 5),
    ("satellite_3", 13), ("satellite_3", 14), ("satellite_3", 15), ("satellite_3", 18),
    ("satellite_4", 1),  ("satellite_4", 3),  ("satellite_4", 4),  ("satellite_4", 6),
    ("satellite_4", 7),  ("satellite_4", 9),  ("satellite_4", 10), ("satellite_4", 11),
    ("satellite_4", 12),
}
# Cohort-level pressure-starvation detector (Glenn 2026-05-30 sat_4:1 case)
GPM_STARVE_DROP = 1.0       # per-bin must be at least this far below baseline
MIN_COHORT_DROP = 3         # need this many bins dropping to flag the cohort
MIN_COHORT_SIZE = 4         # cohort itself must be at least this large
A_BASELINE_OK   = 0.20      # cohort-normalized |cur Δ| must stay under this
                            # to keep "current-at-baseline" prerequisite valid

PULL_PAST_PY = r"""
import redis, msgpack, json, sys, datetime as DT
SINCE_ISO = "__SINCE_ISO__"
PAST_KEY = ("[SYSTEM:main_operations][SITE:LaCima][APPLICATION_SUPPORT:APPLICATION_SUPPORT]"
            "[IRRIGIGATION_SCHEDULING_CONTROL:IRRIGIGATION_SCHEDULING_CONTROL]"
            "[PACKAGE:IRRIGIGATION_SCHEDULING_CONTROL_DATA][STREAM_REDIS:IRRIGATION_PAST_ACTIONS]")
since_dt = DT.datetime.fromisoformat(SINCE_ISO).astimezone()
min_ms = int(since_dt.timestamp() * 1000)
r = redis.Redis(db=4)
ents = r.xrange(PAST_KEY, min=f"{min_ms}-0", max='+', count=20000)
opens = []
runs = []
for sid, fields in ents:
    rec = {}
    for k, v in fields.items():
        ks = k.decode()
        try: rec[ks] = msgpack.unpackb(v, raw=False)
        except Exception:
            try: rec[ks] = v.decode()
            except: rec[ks] = repr(v)
    data = rec.get("data", {})
    act = data.get("action")
    det = data.get("details", {})
    if act == "IRRIGATION_STATION_START":
        opens.append((sid.decode(), det))
    elif act == "IRRIGATION_STEP_COMPLETE":
        for i in range(len(opens)-1, -1, -1):
            ssid, sdet = opens[i]
            if (sdet.get("step") == det.get("step")
                and sdet.get("schedule_name") == det.get("schedule_name")):
                runs.append({
                    "start_ms": int(ssid.split("-")[0]),
                    "end_ms":   int(sid.decode().split("-")[0]),
                    "schedule": det.get("schedule_name"),
                    "step":     det.get("step"),
                    "run_time": det.get("run_time"),
                    "io_setup": det.get("io_setup"),
                })
                opens.pop(i); break
sys.stdout.write(json.dumps(runs, default=str))
"""


def ssh_python(script):
    cmd = ["ssh", "irrigation", "python3 -"]
    p = subprocess.run(cmd, input=script.encode(), capture_output=True, timeout=30)
    if p.returncode != 0:
        raise RuntimeError(f"ssh python failed: {p.stderr.decode()}")
    return p.stdout.decode()


def canonicalize_io(io_setup):
    if not io_setup: return "?"
    parts = []
    for s in io_setup:
        rem = s.get("remote", "?")
        for b in (s.get("bits") or []):
            parts.append(f"{rem}:{b}")
    parts.sort()
    return "/".join(parts)


def median(xs):
    return st.median(xs) if xs else None


def mad(xs, m=None):
    if not xs: return None
    if m is None: m = median(xs)
    return median([abs(v - m) for v in xs])


def body_med(samples):
    if not samples or len(samples) < STARTUP_SKIP + TAIL_SKIP + MIN_BODY:
        return None
    body = samples[STARTUP_SKIP: len(samples) - TAIL_SKIP]
    return median(body) if body else None


def ma_filter(samples, taps=MA_TAPS):
    """Causal 5-tap moving average matching controller's FILTERED_HUNTER_VALVE."""
    out = []
    for t, _ in enumerate(samples):
        if t < taps - 1:
            out.append(None)
        else:
            out.append(sum(samples[t - taps + 1 : t + 1]) / taps)
    return out


def flow_body_mean(samples):
    """Per-run filtered flow scalar (matches controller filter, then mean).

    Returns the mean of MA5(samples) over t in [FLOW_SKIP, n - TAIL_SKIP).
    Decimal-valued — preserves sub-integer drift the raw median would hide.
    """
    if not samples or len(samples) < FLOW_SKIP + TAIL_SKIP + MIN_BODY_FLOW:
        return None
    filt = ma_filter(samples)
    body = [v for v in filt[FLOW_SKIP: len(samples) - TAIL_SKIP] if v is not None]
    if len(body) < MIN_BODY_FLOW: return None
    return sum(body) / len(body)


def split_features(samples):
    if not samples or len(samples) < STARTUP_SKIP + TAIL_SKIP + MIN_BODY:
        return None
    body = samples[STARTUP_SKIP: len(samples) - TAIL_SKIP]
    if len(body) < MIN_BODY: return None
    min_half = max(MIN_HALF_HARD, int(len(body) * MIN_HALF_FRAC))
    if len(body) < 2 * min_half: return None
    best = None; best_abs = -1.0
    for i in range(min_half, len(body) - min_half + 1):
        a = median(body[:i]); b = median(body[i:])
        gap = abs(b - a)
        if gap > best_abs:
            best_abs = gap
            best = (i + STARTUP_SKIP, a, b, b - a)
    if best is None: return None
    split_at, early, late, delta = best
    return {"split_at": split_at, "early": early, "late": late, "delta": delta,
            "n_body": len(body)}


def historic_baseline(runs, stream_key, exclude_last=True):
    pool = runs[:-1] if (exclude_last and len(runs) > 1) else runs
    # Stream-specific per-run reduction.
    # Flow uses filtered body_mean (matches controller filter, decimal-valued).
    # Current keeps raw body_med (current isn't 1-unit quantized; median fine).
    reducer = flow_body_mean if stream_key == "HUNTER_FLOW_METER" else body_med
    bms = []
    for r in pool:
        arr = (r.get(stream_key) or {}).get("data") or []
        bm = reducer(arr)
        if bm is not None: bms.append(bm)
    if len(bms) < MIN_HIST: return None
    m = median(bms)
    return {"n": len(bms), "med": m, "mad": mad(bms, m)}


def iglew_z(v, m, m_mad):
    if m_mad is None or m_mad < 1e-9: return None
    return 0.6745 * (v - m) / m_mad


def classify_drift(today, base, floor, cohort_offset=0.0):
    """Apply cohort-offset BEFORE gating (current only — flow passes 0)."""
    if today is None or base is None: return None
    delta_raw  = today - base["med"]
    delta_norm = delta_raw - cohort_offset
    z = iglew_z(today - cohort_offset, base["med"], base["mad"])
    gate = max(K_MAD * (base["mad"] or 0), floor)
    flagged = abs(delta_norm) > gate
    if not flagged:
        return {"z": z, "delta": delta_norm, "delta_raw": delta_raw,
                "cohort_offset": cohort_offset, "gate": gate,
                "flagged": False, "label": "OK"}
    return {"z": z, "delta": delta_norm, "delta_raw": delta_raw,
            "cohort_offset": cohort_offset, "gate": gate, "flagged": True,
            "label": "ABOVE" if delta_norm > 0 else "BELOW"}


def classify_within(f_flow, f_cur, hist_mad_flow, hist_mad_cur):
    if f_flow is None or f_cur is None: return None
    flow_gate = max(K_FLOW * (hist_mad_flow or 0), GPM_SPLIT_FLOOR)
    cur_gate  = max(K_CURRENT * (hist_mad_cur or 0), A_SPLIT_FLOOR)
    df = f_flow["delta"]; dc = f_cur["delta"]
    flow_sig = "+" if df > flow_gate else "-" if df < -flow_gate else "0"
    cur_sig  = "+" if dc > cur_gate else "-" if dc < -cur_gate else "0"
    label_map = {
        "+0": "MID-BREAK", "+-": "MID-BREAK+DROOP",
        "-0": "MID-CLOG",  "-+": "MID-VALVE-CLOSING",
        "0+": "CUR-DRIFT-UP", "0-": "CUR-DRIFT-DOWN", "00": "STEADY",
        "++": "BREAK+CUR-RISE", "--": "CLOG+DROOP",
    }
    return {"label": label_map.get(flow_sig + cur_sig, "?"),
            "sigs": flow_sig + cur_sig, "flow_delta": df, "cur_delta": dc,
            "flow_gate": flow_gate, "cur_gate": cur_gate,
            "flagged": (flow_sig + cur_sig) != "00"}


def primary_satellite(bin_key):
    """Return primary satellite for cohort grouping; 'mixed' if multi-sat,
    excluding sat_1 which is the dwell/master-style valve."""
    parts = bin_key.split("/")
    sats = []
    for p in parts:
        sat = p.split(":")[0]   # 'satellite_X'
        if sat == "satellite_1": continue
        if sat not in sats: sats.append(sat)
    if not sats:
        return "satellite_1"     # bin is pure sat_1 (dwell-only)
    if len(sats) == 1:
        return sats[0]
    return "mixed"


def bin_analysis_mode(bin_key):
    """Glenn 2026-05-30 rule: bin is 'short' if ALL valves are non-ETO,
    'long' if at least one ETO valve is in it.

    Returns 'short' or 'long'.
    """
    parts = bin_key.split("/")
    for p in parts:
        try:
            sat_str, bit_str = p.split(":")
            bit = int(bit_str)
        except (ValueError, AttributeError):
            continue
        if (sat_str, bit) in ETO_VALVES:
            return "long"
    return "short"


def last_sample(samples):
    """Short-bin steady-state reading — last sample of the run."""
    if not samples: return None
    return samples[-1]


def short_baseline(runs, stream_key, exclude_last=True):
    """Median of last 5 (or fewer) historic runs' last-samples for short bins.

    Returns dict {n, med, mad} or None if insufficient history.
    """
    pool = runs[:-1] if (exclude_last and len(runs) > 1) else runs
    # Rolling-5 window (or fewer if we don't have 5 yet, e.g., post-reset)
    window = pool[-5:]
    lasts = []
    for r in window:
        arr = (r.get(stream_key) or {}).get("data") or []
        ls = last_sample(arr)
        if ls is not None: lasts.append(ls)
    if len(lasts) < MIN_HIST_SHORT: return None
    m = median(lasts)
    return {"n": len(lasts), "med": m, "mad": mad(lasts, m)}


def is_city_fed(bin_key):
    """True if sat_1:39 (city-water valve with dwell) is in the bin —
    city pressure is supplied, so well-pressure-starvation is impossible
    and the bin lives in a different cohort for current normalization."""
    return "satellite_1:39" in bin_key.split("/")


def cohort_key(primary_sat, city_fed):
    """Cohort grouping key — splits by satellite AND feed mode."""
    feed = "city" if city_fed else "well"
    return f"{primary_sat}/{feed}"


def compute_cohort_offsets(results, min_cohort=4):
    """For each (satellite, feed-mode) cohort of LONG-mode bins with
    >= min_cohort bins that have valid raw current-Δ, return
    cohort_median(Δ_raw). Short bins use last-sample current which
    isn't directly comparable to body_med current; cohort norm
    applies to long-mode only."""
    by_cohort = {}
    for r in results:
        if r["status"] != "ok": continue
        if r.get("mode") != "long": continue
        cd = r.get("cur_drift_raw")
        if cd is None: continue
        if r["primary_sat"] in ("mixed", "satellite_1"): continue
        ck = cohort_key(r["primary_sat"], r["city_fed"])
        by_cohort.setdefault(ck, []).append(cd["delta"])
    offsets = {}
    for ck, deltas in by_cohort.items():
        if len(deltas) >= min_cohort:
            offsets[ck] = st.median(deltas)
    return offsets


def detect_cohort_starvation(results):
    """Cohort-level pressure-starvation detector.

    For each well-fed cohort with >= MIN_COHORT_SIZE bins, count bins whose
    flow body_med dropped by >= GPM_STARVE_DROP vs their own baseline AND
    whose cohort-normalized current Δ is within A_BASELINE_OK. If
    >= MIN_COHORT_DROP bins meet both criteria, flag the cohort.
    """
    by_sat = {}
    for r in results:
        if r["status"] != "ok": continue
        if r.get("mode") != "long": continue   # pressure starvation = ETO/long concept
        if r["primary_sat"] in ("mixed", "satellite_1"): continue
        if r["city_fed"]: continue   # city-fed cannot be starved (locked rule)
        by_sat.setdefault(r["primary_sat"], []).append(r)
    flags = []
    for sat, members in by_sat.items():
        if len(members) < MIN_COHORT_SIZE: continue
        starved = []
        for r in members:
            ft, fb = r["flow_today"], r["flow_base"]
            cd = r["cur_drift"]
            if ft is None or fb is None: continue
            flow_drop = fb["med"] - ft
            cur_ok = cd is not None and abs(cd["delta"]) < A_BASELINE_OK
            if flow_drop >= GPM_STARVE_DROP and cur_ok:
                starved.append({
                    "bin":       r["bin"],
                    "flow_today": ft,
                    "flow_base":  fb["med"],
                    "flow_drop":  flow_drop,
                    "cur_norm_delta": cd["delta"] if cd else None,
                    "individually_flagged": (r["flow_drift"] is not None
                                             and r["flow_drift"]["flagged"]),
                })
        if len(starved) >= MIN_COHORT_DROP:
            flags.append({
                "satellite":  sat,
                "cohort_n":   len(members),
                "starved_n":  len(starved),
                "starved":    sorted(starved, key=lambda x: -x["flow_drop"]),
            })
    return flags


def historic_split_mad(runs, stream_key):
    deltas = []
    for r in runs[:-1]:
        arr = (r.get(stream_key) or {}).get("data") or []
        f = split_features(arr)
        if f is not None: deltas.append(f["delta"])
    if len(deltas) < 3: return None
    m = median(deltas)
    return median([abs(d - m) for d in deltas])


def main():
    ap = argparse.ArgumentParser()
    default_since = (DT.datetime.now().astimezone()
                     - DT.timedelta(days=1)).replace(hour=18, minute=0, second=0,
                                                     microsecond=0)
    ap.add_argument("--since", default=default_since.isoformat(),
                    help="cycle start (ISO, local TZ default; default = yesterday 18:00 local)")
    ap.add_argument("--snap", default=str(ROOT / "snapshots"
                                          / DT.date.today().isoformat()
                                          / "time_history.json"))
    args = ap.parse_args()

    print(f"cycle since: {args.since}")
    print(f"snapshot:    {args.snap}")

    # ── 1) Pull past_actions since cycle start ──
    raw = ssh_python(PULL_PAST_PY.replace("__SINCE_ISO__", args.since))
    past_runs = json.loads(raw)
    if not past_runs:
        print("\nNO RUNS in cycle window — nothing to analyze.")
        return

    # Build per-(bin, schedule:step) records so we can show what fired
    in_cycle = {}     # bin_key -> list[(schedule, step, run_time)]
    for r in past_runs:
        bk = canonicalize_io(r["io_setup"])
        in_cycle.setdefault(bk, []).append((r["schedule"], r["step"], r["run_time"]))

    print(f"\n=== In-cycle bins ({len(in_cycle)}) — fired since cycle start ===")
    print(f"  {'bin':<48s}  schedule:step (run_time min)")
    print("  " + "-" * 88)
    for bk in sorted(in_cycle.keys()):
        steps = ", ".join(f"{s}:{step}({rt})" for s, step, rt in in_cycle[bk])
        if len(steps) > 80: steps = steps[:77] + "..."
        print(f"  {bk:<48s}  {steps}")

    # ── 2) Load TIME_HISTORY snapshot ──
    th = json.loads(Path(args.snap).read_text())

    # ── 3) Pass 1: compute raw current drift per bin (no cohort offset yet) ──
    results = []
    for bk in sorted(in_cycle.keys()):
        runs = th.get(bk, [])
        mode = bin_analysis_mode(bk)
        if not runs:
            results.append({"bin": bk, "status": "no_time_history",
                            "primary_sat": primary_satellite(bk),
                            "city_fed":    is_city_fed(bk),
                            "mode":        mode})
            continue
        # Pick canonical "today" run: among last-N runs (N = # of fires in
        # this cycle), use the LONGEST. Diagnostic short tests shouldn't
        # override the regularly-scheduled longer run.
        n_in_cycle = len(in_cycle[bk])
        cycle_runs = runs[-n_in_cycle:] if n_in_cycle > 0 else [runs[-1]]
        newest = max(cycle_runs,
                     key=lambda r: len((r.get("HUNTER_FLOW_METER") or {}).get("data") or []))
        flow_arr = (newest.get("HUNTER_FLOW_METER")  or {}).get("data") or []
        cur_arr  = (newest.get("IRRIGATION_CURRENT") or {}).get("data") or []

        # ── Mode-aware "today" summary + baseline ──
        if mode == "short":
            flow_today = last_sample(flow_arr)
            cur_today  = last_sample(cur_arr)
            flow_base  = short_baseline(runs, "HUNTER_FLOW_METER")
            cur_base   = short_baseline(runs, "IRRIGATION_CURRENT")
            flow_floor = GPM_SHORT_FLOOR
            cur_floor  = A_SHORT_FLOOR
            # Short bins: no within-run split scan (too few samples)
            within = None
        else:  # long
            flow_today = flow_body_mean(flow_arr)   # filtered, decimal
            cur_today  = body_med(cur_arr)
            flow_base  = historic_baseline(runs, "HUNTER_FLOW_METER")
            cur_base   = historic_baseline(runs, "IRRIGATION_CURRENT")
            flow_floor = GPM_FLOOR
            cur_floor  = A_FLOOR
            # Long bins: within-run split scan as before
            f_flow_w   = split_features(flow_arr)
            f_cur_w    = split_features(cur_arr)
            mad_flow_w = historic_split_mad(runs, "HUNTER_FLOW_METER")
            mad_cur_w  = historic_split_mad(runs, "IRRIGATION_CURRENT")
            within     = classify_within(f_flow_w, f_cur_w, mad_flow_w, mad_cur_w)

        # Raw (cohort_offset=0) current drift — used only to compute the cohort offset
        cur_drift_raw  = classify_drift(cur_today, cur_base, cur_floor, cohort_offset=0.0)

        results.append({
            "bin": bk,
            "status": "ok",
            "primary_sat": primary_satellite(bk),
            "city_fed":    is_city_fed(bk),
            "mode":        mode,
            "n_samples_flow": len(flow_arr),
            "flow_today": flow_today,
            "cur_today":  cur_today,
            "flow_base":  flow_base,
            "cur_base":   cur_base,
            "flow_drift": classify_drift(flow_today, flow_base, flow_floor),
            "cur_drift_raw":  cur_drift_raw,
            "within":     within,
            "flow_floor": flow_floor,
            "cur_floor":  cur_floor,
        })

    # ── 3b) Pass 2: compute cohort offsets, then re-classify current ──
    cohort_offsets = compute_cohort_offsets(results, min_cohort=4)
    cohort_K_MAD_widen = 5.0 / K_MAD  # widen gate for bins without cohort coverage
    for r in results:
        if r["status"] != "ok": continue
        cur_floor = r.get("cur_floor", A_FLOOR)
        # Short bins: skip cohort norm (last-sample currents aren't comparable
        # cross-bin). Use raw Δ with the short-bin floor.
        if r.get("mode") == "short":
            r["cur_drift"] = classify_drift(r["cur_today"], r["cur_base"],
                                            cur_floor, cohort_offset=0.0)
            r["cohort_used"] = None
            continue
        # Long bins: cohort normalization when cohort exists
        ck = cohort_key(r["primary_sat"], r["city_fed"])
        offset = cohort_offsets.get(ck, 0.0)
        if ck in cohort_offsets:
            r["cur_drift"] = classify_drift(r["cur_today"], r["cur_base"],
                                            cur_floor, cohort_offset=offset)
            r["cohort_used"] = ck
        else:
            wider_floor = cur_floor * cohort_K_MAD_widen
            r["cur_drift"] = classify_drift(r["cur_today"], r["cur_base"],
                                            wider_floor, cohort_offset=0.0)
            cd = r["cur_drift"]
            if cd is not None:
                cd["gate"] = cd["gate"] * cohort_K_MAD_widen
                cd["flagged"] = abs(cd["delta"]) > cd["gate"]
                if not cd["flagged"]: cd["label"] = "OK"
            r["cohort_used"] = None

    # Print cohort offsets so reader knows what was subtracted
    print(f"\n=== Cohort current offsets (split by satellite + feed-mode) ===")
    if cohort_offsets:
        for ck in sorted(cohort_offsets):
            n_bins = sum(1 for r in results
                         if r["status"]=="ok"
                         and cohort_key(r["primary_sat"], r["city_fed"]) == ck)
            print(f"  {ck:<22s}  median Δ_raw = {cohort_offsets[ck]:+.4f} A   "
                  f"(n_bins={n_bins})")
    else:
        print("  (no cohorts met min_cohort=4 threshold)")
    print(f"  (well = no sat_1:39 in bin; city = sat_1:39 present, "
          f"city pressure supplies → starvation impossible)")

    # ── 4) Per-bin table ──
    print(f"\n=== Per in-cycle bin — short uses last-sample, long uses body_med ===")
    hdr = (f"  {'bin':<42s} {'mode':<5s} {'sat':<12s} {'feed':<5s} {'n_s':>4s}  "
           f"{'F now':>5s} {'F base±mad':>10s}  {'fΔ':>5s} {'fz':>5s} {'fcls':<7s}  "
           f"{'C now':>5s} {'C base±mad':>10s}  {'cΔraw':>6s} {'cΔnorm':>6s} {'ccls':<7s}  "
           f"{'within':<12s}")
    print(hdr); print("  " + "-" * (len(hdr) - 2))

    def sk(r):
        if r["status"] != "ok": return (1, r["bin"])
        z = 0
        if r["flow_drift"] and r["flow_drift"].get("z") is not None:
            z = max(z, abs(r["flow_drift"]["z"]))
        if r["cur_drift"] and r["cur_drift"].get("z") is not None:
            z = max(z, abs(r["cur_drift"]["z"]))
        if r["within"] and r["within"]["flagged"]: z += 1
        return (0, -z, r["bin"])
    results.sort(key=sk)

    def zfmt(z): return f"{z:+.1f}" if z is not None else "  —"

    for r in results:
        if r["status"] != "ok":
            print(f"  {r['bin']:<42s}  ** {r['status']} **")
            continue
        b = r["bin"][:40]
        mode_s = r["mode"]
        sat_s = r["primary_sat"] + ("" if r.get("cohort_used") else " *")
        ft = f"{r['flow_today']:.1f}" if r['flow_today'] is not None else "  —"
        ct = f"{r['cur_today']:.2f}"  if r['cur_today']  is not None else "  —"
        fb = r["flow_base"]; cb = r["cur_base"]
        fb_s = f"{fb['med']:.1f}±{fb['mad']:.2f}" if fb else "    —    "
        cb_s = f"{cb['med']:.2f}±{cb['mad']:.3f}" if cb else "    —    "
        fd, cd, w = r["flow_drift"], r["cur_drift"], r["within"]
        fd_s = (f"{fd['delta']:+5.1f} {zfmt(fd['z']):>5s} {fd['label']:<7s}" if fd
                else f"   —    —   no_hist")
        if cd:
            cd_raw  = cd.get("delta_raw", cd["delta"])
            cd_norm = cd["delta"]
            cd_s = f"{cd_raw:+6.3f} {cd_norm:+6.3f} {cd['label']:<7s}"
        else:
            cd_s = f"    —      —     no_hist"
        w_s = w["label"] if w else "n/a"
        feed = "city" if r["city_fed"] else "well"
        print(f"  {b:<42s} {mode_s:<5s} {sat_s:<12s} {feed:<5s} {r['n_samples_flow']:>4d}  "
              f"{ft:>5s} {fb_s:>10s}  {fd_s}  "
              f"{ct:>5s} {cb_s:>10s}  {cd_s}  {w_s:<12s}")
    print(f"  (sat '*' = no cohort offset (mixed/lone/short); within 'n/a' = short bin)")

    # ── 5) Flagged-only summary ──
    flagged = [r for r in results if r["status"] == "ok" and (
        (r["flow_drift"] and r["flow_drift"]["flagged"]) or
        (r["cur_drift"]  and r["cur_drift"]["flagged"]) or
        (r["within"]     and r["within"]["flagged"])
    )]
    print(f"\n=== Flagged in-cycle bins ({len(flagged)}) ===")
    if not flagged:
        print("  (none — last cycle was clean)")
    for r in flagged:
        fd, cd, w = r["flow_drift"], r["cur_drift"], r["within"]
        marks = []
        # Flow-low on a well-fed bin → starvation-eligible; city-fed → exempt
        if fd and fd["flagged"]:
            base = f"FLOW {fd['label']} Δ={fd['delta']:+.2f} z={zfmt(fd['z'])}"
            if fd["label"] == "BELOW":
                if r["city_fed"]:
                    base += "  (city-fed — NOT pressure starvation)"
                else:
                    base += "  (well-fed — pressure-starvation candidate)"
            marks.append(base)
        if cd and cd["flagged"]:
            marks.append(f"CUR {cd['label']} Δ={cd['delta']:+.3f} "
                         f"(raw {cd.get('delta_raw',cd['delta']):+.3f}) z={zfmt(cd['z'])}")
        if w and w["flagged"]:
            marks.append(f"within {w['label']}")
        steps = ", ".join(f"{s}:{step}" for s, step, _ in in_cycle[r["bin"]])
        feed = "city-fed" if r["city_fed"] else "well-fed"
        mode_s = r["mode"]
        print(f"\n  {r['bin']}   [{mode_s}; {feed}; {steps}]")
        for m in marks: print(f"    {m}")

    # ── 6) Cohort-level pressure-starvation detector ──
    cohort_flags = detect_cohort_starvation(results)
    print(f"\n=== Cohort-level PRESSURE_STARVATION flags ({len(cohort_flags)}) ===")
    print(f"    triggers when >= {MIN_COHORT_DROP} well-fed bins on same satellite")
    print(f"    drop >= {GPM_STARVE_DROP} GPM each with current within "
          f"{A_BASELINE_OK} A of baseline (after cohort normalization)\n")
    if not cohort_flags:
        print("  (none)")
    for f in cohort_flags:
        print(f"  PRESSURE_STARVATION_COHORT on {f['satellite']}  "
              f"({f['starved_n']} of {f['cohort_n']} well-fed bins starved)")
        for s in f["starved"]:
            mark = " [also K_MAD flagged]" if s["individually_flagged"] else ""
            print(f"    {s['bin']:<42s}  today={s['flow_today']:.1f} GPM  "
                  f"base={s['flow_base']:.1f}  drop={s['flow_drop']:+.1f}  "
                  f"cur_norm Δ={s['cur_norm_delta']:+.3f} A{mark}")


if __name__ == "__main__":
    main()
