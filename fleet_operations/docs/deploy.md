# Deploy guide

Two deploy targets: WSL bench (development) and Raspberry Pi 4
(production). The same image runs on both — Apple-Silicon WSL is
arm64, Pi 4 is arm64.

## WSL bench

Build, then run from `packaging/wsl/`:

```sh
cd fleet_design
bash packaging/build.sh          # stages prebuilt .so + docker build
cd packaging/wsl
cp fleet.env.example fleet.env   # edit if needed; defaults work
mkdir -p secrets
# populate secrets/ttn.env, secrets/discord.env, secrets/rancho.env
bash start.sh
```

Dashboard at `http://127.0.0.1:8080/`. `NETWORK_MODE` defaults to
`bridge` because Docker Desktop on WSL doesn't honor `--network=host`.

## Production deploy to Pi 4

The Mcfarland deploy is the worked example. The Pi is at
`192.168.1.66` (host alias `robot` in `~/.ssh/config`).

### 1. Push the image to Docker Hub from WSL

```sh
docker tag fleet-mcfarland:wsl nanodatacenter/fleet-mcfarland:0.1
docker tag fleet-mcfarland:wsl nanodatacenter/fleet-mcfarland:latest
docker push nanodatacenter/fleet-mcfarland:0.1
docker push nanodatacenter/fleet-mcfarland:latest
```

(Tag scheme: `nanodatacenter/<image>:<version>`. Version-pin per
deploy so a fresh push doesn't rev all production sites at once.)

### 2. Deploy folder on Pi

```sh
ssh robot 'mkdir -p /home/pi/farm/irrigation_demand_useage'

# rsync wrapper + env template (exclude per-deploy state & secrets)
rsync -av --exclude=var --exclude=secrets \
    fleet_design/packaging/wsl/ \
    robot:/home/pi/farm/irrigation_demand_useage/

# rsync secrets separately, restrictive perms
rsync -av --chmod=D700,F600 \
    fleet_design/packaging/wsl/secrets/ \
    robot:/home/pi/farm/irrigation_demand_useage/secrets/
```

### 3. Pi `fleet.env`

```env
IMAGE_TAG=nanodatacenter/fleet-mcfarland:0.1

# Real Linux Docker, so --network=host actually works.
NETWORK_MODE=host
GATEWAY_HOST=0.0.0.0

# Pick a random high port per deploy (port-obscurity until dashboard
# auth lands — see dashboard_port_obscurity_todo memory).
GATEWAY_PORT=47291

FARM_SOIL_INSTANCE=lacima01
RANCHO_WATER_INSTANCE=main

RESTART_POLICY=unless-stopped
```

### 4. Pull image + first launch

```sh
ssh robot 'docker pull nanodatacenter/fleet-mcfarland:0.1'
ssh robot 'cd /home/pi/farm/irrigation_demand_useage && bash start.sh'
```

The container goes through the 110 s staggered start, then both
robots come online. Dashboard at `http://192.168.1.66:47291/`.

### 5. Auto-launch on host reboot

Edit `/etc/rc.local`, add **before** `exit 0`:

```sh
su - pi -c '/home/pi/farm/irrigation_demand_useage/start.sh' &
```

Or automate with:

```sh
ssh robot 'sudo sed -i "/^exit 0$/i su - pi -c \"/home/pi/farm/irrigation_demand_useage/start.sh\" \&" /etc/rc.local'
```

`docker run --restart=unless-stopped` covers container-internal
crashes; rc.local covers the case where someone explicitly
`docker stop`s and then reboots.

## Adding another robot complex at the same site

Different geography means different image (different robot roster).
Per the locked architecture decision, **one image per robot complex**.
For a second complex at the same Pi (rare but possible), use a
different deploy folder and a different `CONTAINER_NAME` in
fleet.env. Pick a different `GATEWAY_PORT` so the dashboards don't
collide.

## Verifying a deploy is healthy

```sh
curl -s http://<host>:<port>/api/robots             # both robots listed
curl -s http://<host>:<port>/api/robots/farm_soil/lacima01/latest?path=heartbeat
curl -s http://<host>:<port>/api/robots/rancho_water/main/latest?path=heartbeat
```

The heartbeat JSON includes per-app-KB health (`ok`/`degraded`) and
free-form `detail` strings. A degraded app surfaces here before it
shows up on Discord.

## Rollback

The previous image tag is still in Docker Hub. To roll back:

```sh
ssh robot 'cd /home/pi/farm/irrigation_demand_useage && \
    sed -i "s/^IMAGE_TAG=.*/IMAGE_TAG=nanodatacenter\/fleet-mcfarland:0.0/" fleet.env && \
    docker pull nanodatacenter/fleet-mcfarland:0.0 && \
    docker stop fleet; bash start.sh'
```

(Assumes a `:0.0` tag exists. Always push at least two versions so
there's something to roll back to.)
