# Discoveries

Why this mod is built the way it is.

Build 42 changed enough that most advice about zombie speed — including advice from build 41 mods
that still ship today — is wrong. Everything below was verified against `projectzomboid.jar` for
**42.20** with `javap`, not taken from documentation or existing mods. Where a claim can be
checked, the class and method are named so you can check it yourself.

---

## 1. Zombie speed

### The method most guides point at is dead code

`IsoZombie.getZombieWalkTowardSpeed()` looks authoritative. It reads the sandbox Speed option,
applies `speedMod`, and hard-sets sprint velocity. It is also **never called** — it appears
exactly once in `IsoZombie`'s bytecode, its own declaration, and nothing in the jar invokes it.

The live path is `PathFindBehavior2`, which does this in *both* `update()` and `moveToPoint()`:

```java
zombie.running = false;
if (SandboxOptions.instance.lore.speed.getValue() == 1) zombie.running = true;
```

Three properties of that line drive most of this mod's design:

- **`running` comes only from the global option.** A zombie's own `speedType` plays no part.
  Setting one zombie's `speedType` to 1 does *not* make it run.
- **It is recomputed locally on every machine**, every pathfind tick, for every zombie including
  remote ones.
- **It is never networked.** There is no `running` field in `ZombiePacket`.

### Speed and animation are separate systems

| | Source | Networked? |
|---|---|---|
| Movement speed | `running`, from the global option | **No** |
| Animation | `walkType` → the `zombieWalkType` anim variable | **Yes**, in `ZombiePacket` |

`walkType` selects an AnimSet — `sprintPathfind1.xml` → `Zombie_Sprint`, `pathfind1.xml` →
`Zombie_Walk` with `<m_SpeedScale>0.92</m_SpeedScale>`, `zombieWalkSlow1.xml` → a slow variant.
Movement magnitude in `PathFindBehavior2.update()` comes from the animation vector, so the chosen
animation *is* the speed, via root motion.

This split is directly observable: force the global option on a client only, and zombies move at
the new speed while still playing the old animation.

### Why per-zombie changes alone do not work

`IsoZombie.doZombieSpeedInternal` is:

```java
n = determineZombieSpeed(n);                       // -1 means "read the sandbox option"
if (crawling)                          doCrawlerSpeed(n);
else if (sandboxSpeed == 3 || n == 3)  doShambler();          // <-- short-circuit
else if (Rand.Next(3) != 0)            doFakeShambler(n);
else if (sandboxSpeed == 2 || n == 2)  doFastShambler();
else if (sandboxSpeed == 1 || n == 1)  doSprinter();
```

If the world's `ZombieLore.Speed` is *Shamblers*, `doZombieSpeed(1)` still calls `doShambler()`.
Any mod that promotes individual zombies while the global stays put has its work discarded. This
is the most likely reason existing night-sprinter mods fail on this build.

### So the mod does both halves

1. Write the new value into the global `ZombieLore.Speed`.
   *Required for night → day*: without it `running` stays true and zombies never slow down.
2. Walk the loaded zombie list calling `doZombieSpeed(-1)` to re-derive each zombie from the
   now-updated global.
   *Required for day → night*: without it zombies keep the `walkType` and `speedMod` they were
   assigned at spawn, so the animation never changes.

A `setWalkType` fallback exists for when `doZombieSpeed(-1)` does not produce the requested
speed. `getSpeedTypeFromWalkType()` maps `"sprint*"` → 1, `"slow*"` → 3, anything else → 2, and
those strings match the networked `NetworkVariables$WalkType` enum (`WT1-5`, `WTSprint1-5`,
`WTSlow1-3`) — so the fallback produces network-legal values.

### Vanilla already has a night/day system

`ZombieLore.ActiveOnly` ("Day/Night Zombie Speed Effect") pins zombies to `speedType = 3` outside
its active phase:

```java
boolean isZombieActivityPhase() {
    if (activeOnly == 1) return true;
    if (activeOnly == 2 && isNight()) return true;
    if (activeOnly == 3 && isDay())   return true;
    return false;
}
```

`IsoZombie.updateInternal()` calls `updateActiveState()` → `makeInactive(...)` every tick. The
switchover times come from the season's dusk and dawn and are not configurable, which is the gap
this mod fills. The mod forces `ActiveOnly` to *Both* by default so the two systems do not fight.

### A vanilla quirk worth knowing

`doZombieSpeedInternal` sends `Rand.Next(3) != 0` — two thirds — of zombies down
`doFakeShambler`, which assigns `speedMod = 0.55` (shambler pace) while still setting the
requested `speedType`. This is vanilla behaviour. It is invisible for *Sprinters* but means
*Fast Shamblers* is genuinely a mixed-pace population.

---

## 2. Toughness works cleanly; Strength cannot

**Toughness** is read live on every hit, in `IsoPlayer.calculateCritChance()`:

```java
if (target instanceof IsoZombie) {
    if (lore.toughness.getValue() == 1) crit -= 6.0f;   // Tough
    if (lore.toughness.getValue() == 3) crit += 6.0f;   // Fragile
}
```

Nothing is cached per zombie, so writing the global option takes effect immediately for every
zombie with no refresh pass.

**Strength is deliberately not exposed**, for two reasons:

1. It does not do what the name suggests. The only classes reading `IsoZombie.strength` are
   `IsoBarricade`, `IsoDoor`, `IsoWindow` and `AttackVehicleState` — it governs how fast zombies
   break through barricades, doors, windows and vehicles. It has no effect on damage dealt to
   the player.
2. It cannot be changed on existing zombies from Lua. `strength` is a per-zombie int that
   `DoZombieStats()` only re-derives when it equals `-1`; there is no `setStrength()`; and
   Kahlua's `LuaJavaClassExposer` binds `java.lang.reflect.Method` objects only, with no field
   handling at all — so `zombie.strength = -1` from Lua just writes an ignored Lua property.

A Strength option would therefore have silently applied only to zombies spawned after the
switchover, which is worse than not having it.

---

## 3. XP is a no-op on a multiplayer client

All three Lua XP globals share this shape:

```java
if (GameServer.server) { GameServer.addXp(...); }
if (GameClient.client) return;          // <-- client does nothing at all
player.getXp().AddXP(...);              // singleplayer only
```

`addXpNoMultiplier()`, `addXp()` and `addXpMultiplier()` all return early on a client. No error,
no log — the XP simply never lands. Any client-side XP mod is silently broken in multiplayer.

The fix is a client → server command: the client detects the gain (`OnHitZombie` and
`OnPlayerUpdate` both fire client-side) and sends the computed bonus; the server pays it out.

### Why not `addXpMultiplier()`

`IsoGameCharacter.XP.addXpMultiplier(perk, mult, minLvl, maxLvl)` writes a single `XPMultiplier`
per perk into `xpMapMultiplier` — the same map the skill-book system uses. It replaces rather
than stacks, which is convenient, but it applies to *every* XP gain for that perk regardless of
source, and it would clobber a book's multiplier. It cannot express "only XP from fighting".

### Measuring instead

The mod watches each tracked perk's cumulative XP and tops up gains that occur inside a short
window after `OnHitZombie`. `getXP(perk)` is cumulative — it is compared internally against
`Perk.getTotalXpForLevel(n)` — so it never resets on level-up and deltas are always positive.

The subtle part is that a multiplayer grant is **asynchronous**. Re-reading `getXP()` after
granting works in singleplayer but not over a round-trip: the bonus lands several ticks later,
gets read as fresh combat XP, and is boosted again, compounding without limit. So the module
tracks a **pending credit** per perk — a bonus is remembered when requested and the matching
later gain is absorbed rather than re-boosted. Credit that never arrives within 15 seconds is
discarded so a rejected grant cannot mask real XP forever. The same accounting runs in
singleplayer, so there is no special case.

---

## 4. Multiplayer: agreement has to be structural

### Zombies are owned by clients

`IsoZombie` has `getOwner()` returning a `UdpConnection`, plus `isRemoteZombie()` and
`getOwnerPlayer()`. PZ hands zombie authority to the nearest player, and the server accepts the
owner's positions.

`ZombiePacket` carries `walkType` and `speedMod`, and `NetworkZombieAI` applies them on receipt
via `setWalkType()` + `setSpeedTypeFromWalkType()`. So writing a speed to a zombie owned by
another machine is overwritten by their next packet — the sweep would fight the network forever
and never converge. `VZS.ownsZombie()` filters both the refresh and the sweep.

### The consequence that forced server authority

Because `running` is derived locally from each machine's own copy of `ZombieLore.Speed`, **and**
zombies near a client are owned by that client, a client that disagrees about the phase does not
merely render zombies wrongly — it moves them wrongly *for everyone*.

This was confirmed on a live server: pinning a client to Sprinters made every zombie in view
genuinely close distance faster, and the server did **not** correct it.

Faster polling shrank the dusk/dawn window but could never make agreement a guarantee. Two
machines independently reaching the same answer from a shared clock is a coincidence, and
coincidences have edge cases — a client whose season resolves differently, a live admin sandbox
edit, a dropped setting. So the server now resolves phase, speed, toughness and XP multiplier and
broadcasts them; clients apply verbatim and stop consulting their own clock.

`isNightPhase()` and `currentXpMultiplier()` also return the server's values on a follower. Without
that, the HUD, flavour text and XP bonus would each re-derive the phase locally and reintroduce
disagreement through the back door.

### Heartbeat on the real clock

The first implementation used `Events.EveryTenMinutes`, which is *in-game* time and therefore
scales with the `DayLength` sandbox setting — the same code fires every few real seconds on a
short-day server and only every several real minutes on a long-day one, making the recovery
window silently depend on an unrelated setting. It is now driven by `getTimestampMs()`.

The heartbeat is only a safety net; a real switchover is broadcast immediately. PZ's Lua command
channel carries gameplay-critical traffic (safehouses, farming, admin commands), so it is
reliable and dropped packets are not the failure mode being covered. What the heartbeat recovers
is a client that reconnected, whose join-time request raced, or whose settings changed behind the
server's back.

---

## 5. Packaging

### Build 42 will not see a build 41 mod layout

`ZomboidFileSystem.getAllModFoldersAux()` decides what counts as a mod:

```java
String versionDirName = getModVersionDirName(path);
if (!Files.exists(path.resolve("common",       "mod.info"))
 && !Files.exists(path.resolve(versionDirName, "mod.info"))) {
    continue;                                          // not a mod, skipped
}
```

There is **no check for `mod.info` at the folder root**. The build 41 layout is never seen, the
mod does not appear in the Mods menu, and nothing is logged at the default log level.
`mod.info` and `media/` must live in `common/` or a version folder such as `42.20/`.
`getModVersionDirName()` picks the highest-numbered version folder `<=` the running build.

Workshop mods that also keep a root `mod.info` are carrying vestigial B41 compatibility; that
file is not what 42.x reads.

### Translations are JSON now

`Translator.loadFiles()` walks a fixed registry (`Translator$1`, 30 entries including `Sandbox`)
and loads exactly:

```
<dir>/media/lua/shared/Translate/<LANG>/<Name>.json
```

`tryFillMapFromMods()` runs the same lookup against each mod's common and version dirs. **No code
path reads `Sandbox_EN.txt` any more** — the B41 Lua-table translation format is dead, which is
why some current workshop mods show raw keys for their own options.

Keys are built by string concatenation, read from the `BootstrapMethods` recipes in
`SandboxOptions$EnumSandboxOption`:

| What | Key |
|---|---|
| Option label | `Sandbox_<translation>` |
| Option tooltip | `Sandbox_<translation>_tooltip` |
| Enum value | `Sandbox_<valueTranslation>_option<N>` |
| Page heading | `Sandbox_<page>` |

A line break inside a tooltip is written `\\n` in the JSON source: that decodes to the literal
two-character sequence `\n`, which the game then converts. A real JSON newline does not render.

### `sandbox-options.txt` has no line comments

`CustomSandboxOptions.readFile()` concatenates the file's lines with **no separator** before
parsing, so a single `--` comment would comment out the entire rest of the file.

---

## 6. Pitfalls that cost time

### Vanilla Lua is only evidence when it is not commented out

`HaloTextHelper.addText(player, text, ColorInfo)` throws
`No implementation found for function: addText(...)` on 42.20. That three-argument colour overload
no longer exists. It was copied from `ISVehicleMenu.lua`, where the line is **commented out** —
dead build 41 code. Live vanilla code uses the two-argument form.

Compiling the Lua does not catch this: Kahlua resolves Java overloads at *call* time, so a bad
signature only fails when that branch actually runs.

### `pcall` does not suppress a Java-side exception

Wrapping a call in `pcall` keeps Lua running, but the JVM has already thrown and PZ logs the
stack trace regardless — a pcall'd bad call still produces an error report every frame. These
must be avoided, not caught.

### Null-safety is inconsistent between neighbouring methods

| Method | When `season` is unset |
|---|---|
| `ClimateManager.getSeasonId()` | **throws NPE** — bare `getfield` then `invokevirtual` |
| `ClimateManager.getSeasonName()` | safe — `ifnull` guard, returns null |
| `ClimateManager.getSeason()` | returns null, but reads `currentDay.getSeason()` *first* |
| `GameTime.isDay()` / `isNight()` | **throws NPE** — `getSeason().getDawn()` unguarded |

`VZS.climateReady()` guards on `getSeasonName() ~= nil`, which is exact rather than approximate:
it reads the *same* `season` field the throwing methods need, just behind a null check. Note that
`getSeason() ~= nil` would **not** work as a guard — it prefers `currentDay.getSeason()` and only
falls back to the field, so it can return non-null while `season` is still null.

This matters because `Events.OnPreUIDraw` also fires from `MainScreenState.render` — on the main
menu, before any world exists.

### Empty method stubs

`IsoGameCharacter.XP.AddXP(HandWeapon, int)` compiles to `0: return`. Verifying that a method
*exists* is not the same as verifying it does anything.

---

## 7. How this was verified

The game ships the tools to check a mod without launching it.

- **Lua syntax** — `se.krka.kahlua.luaj.compiler.LuaCompiler.loadis()` from `projectzomboid.jar`
  is the exact compiler the game uses. Every file is compiled before shipping.
- **Sandbox options** — `zombie.sandbox.CustomSandboxOptions.parse()` invoked reflectively over
  `sandbox-options.txt` reports the options the game will actually register, with their parsed
  types, bounds and translation tokens.
- **Translation keys** — derived from that parser's output and diffed against `Sandbox.json`, so
  missing and unused keys are both caught.
- **Lua fallback defaults** — diffed against the real option ids. This one earns its keep: profile
  lookups are built dynamically as `prefix .. "FieldName"`, so a typo would silently fall back to
  a hardcoded default rather than erroring.
- **Java API shapes** — every method the Lua calls is checked for a matching overload with
  `javap` before use.

`tools_gen_options.py` generates `sandbox-options.txt` and `Sandbox.json` from one source so the
option ids and their translation keys cannot drift apart.

---

## 8. Testing multiplayer desync

`VZS.desync(n)` pins a machine to a chosen speed and suppresses the mod's own re-assertion. The
real disagreement window lasts under a second; this makes it permanent and total, so a
worst-case artefact can be observed deliberately rather than waited for.

Two supporting measurements:

- Every switchover logs `role` and a wall-clock stamp. On two machines with agreeing clocks, the
  difference between their `switched to` lines *is* the desync window.
- `VZS.status()` reports packets sent and received, the age of the last sync, and how many
  zombies were skipped as remote.

The relevant result: a forced desync was **not** corrected by the server, which is what
established that client disagreement changes zombie speed for everyone and that server authority
was required rather than merely tidy.
