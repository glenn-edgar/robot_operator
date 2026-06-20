# fleet_design

A framework for **standalone LuaJIT robots** that share a local Zenoh
fabric, persist their state in SQLite, surface dashboards over HTTP, and
push notifications to operator-facing channels (Discord today; ntfy /
Slack / SMS are slot-ins).

Every robot of every class runs the same supervisor pattern (KB0 + app
KBs on the `chain_tree_luajit` engine), publishes on the same wire
shapes, and ships in the same single Docker container with its peers.

## What lives in a deploy

| Process | Role |
|---|---|
| `zenohd` | Local Zenoh router (peer-to-peer fabric for all in-container processes). |
| `fleet_manager` | Controller — owns the robot registration RPC + 1 Hz heartbeat that KB0 verifies. |
| `persistence` | SQLite-backed store of every leaf the robots declare. Query RPC for the dashboard. |
| `application_gateway` | HTTP server in front of the persistence query RPC; serves the dashboard SPA. |
| `notification_service` | Subscribes to `fleet/notify/digest/daily`; POSTs to Discord. |
| `farm_soil` (N×) | TTN-driven soil-moisture robot + CIMIS ETo + daily digest. |
| `rancho_water` (N×) | Daily water-portal scraper + usage digest. |

All seven run side-by-side under `tini` PID 1 inside one container.
The container is the unit of deploy.

## What you do at a site

1. Pick a deploy directory on the host (`/home/pi/farm/<robot-complex>/`).
2. Drop `start.sh` (the host docker-run wrapper) and a `fleet.env` there.
3. Drop secrets in `secrets/` (gitignored — TTN token, Discord webhook,
   per-portal credentials).
4. `bash start.sh` — the container pulls (or runs from a local image),
   binds the deploy folder as `/var/fleet`, comes up under a 2-minute
   staggered start, exposes the dashboard on the chosen port.

`/etc/rc.local` invokes `start.sh` on host reboot; `docker run
--restart=unless-stopped` covers container-internal crashes.

## Where to read next

* [Architecture](architecture.md) — what Zenoh layer does what, why
  staggered startup exists, how persistence discovers robots.
* [Container runtime](container_runtime.md) — supervisor model, crash
  log, bind mounts, image layout.
* [Deploy guide](deploy.md) — WSL bench setup, Pi production deploy
  (with the actual Mcfarland deploy as the worked example).
* [Robot classes](robots.md) — farm_soil and rancho_water specifics.
* [Operations](operations.md) — dashboard, Discord, persistence schema,
  troubleshooting.

## Source layout

```
fleet_design/
  robot_common/         shared lib code (identity, clock, KB0, daily_marker)
  farm_soil/            soil-moisture robot class
  rancho_water/         water-portal robot class
  server/
    fleet_manager/      registration + 1 Hz heartbeat
    persistence/        SQLite store + query RPC
    application_gateway/  HTTP front end + dashboard SPA
    notification_service/ Discord push
  packaging/
    Dockerfile          base image build
    build.sh            stage prebuilt .so + docker build
    container/start.sh  in-container supervisor (PID 2 under tini)
    wsl/start.sh        host docker-run wrapper (also used on Pi)
```
