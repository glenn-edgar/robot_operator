# Operations

## Dashboard

The `application_gateway` serves an SPA at `http://<host>:<port>/`
backed by a small JSON API:

| Endpoint | Returns |
|---|---|
| `GET /api/robots` | List of (class, instance, kb_name, leaf_count). |
| `GET /api/robots/:class/:inst/leaves` | All leaves the class declared. |
| `GET /api/robots/:class/:inst/latest?path=<leaf>` | Most recent value of a status or stream leaf. |
| `GET /api/robots/:class/:inst/latest_stream?path=<leaf>` | Newest entry from a stream leaf. |
| `GET /api/robots/:class/:inst/stream?path=<leaf>&limit=N&order=desc&page=<cursor>` | Paginated stream history. |

The persistence query RPC enforces a **~4 KB per-page size cap** so
chunky payloads (moisture readings with full TTN gateway metadata)
come back ~6 at a time. The dashboard walks the cursor up to
`MAX_PAGES=8` to gather a useful history without unbounded render
cost.

The HTTP server is LuaSocket-based — single-threaded request
handling, plenty fast for the ~1 req/s load of one dashboard
session. It is NOT designed to handle adversarial traffic — see
the auth note below.

## Auth status (open issue)

The dashboard has **no auth today**. Today's mitigation is
port-obscurity:

```env
GATEWAY_PORT=<random_high_port>      # not 8080
GATEWAY_HOST=0.0.0.0                 # LAN-reachable on Pi production
```

Real fix is HTTP basic / session-token auth on the gateway. Tracked
in the `dashboard_port_obscurity_todo` memory.

## Discord notifications

`notification_service` subscribes to `fleet/notify/digest/daily` and
POSTs the body to the configured `DISCORD_WEBHOOK_URL`. Webhook URL
is treated as a bearer credential — masked in logs as
`https://discord.com/api/webhooks/…`.

LuaSec quirk: `https.request` returns `(r, c, h, sline)` — `r==1`
is success, `c` is the HTTP status (typically 204 for a Discord
webhook).

## Persistence schema

SQLite at `/var/fleet/persistence.db` (bind-mounted). Schema mirrors
the construct_kb pattern:

```
knowledge_base         — leaf catalog: path, kind, properties, ltree-ish
knowledge_base_stream  — pre-allocated ring rows per stream leaf
knowledge_base_status  — UPSERT-by-path table for status leaves
knowledge_base_info    — KB-level metadata
+ a few support tables (job, link, link_mount, rpc_*, bit_mask)
```

`path` columns use dot-separated form `<class>_<instance>.<kind>.<tail>`,
e.g. `farm_soil_lacima01.stream.lacamia1b.zone3.latest`. The
`ltree.so` C extension provides hierarchical-path query support;
loaded at persistence startup.

## Bind-mount state files

```
/var/fleet/
  persistence.db                  ← SQLite store (recreated if missing;
                                    schema migrated if existing)
  logs/supervisor.log             ← structured crash log
  daily_markers/                  ← idempotency markers for daily one-shots
    <class>_<instance>_<key>.txt    "2026-05-25\n"
  moisture_rings/                 ← persisted moisture ring state
    <class>_<instance>_<dev>_<loc>.json
  identity/                       ← per-robot identity files
```

Wipe `daily_markers/` to force re-publish of today's digest (manual
recovery if a digest got lost). Wipe `moisture_rings/` to force
re-fetch of the full TTN backlog (typically you don't want this;
it causes duplicate-publish during the catch-up).

## Troubleshooting

| Symptom | Where to look |
|---|---|
| Container restart-looping | `var/logs/supervisor.log` for crash events. |
| Robot missing from `/api/robots` | `docker logs fleet` for KB0 connection traces. Check the robot's `app_heartbeats` via the heartbeat leaf. |
| Dashboard shows stale data | persistence service might have crashed earlier; check supervisor.log. Restart via `docker stop fleet; bash start.sh`. |
| Discord not posting | check `secrets/discord.env` has a valid webhook URL; `docker logs fleet | grep NOTIFY`. |
| Sensor data not arriving | TTN: `docker logs fleet | grep moisture`. Portal: `docker logs fleet | grep daily_pull`. |

## Health probing

```sh
# Container alive?
docker ps --filter name=fleet --format '{{.Names}}\t{{.Status}}'

# How many container boots since last log rotation?
grep -c container_boot /home/pi/farm/<deploy>/var/logs/supervisor.log

# How many crashes?
grep '"event":"crash"' /home/pi/farm/<deploy>/var/logs/supervisor.log

# Are the daily digests firing?
docker logs fleet 2>&1 | grep -E 'digest delivered|published 2026' | tail -5

# Per-robot heartbeat
curl -s http://<host>:<port>/api/robots/farm_soil/lacima01/latest?path=heartbeat
```

## Sustained-polling stress test

`packaging/wsl/dashboard_hammer.sh` — hits the gateway API in a
tight loop at ~3 req/s. Used to reproduce the
[zenoh-rpc UAF](https://github.com/glenn-edgar/knowledge_base_container)
under load. Reach for it whenever changes touch the RPC/gateway
path.

```sh
HOST=192.168.1.66 PORT=47291 bash packaging/wsl/dashboard_hammer.sh
```
