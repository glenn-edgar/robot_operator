# irrigation_analytics — the full virtual operator

This is the robot the project started from, and the only one that exercises **all
six themes**. The two robots before it each demonstrate a piece — consolidation,
then the adapter. `irrigation_analytics` is where the pieces become an actual
virtual operator: it extracts telemetry from the LaCima irrigation controller,
reasons about it with physics-grounded detectors, *takes corrective action*
through the operator's own command path under armed gates, and answers a grower's
questions about what happened and what to do.

(Mechanical detail lives in
[Fleet framework → Robot classes](../fleet/robots.md) and the robot's own
research notes under `irrigation_analytics/docs/`.)

## 1. Screens it replaces

The work this robot removes is the heaviest of the fleet:

- **The controller's run logs and screens** — the per-valve current and flow
  telemetry from each irrigation cycle.
- **The nightly cycle review** — a human would otherwise read the overnight
  run, valve by valve, looking for the ones that drew no current, too little,
  too much, or spiked.
- **The slow-trend bookkeeping** no screen shows at all — per-valve resistance
  drifting over weeks, a well drawing down a little further each night.

It replaces not just *screens* but a *vigil*: the attention a person would have
to spend, every morning and across months, to catch failures early.

## 2. Same controls as the user

`irrigation_analytics` operates the controller through the exact path a human
operator uses. It `ssh`es the controller host (`pi@irrigation`, the LaCima
controller at `192.168.1.146`), reads its telemetry, and — when armed — issues
`SKIP_STATION` through the same `ws_command` channel an operator would use to skip
a valve, recording actions on the controller's own past-actions bus.
`controller_client.lua` even runs `python3` *on the controller* over that SSH
session, rather than reaching around it.

This is the strongest form of "same controls as the user": the robot both
**reads and writes** through the operator's interface, with the operator's
access, doing only what the operator could already do by hand. Its authority is
bounded to the human's, which is precisely what makes armed actuation defensible.

## 3. AI as universal adapter

The controller exposes no analytics API — just a PLC with a 12/13-bit ADC, an
ACS712 5 A Hall current sensor, a flow sensor, and 1-minute aggregate sampling.
Everything this robot knows, it extracts from that raw, undocumented stream and
reasons about itself. There was never going to be a vendor integration for "is
this valve's coil starting to fail"; the agent *is* the integration.

What makes the extraction trustworthy rather than guesswork is that the detectors
are built on a **synthesis of the solenoid-failure literature** — a two-phase
thermal-degradation model reduced to only the signatures this hardware can
actually see. The robot's `docs/` folder records both what is detectable
(per-run current excursions, run-over-run resistance drift, self-extinguishing
spikes, flow×current cross-validation) and what is *not* with this sensor stack
(Phase-1 insulation creep, single-turn shorts below the ACS712 noise floor,
spectral features at a 1-minute rate) — and drops the undetectable ideas rather
than faking them.

## 4. Workload offloaded

The offloaded labor is both routine and expert:

- **Overnight vigilance** — the canonical task humans are bad at. The robot reads
  every valve of every cycle, every night, without fatigue.
- **Per-valve trend tracking** — maintaining a baseline of each valve's expected
  current and watching for slow drift, stratified by sun-exposure cohort.
- **Leak and well monitoring** — distinguishing internal from external leaks,
  watching well drawdown.
- **First-line triage** — turning "something looks off on valve 13" into a
  specific, classified finding on the alerts dashboard.

The detector stack divides this into knowledge bases by timescale and job:

| KB | Cadence | Job |
|---|---|---|
| **KB1** | real-time (60 s) | current-anomaly detector for the actionable failure modes; can fire `SKIP_STATION` |
| **KB2** | offline, event-driven | Mann-Kendall resistance-drift trend, cohort-stratified; maintains the per-valve expected-current model KB1 reads |
| **KB3** | per run | leak detection and well-drawdown monitoring |
| **KB4** | per run | clog / leak current-curve detectors over the ETO valve set |

## 5. Safety and the autonomy gradient

This robot is where safety stops being "fail loud" and becomes *acting in the
world*, so it carries the full machinery.

**The autonomy gradient is explicit and arm-gated.** Each capability is promoted
to action only by an explicit flag in `fleet.env` — `SKIP_LIVE`, `KB1_ARM_KILL`,
`KB3_ARM_KILL`, `KB3_WELL_ARM`, `KB4_CURVE_ARM`, `FIELD_LOG_ARM`. Unarmed, a
detector observes and alerts; armed, the *same* detector is permitted to actuate.
The promotion from "recommend" to "act" is a deliberate configuration decision,
logged, never a default.

**Physics is the hallucination check.** The clearest lesson in the whole project
is a detector this robot *rejected*: a coil-temperature ("heat-margin") model
that the literature endorses in principle. Walked through on real run data it
computed a coil temperature of **−118 °C** — physically impossible, because
copper resistance must rise with heat. Three measurement-stack problems (the
master valve always in parallel, unknown run-time supply voltage, an ACS712
calibration-regime mismatch) made the inference unrecoverable, so the component
was *not built*. Conservation laws gave a ground truth the inference had to agree
with, and when it didn't, the answer was to drop it — not to ship a confident
wrong number near an actuator. The de-facto remaining-life proxy is instead the
Mann-Kendall trend on cold resistance, which is grounded in directly measured
data.

**The human stays in the loop.** The
[`irrigation-ops` operator skill](../fleet/operations.md) is the runbook the
robot and the grower share: how to access the system, how to decide internal vs.
external leak, how to assess well health and solenoid health, how to triage a
blocked sprinkler, and how to take recovery actions (well-drain recharge, station
skip, baseline reset) *safely*. The robot acts within those procedures; the
operator can review every action against the same document.

**The deterministic core does the always-on work.** The production detector
(`robot/`) runs as bare LuaJIT directly on the Pi — outside the container — so
the safety-critical loop doesn't depend on the rest of the stack being up. The
agent layer adapts and analyzes; the grounded core watches and, when armed,
acts.

## 6. Interactive analyst

This is where the resident-analyst role earns its keep. Because every run,
baseline, and action is persisted and the system model is written down, a grower
can interrogate live situations:

- *"Why did valve 13 trip last night?"*
- *"Is this an internal leak or an external one?"*
- *"Is the well drawing down faster than usual this week?"*
- *"Which valves are trending toward failure, and how soon?"*

The analyst answers over the actual persisted history, the declared system model,
and the runbook — and, crucially, *cites* them. It is grounded in the same data
the deterministic detectors use, which is what separates a trustworthy diagnosis
from a confident guess. A dashboard could show last night's currents; only an
analyst can be asked *why*, in the moment, and reason it out.

---

`irrigation_analytics` is the thesis fully realized: a virtual operator that
reads and controls through the grower's own interface, grounds its judgments in
physics and stored truth, escalates from observation to armed action only through
deliberate gates, and stands ready to explain itself. The
[Opening](index.md#the-themes-and-the-journey-through-the-robots) is the claim;
this robot is the proof.
