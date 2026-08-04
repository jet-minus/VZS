--[[
	Variable Zombie Speed - core logic (build 42.20)

	How zombie speed actually works in 42.20 (verified against IsoZombie / GameTime bytecode):

	  * Every zombie has an int `speedType`: 1 = sprinter, 2 = fast shambler, 3 = shambler.
	  * IsoZombie.getZombieWalkTowardSpeed() decides sprinting with:
	        if ((SandboxOptions.lore.speed == 1 && !inactive) || speedType == 1) -> full sprint
	    ...so the *global* sandbox Speed option is read live, every tick, by every zombie.
	  * Otherwise the walk vector is scaled by the per-zombie `speedMod`
	    (0.85 fast shambler, 0.55 shambler, 0.3 crawler), which is only assigned when
	    doZombieSpeed()/DoZombieStats() runs.
	  * IsoZombie.doZombieSpeed(n) re-derives the speed. Passing -1 means "read the current
	    sandbox Speed option"; passing 1..4 is only partly honoured, because
	    doZombieSpeedInternal short-circuits to doShambler() whenever the *global* option is 3.

	Therefore this mod drives the global `ZombieLore.Speed` option and then re-derives every
	loaded zombie from it. Both halves are needed:
	    global only   -> night->day switch fails (zombies keep speedType == 1 and sprint on)
	    per-zombie    -> day->night switch fails when global is 3 (short-circuit above)

	Toughness is much simpler: IsoPlayer.calculateCritChance() reads
	SandboxOptions.lore.toughness live on every hit (1 = Tough, -6 crit chance; 3 = Fragile,
	+6), so writing the global option alone takes effect immediately for every zombie.

	Zombie *Strength* is deliberately not touched. It is a per-zombie int only re-derived in
	DoZombieStats() when it equals -1, it has no public setter, and Kahlua's exposer binds
	methods rather than fields - so it cannot be changed on already-spawned zombies from Lua.
	It also only drives barricade/door/window/vehicle thumping, not damage dealt to the player.
]]

-- Guard against a second execution (this file is picked up by the automatic loader and is also
-- require()d by the client modules); re-running would double-register event handlers.
if VZS and VZS.__loaded then return end

VZS = VZS or {}
VZS.__loaded = true

VZS.VERSION = "0.2.0"

VZS.SPRINTER      = 1
VZS.FAST_SHAMBLER = 2
VZS.SHAMBLER      = 3
VZS.RANDOM        = 4

VZS.SPEED_NAMES = {
	[1] = "Sprinters",
	[2] = "Fast Shamblers",
	[3] = "Shamblers",
	[4] = "Random",
}

VZS.TOUGH_UNCHANGED = 5
VZS.TOUGH_NAMES = {
	[1] = "Tough",
	[2] = "Normal",
	[3] = "Fragile",
	[4] = "Random",
	[5] = "Leave unchanged",
}

local VANILLA_SPEED_OPTION  = "ZombieLore.Speed"
local VANILLA_TOUGH_OPTION  = "ZombieLore.Toughness"
local VANILLA_ACTIVE_OPTION = "ZombieLore.ActiveOnly"

local MOD_DATA_KEY = "VariableZombieSpeed"

-- ErosionSeason.SEASON_*  ->  sandbox option prefix ("" is the Default profile).
-- SUMMER2 (late/dry summer) shares the Summer profile.
local SEASON_PREFIX = {
	[0] = "",        -- SEASON_DEFAULT
	[1] = "Spring",
	[2] = "Summer",
	[3] = "Summer",  -- SEASON_SUMMER2
	[4] = "Autumn",
	[5] = "Winter",
}

local CORE_DEFAULTS = {
	Enable          = true,
	SeasonMode      = 2,
	TimeMode        = 1,
	ForceActiveOnly = true,
	RefreshOnSwitch = true,
	RefreshBatch    = 250,
	SweepEnable     = true,
	SweepInterval   = 30,
	SweepBatch      = 100,
	SyncInterval    = 1,
	Notify          = false,
	Debug           = false,
	XpEnable        = true,
	XpCombatSkills  = true,
	XpStrength      = true,
	XpFitness       = true,
	XpWindow        = 1000,
}

local PROFILE_DEFAULTS = {
	[""]   = { NightStart = 19.0, NightEnd = 6.0, NightSpeed = 1, DaySpeed = 3, NightToughness = 5, DayToughness = 5, NightXp = 2.0 },
	Spring = { NightStart = 20.0, NightEnd = 6.0, NightSpeed = 1, DaySpeed = 3, NightToughness = 5, DayToughness = 5, NightXp = 2.0 },
	Summer = { NightStart = 21.0, NightEnd = 5.5, NightSpeed = 1, DaySpeed = 3, NightToughness = 5, DayToughness = 5, NightXp = 2.0 },
	Autumn = { NightStart = 19.0, NightEnd = 6.5, NightSpeed = 1, DaySpeed = 3, NightToughness = 5, DayToughness = 5, NightXp = 2.0 },
	Winter = { NightStart = 17.0, NightEnd = 7.5, NightSpeed = 1, DaySpeed = 3, NightToughness = 1, DayToughness = 5, NightXp = 2.5 },
}

local DEFAULTS = {}
for name, value in pairs(CORE_DEFAULTS) do
	DEFAULTS[name] = value
end
for prefix, fields in pairs(PROFILE_DEFAULTS) do
	for name, value in pairs(fields) do
		DEFAULTS[prefix .. name] = value
	end
end

VZS.state = {
	appliedSpeed     = nil,   -- last value written to ZombieLore.Speed
	appliedToughness = nil,   -- last value written to ZombieLore.Toughness
	night            = nil,
	profilePrefix    = nil,
	override         = nil,   -- "night" / "day" / nil, from the debug console
	refreshing       = false,
	refreshCursor    = 0,
	refreshTouched   = 0,
	sweepCursor      = 0,
	tick             = 0,
	lastError        = nil,
	fallbackCount    = 0,
	started          = false,
}

-- ---------------------------------------------------------------- utilities

function VZS.log(msg)
	print("[VZS] " .. tostring(msg))
end

function VZS.debugLog(msg)
	if VZS.opt("Debug") then
		VZS.log(msg)
	end
end

local function warnOnce(key, msg)
	VZS.state.warned = VZS.state.warned or {}
	if not VZS.state.warned[key] then
		VZS.state.warned[key] = true
		VZS.log("WARNING: " .. msg)
	end
end

--- Read one of this mod's sandbox options, with a hardcoded fallback so the mod still
--- functions if sandbox-options.txt failed to parse.
function VZS.opt(name)
	local sv = SandboxVars and SandboxVars.VZS
	if sv ~= nil and sv[name] ~= nil then
		return sv[name]
	end
	local so = getSandboxOptions()
	if so then
		local option = so:getOptionByName("VZS." .. name)
		if option then
			local ok, value = pcall(function() return option:getValue() end)
			if ok and value ~= nil then
				return value
			end
		end
	end
	warnOnce("opt_" .. name, "sandbox option VZS." .. name .. " is unreadable, using default")
	return DEFAULTS[name]
end

local function readVanilla(optionName)
	local so = getSandboxOptions()
	if not so then return nil end
	local option = so:getOptionByName(optionName)
	if not option then return nil end
	local ok, value = pcall(function() return option:getValue() end)
	if ok then return value end
	return nil
end

local function writeVanilla(optionName, value)
	local so = getSandboxOptions()
	if not so then return false, "getSandboxOptions() returned nil" end
	local option = so:getOptionByName(optionName)
	if not option then return false, optionName .. " not found" end
	local ok, err = pcall(function() option:setValue(value) end)
	if not ok then return false, tostring(err) end
	return true
end

local function modData()
	local ok, md = pcall(function() return ModData.getOrCreate(MOD_DATA_KEY) end)
	if ok and md then return md end
	return nil
end

-- ------------------------------------------------------------ season/profile

--- Is the climate model far enough along that the season can be read?
---
--- ClimateManager.getSeasonId() dereferences its `season` field with no null check, so calling
--- it before a world is loaded throws NPE from Java - and a Lua pcall does not stop the game
--- logging that. getSeasonName() reads the *same* field behind an `ifnull` guard and returns
--- null instead, so a non-nil name is an exact, safe proxy for "getSeasonId() will not throw".
---
--- Note that ClimateManager.getSeason() is NOT a valid guard: it prefers
--- currentDay.getSeason() and only falls back to the `season` field, so it can return non-null
--- while `season` is still null.
local function seasonReady(climate)
	if not climate then return false end
	local ok, name = pcall(function() return climate:getSeasonName() end)
	return ok and name ~= nil, name
end

--- Sandbox option prefix for the active profile. "" is the Default profile.
function VZS.currentProfilePrefix()
	if VZS.opt("SeasonMode") ~= 2 then return "" end
	local climate = getClimateManager()
	if not seasonReady(climate) then return "" end
	local ok, id = pcall(function() return climate:getSeasonId() end)
	if not ok or id == nil then return "" end
	return SEASON_PREFIX[id] or ""
end

function VZS.seasonName()
	local ready, name = seasonReady(getClimateManager())
	if ready and name then return tostring(name) end
	return "?"
end

--- Safe to call the season-dependent parts of the climate/time API?
---
--- GameTime.isDay() does ClimateManager.getInstance().getSeason().getDawn() with no null check
--- either, so isNight()/isDay() carry the same NPE risk as getSeasonId(). seasonReady() proves
--- the `season` field is set, which makes getSeason() non-null too, so it covers both.
function VZS.climateReady()
	return (seasonReady(getClimateManager()))
end

--- GameTime:isNight() behind that guard. Returns nil when it cannot be answered safely.
function VZS.gameIsNight()
	local gt = getGameTime()
	if not gt or not VZS.climateReady() then return nil end
	local ok, night = pcall(function() return gt:isNight() end)
	if ok then return night end
	return nil
end

--- Resolve the active profile's settings.
function VZS.profile()
	local prefix = VZS.currentProfilePrefix()
	return {
		prefix         = prefix,
		label          = (prefix == "" and "Default" or prefix),
		nightStart     = VZS.opt(prefix .. "NightStart"),
		nightEnd       = VZS.opt(prefix .. "NightEnd"),
		nightSpeed     = VZS.opt(prefix .. "NightSpeed"),
		daySpeed       = VZS.opt(prefix .. "DaySpeed"),
		nightToughness = VZS.opt(prefix .. "NightToughness"),
		dayToughness   = VZS.opt(prefix .. "DayToughness"),
		nightXp        = VZS.opt(prefix .. "NightXp"),
	}
end

-- ------------------------------------------------------------------- timing

--- True if `hour` falls inside [from, to), handling windows that wrap past midnight.
function VZS.hourInWindow(hour, from, to)
	if from == to then return false end
	if from < to then
		return hour >= from and hour < to
	end
	return hour >= from or hour < to
end

function VZS.currentHour()
	local gt = getGameTime()
	if not gt then return nil end
	return gt:getTimeOfDay()
end

--- Is this machine taking its orders from the server rather than its own clock?
function VZS.isFollower()
	return isClient() and VZS.state.remoteApplied == true
end

--- Which phase are we in right now? `profile` is optional and avoids a re-resolve.
function VZS.isNightPhase(profile)
	if VZS.state.override == "night" then return true end
	if VZS.state.override == "day" then return false end

	-- A multiplayer client reports the server's phase, not its own reading of the clock.
	-- Anything downstream of this - the XP multiplier, the HUD, flavour text - then agrees
	-- with the server by construction instead of by coincidence.
	if VZS.isFollower() and VZS.state.night ~= nil then
		return VZS.state.night
	end

	local gt = getGameTime()
	if not gt then return false end

	if VZS.opt("TimeMode") == 2 then
		local night = VZS.gameIsNight()
		if night ~= nil then return night end
		-- Climate not ready yet; fall through to the profile's fixed hours rather than guess.
	end

	profile = profile or VZS.profile()
	return VZS.hourInWindow(gt:getTimeOfDay(), profile.nightStart, profile.nightEnd)
end

function VZS.targetSpeed(profile)
	profile = profile or VZS.profile()
	if VZS.isNightPhase(profile) then
		return profile.nightSpeed
	end
	return profile.daySpeed
end

--- Multiplier the XP module should apply to combat XP right now.
function VZS.currentXpMultiplier()
	if not VZS.opt("Enable") or not VZS.opt("XpEnable") then return 1.0 end

	-- Followers use the server's resolved multiplier. Recomputing it locally would reintroduce
	-- disagreement through the back door if a client's season or profile differed.
	if VZS.isFollower() and VZS.state.remoteXp ~= nil then
		return VZS.state.remoteXp
	end

	local profile = VZS.profile()
	if not VZS.isNightPhase(profile) then return 1.0 end
	local mult = profile.nightXp or 1.0
	if mult < 1.0 then mult = 1.0 end
	return mult
end

--- Mirror of GameTime.isZombieActivityPhase(). When false, the engine calls
--- makeInactive(true) on every zombie, which pins speedType to 3 and stops chasing.
function VZS.engineActivePhase()
	local activeOnly = readVanilla(VANILLA_ACTIVE_OPTION)
	if activeOnly == nil then return true end
	if activeOnly == 1 then return true end

	local night = VZS.gameIsNight()
	if night == nil then return true end   -- cannot tell yet; assume active

	if activeOnly == 2 then return night end
	if activeOnly == 3 then return not night end
	return true
end

-- --------------------------------------------------------- per-zombie apply

--- Last-resort assignment. getSpeedTypeFromWalkType() maps "sprint*" -> 1, "slow*" -> 3,
--- anything else -> 2, and `walkType` is also the `zombieWalkType` animation variable,
--- so this keeps the animation in sync with the speed.
local function forceSpeedType(zombie, speed)
	local walkType
	if speed == VZS.SPRINTER then
		walkType = "sprint" .. tostring(ZombRand(5) + 1)
	elseif speed == VZS.SHAMBLER then
		walkType = "slow" .. tostring(ZombRand(3) + 1)
	else
		walkType = tostring(ZombRand(5) + 1)
	end
	local ok, err = pcall(function()
		zombie:setWalkType(walkType)
		zombie:setSpeedTypeFromWalkType()
	end)
	if not ok then
		VZS.state.lastError = tostring(err)
		return false
	end
	VZS.state.fallbackCount = VZS.state.fallbackCount + 1
	return true
end

--- Bring one zombie in line with `speed`. `engineActive` is hoisted out of the loop by callers.
function VZS.applyToZombie(zombie, speed, engineActive)
	if zombie == nil then return false end

	-- When the engine has this zombie in its inactive phase, doZombieSpeed(-1) always
	-- resolves to shambler, so skip straight to the direct assignment.
	if engineActive then
		local ok, err = pcall(function() zombie:doZombieSpeed(-1) end)
		if not ok then
			VZS.state.lastError = tostring(err)
			warnOnce("doZombieSpeed", "IsoZombie:doZombieSpeed(-1) is unavailable (" ..
				tostring(err) .. "); falling back to setWalkType")
			return forceSpeedType(zombie, speed)
		end
		if speed == VZS.RANDOM then
			return true
		end
		local okGet, current = pcall(function() return zombie:getSpeedType() end)
		if okGet and current == speed then
			return true
		end
	end

	if speed == VZS.RANDOM then
		-- Nothing sensible to force; leave whatever doZombieSpeed rolled.
		return true
	end
	return forceSpeedType(zombie, speed)
end

local function zombieList()
	local cell = getCell()
	if not cell then return nil end
	local ok, list = pcall(function() return cell:getZombieList() end)
	if not ok or list == nil then return nil end
	return list
end

--- Do we simulate this zombie, or does another machine?
---
--- ZombiePacket carries both `walkType` (NetworkVariables$WalkType: WT1-5, WTSprint1-5,
--- WTSlow1-3) and `speedMod`, and NetworkZombieAI applies them on receipt with
--- setWalkType() + setSpeedTypeFromWalkType(). So a speed we write to a zombie owned by
--- someone else is overwritten by their next packet - we would fight the network forever and
--- the sweep would never converge. Only touch what we own.
---
--- Singleplayer short-circuits to true, so this is provably a no-op outside multiplayer.
function VZS.ownsZombie(zombie)
	if not (isClient() or isServer()) then return true end

	if isClient() then
		local ok, remote = pcall(function() return zombie:isRemoteZombie() end)
		return not (ok and remote == true)
	end

	-- Dedicated server: a zombie with an owning connection is simulated by that client.
	local ok, owner = pcall(function() return zombie:getOwner() end)
	return not (ok and owner ~= nil)
end

--- Walk `count` zombies starting at the shared cursor.
--- Returns howManyTouched, wrappedToStart.
local function processBatch(cursorKey, count, speed, forceAll)
	local list = zombieList()
	if not list then return 0, true end

	count = math.floor(count or 100)
	if count < 1 then count = 1 end

	local size = list:size()
	if size == 0 then
		VZS.state[cursorKey] = 0
		return 0, true
	end

	local engineActive = VZS.engineActivePhase()
	local cursor = VZS.state[cursorKey] or 0
	if cursor >= size then cursor = 0 end

	local touched = 0
	local scanned = 0
	local wrapped = false

	while scanned < count do
		local zombie = list:get(cursor)
		if zombie ~= nil and VZS.ownsZombie(zombie) then
			local needs = forceAll
			if not needs and speed ~= VZS.RANDOM then
				local ok, current = pcall(function() return zombie:getSpeedType() end)
				needs = ok and current ~= speed
			end
			if needs then
				VZS.applyToZombie(zombie, speed, engineActive)
				touched = touched + 1
			end
		elseif zombie ~= nil then
			VZS.state.skippedRemote = (VZS.state.skippedRemote or 0) + 1
		end

		cursor = cursor + 1
		scanned = scanned + 1
		if cursor >= size then
			cursor = 0
			wrapped = true
			break
		end
	end

	VZS.state[cursorKey] = cursor
	return touched, wrapped
end

-- ------------------------------------------------------------ apply / switch

--- Announce a phase or season change in character. The actual lines live in the client-only
--- VZS_Flavour module, so this is a no-op on a dedicated server.
--- `kind` is "nightfall", "daybreak" or "season".
function VZS.announce(kind, profile)
	if not VZS.opt("Notify") then return end
	if VZS.state.notifyBroken then return end
	if not (VZS.flavour and VZS.flavour.say) then return end
	VZS.flavour.say(kind, profile)
end

--- The Toughness the world had before this mod ever touched it, remembered in the save so a
--- reload cannot mistake our own value for the original.
function VZS.originalToughness()
	local md = modData()
	if md and md.originalToughness ~= nil then
		return md.originalToughness
	end
	local current = readVanilla(VANILLA_TOUGH_OPTION)
	if md and current ~= nil then
		md.originalToughness = current
	end
	return current
end

function VZS.applyToughness(value)
	if value == VZS.TOUGH_UNCHANGED then
		value = VZS.originalToughness()
	end
	if value == nil then return end

	-- Compare against the option's LIVE value, not our own memory of what we last wrote.
	-- Anything else that changes Toughness (admin panel, a server pushing sandbox settings,
	-- another mod) would otherwise go unnoticed until the next phase change.
	local live = readVanilla(VANILLA_TOUGH_OPTION)
	if live == value then
		VZS.state.appliedToughness = value
		return
	end
	if VZS.state.appliedToughness ~= nil and live ~= VZS.state.appliedToughness then
		VZS.state.driftCount = (VZS.state.driftCount or 0) + 1
		VZS.debugLog("toughness drifted externally (expected " ..
			tostring(VZS.state.appliedToughness) .. ", found " .. tostring(live) .. "), re-asserting")
	end

	local ok, err = writeVanilla(VANILLA_TOUGH_OPTION, value)
	if not ok then
		VZS.state.lastError = err
		VZS.log("ERROR: could not set " .. VANILLA_TOUGH_OPTION .. " -> " .. tostring(err))
		return
	end
	if SandboxVars and SandboxVars.ZombieLore then
		SandboxVars.ZombieLore.Toughness = value
	end
	VZS.state.appliedToughness = value
	VZS.debugLog("toughness -> " .. tostring(VZS.TOUGH_NAMES[value] or value))
end

--- Push `speed` into the global sandbox option and start a refresh pass.
function VZS.applySpeed(speed, reason)
	local ok, err = writeVanilla(VANILLA_SPEED_OPTION, speed)
	if not ok then
		VZS.state.lastError = err
		VZS.log("ERROR: could not set " .. VANILLA_SPEED_OPTION .. " -> " .. tostring(err))
		VZS.log("       per-zombie speed will still be forced, but zombies may not slow back down.")
	end

	-- Keep the Lua-side mirror consistent for anything else reading SandboxVars.
	if SandboxVars and SandboxVars.ZombieLore then
		SandboxVars.ZombieLore.Speed = speed
	end

	VZS.state.appliedSpeed = speed

	if VZS.opt("RefreshOnSwitch") then
		VZS.state.refreshing     = true
		VZS.state.refreshCursor  = 0
		VZS.state.refreshTouched = 0
	end

	local speedName = VZS.SPEED_NAMES[speed] or ("speed " .. tostring(speed))
	-- The wall-clock stamp is what lets you diff a server console.txt against a client one and
	-- measure how far apart the two machines flipped. See "Measuring the desync window".
	VZS.log("switched to " .. speedName .. " (" .. tostring(reason) .. ", hour " ..
		string.format("%.2f", VZS.currentHour() or -1) ..
		", role " .. (isClient() and "client" or (isServer() and "server" or "sp")) ..
		", wallclock " .. tostring(getTimestampMs()) .. ")")
end

--- Enforce ActiveOnly = Both so the vanilla dusk/dawn effect does not override us.
local function reconcileActiveOnly()
	local activeOnly = readVanilla(VANILLA_ACTIVE_OPTION)
	if activeOnly == nil or activeOnly == 1 then return end

	if not VZS.opt("ForceActiveOnly") then
		warnOnce("activeOnly", "ZombieLore.ActiveOnly is " .. tostring(activeOnly) ..
			" and 'Override vanilla day/night effect' is off. The engine will force " ..
			"shamblers outside its own active phase; this mod will fight it every sweep.")
		return
	end

	local ok, err = writeVanilla(VANILLA_ACTIVE_OPTION, 1)
	if ok then
		VZS.log("set ZombieLore.ActiveOnly to Both (was " .. tostring(activeOnly) .. ")")
		if SandboxVars and SandboxVars.ZombieLore then
			SandboxVars.ZombieLore.ActiveOnly = 1
		end
	else
		VZS.log("ERROR: could not set ZombieLore.ActiveOnly -> " .. tostring(err))
	end
end

VZS.SYNC_MODULE = "VZS"

--- Server -> all clients. The server resolves everything (phase, speed, toughness, XP
--- multiplier) and clients apply it verbatim.
---
--- This exists because zombies near a client are owned by that client: PZ hands zombie
--- authority to the nearest player, and the server accepts the owner's positions. Combined
--- with PathFindBehavior2 deriving `running` from each machine's own copy of
--- ZombieLore.Speed, a client that disagreed did not merely render zombies wrongly - it moved
--- them wrongly for everybody. Letting each machine reach its own conclusion from a shared
--- clock made agreement a coincidence; this makes it structural.
function VZS.broadcastState(reason)
	if not isServer() then return end

	local payload = {
		speed     = VZS.state.appliedSpeed,
		toughness = VZS.state.appliedToughness,
		night     = VZS.state.night,
		profile   = VZS.state.profilePrefix,
		xp        = VZS.currentXpMultiplier(),
		reason    = reason,
	}

	local ok, err = pcall(function()
		sendServerCommand(VZS.SYNC_MODULE, "state", payload)
	end)
	if not ok then
		VZS.state.lastError = tostring(err)
		VZS.log("ERROR: state broadcast failed -> " .. tostring(err))
		return
	end

	VZS.state.broadcasts = (VZS.state.broadcasts or 0) + 1

	-- Heartbeats fire once a second by default; logging each one would bury console.txt.
	-- Real state changes are always worth a line.
	if reason ~= "heartbeat" then
		VZS.debugLog("broadcast state: speed " .. tostring(payload.speed) ..
			", tough " .. tostring(payload.toughness) ..
			", night " .. tostring(payload.night) ..
			", xp " .. tostring(payload.xp) ..
			" (" .. tostring(reason) .. ")")
	end
end

--- Send the current state to one player (used to answer a join-time request).
function VZS.sendStateTo(player)
	if not isServer() or not player then return end
	pcall(function()
		sendServerCommand(player, VZS.SYNC_MODULE, "state", {
			speed     = VZS.state.appliedSpeed,
			toughness = VZS.state.appliedToughness,
			night     = VZS.state.night,
			profile   = VZS.state.profilePrefix,
			xp        = VZS.currentXpMultiplier(),
			reason    = "join",
		})
	end)
end

--- Client side: adopt the server's state verbatim.
function VZS.applyRemoteState(args)
	if not args then return end

	local speed = tonumber(args.speed)
	if not speed then return end
	local toughness = tonumber(args.toughness)
	local night     = (args.night == true)

	local firstSync    = not VZS.state.remoteApplied
	local phaseChanged = (not firstSync) and (VZS.state.night ~= nil) and (night ~= VZS.state.night)

	VZS.state.remoteApplied    = true
	VZS.state.night            = night
	VZS.state.profilePrefix    = args.profile or VZS.state.profilePrefix
	VZS.state.remoteXp         = tonumber(args.xp) or 1.0
	VZS.state.lastSyncAt       = getTimestampMs()
	VZS.state.syncsReceived    = (VZS.state.syncsReceived or 0) + 1

	if speed ~= VZS.state.appliedSpeed or readVanilla(VANILLA_SPEED_OPTION) ~= speed then
		VZS.applySpeed(speed, "server sync (" .. tostring(args.reason or "update") .. ")")
	end
	if toughness then
		VZS.applyToughness(toughness)
	end

	if phaseChanged then
		VZS.announce(night and "nightfall" or "daybreak", VZS.profile())
	end
end

--- Evaluate the current phase and switch if needed. `force` re-applies even if unchanged.
function VZS.evaluate(force)
	if not VZS.opt("Enable") then return end
	if VZS.state.testDesync then return end   -- VZS.desync() holds this machine off-sync

	-- Once the server has spoken, a client stops deciding for itself. Before the first packet
	-- it still evaluates locally so a joining player is not left on stale settings.
	if VZS.isFollower() then return end

	reconcileActiveOnly()

	local profile = VZS.profile()
	local night   = VZS.isNightPhase(profile)
	local speed   = night and profile.nightSpeed or profile.daySpeed

	local firstRun      = (VZS.state.night == nil)
	local phaseChanged  = (not firstRun) and (night ~= VZS.state.night)
	local seasonChanged = (not firstRun) and (profile.prefix ~= VZS.state.profilePrefix)

	-- Detect the global option being changed out from under us. state.appliedSpeed is only our
	-- memory of the last write, so without this check an external change (admin sandbox panel,
	-- a server pushing settings, another mod) would persist until the next dusk or dawn.
	local liveSpeed  = readVanilla(VANILLA_SPEED_OPTION)
	local speedDrift = (VZS.state.appliedSpeed ~= nil) and (liveSpeed ~= nil)
		and (liveSpeed ~= VZS.state.appliedSpeed)

	if force or firstRun or phaseChanged or seasonChanged or speedDrift
		or speed ~= VZS.state.appliedSpeed then

		local reason
		if firstRun then
			reason = "startup"
		elseif seasonChanged then
			reason = "season -> " .. profile.label
		elseif phaseChanged then
			reason = night and "nightfall" or "daybreak"
		elseif speedDrift then
			VZS.state.driftCount = (VZS.state.driftCount or 0) + 1
			reason = "re-asserting after external change (found " ..
				tostring(VZS.SPEED_NAMES[liveSpeed] or liveSpeed) .. ")"
		else
			reason = "settings changed"
		end
		VZS.applySpeed(speed, reason)
	end

	VZS.state.night         = night
	VZS.state.profilePrefix = profile.prefix

	VZS.applyToughness(night and profile.nightToughness or profile.dayToughness)

	-- Push the resolved state out whenever any of it moved.
	if isServer() then
		local last = VZS.state.lastBroadcast
		if not last or last.speed ~= VZS.state.appliedSpeed
			or last.toughness ~= VZS.state.appliedToughness
			or last.night ~= night then

			VZS.state.lastBroadcast = {
				speed     = VZS.state.appliedSpeed,
				toughness = VZS.state.appliedToughness,
				night     = night,
			}
			VZS.broadcastState(phaseChanged and (night and "nightfall" or "daybreak")
				or (seasonChanged and "season") or "update")
		end
	end

	-- Flavour text keys off the phase/season flip itself rather than the speed write, so the
	-- survivor still comments at dusk even when night and day are set to the same speed - and
	-- stays quiet on startup, where a sudden "the light's going" would make no sense.
	if phaseChanged then
		VZS.announce(night and "nightfall" or "daybreak", profile)
	elseif seasonChanged then
		VZS.announce("season", profile)
	end
end

-- -------------------------------------------------------------- event hooks

-- How often to re-check the phase, in ticks. EveryOneMinute is one *in-game* minute, which at
-- the default day length is ~2.5 real seconds - long enough for a client and server to sit on
-- different values of ZombieLore.Speed either side of dusk. That matters more than it sounds:
-- PathFindBehavior2 derives `zombie.running` from that option locally, on every machine, for
-- every zombie including remote ones, and never networks it - so during the gap one machine
-- moves the whole horde at a different speed from the other. Polling here collapses the
-- disagreement to a few ticks. The check is a couple of table lookups plus a compare, so it is
-- cheap enough to run at this rate.
local PHASE_POLL_TICKS = 10

local function onTick()
	if not VZS.state.started then return end
	if not VZS.opt("Enable") then return end

	VZS.state.tick = VZS.state.tick + 1

	-- Fast phase-flip detection. EveryOneMinute still runs as the coarse safety net; it also
	-- covers season changes and external drift, which this deliberately does not check.
	if not VZS.state.testDesync and VZS.state.night ~= nil
		and VZS.state.tick % PHASE_POLL_TICKS == 0 then
		if VZS.isNightPhase() ~= VZS.state.night then
			VZS.evaluate(false)
		end
	end

	local target = VZS.state.appliedSpeed
	if target == nil then return end

	if VZS.state.refreshing then
		local touched, wrapped = processBatch("refreshCursor", VZS.opt("RefreshBatch"), target, true)
		VZS.state.refreshTouched = VZS.state.refreshTouched + touched
		if wrapped then
			VZS.state.refreshing = false
			VZS.debugLog("switchover refresh done, " .. tostring(VZS.state.refreshTouched) ..
				" zombies re-derived")
		end
		return
	end

	if VZS.opt("SweepEnable") and target ~= VZS.RANDOM then
		local interval = math.floor(VZS.opt("SweepInterval") or 30)
		if interval < 1 then interval = 1 end
		if VZS.state.tick % interval == 0 then
			local touched = processBatch("sweepCursor", VZS.opt("SweepBatch"), target, false)
			if touched > 0 then
				VZS.debugLog("sweep corrected " .. tostring(touched) .. " zombies")
			end
		end
	end
end

local function onEveryOneMinute()
	if not VZS.state.started then return end
	VZS.evaluate(false)
end

local function onStart()
	if VZS.state.started then return end
	VZS.state.started = true

	if not VZS.opt("Enable") then
		VZS.log("v" .. VZS.VERSION .. " loaded but disabled in sandbox options")
		return
	end

	-- Capture the world's original Toughness before anything is written to it.
	VZS.originalToughness()

	local profile = VZS.profile()
	local window  = VZS.opt("TimeMode") == 2 and "game dusk/dawn"
		or (string.format("%.2f", profile.nightStart) .. " -> " ..
		    string.format("%.2f", profile.nightEnd))

	VZS.log("v" .. VZS.VERSION .. " active. season " .. VZS.seasonName() ..
		", profile " .. profile.label ..
		", window " .. window ..
		", night = " .. (VZS.SPEED_NAMES[profile.nightSpeed] or "?") ..
		", day = " .. (VZS.SPEED_NAMES[profile.daySpeed] or "?") ..
		", night XP x" .. string.format("%.2f", profile.nightXp or 1))

	VZS.evaluate(true)
end

Events.OnGameStart.Add(onStart)
Events.OnServerStarted.Add(onStart)
Events.EveryOneMinute.Add(onEveryOneMinute)
Events.OnTick.Add(onTick)

-- ------------------------------------------------------- debug console tools

--- Count loaded zombies by speedType.
function VZS.speedCensus()
	local counts = { [1] = 0, [2] = 0, [3] = 0, other = 0, total = 0 }
	local list = zombieList()
	if not list then return counts end
	local size = list:size()
	counts.total = size
	for i = 0, size - 1 do
		local zombie = list:get(i)
		if zombie then
			local ok, speedType = pcall(function() return zombie:getSpeedType() end)
			if ok and counts[speedType] then
				counts[speedType] = counts[speedType] + 1
			else
				counts.other = counts.other + 1
			end
		end
	end
	return counts
end

function VZS.speedCensusString()
	local c = VZS.speedCensus()
	return "total " .. c.total ..
		" | sprinter " .. c[1] ..
		" | fast " .. c[2] ..
		" | shambler " .. c[3] ..
		" | other " .. c.other
end

--- Print current state. Call from the in-game Lua console: VZS.status()
function VZS.status()
	local hour    = VZS.currentHour()
	local profile = VZS.profile()
	VZS.log("---- status ----")
	VZS.log("  version        : " .. VZS.VERSION)
	VZS.log("  enabled        : " .. tostring(VZS.opt("Enable")))
	VZS.log("  hour           : " .. (hour and string.format("%.3f", hour) or "n/a"))
	VZS.log("  season         : " .. VZS.seasonName() ..
		"  (season mode: " .. (VZS.opt("SeasonMode") == 2 and "per-season" or "single") .. ")")
	VZS.log("  profile        : " .. profile.label)
	VZS.log("  time mode      : " .. (VZS.opt("TimeMode") == 2 and "game dusk/dawn" or "fixed hours"))
	VZS.log("  night window   : " .. string.format("%.2f", profile.nightStart) ..
		" -> " .. string.format("%.2f", profile.nightEnd))
	VZS.log("  phase          : " .. (VZS.isNightPhase(profile) and "NIGHT" or "DAY") ..
		(VZS.state.override and ("  (forced: " .. VZS.state.override .. ")") or ""))
	VZS.log("  target speed   : " .. tostring(VZS.SPEED_NAMES[VZS.targetSpeed(profile)]))
	VZS.log("  applied speed  : " .. tostring(VZS.SPEED_NAMES[VZS.state.appliedSpeed]))
	VZS.log("  sandbox Speed  : " .. tostring(readVanilla(VANILLA_SPEED_OPTION)))
	VZS.log("  toughness      : applied " .. tostring(VZS.TOUGH_NAMES[VZS.state.appliedToughness]) ..
		", original " .. tostring(VZS.TOUGH_NAMES[VZS.originalToughness()]) ..
		", sandbox " .. tostring(readVanilla(VANILLA_TOUGH_OPTION)))
	VZS.log("  night XP mult  : " .. string.format("%.2f", VZS.currentXpMultiplier()))
	VZS.log("  ActiveOnly     : " .. tostring(readVanilla(VANILLA_ACTIVE_OPTION)) ..
		"  (engine active phase: " .. tostring(VZS.engineActivePhase()) .. ")")
	VZS.log("  refreshing     : " .. tostring(VZS.state.refreshing))
	VZS.log("  net role       : " .. (isClient() and "MP client" or (isServer() and "server" or "singleplayer")) ..
		", zombies skipped as remote " .. tostring(VZS.state.skippedRemote or 0))
	VZS.log("  sync           : following server " .. tostring(VZS.isFollower()) ..
		", packets rcvd " .. tostring(VZS.state.syncsReceived or 0) ..
		", sent " .. tostring(VZS.state.broadcasts or 0) ..
		(VZS.state.lastSyncAt
			and (", last " .. tostring(getTimestampMs() - VZS.state.lastSyncAt) .. "ms ago")
			or ""))
	VZS.log("  external drift : " .. tostring(VZS.state.driftCount or 0) .. " re-assertion(s)")
	VZS.log("  fallback uses  : " .. tostring(VZS.state.fallbackCount))
	VZS.log("  last error     : " .. tostring(VZS.state.lastError))
	VZS.log("  zombie counts  : " .. VZS.speedCensusString())
	if VZS.xp and VZS.xp.status then
		VZS.xp.status()
	end
end

--- Force a phase for testing: VZS.force("night") / VZS.force("day") / VZS.force(nil)
function VZS.force(phase)
	if phase ~= "night" and phase ~= "day" then phase = nil end
	VZS.state.override = phase
	VZS.log("override = " .. tostring(phase))
	VZS.evaluate(true)
end

--- Dump the first `count` loaded zombies (default 10).
function VZS.dump(count)
	count = count or 10
	local list = zombieList()
	if not list then
		VZS.log("no cell / zombie list")
		return
	end
	local size = list:size()
	VZS.log("dumping " .. math.min(count, size) .. " of " .. size .. " zombies")
	for i = 0, math.min(count, size) - 1 do
		local zombie = list:get(i)
		if zombie then
			local speedType = "?"
			local walkType  = "?"
			pcall(function() speedType = tostring(zombie:getSpeedType()) end)
			pcall(function() walkType = tostring(zombie:getWalkType()) end)
			VZS.log("  [" .. i .. "] speedType=" .. speedType ..
				" walkType=" .. walkType ..
				" crawling=" .. tostring(zombie:isCrawling()))
		end
	end
end

--- Re-apply from scratch right now.
function VZS.reapply()
	VZS.evaluate(true)
end

--- Deliberately hold this machine at a chosen speed and stop it re-syncing, to test whether a
--- client/server disagreement is actually visible.
---
--- Worth understanding why this is the right test. PathFindBehavior2.update() and
--- moveToPoint() both do, on every machine, every pathfind tick, for remote zombies too:
---     zombie.running = (SandboxOptions.instance.lore.speed.getValue() == 1);
--- `running` is therefore derived locally and is NOT networked, so two machines holding
--- different values for that option animate and move the same zombie differently. The real
--- disagreement lasts under a minute at dusk; this makes it permanent and total, so if you
--- cannot see an artefact with this on, the transient version cannot matter either.
---
---   VZS.desync(1)   -- hold this machine at Sprinters
---   VZS.desync(3)   -- hold this machine at Shamblers
---   VZS.desync()    -- release and resync
function VZS.desync(speed)
	if speed == nil then
		VZS.state.testDesync = false
		VZS.log("desync test OFF - resuming normal control")
		VZS.evaluate(true)
		return
	end

	VZS.state.testDesync = false          -- let this one write land
	local ok, err = writeVanilla(VANILLA_SPEED_OPTION, speed)
	if not ok then
		VZS.log("ERROR: desync write failed -> " .. tostring(err))
		return
	end
	if SandboxVars and SandboxVars.ZombieLore then
		SandboxVars.ZombieLore.Speed = speed
	end
	VZS.state.appliedSpeed = speed

	-- Re-derive the loaded zombies too. Without this the test only moves the `running` flag
	-- (global, local, not networked) and leaves `walkType` alone, so zombies move at the new
	-- speed while still playing the old animation. A real switchover changes both.
	if VZS.opt("RefreshOnSwitch") then
		VZS.state.refreshing     = true
		VZS.state.refreshCursor  = 0
		VZS.state.refreshTouched = 0
	end

	VZS.state.testDesync = true

	VZS.log("desync test ON - this machine pinned to " ..
		tostring(VZS.SPEED_NAMES[speed] or speed) ..
		" and will not re-assert or follow the clock. Run VZS.desync() to end.")
end

--- Print every profile so you can see what each season will do.
function VZS.profiles()
	VZS.log("---- profiles ----")
	local order = { "", "Spring", "Summer", "Autumn", "Winter" }
	for i = 1, #order do
		local p = order[i]
		VZS.log("  " .. (p == "" and "Default" or p) ..
			"  night " .. string.format("%.2f", VZS.opt(p .. "NightStart")) ..
			" -> " .. string.format("%.2f", VZS.opt(p .. "NightEnd")) ..
			"  speed " .. tostring(VZS.SPEED_NAMES[VZS.opt(p .. "NightSpeed")]) ..
			"/" .. tostring(VZS.SPEED_NAMES[VZS.opt(p .. "DaySpeed")]) ..
			"  tough " .. tostring(VZS.TOUGH_NAMES[VZS.opt(p .. "NightToughness")]) ..
			"/" .. tostring(VZS.TOUGH_NAMES[VZS.opt(p .. "DayToughness")]) ..
			"  xp x" .. string.format("%.2f", VZS.opt(p .. "NightXp")))
	end
end
