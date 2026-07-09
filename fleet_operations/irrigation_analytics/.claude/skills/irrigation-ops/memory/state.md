# Live state — LaCima irrigation site

Site-specific facts that change over time. Update on each deploy / field change.
Last updated: 2026-07-08.

## Deployed robot
- Image: `nanodatacenter/irrigation-analytics:0.70-well-active`
  (lineage: 0.67-leak-14-5 → 0.68-flow-absfloor → 0.69-flow-stepwatch → 0.70-well-active).
- Runs on the Pi (`ssh robot` = 192.168.1.66, hostname `labserver`/Debian 13 after the
  2026-06-23 SD-card crash+rebuild), container `irrigation-analytics`,
  dir `/mnt/ssd/farm/irrigation_analytics/` (MOVED off the boot card onto the SSD).
  Self-recovers across reboots (restart=unless-stopped + docker.service enabled).
- **DEPLOY via registry push/pull** now (`docker push` then `ssh robot docker pull`),
  NOT `docker save | ssh load`. Then bump IMAGE_TAG in fleet.env + `bash start.sh`.
- WSL/bench instance is normally STOPPED. **Never run it armed while the Pi is armed**
  (double-actuate). One armed instance only.

## Arming state (the gates)
| Knob (in Pi `fleet.env`) | Value | Effect |
|---|---|---|
| `SKIP_LIVE` | `1` | controller writes go LIVE (not dry-run) |
| `KB1_ARM_KILL` | `1` | KB1 overcurrent → CLOSE_MASTER + SKIP (IRR_KILL 1.5A non-city/1.8A city, EQ 1.8A) |
| `KB3_ARM_KILL` | `1` | KB3 leak → SKIP + insert 15-min 1:39 wait. Thresholds: **abs 14 GPM OR base+5 GPM, 4 consec** |
| `KB3_FLOW_ARM` | `1` | Hunter flow-deplete → SKIP + [wait → CLEAN_FILTER → reinsert]. 3 paths: deplete-from-steady, low-vs-baseline, **abs floor < 5.0 GPM (0.68)** catches clogs a suppressed baseline hides |
| `KB3_FOUL_ARM` | `1` | **CITY-WATER MONITOR / keep-well-active (0.70):** PLC(well)<3 while Hunter(city)≥4, non-city = run coasting on city → **SKIP + wait 15 + CLEAN_FILTER + re-run REMAINING on well** (was: no-skip wait+clean). Total dose unchanged; remainder off free well not paid city. **Watch schedule churn.** |
| `KB3_FLOWSTEP_ARM` | `1` | **flow step-watch (0.69), ALERT-ONLY:** per-run delivery step-up ≥1.5 GPM sustained = small developing leak the 14/+5 trips miss → YELLOW `FLOW_STEP_UP`, no actuation. `KB3_FLOWSTEP_GPM` tunes it. |
| `FIELD_LOG_ARM` | `1` | field-check action → baseline reset |
| `KB1_EQ_KILL_A` | `1.8` | EQ overcurrent kill level |
| `KB3_HYDRAULIC_ARM` | absent | divergence/well-exhaustion stay monitor-first (monitor-only) |

**Filter-clean is consolidated in kb3** (kb5 retired): both the Hunter-depletion clean and the
PLC-foul clean share ONE 90-min cooldown (kb3.db kb3_meta). kb3 also RETRO-ARMS on the
in-progress step at boot (a mid-run restart no longer blinds it).

To DISARM any: set the knob `=0` in Pi `fleet.env` + restart. NOTE: `start.sh` passes a
hand-listed `-e` env allowlist — a NEW knob must be added there too, or it won't reach
the container.

## Known field faults (open)
- **4:10 = pipe break (coyote pipe) — REPAIRED 2026-06-14.** It had been held out, but
  ran 06-14 (steps 33/34) above baseline, over-drew the well. Field-repaired; clean
  post-fix runs ~8 GPM (was ~11–12 leaking). `repair_leak` logged → watcher cleared the
  watch; baseline re-learning from clean runs.
- **4:11 = REPAIRED 2026-06-14** (`repair_leak` applied); clean ~6 GPM.
- **VALVE COIL HEALTH — full current+resistance sweep 2026-07-08** (details in auto-memory
  [[valve-health-findings-2026-07-08]]). Method: coil current = IRRIGATION_CURRENT steady −
  master; **master = valve 1:40 (~0.42-0.44 A, ALWAYS ON, gates the WELL); city water = 1:39.**
  Analyze by CABLE GROUP (same length → same baseline; lower-numbered banks draw more,
  4:1-8 > 4:9-15). Resistance = valve_test hash (per-valve time-series); warming is ADDITIVE
  (~+0.05 fleet-wide) so use ABSOLUTE change vs fleet, NOT ratio. Field-check priority:
  - **4:9 = ACTIVELY SHORTING (top).** The replaced coil is degrading: rising current
    (+0.013 drift), resistance rising only +0.018 vs fleet +0.053 (R dropping *relative* to
    the warming = shorting turns). Three signals agree. (SUPERSEDES the old "replaced, resolved.")
  - **3:2 = developing HIGH-R in its OWN leg.** Resistance step-jumped +0.10 and held (+0.091
    vs fleet). Runs with **4:12**, which warms normally → fault is 3:2's own coil/branch, NOT
    the shared feed. Field target: 3:2 solenoid + its lug, not the common cable.
  - **1:1 = mid-run current COLLAPSE (thermal).** Holds ~0.84 A for 2 min then drops to ~0.52
    every run; static R normal → sustained-thermal dropout. Confirm it's a normal solenoid
    (not an economizer type) before repair.
  - **4:7 = STABLE low-R, elective (downgraded).** Still ~3 Ω low + hottest in 4:1-8, but
    resistance trend is NORMAL (+0.056 ≈ fleet) = already-shorted but NOT worsening.
- **1:32 = external leak** (~13 GPM, within sensor range → trustworthy +5 flag; watch-listed).
- **3:5 = REAL LEAK (2026-07-08), NEEDS REPAIR.** Jumped from a stable ~7.5 GPM (8-day) to
  13.0 (+5.4 over base 7.62) → KB3 RED LEAK fired 13:14, SKIP+recharge. Coil current is fine —
  it's a pipe/flow leak (coyote-pipe class). Field target: 3:5 line.
- **4:4 = SLOW DEVELOPING LEAK (2026-07-08), NEEDS REPAIR.** Delivery stepped ~10→~12.3 around
  07-05, held 4 runs (+2). Sub-threshold (under 14 and under +5) so the gross leak trip missed
  it — caught by the new FLOW_STEP_UP watch. Field target: 4:4 line.
- **3:11 = sub-floor drip zone, working FINE** — marked `phantom=1` (reads ~0 = no data).
- **4:4** — watch: 5–15 gallons declining (109→101 post-Thu-fix), maybe a new ~2–3 head clog.

## Known field faults (open) — cont.
- **Well-source PLC flow meter is SAND-FOULED, reads false-ZERO (2026-06-19).** On
  `No_city_water` (well) runs the well-source meter (`main_flow_meter` / "PLC Flow Rate")
  reads a flat 0.00 while downstream Hunter holds steady 6–7 GPM (Filtered Hunter ~6.2,
  HiRes ~6–8, currents normal). **The well is HEALTHY** (Hunter confirms delivery); the
  meter sits in sandy raw well water and fouls — Hunter does not. Same meter read ~11 GPM
  at 16:00 06-19, flat 0 from ~19:48 → degrading through the day. **PLC=0 only means a
  fault on NON-city-water runs** (on `city_rose`/city runs the well meter reads 0
  normally — well is bypassed). **Trust Hunter, distrust PLC/well-flow on well runs.**
  Implications while fouled: (1) well-drawdown detector (KB3_WELL_ARM, armed) is BLIND —
  can't catch a real drawdown; flat-0 doesn't false-fire (no plateau) but an INTERMITTENT
  meter (plateau then re-clog to 0 mid-run) would look like a drawdown → false
  recharge+skip; (2) internal-leak rule `PLC≫HUNTER` is inverted (PLC≪HUNTER) → internal
  leaks incl. 4:9 MASKED on well runs. FIX = physically clean sand from the well flow
  meter. SOFTWARE idea: detect `PLC_well==0 & Hunter>~4 sustained on No_city_water` →
  alert "clean well meter" + auto-suppress PLC-based well/leak detectors. Verified live
  06-19 ~20:00 (29/30 samples PLC=0, Hunter 6–7), no false actuation that run.

## CLOGGED-FILTER signature + monitor (validated 2026-06-20, deployed `0.50-clog-monitor`)
- **The clogged well/main filter starves DELIVERY: Filtered Hunter sags below the bin's
  clean baseline while the well source is fine. Discriminator = HUNTER vs baseline, NOT
  PLC** — the PLC well meter is sand-fouled (false-0 on well runs), so any PLC/divergence
  rule false-fires. (Confirms Glenn: "the sensor is the Filtered Hunter.")
- **VALIDATED against the operator's manual clean-filter events 06-19/06-20** (clear sched →
  `clean filter` → re-queue, done 4×: 06-19 14:32, 06-20 08:02/16:11/16:14). Same valves
  recovered right after each clean: **4:10 5.0→7.7 GPM, 4:11 4.2→7.4 GPM** (base 9.69/5.79).
  Healthy steps deliver **0.85–0.92×** baseline; clog candidates **0.50–0.78×**. The filter
  re-clogs progressively across a cycle (4:4 0.63, 4:7 0.66, 3:18 0.71, 2:13 0.73, 2:15 0.75).
- **MONITOR deployed (log-only):** `lib/clog_filter.lua` + a block in
  `chains/kb3_sustained_user_functions.lua`, mirroring the well-drawdown monitor. Per ETO
  step (is_city excluded), median Hunter over min 5–15 (judged from min 9 to dodge the
  Filtered-Hunter lag); trips once/step at **Hunter < 0.75× baseline**. Logs `CLOG-FILTER
  [monitor] … WOULD: SKIP step, then rpush REVERSE [wait 1:39 15m → CLEAN_FILTER → reinsert]`.
  Gate `KB3_CLOG_ARM` (default OFF) for later arming. Watch:
  `ssh robot 'docker logs irrigation-analytics 2>&1 | grep -i CLOG-FILTER'`.
- **CAVEAT:** baselines are clog-depressed (4:11 base 5.79 < its post-clean 7.4 = 1.28×), so
  real deficits are understated. Arming needs a clean-filter-aware baseline refresh, and the
  CLEAN_FILTER + reinsert job formats (byte-matched, like WAIT_JOB) still need capturing.
- **`clean filter` is a logged PAST_ACTIONS action** (level RED) and a `mode_change` verb.
- **DESIGN PRINCIPLE (Glenn 2026-06-21): HUNTER is the source of truth; PLC never triggers
  an action by itself.** Hunter good + PLC bad → KEEP RUNNING, ignore PLC. A real well
  drawdown drops Hunter too, so the Hunter detector catches it; PLC (when trustworthy) only
  hints which remedy (Hunter-low + PLC-low ⇒ recharge; Hunter-low + PLC-normal ⇒ clean filter).
- **DISARMED `KB3_WELL_ARM` 2026-06-21** (Pi fleet.env → 0; backup `fleet.env.bak.well-arm-on`).
  The armed PLC-based well-drawdown detector was FALSE-SKIPPING healthy stations on the
  sand-fouled meter: 5 skips in 30h (steps 4,24,26,28,30) where PLC read 0/intermittent while
  Hunter delivered a healthy 7–8 GPM (e.g. 3:13 PLC=0 all run, Hunter ramped to 7.0 — skipped
  anyway). Well-drawdown is now monitor-only; KB3_ARM_KILL (Hunter leak) + KB1 stay armed.
  The well-drawdown (PLC) and clog-filter (Hunter) were "two detectors doing the same thing"
  → **DONE: consolidated into `lib/flow_deplete.lua`**. Hunter-ONLY. Two trip paths (once/step):
  (A) DEPLETION — Hunter drops below its own post-ramp steady; (B) LOW — steady < 0.75× baseline.
  RAMP-SAFE: only judges AFTER the slow Filtered-Hunter ramp (steady window min 10–15, no verdict
  before min 14) — fixed a 06-21 false fire on 3:18 that tripped at min 9 mid-ramp.
- **ARMED + VALIDATED 2026-06-21 (prod `0.52-flow-clean`, `KB3_FLOW_ARM=1`).** On a trip the
  recovery is ONE consistent action for low-flow OR clogged filter (Glenn "i believe the filter
  is bad"): `rpush(reinsert step)` + `rpush(CLEAN_FILTER)` + `rpush(1:39 wait)` + `SKIP` →
  controller pops **[wait → CLEAN_FILTER → re-run step]**. One clean+retry per step (anti-loop;
  a step still low after the clean is the head/valve, not the filter). CLEAN_FILTER + reinsert
  jobs byte-matched to live IRRIGATION_PENDING.
  **FIRST CONFIRMED AUTONOMOUS RECOVERY:** 2:15 (step 28) delivered **7.2 GPM (0.73× base 9.8)** →
  fired at min 14 → wait → CLEAN_FILTER (14:17) → 2:15 re-ran → recovered to **~10.4 GPM (1.06×)**,
  no re-fire. The filter WAS bad; the auto-clean fixed it (+44% flow). PLC well meter also read
  ~11–13 again on the retry (was false-0). Gate `KB3_FLOW_ARM`; disarm = set 0 + `bash start.sh`.
  NOTE: Pi `start.sh` must forward `-e KB3_FLOW_ARM` (added 06-21) or the gate silently no-ops.
  Watch: `ssh robot 'docker logs irrigation-analytics 2>&1 | grep -iE FLOW-DEPLETE'`.

## FIXED + DEPLOYED (prod `0.49-cursor-fix`, 2026-06-20) — clog/flow analysis blind: POISONED CURSOR (root-caused 2026-06-20)
- **DEPLOYED to the Pi 2026-06-20**: image `irrigation-analytics:0.49-cursor-fix` built,
  pushed, pulled on Pi, `fleet.env` IMAGE_TAG bumped, container relaunched. Verified live:
  all 5 chains (detector/kb4_clog/kb3_sustained/kb4_v2/kb2_within_run) fast-forwarded the
  past_actions cursor to a VALID stream id `1781997492898-0`; zero decode/Invalid-stream
  errors post-restart (vs continuous on 0.48). Commit `d1c4178` (controller_client.lua).
- **CODE FIX APPLIED 2026-06-20 in `lib/controller_client.lua`** (all 3 parts):
  (a) `past_actions_tip` rejects any output not matching `^%d+%-%d+$` → returns nil (caller
  keeps prior tip); (b) `past_actions_xrange` only builds `"("..last_id` when last_id is a
  valid stream id, else `min="-"` → full replay self-heals a poisoned cursor; (c)
  `run_remote_python` now sends stderr to its OWN file (not `2>&1`), so an ssh/python
  transport error can no longer masquerade as stdout data; empty stdout + nonempty stderr
  returns `nil,err`. **Still needs: irrigation-analytics image rebuild + redeploy to the
  robot.** Until redeployed, STOPGAP below still applies. Original write-up retained below.
- **detector/kb4_clog/kb4_v2/kb3/kb2_within_run have recorded NOTHING since ~14:40 06-19**
  (runs/runs_eto/flow_within all 0 rows in 22h; the whole 06-19 No_city_water cycle —
  35 steps GREEN, 0 alerts — went un-analyzed. Irrigation fine, MONITORING blind.)
- **ROOT CAUSE (not a redis/xrange bug per se):** the past_actions **cursor got poisoned
  with an SSH error string.** Live heartbeat shows `cursor=ssh: connect to host
  192.168.1.146 port 22: No route to host`. Chain: (1) transient robot->controller SSH
  failure during the 06-19 reboot/deploy turmoil; (2) `run_remote_python` uses `ssh ...
  2>&1` so the SSH error merged into stdout; (3) `past_actions_tip` only guards `raw==""`,
  so the non-empty error string passed as a "tip" and was stored as the cursor
  (kb3:131 / kb4_v2:72 set `last_stream_id = tip` unconditionally); (4) every
  `past_actions_xrange` then builds `min = "(" .. <error string>` (controller_client.lua:134)
  -> redis `ResponseError: Invalid stream ID`; (5) STUCK — cursor only advances on success,
  so it never recovers. Isolated calls with a clean cursor WORK (verified); only the running
  process's poisoned in-memory cursor fails.
- **FIX (robot-side lib/controller_client.lua):** (a) past_actions_tip: reject output not
  matching `^%d+%-%d+$` -> return nil; (b) past_actions_xrange: only build `"("..last_id`
  when last_id matches a stream id, else min="-" (self-heals via full-replay); (c) deeper:
  run_remote_python `2>&1` lets transport errors masquerade as data — separate stderr / check
  ssh exit. Needs irrigation-analytics image rebuild+redeploy.
- **STOPGAP:** restarting the container re-inits cursors to a fresh valid tip (controller
  reachable now) — but a future SSH blip re-poisons without the code fix.
- Related: `kb1 popup fetch ... Connection timed out during banner exchange` = same flaky
  robot->controller SSH link.
- KB2 watch: `sat_2_group_6 = 22.7 Ω` (06-20, vs single-digit peers) — 1 warn, single-cycle
  (below 2-consec alert gate). Confirm next cycle before treating as real.

## Pending / watch
- **⭐ NEXT BUILD (2026-06-15): KB3 leak CURVE detector.** The 06-14 4:10 break was
  missed because KB3 polls a damped popup channel (saw HUNTER=8.4 flat) once/min vs the
  real raw ~11–12 / PLC ~12–13.4 in the measurement stream. Fix = read the STREAM +
  per-bin RELATIVE baseline (+~3 GPM); leak lift measured at +3–4 GPM. Lowering the
  absolute 14→13 threshold was proven cosmetic and NOT shipped.
- **First live `KB3_WELL_ARM` actuation fired 06-14 on 4:11** (skip + recharge, both
  200, recovered correctly). It catches the downstream symptom, not the leak source.
- Multi-week monitors accumulating (read-time, no thresholds yet): flow_within clog
  trend, coil_decomp per-coil current trend, well-drawdown/internal-leak logs.
- **Modbus current-spike bug confirmed in BOTH channels (2026-06-19).** Unflushed
  serial-buffer desync (controller `myModbus_py3.py:1033`, see `my-irrigation-controller`
  project memory) lands garbage frames in the current data.
  - IRRIGATION (`plc_irrigation_1`/DF2): FREQUENT — single ~+0.20 A samples (~20σ vs
    sd≈0.01) within TIME_HISTORY runs; 74 outliers in last ~26h stream. **Per-run `mean`
    is diluted → spike-hunt on `max` vs `mean`.** Max seen ~1.31 A (< IRR_KILL 1.8A).
  - EQUIPMENT (`plc_slave_1`/DF1): RARE but DANGEROUS — only 1 spike in ~51h
    (06-17 18:06:02, **EQ=1.255 A**, flat IRR + steady 8.5 GPM = garbage, not load) but it
    **crossed EQ_KILL=1.2A**. Did NOT trip KB1 that time (PAST_ACTIONS normal, no
    CLOSE_MASTER/SKIP) — luck, not safety. A future equipment garbage frame aligned with a
    KB1 read would false-fire CLOSE_MASTER+SKIP. Don't dismiss equipment as "load only" —
    check single-sample jumps vs flow (real load tracks flow & is sustained; garbage is 1
    sample with flat flow). Equipment garbage is intermittent; a short window can miss it.
  - Clears on reboot (last 06-19 18:16). Fix scheduled 06-20 after nightly run. **The CRC
    + outlier-filter HARDENING is required (not optional) because the equipment channel
    feeds the KB1 kill** — the one-line flush alone won't stop a single frame from acting.
    Verify the fix by confirming the flush executes (a reboot already re-aligned framing,
    so "no spikes" won't prove it).
- **(SUPERSEDED) 4:9 shorted-turns** — 4:9 was REPLACED ~06-22; the new analysis target is
  **4:7** (confirmed shorted-turns by current AND valve_test resistance, see field faults).

## Site-specific tunings (current production values)
Well-drawdown detector: `WARMUP_MIN=5`, `PLATEAU_FROM/TO=5/12`, `DRAW_FRAC=0.78`,
`ONSET_CONSEC=2`, `WINDOW=4`/`WINDOW_HITS=3`, `HUN_DROP=1.5`, `GUARD_REMAIN_MIN=1`,
`IL_DIV_ABS=3.5`, `IL_SUSTAIN=2`. KB2 R calibration: `V_PSU≈15.4`, offset from null
channels `3:1`+`4:6`; branch median coil_R ≈ 43 Ω. KB1: IRR_KILL=1.5A non-city/1.8A city,
EQ_KILL=1.8 A. KB3 leak: abs 14 GPM OR base+5 GPM (`BASELINE_DELTA_GPM`), 4 consec. KB3 foul:
PLC<3 & Hunter≥4 for 3 consec. Filter-clean shared cooldown 90 min. Master `1:43` ≈ 0.46 A.
