#!/usr/bin/env python3
"""
Build a per-valve R-history series from the daily resistance scan.

Output: stitched_r_history.json
  {
    "satellite_X:pin": {
      "cold":     [{"ord": int, "r": float, "source": "cold_d<n>"}, ...],
      "stitched": [{"ord": int, "r": float, "source": "cold"}, ...]
    }
  }

Ordinal scale:
  ord = 0   → today (newest cold-R)
  ord = -n  → n days ago

Hot-R from time_history runs is intentionally NOT included here. Run current
is parallel(zone, master) ≈ 20Ω, not single-valve. Including it produces
spurious "jumps" at the hot/cold seam. See memory:
[[master-valve-parallel-correction-2026-05-27]].
"""
import json
import statistics
from pathlib import Path
from collections import defaultdict

V_SUPPLY = 15.5
ACS712_OFFSET = 0.0133
NONEXISTENT = {"satellite_1:1", "satellite_1:28", "satellite_1:38",
               "satellite_1:40", "satellite_3:1", "satellite_4:6"}  # 6 phantom null-anchors
WIRE_OFFSET_OHMS = {**{f"satellite_2:{p}": 10.0 for p in (13, 14, 15, 16, 17)},
                    **{f"satellite_3:{p}":  3.0 for p in (11, 12, 13, 14, 15, 16, 17, 18)}}
PARALLEL_PAIRS = {"satellite_1:44"}

# Phantom-pin offset normalization (backlog item 1 from daily-review-workflow).
# Cross-day R noise is dominated by ACS712 null drift — the 6 NONEXISTENT pins
# read (LEAKAGE_THROUGH_200OHM + ACS712_NULL) each cycle, so cycle-to-cycle
# changes in their median directly reflect drift in the sensor null.
#
# REF_PHANTOM = phantom median at the calibration anchor point (ACS712_OFFSET
# was anchored to sat_2:4 = 35 Ω at that time). Computed as
#   leakage_through_200Ω = 15.5 / 200 = 0.0775
# plus the calibration-time ACS712 null 0.0133, gives 0.0908. Per-ord effective
# offset is then ACS712_OFFSET + (phantom_at_ord − REF_PHANTOM), which centres
# the rolling-window R values on the calibration anchor and removes drift.
REF_PHANTOM = 0.0908


def phantom_offsets(vt: dict, n: int) -> list[float]:
    """Per-ordinal effective offset, length n. Falls back to ACS712_OFFSET
    when a given ordinal has no phantom samples."""
    out: list[float] = []
    for k in range(n):
        vals = [vt[v][k] for v in NONEXISTENT
                if vt.get(v) and len(vt[v]) > k and vt[v][k] is not None]
        if vals:
            vals.sort()
            mid = vals[len(vals) // 2] if len(vals) % 2 else \
                  0.5 * (vals[len(vals)//2 - 1] + vals[len(vals)//2])
            out.append(ACS712_OFFSET + (mid - REF_PHANTOM))
        else:
            out.append(ACS712_OFFSET)
    return out


def corr_r(valve: str, i_amps: float, offset: float = ACS712_OFFSET) -> float | None:
    """Convert measured current to corrected R using a per-cycle offset."""
    i_true = i_amps - offset
    if i_true <= 1e-4:
        return None
    r = V_SUPPLY / i_true - WIRE_OFFSET_OHMS.get(valve, 0.0)
    if valve in PARALLEL_PAIRS:
        r *= 2.0
    if not (5.0 < r < 500.0):
        return None
    return r


def asymptote(samples: list[float]) -> float | None:
    """Mean of last 3 non-zero samples — skip sample[0] timing-race per characterize_runs."""
    # Trim trailing zeros (post-close)
    n = len(samples)
    while n > 0 and samples[n-1] <= 1e-6:
        n -= 1
    samples = samples[:n]
    # Skip sample[0] — known timing race (σ=0.153 vs 0.005 at sample[1])
    if len(samples) < 4:
        return None
    tail = samples[-3:]
    return statistics.mean(tail)


def main():
    here = Path(__file__).parent
    vt = json.loads((here / "data" / "valve_test.json").read_text())

    n_buf = max((len(v) for v in vt.values()), default=0)
    offsets = phantom_offsets(vt, n_buf)

    out: dict[str, dict] = {}
    for valve, daily_series in vt.items():
        cold: list[dict] = []
        n_cold = len(daily_series)
        for i, i_amps in enumerate(daily_series):
            ord_pos = -(n_cold - 1 - i)
            off = offsets[i] if i < len(offsets) else ACS712_OFFSET
            r      = corr_r(valve, i_amps, off)            # normalized
            r_raw  = corr_r(valve, i_amps, ACS712_OFFSET)  # fixed-offset (legacy)
            if r is None:
                continue
            cold.append({"ord": ord_pos, "r": round(r, 3),
                         "r_raw": round(r_raw, 3) if r_raw is not None else None,
                         "offset_at_ord": round(off, 5),
                         "source": f"cold_d{-ord_pos}"})

        stitched = [{"ord": e["ord"], "r": e["r"], "source": "cold"}
                    for e in cold]
        out[valve] = {"cold": cold, "stitched": stitched,
                      "n_cold": len(cold), "n_total": len(stitched)}

    out_path = here / "stitched_r_history.json"
    out_path.write_text(json.dumps(out, indent=2))

    print(f"\n=== R-history (cold-R only, 20-cycle window) ===")
    print(f"  valves: {len(out)}")
    print(f"\n  per-ordinal phantom offset (normalized to REF_PHANTOM={REF_PHANTOM:.4f}):")
    for k, off in enumerate(offsets):
        ord_pos = -(n_buf - 1 - k)
        print(f"    ord={ord_pos:>4}  offset={off:+.5f}  Δ_vs_anchor={off-ACS712_OFFSET:+.5f}")
    if "satellite_2:4" in out:
        print(f"\n  sat_2:4 (known recently-replaced) full series:")
        for r in out["satellite_2:4"]["stitched"]:
            raw = next((c["r_raw"] for c in out["satellite_2:4"]["cold"]
                        if c["ord"] == r["ord"]), None)
            raw_s = f"{raw:6.2f}" if raw is not None else "  ---"
            print(f"    ord={r['ord']:>4}  R={r['r']:6.2f}  (raw {raw_s})")
    print(f"\n  → {out_path}")


if __name__ == "__main__":
    main()
