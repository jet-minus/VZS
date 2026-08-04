# Variable Zombie Speed

Configurable day/night zombie speed for **Project Zomboid build 42.20**.

Choose the exact in-game hours at which zombies switch between a day speed and a night speed —
independently for each season — plus night toughness and a combat-only night XP multiplier.

Vanilla can already make zombies slower outside their "active" phase, but the switchover is tied
to the season's dusk and dawn and cannot be configured. This mod makes the timing, the speeds and
the consequences yours.

> Curious *why* it works the way it does? See **[DISCOVERIES.md](DISCOVERIES.md)** — the method
> most guides point at is dead code in this build, and several other things changed in 42.

---

## Features

- **Configurable switchover** — fixed hours, or follow the game's own dusk/dawn
- **Per-season profiles** — separate settings for Spring, Summer, Autumn and Winter
- **Night toughness** — optionally make zombies harder or easier to kill after dark
- **Night combat XP** — a multiplier on XP earned *from fighting*, not from everything
- **Survivor dialogue** — your character mutters something in-character at dusk and dawn
- **Multiplayer safe** — the server is authoritative; clients cannot drift
- **Built to be debugged** — an on-screen readout and a set of console commands

### Defaults

| Profile | Night window | Night speed | Night toughness | Night XP |
|---|---|---|---|---|
| Default | 19:00 – 06:00 | Sprinters | unchanged | 2.0× |
| Spring | 20:00 – 06:00 | Sprinters | unchanged | 2.0× |
| Summer | 21:00 – 05:30 | Sprinters | unchanged | 2.0× |
| Autumn | 19:00 – 06:30 | Sprinters | unchanged | 2.0× |
| Winter | 17:00 – 07:30 | Sprinters | **Tough** | **2.5×** |

Day speed is Shamblers throughout. Every value is configurable.

## Sandbox options

52 options across 7 pages.

**Variable Zombie Speed** — master switch, season handling, switchover timing, whether to override
the vanilla day/night effect, refresh and sweep tuning, dialogue and debug toggles, and the
multiplayer sync interval.

**Night XP** — enable the bonus, choose which skills it covers (weapon skills, Strength, Fitness),
and the combat window in milliseconds.

**Default Profile / Spring / Summer / Autumn / Winter** — seven options each:

| Option | Notes |
|---|---|
| Night starts at (hour) | 24-hour clock, fractions allowed (`19.5` = 19:30) |
| Night ends at (hour) | May be earlier than the start; the window wraps past midnight |
| Night speed | Sprinters / Fast Shamblers / Shamblers / Random |
| Day speed | Same four values |
| Night toughness | Tough / Normal / Fragile / Random / **Leave unchanged** |
| Day toughness | Same five values |
| Night combat XP multiplier | 1.0 disables the bonus for that season |

> **This mod drives your Zombie Lore → Speed setting**, and Toughness if you set it to anything
> other than *Leave unchanged*. If you later disable the mod, the world keeps whatever values were
> in effect at the last switchover. The pre-mod Toughness is recorded in the save's mod data under
> `VariableZombieSpeed.originalToughness`.

---

## Night combat XP

The multiplier applies to XP earned *from fighting* — XP gained within a short window after
hitting a zombie. Night-time exercise, reading and crafting are unaffected.

Covered skills: Axe, Blunt, Small Blunt, Long Blade, Small Blade, Spear, Maintenance, Aiming,
Reloading, plus Strength and Fitness. Each group can be toggled separately.

Because the trigger is "you hit a zombie recently", XP from a fight that spills past the window is
missed, and unrelated XP earned *during* a fight is boosted. Adjust *Combat window (ms)* to trade
one against the other.

---

## Survivor dialogue

With *Survivor comments at dusk and dawn* enabled, your character says something in character when
the night window opens or closes, and when the season turns — rather than announcing the mechanic.

Lines are drawn from up to four pools: a general pool for the transition, an outdoor-only pool for
lines that reference the sky, a season-specific pool, and a darker pool when the coming night is a
Sprinter night. The picker avoids repeating the previous line.

All lines are plain strings at the top of `VZS_Flavour.lua` — edit them freely. Speech bubbles
make no noise and do not attract zombies.

---

## Multiplayer

The server is authoritative. It resolves the phase, speed, toughness and XP multiplier and
broadcasts them; clients apply that state verbatim and never consult their own clock.

This is not merely tidy. PZ gives zombie ownership to the nearest player and the server accepts
the owner's positions, so a client that disagreed about the phase would move zombies wrongly **for
everyone**, not just on its own screen. Details in
[DISCOVERIES.md](DISCOVERIES.md#4-multiplayer-agreement-has-to-be-structural).

- A joining client is sent the current state immediately, retrying until answered.
- The server re-broadcasts once a second by default (*Server sync interval*) so a client that
  missed an update recovers. The payload is a handful of numbers; the cost is negligible.
- Every client needs the mod. A client without it renders zombies at its own setting permanently.

Singleplayer is unaffected by all of this.

---

## Debugging

Enable **Debug logging** for an on-screen readout: season and active profile, current hour and
window, phase, target vs applied speed, applied toughness, live XP multiplier, a census of loaded
zombies by speed type, sync state and error counters.

Console commands (in-game Lua console, which requires debug mode — and admin access on a server):

| Call | What it does |
|---|---|
| `VZS.status()` | Full state dump to `console.txt` |
| `VZS.profiles()` | Print all five profiles side by side |
| `VZS.force("night")` | Pretend it is night. Also `"day"`, or `nil` to release |
| `VZS.reapply()` | Re-evaluate and re-apply from scratch |
| `VZS.dump(20)` | Print speed type / walk type / crawling for loaded zombies |
| `VZS.flavour.test("nightfall")` | Preview a dialogue line now |
| `VZS.xp.reset()` | Zero the XP counters to measure a clean interval |
| `VZS.syncStatus()` | Multiplayer sync detail on a client |
| `VZS.desync(1)` | Pin this machine off-sync to test multiplayer disagreement |

All log lines are prefixed `[VZS]`.


## Project layout

```
VariableZombieSpeed/
├── README.md
├── DISCOVERIES.md          how and why, with the bytecode evidence
├── tools_gen_options.py    generates the two files below from one source
└── common/
    ├── mod.info
    └── media/
        ├── sandbox-options.txt
        └── lua/
            ├── client/VariableZombieSpeed/
            │   ├── VZS_Xp.lua              night combat XP
            │   ├── VZS_Flavour.lua         survivor dialogue
            │   ├── VZS_SyncClient.lua      receives server state
            │   └── VZS_DebugHUD.lua        on-screen readout
            ├── server/VariableZombieSpeed/
            │   ├── VZS_Sync.lua            broadcasts state, answers joins
            │   └── VZS_XpServer.lua        XP authority
            └── shared/
                ├── Translate/EN/Sandbox.json
                └── VariableZombieSpeed/VZS_Core.lua
```

`sandbox-options.txt` and `Sandbox.json` are **generated** — edit `tools_gen_options.py` and
re-run it, not the outputs. It keeps the 52 option ids and their 124 translation keys in sync.

---

## Status

Speed switching, toughness, per-season profiles and the survivor dialogue are working in
singleplayer. Multiplayer has been tested against a local dedicated server: the mod loads, state
sync works, and the zombie-ownership and XP-authority paths behave. Long-run multiplayer with
several players is still untested.

Every build is checked without launching the game, using the game's own tooling: all Lua compiled
with PZ's Kahlua compiler, `sandbox-options.txt` parsed with PZ's own `CustomSandboxOptions`
parser, translation keys derived from that output and diffed against the JSON, Lua fallback
defaults diffed against the real option ids, and every Java method checked for a matching overload
with `javap`. See [DISCOVERIES.md](DISCOVERIES.md#7-how-this-was-verified).

## License

See [LICENSE](LICENSE).
