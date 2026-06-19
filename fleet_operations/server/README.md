# server/ — Robot controller

The Linux-side fleet controller. Robots register here and consume its
heartbeat; it owns the fleet registry and (later) the external API surface.
This is Path 1 of the development plan (decision #22).

## Target shape — five layers (decision #13)

One process per layer, started in order; built `FROM nanodatacenter/luajit-base`
(decision #12) with that image's chain-tree supervisor managing the layer
processes — not s6, not supervisord.

| start_order | Layer | Status |
|---|---|---|
| 10 | `zenohd` | external `eclipse/zenoh` docker container for now (decision #16) |
| 20 | `fleet_manager` | **built** — registry + register RPC + heartbeat |
| 30 | `persistence` | not started |
| 40 | `application_logic` | not started |
| 50 | `application_gateway` | not started |

Container packaging, internal inter-layer Zenoh transport, and the other four
layers are later work.

## fleet_manager (this layer)

Replaces the throwaway `bench_manager` stub. Reproduces its wire contract so
`fake_robot` registers against the real controller:

- RPC queryable on `fleet/admin/register` — records the robot, replies
  `{ok, controller_id, ts, echo_chip_uid}` (decision #30).
- 1 Hz heartbeat publisher on `fleet/admin/heartbeat` `{seq, ts}` — robots
  use it for passive disconnect detection (decision #32).

Beyond `bench_manager` it keeps a real registry — `chip_uid → {class,
instance, fw_version, capabilities, first_seen, last_seen, register_count}` —
which the stub lacked. The controller is **passive**: no validation, NACK, or
uniqueness enforcement; the robot is sovereign (decision #29).

`lib/registry.lua` is in-memory. It is the seam for decision #15 (SQLite
`registry.db`): swapping storage is local to that module.

## Run

```sh
# zenohd router (layer-10 stand-in)
docker run -d --name fleet-zenohd -p 7447:7447/tcp -p 7447:7447/udp \
    eclipse/zenoh --listen tcp/0.0.0.0:7447 --listen udp/0.0.0.0:7447

# fleet_manager
ZENOH_LOCATOR=tcp/127.0.0.1:7447 ./fleet_manager/run.sh
```
