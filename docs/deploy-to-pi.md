# Deploy to the Pi

Production runs on the Raspberry Pi 4 at `pi@192.168.1.66` (`ssh robot`); the
irrigation controller is `ssh pi@irrigation`. The build host and the Pi are both
arm64, so the image deploys unchanged.

For the framework-level deploy guide (WSL bench runs, secrets, ports, host
reboot wiring) see **[Fleet framework → Deploy guide](fleet/deploy.md)**. This
page is the repo-level build → ship → boot loop.

## Ship and run

```bash
# 1. Build (see Build from source)
IMAGE_TAG=nanodatacenter/irrigation-analytics:<tag> \
  fleet_operations/packaging_irrigation_analytics/build.sh

# 2. Ship the image to the Pi
docker save nanodatacenter/irrigation-analytics:<tag> | ssh robot 'docker load'

# 3. Point the deploy at the new tag and (re)launch
ssh robot 'cd /home/pi/farm/irrigation_analytics \
  && sed -i "s#^IMAGE_TAG=.*#IMAGE_TAG=nanodatacenter/irrigation-analytics:<tag>#" fleet.env \
  && bash start.sh'
```

`start.sh` does `docker rm -f` on the running container, then `docker run`s the
new tag (bridge mode, host ports 28080 + 27447, `--restart=unless-stopped`,
binding the deploy folder as `/var/fleet`). There is a brief monitoring gap
during the swap.

!!! tip "Rollback"
    Previous image tags stay on the Pi. To roll back, point `IMAGE_TAG` at the
    prior tag (e.g. `0.47-rstep-gate`) and re-run `start.sh`.

## Staggered boot (~105 s)

The in-container supervisor (`start.sh` under `tini` PID 1) launches processes
in phases to avoid boot races. Full stack is up about 105 s after launch:

| Phase | T+ | Process(es) |
|---|---|---|
| 1 | 0 s | `zenohd` (router on `0.0.0.0:7447`) |
| 2 | 60 s | `fleet_manager` (registration RPC + 1 Hz heartbeat) |
| 3 | 75 s | `persistence`, `application_gateway`, `notification_service` |
| 4 | 105 s | `irrigation_analytics` robot (KB0 + app KBs) |

## Verify the boot

```bash
ssh robot 'docker ps --filter name=irrigation-analytics --format "{{.Image}} | {{.Status}}"'
ssh robot 'docker inspect irrigation-analytics --format "RestartCount={{.RestartCount}} Running={{.State.Running}}"'

# all six start events, no crashes
ssh robot 'docker logs irrigation-analytics 2>&1 | grep -oE "\"event\":\"start\",\"proc\":\"[a-z_]+\""'

# robot registered with the controller
ssh robot 'docker logs irrigation-analytics 2>&1 | grep -iE "NEW .*lacima|controller ack"'

# dashboard responds
ssh robot 'curl -s -o /dev/null -w "%{http_code}\n" http://127.0.0.1:28080/irrigation/alerts'   # → 200
```

A healthy boot shows `RestartCount=0`, all six `start` events
(`zenohd`, `fleet_manager`, `persistence`, `gateway`, `notification`,
`irrigation_analytics`), no `exit`/`crash` events, a `NEW … lacima` registration
with a `controller ack`, and `HTTP 200` on the alerts page.
