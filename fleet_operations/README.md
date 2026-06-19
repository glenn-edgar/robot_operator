# fleet_design

A standalone **LuaJIT robot framework** built on Zenoh + SQLite +
chain_tree, packaged as a **single Docker container** per robot
complex.

* No MQTT, no NATS, no Postgres — just Zenoh and SQLite.
* No DCS, no cloud — a deploy is self-sufficient on a Pi 4 with
  spotty WAN connectivity.
* One image per robot complex; one container per host; the seven
  cooperating processes (router + controller + back-office + N
  robots) ship together.

## Components

| Component | Path |
|---|---|
| **robot_common/** | Shared lib code (identity, clock, KB0, daily_marker, app_heartbeat). |
| **farm_soil/** | LoRaWAN soil-moisture robot class with CIMIS ETo context + daily digest. |
| **rancho_water/** | Daily water-portal scraper class. |
| **server/fleet_manager/** | Controller: registration RPC + 1 Hz heartbeat. |
| **server/persistence/** | SQLite-backed persistence + Zenoh query RPC. |
| **server/application_gateway/** | HTTP front-end + dashboard SPA. |
| **server/notification_service/** | Discord push. |
| **packaging/** | Dockerfile + build.sh + supervisor + WSL/Pi host wrapper. |

## Quickstart

Bench (WSL with Docker Desktop):

```sh
bash packaging/build.sh
cd packaging/wsl
cp fleet.env.example fleet.env
mkdir -p secrets       # populate ttn.env, discord.env, etc.
bash start.sh
# dashboard at http://127.0.0.1:8080/
```

Production (Pi 4):

```sh
# from WSL — push image
docker push nanodatacenter/fleet-mcfarland:0.1

# on Pi (one-time)
docker pull nanodatacenter/fleet-mcfarland:0.1
mkdir -p /home/pi/farm/irrigation_demand_useage
# rsync packaging/wsl/ + secrets/ from WSL
# write fleet.env with NETWORK_MODE=host, GATEWAY_HOST=0.0.0.0,
#                     GATEWAY_PORT=<random>
bash /home/pi/farm/irrigation_demand_useage/start.sh
```

Full details in [docs/deploy.md](docs/deploy.md).

## Documentation

Run `mkdocs serve` from this directory; site lives under `docs/`.
Or read the markdown directly:

* [docs/index.md](docs/index.md) — overview
* [docs/architecture.md](docs/architecture.md) — Zenoh layer, staggered
  startup, persistence two-phase apply, robot internal shape
* [docs/container_runtime.md](docs/container_runtime.md) — supervisor,
  crash log, bind mounts, networking modes
* [docs/deploy.md](docs/deploy.md) — WSL bench + Pi production deploy
* [docs/robots.md](docs/robots.md) — farm_soil and rancho_water
  specifics, how to add a new class
* [docs/operations.md](docs/operations.md) — dashboard, Discord,
  persistence schema, troubleshooting

## Container image

Built once on WSL Apple-Silicon (arm64), pushed to Docker Hub, pulled
on Pi 4 (arm64) — same digest, no cross-compile:

* `nanodatacenter/fleet-mcfarland:0.1` (version-pinned)
* `nanodatacenter/fleet-mcfarland:latest`

The `Dockerfile` reads prebuilt `.so` files from `packaging/build_assets/lib/`
(populated by `packaging/build.sh`). zenohd comes from the Eclipse
Debian APT repo (glibc-linked, unlike the alpine-musl-linked image).

## Production deploys

| Site | Host | Port | Robots |
|---|---|---|---|
| Mcfarland — irrigation demand & usage | `192.168.1.66` (Pi 4) | `47291` | farm_soil/lacima01, rancho_water/main |

## License

[MIT](../LICENSE) — Copyright © 2026 Glenn Edgar.
