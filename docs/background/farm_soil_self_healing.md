# farm_soil — self-healing

`farm_soil` is the fleet's pure observer: it reads soil moisture and ETo and
pushes a daily digest. It watches; it doesn't act. But it has one small, telling
exception — and it's worth a look, because it shows how an observe-only agent
earns its *first* sliver of autonomy without sliding toward controlling the farm.

(For the blog-length version see the repo's `articles/farm_soil_self_healing`;
for the mechanical setup see the [README Alexa appendix](https://github.com/glenn-edgar/robot_operator#appendix-alexa-smart-plug-auto-power-on-farm_soil).)

## The 2 a.m. failure mode

The irrigation controller `farm_soil` watches runs on a Raspberry Pi in the
field, plugged into a cheap **Amazon smart plug**. Power blips; the plug stays
off; the Pi stays dark; the controller is gone until a human notices and flips it
back on. Until recently that's exactly what happened — the watchdog detected the
outage and nagged the operator on Discord, *"reset the Alexa plug,"* and someone
eventually did. That's a screen-fatigue chore wearing a different hat.

## The bootstrap paradox

The obvious fix — "have the robot turn its own power back on" — has a trap: the
robot running *on* the dark Pi can't turn anything on, because it isn't running.
You can't pull yourself up by a power cord you're not plugged into.

The resolution is that the recovery doesn't belong to the robot being recovered.
`farm_soil` runs on a **different, always-on machine** and already watches the
field Pi from the outside — awake, networked, and unaffected by the outage it's
responding to. It's the natural owner of the recovery.

## The same controls as a person — again

True to the fleet's core rule, `farm_soil` gets no secret backdoor to the plug.
The Amazon plug has no real API; the only thing that controls it is Alexa. So the
agent does what a person would do: it fires an **Alexa Routine** through a webhook
(Voice Monkey) — the same routine a human could trigger by voice. The grower's own
smart-home account is the only key.

When the watchdog sees the Pi unreachable it fires the "turn on" trigger, waits
for the Pi to boot, and re-probes. If it comes back, the operator gets a
*self-healed* note instead of a chore; if a few attempts don't fix it (the outage
wasn't the plug), it falls back to the original Discord nag. The "turn on" is
idempotent — it can never cut power to a Pi that's actually running.

## Still the bottom of the autonomy gradient

It would be easy to call this "actuation" and get nervous. It isn't, in the way
that matters. `farm_soil` still never touches a valve, never moves water, never
makes an agronomic decision. The one thing it can now do is *keep a crashed
computer alive* — a bounded, idempotent, self-limiting **L0–L1 keep-it-alive
action**. The gradient is intact; the agent simply stopped asking a human to do
the one thing a human should never have had to do.

The quiet lesson: the first responsible step beyond pure observation isn't
controlling the process — it's refusing to let the process go dark on your watch.
