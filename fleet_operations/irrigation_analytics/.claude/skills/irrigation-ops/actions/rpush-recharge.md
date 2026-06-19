# Action: rpush the well-recharge wait (queue NEXT)

Insert a 15-min `sat 1:39` city-water `wait` so the well rests/recovers, running as
the **next** job. Used by `procedures/well-drawdown.md` step 1.

## Safety gate
- Dry-run unless `SKIP_LIVE=1` (Safety Rule 2). With it off: **log "WOULD POST", do
  nothing.**
- Only when you are the sole armed actor (Safety Rule 1).
- In the robot this is `lib/ws_command.lua` → `M.queue_front(body, opts)`; it already
  honors the `SKIP_LIVE` gate and the auth below. Prefer letting the armed robot do it.
  Do it by hand only to recover a live event the robot missed.

## The wait job (byte-matched to a live IRRIGATION_PENDING entry)
```json
{"type":"IRRIGATION_STEP","schedule_name":"wait","step":0,"io_setup":[{"remote":"satellite_1","bits":[39]}],"run_time":15,"elasped_time":0,"eto_enable":false,"eto_list":null,"eto_flag":false}
```
Notes: `elasped_time` is misspelled **on purpose** (matches the controller's wire
format). `io_setup` is a list of `{remote,bits}` dicts. `sat 1:39` = city water (no
well draw), 15 min → the well rests.

## How it reaches the queue
NOT a raw redis write. POST the job to the controller route
**`/ajax/irrigation_queue_front`**, whose handler does
`redis_handle.rpush(IRRIGATION_PENDING, msgpack.packb(json, use_bin_type=True))`.
`rpush` = tail = the `rpop`/front side = **runs NEXT**.

## The command (HTTP Digest + empty cookie engine)
Creds = `admin:pass` from redis db=5 (`references/data-access.md`; **redact** them).
`-b ''` is REQUIRED — Flask binds the digest nonce to the session cookie; without it
you get `Unauthorized Access`.

```bash
curl -sS --digest -u "$USER:$PASS" -b '' --max-time 8 \
  -H 'Content-Type: application/json' \
  -X POST -d "$WAIT_JOB_JSON" \
  -o /dev/null -w '%{http_code}' \
  http://192.168.1.146/ajax/irrigation_queue_front
```
Success = `200` and the controller returns `"SUCCESS"`.

## Verify
The `wait` job is now at `IRRIGATION_PENDING` index **-1** (front/next). Confirm via
the redis read in `references/data-access.md`.

## Back-out
Delete that one list entry from `IRRIGATION_PENDING` (e.g. `LREM` the matching value,
or pop it if it's at the front). It's a single queue entry — trivial to remove.
