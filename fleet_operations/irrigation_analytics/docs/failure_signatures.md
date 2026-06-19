# Solenoid Failure Signatures — Data-Driven

This document is the **detector reference**. Each mode is paired with its
detectable signature on the irrigation current trace, validated against
real labeled failure events mined from the LaCima time-history record
(2026-05-26 snapshot).

For background physics see [`README.md`](README.md).

---

## Summary table

| Mode | Mechanism | Where seen | Detector |
|------|-----------|-----------|----------|
| 1 | Incipient enamel creep | HF impedance only | **out of scope** for I-detector |
| 2 | Slow R-drift (aging) | daily R-scan | KB2-daily — `R_corr` trend & cohort z |
| 3 | Intermittent cascade | within-run I(t) | KB1 — `peak/asym > 1.5` post-sample[0] |
| 4 | Hard short / dead-short | within-run I(t) | KB1 — `I_asym > 2.0 A` or `peak > 5 A` |

The strong claim from the data: **mode-4 hard shorts have no warning runway
in I(t)**. Forty-four perfectly normal runs preceded sat_1:20's cataclysm.
The only viable prediction path is mode-2 R-drift caught by the *cold-R*
daily scan, which is independent of run-time current.

---

## Mode 1 — Incipient enamel creep

**Mechanism**: micro-cracks in coil enamel insulation produce minute
turn-to-turn leakage that does NOT yet cause measurable DC current change.
Detectable only by HF impedance / partial-discharge testing — instruments
we do not have.

**Detector signature**: **none in I(t) or daily R**. Documented for
completeness; do not write a detector for this.

**Operational implication**: any valve old enough to be mode-1 will
eventually progress to mode 2 (R-drift) where we *can* see it. Don't
attempt to catch mode 1; catch mode 2.

---

## Mode 2 — Slow R-drift (aging open)

**Mechanism**: progressive winding-resistance increase from coil oxidation,
internal connection corrosion, or partial-turn loss. R rises gradually
(weeks-to-months). Eventually crosses an absolute threshold where the
controller can no longer pull-in the plunger reliably ("won't operate").

**Real example — sat_2:4 (replaced 2026-05-27)**:

Daily R-scan, last 20 days (newest right):

```
ord:  -19 -18 -17 -16 -15 -14 -13 -12 -11 -10 -9 -8 -7 -6 -5 -4 -3 -2 -1 0
R:    38  36  33  37  40  43  44  39  40  38  39 38 38 40 39 37 37 40 37 35
```

- Range: 33–44 Ω (noisy ±5 Ω daily, structural drift visible)
- Cohort z-score: −2.09 (sun cohort μ = 38.6, σ = 1.7) → outlier
- Field measurement on replacement day: 35 Ω → confirmed real failure
- Replacement new solenoid: 43 Ω (new-install spec)

**Detector**: `KB2-daily/cohort_z_score < −2.0` AND `mk_p < 0.10` AND
`mk_tau < 0` (Mann-Kendall trend test on R-series, negative tau = R falling).
Implemented in `explore/analyze_resistance.py`.

**Replacement-event signature**: R jumps from depressed band (33–40 Ω) to
new-install band (40–48 Ω). Implemented in `explore/detect_replacements.py`:

- ΔR ≥ 6 Ω vs pre-window median
- ≥60% of 5-reading pre-window below `R_after − 6 Ω`
- R_after in [40, 48] Ω
- Multi-valve same-ordinal events demoted to system-event (wire/terminal/supply change)
- Next-day persistence required (real replacement does not oscillate back)

---

## Mode 3 — Intermittent cascade (incipient hot short)

**Mechanism**: thermal runaway — partial inter-turn short heats coil →
copper TC raises R → BUT shorted turns reduce effective winding →
net effect: bursts of high current intermixed with normal periods. The
literature describes a multi-minute cascade within a single run as the
classic mode-3 signature.

**Best partial example — sat_1:20/sat_1:39 run 44**:

Sample-by-sample current (5-sample run, 1-minute interval):

```
sample:  0     1     2     3     4
I (A):   1.13  7.29  7.28  1.08  1.08
```

Interpretation: run was *transitioning* into hard short. Two samples at
7.3 A (full short), two samples back at ~1.1 A (intermittent partial
contact). One run later (run 45) it's sustained 5.20 A with 7.27 A peaks
— now in mode 4.

**Detector**:
```
for sample i in run, i > 0:
    if sample[i] > 1.5 × bin_baseline_asym: → spike
if spike_count(run) ≥ 1: → mode-3 candidate
```

**Important calibration caveat**: sample[0] is unreliable — known timing
race (σ = 0.153 vs σ = 0.005 at sample[1]). Always start spike detection
at sample[1]. Documented in
[[characterize_runs.py findings 2026-05-26]].

**Open question**: a longer dataset would likely show classical mode-3
runs that *don't* progress to mode 4 in the same session — coils that
spike and recover. We see only the one example transitioning straight
to mode 4 within 2 runs. Worth re-investigating after collecting more
labeled events.

---

## Mode 4 — Hard short / dead-short

**Mechanism**: complete inter-turn short. Coil R drops dramatically.
Current limited only by upstream supply impedance + wire R. Sustained
high current causes thermal damage; valve typically retired immediately.

**Real example A — sat_1:27/sat_1:39 (abrupt mode-4, zero warning)**:

11 normal runs preceding (asym 0.73–0.80 A), then:

```
run:    ...  −5    −4    −3    −2    −1
asym:   ...  0.77  0.78  0.75  7.33  7.32  ← retirement
```

Within run −2, the trace was `[1.12, 7.33, 7.33, 7.32, 7.33, ...]` — fully
shorted from sample[1] onward. No mode-3 precursor in any of the 11 prior runs.

**Real example B — sat_1:20/sat_1:39 (mode-3 → mode-4 over 2 runs)**:

44 normal runs (asym 1.07–1.20 A, σ = 0.04), then:

```
run:    ...  43    44              45             46–48
asym:   ...  1.20  3.14 (★mode-3)  5.20 (★mode-4) 0.78 (bypassed/retired)
peak:   ...  1.22  7.29            7.27           0.79–1.14
```

Run 44 was mixed (1.13, 7.29, 7.28, 1.08, 1.08 A), run 45 sustained
high. Bin retired after run 45. **Even with the mode-3 warning at run
44, only one run of advance notice was provided.**

**Detector**:
```
if any sample[i] for i>0 in run > 5.0 A:  → MODE_4_HARD
if I_asym > 2.0 × bin_baseline:          → MODE_4_DEAD
```

**Operational implication**: mode-4 events demand **autonomous
SKIP_STATION authority** in KB1 — there is no time for human-in-the-loop
approval. The robot must shut off the failing valve mid-run on first
detection, log the event, push Discord notification.

---

## What this means for KB1 (real-time, 60-s poll)

Implementable detectors:

1. **MODE_4_HARD** — any current sample > 5.0 A → `SKIP_STATION` immediately
2. **MODE_4_DEAD** — `I_asym > 2.0 × bin_baseline` → `SKIP_STATION` after 1 confirmation
3. **MODE_3_SPIKE** — any sample[i>0] > 1.5 × asym → log event, alert KB2

Not implementable (insufficient signal):

- mode 1 prediction
- mode 2 from run-time current (use cold-R via KB2-daily)
- mode-4 prediction from prior runs

## What this means for KB2 (event-driven)

1. **R-drift trend** — Mann-Kendall on 20-day cold-R series; flag cohort z < −2
2. **Replacement-event log** — detect R-jump back to new-install band, reset
   the trend baseline for that valve, log to maintenance ledger
3. **Mode-3 trailing analysis** — when KB1 reports a spike event, KB2 walks
   back N runs to compute spike-count trend; rising trend → impending mode 4

## Open work

- Mine longer history (>3 months) once timestamps land in time_history
- Master-valve parallel correction (see
  [[master-valve-parallel-correction-2026-05-27]]) so hot-R is usable
- Audit 13 retired bins not classified here for additional labeled events
- Cross-validate mode-3 detection by replaying spike-rule against the
  sat_1:20 run-44 fixture
