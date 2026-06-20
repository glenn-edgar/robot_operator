# Background — a virtual operator for the farm

## The problem: a farm is run through a dozen screens

Running a modern farm is, increasingly, an *interface* problem. The grower
operates a growing stack of separate, web-based systems — the irrigation
controller, a LoRaWAN sensor network's console, one or more
evapotranspiration (ETo) data sources, a water-district usage portal, and on
the equipment itself a tractor cab full of screens, each its own vendor, login,
and mental model. None of them talk to each other.

The work that falls on the human is not really *farming* — it is **integration
and vigilance**:

- Open each system, every day, and read it.
- Cross-reference data that lives in different places (is this soil dry because
  it's hot, or because a valve failed?).
- Notice the slow, boring signals a screen won't shout about — a valve current
  drifting 2% a week, a well drawing down a little further each night.
- And when something is wrong, **decide and take corrective action** — through,
  again, one of those same systems.

That last part is where it stops being inconvenient and starts being dangerous.
Missed corrective action — a valve cascading to burnout, a leak running all
night, a well pumped too hard — is the real cost of fragmentation. The human is
the integration layer, and humans get tired, distracted, and overloaded.

## The thesis: a virtual operator using the same controls as the user

This project's motivation is to put a **virtual operator** alongside the human —
one that uses **the same controls the user does** to mitigate the workload and
increase safety.

"The same controls" is the load-bearing idea, not a detail. The virtual
operator works through the operator's *own* interfaces — it reads the same
portals, polls the same sensor consoles, `ssh`es the same controller, and issues
the same commands a person would. It does **not** require a special vendor API,
a backdoor, or a standardized integration. The farm's existing stack *is* the
integration surface.

That choice buys three things:

- **Universality** — it works against closed, heterogeneous, vendor-locked
  systems that will never expose an API.
- **Bounded authority** — it can do nothing a human operator couldn't already do
  through the same interface, which makes "is this safe?" a tractable question.
- **Legibility** — because it acts like an operator, its actions are explainable
  in operator terms and reviewable against the same runbook a person follows.

It costs two: human interfaces are **brittle** (they change without notice — a
portal tweak returns an HTTP 411 and the operator breaks), and the virtual
operator **inherits the human's credentials and access**. Both are managed, not
wished away — see the safety discussion below.

## Why this is possible only now

This is the part worth being honest about. The ambition here is not new — the
*degree of analytics* reached in this system is something that fifteen years of
effort, with the prior generation of tools, could not achieve. The wall was
never sensors, storage, or compute. **It was the cost of integration and
analysis labor, and that cost never came down.**

The old answer to "many heterogeneous systems" was always to **standardize the
interfaces**: define a canonical data model, write a connector per system,
normalize everything into it. That bet has a structural flaw no amount of effort
fixes — standardization never converges. Vendors don't cooperate, every adapter
is bespoke, the adapters rot the moment a UI or firmware changes, and the
integration budget is consumed before any real analysis gets built.

Agents invert the bet:

> Don't make the world conform to a standard interface. Build agents — with AI —
> that adapt to whatever interface already exists, extracting and controlling
> information directly from it.

We do **not** standardize the interfaces. We construct agents that comprehend a
semi-structured, undocumented, drifting interface; extract meaning from it
robustly despite variation; operate it the way a human would; and reason about
the domain well enough to be useful. Each of those four was individually
intractable with pre-agent tooling. Together they collapse the marginal cost of
adding a system or an analysis from an engineer-month to an agent task. When that
cost collapses, the constraint moves from *"can we afford to build this
analysis?"* to *"do we know what to ask?"* — and the achievable degree of
analytics jumps.

The agent shows up in three distinct roles in this system:

1. **As constructor** (build time) — AI helps build the extractors, the
   detectors, the operating procedures. AI building the operator.
2. **As resident operator** (run time) — extract, control, and alert,
   unattended, around the clock.
3. **As resident analyst** (interactive) — the user asks *"why did valve 13 trip
   last night?"* and gets reasoning over the live, persisted system state, the
   system model, and the runbook. This is past a dashboard: a dashboard answers
   questions you anticipated when you built it; an analyst answers the ones you
   think of in the moment.

## Keeping it safe: a deterministic core under an agent layer

Adapting to non-standardized interfaces with AI buys coverage by giving up
determinism. A standardized interface is a contract; an agent reading a portal is
an inference that can be wrong, and a conversational analyst can be confidently
wrong. For a system whose whole purpose includes *safety*, that risk has to be
engineered against, not hoped away.

The architecture answers this by **layering on determinism**:

- A **deterministic, grounded core** runs the always-on, safety-critical loop —
  a local messaging fabric and an on-site database feeding physics-grounded
  detectors. This part is not an LLM and never enters the actuation path without
  an explicit, armed, audited gate.
- A **probabilistic agent layer** does what it is uniquely good at — universal
  extraction and control, construction, and interactive analysis.

The antidote to a wrong inference is **grounding**. The clearest example in this
system is a coil-temperature ("heat-margin") model that was *rejected* because it
computed a physically impossible −118 °C — conservation laws and known constants
gave a ground truth that the inference had to agree with, and didn't. The same
discipline governs the interactive analyst: it is trustworthy precisely to the
degree it reasons over the persisted history and the declared system model and
*cites* them, rather than free-associating.

Safety is therefore expressed as an **autonomy gradient** — observe → alert →
recommend → act — where promotion to the next level is deliberate, arm-gated, and
logged, and where the agent layer is kept out of the always-on actuation path
except through those gates. Coverage of agents, reliability of a control system.

## The strategic consequence

If agents commoditize integration, the adapters are no longer the valuable part —
anyone can point an agent at a portal. The durable, scarce asset is the
**operating knowledge**: the encoded runbooks, the physics groundings, the
failure taxonomies, the safety gates, the system models. Fifteen years of knowing
what a failing valve actually looks like, and what is safe to do about it — that
is the moat. The agent simply made it deployable.

## The themes — and the journey through the robots

Everything above is the claim. The rest of this section is the **demonstration**:
the system, operating, on real robots, against six recurring themes.

1. **Screens it replaces** — which fragmented systems the grower no longer opens.
2. **Same controls as the user** — how it extracts *and* controls through the
   human's own interface.
3. **AI as universal adapter** — what made the interface tractable now, and the
   brittleness that costs.
4. **Workload offloaded** — the specific attention and labor that disappears.
5. **Safety and the autonomy gradient** — where it sits on observe → alert →
   recommend → act, the arming gates, and the grounding that keeps it honest.
6. **Interactive analyst** — the new questions the user can now ask it.

Each robot is the same thesis at a different depth:

- **[farm_soil — consolidation](farm_soil.md).** Many sources (LoRaWAN console,
  two ETo feeds) collapsed into one daily picture. Pure ingest and observe.
- **[rancho_water — the adapter](rancho_water.md).** Deliberately minimal: one
  portal, no actuation. Its job is to make the universal-adapter inversion — and
  its brittleness — concrete before the hard case.
- **[irrigation_analytics — the full virtual operator](irrigation_analytics.md).**
  The robot the project started from, and the only one that exercises all six
  themes: extraction *and* armed control, physics-grounded safety detectors, and
  an interactive analyst a grower can interrogate.

Read them in that order; each escalates from "consolidates screens" toward "the
full supervised virtual operator."
