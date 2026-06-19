# Procedure: Leak triage — internal vs external

Classify a flow anomaly and route it. INTERNAL over-draws the well (act); EXTERNAL is a
field break (log + watch). Physics: `references/system-model.md` § "Two leak types".

---

## TRIGGER
- A KB3 leak alert, a flow anomaly in the morning scan, "is X leaking?", or
  investigating a well over-draw.

---

## INPUTS (pull before reasoning)
1. **PLC + HUNTER traces** for the bin/run — `main_flow_meter` (PLC, well source) and
   `FILTERED_HUNTER_VALVE` from `PLC_MEASUREMENTS_STREAM` (db=4). HUNTER lags (filtered).
2. **HUNTER baseline** for the bin — the bin's clean HUNTER level (kb4 baselines / recent
   OK runs).
3. **Recent runs for statistics** — pull the last ~9 runs. **Caveat:** many runs may
   themselves contain breaks, so estimate the clean HUNTER from the lower-envelope good
   runs (Glenn's "filtered hunter ~8 GPM" estimate came this way). Need enough GOOD runs
   to trust the stat.
4. **Floor check** — is the bin sub-floor (`phantom=1`)? If so its ~0 read is NO DATA.

---

## RULES
| Observation | Class | Why |
|---|---|---|
| **PLC ≫ HUNTER** (divergence ≥ `IL_DIV_ABS`≈3.5 sustained ≥`IL_SUSTAIN`≈2) | **INTERNAL** | loss *between* meters = supply-line break; **over-draws the well** = the early drawdown warning |
| **HUNTER > baseline + ~5** | **EXTERNAL** | loss *past* meters = broken/over-flowing field head |
| flow DOWN vs baseline | **NOT a leak** | that's a clog → `procedures/blocked-sprinkler.md` |
| sub-floor (`phantom=1`) reads ~0 | **NO DATA** | meter floor, not a fault |

A leak pushes flow UP; a clog pushes it DOWN — don't confuse them. An internal leak is
*also* the earliest signal that the well is about to draw down.

---

## ACTION
- **INTERNAL on a live over-draw** → run `procedures/well-drawdown.md` (recharge the
  well via `actions/rpush-recharge.md`, then `actions/skip-station.md`). Gates apply.
- **EXTERNAL** → no controller action. Add the bin to `watch_list` (kb4), confirm on the
  next cycle of that schedule, and flag for **field repair** (human). Once repaired,
  the operator logs it via `procedures/field-check-reset.md` (`repair_leak`).
- **Operator scheduling option:** a persistently-leaking bank may be held OUT of the
  schedule until repaired (this is a manual controller-schedule edit, not an automation —
  e.g. 4:10 is currently held out). Note any such hold in `memory/state.md`.

---

## VERIFY
- Internal/actuated → same as `procedures/well-drawdown.md` VERIFY (wait at index -1,
  step skipped, log line, back-out path).
- External/watched → `watch_list` row present; re-check next cycle to confirm it's real
  (not a one-run transient). Record a confirmed leak in `memory/state.md`.
