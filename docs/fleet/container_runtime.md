# Container runtime

## Image layout

Base: `debian:bookworm-slim`. zenohd installed from the
[Eclipse zenoh Debian APT repo](https://download.eclipse.org/zenoh/debian-repo/) —
this is **important**: the official `eclipse/zenoh` Docker image is
Alpine/musl-linked and its binary won't run on a Debian/glibc host
even via `COPY`. The Debian APT repo provides a glibc-linked
`zenohd`.

Prebuilt `.so` files live in `/usr/local/lib`:

* `libzenohpico.so` — Eclipse zenoh-pico C library
* `libzenoh_rpc.so` — knowledge_base_assembly RPC FFI wrapper
* `libzenoh_pubsub.so` — knowledge_base_assembly PubSub FFI wrapper
* `libzenoh_token.so` — FNV1a token hash helpers
* `ltree.so` — SQLite extension for ltree-style path queries

`libsqlite3.so` symlink is **manually recreated after `apt-get
remove --purge libsqlite3-dev`** — the dev package owns the
unversioned symlink that `ffi.load("sqlite3")` needs; removing it
to slim the image deletes the symlink. The Dockerfile re-creates it
with `ln -sf libsqlite3.so.0 /usr/lib/aarch64-linux-gnu/libsqlite3.so
&& ldconfig` after the dev-package purge.

## Process supervisor

`packaging/container/start.sh` runs as tini's child (PID 2). Source
of truth for the bring-up sequence.

### Staggered launch

```
Phase 1  0 s    launch zenohd
sleep 60
Phase 2  60 s   launch fleet_manager
sleep 15
Phase 3  75 s   launch persistence, gateway, notification
sleep 30
Phase 4  105 s  launch robots (farm_soil, rancho_water, …)
```

Total cold-boot ~110 s. Paid once per container start. Recreates
the bench's natural human-typing latency between manual `bash run.sh`
launches — the latency that, on the bench, accidentally hid the
zenoh-pico late-binding race surfaced during 2026-05-24
containerization.

### Crash supervision

```bash
wait -n -p CRASHED_PID    # block on first child to exit
log_event ERROR crash "$CRASHED_NAME" "$CRASHED_PID" "$CRASHED_RC"
trap - TERM INT
kill 0 2>/dev/null         # signal siblings to exit cleanly
exit "$CRASHED_RC"         # propagate exit code to docker daemon
```

`docker run --restart=unless-stopped` brings the whole container
back. The exit code in the structured log is preserved so external
maintenance programs can scan for crashloops.

### Structured crash log

`/var/fleet/logs/supervisor.log` — one JSON object per line, rotated
at 100 entries (`mv .log -> .log.1`). Sample:

```json
{"ts":"2026-05-25T17:32:10.164Z","level":"INFO","event":"container_boot","proc":"supervisor","pid":null,"rc":null,"host":"raspberrypi"}
{"ts":"2026-05-25T17:32:10.169Z","level":"INFO","event":"start","proc":"zenohd","pid":16,"rc":null,"host":"raspberrypi"}
{"ts":"2026-05-25T19:45:38.598Z","level":"ERROR","event":"crash","proc":"gateway","pid":47,"rc":134,"host":"raspberrypi"}
```

**Dedup**: crash events with identical (proc, rc) within
`DEDUP_WINDOW_S` seconds of the prior matching crash are suppressed.
Default 300 s. Burst storms compress to one entry; crashes spread
further apart each land in the log.

(Pre-fix, dedup was unbounded — every same-signature crash after the
first was suppressed forever, so 15 overnight crashes registered as
1 log entry. See `zenoh_rpc_uaf_fix_2026-05-25` memory for the
fix and the root-cause UAF.)

## Bind mounts

The host's deploy folder is bind-mounted as `/var/fleet`:

```
host: /home/pi/farm/<robot>/var      →  container: /var/fleet
host: /home/pi/farm/<robot>/secrets  →  container: /secrets (read-only)
```

State files (db, logs, identity, daily_markers, moisture_rings)
all live under `/var/fleet` so they survive image upgrades. Secrets
are read-only inside the container.

## Networking

Two modes, env-driven:

| `NETWORK_MODE` | Effect |
|---|---|
| `bridge` (WSL default) | `docker run -p $GATEWAY_PORT:$GATEWAY_PORT -p 7447:7447`. Required on Docker Desktop where `--network=host` is a no-op. Forces `GATEWAY_HOST=0.0.0.0` inside the container so the dashboard is reachable on the published port. |
| `host` (Pi production) | `docker run --network=host`. Real Linux Docker; gateway and zenohd bind directly on host IPs. |

`GATEWAY_HOST=0.0.0.0` is set in Pi `fleet.env` so the dashboard
serves on `0.0.0.0:<GATEWAY_PORT>` — reachable from any LAN client.

## Docker log cap

`--log-driver json-file --log-opt max-size=20m --log-opt max-file=5`
= 100 MB hard cap on `docker logs fleet`. At steady-state chatter
(mostly heartbeats) 100 MB lasts weeks. Separate cap from
supervisor.log's 100-entry rotation.

## Secrets convention

`/secrets/*.env` files are sourced by start.sh into the environment
before any robot launches. Per-service `run.sh` files don't need
to source secrets themselves — one sweep handles all of them.

Files:

* `secrets/ttn.env` → `TTN_BEARER_TOKEN`
* `secrets/discord.env` → `DISCORD_WEBHOOK_URL`
* `secrets/rancho.env` → `RANCHO_WATER_ACCOUNT`, `RANCHO_WATER_PASSWORD`

Add another robot class that needs a new credential? Drop a new
`.env` in `secrets/`, reference the env var name in the robot's
code. No code change to start.sh.

## Adding a process

To add another back-office service or robot:

1. Build the proc tree (`server/<name>/run.sh` etc.) and a
   `COPY <name>` line in the Dockerfile.
2. Add a `launch <name> bash "$APP_DIR/server/<name>/run.sh"` line
   in `start.sh` in the appropriate phase.
3. If it's a robot class, add a `launch_robot` line in Phase 4 with
   the instance env var.
4. Decide if it should crash-stop the whole container (default,
   matches the bench model) or be allowed to fail independently
   (would need a new supervisor design — currently rejected).
