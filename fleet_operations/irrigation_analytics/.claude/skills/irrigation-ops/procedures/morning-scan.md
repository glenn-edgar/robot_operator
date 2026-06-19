# Procedure: Morning ETO scan

The daily review: "what happened last night." A QUESTION procedure — it stops at
RULES and reports; it takes no action. Physics: `references/system-model.md`. Access:
`references/data-access.md`.

---

## TRIGGER
- "what happened last night", "scan eto data since 6pm", the morning review.
- Run it each morning to catch developing clogs/leaks/well events before they alarm.

---

## INPUTS (pull before reasoning)
1. **Runs since the cutoff** — the ETO cycle from ~18:00 PT prior day to now. Delineate
   via `PAST_ACTIONS` `IRRIGATION_STEP_COMPLETE` (db=4) — this is also the list of bins
   that ACTUALLY fired this cycle (see the in-cycle filter in RULES).
2. **Per-bin flow movement** — `flow_within` / `flow_within_baseline` and
   `baselines_eto` in `kb4.db` (steady_5_15 gallons vs baseline). Query via the
   docker-exec luajit/lsqlite3 pattern in `references/data-access.md`.
3. **Alerts since cutoff** — `kb_alerts` (KB2 resistance, KB3 leak, KB1 overcurrent).
4. **Well / leak log lines** — `docker logs irrigation-analytics | grep -iE
   "WELL-DRAWDOWN|INTERNAL-LEAK|MANUAL-LOG"`.
5. **Solenoid trend** (weekly, not nightly) — `coil_onset` / coil-decomposition.

---

## RULES
- **In-cycle filter (critical — avoids stale-baseline false positives):** only analyze
  bins that **fired in THIS cycle**. Cross-reference `PAST_ACTIONS`
  `IRRIGATION_STEP_COMPLETE` since cycle start; **skip any bin whose newest
  `TIME_HISTORY` entry pre-dates the cycle** (an edited-out schedule pair leaves a stale
  baseline that looks like a drop).
- **Flow movement:** a blocked head ≈ **−2.42 gal** on steady_5_15 (14.5 gph). Report
  per-bin movement vs baseline. The gated median absorbs MODERATE change automatically —
  flag the ones too large for it, or trending across multiple runs.
- **Clog vs single-head:** single-head clogs are below the meter floor → field-eyeball
  only. Reliable signals are **clean-bin clog/recovery** and **multi-head** step-downs
  (confirm vs neighbour cohort median, not just the bin's own baseline).
- **Leaks:** HUNTER > baseline+~5 = external; PLC ≫ HUNTER = internal (over-draws well).
  Route a real one to `procedures/leak-triage.md`.
- **KB2 resistance:** trust only alerts that survived the **2-consecutive-cycle**
  persistence gate; a single-cycle flip is noise (±~10 Ω).
- **Well:** any `WELL-DRAWDOWN`/`INTERNAL-LEAK` log line → note timing + severity; route
  to `procedures/well-drawdown.md` if live.

---

## ACTION
None — this is a report. If the scan surfaces a *live* event (active over-draw, armed
alarm), hand off to the matching action procedure (well-drawdown / leak-triage).

---

## VERIFY / record
Read-only, nothing to verify. If the scan reveals a NEW developing fault (e.g. a bin
trending toward a multi-head clog), add it to `memory/state.md` watch list so the next
cold-start operator follows it. Currently watched: see `memory/state.md`.
