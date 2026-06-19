# System model — the physics you reason from

Decisions come from physics, **not rule-lists**. Every anomaly must have a physical
cause. This file is the model; the procedures apply it.

## Hydraulic topology

```
  WELL (source)                          CITY WATER
  main_flow_meter = PLC_FLOW_METER         sat 1:39  (no well draw)
        │                                      │
        ▼                                      │ used as the "recharge wait"
  MASTER VALVE  sat 1:43 (implicit, ~0.46 A always-on)
        │
        ▼
  banks / satellites  ── per-step io_setup {remote, bits}
        │
        ▼
  HUNTER meter  (FILTERED_HUNTER_VALVE = downstream, FILTERED → it LAGS)
        │
        ▼
  field heads (14.5 gph each)
```

Key consequences:
- **`main_flow_meter` (PLC) = the well source.** Read THIS for well health — it
  reacts immediately. The filtered HUNTER lags too much to abort on.
- **`sat 1:43` is the master**, always energized; it's why current is a summed bus.
- **`sat 1:39` is city water** (no well draw). Running it for 15 min lets the well
  rest — that's the "recharge wait" the drawdown recovery inserts.
- Each `TIME_HISTORY` bin (a valve/pair) is **its own analysis unit**; you cannot
  separate a valve from its pair.

## Two leak types (different alerts, different actions)

| | INTERNAL leak | EXTERNAL leak |
|---|---|---|
| Signature | **PLC ≫ HUNTER** (loss *between* the meters) | **HUNTER > baseline** (loss *past* the meters) |
| Physical cause | supply-line break | broken/over-flowing field head |
| Effect on well | **over-draws the well** → it's the EARLY drawdown warning | no extra well draw |
| Action | recharge + skip (well protection) | log + watch; field repair |

## Well drawdown (running dry)

A well drawing down shows as the **source flow (PLC) sagging below the level it held
early in the run** — catch it *before* PLC hits zero ("too late then"). Two
self-referencing references, so it needs NO clean baselines:
- **plateau** = the source's own early-run level (this run, ~min 5–12).
- **cycle capacity** = prior stations' plateaus this cycle (rolling median).

A dying well sawtooths, so the rule is **windowed (3-of-4 below the fraction)**, not
strict-consecutive. Tag **SEVERE** when HUNTER also drops (real loss, not noise).
Root causes both fixed by the SAME action (recharge the well via 1:39 + skip the
over-drawing step): (a) an internal leak over-drawing, or (b) a scheduling gap (a
high-draw bank with no 1:39 recharge before it → well starts the step depleted).

## Flow meter LOWER FLOOR (~1 GPM)

The meter can't resolve flows below ~1 GPM — it reads ~0. A sub-floor zone (drip,
small zone, e.g. `sat 3:11`) reading ~0 is **NO DATA, not a fault**, and any flow
baseline for it is bogus. Mark such bins **`phantom=1`** in `kb4.db baselines`; the
detectors skip phantom bins. A coil that's *alive* (proof-of-life) + *real* zero
flow (above floor) WOULD be a stuck valve — but sub-floor + alive is just fine.

## Per-head flow arithmetic

14.5 gph = **0.242 GPM = 2.42 gal** over a 10-min (min 5–15) window. So a single
blocked head subtracts ~2.42 gal from the steady_5_15 gallons curve — which is
**below most bins' flow floor**, so single-head clogs are field-eyeball only. The
robot reliably catches **clean-bin clog/recovery** and **multi-head** changes, not
single heads. Integrating a wider window (5–25 min) improves resolution but the
floor still bounds single-head detectability.

## Solenoid: PROOF-OF-LIFE vs HEALTH (don't conflate)

- **Proof-of-life = `IRRIGATION_VALVE_TEST` resistance.** COARSE only: alive / open /
  short. The `R = V/(I − offset)` division is **numerically unstable** (offset ~0.11 A
  is a large fraction of the net current; δR ≈ V·δI/I²), and per-cycle readings are
  noisy (±~10 Ω). Use it for alive/open/short, interpreted **cohort-relative** (same
  branch cancels common-mode), **never** as a precise R. Calibration: `R = V_PSU/(I_raw
  − offset)`, `V_PSU≈15.4`, offset from the 2 null channels (`3:1`+`4:6`, unconnected
  → their raw reading is the per-cycle zero).
- **HEALTH = `TIME_HISTORY` during-run current.** Offset-immune (the offset is constant
  *within* a run, so it cancels in differences). Current is a **summed bus**:
  `hold = master(1:43) + Σ coils`. Solve a whole CYCLE as a least-squares linear system
  (one eq per key) to get each coil's TRUE operating current — master and offset removed.
  Unconnected/bad-wiring valves solve to ≈0 A (null references that calibrate the zero).
  A weak coil = a CONNECTED coil low vs the cohort median or trending toward the null
  floor over time. (Onset current spikes were a red herring — benign cold-coil thermal.)

## Baselines: gated running median

Flow baselines are the median of a bin's `cls='OK'` runs. This **absorbs moderate
changes** automatically — so the human→reset loop only matters for changes too LARGE
for the median to absorb, or that need a phantom/coil/resistance reset. **Catch-22:**
post-change runs get classified against the OLD baseline, so a reset must recompute
medians **directly from post-change runs (ignoring `cls`)** and defer until ≥2 such runs.

## KB roster (what acts vs what only alerts)

| KB | Scope | Behavior |
|---|---|---|
| KB1 overcurrent | all bins | **ARMED**: IRR>1.8 A / EQ>1.2 A → CLOSE_MASTER + SKIP. |
| KB3 sustained | ETO bins | **ARMED** leak: HUNTER>14×3min OR HUNTER>base+4. PLUS divergence + well-drawdown (monitor/armed per env). |
| KB2 resistance | per valve_test | proof-of-life R → alerts → digest. 2-consecutive-cycle persistence gate. |
| KB4 / kb4_clog | ETO + non-ETO | blocked (PLC gallons), clog (last value vs baseline), within-run flow, coil_onset. |
| field_log watcher | in kb4_clog | maps a logged field action → baseline reset. |

Detail and the live arming state are in `memory/state.md`.
