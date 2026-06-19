# Plan for 2026-06-07 — complete the robot core

Goal: close the loop on the analytics core by making KB1 R-relative (uses
KB2's live coil R to set its current-low threshold instead of fixed bands)
and adding `R_HOT_WARN` to KB2 (predictive thermal-failure warning). This
completes the detector layer. Web + cross-robot integration (eto_sync,
dashboard polish, persistence cross-feeds) come the day after.

## State as of EOD 2026-06-06

Robot at `nanodatacenter/irrigation-analytics:0.4-kb2`, running on WSL.
Four chains live:

| chain | role | first-cycle status |
|---|---|---|
| monitor | popup heartbeat + persistence | OK |
| detector | KB1 modes + legacy KB3 live + **KB3-curve** (added today AM) | OK |
| kb4_clog | non-ETO + ETO post-run leak/clog detection | OK, 16 ETO runs classified today |
| **kb2_resistance** | per-cycle coil R, 2-null offset, rolling baseline | OK, first cycle 43 valves @ offset=0.1526 A |

KB2 SQLite at `/var/fleet/kb2/kb2.db`. Tables: `runs_kb2`, `baselines_kb2`,
`alert_state_kb2`, `cycle_state_kb2`. First cycle seeded baselines from
the latest valve_test cycle (correct strategy locked today — not the
3-cycle mean).

**Today's load-bearing findings (locked, do not re-derive):**

1. **Calc R = true coil R within 2 Ω** for all 5 meter-verified valves
   (sat_1:29/30/31/43/44). No per-channel ACS712 scaling needed.
   [[kb2-sensor-scale-finding-2026-06-06]]
2. **IRRIGATION_CURRENT during runs matches V/R expected** within 0.5-8%
   when using the same 2-null offset. The 5-8% under-prediction on
   high-current bins is the upstream wire voltage drop. Lock: PSU=15.6 V,
   master R = 40 Ω.
3. **sat_3:1 is electrically near-null** (no real coil) — explains both
   why it works as offset reference AND why sat_3:1/sat_3:7 bin's current
   matches master + sat_3:7 only.
4. **R_STEP_NOTED detector is live** — catches the maintenance-event
   signature (5+ Ω one-cycle jump vs prior). KB2 logs but does not
   Discord-push step events; they're informational.

## What we're building tomorrow

### Track A — KB2 `R_HOT_WARN` (new classification)

Solenoid coils in direct summer sun heat to ~75 °C. Copper TCR = +0.393%/°C
gives a 50 → 60 Ω swing (R rises 20%, I drops 16%). At some I_holding, the
valve mechanically closes — a real failure mode. We want predictive warning
BEFORE the valve trips.

#### Logic (in `lib/kb2_resistance.lua`)

Add to `M.classify`:

```
R_HOT_WARN  trigger: R > baseline_med + 5 Ω        AND cohort_excess > 5%
R_HOT_ALERT trigger: R > baseline_med + 10 Ω       AND cohort_excess > 5%
                  OR  R > baseline_med + 5 Ω        AND cohort_excess > 10%
```

#### Cohort common-mode rejection (the critical piece)

If EVERY valve rises 10% simultaneously, that's ambient heating — NOT a
focal fault. Suppress universal warnings.

Implementation in `chains/kb2_resistance_user_functions.lua` KB2_TICK:

1. **First pass:** compute R, baseline lookup, raw classify for each valve.
   Cache per-valve `relative_drift = (R - baseline_med) / baseline_med`.
2. **Cohort pass:** `cohort_median_drift = median(relative_drift) over
   valves with R_DRIFT_WARN, R_HOT_*, or OK classifications`.
3. **Second pass:** for each valve, `excess = relative_drift - cohort_median_drift`.
   If excess > 5% AND R > baseline + 5 Ω, upgrade cls to R_HOT_WARN.
   If excess > 10% OR (R > baseline + 10 Ω AND excess > 5%), upgrade to R_HOT_ALERT.
4. **Discord:** R_HOT_WARN → bundle into the per-cycle notify; R_HOT_ALERT
   → bundle PLUS prefix with "🌡️ HOT".

#### Tuneables (new in M.*)

```
M.HOT_WARN_DELTA_OHM    = 5.0
M.HOT_ALERT_DELTA_OHM   = 10.0
M.HOT_WARN_COHORT_PCT   = 0.05   -- 5 %
M.HOT_ALERT_COHORT_PCT  = 0.10   -- 10 %
```

All overridable via env vars (mirror KB3-curve pattern):
`KB2_HOT_WARN_DELTA_OHM`, etc.

#### Database: add to runs_kb2 schema (additive migration)

Already has `cls`, `severity`, `delta_baseline`. Add:
- `cohort_drift_pct REAL` (per-cycle cohort median drift)
- `relative_drift_pct REAL` (per-valve normalized drift)
- `excess_drift_pct REAL` (per-valve excess over cohort)

These are diagnostic columns — surface in the dashboard later.

### Track B — KB1 R-relative thresholds

Today's KB1 (`lib/modes.lua` + `lib/baselines.lua` curves) uses fixed
`i_low_open` per bin. Replace with computed `expected_I` from KB2 R.

#### Code changes

1. **`lib/modes.lua`** — new function `expected_current_for_bin(bin_key, kb2_R_table, null_offset, R_master)`:

   ```
   expected = R_master and (15.6 / R_master) or 0.39   -- master always on
   for each valve V in bin_key:
       R = kb2_R_table[V]
       if R and R > 18 then expected += 15.6 / R
       end
   end
   return expected + null_offset
   ```

   - Skip valves with no R (treat as 0 contribution — same as the
     sat_3:1 "null channel" case)
   - Apply small terminal-V drop correction:
     `expected = expected * 0.93` (the ~7% wire-drop empirical factor)

2. **`lib/modes.lua` evaluate_calibrated_modes** — replace
   `baseline.i_low_open` reference with `expected_I × 0.85` (15% margin).
   Keep fallback to static `i_low_open` when KB2 R is missing for any
   constituent valve.

3. **`chains/detector_user_functions.lua`** — pass KB2 R table into
   Modes.evaluate via the ctx parameter (already passes ctx). Add to bb:

   ```
   bb._kb2_last_R = read_baselines_kb2_last_R(kb4.db_path)
   ```

   Refresh this from kb2.db at boot AND at start of each STATION_START
   (cheap query, ~43 rows).

#### Critical: keep fallback path

Until we have weeks of valve_test cycles, some valves may not have
mature baselines. KB1's static `i_low_open` from the curves JSON stays
as fallback. Only use R-relative when KB2 has a confidence-positive R
for ALL valves in the bin (n_healthy >= 3 in baselines_kb2).

### Track C — Wire-drop correction in KB2 expected math (small, last)

A small refinement that closes the IRRIGATION_CURRENT vs V/R 5-8% gap
on high-load bins. Used in KB1's expected_current_for_bin (Track B uses
the empirical 0.93 factor for now; this makes it physics-grounded):

```
V_term = V_PSU - I_total * R_upstream
where R_upstream defaults to 1.7 Ω (sat_1:29 baseline)
solve iteratively (one pass converges):
   I_total_0 = V_PSU/R_combined
   V_term_1  = V_PSU - I_total_0 * R_upstream
   I_total_1 = V_term_1/R_combined
```

Defer to Track B if time permits; otherwise the 0.93 empirical multiplier
is fine for v1.

## Order of work

1. **Track A first** (KB2 R_HOT_WARN). Pure addition, no refactor risk.
   ~80 lines.
2. **Track B** (KB1 R-relative). Refactor, needs careful test against
   one of today's IRRIGATION_CURRENT traces. ~120 lines.
3. **Rebuild IR + image 0.5-hotwarn-r-relative** and deploy WSL.
4. **Verify cold path** — both KBs alive, KB2 R_HOT_WARN classification
   present in runs_kb2 (zero-fire on first cycle is fine — it's currently
   cool here in late evening).
5. **Force-fire R_HOT_WARN** via env var override
   (`KB2_HOT_WARN_DELTA_OHM=-3` makes any healthy valve trigger) — confirm
   Discord push + cohort rejection both work. Reset to default after.
6. **KB1 fallback verification** — kill KB2's last_R for one bin and
   confirm KB1 falls back to static i_low_open without errors.

## What's NOT in scope tomorrow (deferred to day after)

- Dashboard panel for KB2 / KB3-curve runs + baselines table
- application_gateway query RPC for `valve_resistance/latest`
- Cross-robot integration: feeding KB2 R_HOT_WARN into eto_sync (e.g.
  reduce ETO multiplier if many R_HOT_WARN signals = degraded fleet)
- Promotion of WSL image to Pi production (replaces 0.1)

## Promotion gate (after day-after)

Image gets promoted to Pi once:
- KB2 has run for 3+ days without crashes on WSL
- KB1 R-relative tested through one summer-warm afternoon (verify no
  false CUR_LOW fires when ambient heats coils)
- Dashboard surfaces KB2 baselines + runs

## Memory references

- [[kb2-sensor-scale-finding-2026-06-06]] — calc R = true coil R, no
  per-channel scaling
- [[kb2-chain-landed-2026-06-06]] — KB2 chain implementation (today)
- [[kb4-chain-landed-2026-06-05]] — architectural pattern KB2 mirrors
- [[irrigation-channel-physics-2026-05-30]] — master, null, city-water
  topology context
