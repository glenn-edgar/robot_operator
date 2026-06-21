# Continue — irrigation-analytics session handoff

**Written:** 2026-06-20 (evening), likely a Windows-update / WSL-reboot night.
**A WSL reboot does NOT touch production.** The Pi (`robot` / 192.168.1.66) and the
controller (`pi@irrigation` / 192.168.1.146) are separate machines; the Pi container is
`restart=unless-stopped` + rc.local autostart, so it keeps running through a dev-host
reboot. What a reboot loses is *this chat's context* — hence these notes.

Read first on resume: the **irrigation-ops** skill (its `memory/state.md` has the live
field state) and project memories `irrigation-analytics-deploy`, `fleet-mcfarland-deploy`.

---

## TL;DR — where things stand

- **Production = the Pi**, image **`nanodatacenter/irrigation-analytics:0.52-flow-clean`**,
  armed: `KB1_ARM_KILL=1 KB3_ARM_KILL=1 SKIP_LIVE=1 KB4_CURVE_ARM=1 FIELD_LOG_ARM=1`
  **and `KB3_FLOW_ARM=1`** (flow-deplete is LIVE-actuating as of 2026-06-21 ~13:30).
  Disarm fast: `ssh robot 'cd /home/pi/farm/irrigation_analytics && sed -i "s/^KB3_FLOW_ARM=.*/KB3_FLOW_ARM=0/" fleet.env && bash start.sh'`.
  NOTE: the Pi `start.sh` must forward `-e KB3_FLOW_ARM` (added 2026-06-21) or the gate no-ops.
- **DESIGN (Glenn 2026-06-21): HUNTER is truth; PLC never triggers an action alone.** Hunter
  good + PLC bad → keep running. The old PLC well-drawdown false-skipped 5 healthy stations on
  the sand-fouled meter, so it's **retired**.
- **CONSOLIDATED: one Hunter-only detector** (`lib/flow_deplete.lua`). Trips on depletion
  (Hunter drops below its own post-ramp steady) OR low-vs-baseline (steady < 0.75× baseline).
  Judges only AFTER the slow Filtered-Hunter ramp (steady window min 10–15, JUDGE_FROM=14) —
  this fixed a 06-21 false fire where it tripped at min 9 on a still-climbing 3:18.
  On a trip (ARMED) it does `rpush(reinsert step)` → `rpush(CLEAN_FILTER)` → `rpush(1:39 wait)`
  → `SKIP`, so the queue pops [wait → CLEAN_FILTER → re-run step]. One clean+retry per step
  (anti-loop). Both job formats byte-matched to live IRRIGATION_PENDING. `KB3_WELL_ARM` retired.
- Everything is committed AND pushed to `origin/main` (see `git log`).
- The earlier **poisoned-cursor outage is fixed** (cursor fix in 0.49, deployed; detectors
  record again).

## Watch tonight / after reboot
```bash
# container up + version
ssh robot 'docker ps --filter name=irrigation-analytics --format "{{.Image}} {{.Status}}"'
# the flow-deplete detector firing on real low-Hunter steps (the whole point tonight)
ssh robot 'docker logs irrigation-analytics 2>&1 | grep -iE "FLOW-DEPLETE|flow-deplete"'
# health: must stay 0 (poisoned-cursor regression check)
ssh robot 'docker logs --since 6h irrigation-analytics 2>&1 | grep -ciE "decode failed|Invalid stream|Traceback"'
```

## What was done this session (all on `origin/main`)
- `d1c4178` — fix poisoned past_actions cursor (controller_client.lua); deployed as 0.49.
- `ef4601f` — dashboard URL default 28081→28080 (verified live 200); arming note in
  `fleet.env.example`.
- `c858ada`, `1a89ebf` — runbook notes; vendored arm64 libzenohpico.so.
- `2374caa` — **monitor-only clogged-filter detector** (`lib/clog_filter.lua` +
  `chains/kb3_sustained_user_functions.lua`); deployed as 0.50-clog-monitor.

## The clogged-filter finding (validated)
- Sensor = **Filtered Hunter vs the bin's clean baseline**, NOT PLC (well meter is
  sand-fouled → false-0 on well runs → any PLC/divergence rule false-fires).
- Validated vs the operator's manual `clean filter` events 06-19/06-20: same valves
  recovered after each clean (4:10 5.0→7.7, 4:11 4.2→7.4 GPM). Healthy ≈0.85–0.92×
  baseline; clog candidates 0.50–0.78×. Trip set at 0.75×, once/step.

## NEXT STEPS — to ARM the consolidated flow-deplete detector (do NOT arm blind)
The detector + actuation are already WIRED in `lib/flow_deplete.lua` + the kb3 chain; the
`rpush(reinsert)+rpush(wait)+SKIP` jobs are byte-matched and unit-tested. To go live:
1. **Let cycles accumulate** `FLOW-DEPLETE [monitor]` lines; check each trip against the real
   cycle (was that step actually depleting? did delivery recover?). Validate the threshold.
2. **Eyeball the WOULD reinsert job** in the monitor log vs a live `IRRIGATION_PENDING` entry
   (already verified once 2026-06-21 — matches). The `CLEAN_FILTER` step format is also
   captured if you want to add a clean step to the recovery later:
   `{"type":"CLEAN_FILTER","schedule_name":"CLEAN_FILTER","step":1,"run_time":0}`.
3. **Baseline caveat** — kb4v2 baselines are clog-depressed (4:11 base 5.79 < post-clean 7.4),
   so path-B (low-vs-baseline) deficits are understated; path-A (plateau-drop) is self-
   referencing and unaffected. Consider a clean-run baseline refresh before relying on path B.
4. **Arm** by adding `KB3_FLOW_ARM=1` to the Pi `fleet.env` + restart. Test on a THROWAWAY
   job first (Safety Rule 4). Anti-loop already enforces one wait+retry per step.

## Gotchas / facts to carry forward
- **Prod is the Pi, not WSL.** The committed `packaging_irrigation_analytics/wsl/fleet.env`
  is gitignored; its on-disk copy was de-staled to 0.50-era + **disarmed** (KB1/KB3/SKIP_LIVE=0)
  so a stray WSL `start.sh` can't race the armed Pi. A parallel Claude window deleted the WSL
  dev container earlier — it is NOT production.
- Pi runtime config: `/home/pi/farm/irrigation_analytics/{fleet.env,start.sh}`. Rollback
  backups on the Pi: `fleet.env.bak.0.48-selfcontained`, `fleet.env.bak.0.49-cursor-fix`.
- Rebuild+deploy flow: `cd fleet_operations && IMAGE_TAG=…:<ver> bash
  packaging_irrigation_analytics/build.sh` → `docker push` → `ssh robot 'docker pull …'` →
  edit Pi `fleet.env` IMAGE_TAG (back it up) → `ssh robot 'cd …/irrigation_analytics && bash
  start.sh'`. arm64 native on WSL = same arch as Pi; no buildx flags.
- **PLC well meter is sand-fouled** (reads false-0 on well runs) — distrust PLC/divergence;
  trust Hunter. See irrigation-ops `state.md`.
- Restart re-inits the past_actions cursor to a valid tip (also the poisoned-cursor stopgap);
  brief ~90s gap where KB1/KB3 arming is off — harmless when no cycle is mid-step.
