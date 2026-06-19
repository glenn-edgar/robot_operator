# Action: Log a field-check (triggers the baseline reset)

Record a field-maintenance action against a bin via the dashboard form. The armed
`FIELD_LOG_ARM` watcher in kb4_clog then applies the matching baseline reset. Used by
`procedures/field-check-reset.md`.

## Safety gate
- The watcher applies resets only when `FIELD_LOG_ARM=1` (see `memory/state.md`).
  Otherwise it records monitor-only and logs `WOULD rebaseline...` — safe, no change.
- Resets are **auditable + reversible + idempotent**: each is logged with the triggering
  `clog_observations` row; `action_applied=1` + `manual_reset_log` prevent re-applying.
- This is the SAFE side of the human→detector loop — it only ever resets a baseline (re-
  learn), never actuates a valve. No queue write, no SKIP.

## How to log it
The dashboard field-check form: **`http://192.168.1.66:28080/irrigation/check`**. For the
bin, pick the **Action** dropdown value, submit. Valid actions:
`inspect_ok` / `clean_heads` / `cap_heads` / `replace_valve` / `replace_solenoid` /
`repair_leak` / `other`.

This writes `clog_observations.action` (+ `action_applied=0`) in `kb4.db`. On its next
tick the watcher (`lib/field_log.lua`, in kb4_clog) scans for rows with `action != ''`
and `action_applied=0` not already in `manual_reset_log`, and applies the reset from the
action→reset map (`procedures/field-check-reset.md`).

## Verify
```
ssh robot 'docker logs irrigation-analytics 2>&1 | grep MANUAL-LOG | tail'
```
- `MANUAL-LOG [APPLIED] ...` — reset done (immediate actions like `repair_leak`).
- `MANUAL-LOG [deferred] ...` — waiting for ≥2 post-change runs (`cap_heads`/`replace_*`).
- Then confirm the baseline/watch/coil row actually changed in `kb4.db`, and
  `action_applied=1`.

## Back-out
A reset just clears/recomputes a baseline — the detector re-learns from subsequent runs.
To undo a wrong action entry, set its `clog_observations.action_applied` and the
`manual_reset_log` row so it won't re-fire, and let the baseline re-learn (or restore a
pre-change baseline from a snapshot if one was taken).
