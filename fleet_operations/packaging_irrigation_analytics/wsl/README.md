# irrigation-analytics — single-container fleet for the LaCima controller

Sibling deploy to `nanodatacenter/fleet-mcfarland`. Bundles the
`irrigation_analytics` robot (fleet_design scaffold flavor) + the full
fleet stack (zenohd + fleet_manager + persistence + application_gateway +
notification_service) into one container.

Runs side-by-side with fleet-mcfarland on the same Pi: different image,
different container name, **different host ports**.

## Port choices

| Service | Container-internal | Host-side (this deploy) | Host-side (fleet-mcfarland) |
|---|---|---|---|
| Dashboard / gateway HTTP | 8080 | **28080** | 47291 |
| zenohd router            | 7447 | **27447** | 7447 (host-net) |

The new container uses `bridge` networking so its 7447 lives in a private
namespace — no clash with the mcfarland zenohd that owns host 7447.

## What lives in this directory

```
.
├── README.md             ← this file
├── start.sh              ← docker-run wrapper (resolves bind mounts relative to itself)
├── fleet.env             ← LOCAL overrides (gitignored)
├── fleet.env.example     ← annotated template (in git)
├── .gitignore            ← excludes var/, secrets/*, fleet.env
├── secrets/              ← bind-mounted read-only into the container
│   └── discord.env         DISCORD_WEBHOOK_URL (optional)
└── var/                  ← bind-mounted read-write
    ├── persistence.db
    ├── identity/
    └── logs/supervisor.log
```

## Build + run on WSL

```sh
# from anywhere
bash /home/gedgar/motioncore-prototype/fleet_design/packaging_irrigation_analytics/build.sh
bash /home/gedgar/motioncore-prototype/fleet_design/packaging_irrigation_analytics/wsl/start.sh

# dashboard
xdg-open http://127.0.0.1:28080/

# tail container logs
docker logs -f irrigation-analytics

# supervisor JSON log (process starts + crashes)
tail -F var/logs/supervisor.log

# inspect persistence DB
docker exec irrigation-analytics sqlite3 /var/fleet/persistence.db \
    "SELECT path, length(data) FROM knowledge_base WHERE path LIKE 'irrigation_analytics%';"
```

## SSH access from inside the container (popup fetch)

The robot's `controller_client.lua` runs
`ssh pi@irrigation python3 - <…>` to fetch the popup from the LaCima
controller. The container needs:

1. The SSH client (already in the image — `openssh-client` is installed).
2. A private key + a `~/.ssh/config` entry that resolves `irrigation`.

**One-time bench setup** — drop your existing key + config into the
secrets bind mount:

```sh
mkdir -p packaging_irrigation_analytics/wsl/secrets/ssh
cp ~/.ssh/config            packaging_irrigation_analytics/wsl/secrets/ssh/
cp ~/.ssh/id_irrig_146      packaging_irrigation_analytics/wsl/secrets/ssh/
cp ~/.ssh/id_irrig_146.pub  packaging_irrigation_analytics/wsl/secrets/ssh/
cp ~/.ssh/known_hosts       packaging_irrigation_analytics/wsl/secrets/ssh/   # optional
```

On container boot, `/app/start.sh` copies `/secrets/ssh/*` into
`/root/.ssh/` and re-chowns / re-chmods them so SSH's strict-perm check
passes. (Direct bind-mount doesn't work — the bind-mounted files keep
the host uid, and `ssh` refuses keys not owned by the current uid.)

Smoke-test once container is up:

```sh
docker exec irrigation-analytics ssh -o BatchMode=yes pi@irrigation 'hostname'
# expect: irrigation-vm  (or similar)
```

**Pi deploy** — on the Pi the same `start.sh` works; place the key in
`/home/pi/farm/irrigation_analytics/secrets/ssh/`. The Pi already has
SSH access to the controller from elsewhere; just clone the relevant
entries.

## Pi deploy (later — when WSL run is stable)

```sh
# tag + push from WSL
docker tag nanodatacenter/irrigation-analytics:wsl nanodatacenter/irrigation-analytics:0.1
docker push nanodatacenter/irrigation-analytics:0.1

# on the Pi (ssh robot):
mkdir -p /home/pi/farm/irrigation_analytics
rsync -av packaging_irrigation_analytics/wsl/ \
      robot:/home/pi/farm/irrigation_analytics/
ssh robot 'docker pull nanodatacenter/irrigation-analytics:0.1 && \
           cd /home/pi/farm/irrigation_analytics && \
           bash start.sh'
```

Same `start.sh` works on the Pi — bridge mode means it doesn't fight
fleet-mcfarland for ports. Dashboard reachable at
`http://192.168.1.66:28080/`.
