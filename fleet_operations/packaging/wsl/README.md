# Mcfarland — irrigation demand & usage

Production deploy of `nanodatacenter/fleet-mcfarland:0.1` to the
Pi 4 at **192.168.1.66**. Runs two robots:

| Robot | Job |
|---|---|
| **farm_soil/lacima01** | LoRaWAN soil-moisture monitoring (3 SenseCAP S2105 sensors) + CIMIS daily ETo context + 09:00 PT operator digest to Discord. |
| **rancho_water/main** | Daily scrape of the Rancho California Water District customer portal — hourly usage table + daily total + Rancho's own anomaly flags. Pushed at 09:00 PT to Discord. |

## What lives in this directory

```
.
├── README.md             ← this file (deploy-specific notes)
├── start.sh              ← docker-run wrapper (resolves bind mounts relative to itself)
├── fleet.env             ← Pi-specific overrides (LOCAL — gitignored)
├── fleet.env.example     ← annotated template (in git)
├── dashboard_hammer.sh   ← sustained-polling stress harness (development only)
├── .gitignore            ← excludes var/, secrets/, fleet.env
├── secrets/              ← bind-mounted read-only into the container
│   ├── ttn.env             TTN_BEARER_TOKEN
│   ├── discord.env         DISCORD_WEBHOOK_URL
│   └── rancho.env          RANCHO_WATER_ACCOUNT, RANCHO_WATER_PASSWORD
└── var/                  ← bind-mounted read-write into the container
    ├── persistence.db
    ├── identity/
    ├── logs/supervisor.log
    ├── daily_markers/
    └── moisture_rings/
```

## fleet.env (the live values for this site)

```env
IMAGE_TAG=nanodatacenter/fleet-mcfarland:0.1
NETWORK_MODE=host
GATEWAY_HOST=0.0.0.0
GATEWAY_PORT=47291
FARM_SOIL_INSTANCE=lacima01
RANCHO_WATER_INSTANCE=main
RESTART_POLICY=unless-stopped
```

**Dashboard**: <http://192.168.1.66:47291/>

The port is intentionally random — the dashboard has no auth yet and
:8080 is too easy to discover via a port scan. Move to a different
random port whenever the next deploy goes out.

## Operational commands

```sh
# from any LAN host (ssh robot resolves to pi@192.168.1.66):

# state
ssh robot 'docker ps --filter name=fleet --format "{{.Names}}\t{{.Status}}"'
ssh robot 'cat /home/pi/farm/irrigation_demand_useage/var/logs/supervisor.log | tail -20'

# restart
ssh robot 'docker stop fleet; cd /home/pi/farm/irrigation_demand_useage && bash start.sh'

# pull a newer image then restart
ssh robot 'docker pull nanodatacenter/fleet-mcfarland:0.1'   # or new tag
ssh robot 'docker stop fleet; cd /home/pi/farm/irrigation_demand_useage && bash start.sh'

# tail live logs
ssh robot 'docker logs -f fleet'
```

## Auto-launch on reboot

The Pi's `/etc/rc.local` ends with:

```sh
su - pi -c '/home/pi/farm/irrigation_demand_useage/start.sh' &
```

This survives reboots (verified 2026-05-25 — SSH back 40s, dashboard
live 2m25s after a `sudo reboot`). `docker run
--restart=unless-stopped` covers container-internal crashes; rc.local
covers the case where someone explicitly `docker stop`s and then
reboots.

## What lives elsewhere on the Pi

- The image itself: `docker images nanodatacenter/fleet-mcfarland`
- USB drive mount at `/home/pi/mountpoint` (predates this deploy;
  unrelated). rc.local also `mount /dev/sda1 /home/pi/mountpoint`.

## Secrets handling

Files under `secrets/` are mode 0600, owner `pi`. They contain bearer
credentials (TTN token, Discord webhook URL, portal password):

- **Never commit them.** `.gitignore` covers it.
- **Never paste them in logs / chat.** Mask the webhook as
  `https://discord.com/api/webhooks/…`.
- When rotating: edit on WSL, rsync over with
  `rsync -av --chmod=D700,F600 secrets/ robot:/home/pi/farm/irrigation_demand_useage/secrets/`,
  then `docker stop fleet; bash start.sh`.

## See also

- Top-level framework docs at `fleet_design/docs/` in the repo.
- This deploy's session notes:
  `~/.claude/projects/-home-gedgar-motioncore-prototype/memory/pi_deploy_2026-05-25.md`
