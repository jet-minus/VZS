# Variable Zombie Speed

Sandbox-configurable night sprinters for Project Zomboid **build 42.20**.

Pick the exact in-game hours at which zombies switch between a *day speed* and a *night speed* —
independently for each season — plus night Toughness and a combat-only night XP multiplier.

Defaults: shamblers by day, sprinters at night, 2x combat XP at night, with the night window
moving from 21:00–05:30 in summer to 17:00–07:30 in winter, where zombies also turn Tough and
combat XP goes to 2.5x.

| Profile | Night window | Night speed | Night toughness | Night XP |
|---|---|---|---|---|
| Default | 19:00 – 06:00 | Sprinters | unchanged | 2.0x |
| Spring | 20:00 – 06:00 | Sprinters | unchanged | 2.0x |
| Summer | 21:00 – 05:30 | Sprinters | unchanged | 2.0x |
| Autumn | 19:00 – 06:30 | Sprinters | unchanged | 2.0x |
| Winter | 17:00 – 07:30 | Sprinters | **Tough** | **2.5x** |

---

## Install

The mod folder is already in the right place:

```
C:\Users\Michael\Zomboid\mods\VariableZombieSpeed\
```

Enable **Variable Zombie Speed** in Main Menu → Mods, then configure it under
**Sandbox Options → Variable Zombie Speed** when starting a new game (or via the in-game admin
sandbox panel on a server).

```
VariableZombieSpeed/
├── README.md
└── common/                                                   -- REQUIRED in 42.x, see below
    ├── mod.info
    └── media/
        ├── sandbox-options.txt
        └── lua/
            ├── client/VariableZombieSpeed/
            │   ├── VZS_Xp.lua                                -- night combat XP multiplier
            │   ├── VZS_Flavour.lua                           -- survivor dialogue at dusk/dawn
            │   └── VZS_DebugHUD.lua                          -- on-screen readout (debug only)
            ├── server/VariableZombieSpeed/
            │   └── VZS_XpServer.lua                          -- XP authority (multiplayer)
            └── shared/
                ├── Translate/EN/Sandbox.json                 -- JSON in 42.x, NOT Sandbox_EN.txt
                └── VariableZombieSpeed/VZS_Core.lua          -- speed, toughness, seasons, timing
```

`sandbox-options.txt` and `Sandbox.json` are generated from one source so the 51 option ids and
their 122 translation keys cannot drift apart. Edit the generator, not the two outputs.

### Why everything lives in `common/`

Worth writing down, because a mod laid out the old way is skipped *silently*. In 42.20 the mod
scanner is `ZomboidFileSystem.getAllModFoldersAux()`, and for each folder under `Zomboid/mods/`
it does effectively:

```java
String versionDirName = getModVersionDirName(path);   // best-matching "42.x" subfolder, if any
if (!Files.exists(path.resolve("common",       "mod.info"))
 && !Files.exists(path.resolve(versionDirName, "mod.info"))) {
    continue;                                          // not a mod, skipped
}
```

There is **no check for `mod.info` at the folder root**. The build 41 layout
(`VariableZombieSpeed/mod.info` + `VariableZombieSpeed/media/`) is never seen, so the mod does not
appear in the Mods menu and nothing is logged at the default log level.

A 42.x mod therefore needs its `mod.info` and `media/` inside either:

* `common/` — loaded on every build (what this mod uses), or
* a version folder such as `42.20/` — for shipping different content per build.
  `getModVersionDirName()` picks the highest-numbered version folder that is `<=` the running
  game version.

Both are supported at once; workshop mods like *that DAMN Library* ship `common/` plus `42.0/`,
`42.13/`, `42.17/`. Those mods often *also* keep a root `mod.info`, but that is vestigial B41
compatibility and is not what 42.x reads — likely why a mod that "worked with a `.txt`" seemed to
prove the root layout was fine.

`CustomSandboxOptions.init()` follows the same rule for `sandbox-options.txt`: it tries
`<versionDir>/media/sandbox-options.txt` first, then falls back to
`<commonDir>/media/sandbox-options.txt`.

One smaller layout note: `CustomSandboxOptions.readFile()` concatenates the file's lines with
**no separator** before parsing, so a `--` line comment in `sandbox-options.txt` would comment out
the entire rest of the file. This mod's file contains no comments.

### Translations are JSON in 42.x, not `_EN.txt`

Second thing that bit us: the options appeared in the menu, but showed raw keys instead of labels.

`Translator.loadFiles()` walks a fixed registry (`Translator$1`, 30 entries including `Sandbox`)
and for each one loads exactly:

```
%s/media/lua/shared/Translate/%s/%s.json      // <dir>/media/lua/shared/Translate/EN/Sandbox.json
```

`tryFillMapFromMods()` runs the same lookup against every enabled mod's `getCommonDir()` and
`getVersionDir()`. **There is no code path that reads `Sandbox_EN.txt` any more** — the B41
Lua-table translation format is dead in 42.x. This is also why some workshop mods that still ship
`Sandbox_EN.txt` (damnlib among them) show raw keys for their own options on 42.20.

So the file must be `Translate/EN/Sandbox.json`: flat JSON object, UTF-8, **no BOM**, no language
suffix in the filename (the folder is the language).

The keys are built by string concatenation in `SandboxOptions$EnumSandboxOption` — read straight
out of the `BootstrapMethods` recipes, so these are exact:

| What | Key | Source |
|---|---|---|
| Option label | `Sandbox_<translation>` | `getTranslatedName()` |
| Option tooltip | `Sandbox_<translation>_tooltip` | `getTooltip()` |
| Enum value label | `Sandbox_<valueTranslation>_option<N>` | `getValueTranslationByIndexOrNull()` |
| Page heading | `Sandbox_<page>` | |

`<translation>`, `<valueTranslation>` and `<page>` are the values you wrote in
`sandbox-options.txt`. Note the `Sandbox_` prefix is added by the game — do **not** include it in
`sandbox-options.txt`, and **do** include it in the JSON.

For a line break inside a tooltip, write `\\n` in the JSON source (it decodes to a literal `\n`
two-character sequence, which the game then turns into a break) — this is what vanilla's
`Sandbox.json` does.

Keys 42.20 reads from `mod.info`: `name`, `id`, `description`, `author`, `modversion`, `category`,
`icon`, `poster`, `url`, `type`, `pack`, `tiledef`, `require`, `incompatible`, `loadModAfter`,
`loadModBefore`, `versionMin`, `versionMax`. Everything except `id` is optional; `versionMin` /
`versionMax` are parsed with `GameVersion.parse()` (`([0-9]+)\.([0-9]+)(.*)`) and are omitted here
so they cannot narrow compatibility while debugging.

---

## How zombie speed actually works in 42.20

This is the part that matters, because it is what the currently-broken night-sprinter mods get
wrong. All of it was read directly out of `projectzomboid.jar` for 42.20, not from old wiki pages.

**1. Every zombie carries an int `speedType`** — `1` sprinter, `2` fast shambler, `3` shambler.

**2. The run flag comes from the *global* option, recomputed every pathfind tick.**

> **Correction.** Earlier versions of this document cited
> `IsoZombie.getZombieWalkTowardSpeed()`. That method is **dead code in 42.20** — it appears
> exactly once in `IsoZombie`'s bytecode, its own declaration, and nothing in the jar invokes it.
> The live path is `PathFindBehavior2`, which does this in *both* `update()` and `moveToPoint()`:

```java
zombie.running = false;
if (SandboxOptions.instance.lore.speed.getValue() == 1) zombie.running = true;
```

Two things follow, and both matter:

* `running` is decided **purely by the global option** — `speedType` plays no part in it. Setting
  a single zombie's `speedType` to 1 does *not* make it run.
* It is recomputed locally on **every machine**, every pathfind tick, for remote zombies too, and
  is never networked. That is the multiplayer hazard described below.

The per-zombie half still matters, but through animation rather than arithmetic: `walkType` is the
`zombieWalkType` animation variable, and the AnimSets select on it
(`sprintPathfind1.xml` → `Zombie_Sprint`, `pathfind1.xml` → `Zombie_Walk` with
`<m_SpeedScale>0.92</m_SpeedScale>`, `zombieWalkSlow1.xml` → a slow variant). Movement magnitude
in `PathFindBehavior2.update()` comes from the animation vector, so the chosen animation *is* the
speed, via root motion.

`speedMod` (`0.85` fast shambler, `0.55` shambler, `0.3` crawler) is written by `doZombieSpeed()`
and travels in `ZombiePacket`, but is a much smaller lever than the animation choice.

**3. `doZombieSpeed(n)` does *not* reliably honour `n`.** `doZombieSpeedInternal` is:

```java
n = determineZombieSpeed(n);                       // n == -1 means "read the sandbox option"
if (crawling)                          doCrawlerSpeed(n);
else if (sandboxSpeed == 3 || n == 3)  doShambler();          // <-- short-circuit
else if (Rand.Next(3) != 0)            doFakeShambler(n);
else if (sandboxSpeed == 2 || n == 2)  doFastShambler();
else if (sandboxSpeed == 1 || n == 1)  doSprinter();
```

If the world's `ZombieLore.Speed` is *Shamblers*, then `doZombieSpeed(1)` still calls
`doShambler()`. **This is almost certainly why the existing mods are broken** — they try to
promote individual zombies to sprinters while the global option stays on shamblers, and the
short-circuit throws it away.

**4. Vanilla already has a night/day speed system**, `ZombieLore.ActiveOnly`
("Day/Night Zombie Speed Effect", 1 = Both / 2 = Night / 3 = Day):

```java
boolean isZombieActivityPhase() {
    if (activeOnly == 1) return true;
    if (activeOnly == 2 && isNight()) return true;
    if (activeOnly == 3 && isDay())   return true;
    return false;
}
```

Every tick, `IsoZombie.updateInternal()` calls `updateActiveState()` →
`makeInactive(isZombieInactivityPhase())`, and an inactive zombie is pinned to `speedType = 3`.
The switchover times come from the *season's* dusk and dawn
(`isDay() == timeOfDay >= season.getDawn() && timeOfDay <= season.getDusk()`) and are not
configurable — which is exactly the gap this mod fills.

### What this mod therefore does

At each switchover it does **both** halves, because either alone fails in one direction:

1. Writes the new value into the global `ZombieLore.Speed` sandbox option.
   *Needed for night → day*: without it, `sandboxSpeed == 1` keeps every zombie sprinting no
   matter what their `speedType` says.
2. Walks the loaded zombie list and calls `doZombieSpeed(-1)` on each, forcing it to re-derive
   from the (now updated) global option.
   *Needed for day → night*: without it, zombies keep the `speedType` and `speedMod` they were
   assigned when they spawned.

It also sets `ZombieLore.ActiveOnly` to *Both* so the vanilla dusk/dawn effect does not fight it
(toggleable), and runs a low-rate background sweep that fixes any zombie whose `speedType` does
not match the current phase — this catches zombies streaming in from chunks that were unloaded
during the switchover.

If `doZombieSpeed(-1)` is unavailable or does not produce the requested speed, it falls back to
setting `walkType` directly (`"sprint1".."sprint5"` → 1, `"slow1".."slow3"` → 3, `"1".."5"` → 2,
per `getSpeedTypeFromWalkType`) and calling `setSpeedTypeFromWalkType()`. `walkType` is also the
`zombieWalkType` animation variable, so the animation stays in sync with the speed.

---

## Toughness, and why Strength is not included

**Toughness works cleanly.** `IsoPlayer.calculateCritChance()` reads the global option live on
every hit:

```java
if (target instanceof IsoZombie) {
    if (lore.toughness.getValue() == 1) crit -= 6.0f;   // Tough
    if (lore.toughness.getValue() == 3) crit += 6.0f;   // Fragile
}
```

Nothing is cached per zombie, so writing `ZombieLore.Toughness` takes effect immediately for
every zombie — no refresh pass needed. Each profile's *Night/Day toughness* defaults to
**Leave unchanged**, which restores whatever Toughness the world was created with. That original
value is captured into the save's mod data the first time the mod runs, so reloading a world at
night cannot mistake our own value for the original.

**Strength is deliberately not exposed**, for two reasons found in the bytecode:

1. It does not do what the name suggests. The only classes that read `IsoZombie.strength` are
   `IsoBarricade`, `IsoDoor`, `IsoWindow` and `AttackVehicleState` — it governs how fast zombies
   smash through barricades, doors, windows and vehicles. It has no effect on the damage a
   zombie does to you.
2. It cannot be changed on existing zombies from Lua. `strength` is a per-zombie int that
   `DoZombieStats()` only re-derives when it equals `-1`; there is no `setStrength()`; and
   Kahlua's `LuaJavaClassExposer` binds `java.lang.reflect.Method` objects only — it has no
   field handling at all, so `zombie.strength = -1` from Lua just writes an ignored Lua property.

A Strength option would therefore have silently applied only to zombies spawned after the
switchover, which is worse than not having it.

---

## Night combat XP

The requirement was a multiplier on XP *from fighting*, without boosting night-time exercise or
crafting. The obvious tool does not do that:

`IsoGameCharacter.XP.addXpMultiplier(perk, mult, minLvl, maxLvl)` writes a single `XPMultiplier`
per perk into `xpMapMultiplier` — the same map the skill-book system uses. It replaces rather
than stacks (good), but it applies to *every* XP gain for that perk regardless of source, and it
would clobber a book's multiplier.

So this mod measures instead:

1. `OnHitZombie(zombie, wielder, bodyPart, weapon)` opens a short combat window for that player
   (default 1000 ms, configurable).
2. On every `OnPlayerUpdate`, each tracked perk's cumulative XP is compared against its previous
   value. `getXP(perk)` is cumulative — it is compared internally against
   `Perk.getTotalXpForLevel(n)` — so it never resets on level-up and deltas are always positive.
3. If XP rose *inside* the combat window, the gain is topped up by `delta * (mult - 1)` via
   `addXpNoMultiplier()`, so the bonus cannot be re-multiplied by traits. The baseline is
   re-read afterwards so the bonus is never counted as a fresh gain next tick.

The result is a true multiplier on exactly the combat-derived XP. Tracked perks (all verified to
exist in 42.20's `PerkFactory$Perks`):

* **Weapon skills** — Axe, Blunt, SmallBlunt, LongBlade, SmallBlade, Spear, Maintenance, Aiming,
  Reloading
* **Strength**, **Fitness** — each individually toggleable

Because the trigger is "you hit a zombie recently", XP from a fight that spills a second past the
window is missed, and XP from a non-combat source *during* a fight is boosted. Raise or lower
*Combat window (ms)* to trade one against the other. Turning the feature off skips the per-tick
loop entirely.

---

## Survivor dialogue

With *Survivor comments at dusk and dawn* enabled, your character mutters an in-character line
when the night window opens or closes, and when the season turns — rather than announcing the
mechanic. All lines live in plain tables at the top of `VZS_Flavour.lua`; edit them freely.

A line is drawn from up to four pools combined:

| Pool | When |
|---|---|
| `nightfall` / `daybreak` | always |
| `nightfallOutdoor` / `daybreakOutdoor` | only when `player:isOutside()` — these reference the sky, so they would read oddly indoors |
| `bySeason[<profile>].nightfall` / `.daybreak` | when a season profile is active |
| `nightfallSprinters` | when the coming night's speed is *Sprinters* |

The picker avoids repeating the previous line. `season` is its own small pool.

Implementation notes:

* `IsoGameCharacter.Say(String)` is the speech-bubble call. Internally it forwards to the long
  overload with the character's `speakColour` and passes `false` for the noise flag, so **it does
  not attract zombies**.
* It fires on the phase flip itself, not on the speed write. That matters in two ways: the
  survivor still comments at dusk when night and day are set to the *same* speed, and stays quiet
  on world load, where a sudden "the light's going" would make no sense.
* Suppressed while dead or asleep.
* `VZS.flavour.test("nightfall")` previews a line immediately — also `"daybreak"` or `"season"`.

---

## Seasons

`getClimateManager():getSeasonId()` returns `ErosionSeason.SEASON_*`, which this mod maps to a
profile page:

| Season id | Constant | Profile |
|---|---|---|
| 0 | `SEASON_DEFAULT` | Default |
| 1 | `SEASON_SPRING` | Spring |
| 2 | `SEASON_SUMMER` | Summer |
| 3 | `SEASON_SUMMER2` | Summer (late/dry summer shares the profile) |
| 4 | `SEASON_AUTUMN` | Autumn |
| 5 | `SEASON_WINTER` | Winter |

Set *Season handling* to **Single profile** to ignore all of that and always use the Default
Profile page. A season change is treated as a switchover, so speed, toughness and the XP
multiplier all re-apply the moment the season rolls over.

Note that *Switchover timing* is global, not per-profile: setting it to **Game dusk/dawn** makes
every profile ignore its Night Start / Night End hours and follow the season's own dusk and dawn
instead, which already lengthens winter nights on its own.

---

## Sandbox options

51 options across 7 pages.

### Page: Variable Zombie Speed

| Option | Default | Notes |
|---|---|---|
| Enable Variable Zombie Speed | on | Off = mod never touches anything, pure vanilla. |
| Season handling | Per-season profiles | Or *Single profile* to always use the Default Profile page. |
| Switchover timing | Fixed hours | Global, not per-profile. *Game dusk/dawn* makes every profile ignore its hours. |
| Override vanilla day/night effect | on | Forces `ZombieLore.ActiveOnly` to *Both*. |
| Re-roll loaded zombies on switch | on | Turn off only to test whether the global option alone is doing the work. |
| Zombies re-rolled per tick | 250 | Lower if dusk/dawn stutters on a high-population world. |
| Background correction sweep | on | Skipped automatically when the phase speed is *Random*. |
| Sweep interval (ticks) | 30 | |
| Zombies checked per sweep | 100 | |
| Survivor comments at dusk and dawn | off | In-character speech bubble. Makes no noise. See *Survivor dialogue*. |
| Debug logging | off | Verbose `console.txt` logging **and** an on-screen readout. |

### Page: Night XP

| Option | Default | Notes |
|---|---|---|
| Enable night combat XP bonus | on | Off skips the per-tick XP loop entirely. |
| Boost weapon skills | on | Axe, Blunt, SmallBlunt, LongBlade, SmallBlade, Spear, Maintenance, Aiming, Reloading. |
| Boost Strength | on | |
| Boost Fitness | on | |
| Combat window (ms) | 1000 | How long after hitting a zombie XP still counts as combat XP. |

The multiplier itself is per-profile, so each season can pay differently.

### Pages: Default Profile / Spring / Summer / Autumn / Winter

Seven options each, identical layout:

| Option | Notes |
|---|---|
| Night starts at (hour) | 24-hour clock, fractions allowed (`19.5` = 19:30). |
| Night ends at (hour) | May be earlier than the start; the window wraps past midnight. |
| Night speed | Sprinters / Fast Shamblers / Shamblers / Random. |
| Day speed | Same four values. |
| Night toughness | Tough / Normal / Fragile / Random / **Leave unchanged**. |
| Day toughness | Same five values. |
| Night combat XP multiplier | 1.0 disables the bonus for that season. |

> **This mod overrides your Zombie Lore → Speed setting, and Toughness if you set it to anything
> other than *Leave unchanged*.** While enabled it continuously drives those options. If you later
> disable the mod, the world keeps whatever values were in effect at the last switchover — set
> Zombie Lore → Speed / Toughness back by hand if that matters. The pre-mod Toughness is recorded
> in the save's mod data under `VariableZombieSpeed.originalToughness`.

---

## Debugging

Since the 42.20 behaviour is not fully documented anywhere, the mod is built to be inspected.

**Turn on `Debug logging`.** You get a seven-line on-screen readout (top-left) showing the season
and active profile, the current hour and window, the phase, target vs applied speed, applied
toughness, the live combat XP multiplier, a census of loaded zombies by `speedType`, whether the
engine considers this an active phase, and how many `walkType` fallbacks have been needed.

**Console functions** — usable from the in-game Lua console (debug mode) or any Lua entry point:

| Call | What it does |
|---|---|
| `VZS.status()` | Full state dump to `console.txt`, including the XP section. |
| `VZS.profiles()` | Print all five profiles side by side, so you can see what each season will do. |
| `VZS.force("night")` | Pretend it is night regardless of the clock, and switch immediately. |
| `VZS.force("day")` | Same for day. |
| `VZS.force(nil)` | Back to the real clock. |
| `VZS.reapply()` | Re-evaluate and re-apply from scratch. |
| `VZS.dump(20)` | Print `speedType` / `walkType` / `crawling` for the first 20 loaded zombies. |
| `VZS.speedCensusString()` | One-line count of loaded zombies by speed. |
| `VZS.xp.rebuild()` | Rebuild the tracked perk list after changing the XP toggles mid-game. |

| `VZS.xp.reset()` | Zero the XP counters so you can measure a clean interval. |
| `VZS.flavour.test("nightfall")` | Preview a dialogue line now. Also `"daybreak"` / `"season"`. |
| `VZS.desync(1)` | Pin this machine to a speed and stop it resyncing, to test multiplayer desync. `VZS.desync()` releases. |

Testing the XP bonus is easiest with `VZS.force("night")`, then hit a zombie and watch `grants`
climb in `VZS.status()`. **Remember to call `VZS.force(nil)` afterwards** — the override sticks
for the rest of the session and makes it permanently night for both speed *and* XP.

### Is the XP bonus firing when it should not?

The bonus and the zombie speed switch are gated by the *same* `VZS.isNightPhase()` call, so they
cannot disagree. If XP is being boosted during the day then the phase itself is wrong, which
means zombies are also running at their night speed at noon. Check the HUD's `phase` field first.

Two HUD lines answer this directly:

* **Line 5**, `combat XP x2.00 (potential)` — the multiplier the current phase *would* apply.
  It reads 2.00 for the whole night whether or not you are fighting. It is not evidence that a
  bonus is being paid.
* **Line 6**, `xp: inCombat false  grants 12  bonus 340  last at hour 21.15` — what has actually
  been paid, and the in-game hour of the most recent payment.

With `Debug logging` on, every bonus is also written to `console.txt` (rate-limited to one line
per second) with the hour it happened at:

```
[VZS] xp bonus +2.50 Blunt at hour 21.15 (phase NIGHT, profile Winter, mult 2.50, 12 grants total)
```

If those lines show daytime hours, the gate is genuinely broken. If `last at hour` only ever shows
night hours, the bonus is behaving and the constant XP is coming from somewhere else.

All log lines are prefixed `[VZS]` in `%USERPROFILE%\Zomboid\console.txt`.

### If something is wrong, check in this order

0. **The mod is not in the Mods menu at all.** Layout problem, not a code problem — see
   "Why everything lives in `common/`" above. `mod.info` must be under `common/`.
0b. **Options show raw keys like `Sandbox_VZS_Enable` instead of labels.** Translation problem —
   the file must be `Translate/EN/Sandbox.json`, not `Sandbox_EN.txt`. See above.
1. **`VZS.status()` → `sandbox Speed`.** If this is not the target value, the write to
   `ZombieLore.Speed` failed and the error is in `last error`. Nothing else will work until
   this does.
2. **`engine active phase: false`.** The vanilla `ActiveOnly` option is forcing zombies inactive,
   which pins them to shamblers. Turn on *Override vanilla day/night effect*, or set Zombie Lore →
   Day/Night Zombie Speed Effect to *Both* yourself.
3. **Census shows the right `speedType` but zombies still look wrong.** `speedType` is correct but
   `speedMod` is stale — check `walkType fallbacks`; a high number means `doZombieSpeed(-1)` is
   not landing and only the fallback path is running. Fast shambler vs shambler is a `speedMod`
   difference only, so the fallback cannot fix that one; sprinting is unaffected because sprint
   speed is hardcoded to `0.08` and ignores `speedMod`.
4. **Census is mixed after a switch.** Normal for a few seconds while the batched refresh runs
   (`[refreshing]` shows in the HUD). If it persists, raise *Zombies re-rolled per tick*.
5. **Nothing in `console.txt` at all.** The mod's Lua did not load — check for a load error near
   the top of `console.txt`.
6. **The wrong profile is active.** `VZS.status()` prints both the season name and the resolved
   profile. Remember `SEASON_SUMMER2` maps to the Summer profile, and `SEASON_DEFAULT` maps to
   Default. If *Season handling* is *Single profile*, the profile is always Default.
7. **XP bonus not paying out.** Check `tracked perks` is non-zero in `VZS.status()` (it is zero
   if all three XP toggles are off), that `active mult` is above 1.00, and that `in combat` goes
   true while you are swinging. If the multiplier is 1.00 at night, the active profile's *Night
   combat XP multiplier* is 1.0.
8. **Toughness looks stuck.** It only changes when the profile asks for a different value; the
   HUD shows the applied value. *Leave unchanged* restores the recorded original, so if that
   original was captured while a previous version of the mod had already modified Toughness, clear
   `VariableZombieSpeed.originalToughness` from the save's mod data.

### A note on 2/3 of your "fast shamblers"

`doZombieSpeedInternal` sends `Rand.Next(3) != 0` (two thirds) of zombies down `doFakeShambler`,
which assigns `speedMod = 0.55` — shambler pace — while still setting the requested `speedType`.
This is vanilla behaviour, not a mod bug. It is invisible for *Sprinters* (sprint speed bypasses
`speedMod`) but means *Fast Shamblers* is genuinely a mixed-pace population.

---

## Multiplayer

Still untested against a real dedicated server, but three concrete multiplayer defects found by
reading the netcode have been fixed.

### Zombie ownership — only touch what you simulate

`ZombiePacket` carries both fields this mod manipulates:

```java
public short speedMod;
public NetworkVariables$WalkType walkType;   // WT1-5, WTSprint1-5, WTSlow1-3
```

and `NetworkZombieAI` applies them on receipt with `setWalkType()` + `setSpeedTypeFromWalkType()`.
Zombies are network-owned (`getOwner()` returns a `UdpConnection`, plus `isRemoteZombie()`), so a
speed written to a zombie owned by another machine is overwritten by their next packet. The old
code would have fought the network forever and the sweep would never converge.

`VZS.ownsZombie()` now filters the refresh and sweep: on a client, skip `isRemoteZombie()`; on the
server, skip anything with an owning connection. It short-circuits to `true` in singleplayer, so
it is provably a no-op there. The skip count shows in the HUD and `VZS.status()`.

Reassuringly, the `WalkType` enum values map exactly onto the strings the `setWalkType` fallback
writes, so that path produces network-legal values rather than corrupting the packet.

### XP had to move server-side

All three Lua XP globals share this shape:

```java
if (GameServer.server) { GameServer.addXp(...); }
if (GameClient.client) return;          // <-- client does nothing at all
player.getXp().AddXP(...);              // singleplayer only
```

`addXpNoMultiplier()` on a multiplayer client is a **silent no-op** — no error, no log, the bonus
simply never lands. The night XP feature did nothing in multiplayer.

Now: the client still detects the gain (`OnHitZombie` and `OnPlayerUpdate` both fire client-side),
but sends the computed bonus over `sendClientCommand(player, "VZS", "grantXp", …)`.
`server/VariableZombieSpeed/VZS_XpServer.lua` validates and pays it out, where
`addXpNoMultiplier()` routes into `GameServer.addXp()` and actually lands. Singleplayer keeps
granting locally and skips the round-trip.

Server-side validation, because a number off the wire is not trustworthy: the perk must be one of
the 11 the client tracks, the amount must be positive and non-NaN, it is clamped to 250 XP per
message, and `Enable`/`XpEnable` are re-checked so a client cannot pay itself while the feature is
off for the world.

**The subtle part** is that the grant is now asynchronous. Re-reading `getXP()` after the grant —
which is what made this safe in singleplayer — no longer works, because the bonus lands several
ticks later and would be read as fresh combat XP and boosted again, compounding without limit. So
the module tracks a **pending credit** per perk: a bonus is remembered when requested and the
matching later gain is absorbed rather than re-boosted. Credit that never arrives within 15
seconds is discarded so a rejected grant cannot mask real XP forever. That accounting is uniform
across singleplayer and multiplayer rather than being a special case.

### External changes are now re-asserted

`VZS.state.appliedSpeed` is only this mod's memory of its last write. If anything else changed
`ZombieLore.Speed` or `ZombieLore.Toughness` — the admin sandbox panel, a server pushing settings,
another mod — the change persisted until the next dusk or dawn. Both are now compared against the
option's **live** value each evaluation and re-asserted on mismatch, counted as `external drift`
in the HUD and `VZS.status()`. This was a real bug in singleplayer too.

### The server decides; clients follow

Testing on a live server showed that a client holding a different `ZombieLore.Speed` **moved
zombies faster and was not corrected** — no snapping. That is the important result, and it is
worse than rubber-banding would have been.

PZ hands zombie ownership to the nearest player and the server accepts the owner's positions. So
a disagreeing client does not merely *render* zombies wrongly; it moves them wrongly **for
everyone else too**. Faster polling shrank the dusk/dawn gap but could never make agreement a
guarantee — two machines independently reaching the same answer from a shared clock is a
coincidence, and coincidences have edge cases (a client whose season resolves differently, a live
admin sandbox edit, a dropped setting, `VZS.desync`).

So the phase is now server-authoritative:

* The server resolves everything — phase, speed, toughness, XP multiplier — and broadcasts it
  with `sendServerCommand("VZS", "state", …)` whenever any of it changes.
* Clients apply it verbatim via `VZS.applyRemoteState()`. From the first packet onward
  `VZS.isFollower()` is true, and `VZS.evaluate()` returns immediately — a client never again
  consults its own clock.
* `VZS.isNightPhase()` and `VZS.currentXpMultiplier()` also return the server's values on a
  follower, so the HUD, flavour text and XP bonus agree with the server *by construction* rather
  than by re-deriving and hoping.
* A joining client sends `requestState` and gets the current state immediately, retrying every
  5 s until answered. Before the first packet it evaluates locally, so a joining player is never
  stuck on stale settings.
* The server re-broadcasts on a **real-time** heartbeat, *Server sync interval (seconds)*,
  default 10. Each `applyRemoteState` also re-asserts the sandbox option if it has drifted, which
  is what keeps the client's drift correction working now that `evaluate()` no longer runs there.

#### On the heartbeat interval

The heartbeat is a safety net, not the main path — a dusk or dawn change is broadcast
**immediately**, so the interval never affects normal play. It exists to recover a client whose
state changed behind the server's back: an admin sandbox edit, another mod, or `VZS.desync`.

PZ's Lua command channel carries gameplay-critical traffic (safehouses, farming, admin commands),
so it is reliable — dropped packets are not the failure mode being covered here.

**Default is 1 second.** The payload is five small fields — roughly 100–200 bytes per connected
client — so even at 1 s with 32 players that is a few KB/s, against PZ's continuous position and
zombie traffic which is orders of magnitude larger. An unchanged heartbeat costs the client
almost nothing either: `applyRemoteState()` compares against the live sandbox value and only
calls `applySpeed()` when it actually differs, so no refresh pass is triggered.

Note what the fast heartbeat does and does not buy. A *lagging* client is not the case it covers —
PZ's Lua command channel is reliable, so a lag spike delays delivery rather than dropping it, and
the update still lands. What 1 second genuinely helps with is a client that **reconnected**, whose
join-time `requestState` raced or failed, or whose settings were changed behind the server's back.
It is also cheap insurance against the reliability assumption above being wrong — that was
inferred from how vanilla uses the channel, not proven from the RakNet flags.

Heartbeat broadcasts are excluded from debug logging; at one per second they would otherwise bury
`console.txt`. Real state changes are always logged.

It is driven by the **real** clock deliberately. The first implementation used
`Events.EveryTenMinutes`, which is *in-game* time and therefore scales with the `DayLength`
sandbox setting — the same code would have fired every few real seconds on a short-day server and
only every several real minutes on a long-day one, making the recovery window silently depend on
an unrelated setting.

`VZS.status()` reports `following server`, packets received/sent and the age of the last sync;
`VZS.syncStatus()` on a client prints the detail.

Singleplayer is untouched — `isClient()` is false, so nothing follows anything and the local path
runs exactly as before.

### Historical: the polling fix, and how the risk was assessed

Each machine decides the phase independently from the synchronised `GameTime`, polled once per
in-game minute, so around dusk and dawn two machines can briefly hold different values for
`ZombieLore.Speed`. Because `PathFindBehavior2` derives `zombie.running` from that option locally
and never networks it, a mismatch means the two machines animate and move the *same* zombie
differently — the client predicts one speed, the server corrects it, and you get rubber-banding.

**Tested on a real dedicated server, and it is perceptible** — see the result below. The window
is now closed by polling the phase every 10 ticks in `onTick` (`PHASE_POLL_TICKS`), which
collapses the disagreement from ~2.5 real seconds to a few ticks. `EveryOneMinute` remains as the
coarse safety net and still covers season changes and external drift. That is a local fix — no
packets, no server authority — and it is enough because both machines read the same synchronised
`GameTime`; the gap was polling latency, not disagreement about the time.

#### Measured result

With `VZS.desync(1)` on a client against a live server, **every zombie in view moved at sprint
speed and genuinely closed distance faster**, while still playing the shambler animation. That
split is diagnostic:

| | Source | Networked? |
|---|---|---|
| Movement speed | `running`, from the global option, recomputed locally every pathfind tick | **No** |
| Animation | `walkType` → the `zombieWalkType` anim variable | **Yes**, in `ZombiePacket` |

So a client and server holding different values for `ZombieLore.Speed` really do move the same
zombie at different speeds. It is not a cosmetic animation mismatch.

(The animation staying put was an artefact of the test tool: `VZS.desync()` set `testDesync`,
which made `evaluate()` early-return and skip the per-zombie refresh. It now runs the refresh too,
so it faithfully reproduces a real switchover. A real dusk changes both together.)

The historical reasoning below is kept because the method generalises.

#### Test 1 — is the artefact visible at all? (do this first)

The real disagreement lasts under a minute. Rather than trying to catch that window, make it
permanent and total: if a *worst-case* mismatch is not visible, a sub-minute transient cannot be.

1. Start a local dedicated server (`ProjectZomboidServer.bat`) with the mod enabled, and connect
   a client from the same machine.
2. Confirm both loaded it — `[VZS] v0.2.0 active` appears in the server console and the client's
   `console.txt`.
3. Find a horde and let it chase you, so zombies are actively pathfinding toward a target.
4. On the **client**, run `VZS.desync(1)` (pin to Sprinters). The server stays on whatever the
   clock says. Now the two machines permanently disagree.
5. Watch the zombies. Snapping, stuttering, sliding, or positions jumping backwards means the
   fix is warranted. Smooth movement means it is not.
6. `VZS.desync(3)` to try the opposite direction, then `VZS.desync()` to release.

`VZS.desync()` suppresses the mod's own re-assertion for exactly this purpose — without it, the
drift correction added above would undo your test write within a second.

#### Test 2 — how wide is the real window?

Every switchover logs a wall-clock stamp:

```
[VZS] switched to Sprinters (nightfall, hour 19.00, role server, wallclock 1754238301422)
[VZS] switched to Sprinters (nightfall, hour 19.00, role client, wallclock 1754238303117)
```

Both machines are the same physical box in a local test, so their clocks agree and the difference
between the two stamps **is** the desync window — here 1.7 s. Grep both logs for `switched to`
across several in-game days and take the worst case.

#### Deciding

| Test 1 | Test 2 | Verdict |
|---|---|---|
| No visible artefact | any | Leave it. The transient cannot matter if the permanent case does not. |
| Visible | small (a few seconds) | Marginal. Polling `EveryTenMinutes` → `OnTick` near the boundary would shrink it cheaply. |
| Visible | large (tens of seconds) | Worth doing properly: server decides the phase and broadcasts it with `sendServerCommand`, clients apply on receipt instead of consulting their own clock. |

Survivor dialogue is client-only and each client speaks for its own survivor, so in a group
everyone mutters at once at dusk. Harmless, but noticeable.

Survivor dialogue is client-only and each client speaks for its own survivor, so in a group
everyone mutters at once at dusk. Harmless, but noticeable.

---

## Status

**v0.2.0.** Speed switching (v0.1.0) has been confirmed working in-game. Toughness, per-season
profiles and the night combat XP multiplier are new and **not yet run in-game**.

Static verification performed on every build:

* All 51 sandbox options parsed with the game's own `CustomSandboxOptions` parser.
* All 122 translation keys derived from that parsed output and diffed against `Sandbox.json` —
  zero missing, zero unused.
* The Lua fallback-defaults table diffed against the real option ids — 51 vs 51, no drift. This
  matters because profile lookups are built dynamically as `prefix .. "FieldName"`, so a typo
  would silently fall back to a hardcoded default rather than erroring.
* Every `Perks.*` name checked against `PerkFactory$Perks` in the jar.
* Every Java method the Lua calls — 17 instance methods and 9 Lua globals — checked for a
  matching overload in `projectzomboid.jar`.
* All Lua compiled with the game's own Kahlua compiler (`se.krka.kahlua.luaj.compiler`).

### Do not copy from commented-out vanilla Lua

v0.2.0 shipped one runtime error: `HaloTextHelper.addText(player, text, ColorInfo)`, which throws
`No implementation found for function: addText(...)` in 42.20. That three-argument colour overload
does not exist any more — what exists is `addText(IsoPlayer, String)`,
`addGoodText(IsoPlayer, String)`, and variants taking `HaloTextHelper$ColorRGB`.

It was copied out of `ISVehicleMenu.lua`, where the line is **commented out** — it is dead build 41
code the devs left behind. Live vanilla code (`forageClient.lua`) uses the two-argument form.

Compiling the Lua does not catch this: Kahlua resolves Java overloads at *call* time, so a bad
signature only fails when that branch actually runs. The lesson, now applied as a rule: confirm
API shapes against `javap` output from the jar, and treat vanilla Lua as evidence only when the
line is not commented out.

### `pcall` does not suppress a Java-side exception

v0.2.0 also spammed `NullPointerException: ... because "this.season" is null` from the debug HUD.
Two things combined:

1. `Events.OnPreUIDraw` fires from `MainScreenState.render` — i.e. **on the main menu**, before any
   world exists. The HUD now returns early when `getPlayer() == nil`.
2. Several climate/time accessors dereference an unset field with no null check.

The second is the trap worth remembering. Wrapping the call in `pcall` keeps *Lua* running, but
the JVM has already thrown and PZ logs the stack trace regardless — so a pcall'd bad call still
produces an error report every frame. These must be avoided, not caught.

Null-safety is inconsistent across neighbouring methods in the same class:

| Method | Behaviour when `season` is unset |
|---|---|
| `ClimateManager.getSeasonId()` | **throws NPE** — bare `getfield` then `invokevirtual` |
| `ClimateManager.getSeasonName()` | safe — `ifnull` guard, returns null |
| `ClimateManager.getSeason()` | returns null, but reads `currentDay.getSeason()` *first* |
| `GameTime.isDay()` / `isNight()` | **throws NPE** — `getSeason().getDawn()` unguarded |

So `VZS.climateReady()` guards on `getSeasonName() ~= nil`. That is exact rather than approximate:
`getSeasonName()` reads the *same* `season` field that `getSeasonId()` and `isDay()` need, just
behind a null check. Note that `getSeason() ~= nil` would **not** work as a guard — it prefers
`currentDay.getSeason()` and only falls back to the `season` field, so it can return non-null
while `season` is still null.

When the climate is not ready, `isNightPhase()` falls back to the profile's fixed hours (the
`timeOfDay` field is a plain read and always safe) and `engineActivePhase()` assumes active.

The multiplayer story is unchanged and still untested: the core runs in `shared/` on both server
and clients off the synchronised `GameTime`, while the XP module is `client/` only, which is
correct since XP is per-player and client-side.
