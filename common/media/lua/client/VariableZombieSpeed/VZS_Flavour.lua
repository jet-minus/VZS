--[[
	Variable Zombie Speed - in-character flavour text.

	Instead of announcing the mechanic ("Zombies: Sprinters"), the survivor mutters something
	when the phase turns. IsoGameCharacter.Say(String) puts a speech bubble over the character
	and passes false for the noise flag internally, so it does not attract zombies.

	Lines are picked from: a generic pool for the transition, plus a season-specific pool, plus
	an extra-ominous pool when the coming night is a Sprinter night. Lines that reference seeing
	the sky are kept in a separate `outdoor` pool and only used when the player is outside.

	To customise, just edit the tables below - they are plain strings on purpose.
]]

require "VariableZombieSpeed/VZS_Core"

VZS.flavour = VZS.flavour or {}

VZS.flavour.lines = {

	nightfall = {
		"The light's going. I should be somewhere with a door.",
		"Why is the air getting colder...?",
		"It's too quiet out here.",
		"I should have been back an hour ago.",
		"Sun's going down. Nothing good happens after that.",
		"Something feels off about tonight.",
		"I can hear them moving already.",
		"Just get through the night. That's all.",
	},

	nightfallOutdoor = {
		"Looks like a full moon tonight.",
		"Are those wolves, or...?",
		"Nothing but dark between here and home.",
		"The shadows are getting long.",
		"Not a light on anywhere.",
	},

	-- Layered on top when the coming night is a Sprinter night.
	nightfallSprinters = {
		"They sound... faster after dark. That can't be right.",
		"Something changes in them at night. I've seen it.",
		"Whatever's out there tonight, I can't outrun it.",
		"God, please let me be imagining that.",
	},

	daybreak = {
		"Sun's coming up. I made it.",
		"Another one down.",
		"Whatever that was, it's over. For now.",
		"Daylight. Finally.",
		"They've settled again. Like nothing happened.",
		"I need to sleep. I'm not going to.",
	},

	daybreakOutdoor = {
		"First light. The air feels warmer already.",
		"Sky's going grey. Time to move.",
	},

	season = {
		"The season's turning. I can feel it.",
		"Weather's changing.",
		"Days don't feel the same length anymore.",
	},

	-- Season-specific pools, keyed by the profile prefix from VZS_Core.
	bySeason = {
		Winter = {
			nightfall = {
				"Dark comes early this time of year.",
				"The cold gets into your bones out here.",
				"I can see my breath. I need to move.",
				"Long night ahead. Longest yet.",
			},
			daybreak = {
				"Made it. Cold nearly did what they couldn't.",
				"Sun's up, for what little warmth it gives.",
			},
		},
		Summer = {
			nightfall = {
				"Still warm out. Doesn't make it any safer.",
				"Short night, at least. Small mercy.",
			},
			daybreak = {
				"Light already. That went quick.",
				"Going to be another hot one.",
			},
		},
		Spring = {
			nightfall = {
				"Something's stirring out there.",
				"The nights still bite this time of year.",
			},
			daybreak = {
				"Everything's growing again. Doesn't care what happened.",
			},
		},
		Autumn = {
			nightfall = {
				"Leaves are turning. Nights are getting longer.",
				"The dark comes sooner every day.",
			},
			daybreak = {
				"Frost on the grass. Winter's coming.",
			},
		},
	},
}

local memory = { last = nil }

--- Random pick that avoids repeating the previous line.
local function pick(pool)
	local count = #pool
	if count == 0 then return nil end
	if count == 1 then return pool[1] end

	local choice
	for _ = 1, 6 do
		choice = pool[ZombRand(count) + 1]
		if choice ~= memory.last then break end
	end
	memory.last = choice
	return choice
end

local function append(target, source)
	if not source then return end
	for i = 1, #source do
		target[#target + 1] = source[i]
	end
end

--- Build the candidate pool for this transition.
local function poolFor(kind, profile, outside)
	local lines = VZS.flavour.lines
	local pool  = {}

	if kind == "season" then
		append(pool, lines.season)
		return pool
	end

	append(pool, lines[kind])
	if outside then
		append(pool, lines[kind .. "Outdoor"])
	end

	local seasonal = profile and profile.prefix and lines.bySeason[profile.prefix]
	if seasonal then
		append(pool, seasonal[kind])
	end

	if kind == "nightfall" and profile and profile.nightSpeed == VZS.SPRINTER then
		append(pool, lines.nightfallSprinters)
	end

	return pool
end

--- Called by VZS_Core on a phase or season change. `kind` is "nightfall", "daybreak" or "season".
function VZS.flavour.say(kind, profile)
	local player = getSpecificPlayer(0)
	if not player then return end

	local okState, skip = pcall(function()
		return player:isDead() or player:isAsleep()
	end)
	if not okState or skip then return end

	local outside = false
	pcall(function() outside = player:isOutside() end)

	local line = pick(poolFor(kind, profile, outside))
	if not line then return end

	local ok, err = pcall(function() player:Say(line) end)
	if not ok then
		VZS.state.notifyBroken = true
		VZS.state.lastError = tostring(err)
		VZS.log("WARNING: player:Say failed (" .. tostring(err) ..
			"); flavour text disabled for this session")
		return
	end

	VZS.debugLog("flavour (" .. tostring(kind) .. ", outside " .. tostring(outside) ..
		"): " .. line)
end

--- Preview a line without waiting for dusk: VZS.flavour.test("nightfall")
function VZS.flavour.test(kind)
	VZS.flavour.say(kind or "nightfall", VZS.profile())
end
