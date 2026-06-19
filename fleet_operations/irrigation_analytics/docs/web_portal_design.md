# Valve-Maintenance Web Portal — Design

User-facing workflow for marking solenoid replacements. Extends the
existing fleet_design dashboard (layer 50) and application_gateway
(layer 40). LAN-only, no auth in v1 — same trust model as the rest of
the dashboard.

---

## Layer placement

```
  ┌─────────────────────────────────────────────┐
  │  Dashboard (browser, layer 50)              │
  │   + Valve Maintenance panel (new)           │
  └──────────────────┬──────────────────────────┘
                     │ HTTP
  ┌──────────────────┴──────────────────────────┐
  │  application_gateway (LuaSocket, layer 40)  │
  │   GET /api/valves                           │
  │   POST /api/replacements                    │
  │   GET /api/replacements                     │
  │   POST /api/replacements/{id}/confirm       │
  └──────────────────┬──────────────────────────┘
                     │ Zenoh RPC
  ┌──────────────────┴──────────────────────────┐
  │  persistence_service (layer 30)             │
  │   leaf: irrigation_analytics/replacements   │
  └──────────────────┬──────────────────────────┘
                     │ leaf subscribe
  ┌──────────────────┴──────────────────────────┐
  │  irrigation_analytics robot (KB2-daily)     │
  │   on replacement_confirmed: reset baseline  │
  └─────────────────────────────────────────────┘
```

---

## Backend: leaf shape

**Leaf path**: `fleet/irrigation_analytics/replacements`

**Type**: append-only stream (uses existing kb_stream from `data_structures`).

**Per-event schema**:
```json
{
  "id":         "evt_<unix_ms>",
  "valve":     "satellite_2:4",
  "date":       "2026-05-27",
  "source":     "user" | "auto",
  "confirmed":  true | false,
  "r_before":   35.0,
  "r_after":    43.0,
  "detector_ord": 0,
  "notes":      "<optional operator note>"
}
```

**Lifecycle**:
1. **Auto-detect entry** (KB2-daily nightly run): writes with
   `source=auto, confirmed=false`. Robot does NOT reset baseline yet.
2. **User confirms via portal**: gateway POSTs to update — sets
   `confirmed=true`. Robot subscribes to the update event, resets the
   valve's R-trend baseline and Mann-Kendall window.
3. **User manually-marks** (no prior auto-detect): writes with
   `source=user, confirmed=true`. Same baseline-reset path.
4. **User rejects auto-detect**: gateway POSTs to mark `confirmed=false`
   with `rejected=true`. Robot leaves baseline untouched.

Append-only — no rewriting; rejections add an annotation event referencing
the original.

---

## Backend: gateway endpoints

### `GET /api/valves`

Returns all active valves with current state. Used by the maintenance panel
to render the table.

```json
[
  {
    "valve":          "satellite_2:4",
    "r_corrected":    35.0,
    "cohort":         "sun",
    "cohort_z":       -2.09,
    "mk_tau":         -0.30,
    "mk_p":           0.043,
    "status":         "COHORT_OUTLIER",
    "auto_detected":  false,
    "last_replacement": "2026-05-27"
  },
  ...
]
```

Implementation: gateway calls existing persistence query RPC
(`fleet/persistence/query` op=`latest_stream` on `irrigation_analytics/
valve_status`), joins with last replacement event per valve.

### `GET /api/replacements`

Returns replacement history (full or filtered by valve/date).

### `POST /api/replacements`

Operator manually marks a replacement.

```json
Request:
{ "valve": "satellite_2:4", "date": "2026-05-27", "notes": "" }

Response:
{ "id": "evt_1716800000000", "status": "ok" }
```

Validates: valve exists in active list, date in [today-30, today].
Writes a new event with `source=user, confirmed=true`.

### `POST /api/replacements/{id}/confirm`

Confirm or reject an auto-detected replacement candidate.

```json
Request:
{ "confirmed": true }    or    { "confirmed": false, "reason": "false alarm" }
```

---

## Frontend: Valve Maintenance panel

A new tab/panel on the per-robot view of the dashboard. Three sections:

### 1. Auto-detected candidates (top, prominent)

A small card per pending auto-detection:

```
┌─────────────────────────────────────────────────────────┐
│ ⚠  Replacement candidate: satellite_2:4                 │
│    R jumped 35 Ω → 43 Ω on 2026-05-27                   │
│    Δ +8 Ω (above 6 Ω threshold), persisted next day     │
│                                                          │
│    [ Confirm replacement ]   [ Not a replacement ]      │
└─────────────────────────────────────────────────────────┘
```

Confirming POSTs to `/api/replacements/{id}/confirm`. The card disappears
on success and the entry appears in the History section below.

### 2. Active valve table

Sortable. Default sort: anomaly status first, then valve name.

| Valve         | R   | Cohort z | Trend | Status         | Last replaced | Action          |
|---------------|-----|----------|-------|----------------|---------------|-----------------|
| sat_2:4       | 35  | -2.09    | ↓     | COHORT_OUTLIER | —             | [Mark replaced] |
| sat_1:43      | 35  | —        | ↑     | HEAVY_TREND_UP | —             | [Mark replaced] |
| sat_2:13      | 42  | —        | —     | STABLE         | 2025-11       | [Mark replaced] |
| ...           |     |          |       |                |               |                 |

Anomaly statuses highlighted (red for outliers, yellow for trends).

[Mark replaced] opens a modal:

```
┌──────────────────────────────────────────────┐
│  Mark satellite_2:4 as replaced              │
│                                              │
│  Date:    [ 2026-05-27 ▼ ]                  │
│  Notes:   [_________________________]        │
│                                              │
│           [ Cancel ]      [ Confirm ]        │
└──────────────────────────────────────────────┘
```

### 3. Replacement history

Reverse chronological list. Each entry shows valve, date, source
(user/auto), R_before/R_after if auto, and notes. Filterable.

---

## Auto-detect → portal data flow

1. KB2-daily runs nightly, calls `detect_replacements.detect()` per
   valve, finds candidates passing the v4 rule (ΔR≥6, uplift≥4, pre-low-
   frac, post-confirm, multi-valve filter).
2. For each candidate, POSTs to its own gateway endpoint (or directly
   writes to the leaf via the persistence pub side) with
   `source=auto, confirmed=false`.
3. On next dashboard load, panel's "candidates" section fetches
   `GET /api/replacements?confirmed=false&source=auto` → renders cards.
4. User reviews, confirms or rejects.
5. Confirm → leaf event updated → robot's KB2-daily subscribes, on
   `confirmed=true` events it resets the valve's MK window.

---

## Out-of-scope for v1

- Authentication (LAN-only, port-obscurity per
  [[dashboard-port-obscurity-todo]]).
- Photo upload of replaced valve.
- Mobile-optimized layout.
- Bulk-confirm (rare workflow).
- Multi-controller deploys (LaCima is only deploy site today).

---

## Implementation order when we get to building

1. Leaf + persistence write path (skill in robot writes `replacements`)
2. KB2-daily emit auto-candidates after each run
3. Gateway endpoints + JSON shape
4. Dashboard panel (HTML + plain-JS, no framework — matches existing
   dashboard convention)
5. Robot subscription to confirm events + baseline-reset hook

Estimate: ~1 day work each for items 1–3, half-day for 4–5. Defer until
the irrigation_analytics chain_tree port lands.

---

## Cross-refs

- [[new-irrigation-robot-design-2026-05-26]] — KB1/KB2 robot design
- [[application-gateway-dashboard-2026-05-23]] — gateway+dashboard MVP
- [[persistence-layer-2026-05-23]] — leaf model
- [[discord-integration-architecture-2026-05-23]] — push-only contrasted
- [[master-valve-parallel-correction-2026-05-27]] — why cold-R drives
  detection
- `failure_signatures.md` — what we're detecting
- `explore/detect_replacements.py` — current detector logic
