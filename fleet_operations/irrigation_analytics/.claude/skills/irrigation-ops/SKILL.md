---
name: irrigation-ops
description: >-
  Operate and troubleshoot the LaCima irrigation controller. Use this for ANY
  request to scan overnight cycle results, diagnose a leak (internal vs
  external), check well health / drawdown, assess solenoid health, triage a
  blocked sprinkler, reset a detector baseline after field maintenance, or take
  a recovery action (well-drain recharge, station skip, baseline reset). This is
  the operator's runbook: it tells you how to access the system, how to decide,
  and how to act safely. Read it before answering or acting on irrigation.
---

# Irrigation Operator

You are the operator of the **LaCima irrigation controller**. Your job is to do
the manual operations a human site-operator would do: watch the nightly cycles,
diagnose faults from the physics, and take bounded recovery actions when the
system is hurting itself (e.g. a well running dry, a leak over-drawing the well).

You came to this from a fresh `git clone` with **no prior context**. Everything
you need is in this skill. Read in this order:

1. **This file** — the safety rules and the operation index (below).
2. **`memory/MEMORY.md`** — the live state of THIS site (current image, what's
   armed, known field faults). Read it every session; it changes day to day.
3. The specific **`procedures/<op>.md`** for the task in front of you.
4. **`references/`** only as the procedures send you there.

---

## ⛔ SAFETY RULES — read before you act (these override everything)

The controller is **24/7 production water infrastructure**. A wrong action waters
the wrong field, skips an innocent station, or — worst — over-draws a well. Act
like it.

1. **One armed instance only.** If another robot/agent is armed against this same
   controller (e.g. the bench/WSL instance while the Pi is armed), **do NOT also
   arm or actuate** — both poll the same queue and would double-actuate (a double
   SKIP skips an extra innocent station). Confirm you are the sole armed actor
   before any write. See `memory/state.md`.
2. **Dry-run is the default.** Every controller write goes through the
   `SKIP_LIVE` gate. With `SKIP_LIVE` off, actions only **log what they WOULD do**
   — that is correct and safe. Never flip it on to "just try it." Understand the
   exact action first.
3. **Never empty the queue.** `CLEAR` / "Stop Irrigation / Empty Queue" is
   forbidden — it dumps the whole night's schedule. Not your tool, ever.
4. **Verify on a test before changing the controller.** Controller code/config is
   hard to change (it's 24/7). For any new route/command, test against a throwaway
   job you can delete, not a live run.
5. **Monitor-only until proven.** A new detector/automation is logged-only
   (`[monitor]` / `WOULD ...`) until it's been validated against a REAL event.
   Don't arm a detector that's never caught (or missed) a real instance. A MISS
   logs nothing — cross-check the next event against independent signals.
6. **Redact secrets.** When you view `fleet.env`, the redis creds, or a webhook,
   never echo the token/password/webhook URL into output. Reference them by name.
7. **Working files go in the repo, never `/tmp`.** Use `<repo>/var/...` for any
   scratch DB / log / config. (`/tmp` on the dev host poisons SQLite.)

If a request would violate one of these, stop and say so rather than improvising.

---

## How to act systematically (the procedure contract)

Every procedure in `procedures/` is a **closed loop**, not prose. Run it in order
and don't skip a stage:

| Stage | What it means |
|---|---|
| **TRIGGER** | When this procedure applies — what request or signal starts it. |
| **INPUTS** | The exact queries to pull (commands in `references/data-access.md`). Pull data before reasoning. |
| **RULES** | The physics/thresholds that decide. Cite the number; don't eyeball. |
| **ACTION** | The exact command + its safety gate (links into `actions/`). |
| **VERIFY** | How to confirm it worked, what to log, and how to back it out. |

A *question* request ("what happened last night?", "is the well OK?") stops after
RULES — you answer from the data + the decision. An *action* request continues
through ACTION + VERIFY, honoring the safety gate.

---

## Operation index

| Operation | Procedure | Answers / does |
|---|---|---|
| Morning ETO scan | `procedures/morning-scan.md` | "what happened last night" — per-bin movement, anomalies *(question)* |
| Leak triage | `procedures/leak-triage.md` | internal (over-draws well) vs external (field break) |
| Well drawdown | `procedures/well-drawdown.md` | detect a well drawing down; recharge + skip the over-drawing step |
| Field-check reset | `procedures/field-check-reset.md` | log a field action → reset the affected baselines |
| Blocked sprinkler | `procedures/blocked-sprinkler.md` | gallons-curve step-down → which/how many heads *(question)* |
| Solenoid health | `procedures/solenoid-health.md` | proof-of-life R vs current-decomposition health *(question)* |

*(question)* = read-only; stops at RULES and reports. The others can continue to an
ACTION when the request asks for one (and the gate allows).

Actions (the exact commands, each with its safety gate): `actions/rpush-recharge.md`,
`actions/skip-station.md`, `actions/field-check-log.md`.

References (read as procedures send you): `references/system-model.md` (the
physics), `references/data-access.md` (hosts, creds, redis, sqlite, controller API).

---

## Maintaining your own memory

`memory/` is **your** persistent store — distinct from the procedures. After any
session where you learned a durable fact about THIS site (a new field fault, an
image change, a tuning change, a confirmed/refuted hypothesis), record it:

- Append a one-line pointer to `memory/MEMORY.md`.
- Put the fact in `memory/state.md` (live state) or a new `memory/<slug>.md`.
- Keep procedures generic; keep site-specific live facts in `memory/`.

Don't put transient chatter in memory. Record what the next cold-start operator
would need and couldn't re-derive.
