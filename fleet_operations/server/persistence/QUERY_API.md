# persistence query API — v1 (draft)

The persistence service owns `persistence.db` exclusively. Other processes
read the data over Zenoh via the single RPC defined here. This file is the
contract; the implementation in `main.lua` follows it.

Versioning: `schema = "persistence_query/1"`. Bumps are additive (new op,
new optional field). Breaking changes go to `/2`, with both served for a
deprecation window.

> **Poison-key gotcha (query topic only)**: the specific string
> `fleet/admin/persistence_query` triggers a deterministic routing bug in
> this build of zenoh-pico (commit `88e0ba3`) — server-side
> `z_query_reply()` returns OK but the reply never reaches the client
> (5-sec timeout). Verified by 5×5 isolated repro: same minimal RPC
> server, same client, only this exact string fails. Other `fleet/admin/*`
> topics (heartbeat, register, persistence_topology_announce,
> persistence_service_announce) all route cleanly as queryables. Hence
> the query topic uses `fleet/persistence/query`; the announce stays on
> `fleet/admin/persistence_service_announce` for naming consistency with
> the existing `topology_announce`. If you rename either topic, re-verify
> with `test_query_client.sh`. Root cause not yet identified — looks like
> a zenoh-pico keyexpr/routing edge case on this specific hash
> (`tok/1750b74c`).

## 1. Discovery — service announce

Persistence publishes its own topology onto a well-known fleet-wide token
so consumers can find it without hardcoding. Same shape and cadence as
`fleet/admin/persistence_topology_announce` (decision #9 — discovery is
always announce-driven).

**Token:** `fleet/admin/persistence_service_announce` (FNV1a-hashed
uint32; identical workaround as the robot-side discovery).

**Payload (JSON):**
```json
{
  "schema": "persistence_service/1",
  "service_id": "persistence-1",
  "rpc_token_key": "fleet/persistence/query",
  "republish_s": 30,
  "max_page_rows": 100,
  "max_reply_bytes": 4096,
  "kbs": [
    {"kb_name": "farm_soil_lacima01", "class": "farm_soil", "instance": "lacima01"}
  ]
}
```

**Cadence:** publish on startup, then every `republish_s` seconds. Same
late-joiner / propagation-race reasoning as the robot-side republish.

**`kbs` list** is derived from `p.instances` (apply_topology output).
Reanouncing the kb list lets a consumer that joined late discover which
instances exist without having to also subscribe to every robot announce.

## 2. RPC envelope

**One** RPC server, **one** token (`fleet/persistence/query`), op
dispatched inside the payload. Reuses the existing
`vendor/lua/zenoh_rpc.lua` token-only Server.

**Request:**
```json
{ "op": "<op-name>", "args": { ... }, "page": "<opaque-cursor>" }
```
- `op` (required, string) — one of the v1 ops listed below.
- `args` (required, object) — op-specific.
- `page` (optional, string) — opaque cursor returned from a prior reply's
  `next_page`. Absent on first call.

**Reply — success:**
```json
{ "ok": true, "data": <op-specific>, "next_page": "<opaque>", "stats": { ... } }
```
- `data` shape is per-op.
- `next_page` present iff more results exist; omitted on the last page.
- `stats` is optional metadata (e.g., `{rows: 100, truncated: true}`); not
  load-bearing.

**Reply — error:**
```json
{ "ok": false, "error": { "code": "<code>", "msg": "<human>" } }
```

**Error codes (v1):**
| code              | meaning                                      |
|-------------------|----------------------------------------------|
| `bad_request`     | malformed payload, missing required arg      |
| `unsupported_op`  | op string not in v1 surface                  |
| `not_found`       | kb / path doesn't exist                      |
| `payload_too_big` | reply would exceed `max_reply_bytes`         |
| `internal`        | unexpected server-side fault (logged)        |

**Transport-level failures** (timeout, no server registered) surface as
`ZRPC_ERR_TIMEOUT` to the client — those are NOT the same as a server
`ok:false`. Client code distinguishes them.

## 3. v1 op surface

### `latest(path)`
Last status value for a path.
- `args`: `{ "kb_name": "<kb>", "path": "<ltree-or-zenoh-tail>" }`
- `data`: the stored object, or `null` if nothing recorded yet.
- Errors: `not_found` if the path is not declared on this kb.

### `stream(path, since_ts?, until_ts?, limit?, order?)`
Stream rows. Always paginated.
- `args`: `{ kb_name, path, since_ts?, until_ts?, limit?, order? }`
  - `since_ts` / `until_ts` are epoch seconds (matches `recorded_at`).
  - `limit` capped server-side at `max_page_rows` (default 100).
  - `order` ∈ `"asc" | "desc"`, default `"desc"` (newest first — what a
    dashboard usually wants).
- `data`: array of `{ id, recorded_at, value }`.
- `next_page` present if more rows exist; cursor encodes `(order, last_id)`.
- Errors: `not_found`, `payload_too_big`.

### `latest_stream(path)`
Newest stream row, no list. Convenience over `stream(..., limit=1, order=desc)`.
- `args`: `{ kb_name, path }`
- `data`: `{ id, recorded_at, value }` or `null`.

### `list_kbs()`
What instances persistence currently knows about. Same info as the
announce, exposed via RPC for callers that don't want to subscribe.
- `args`: `{}`
- `data`: `[ { kb_name, class, instance, leaf_count } ]`

### `list_leaves(kb_name)`
Topology for one kb — paths + kinds.
- `args`: `{ kb_name }`
- `data`: `[ { path, kind, length?, desc? } ]`

That's the v1 surface. **Not in v1, deliberately:** wildcard ltree
descendant queries, server-side aggregations (sum/avg/etc), live-update
push channels. Add when there's a concrete consumer asking.

## 4. Path arg — `kb_name` + `path` (not Zenoh full key)

Args take `(kb_name, path)` separately rather than the full Zenoh key.
Reasons:
- Forces the caller to know which instance it's querying — prevents
  silent "wrong robot" reads on a class-rename.
- Matches the construct_kb / KBDS shape; no string-munging on the server.
- Easier to extend later (e.g., per-kb wildcard).

`path` accepts BOTH forms transparently:
- Zenoh-tail form: `cimis/station/sample` (`/` separator)
- ltree form: `cimis.station.sample` (`.` separator)

Server normalizes by `path:gsub("/", ".")` before lookup.

## 5. Pagination + size discipline

zenoh-pico's pub/sub silently dropped a ~7 KB payload — RPC reply isn't
the same code path, but we assume the same ceiling until proven otherwise.

**Hard rules:**
- Server caps individual replies at `max_reply_bytes` (default 4096 B).
- Any list-shaped op (`stream`, `list_kbs`, `list_leaves`) MUST paginate
  with `next_page` when results exceed `max_page_rows` OR estimated
  encoded size approaches `max_reply_bytes`.
- If the FIRST row alone exceeds `max_reply_bytes`, return
  `payload_too_big` — the caller's storing oversized values and that's a
  schema bug worth surfacing, not silently truncating.

**Cursor format (opaque to client; documented here):**
- For `stream`: plain string `"<order>:<after_id>"` (e.g. `"desc:42"`).
  Server resumes with `WHERE id < after_id ORDER BY id DESC` (or `>` for
  asc). ID-based (not `recorded_at`-based) so concurrent inserts mid-walk
  don't cause dupes or skips. The cursor includes order so a client
  cannot accidentally flip direction by re-passing the cursor with new
  args — server uses cursor's order when present.
- For `list_kbs` / `list_leaves`: probably no cursor needed in v1
  (counts are small); leave the field structure in place so adding one
  later isn't a breaking change.

**Size discipline for `stream` specifically:** the op queries with
`limit+1` to detect `more_available`, then iteratively trims the tail
row + recomputes the cursor until the encoded reply fits under
`max_reply_bytes`. So `limit` is a *hint*; actual page size can be
smaller. If the FIRST row alone is over-cap → `payload_too_big`.

## 6. KBDS read-side facts (for the implementer)

- Status read: `rt:get_status_data(ltree_path)` on KBDS aggregator.
- Stream read: `rt:list_stream_data(path, {limit, offset, recorded_after,
  recorded_before, order, order_by='id', after_id=N})` — facade method
  (added 2026-05-23, was previously only on `rt.stream:`).
- Latest stream row: `rt:get_latest_stream_data(path)` — facade method
  (added 2026-05-23 alongside `list_stream_data` to close the same gap).
- KB list: iterate `p.instances` (already in memory).
- Leaf list: iterate `state.leaves` (already in memory).

So v1 needs NO new KBDS calls — every op is one in-memory lookup or one
existing kb_stream / kb_status call. Implementation is small.

## 7. Open questions (decide before slice-2, not blocking slice-1)

- **Live-update push channel** (`fleet/persistence/<kb>/<path>/latest`
  republished on every write) — needed for dashboards that don't want
  to poll. Concrete trigger: first dashboard consumer asks.
- **Multi-kb queries** (e.g., "latest heartbeat from all robots") —
  client can loop today; add a server-side fan-out op when N gets large.
- **Auth / read-allowlist** — single-host fabric for now, defer until
  the fabric crosses a trust boundary.
- **Wildcard ltree descendant query** — wants real subtree subs, which
  wants the zenoh-rs binding. Same gate as the topology design.

## 8. Slice plan

- **Slice 1** (DONE 2026-05-23): envelope + announce + `latest(path)` +
  `list_kbs()` + test client. Smoke against farm_soil heartbeat.
- **Slice 2** (DONE 2026-05-23): `stream(...)` with cursor pagination +
  iterative size-trim + `latest_stream(...)` + `list_leaves(...)`.
  Smoked against CIMIS sample stream (7 rows / 3 pages at limit=3) and
  moisture stream (limit=100 trimmed to 6 rows under the 4 KB cap).
  Library extensions: `kb_stream.list_stream_data` now takes
  `opts.after_id` + `opts.order_by='id'`; `kb_data_structures` facade
  now exposes `get_latest_stream_data`.
- **Slice 3**: live-update push channel if a dashboard consumer needs
  it; otherwise deferred.
