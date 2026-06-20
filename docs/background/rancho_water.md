# rancho_water — the adapter

`rancho_water` is deliberately the smallest robot in the fleet: one screen, one
daily pull, no actuation. Its job in this narrative is to make the
**universal-adapter** theme concrete and unmissable — to show, in the simplest
possible case, what "we construct an agent that adapts to the interface instead
of standardizing it" actually means, and what it costs.

(For the mechanical spec see
[Fleet framework → Robot classes](../fleet/robots.md#rancho_water).)

## 1. Screens it replaces

Exactly one: the **Rancho California Water District customer portal**. Every day
a person would otherwise log in, read yesterday's hourly usage and daily total,
and check whether the district flagged anything. That single login is the whole
of what this robot removes — which is the point. It isolates the adapter pattern
from everything else.

## 2. Same controls as the user

There is no API to call. The portal is a customer-facing web application — a thin
ASP.NET shell over a JSON REST endpoint (`/api/usage/get/`) — and `rancho_water`
drives it the way a logged-in customer's browser does, authenticating with the
operator's own account number and password (`RANCHO_WATER_ACCOUNT`,
`RANCHO_WATER_PASSWORD`, mounted read-only). It reads only what the account
holder can already see, including the district's **own anomaly flags**
(`LeakDetected`, `ExceededFlowThreshold`, …) — it surfaces the portal's
judgments rather than re-deriving them.

This is "same controls as the user" in its purest form: the integration surface
*is* the customer portal, and the robot's authority is exactly the customer's.

## 3. AI as universal adapter

This robot is the **brittleness exemplar** for the whole fleet. A customer portal
is not a contract — it has no versioning, no schema guarantee, no obligation to
stay the same. Adapting to it means living with its sharp edges, and
`rancho_water` carries the scar in its code as a permanent reminder:

> **The `curl` 411 gotcha** — never pass `--request=POST` alongside
> `data-urlencode`. Doing so forces a POST on the portal's redirect, which strips
> the request body and returns **HTTP 411 Length Required**. The working call
> lets POST happen implicitly via the data.

That single line is the universal-adapter bargain in miniature: you gain the
ability to integrate a closed system *no API would ever have exposed*, and you
pay for it in fragility that only careful, real-world adaptation handles. A
standardized connector would be more robust — and would not exist, because the
district was never going to build one.

## 4. Workload offloaded

Modest and exact: the daily portal login and read. The single `daily_pull` KB
fires once per day at the configured Pacific hour, fetches yesterday's numbers,
and publishes both a human digest body and a compact persistence envelope
(the hourly array trimmed to `{h, gph, gpm}`) into the same notify + store
channels the rest of the fleet uses. The grower stops visiting the portal; the
usage and any leak flags arrive in the same daily digest as soil and irrigation.

## 5. Safety and the autonomy gradient

`rancho_water` is **observe-only (L0)** — the floor of the gradient. It takes no
corrective action; it cannot. Its safety contribution is *surfacing* the
district's leak and flow-threshold flags promptly into the unified digest, so a
leak the grower might not have noticed for a billing cycle shows up the next
morning.

As with farm_soil, the real risk is silent failure. Because the portal is
brittle (see theme 3), a failed scrape must read as "I couldn't check today,"
**not** as a quiet zero — a virtual operator that goes silent is indistinguishable
from one reporting all-clear, and that is the dangerous confusion to prevent.

## 6. Interactive analyst

Usage history is persisted as a stream under `ltree` paths, so the analyst can
field questions on demand:

- *"Did usage spike yesterday, and at what hour?"*
- *"Have there been any leak flags this month?"*
- *"How does this week's daily total compare to the same week last month?"*

Small surface, same principle: the data is grounded and queryable, so the user
can ask what they didn't think to chart.

---

`rancho_water` isolates the adapter — extraction from a closed interface, and the
brittleness that comes with it. Next,
[**irrigation_analytics**](irrigation_analytics.md) brings every theme together:
extraction *and* armed control, physics-grounded safety, and an analyst the
grower can interrogate about live failures.
