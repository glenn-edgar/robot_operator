# Live state — LaCima irrigation site

Site-specific facts that change over time. Update on each deploy / field change.
Last updated: 2026-06-14.

## Deployed robot
- Image: `nanodatacenter/irrigation-analytics:0.38-well-arm`.
- Runs on the Pi (`ssh robot` = 192.168.1.66), container `irrigation-analytics`,
  dir `/home/pi/farm/irrigation_analytics/`. Self-recovers across reboots.
- WSL/bench instance is normally STOPPED. **Never run it armed while the Pi is armed**
  (double-actuate). One armed instance only.

## Arming state (the gates)
| Knob (in Pi `fleet.env`) | Value | Effect |
|---|---|---|
| `SKIP_LIVE` | `1` | controller writes go LIVE (not dry-run) |
| `KB1_ARM_KILL` | `1` | KB1 overcurrent → CLOSE_MASTER + SKIP |
| `KB3_ARM_KILL` | `1` | KB3 leak → actuate |
| `KB3_WELL_ARM` | `1` | well-drawdown → rpush recharge + SKIP (ARMED 2026-06-14, first live run not yet observed) |
| `FIELD_LOG_ARM` | `1` | field-check action → baseline reset (live-testing) |
| `KB3_HYDRAULIC_ARM` | absent | divergence/well stay monitor-first |

To DISARM any: set the knob `=0` in Pi `fleet.env` + restart. NOTE: `start.sh` passes a
hand-listed `-e` env allowlist — a NEW knob must be added there too, or it won't reach
the container.

## Known field faults (open)
- **4:10 = pipe break (coyote pipe) — REPAIRED 2026-06-14.** It had been held out, but
  ran 06-14 (steps 33/34) above baseline, over-drew the well. Field-repaired; clean
  post-fix runs ~8 GPM (was ~11–12 leaking). `repair_leak` logged → watcher cleared the
  watch; baseline re-learning from clean runs.
- **4:11 = REPAIRED 2026-06-14** (`repair_leak` applied); clean ~6 GPM.
- **4:9 = internal leak** (also ~6 Ω below same-branch peers = shorted-turns suspect).
- **1:32 = external leak** (~13 GPM, within sensor range → trustworthy +5 flag; watch-listed).
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
- **4:9 shorted-turns NOT supported by solenoid current (2026-06-19).** 4:9 IRR≈1.03 A
  sits mid-pack among branch-4 peers (4:4 .96, 4:7 .99, 4:11 .97, 4:1 1.05, 4:10 1.10) —
  shorted turns would read cohort-HIGH. The "~6 Ω below peers" KB2 flag isn't showing in
  current; recheck KB2 resistance to confirm/refute before treating 4:9 as a coil fault.

## Site-specific tunings (current production values)
Well-drawdown detector: `WARMUP_MIN=5`, `PLATEAU_FROM/TO=5/12`, `DRAW_FRAC=0.78`,
`ONSET_CONSEC=2`, `WINDOW=4`/`WINDOW_HITS=3`, `HUN_DROP=1.5`, `GUARD_REMAIN_MIN=1`,
`IL_DIV_ABS=3.5`, `IL_SUSTAIN=2`. KB2 R calibration: `V_PSU≈15.4`, offset from null
channels `3:1`+`4:6`. KB1: IRR_KILL=1.8 A, EQ_KILL=1.2 A. Master `1:43` ≈ 0.46 A.
