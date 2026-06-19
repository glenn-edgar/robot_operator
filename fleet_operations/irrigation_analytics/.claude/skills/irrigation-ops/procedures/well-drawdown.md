# Procedure: Well drawdown — detect & recover

**The exemplar procedure.** Detect the well drawing down and, if armed, recharge it
(1:39 city-water wait) + skip the step over-drawing it. Physics: see
`references/system-model.md` § "Well drawdown". Access: `references/data-access.md`.

---

## TRIGGER

Any of:
- A question about well health ("is the well OK?", "did the well run dry?", "why did
  the well draw down on 4:10?").
- A live high-draw step running with no preceding 1:39 recharge (scheduling-gap risk).
- A `WELL-DRAWDOWN` line in the KB3 logs (the in-robot detector fired).
- Investigating a past drawdown/collapse event.

If the request is a **question**, run through RULES and answer. If it's a request to
**recover** a live event, continue to ACTION + VERIFY (honoring the gates).

---

## INPUTS (pull before reasoning)

1. **Source flow trace, THIS run** — `main_flow_meter` (= PLC, the well source) from
   `PLC_MEASUREMENTS_STREAM` (db=4). Get the per-minute series for the active step.
   *Use PLC, not FILTERED_HUNTER — HUNTER lags and droops even when the well is fine.*
2. **Run position** — `popup` (db=4): current `step`, `schedule_name`, elapsed minute,
   the step's `run_time`.
3. **Cycle capacity** — prior stations' plateaus this cycle (rolling median of their
   early-run PLC level). From the KB3 state or recompute from `PLC_MEASUREMENTS_STREAM`
   over the cycle's steps (delineate the cycle via `PAST_ACTIONS`
   `IRRIGATION_STEP_COMPLETE` since cycle start).
4. **HUNTER trace** (for the SEVERE tag) — `FILTERED_HUNTER_VALVE`, same window.

Commands for all of the above: `references/data-access.md` § Redis.

---

## RULES (cite the number; don't eyeball)

Let `plateau` = the source's own early-run level (median of PLC over **min 5–12**, the
PLATEAU_FROM/TO window). These thresholds are the tuned production values:

| Test | Threshold | Meaning |
|---|---|---|
| Warmup skip | minute < `WARMUP_MIN` (5) | too early to judge; ignore |
| Below-fraction | PLC < `DRAW_FRAC` × plateau, `DRAW_FRAC = 0.78` | source has sagged below its own early level |
| Windowed fire | 3 of the last 4 minutes below-fraction (`WINDOW=4`, `WINDOW_HITS=3`) | handles the dying-well sawtooth |
| OR onset fire | `ONSET_CONSEC = 2` consecutive below | faster fire on a clean drop |
| SEVERE tag | HUNTER also drops ≥ `HUN_DROP` (1.5) | real loss, not noise |
| Completion guard | skip if `run_time − minute ≤ GUARD_REMAIN_MIN` (1) | step nearly done — don't bother |
| Floor | PLC ≤ ~1 GPM is the meter floor | sub-floor = no data, not "well dead" |
| Internal-leak early warning | PLC − HUNTER divergence ≥ `IL_DIV_ABS` (3.5) sustained `IL_SUSTAIN` (2) | supply break over-drawing — the EARLY drawdown warning (logged, not an actuation) |

**Decision:** if (windowed fire OR onset fire) AND NOT completion-guard AND plateau is
above floor → **drawdown confirmed**. SEVERE if HUNTER also dropped.

For a **question**, report: did it draw down, when (which minute), how far below plateau,
SEVERE or not, and the likely root cause (internal-leak over-draw vs scheduling gap —
check whether a 1:39 recharge preceded this step).

---

## ACTION (only on a recover request; honors the gates)

**GATES — all must hold or you only log "WOULD":**
- `KB3_WELL_ARM=1` (this automation is armed) AND `SKIP_LIVE=1` (writes go live).
- You are the **sole armed actor** (Safety Rule 1) — no other armed instance.
- Completion guard did not fire.

Sequence (the robot does this automatically when armed; do it manually only to
recover a live event the robot didn't, and only when you're certain):

1. **Recharge first** — rpush the 15-min 1:39 city-water `wait` so the well rests and
   recovers, running NEXT. → `actions/rpush-recharge.md`.
2. **Then skip** the over-drawing step. → `actions/skip-station.md`.

Order matters: recharge is queued to run NEXT, *then* the current over-drawing step is
ended, so the well immediately gets its rest step instead of the next high-draw bank.

---

## VERIFY

1. **Recharge landed:** the `wait` job is at `IRRIGATION_PENDING` index **-1** (the
   rpop/front side — runs next). Check via `references/data-access.md` redis.
2. **Step skipped:** `popup` shows the step advanced; `PAST_ACTIONS` has the SKIP.
3. **Log line** (armed): KB3 logs
   `WELL-DRAWDOWN ARMED ... rpush wait → ok=<code> SKIP_STATION → ok=<code>`.
4. **Back-out** (if it fired wrongly): delete the `wait` job from `IRRIGATION_PENDING`
   (it's just one list entry), and disarm with `KB3_WELL_ARM=0` in the Pi `fleet.env`
   + restart. Easy to reverse — that's why it's safe to arm.
5. **Record** the event in `memory/` if it's the first live actuation or it revealed a
   tuning gap.
