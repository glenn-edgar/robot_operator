# Procedure: Blocked sprinkler — read the gallons curve

Decide whether a bin has blocked head(s), how many, and whether a cleaning recovered
it. A QUESTION procedure — it reports; remediation is field work. Physics:
`references/system-model.md` § "Per-head flow arithmetic".

---

## TRIGGER
- "check X for blocked heads", a gallons-curve step-down in the morning scan, "did 4:4
  recover after cleaning?", "is a new clog developing?".

---

## INPUTS (pull before reasoning)
1. **steady_5_15 gallons** for the bin across runs since a reference date — `flow_within`
   in `kb4.db` (the well-stable early-window gallons). Pick the reference date to bracket
   a suspected event (e.g. "since Monday 18:00", "before/after Thursday's fix").
2. **Neighbour cohort** — the same metric for sibling bins, to normalize out cycle-wide
   supply-pressure shifts (compare vs cohort median, not just the bin's own baseline).
3. **flatness** — within-run SD across steady bins (5–15 / 15–25 / 25–35) from
   `flow_within`; cancels run-to-run offset → per-bin regime (clean ~0.8 gal; supply-
   limited >2 gal).
4. **Baseline** — `baselines_eto` for the bin.

---

## RULES
- **One blocked head ≈ −2.42 gal** on steady_5_15 (14.5 gph × 10 min). So N heads ≈
  −2.42·N gal.
- **Single-head is below the meter floor** → NOT reliably detectable from flow (field-
  eyeball only). Report it as "below detection, field-check to confirm."
- **Detectable signals:** a **clean-bin** clog or recovery, and **multi-head** (~2–3+)
  sustained step-downs confirmed against the **neighbour cohort** (a cycle-wide pressure
  dip moves all bins; a real clog moves one).
- **Timing matters:** check whether the step-down began **after** a known event (a fix /
  a date) → distinguishes a NEW developing clog from an old known one. A post-fix
  *decline* vs neighbours = a possible new clog (e.g. the 4:4 watch: 109→101 post-Thu).
- Widening the integration window (5–25 min) improves resolution but the floor still
  bounds single-head detectability.

---

## ACTION
None from the robot. Report: which bin, estimated #heads, when it started, recovered or
not. If field cleaning/capping is warranted, that's human field work — afterward log it
via `procedures/field-check-reset.md` (`clean_heads` / `cap_heads`) so the baseline
re-learns.

---

## VERIFY / record
Read-only. Add a new multi-head candidate to `memory/state.md` watch list with its
since-date and neighbour-confirmed head estimate, so the trend is followed across the
weeks it takes to confirm.
