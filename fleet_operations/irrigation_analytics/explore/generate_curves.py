#!/usr/bin/env python3
"""
Per-bin baseline generator for the irrigation analytics LuaJIT robot.

Reads a TIME_HISTORY snapshot, classifies each bin as long (ETO/tree) or
short (non-ETO end-point), reduces each of the last N runs to a single
scalar, and writes the rolling-window baseline to a single JSON file.

Long bins:
  reducer = ma5_body_mean_t5
            apply controller's 5-tap MA to HUNTER_FLOW_METER.data,
            then mean over t in [5, n - TAIL_SKIP).
            Decimal-valued; preserves sub-integer drift.

Short bins:
  reducer = last_sample_raw
            take HUNTER_FLOW_METER.data[-1] directly. The 5-tap MA
            of the last sample is the whole-run average for runs
            shorter than ~7 min, which biases toward startup — raw
            last_sample is the meaningful steady-state estimate.

For each bin the file stores ref (median of the window) + ref_mad
(median absolute deviation). Robot consumer compares today's run's
reduction against ref; flags if |today - ref| > max(K * ref_mad, floor).

Usage:
  python3 generate_curves.py
       --snap snapshots/2026-05-31/time_history.json   (default = today's)
       --out  baseline_state/baselines.json
       --window 5

Writes atomically (temp + rename) so a reading robot never sees a
half-written file.
"""
import argparse
import datetime as DT
import json
import os
import statistics as st
import sys
from pathlib import Path

ROOT = Path(__file__).parent

# Must match in_cycle_long_run.py and irrigation-schedule-taxonomy memory.
ETO_VALVES = {
    ("satellite_2", 13), ("satellite_2", 14), ("satellite_2", 15), ("satellite_2", 16),
    ("satellite_3", 1),  ("satellite_3", 2),  ("satellite_3", 5),
    ("satellite_3", 13), ("satellite_3", 14), ("satellite_3", 15), ("satellite_3", 18),
    ("satellite_4", 1),  ("satellite_4", 3),  ("satellite_4", 4),  ("satellite_4", 6),
    ("satellite_4", 7),  ("satellite_4", 9),  ("satellite_4", 10), ("satellite_4", 11),
    ("satellite_4", 12),
}

# Long-bin reduction tuning. Matches in_cycle_long_run.py filtered path.
FLOW_SKIP        = 5
TAIL_SKIP        = 2
MA_TAPS          = 5
MIN_BODY_FLOW    = 5     # filtered body needs >= 5 valid samples
MIN_TOTAL_LONG   = FLOW_SKIP + TAIL_SKIP + MIN_BODY_FLOW   # 12

# Short-bin reduction tuning.
MIN_TOTAL_SHORT  = 5     # need at least 5 samples to take a meaningful end-point

# KB3 live-detector tuning (per-bin instantaneous excursion).
# Real pipe breaks are NOT transient (sustained leak) — 5-consec rule
# (5 filtered samples in a row above thresh) filters single-sample noise
# while letting any real break through within 5 minutes of onset.
KB3_K_STDEV      = 5.0   # threshold = K * historic_stdev
KB3_THRESH_FLOOR = 1.5   # ... but never below this (GPM)
KB3_NOISE_CAP    = 3.0   # bin is ineligible for KB3 if K*stdev > this

SCHEMA_VERSION   = 1
SCHEMA_NAME      = "baseline.v1"


def bin_mode(bin_key):
    """Bin is 'long' if any valve in it is ETO-managed, else 'short'."""
    for part in bin_key.split("/"):
        try:
            sat, bit = part.split(":")
            bit = int(bit)
        except (ValueError, AttributeError):
            continue
        if (sat, bit) in ETO_VALVES:
            return "long"
    return "short"


def n_eto_valves(bin_key):
    n = 0
    for part in bin_key.split("/"):
        try:
            sat, bit = part.split(":")
            bit = int(bit)
        except (ValueError, AttributeError):
            continue
        if (sat, bit) in ETO_VALVES:
            n += 1
    return n


def ma_filter(samples, taps=MA_TAPS):
    """Causal moving average matching controller's FILTERED_HUNTER_VALVE."""
    out = []
    for t, _ in enumerate(samples):
        if t < taps - 1:
            out.append(None)
        else:
            out.append(sum(samples[t - taps + 1 : t + 1]) / taps)
    return out


def reduce_long(samples):
    """ma5 body_mean over t in [5, n - 2). Returns float or None."""
    n = len(samples)
    if n < MIN_TOTAL_LONG: return None
    filt = ma_filter(samples)
    body = [v for v in filt[FLOW_SKIP: n - TAIL_SKIP] if v is not None]
    if len(body) < MIN_BODY_FLOW: return None
    return sum(body) / len(body)


def reduce_short(samples):
    """Raw end-point sample. Returns float or None."""
    if len(samples) < MIN_TOTAL_SHORT: return None
    return float(samples[-1])


def kb3_noise_stats(runs, ref, holdout=2):
    """Walk historic runs (excluding the most recent `holdout`), compute the
    per-step filtered err = MA5(samples)[t] - ref across body window, and
    return {stdev, n_samples} characterizing that bin's intrinsic noise.

    Returns None if too little history.
    """
    if len(runs) < holdout + 2: return None
    hist = runs[:-holdout] if holdout > 0 else runs
    errs = []
    for r in hist:
        arr = (r.get("HUNTER_FLOW_METER") or {}).get("data") or []
        n = len(arr)
        if n < FLOW_SKIP + TAIL_SKIP + 3: continue
        filt = ma_filter(arr)
        for t in range(FLOW_SKIP, n - TAIL_SKIP):
            f = filt[t]
            if f is not None: errs.append(f - ref)
    if len(errs) < 30: return None
    if len(errs) > 1:
        mean = sum(errs) / len(errs)
        var  = sum((e - mean) ** 2 for e in errs) / len(errs)
        stdev = var ** 0.5
    else:
        stdev = 0.0
    return {"stdev": stdev, "n_samples": len(errs), "n_hist_runs": len(hist)}


def per_bin_baseline(bin_key, runs, window_n):
    """Return baseline dict for one bin, or None if unbuildable."""
    mode = bin_mode(bin_key)
    reducer = reduce_long if mode == "long" else reduce_short
    # Walk newest-first; take the most recent `window_n` valid reductions.
    window = []
    for r in reversed(runs):
        arr = (r.get("HUNTER_FLOW_METER") or {}).get("data") or []
        v = reducer(arr)
        if v is None: continue
        window.append(v)
        if len(window) >= window_n: break
    if len(window) < 2: return None
    window.reverse()   # oldest-first in stored order
    ref = st.median(window)
    ref_mad = st.median([abs(x - ref) for x in window])
    # typical_n_samples: median over the window of source-run sample count
    n_samples_list = []
    count_back = 0
    for r in reversed(runs):
        arr = (r.get("HUNTER_FLOW_METER") or {}).get("data") or []
        if reducer(arr) is None: continue
        n_samples_list.append(len(arr))
        count_back += 1
        if count_back >= window_n: break
    typical_n = int(st.median(n_samples_list)) if n_samples_list else 0
    out = {
        "mode": mode,
        "reducer": "ma5_body_mean_t5" if mode == "long" else "last_sample_raw",
        "ref": round(ref, 4),
        "ref_mad": round(ref_mad, 4),
        "window": [round(v, 4) for v in window],
        "n_runs_total": len(runs),
        "n_window": len(window),
        "typical_n_samples": typical_n,
        "n_eto_valves": n_eto_valves(bin_key),
    }
    # KB3 instantaneous-detector fields (long bins only — short bins are
    # end-point, no per-step curve to monitor).
    if mode == "long":
        ns = kb3_noise_stats(runs, ref)
        if ns is not None:
            stdev = ns["stdev"]
            kb3_thresh    = max(KB3_K_STDEV * stdev, KB3_THRESH_FLOOR)
            kb3_eligible  = (KB3_K_STDEV * stdev) <= KB3_NOISE_CAP
            out["kb3_stdev"]        = round(stdev, 4)
            out["kb3_threshold"]    = round(kb3_thresh, 3)
            out["kb3_eligible"]     = kb3_eligible
            out["kb3_consec"]       = 5
            out["kb3_noise_n"]      = ns["n_samples"]
        else:
            out["kb3_stdev"]        = None
            out["kb3_threshold"]    = None
            out["kb3_eligible"]     = False
            out["kb3_consec"]       = 5
            out["kb3_noise_n"]      = 0
    return out


def atomic_write_json(path, payload):
    """Write JSON to a temp file in the same dir, then rename."""
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_name(path.name + ".tmp")
    tmp.write_text(json.dumps(payload, indent=2, sort_keys=True))
    os.replace(tmp, path)


def main():
    ap = argparse.ArgumentParser()
    today_snap = ROOT / "snapshots" / DT.date.today().isoformat() / "time_history.json"
    ap.add_argument("--snap", default=str(today_snap),
                    help="path to time_history.json (default = today's snapshot)")
    ap.add_argument("--out", default=str(ROOT / "baseline_state" / "baselines.json"))
    ap.add_argument("--window", type=int, default=5,
                    help="rolling window size in runs (default 5)")
    ap.add_argument("--quiet", action="store_true")
    args = ap.parse_args()

    snap_path = Path(args.snap)
    if not snap_path.exists():
        print(f"ERROR: snapshot not found: {snap_path}", file=sys.stderr)
        sys.exit(1)
    th = json.loads(snap_path.read_text())

    # Canonicalize compound bin_keys by sorting their valve components.
    # time_history and past_actions stream compound keys in different valve
    # orders; baselines.json must use one canonical form so runtime lookup
    # is deterministic regardless of which stream observed the run.
    def canonical(k):
        return "/".join(sorted(k.split("/"))) if "/" in k else k

    bins_out = {}
    skipped = []
    for bin_key, runs in sorted(th.items()):
        if not runs:
            skipped.append((bin_key, "no_runs")); continue
        b = per_bin_baseline(bin_key, runs, args.window)
        if b is None:
            skipped.append((bin_key, "insufficient_history")); continue
        bins_out[canonical(bin_key)] = b

    payload = {
        "version":      SCHEMA_VERSION,
        "schema":       SCHEMA_NAME,
        "generated_at": DT.datetime.now().astimezone().isoformat(timespec="seconds"),
        "source_snap":  str(snap_path),
        "window":       args.window,
        "n_bins":       len(bins_out),
        "n_skipped":    len(skipped),
        "bins":         bins_out,
    }
    atomic_write_json(args.out, payload)

    if not args.quiet:
        print(f"wrote {args.out}")
        print(f"  {len(bins_out)} bins  ({sum(1 for b in bins_out.values() if b['mode']=='long')} long, "
              f"{sum(1 for b in bins_out.values() if b['mode']=='short')} short)")
        if skipped:
            print(f"  skipped {len(skipped)}: " +
                  ", ".join(f"{k}({why})" for k, why in skipped[:8]) +
                  ("..." if len(skipped) > 8 else ""))


if __name__ == "__main__":
    main()
