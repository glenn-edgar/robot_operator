# farm_soil — consolidation

The simplest expression of the thesis: take several systems the grower would
otherwise open and read by hand, and collapse them into **one daily picture**.
`farm_soil` ingests LoRaWAN soil-moisture data and evapotranspiration context,
reasons about them together, and pushes a single digest. It observes; it does not
act. That makes it the clean place to see the *consolidation* theme before
control enters the story.

(For the mechanical spec — KBs, config keys, namespace — see
[Fleet framework → Robot classes](../fleet/robots.md#farm_soil).)

## 1. Screens it replaces

Three, at least:

- **The LoRaWAN / TTN console** — where soil-sensor uplinks would otherwise be
  read, per device, per sensing point.
- **The CIMIS station ETo page** — local evapotranspiration.
- **The CIMIS spatial (grid) ETo source** — the regional picture.

Without the robot the grower logs into the sensor console, reads each device,
then opens the ETo sources separately and does the cross-reference in their head.
After the robot, those three live in one place and arrive as one digest.

## 2. Same controls as the user

`farm_soil` pulls from each system exactly the way a person (or their browser)
would: `ttn_client.lua` issues authenticated HTTPS requests to The Things
Network — the same endpoint the console uses — and the CIMIS sources are fetched
the same way. There is no privileged sensor-vendor backend involved; the
operator's own credential (`TTN_BEARER_TOKEN`) is the only key, mounted
read-only.

It is **read-only by design**. The "controls" it uses are entirely the *reading*
controls — there is nothing on a soil sensor to actuate. This is the bottom of
the autonomy gradient, on purpose.

## 3. AI as universal adapter

The adaptation work here is **comprehending the uplink stream**: `decoder.lua`
parses SenseCAP S2105 frames out of the TTN payloads. New devices are
*dynamic* — a `<device>/<location>` subtree appears the first time a device is
seen in the stream, so adding a sensor is one config entry, not a code change.
The agent absorbs the shape of the data instead of demanding the sensor network
conform to a schema.

It also documents a brittleness lesson that recurs across the fleet: the
**zenoh-pico per-sample-publish constraint** — batching multiple readings into
one payload silently dropped messages on the bench, so the robot publishes each
genuinely-new reading individually. Adapting to real transports means respecting
their sharp edges.

## 4. Workload offloaded

The daily labor that disappears:

- Logging into the sensor console and reading N sensing points.
- Opening two ETo sources and noting the day's numbers.
- Holding "is this soil dry because it's hot, or because something's wrong?" in
  your head by manually pairing moisture against ETo.

The `moisture` KB polls on its own cadence (hourly), dedups against a per-slot
ring so nothing is double-counted, and the `digest` KB fires a single daily
one-shot at the configured Pacific hour — disk-marker-gated so a container
restart doesn't re-send it. The grower reads one message instead of running a
morning routine across three systems.

## 5. Safety and the autonomy gradient

`farm_soil` sits firmly at **observe → alert (L0–L1)**. It never actuates, so the
safety surface is small — the failure mode that matters is *silent* failure. A
robot whose whole value is "you don't have to check anymore" must fail loud: a
TTN poll that comes back empty, or a CIMIS fetch that doesn't complete, has to
read as a problem, not as "all clear." The daily-gated CIMIS state machine and
the health-aware heartbeat (KB0 rolls each app-KB's liveness into the published
heartbeat) are what keep an absence of data visible.

There is no physics-grounding drama here because there is no inference being
trusted with an action — that theme arrives with irrigation_analytics. What
farm_soil establishes is the **discipline of grounding in stored truth**: the
robot is stateless between ticks, and the Zenoh slots (plus the persisted ring)
are the single source of truth — not anything the robot holds in memory.

!!! note "One bounded exception — keeping the lights on"
    farm_soil is observe-only over the *field*: it never touches a valve. The
    single action it can take is **operational, not agronomic**. The irrigation
    Pi it watches is powered by an Amazon smart plug, and when the
    `irrigation_watchdog` finds that Pi unreachable after a power blip, it powers
    the plug back on via an Alexa trigger (Voice Monkey), re-probes, and only
    nags a human on Discord if that self-heal fails. Turning a crashed box back
    on is squarely an L0–L1 *keep-it-alive* action — not control of the
    irrigation — so the autonomy gradient stays intact. Setup is in the
    repository README's *Alexa smart-plug* appendix.

## 6. Interactive analyst

Because every reading is persisted under a hierarchical (`ltree`) path, the
resident analyst can answer questions the digest never anticipated:

- *"What's the moisture trend at the north block this week versus ETo?"*
- *"Which sensing points haven't reported since yesterday?"*
- *"Is the east field drying faster than the west, controlling for ETo?"*

These are answered over the actual persisted history, not a pre-built chart —
the difference between a screen and a colleague.

---

`farm_soil` shows consolidation and observe-only operation. Next,
[**rancho_water**](rancho_water.md) strips the pattern down to a single screen to
make the *universal-adapter* theme — and its brittleness — impossible to miss.
