# KB2 Trend State Schema

KB2 is the event-driven post-run analyzer. After each completed
irrigation run, the controller emits a `past_actions/run_complete`
event. KB2 subscribes, updates per-bin trend state, and triggers
Discord/notifications when slow-drift or mode-3-precursor patterns
emerge.

This doc defines the persistent state + trigger rules. Implementation
ports into chain_tree later.

---

## Per-bin state

```jsonc
{
  "bin_key": "satellite_2:1/satellite_1:39",
  "baseline": {                       // frozen from bin_baselines.json
    "mu_i_asym":    1.30,
    "sd_i_asym":    0.053,
    "mu_flow":      2.0,
    "sd_flow":      0.5
  },
  "rolling": {                        // updated per run
    "asym_history":  [1.31, 1.29, 1.32, 1.28, 1.30],  // last 5 run asymptotes
    "spike_history": [0, 0, 0, 1, 0],                  // sample[i>0] > 1.5*mu count
    "ord":           42                                // run sequence counter
  },
  "drift_state": {                    // derived metrics
    "residual_mean":      0.001,      // mean of (asym - mu)/sd over last 5 runs
    "residual_trend_tau": 0.0,        // Mann-Kendall tau on residual series
    "residual_trend_p":   1.0,
    "spike_count_5run":   1
  },
  "last_alert": {
    "kind":    null,                  // or "SLOW_DRIFT" / "MODE_3_CASCADE"
    "ord":     null,                  // run ord when alert fired
    "cleared": true
  }
}
```

---

## Update step (per run_complete event)

```
on run_complete(bin_key, asym, samples, flow_total):
  state = load(bin_key)
  z = (asym - state.baseline.mu_i_asym) / state.baseline.sd_i_asym
  spikes = count(s > 1.5 * state.baseline.mu_i_asym for s in samples[1:])

  state.rolling.asym_history  = (state.rolling.asym_history + [asym])[-5:]
  state.rolling.spike_history = (state.rolling.spike_history + [spikes])[-5:]
  state.rolling.ord += 1

  state.drift_state.residual_mean = mean(
    [(a - mu) / sd for a in state.rolling.asym_history])
  state.drift_state.residual_trend_tau, p = mann_kendall(
    [(a - mu) / sd for a in state.rolling.asym_history])
  state.drift_state.residual_trend_p = p
  state.drift_state.spike_count_5run = sum(state.rolling.spike_history)

  evaluate_triggers(state)
  save(state)
```

---

## Triggers

### SLOW_DRIFT

Slow upward or downward drift of I_asym vs baseline.

```
fire if:
  abs(residual_mean) > 2.0          // sustained ≥2σ off baseline
  AND residual_trend_p < 0.20       // trend statistically real
  AND len(asym_history) == 5        // enough samples
```

Direction:
- `residual_mean > 0` → I rising → R falling → **PRE_SHORT** trend
- `residual_mean < 0` → I falling → R rising → **AGING_OPEN** trend

Discord: `"⚠ Bin X drifting: residual={mean:.1f}σ over last 5 runs (p={p:.2f}). Direction: {dir}."`

### MODE_3_CASCADE

Spike count rising over recent runs — the literature's mode-3 thermal
cascade precursor.

```
fire if:
  spike_count_5run >= 3              // ≥3 of last 5 runs had spikes
  AND spike_history[-1] >= 1         // last run had a spike
```

Discord: `"⚠ Bin X mode-3 candidate: {spikes_total} spikes in last 5 runs. Next field trip should inspect."`

### Hysteresis / re-alert

- Once an alert fires, set `last_alert.kind` and `last_alert.cleared = false`.
- Do not re-alert same kind until `last_alert.cleared = true`.
- Clear when `abs(residual_mean) < 1.0` for 3 consecutive runs (SLOW_DRIFT)
  or `spike_count_5run < 2` for 3 consecutive runs (MODE_3_CASCADE).

---

## Storage

- Leaf: `fleet/irrigation_analytics/bin_trend_state`
- Storage: kb_stream (one row per state update, latest snapshot via
  kb_status companion path)

## Cross-validation against labeled events

KB2 trend triggers must NOT fire spuriously on healthy bins. Validation
sweep replays the entire historical TIME_HISTORY through the update
logic, counts false-positive trigger fires per bin.

For labeled-failure bins (sat_1:20, sat_1:27 retired):
- Mode-4 was **runway-less** in this data — KB2 SLOW_DRIFT should NOT
  have caught it (and KB1 didn't either, since asymptotes were rock-
  steady at 1.18 A until the cataclysm).
- The acceptable outcome: KB2 catches nothing pre-failure; KB1 catches
  the cataclysm itself. This is the honest detector-coverage profile.

## Cross-refs

- `failure_signatures.md` — what each mode looks like
- `bin_baselines.json` — per-bin μ/σ used here
- `kb1_thresholds.json` — real-time companion
- [[new-irrigation-robot-design-2026-05-26]] — robot design
