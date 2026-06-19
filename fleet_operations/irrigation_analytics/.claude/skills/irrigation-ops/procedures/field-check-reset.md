# Procedure: Field-check reset — close the human→detector loop

After a human does field maintenance, log the action so the affected detector baselines
reset (else they stay stale and false-flag, or mask the change). The reset is applied by
the armed `FIELD_LOG_ARM` watcher in kb4_clog. Physics: `references/system-model.md`
§ "Baselines: gated running median".

---

## TRIGGER
- A human did physical work on a bin: capped/cleaned heads, replaced a valve/solenoid,
  repaired a leak, or inspected-OK. You're told (e.g. "4:10's coyote leak is repaired").
- The held-out ⭐ 4:10 field-check update (see `memory/state.md`) lands here.

---

## INPUTS
- **Which bin** (e.g. `satellite_4:10`) and **what was done** (the action).
- Map the action to its reset effect (next section). If unsure which action fits, ask
  the human what was physically changed — the reset depends on it.

---

## RULES — action → reset map
| Action logged | Reset the watcher applies |
|---|---|
| `cap_heads` | rebaseline flow from POST-change runs (DEFERS until ≥2 such runs); `phantom=1` if now sub-floor |
| `clean_heads` | clear flow baseline + watch → re-learn UP |
| `replace_valve` | reset coil (`coil_onset`) + resistance (KB2) + flow baselines |
| `replace_solenoid` | reset coil + resistance baselines |
| `repair_leak` | clear the leak `watch_list` entry → re-learn (applies IMMEDIATELY) |
| `inspect_ok` / `other` | record only, no auto-reset |

Two things to know:
- **Catch-22 handled:** the watcher recomputes flow medians DIRECTLY from post-change
  runs (ignoring `cls`), because post-change runs would otherwise be judged against the
  OLD baseline. That's why `cap_heads`/`replace_*` **defer** until ≥2 post-change runs.
- **Moderate changes self-heal** via the gated running median anyway — so the watcher's
  real job is changes too LARGE for the median, or those needing a phantom/coil/
  resistance reset.

---

## ACTION
Log the action via the dashboard field-check form → the armed watcher does the reset.
→ `actions/field-check-log.md`. (Gate: `FIELD_LOG_ARM=1`; otherwise it records monitor-
only and logs `WOULD`.)

---

## VERIFY
- Watch kb4_clog logs for `MANUAL-LOG [APPLIED]` (immediate, e.g. `repair_leak`) or
  `MANUAL-LOG [deferred]` (waiting for post-change runs, e.g. `cap_heads`):
  `ssh robot 'docker logs irrigation-analytics 2>&1 | grep MANUAL-LOG | tail'`.
- Confirm the effect: the baseline/`watch_list`/coil row changed (query `kb4.db`), and
  `clog_observations.action_applied=1` + a `manual_reset_log` row (idempotent — won't
  re-reset).
- For 4:10 specifically: `repair_leak` clears the watch now; `cap_heads`/`replace_*`
  defer until 4:10 runs again post-repair. Update `memory/state.md` to clear 4:10 from
  the open-faults list once applied.
