# Action: SKIP_STATION (end the current step)

End the currently-running irrigation step; the controller advances its own queue.
Used by `procedures/well-drawdown.md` step 2 and by overcurrent/leak recovery.

## Safety gate
- Dry-run unless `SKIP_LIVE=1` (Safety Rule 2).
- Sole armed actor only (Safety Rule 1) — a **double** SKIP skips an extra innocent
  station. This is the concrete reason the one-armed-instance rule exists.
- Never `CLEAR` (empties the whole queue — Safety Rule 3). SKIP ends ONE step.
- In the robot: `lib/ws_command.lua` → `M.post("SKIP_STATION", {...})`. Prefer the
  armed robot; do it by hand only to recover a live event.

## The command
Creds = db=5 (`references/data-access.md`; **redact**). `-b ''` required (cookie
engine — same reason as the recharge action).

```bash
curl -sS --digest -u "$USER:$PASS" -b '' --max-time 8 \
  -H 'Content-Type: application/json' \
  -X POST -d '{"command":"SKIP_STATION","schedule_name":"","step":"","run_time":""}' \
  -o /dev/null -w '%{http_code}' \
  http://192.168.1.146/ajax/mode_change
```
Success = `200`. The controller's `op_mode` switch handles `SKIP_STATION` and advances
the queue itself.

## Verify
`popup` (db=4) shows the step advanced; `PAST_ACTIONS` has the SKIP entry.

## Back-out
A skip can't be un-skipped, but you can re-queue the skipped step via the controller's
schedule commands (`QUEUE_SCHEDULE_STEP`) if it was skipped in error. This is why SKIP
is gated behind arming + sole-actor: it's not free to reverse.
