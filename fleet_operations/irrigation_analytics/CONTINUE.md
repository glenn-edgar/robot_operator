# irrigation_analytics — CONTINUE

> ⚠️ Everything below the `--- HISTORICAL ---` marker is the original
> 2026-05-29 build doc, kept for reference. The authoritative current state is
> THIS top section. Companion memory: `irrigation-production-state` (the reset
> runbook).

## ⭐⭐⭐ 2026-07-13 CURRENT STATE (supersedes everything below)

**Image `0.72-step-cooldown`, armed & live on the Pi.** Arc since 07-09:
- **Sand-clog clean FIXED (0.71/0.72).** Glenn's all-city-backed schedule (1:39 on every step, to
  detect pipe breaks) had disabled the PLC-foul via the `not is_city` gate → "sand-clog did not
  work". Now: PLC(well)<3 & smooth Hunter≥4 on **ANY ETO bin** → `SKIP + wait(15m) + CLEAN_FILTER
  + re-run remaining step-time on well`. Cooldown **STEP-based N=1** (`KB3_FILTER_COOLDOWN_STEPS`)
  — backflush EVERY fouled step (a pipe break can exhaust the well). **RULE (final): PLC low →
  backflush every step; NO offline-detection, NO city/well suppression.** Flow-deplete stays
  non-city-only. Committed 7c665a8.
- **PLC sensor OFFLINE 07-11 19:14 → 07-12 15:41 (~20h), resolved.** Flat 0, hardware clean (Glenn
  checked 15:47); well delivered via Hunter throughout; recovered 15:48, healthy 9-11 since. No
  detector added — Glenn's call (backflushes aren't wasted even on a well-off stretch).
- **Field: ALL repairs HOLDING** (4:10/4:4/3:5 pipe breaks, 4:9 new solenoid, 1:1→1:18) — verified
  via the `New_check` schedule (Glenn built it to check the fixes). Open item: **3:2 ELECTRICAL
  high-R** in its own leg (valve_test 0.588, rising +0.032 faster than cable-mates 3:1/3:7) — NOT
  urgent, flow fine (small zone, combined with 4:12). 4:7 stable/elective.
- **RULE: rising within-run current = SOLENOID FAILURE** (4:9 was a thermal short: normal 43.5Ω
  cold, shorted hot — a cold ohmmeter misses it).

---
## ⭐⭐⭐ 2026-07-09 CURRENT STATE (superseded by the 2026-07-13 section above)

**Image `0.70-well-active`, armed & live on the Pi (`ssh robot`).** kb1 + kb3 all armed.
Companion memory: `irrigation-production-state`, `valve-health-findings-2026-07-08`,
`controller-schedules-live-in-redis`, `new-irrigation-gui-project`.

### KB3 detectors (all armed on 0.70)
- **Leak**: abs 14 GPM OR base+5, 4 consec → SKIP + 15-min recharge.
- **Flow-deplete + ABS FLOOR 5.0** (0.68): catches a clog a suppressed baseline hides.
- **CITY-WATER MONITOR / keep-well-active** (0.70): PLC(well) low while Hunter(city) flows →
  SKIP + wait + CLEAN + re-run REMAINING on well. **WATCH: churns on sand-foul (~4/night)** —
  candidate to tighten (distinguish real drawdown from a transient foul).
- **Flow STEP-WATCH** (0.69, ALERT-ONLY): sustained ≥1.5 GPM run-to-run step = developing leak.

### Shipped this session (committed/pushed to robot_operator)
- 0.68 flow abs-floor · 0.69 flow step-watch · 0.70 city-water well-active monitor.
- Fixed `No_city_water` schedule: 1:40-master typo → 1:39; removed empty/0-min tail steps that
  500'd the Flask editor; **SYNCED Redis** (schedules are served from Redis `db=4 [FILE:APP]`
  msgpack, NOT the .json file — see `controller-schedules-live-in-redis`).
- Reset baselines for **4:10/4:11/2:15** (repaired pipe-break bins → re-learn city-backed clean).

### Field maintenance 2026-07-09
- **1:1 → 1:18** (fresh 43Ω solenoid) — DONE, verified flat. 1:18 = shrubbery zone (non-ETO).
- **4:9 solenoid replaced (2nd time)** — CURRENT-SIDE VERIFIED HEALTHY: first full 58-min post-swap
  run drift **−0.020 (cooling)** vs old coil +0.013 rising. Still TBV: resistance-vs-fleet over days.
- **4:7 = planned replacement next** (elective; should read LOW ~40Ω cold — a static short).
- **⭐ RULE: RISING current through a run = SOLENOID FAILURE** (thermal short reads normal cold:
  bad 4:9 was 43.5Ω cold but shorted hot). Watch within-run drift: rising=bad, flat/neg=healthy.
- **Pipe breaks:** 4:4 + 3:5 FIXED (robot caught both). **4:10(×5)/4:11/2:15 were UNDETECTED**
  (internal breaks read LOW). Glenn added **CITY-WATER BACKING** (1:39 on every step) so a break
  draws city water → shows as EXCESS flow. (This is why No_city_water is all-city-backed now.)

### NEXT priorities
1. **NEW GUI PROJECT — kickoff 2026-07-10**: design menu structure → schedule/config tasks. Redis
   stays the contract; strangler-fig; must preserve the `/ajax/mode_change` command API the robot
   uses. Full plan in `new-irrigation-gui-project`.
2. **4:9 verification** — current-side DONE (drift −0.020, healthy); only the resistance-vs-fleet
   trend over a few days remains to fully close it.
3. **Break-detection tuning**: retune the leak trip to key off each bin's CITY-BACKED baseline
   (city-backed normal ~10-12; abs-14/base+5 were well-only-tuned) — after the reset bins re-learn.
4. **4:7 replacement** verify when done.

---

## ⭐⭐ 2026-06-14 UPDATE — next task: KB3 LEAK CURVE DETECTOR
Full plan + measured data in the `irrigation-kb3-curve-tracker-plan` memory. In short:
- A REAL 4:10 pipe break (coyote pipe) went uncaught by KB3 today. Root cause: KB3
  polls `popup.FILTERED_HUNTER_VALVE` once/min (saw **HUNTER=8.4 flat**, strict >14),
  while the real leak in `PLC_MEASUREMENTS_STREAM` was raw HUNTER ~11–12 / PLC ~12–13.4.
  Lowering the absolute threshold (14→13) is **cosmetic** and was NOT shipped.
- Also: the held-out 4-bank is baseline-starved (4:10 n=1, 4:11 n=1, 4:9 n=6 < the
  7-clean-run gate) → KB3 ran `primary-only`, relative trip disabled.
- **2026-06-15 build:** KB3 curve detector — read the STREAM (raw HUNTER + PLC,
  sub-minute, windowed median), per-bin clean baseline, RELATIVE trip (~+3 GPM).
  Leak lift measured: 4:10 clean ~8 vs leak ~11–12. Cohort fallback for sparse bins.
  Monitor-first, no controller change, isolated from the armed path.
- Aftermath: first live well-drawdown actuation fired (4:11, skip+recharge, OK) — it
  catches the downstream symptom not the source. 4:10 field-repaired; 4:10+4:11
  `repair_leak` field reports applied by the watcher; post-fix runs clean (4:10 ~8,
  4:11 ~6), baselines re-learning. Operator skill `irrigation-ops` shipped (commit 638a215).

## ⭐ CURRENT STATE & WINDOWS-RESET RECOVERY (2026-06-12) — READ FIRST

**Production runs on the Pi (`ssh robot` = 192.168.1.66), NOT WSL.** A Windows /
WSL reset does NOT take down production — the painful 2026-06-10 lesson when the
WSL-armed robot was dead 11 h overnight. After a reset there is nothing to
restart; just confirm health.

### After a Windows/WSL reset — do exactly this
1. **Nothing is down.** Confirm the Pi:
   ```
   ssh robot 'docker ps --filter name=irrigation-analytics --format "{{.Image}} {{.Status}}"; \
     docker logs irrigation-analytics 2>&1 | grep -iE "armed=true|seeded.*non-ETO" | tail'
   ```
   Healthy = current image Up; kb1 armed=true (1.8/1.2 A); kb3 armed=true (14 GPM).
2. **Current image: `0.28-flow-within`, armed.** (Confirm the real tag from step 1.)
3. **WSL is dev-only and normally STOPPED. NEVER run WSL armed while the Pi is
   armed** — both poll the same controller and double-actuate.
4. No sqlite3 CLI on the Pi — query DBs via
   `ssh robot 'docker exec -i irrigation-analytics luajit -e "...lsqlite3..."'`.
5. Deploy procedure + gotchas: see the `irrigation-production-state` memory.

### PENDING — periodic checks through the week (Glenn checks system periodically)
- **MULTI-WEEK clog-trend accumulation is the live experiment** (started 06-12).
  The `flow_within` monitor (0.28) records per ETO run; we need WEEKS to see if the
  clog trends hold. On each periodic check do the read-time analysis:
  - `SELECT valve,steady_5_15,flatness,end_droop,ts_ms FROM flow_within ORDER BY ts_ms DESC` (kb4.db)
  - **Neighbour-normalise**: this bin's steady_5_15 minus its cohort (satellite-N
    manifold) median the same night → cancels common-mode supply.
  - **Flag** a sustained MONOTONIC decline > ~2 heads (5 gal) on a CLEAN bin
    (flatness < ~1 gal). **4:4 is the live candidate** (declining 109→101 post-Thu-
    fix, neighbour-confirmed). Only after weeks of holding do we add a clog alert.
  - end_droop is WELL DRAWDOWN — read separately, not a clog.
- **First-night verification (do once, ~06-13)**: confirm both new monitors actually
  wrote rows: kb2_wr.db `runs_kb2_within` (max ts = 06-12 night, not 06-09 — the
  0.27 persistence fix) AND kb4.db `flow_within` (steady_5_15/flatness/end_droop
  populated per ETO bin).
- **Watch list** (kb4.db `watch_list`, shown on `/irrigation/coil`): 2:14, 2:15
  (onset overshoot), **4:4** (developing clog).
- The **KB2 persistence gate** (0.25) verifies on the next valve_test cycle —
  confirm a single-cycle cohort outlier is suppressed (logged, not alerted).

### What we did 2026-06-12 (clog-detection-by-flow arc — the "why" behind 0.27→0.28)
1. **Caught a 3-day silent data loss (0.27 fix).** Within-run R rows stopped
   persisting 06-09→12: the 06-09 thermal-lift change added 4 columns to the INSERT
   but NO `ALTER` migration, so on the live (pre-existing) DB the prepared INSERT
   referenced missing columns and failed silently while STILL logging. Fixed:
   ALTER-migrate all 4 in `open_db` + the call site now logs INSERT failures.
2. **Per-head flow physics**: sprinkler = 14.5 gph = 0.242 gpm → a blocked head
   removes **2.42 gal** from the 10-min (5-15) window. Detection floor on a clean
   bin ≈ 1 head; on noisy bins ~3 heads. Widening window to 5-25 does NOT help
   (drags in the droopy tail); 6 baseline samples only help the random noise, not
   the correlated supply-pressure term.
3. **The unlock = compare TIME BINS WITHIN a run.** Pressure is shared across a
   run, so steady-bin-to-steady-bin scatter cancels the supply offset → noise floor
   0.77 gal (2:16) = ~1-head resolution, vs 1.3 gal run-to-run. MUST exclude the
   end-of-run bins: a late-run droop (−3.5 gal on 2:16's 59-min run) is WELL
   DRAWDOWN, not a clog. This is what `lib/flow_within_run.lua` records.
4. **Validated vs the field clog set**: clean-bin negatives (2:16, 4:3 — both field
   0 blocked) and the multi-head 4:1 (7 heads → +30 recovery after cleaning) MATCH
   ground truth, zero false alarms. SINGLE-head clogs (4:7, 4:6/4:8, 4:9, 3:1/3:7)
   are below every bin's flow floor → field-eyeball only. **So flow is a clean-bin
   clog/recovery detector + multi-head alarm, NOT a single-head detector.**
5. **4:4 = the one live flow-visible candidate**: head fixed Thu but 5-15 kept
   declining 109→107→101, bin-specific vs flat neighbours (4:7 −2, 4:9 0) → a NEW
   multi-head clog likely forming. Watch-listed. Field record corrected: 4:3 → 0.

### What we did 2026-06-11 (the analysis arc — the "why" behind 0.21→0.26)
1. **Coil current is a SUMMED bus, never one coil.** `IRRIGATION_CURRENT` =
   master **1:43** (implicit, always on, ~0.46 A) + the **1-3 pair members** in
   the bin key (1:39 is a normal member). Reading a single hold as one coil is
   wrong — that mistake (twice) drove the design.
2. **Per-coil decomposition by least-squares** (`coil_solve.lua`): each run is
   `hold = master + Σ pair-member coils`; every valve appears in many pairs, so
   the run-set solves for each coil + the master. **Validated**: residual 0.057 A,
   master 0.46 A, typical coil 0.26 A. Unconnected valves (1:1/1:28/1:40) +
   wiring artifacts (3:7/4:8) solve to ≈0 A = **null references** that calibrate
   the fit's zero each render. Page `/irrigation/coil`; backfilled from a
   TIME_HISTORY snapshot via `explore/backfill_coil_onset.py`.
3. **Onset overshoot is benign**, not a fault signature: clogged 2:15 and healthy
   2:14 overshoot identically (cold-coil thermal). Watched anyway, to test the trend.
4. **The KB2 "R_SHORT epidemic" (15:01 cycle) was measurement noise, not faults.**
   The 2-null offset (channels 3:1 + 4:6) already removes common-mode; the 5 V is
   a regulated supply with ~no load. The residual is **per-channel cycle noise** —
   proof: the same valve alerted **drift → step → short** across one afternoon
   (contradictory faults can't coexist). Fix: **same-kind 2-cycle persistence
   gate** (0.25). Purged 33 noise alerts so the digest stayed clean.
   Calibration reverse-engineered: `R = 15.45/(I_raw − 0.114)`.
5. **Controller current path** (`nano_data_center/code/plc_io_cntrl_py3.py
   make_current_measurement`): ACS712-05B, `I=(V−2.52)/0.185` — hardcoded
   zero/gain, single sample, no per-channel cal. Controller is hard to change
   (runs 24/7), so all fixes are robot-side.
6. **Within-run current analysis split by valve class (0.26):**
   - **ETO** (15-25 min) → KB2_WR: boxcar segment-averaging + 1-5 min peak.
   - **non-ETO** (5-8 min) → coil_onset: only the **1-2 min spike vs END of run**.
   Both monitor-only. Self-normalizing (additions constant within a run).

Image history this session: 0.21 coil-onset → 0.22 coil-cohort → 0.23 coil-solve
→ 0.24 watchlist → 0.25 kb2-persist → 0.26 within-run. All armed, all monitor-only
additions (no actuation changed). Commits on `ra4m1-bringup`.

--- HISTORICAL (2026-05-29 build doc) ---

Pick-up doc for the parallel KB1/KB2/KB3/KB4 build. Read first on any
session resume.

**Strategy (locked 2026-05-29 evening, Glenn):** build KB2/KB3/KB4 as
**minimized chain_tree modules** running in parallel inside the robot.
Validate analysis math against organic operator cycles first. Defer
Zenoh + dashboard + persistence-service + RPC integration until all
four KBs' analysis is bench-green.

Memory anchor: `parallel-minimized-chain-trees-2026-05-29`.

---

## Current state (EOD 2026-05-29)

### KB1 — shadow robot (LIVE)

- **Status:** bare-LuaJIT shadow at `robot/` running continuously in WSL.
  PID 21518 at session wrap. Discord on (real channel, `[KB1 SHADOW]`
  prefix). No SKIP_STATION / CLOSE_MASTER_VALVE — observation only.
- **Logs:** `robot/var/kb1.log` (per-poll JSON), `robot/var/kb1_events.log`
  (per Discord event), `robot/var/last_stream_id` (past_actions cursor).
- **Open verification:** 120 s warm-up gate shipped 22:30 PT 2026-05-29
  but UNVERIFIED — first-morning job is to confirm zero MODE_1_LOW /
  MASTER_IDLE_LOW fires within 120 s of any overnight ACTIVE_RUN /
  MASTER_IDLE_CHECK entry. Recipe in
  `~/.claude/projects/-home-gedgar-motioncore-prototype/memory/irrigation_analytics_daily_review_workflow.md`.
- **Restart command:**
  ```
  cd robot && pkill -f 'luajit.*main.lua' || true; POLL_INTERVAL_S=10 ./run.sh &
  ```
- **Memory:** `kb1-design-locked-2026-05-29`,
  `irrigation-analytics-daily-review-workflow`.

### KB2 — post-event resistance analyzer (NOT IN ROBOT YET)

- **Status:** explore-side Python proven. Adaptive-baseline /
  cohort-residual / onboard-new-valve logic locked in design but not
  coded.
- **Scaffold scripts** (read-only after KB2 lands):
  - `explore/analyze_resistance.py` — MK-trend + family-residual + cohort z;
    `RECENT_N=2` median-of-last-2 (cuts within-day noise 16%).
  - `explore/stitch_r_history.py` — daily snapshot stitcher.
  - `explore/compare_snapshots.py` — cross-day diff.
- **Wired in KB1 already:** `kb2.run_resistance_analysis` enable on
  `RESISTANCE_CHECK → not-RESISTANCE_CHECK` edge; `kb2.update_curve` on
  every `IRRIGATION_STEP_COMPLETE`. KB2 just receives the enable.
- **Memory:** `kb1-design-locked-2026-05-29` (KB1↔KB2 plumbing section);
  `solenoid-failure-research-2026-05-26`;
  `irrigation-analytics-explore-state-2026-05-26`.
- **Build estimate:** 2 days when started.

### KB3 — real-time flow monitor (NOT STARTED)

- **Status:** design analogous to KB1 (mirror, flow side). Not coded.
- **Day-1 task:** verify popup has a live flow field (HUNTER_FLOW_METER
  or similar). KB1 only reads PLC_IRRIGATION_CURRENT + PLC_EQUIPMENT_CURRENT
  from popup today; flow may or may not be there. If yes → mirror KB1
  poll loop. If no → KB3 has to read TIME_HISTORY periodically (different
  pattern from KB1, more like KB4).
- **Modes:** mirror KB1 — low warn (Discord), high warn (Discord), trip
  (CLOSE_MASTER_VALVE for runaway flow = pipe break), fixed-limit safety.
- **Build estimate:** 1-2 days when started.

### KB4 — post-event flow + current fusion (NOT IN ROBOT YET)

- **Status:** explore-side Python proven today on 48 short runs. 6 raw
  flags reduced to 2 real escalations once we layered in user context +
  adaptive baseline thinking + cohort layer. See "Today's findings"
  below.
- **Scaffold scripts** (read-only after KB4 lands):
  - `explore/today_last_sample.py` — end-current vs kb1_thresholds μ.
  - `explore/today_flow_endpoint.py` — end-flow vs per-bin med ± MAD.
- **Key analysis features KB4 must own** (lessons from today):
  1. **Two-stream fusion** at `IRRIGATION_STEP_COMPLETE` — combine end-flow
     Δ and end-current Δ; sign pattern → failure-mode label (low+low=CLOG,
     high+low=BREAK+coil-aging, high+normal=pure BREAK, zero+normal=
     upstream block).
  2. **Adaptive baseline** — when N≥3 consecutive runs sit at a new
     stable level outside historic MAD, declare new baseline. Without
     this, sat_3:4 / sat_3:19 (today) fire CLOG/BREAK forever after a
     repair. Memory: same lesson logged in
     `kb1-design-locked-2026-05-29` KB3/KB4 sufficiency section.
  3. **Cohort / family-residual** — if ≥3 valves on same satellite in
     recent steps all show negative Δ, escalate as cohort alert (sat_4
     well-pressure pattern today: 3 of 4 didn't cross individual gate
     but cohort signal was clear).
  4. **Within-run scan** for `run_time ≥ 8 min` (mid-run regime change;
     `explore/within_run_scan.py` has the math).
  5. **ETO truncation handling** — `arming.eto_restriction_seen=true` →
     skip curve update; sample is biased toward early-phase.
  6. **`has_flow_signal` flag** — false for sat_1:1, 1:17, 1:28, 1:39,
     1:40 (city-water cohort, no Hunter flowmeter reading).
  7. **Bin class** — `eto_irrigation` vs `landscape` from
     `eto_site_setup.json` membership. Drives which chains fire.
- **Memory:** `irrigation-schedule-taxonomy-2026-05-29`,
  `kb1-design-locked-2026-05-29` (KB3/KB4 sufficiency section).
- **Build estimate:** 3-5 days when started.

---

## Today's findings (2026-05-29 PM) — design-shaping data

48 short runs (5–45 min, all `run_time` is MINUTES not seconds). Pulled
from past_actions XRANGE since midnight Pacific, cross-referenced
against TIME_HISTORY (last-N runs per bin).

### 6 raw flow flags → triage with operator context

| Bin | Class | Raw flag | Real diagnosis |
|---|---|---|---|
| sat_4:10 | ETO | CLOG | **Well-pressure droop in sat_4 cohort.** All 4 sat_4 ETO valves (4:9, 4:1, 4:10, 4:11) under-baseline 1.3-2.3 GPM in consecutive steps 30-34. Glenn adjusting timing to help. Verify tomorrow. |
| sat_3:11 | landscape | CLOG (0 GPM) | **Throw-away well-charge step** — schedule fixed at source (replaced with sat_1:39). Was BY DESIGN, not anomaly. |
| sat_3:4  | landscape | CLOG | **Step-change false positive.** Run 43 (~mid-May) dropped from 9 GPM → 7 GPM and stayed flat 6 runs. Repair / nozzle change. Adaptive baseline kills this. |
| sat_3:19 | landscape (right_bank) | BREAK | **Step-change false positive.** Run 43 (~mid-May) rose 3.3 GPM → 6 GPM and stayed flat. **Popped pivot head** (Glenn confirmed). Same fix as sat_3:4. |
| sat_2:2  | landscape | BREAK 22 GPM | **Real — worsening.** AM run 16.7 GPM, PM run 22 GPM, baseline 12.3. Within-today escalation = genuine signal. |
| sat_2:17 | landscape | low | Mild, noise-floor. |

**Cross-validation: sat_2:6 (NOT flagged) is the gold-standard true
negative.** Dashboard shows converging ~12 GPM; analyzer hist_med=11.3
and |z|=1.82 (no flag). Confirms the analyzer correctly distinguishes
healthy from anomalous when baseline is stable.

### Two real escalations

1. **sat_4 ETO cohort well-pressure** — needs cross-bin layer (KB4 must own).
2. **sat_2:2 worsening landscape BREAK** — needs trend-within-day rule.

### Three KB4 design must-haves crystallized

- **Adaptive baseline** (3 of 6 false positives traceable to this).
- **Cohort/family-residual** (1 real positive missed by single-valve threshold).
- **Two-stream fusion** (every failure-mode label needs both flow + current sign).

---

## Daily-cadence routine

Each morning before any code change:

1. **Verify robot still running:**
   `ps -ef | grep 'luajit.*main.lua' | grep -v grep` — should see PID.
2. **Today's slice + tonight's overnight events:**
   ```
   cd robot
   TODAY=$(date -u +%Y-%m-%d)
   grep "\"t\":\"$TODAY" var/kb1.log > /tmp/kb1_today.jsonl
   wc -l var/kb1_events.log    # any new Discord events?
   ```
3. **Check 120 s warm-up worked:** grep `var/kb1_events.log` for
   MODE_1_LOW / MASTER_IDLE_LOW. Should be 0 within 120 s of any
   IDLE → ACTIVE_RUN / IDLE → MASTER_IDLE_CHECK edge.
4. **Rerun yesterday's analyzers if irrigation ran overnight:**
   ```
   cd explore
   python3 today_last_sample.py    # end-current vs μ
   python3 today_flow_endpoint.py  # end-flow vs per-bin med ± MAD
   ```
5. **One fix per morning.** Pick the highest-priority issue from the
   overnight log; implement; restart robot; let it bake another day.

---

## Pickup order for next sessions

In priority for the next ~5 days:

1. **Tomorrow morning (2026-05-30):** daily review per above. Verify
   warm-up gate worked overnight. Check sat_4 cohort post-timing-fix.
2. **Tomorrow/+1:** KB3 minimum (verify popup live-flow field; if yes,
   mirror KB1 poll + 4 modes + Discord).
3. **+2:** KB4 v1 — end-flow + end-current fusion at STEP_COMPLETE,
   JSON-backed baselines, no adaptive logic yet (flag everything, tune
   day-by-day).
4. **+3:** KB4 adaptive baseline + cohort layer (today's lessons).
5. **+4:** KB4 within-run scan for ≥8-min runs + ETO truncation gate.
6. **+5:** KB2 chain_tree port of `analyze_resistance.py` + adaptive
   baseline + new-valve onboarding + cohort. (Or earlier if KB3/KB4
   timing slips.)

**Defer to integration phase (post-validation, ~+7):** Zenoh leaves,
dashboard widgets, application_gateway RPCs, SQLite/persistence-service
migration, flipping shadow-mode gates so KB2/KB4 can actually act.

---

## File map (for next session)

```
fleet_design/irrigation_analytics/
├── CONTINUE.md                              # THIS FILE
├── docs/                                    # README, design docs
│   └── README.md                            # solenoid failure research
├── robot/                                   # SHADOW LIVE
│   ├── main.lua                             # KB1 poll loop
│   ├── run.sh                               # launcher (LUA_CPATH for cjson)
│   ├── lib/
│   │   ├── controller.lua                   # SSH+Python+Redis popup/past_actions
│   │   ├── state_machine.lua                # 6-state classifier
│   │   ├── modes.lua                        # eval_mode4/eq/calibrated/master_idle
│   │   ├── thresholds.lua                   # V/R/IRR_TRIP_A/EQ_*/WARMUP_S constants
│   │   ├── discord.lua                      # wrapper over notification_service
│   │   └── logger.lua                       # JSON-per-line append writer
│   └── var/                                 # logs + cursor (in .gitignore)
└── explore/                                 # SCAFFOLD (Python; goes read-only when KB2/4 lands)
    ├── analyze_resistance.py                # → KB2
    ├── stitch_r_history.py                  # → KB2
    ├── compare_snapshots.py                 # → KB2
    ├── extract_bin_baselines.py             # → KB2 (curve generation)
    ├── derive_kb1_thresholds.py             # → KB1 (already shipped)
    ├── default_curve.py                     # → KB2 (cohort seeds)
    ├── within_run_scan.py                   # → KB4 (within-run regime scan)
    ├── within_run_topN.py                   # → KB4 (within-run flagging)
    ├── short_run_end_score.py               # → KB4 (FLOW end-only, older variant)
    ├── today_last_sample.py                 # → KB4 (end-current today's-runs analyzer; committed 2026-05-29)
    ├── today_flow_endpoint.py               # → KB4 (end-flow today's-runs analyzer; committed 2026-05-29)
    ├── kb1_thresholds.json                  # KB1 input (needs 1.75 A trip re-derivation)
    ├── stitched_r_history.json              # KB2 stitched daily R-history
    └── snapshots/YYYY-MM-DD/                # daily snapshot tree
```

## Memory anchor map

- `kb1-design-locked-2026-05-29` — KB1 full spec + KB3/KB4 sufficiency lessons
- `irrigation-schedule-taxonomy-2026-05-29` — ETO vs landscape, ETO truncation, has_flow_signal cohort
- `parallel-minimized-chain-trees-2026-05-29` — build sequencing strategy
- `irrigation-analytics-daily-review-workflow` — morning review recipes
- `solenoid-failure-research-2026-05-26` — physics anchors backing KB2 trip thresholds
- `new-irrigation-robot-design-2026-05-26` — historical (KB1 portion superseded)
- `irrigation-analytics-explore-state-2026-05-26` — earlier explore artifacts
