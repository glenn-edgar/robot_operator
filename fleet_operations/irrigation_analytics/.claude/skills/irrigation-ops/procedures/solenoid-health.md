# Procedure: Solenoid health — proof-of-life vs current

Assess a valve's solenoid. Keep the two signals SEPARATE: `valve_test` resistance is
proof-of-life ONLY; true health is in the during-run current. A QUESTION procedure.
Physics: `references/system-model.md` § "Solenoid: PROOF-OF-LIFE vs HEALTH".

---

## TRIGGER
- "check solenoid health", "scan current for beginning spikes / heating solenoids", a
  KB2 `COIL_SHORT`/`R_SHORT`/drift alert, a `valve_test` anomaly.

---

## INPUTS (pull before reasoning)
1. **Proof-of-life** — `IRRIGATION_VALVE_TEST` (db=4): the per-cycle resistance probe,
   for the bin AND its same-branch cohort (so common-mode cancels).
2. **Health (the real test)** — during-run `IRRIGATION_CURRENT` from `TIME_HISTORY` for
   a whole CYCLE (contiguous runs of one schedule). Use `.data` (raw arrays).
3. **Decomposition** — `coil_onset` / coil-decomposition results in `kb4.db` (the LSQ
   per-coil solve), if available, else recompute (hold = master + Σ coils).
4. **Calibration constants** — `V_PSU≈15.4`, null channels `3:1`+`4:6` (see
   `memory/state.md`).

---

## RULES
**Proof-of-life (coarse only — never a precise R):**
- Classify alive / open / short, **cohort-relative** (same branch cancels wiring/master/
  offset). The `R = V/(I−offset)` division is unstable; per-cycle reads are noisy
  (±~10 Ω); trust only what survives the **2-consecutive-cycle** gate.
- Every anomaly needs a PHYSICAL cause — no exclusion lists: shorted turns → **lower R**
  (real fault, e.g. 4:9 sits ~6 Ω below peers); relay/contact oxidation → **higher R**;
  cold coil → slightly lower (~0.4%/°C, small); transient/non-steady current → bad read
  (e.g. 1:44's rarely-energized coil reads off — explain, don't rule-exclude).

**Health (the decisive test):**
- Decompose the cycle current as a least-squares linear system → each coil's TRUE
  operating current, with master (1:43 ≈ 0.46 A) and offset removed. Unconnected/bad-
  wiring valves solve to ≈0 A = null references that calibrate the zero.
- A **weak coil** = a CONNECTED coil LOW vs cohort median, or trending toward the null
  floor over time. (4:9 reads a normal ~0.337 A in decomposition → its `valve_test`
  "COIL_SHORT" was the unstable-division artifact, NOT a real short.)
- **Onset current spike is a red herring** — benign cold-coil thermal (healthy 2:14 ==
  clogged 2:15). Don't flag it.

---

## ACTION
None from the robot (monitor-only). Report the suspect + its physical cause + which
signal it came from. A solenoid confirmed failing by the *current* test (not just
valve_test) → field replace, then log via `procedures/field-check-reset.md`
(`replace_solenoid`).

---

## VERIFY / record
Read-only. Record a current-confirmed weak/failing coil in `memory/state.md` (with the
decomposed current and the trend), so the multi-week solenoid trend persists. Don't
record a valve_test-only anomaly as a fault — note it as "proof-of-life flag, current
clears it" if decomposition is normal.
