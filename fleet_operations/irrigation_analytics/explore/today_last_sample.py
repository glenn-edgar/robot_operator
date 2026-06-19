#!/usr/bin/env python3
"""
Today's-runs last-sample current analyzer.

Drives off past_actions (authoritative index of what ran today) cross-
referenced against TIME_HISTORY (per-run sample arrays).

For each STATION_START / STEP_COMPLETE pair today:
  bin_key  = canonicalize(io_setup)
  run_time = past_actions step_complete.run_time
  samples  = IRRIGATION_CURRENT.data from matching TIME_HISTORY run
             (last N runs for this bin, where N = count today; bin order
              is append-order so newest N == today's runs)
  end_mean = mean(samples[-3:])   if len(samples) >= 3 else samples[-1]
  delta_mu = end_mean - kb1_thresholds.per_bin[bin_key].mu_i_asym
                                  (None if bin uncalibrated)

Output:
  - Per-run line: schedule:step  bin_key  cal? run_time end_mean ΔμA flags
  - Summary: top |Δ| per bin, run-time vs samples-len mismatch warnings.

Units: run_time in past_actions is **MINUTES**; TIME_HISTORY samples
are 1/min (so ic_len ≈ run_time_min). Short = ≤ 5 min runs today.
All today's runs are well past the 120 s popup-current warm-up; ALL
samples here are steady-state.

Run via:  python3 today_last_sample.py
"""
import json
import statistics as st
import subprocess
import sys
from collections import defaultdict
from pathlib import Path

ROOT = Path(__file__).parent
THRESHOLDS = ROOT / "kb1_thresholds.json"

PULL_PAST_PY = r"""
import redis, msgpack, json, sys, datetime as DT
PAST_DB = 4
PAST_KEY = ("[SYSTEM:main_operations][SITE:LaCima][APPLICATION_SUPPORT:APPLICATION_SUPPORT]"
            "[IRRIGIGATION_SCHEDULING_CONTROL:IRRIGIGATION_SCHEDULING_CONTROL]"
            "[PACKAGE:IRRIGIGATION_SCHEDULING_CONTROL_DATA][STREAM_REDIS:IRRIGATION_PAST_ACTIONS]")
today = DT.datetime.now().astimezone().date()
midnight = DT.datetime.combine(today, DT.time(0,0)).astimezone()
min_ms = int(midnight.timestamp() * 1000)
r = redis.Redis(db=PAST_DB)
ents = r.xrange(PAST_KEY, min=f"{min_ms}-0", max='+', count=10000)
runs = []
opens = []
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
            if sdet.get("step") == det.get("step") and sdet.get("schedule_name") == det.get("schedule_name"):
                runs.append({
                    "start_id": ssid,
                    "end_id": sid.decode(),
                    "start_ms": int(ssid.split("-")[0]),
                    "schedule": det.get("schedule_name"),
                    "step": det.get("step"),
                    "run_time_s": det.get("run_time"),
                    "io_setup": det.get("io_setup"),
                })
                opens.pop(i); break
sys.stdout.write(json.dumps(runs, default=str))
"""

PULL_TH_PY = r"""
import redis, msgpack, json, sys
TH_DB = 4
TH_KEY = ("[SYSTEM:main_operations][SITE:LaCima][APPLICATION_SUPPORT:APPLICATION_SUPPORT]"
          "[IRRIGIGATION_SCHEDULING_CONTROL:IRRIGIGATION_SCHEDULING_CONTROL]"
          "[PACKAGE:IRRIGIGATION_SCHEDULING_CONTROL_DATA][HASH:IRRIGATION_TIME_HISTORY]")
import sys
bins = json.loads(sys.stdin.read())
r = redis.Redis(db=TH_DB)
out = {}
for b in bins:
    v = r.hget(TH_KEY, b)
    if not v: continue
    runs = msgpack.unpackb(v, raw=False)
    # Pull last 25 runs per bin (enough for today + history context)
    slim = []
    for run in runs[-25:]:
        ic = (run.get("IRRIGATION_CURRENT") or {}).get("data") or []
        ec = (run.get("EQUIPMENT_CURRENT") or {}).get("data") or []
        slim.append({"ic": ic, "ec": ec})
    out[b] = slim
sys.stdout.write(json.dumps(out, default=str))
"""


def ssh_python(code, stdin=None, timeout=20):
    r = subprocess.run(
        ["ssh", "-o", "ConnectTimeout=8", "-o", "BatchMode=yes",
         "pi@irrigation", "python3", "-"],
        input=(code if stdin is None else code + "\n" + stdin),
        capture_output=True, text=True, timeout=timeout,
    )
    if r.returncode != 0:
        sys.stderr.write(f"ssh failed: {r.stderr}\n"); sys.exit(2)
    return r.stdout


def ssh_python_with_input(code, payload, timeout=30):
    # Write code+payload to temp; cleaner than two-stage.
    import tempfile, os
    with tempfile.NamedTemporaryFile("w", suffix=".py", delete=False) as f:
        f.write(code); path = f.name
    try:
        r = subprocess.run(
            ["ssh", "-o", "ConnectTimeout=8", "-o", "BatchMode=yes",
             "pi@irrigation", "python3", "-"],
            input=open(path).read(),
            capture_output=True, text=True, timeout=timeout,
        )
    finally:
        os.unlink(path)
    return r


def canonicalize_io(io_setup):
    """Sort+join into satellite_X:N[/satellite_Y:M] bin key."""
    if not io_setup: return "?"
    parts = []
    for s in io_setup:
        rem = s.get("remote", "?")
        for b in (s.get("bits") or []):
            parts.append(f"{rem}:{b}")
    parts.sort()
    return "/".join(parts)


def main():
    # 1) Pull today's runs from past_actions
    raw = ssh_python(PULL_PAST_PY)
    runs = json.loads(raw)
    print(f"Today's runs: {len(runs)}")

    # Annotate with bin_key
    for r in runs:
        r["bin_key"] = canonicalize_io(r["io_setup"])

    # 2) Pull TIME_HISTORY for all unique bins
    unique_bins = sorted({r["bin_key"] for r in runs})
    th_code_with_input = PULL_TH_PY.replace(
        'bins = json.loads(sys.stdin.read())',
        f'bins = {json.dumps(unique_bins)}'
    )
    raw_th = ssh_python(th_code_with_input)
    th = json.loads(raw_th)
    print(f"TIME_HISTORY bins fetched: {len(th)}")

    # 3) Load thresholds
    thresholds = {}
    if THRESHOLDS.exists():
        decoded = json.loads(THRESHOLDS.read_text())
        thresholds = decoded.get("per_bin", {})
    print(f"Calibrated bins in kb1_thresholds.json: {len(thresholds)}")

    # 4) For each bin, count today's runs and slice the last-N TH runs.
    today_per_bin = defaultdict(list)
    for r in runs:
        today_per_bin[r["bin_key"]].append(r)

    # Match: take last len(today_runs) TH runs as today's runs
    enriched = []
    mismatches = []
    for bin_key, today_runs in today_per_bin.items():
        th_runs = th.get(bin_key, [])
        n = len(today_runs)
        if len(th_runs) < n:
            mismatches.append((bin_key, f"only {len(th_runs)} TH runs for {n} past_action runs"))
            continue
        slice_today = th_runs[-n:]   # newest n
        # past_actions today_runs are also in chronological order
        today_runs_sorted = sorted(today_runs, key=lambda r: r["start_ms"])
        for pa, th_run in zip(today_runs_sorted, slice_today):
            ic = th_run.get("ic", [])
            ec = th_run.get("ec", [])
            # Sanity check: len(ic) should roughly match run_time
            length_mismatch = abs(len(ic) - (pa["run_time_s"] or 0)) > 2
            if length_mismatch:
                mismatches.append((bin_key, f"step={pa['step']} run_time={pa['run_time_s']}s, ic_len={len(ic)}"))
            last3 = ic[-3:] if len(ic) >= 3 else ic
            end_mean = (sum(last3)/len(last3)) if last3 else None
            last_eq = (sum(ec[-3:])/len(ec[-3:])) if len(ec) >= 3 else (ec[-1] if ec else None)
            # Exact-bin match only. Compound bins (a/b/c) need their own
            # calibration; falling back to the first valve's μ would compare
            # a 2-valve run against a 1-valve baseline (spurious ~11σ).
            calib = thresholds.get(bin_key)
            is_compound = "/" in bin_key
            # For compound bins: synthesize μ as sum of solo μs when all
            # parts are calibrated (rough; not the true ground truth, but
            # better than skipping or single-valve fallback). Use sd in
            # quadrature.
            if calib is None and is_compound:
                parts = bin_key.split("/")
                solo_calibs = [thresholds.get(p) for p in parts]
                if all(c and c.get("mu_i_asym") is not None for c in solo_calibs):
                    syn_mu = sum(c["mu_i_asym"] for c in solo_calibs)
                    sds = [c.get("sd_i_asym") or 0 for c in solo_calibs]
                    syn_sd = (sum(s*s for s in sds)) ** 0.5 if any(sds) else None
                    calib = {"mu_i_asym": syn_mu, "sd_i_asym": syn_sd,
                             "_synthesized": True}
            mu = calib.get("mu_i_asym") if calib else None
            sd = calib.get("sd_i_asym") if calib else None
            delta = (end_mean - mu) if (end_mean is not None and mu is not None) else None
            z = (delta / sd) if (delta is not None and sd and sd > 0) else None
            enriched.append({
                "schedule": pa["schedule"],
                "step": pa["step"],
                "bin_key": bin_key,
                "run_time_s": pa["run_time_s"],
                "ic_len": len(ic),
                "end_mean": end_mean,
                "mu": mu,
                "sd": sd,
                "delta": delta,
                "z": z,
                "last_eq": last_eq,
                "calibrated": calib is not None,
                "synthesized": bool(calib and calib.get("_synthesized")),
                "length_mismatch": length_mismatch,
            })

    # 5) Print per-run table sorted chronologically
    enriched_sorted = sorted(enriched, key=lambda r: (r["schedule"], r["step"]))

    print()
    print(f"=== Today's {len(enriched)} short runs: end-current (mean of last 3 samples; 1/min sampling) ===")
    print()
    hdr = (f"  {'schedule':<14s} {'step':>4s}  {'bin_key':<32s} "
           f"{'cal':>3s} {'rt_m':>4s} {'n_s':>3s}  "
           f"{'end_A':>6s} {'μ_A':>6s} {'Δ_A':>7s} {'z':>5s}  {'eq_A':>5s}  flags")
    print(hdr)
    print("  " + "-" * (len(hdr) - 2))
    for r in enriched_sorted:
        flags = []
        if r["length_mismatch"]:
            flags.append("LEN")
        if r["z"] is not None:
            if abs(r["z"]) >= 3.0: flags.append("HIGH_Z")
            elif abs(r["z"]) >= 2.0: flags.append("WARN_Z")
        if r["delta"] is not None and r["delta"] < -0.2:
            flags.append("LOW")
        if r["end_mean"] is not None and r["end_mean"] >= 1.75:
            flags.append("TRIP")
        cal = ("S" if r["synthesized"] else "Y") if r["calibrated"] else " "
        mu = f"{r['mu']:.3f}" if r["mu"] is not None else "    —"
        delta = f"{r['delta']:+.3f}" if r["delta"] is not None else "     —"
        z = f"{r['z']:+.2f}" if r["z"] is not None else "   —"
        end = f"{r['end_mean']:.3f}" if r["end_mean"] is not None else "    —"
        eq = f"{r['last_eq']:.2f}" if r["last_eq"] is not None else "  —"
        print(f"  {r['schedule']:<14s} {r['step']:>4d}  {r['bin_key']:<32s} "
              f"{cal:>3s} {r['run_time_s']:>4d} {r['ic_len']:>3d}  "
              f"{end:>6s} {mu:>6s} {delta:>7s} {z:>5s}  {eq:>5s}  {','.join(flags)}")

    # 6) Mismatches
    if mismatches:
        print()
        print(f"=== Mismatches ({len(mismatches)}) — past_action vs TIME_HISTORY length/count issues ===")
        for mb, msg in mismatches[:20]:
            print(f"  {mb:<32s} {msg}")

    # 7) Per-bin summary across today's runs (median delta, max |z|)
    by_bin = defaultdict(list)
    for r in enriched:
        by_bin[r["bin_key"]].append(r)
    print()
    print(f"=== Per-bin summary across today's repeats (sorted by max |z|) ===")
    rows = []
    for bk, rs in by_bin.items():
        deltas = [r["delta"] for r in rs if r["delta"] is not None]
        zs     = [r["z"]     for r in rs if r["z"]     is not None]
        ends   = [r["end_mean"] for r in rs if r["end_mean"] is not None]
        if not ends: continue
        rows.append({
            "bin_key": bk,
            "n": len(rs),
            "cal": rs[0]["calibrated"],
            "end_med":  st.median(ends),
            "end_min":  min(ends),
            "end_max":  max(ends),
            "delta_med": st.median(deltas) if deltas else None,
            "z_max":     max((abs(z) for z in zs), default=None),
        })
    rows.sort(key=lambda r: -(r["z_max"] or 0))
    print(f"  {'bin_key':<32s} {'n':>2s} {'cal':>3s}  "
          f"{'end_med':>7s} {'end_min':>7s} {'end_max':>7s} "
          f"{'Δmed':>7s} {'|z|max':>6s}")
    print("  " + "-" * 84)
    for r in rows:
        zm = f"{r['z_max']:.2f}" if r['z_max'] is not None else "   —"
        dm = f"{r['delta_med']:+.3f}" if r['delta_med'] is not None else "     —"
        print(f"  {r['bin_key']:<32s} {r['n']:>2d} {('Y' if r['cal'] else ' '):>3s}  "
              f"{r['end_med']:>7.3f} {r['end_min']:>7.3f} {r['end_max']:>7.3f} "
              f"{dm:>7s} {zm:>6s}")


if __name__ == "__main__":
    main()
