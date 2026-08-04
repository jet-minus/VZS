"""Generate sandbox-options.txt + Sandbox.json for Variable Zombie Speed.

Single source of truth so option ids, translation keys and enum value counts cannot drift.
"""
import json, os, sys

MOD = sys.argv[1]

opts = []   # (id, type, fields dict, label, tooltip, [value labels])


def add(oid, otype, fields, label, tooltip=None, values=None, page="VZS", vt=None):
    opts.append(dict(id=oid, type=otype, fields=fields, label=label,
                     tooltip=tooltip, values=values, page=page, vt=vt))


SPEEDS = ["Sprinters", "Fast Shamblers", "Shamblers", "Random"]
TOUGH = ["Tough", "Normal", "Fragile", "Random", "Leave unchanged"]

# ----------------------------------------------------------------- core page
add("VZS.Enable", "boolean", dict(default="true"),
    "Enable Variable Zombie Speed",
    "Master switch. When off, this mod never touches the Zombie Lore Speed or Toughness "
    "settings and vanilla behaviour applies.")

add("VZS.SeasonMode", "enum", dict(numValues=2, default=2),
    "Season handling",
    "Single profile: always use the Default Profile page. \\nPer-season profiles: use the "
    "Spring / Summer / Autumn / Winter page matching the current in-game season, falling back "
    "to the Default Profile outside the four seasons.",
    values=["Single profile", "Per-season profiles"], vt="VZS_SeasonMode")

add("VZS.TimeMode", "enum", dict(numValues=2, default=1),
    "Switchover timing",
    "Fixed hours: use each profile's Night Start / Night End hours. \\nGame dusk/dawn: ignore "
    "those hours and follow the season's own dusk and dawn, like the vanilla \\\"Day/Night "
    "Zombie Speed Effect\\\" option.",
    values=["Fixed hours", "Game dusk/dawn"], vt="VZS_TimeMode")

add("VZS.ForceActiveOnly", "boolean", dict(default="true"),
    "Override vanilla day/night effect",
    "Forces Zombie Lore > \\\"Day/Night Zombie Speed Effect\\\" to \\\"Both\\\" so the vanilla "
    "dusk/dawn slowdown does not fight this mod. \\nTurn off only if you want both systems stacked.")

add("VZS.RefreshOnSwitch", "boolean", dict(default="true"),
    "Re-roll loaded zombies on switch",
    "At each switchover, walk the loaded zombie list and re-apply the new speed to every zombie. "
    "\\nRequired for night to day: already-sprinting zombies keep sprinting otherwise.")

add("VZS.RefreshBatch", "integer", dict(min=25, max=5000, default=250),
    "Zombies re-rolled per tick",
    "How many zombies to update per game tick during a switchover. \\nLower this if you see a "
    "stutter at dusk/dawn on a high-population world.")

add("VZS.SweepEnable", "boolean", dict(default="true"),
    "Background correction sweep",
    "Continuously checks loaded zombies and fixes any whose speed does not match the current "
    "phase. \\nCatches zombies that stream in from unloaded chunks. \\nSkipped when the current "
    "phase speed is \\\"Random\\\".")

add("VZS.SweepInterval", "integer", dict(min=1, max=300, default=30),
    "Sweep interval (ticks)", "Run one sweep batch every N game ticks.")

add("VZS.SweepBatch", "integer", dict(min=10, max=2000, default=100),
    "Zombies checked per sweep", "How many zombies each sweep batch inspects.")

add("VZS.SyncInterval", "integer", dict(min=1, max=300, default=1),
    "Server sync interval (seconds)",
    "Multiplayer only. How often the server re-sends the current zombie speed state to clients, "
    "in REAL seconds. \\nA dusk or dawn change is pushed immediately regardless; this is the "
    "safety net that recovers a client which missed it, reconnected, or had its settings changed "
    "behind the server's back. \\nThe payload is a handful of numbers, so 1 second costs a few "
    "KB/s even on a full server. Raise it only if you are chasing bandwidth.")

add("VZS.Notify", "boolean", dict(default="false"),
    "Survivor comments at dusk and dawn",
    "Your character mutters an in-character line when the night window opens or closes, and when "
    "the season turns. \\nLines vary by season, by whether you are outdoors, and are darker when "
    "the coming night is a Sprinter night. \\nThis is speech-bubble text only - it makes no noise "
    "and does not attract zombies.")

add("VZS.Debug", "boolean", dict(default="false"),
    "Debug logging",
    "Verbose logging to console.txt, plus an on-screen readout of the current season, phase, "
    "target speed, XP multiplier and live zombie speed counts.")

# ------------------------------------------------------------------ XP page
add("VZS.XpEnable", "boolean", dict(default="true"),
    "Enable night combat XP bonus",
    "Multiplies XP earned *from fighting* during the night window by the active profile's "
    "Night XP Multiplier. \\nOnly XP gained within a short window after hitting a zombie is "
    "boosted, so night-time exercise, reading and crafting are unaffected.",
    page="VZS_XP")

add("VZS.XpCombatSkills", "boolean", dict(default="true"),
    "Boost weapon skills",
    "Axe, Blunt, Small Blunt, Long Blade, Small Blade, Spear, Maintenance, Aiming and Reloading.",
    page="VZS_XP")

add("VZS.XpStrength", "boolean", dict(default="true"),
    "Boost Strength", "Boost Strength XP earned from fighting at night.", page="VZS_XP")

add("VZS.XpFitness", "boolean", dict(default="true"),
    "Boost Fitness", "Boost Fitness XP earned from fighting at night.", page="VZS_XP")

add("VZS.XpWindow", "integer", dict(min=100, max=5000, default=1000),
    "Combat window (ms)",
    "How long after hitting a zombie XP still counts as combat XP. \\nRaise this if kill XP is "
    "being missed; lower it if unrelated XP is being boosted.",
    page="VZS_XP")

# ------------------------------------------------------------- profile pages
PROFILES = [
    # prefix,   page,          nightStart, nightEnd, nightSpd, daySpd, nightTough, dayTough, xp
    ("",        "VZS_Default", 19.0, 6.0,  1, 3, 5, 5, 2.0),
    ("Spring",  "VZS_Spring",  20.0, 6.0,  1, 3, 5, 5, 2.0),
    ("Summer",  "VZS_Summer",  21.0, 5.5,  1, 3, 5, 5, 2.0),
    ("Autumn",  "VZS_Autumn",  19.0, 6.5,  1, 3, 5, 5, 2.0),
    ("Winter",  "VZS_Winter",  17.0, 7.5,  1, 3, 1, 5, 2.5),
]

for prefix, page, ns, ne, nspd, dspd, ntough, dtough, xp in PROFILES:
    who = prefix or "Default"
    add(f"VZS.{prefix}NightStart", "double", dict(min=0.0, max=24.0, default=ns),
        "Night starts at (hour)",
        f"In-game hour when zombies switch to their night speed in {who}. 24-hour clock, "
        "fractions allowed (19.5 = 19:30). \\nOnly used with \\\"Fixed hours\\\" timing.", page=page)

    add(f"VZS.{prefix}NightEnd", "double", dict(min=0.0, max=24.0, default=ne),
        "Night ends at (hour)",
        f"In-game hour when zombies switch back to their day speed in {who}. \\nMay be earlier "
        "than Night Start; the window wraps over midnight. \\nOnly used with \\\"Fixed hours\\\" "
        "timing.", page=page)

    add(f"VZS.{prefix}NightSpeed", "enum", dict(numValues=4, default=nspd),
        "Night speed", f"Zombie speed inside the {who} night window.",
        values=SPEEDS, vt="VZS_Speed", page=page)

    add(f"VZS.{prefix}DaySpeed", "enum", dict(numValues=4, default=dspd),
        "Day speed", f"Zombie speed outside the {who} night window.",
        values=SPEEDS, vt="VZS_Speed", page=page)

    add(f"VZS.{prefix}NightToughness", "enum", dict(numValues=5, default=ntough),
        "Night toughness",
        "Zombie Lore > Toughness used inside the night window. Tough zombies are harder to kill "
        "(-6 crit chance), Fragile easier (+6). \\n\\\"Leave unchanged\\\" restores whatever "
        "Toughness the world was created with.",
        values=TOUGH, vt="VZS_Toughness", page=page)

    add(f"VZS.{prefix}DayToughness", "enum", dict(numValues=5, default=dtough),
        "Day toughness", "Zombie Lore > Toughness used outside the night window.",
        values=TOUGH, vt="VZS_Toughness", page=page)

    add(f"VZS.{prefix}NightXp", "double", dict(min=1.0, max=10.0, default=xp),
        "Night combat XP multiplier",
        f"Multiplier applied to XP earned from fighting during the {who} night window. "
        "1.0 disables the bonus.", page=page)

# ------------------------------------------------------------------- emit
PAGE_TITLES = {
    "VZS":         "Variable Zombie Speed",
    "VZS_XP":      "Variable Zombie Speed | Night XP",
    "VZS_Default": "Variable Zombie Speed | Default Profile",
    "VZS_Spring":  "Variable Zombie Speed | Spring",
    "VZS_Summer":  "Variable Zombie Speed | Summer",
    "VZS_Autumn":  "Variable Zombie Speed | Autumn",
    "VZS_Winter":  "Variable Zombie Speed | Winter",
}

lines = ["VERSION = 1,", ""]
tr = {}
for page, title in PAGE_TITLES.items():
    tr[f"Sandbox_{page}"] = title

for o in opts:
    # translation token = option id minus the "VZS." table prefix, namespaced
    token = "VZS_" + o["id"].split(".", 1)[1]
    body = [f"type = {o['type']}"]
    for k in ("min", "max", "default", "numValues"):
        if k in o["fields"]:
            body.append(f"{k} = {o['fields'][k]}")
    body.append(f"page = {o['page']}")
    body.append(f"translation = {token}")
    if o["values"]:
        body.append(f"valueTranslation = {o['vt']}")
    lines.append(f"option {o['id']} = {{")
    lines.append("\t" + ", ".join(body) + ",")
    lines.append("}")
    lines.append("")

    tr[f"Sandbox_{token}"] = o["label"]
    if o["tooltip"]:
        tr[f"Sandbox_{token}_tooltip"] = o["tooltip"]
    if o["values"]:
        for i, v in enumerate(o["values"], 1):
            tr[f"Sandbox_{o['vt']}_option{i}"] = v

sandbox_path = os.path.join(MOD, "media", "sandbox-options.txt")
json_path = os.path.join(MOD, "media", "lua", "shared", "Translate", "EN", "Sandbox.json")

with open(sandbox_path, "w", encoding="utf-8", newline="\n") as f:
    f.write("\n".join(lines).rstrip() + "\n")

# tooltips already contain \\n / \" escapes meant to survive into the file verbatim,
# so emit them raw rather than letting json.dumps double-escape.
with open(json_path, "w", encoding="utf-8", newline="\n") as f:
    f.write("{\n")
    items = list(tr.items())
    for i, (k, v) in enumerate(items):
        comma = "," if i < len(items) - 1 else ""
        # Vanilla Sandbox.json stores a line break as the three chars \\n, which JSON-decodes
        # to the literal two-char sequence \n that PZ's Translator turns into a break.
        # A bare \n would decode to a real newline, which the text renderer does not break on.
        v = v.replace("\\n", "\\\\n")
        f.write(f'    "{k}": "{v}"{comma}\n')
    f.write("}\n")

print(f"wrote {len(opts)} options, {len(tr)} translation keys")
