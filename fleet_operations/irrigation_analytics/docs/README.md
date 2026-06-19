# Solenoid Failure Research Synthesis

**Robot:** `irrigation_analytics` (working name — renameable)
**Scope:** background for KB1 + KB2 design on the LaCima irrigation controller (192.168.1.146).
**Status:** research note, design phase, no code yet.

This document collects the external literature on irrigation/industrial
solenoid failure modes and reduces it to the signatures that are
actually detectable with our hardware (PLC ADC 12/13-bit, ACS712 5A
Hall sensor, 1-minute aggregate current sampling, no HF impedance).

The operator's four mode taxonomy is well-supported by the literature —
this doc cites the support, then translates each mode into a detector.

---

## 1. Two-phase degradation model (literature-confirmed)

Multiple peer-reviewed studies converge on the same picture:

### Phase 1 — incipient creep (weeks to months)

- Inter-turn insulation undergoes slow thermal creep deformation;
  effective insulation layer thins.
- **DC resistance is essentially stable** in this phase — bulk copper
  conductivity is not changing.
- What IS changing: turn-to-turn capacitance rises, coil resonant
  frequency drops, an "insulation health indicator" (IHI = thinning
  ratio) drifts downward.
- **Not detectable from DC current alone.** Requires HF impedance
  or LCR sweep. **Out of scope for the irrigation controller.**

### Phase 2 — cascade (minutes to hours, ending in burnout)

- First inter-turn short forms.
- For a typical 43 Ω, ~500-turn irrigation valve coil:
  - ΔR per shorted turn ≈ 43 / 500 ≈ **0.086 Ω**
  - ΔI per shorted turn at 15.5 V ≈ **0.7 mA**
  - **Below ACS712 5A noise floor (~5–10 mA)** — a single turn shorting
    is not directly visible in our stream.
- Cascade: more current → more I²R heat → more shorts → runaway.
- Cascade duration: **seconds in motors, minutes in larger solenoids.**
  This exactly matches the operator's observation that mode-3 spikes
  "last minutes" before either self-extinguishing or causing hard failure.

> **Key insight:** the "spike lasts minutes then later fails" pattern is
> not a separate failure mode — it is *literally* the Phase 2 cascade,
> and a self-extinguishing spike is a cascade that briefly opened
> (insulation re-solidified after partial melt). That valve almost
> certainly fails on its next or next-few runs.

---

## 2. Key physics constants (use directly in code)

| Quantity | Value | Source |
|---|---|---|
| Copper temperature coefficient α | **0.0039 / °C** | Universal |
| R(T) | `R_25 · (1 + α (T − 25))` | Universal |
| T from R | `(R(T)/R_25 − 1)/α + 25` | Universal |
| 100 °C rise impact | **+39 % R, −28 % I** at constant V | Computed |
| Solenoid thermal time constant τ | **≈ 10 min** | Industry typical |
| Time-to-steady-state | **~3 τ ≈ 30 min** | Industry typical |
| Life vs temperature | **−10 °C → 2× life** (universal rule) | All sources |
| Life vs overvoltage | 15 % over → −50 % life; 30 % over → −90 % life | Bepto |
| Insulation Class A max T | 105 °C | Industry standard |
| Insulation Class B max T | 130 °C | Industry standard |

The temperature-from-resistance back-calculation is the workhorse of
KB2: given calibrated R_cold from the daily IRRIGATION_VALVE_TEST and
measured R_hot from the run, we recover T_coil(t) directly.

---

## 3. Detectable signatures (mapped to our hardware)

### What we CAN detect

1. **T_coil(t) live via R back-estimation.**
   Available only in solo-zone segments, or in multi-zone segments after
   per-valve step-edge decomposition succeeds. The math is direct.

2. **Asymptote-R drift run-over-run** (Phase 2 *early*).
   Per cycle the drop is below noise floor, but trend over weeks is
   detectable. Mann-Kendall test on per-valve R_asymptote, stratified
   by sun-exposure cohort and ambient temperature. KB2 work.

3. **Upward I excursion within a run** (Phase 2 *late* / active cascade).
   Healthy thermal evolution is monotone-down toward asymptote.
   ANY sustained upward excursion is anomalous. KB1 detector.

4. **Self-extinguishing spike** (cascade survived).
   Spike sample sandwiched between normal samples. Highest-priority
   alert — next-run failure probability is high.

5. **Heat margin** = T_insulation_class − T_asymptote_estimated.
   Continuous remaining-life proxy. Class A at 105 °C means margin
   shrinks as a valve drifts up; <15 °C margin = expect cascade soon.

6. **Cohort asymmetry.**
   Sun-cohort valves should reach higher asymptote than shade-cohort.
   A shade-cohort valve trending into sun-cohort range = environmental
   change (canopy loss) or thermal degradation.

7. **Flow × current cross-validation.**
   - Current normal, flow low → mechanical (stuck diaphragm, debris)
   - Current low, flow low → electrical (coil failed)
   - Current high, flow normal → cascade in progress (mode 3)
   - Current normal, flow high → leak with healthy valve
   This is the only path to distinguish electrical from hydraulic faults.

### What we CANNOT detect with this hardware (drop early)

- **Phase 1 creep.** Needs HF impedance / capacitance measurement.
- **Per-actuation inrush signature.** PreMa-style TinyML waveform
  classification needs sub-second sampling.
- **Single-turn short from instantaneous DC R.** Below noise floor;
  only *trend in R asymptote* works.
- **Frequency-domain analysis.** 1-min sampling → Nyquist 0.5/min;
  no useful spectral content.

---

## 4. KB1 vs KB2 split — research alignment

The two-phase model maps cleanly to the locked KB1/KB2 split:

| | KB1 (real-time, 60 s) | KB2 (offline, event-driven) |
|---|---|---|
| Phase 1 (creep) | n/a | n/a (not detectable) |
| Phase 2 early (asymptote drift) | n/a | Mann-Kendall trend |
| Phase 2 late (active cascade) | Upward-I detector → SKIP_STATION | Cascade event log |
| Mode 1 (no current) | I_sample ≈ 0 with valve expected on | post-mortem |
| Mode 2 (sub-operational drop) | I deficit vs expected | trend analysis |
| Mode 3 (multi-min spike) | I > 1.5× expected sustained | post-mortem |
| Mode 4 (hard short) | I → wire limit + supply sag | post-mortem |
| Per-valve expected-I seed | reads from KB2 model | maintains the model |

KB2's per-valve health model is the **expected-I table** that KB1 reads
each cycle. This closes the loop: daily check + post-run analysis
calibrate the table; real-time detector uses it.

---

## 5. Heat margin worked example

For a sat_2:13 valve (extra-wire constant +6 Ω, healthy R_cold ≈ 49 Ω):

- I_expected_cold = 15.5 / 49 = 0.316 A
- Suppose run asymptote settles at I = 0.270 A → R_hot = 57.4 Ω
- T_hot = (57.4/49 − 1)/0.0039 + 25 = 25 + 44 = **69 °C**
- Insulation Class B margin: 130 − 69 = **61 °C** — healthy

If 6 months later same valve same run conditions reads I = 0.230 A:
- R_hot = 67.4 Ω → T_hot = 121 °C → margin = 9 °C — **flag impending failure**

The dropping margin is the actionable signal — not the absolute R.

---

## 6. Sources

### Primary research
- [Degradation Monitoring of Insulation Systems Used in Low-Voltage Electromagnetic Coils under Thermal Loading from a Creep Point of View](https://pmc.ncbi.nlm.nih.gov/articles/PMC7374401/) — the canonical two-phase model, IHI metric, DCR threshold math.
- [Failure Mechanism Study of Direct Action Solenoid Valve Based on Thermal-Structure Finite Element Model (IEEE)](https://ieeexplore.ieee.org/document/9045932/) — stepwise "mutations of temperature and resistance" during degradation.
- [Health monitoring of solenoid valve electromagnetic coil insulation under thermal deterioration (ResearchGate)](https://www.researchgate.net/publication/303647058_Health_monitoring_of_solenoid_valve_electromagnetic_coil_insulation_under_thermal_deterioration) — companion piece on HF impedance trends.
- [Data-Driven Prognostics of Alternating Current Solenoid Valves (ResearchGate)](https://www.researchgate.net/publication/342139837_Data-Driven_Prognostics_of_Alternating_Current_Solenoid_Valves) — current-signature feature extraction.
- [Fault Diagnostic Opportunities for Solenoid Operated Valves Using Physics-of-Failure Analysis (ResearchGate)](https://www.researchgate.net/publication/282380189_Fault_diagnostic_opportunities_for_solenoid_operated_valves_using_physics-of-failure_analysis) — physics-of-failure taxonomy.
- [Fault State Detection and RUL Prediction in AC Powered Solenoid Operated Valves (ScienceDirect)](https://www.sciencedirect.com/science/article/pii/S1738573319308435) — ML approach on coil current.
- [Failure Type Prediction Using Physical Indices and Data Features for Solenoid Valve (MDPI)](https://www.mdpi.com/2076-3417/10/4/1323) — feature engineering reference.
- [Reliability and Life Study of Hydraulic Solenoid Valve, Part 2 (Auburn)](https://www.eng.auburn.edu/~choeson/Publication/1132_2009_Reliability%20and%20life%20study%20of%20hydraulic%20solenoid%20valve-Part%202%20_S.%20V.%20Angadi,%20R.%20L.%20Jackson.pdf) — life-test methodology.
- [PreMa: Predictive Maintenance of Solenoid Valve in Real-Time at Embedded Edge-Level (arXiv 2211.12326)](https://arxiv.org/abs/2211.12326) — TinyML on coil-current waveform; useful for what we *can't* do at 1-min rate.
- [Thermal Aging Studies of Solenoid Coil Insulation Systems (IEEE)](https://ieeexplore.ieee.org/document/7456056/) — life-vs-temperature accelerated aging.

### Industry references
- [Solenoid Coil Resistance vs Temperature (Electric Solenoid Valves)](https://electricsolenoidvalves.com/blog/solenoid-coil-resistance-vs-temperature/) — α and R(T) formula.
- [Solenoid Valve Duty Cycle (Electric Solenoid Valves)](https://www.electricsolenoidvalves.com/blog/solenoid-valve-duty-cycle/) — thermal time constant.
- [Failure Analysis: Technical Root Causes of Solenoid Coil Burnout (Bepto)](https://rodlesspneumatic.com/blog/failure-analysis-the-technical-root-causes-of-solenoid-coil-burnout/) — 10 °C / 2× life rule, overvoltage curves.
- [How to Test a 24V DC Solenoid Valve (Atos)](https://www.atosolenoidvalves.com/how-to-test-a-solenoid-valve.html) — DC-specific R thresholds.
- [How Does Temperature Affect Solenoid Valve Coils And Performance? (Bost Hydraulic)](https://www.bosthydraulic.com/news/how-does-temperature-affect-solenoid-valve-coils-and-performance/) — thermal management context.

### Patents (current-signature detection)
- US 7,609,069 — Method to Detect Shorted Solenoid Coils.
- US 5,506,508 — Apparatus for Detecting a Shorted Winding Condition of a Solenoid Coil.
- US 6,917,203 — Current Signature Sensor.
- US 11,243,269 — Spool Fault Detection of Solenoid Valves Using Electrical Signature.
- US 6,621,269 — System for Monitoring Solenoid Flyback Voltage Spike.
- US 12,540,686 — Monitoring a Health Status of a Solenoid.

---

## 7. Decisions locked by this research

1. KB1 detector rules are physics-justified for modes 1, 3, 4. Mode 2
   (sub-operational drop) requires the KB2 expected-I table; KB1 falls
   back to crude threshold (e.g., < 0.5 × cohort mean) on day 1.
2. Heat-margin is the right remaining-life proxy *in principle*, **but
   see §8 — not applicable to LaCima with current sensor stack**.
3. R_hot from each run is NOT recoverable from this data — master valve
   parallel + supply/sensor calibration unknowns. **Use cold-R from
   daily test as the primary R proxy.**
4. Per-valve trend (Mann-Kendall) stratified by sun-exposure cohort is
   the right early-warning detector, not population-wide R thresholds.
5. Drop HF-impedance / spectral-analysis ideas — not feasible with our
   sampling and sensor stack.

---

## 8. Why the heat-margin model fails on this data (2026-05-27 finding)

The literature says heat margin = T_class − T_asymptote is the right
RUL proxy. The math:

    R_hot = V / I_asym − R_wire
    ΔT    = (R_hot − R_cold) / (R_cold · α)        α = 0.0039 /°C for Cu
    T_asym = T_ambient + ΔT
    margin = T_class(130 °C) − T_asym

**Walked through on sat_1:20/1:39 last normal run (run 43, I_asym=1.20 A,
parallel decomposed assuming R_master=40 Ω):**

    R_parallel = 15.5 / 1.20 = 12.92 Ω
    R_zone     = (R_par · R_master) / (R_master − R_par) = 19.08 Ω
    ΔT         = (19.08 − 43) / (43 · 0.0039) = **−143 °C**
    T_asym     = 25 + (−143) = **−118 °C  ← unphysical**

**The model produces negative T_asymptote, which is impossible.** The
copper temperature coefficient says R must *rise* with heating, so R_hot
must exceed R_cold. Observed R_hot (after master decomposition) is
*below* R_cold by a factor of >2.

**Three blocking measurement-stack issues:**

1. **Master valve always parallel during runs** — even "solo" bins in
   time_history energize the master in parallel with the zone valve.
   Decomposition requires assuming R_master, which we don't know
   independently. See
   [[master-valve-parallel-correction-2026-05-27]].

2. **Supply voltage may differ between cold-R test and run-time.** The
   daily R-scan likely uses a 12 V test pulse; runs energize at 24 V AC.
   Without knowing the run-time voltage, V/I gives the wrong R.

3. **ACS712 calibration regime mismatch.** The 0.0133 A offset we
   physically anchored is for the cold-R test current range (~0.4 A
   single-valve). At run-time currents (0.7–1.2 A) and possibly AC
   excitation, that offset is not validated.

**Operational consequence**: do NOT build a thermal-rise inference
component. The KB2-daily R-drift Mann-Kendall trend on cold-R is the
*de facto* RUL proxy for this system. It catches mode 2 with high
fidelity (sat_2:4 caught at z=−2.09). It does not catch mode 4 (which
is runway-less anyway — see `failure_signatures.md`).

If a future hardware upgrade lands per-zone current sensing with known
supply voltage, this model becomes computable. Until then it is
recorded as theoretically-sound but data-blocked.

---

## 8. Cross-references in this repo

- `/home/gedgar/.claude/projects/.../memory/new_irrigation_robot_design_2026-05-26.md` — robot design state
- `/home/gedgar/.claude/projects/.../memory/irrigation_sensor_state_2026-05-26.md` — hardware facts
- `/home/gedgar/.claude/projects/.../memory/irrigation_controller_access_patterns.md` — wire facts, past_actions bus
- `/home/gedgar/motioncore-prototype/fleet_design/var/irrigation_probe/` — bench probe workspace
