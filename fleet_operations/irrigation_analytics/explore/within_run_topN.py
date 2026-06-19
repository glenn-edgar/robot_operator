#!/usr/bin/env python3
"""
Top-N within-run candidates in 5/29 (last night) — solo + paired bins.

Gate-less ranking by |split_delta|. Find the pipe-break event the user
says is in last night's data.

Also flags drastic run-length changes 5/28 → 5/29 (a pipe break can
cause a controlled-cutoff if the controller has a flow-volume limit).
"""
import json
import statistics as st
from pathlib import Path

STARTUP_SKIP = 2
MIN_BODY_LEN = 6
MIN_HALF     = 3

ROOT = Path(__file__).parent


def median(xs):
    return st.median(xs) if xs else None


def within_features(steps):
    if not steps or len(steps) < STARTUP_SKIP + MIN_BODY_LEN:
        return None
    body = steps[STARTUP_SKIP:]
    if len(body) < MIN_BODY_LEN:
        return None
    best = None
    best_abs = -1.0
    for i in range(MIN_HALF, len(body) - MIN_HALF + 1):
        a = median(body[:i])
        b = median(body[i:])
        gap = abs(b - a)
        if gap > best_abs:
            best_abs = gap
            best = (i + STARTUP_SKIP, a, b, b - a)
    if best is None:
        return None
    idx, a, b, delta = best
    return {
        "n": len(body),
        "split_at": idx,
        "early": a,
        "late": b,
        "delta": delta,
    }


def main():
    d28 = json.loads((ROOT / "snapshots" / "2026-05-28" / "time_history.json").read_text())
    d29 = json.loads((ROOT / "snapshots" / "2026-05-29" / "time_history.json").read_text())

    all_bins = sorted(d29.keys())

    rows = []
    for k in all_bins:
        runs28 = d28.get(k, [])
        runs29 = d29[k]
        if not runs29:
            continue
        steps28 = runs28[-1].get("HUNTER_FLOW_METER", {}).get("data") if runs28 else None
        steps29 = runs29[-1].get("HUNTER_FLOW_METER", {}).get("data")
        f28 = within_features(steps28) if steps28 else None
        f29 = within_features(steps29) if steps29 else None
        if f29 is None:
            continue
        len28 = len(steps28) if steps28 else 0
        len29 = len(steps29)
        same = (steps28 == steps29)
        rows.append({
            "bin": k,
            "f28": f28,
            "f29": f29,
            "len28": len28,
            "len29": len29,
            "steps29": steps29,
            "steps28": steps28,
            "same": same,
            "is_paired": "/" in k,
        })

    # Top 15 by 5/29 |delta|
    rows.sort(key=lambda r: -abs(r["f29"]["delta"]))

    print("\n=== Top 15 within-run candidates in 5/29 (all bins, no gate) ===")
    print(f"  {'bin':<38s} {'n':>3s} {'idx':>3s} {'early':>5s} {'late':>5s} {'Δ':>5s}  {'same?':<5s}  {'5/28 Δ':>7s}")
    print("  " + "-" * 88)
    for r in rows[:15]:
        f = r["f29"]
        d28v = f"{r['f28']['delta']:+.1f}" if r["f28"] else "  —"
        print(f"  {r['bin']:<38s} {f['n']:>3d} {f['split_at']:>3d} "
              f"{f['early']:>5.1f} {f['late']:>5.1f} {f['delta']:>+5.1f}  "
              f"{'same' if r['same'] else 'new':<5s}  {d28v:>7s}")

    # Drastic run-length changes
    print("\n=== Run-length day-over-day changes (>= 5-step shift) ===")
    rows.sort(key=lambda r: -abs(r["len29"] - r["len28"]))
    flagged = [r for r in rows if abs(r["len29"] - r["len28"]) >= 5 and r["len28"] > 0]
    for r in flagged[:15]:
        steps29_summary = f"[{r['steps29'][0]:.0f},...{r['steps29'][-1]:.0f}]" if r["steps29"] else "—"
        print(f"  {r['bin']:<38s}  len28={r['len28']:>3d}  len29={r['len29']:>3d}  "
              f"Δlen={r['len29']-r['len28']:+4d}  newest_total={sum(r['steps29']):.0f}")

    # Show full series for top candidate
    if rows:
        rows.sort(key=lambda r: -abs(r["f29"]["delta"]))
        top = rows[0]
        if not top["same"] and abs(top["f29"]["delta"]) >= 1.0:
            print(f"\n=== Full series for top NEW candidate: {top['bin']} ===")
            print(f"  5/28 ({top['len28']} steps): {top['steps28']}")
            print(f"  5/29 ({top['len29']} steps): {top['steps29']}")


if __name__ == "__main__":
    main()
