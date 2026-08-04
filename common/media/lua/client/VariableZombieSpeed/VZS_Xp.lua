--[[
	Variable Zombie Speed - night combat XP multiplier.

	Requirement: multiply XP earned *from fighting* at night, without touching XP from any
	other source (exercise, reading, crafting).

	Why not addXpMultiplier(): IsoGameCharacter.XP.addXpMultiplier() writes a single
	XPMultiplier per perk into the same map the skill-book system uses, and it applies to every
	XP gain for that perk regardless of where the XP came from. That would boost night-time
	push-ups as readily as night-time zombie skulls, and would clobber a book's multiplier.

	So instead: watch each tracked perk's cumulative XP, and when it rises within a short window
	after the player hit a zombie, top the gain up by (multiplier - 1). The result is a true
	multiplier on exactly the combat-derived XP.

	  * IsoGameCharacter.XP.getXP(perk) is cumulative (it is compared against
	    Perk.getTotalXpForLevel(n) internally), so it never resets on level-up and deltas are
	    always positive. A negative delta is treated as a desync and just re-syncs the baseline.
	  * The top-up goes through addXpNoMultiplier() so it cannot be re-multiplied by traits,
	    and the baseline is re-read afterwards so the bonus is never counted as a fresh gain.
]]

require "VariableZombieSpeed/VZS_Core"

VZS.xp = VZS.xp or {}

local COMBAT_PERK_NAMES = {
	"Axe", "Blunt", "SmallBlunt", "LongBlade", "SmallBlade",
	"Spear", "Maintenance", "Aiming", "Reloading",
}

local tracked = nil          -- { {name=, perk=}, ... }
local players = {}           -- playerNum -> per-player tracking state

VZS.xp.MODULE  = "VZS"
VZS.xp.COMMAND = "grantXp"

-- How long to wait for a granted bonus to show up in getXP() before assuming it was rejected
-- or lost. On a multiplayer client the grant round-trips through the server, so it lands some
-- ticks after we asked for it.
local PENDING_TTL = 15000

--- Pay out a bonus.
---
--- On a multiplayer client this MUST go through the server: addXpNoMultiplier(), addXp() and
--- addXpMultiplier() all return early when GameClient.client is set --
---     if (GameServer.server) { GameServer.addXp(...); }
---     if (GameClient.client) return;          // <-- client does nothing at all
---     player.getXp().AddXP(...);              // singleplayer only
--- ...so calling it directly on a client silently does nothing. Only the server has XP
--- authority. In singleplayer the local call is correct and avoids a pointless round-trip.
local function grantXp(player, entry, bonus)
	if isClient() then
		return pcall(function()
			sendClientCommand(player, VZS.xp.MODULE, VZS.xp.COMMAND,
				{ perk = entry.name, amount = bonus })
		end)
	end
	return pcall(function() addXpNoMultiplier(player, entry.perk, bonus) end)
end

--- Build the tracked perk list from the sandbox toggles. Perks missing from this build are
--- skipped rather than erroring.
function VZS.xp.rebuild()
	local list = {}

	local function add(name)
		local perk = Perks and Perks[name]
		if perk then
			list[#list + 1] = { name = name, perk = perk }
		else
			VZS.log("WARNING: Perks." .. name .. " does not exist in this build, skipping")
		end
	end

	if VZS.opt("XpCombatSkills") then
		for i = 1, #COMBAT_PERK_NAMES do
			add(COMBAT_PERK_NAMES[i])
		end
	end
	if VZS.opt("XpStrength") then add("Strength") end
	if VZS.opt("XpFitness") then add("Fitness") end

	tracked = list
	players = {}
	VZS.debugLog("XP tracking " .. #list .. " perks")
	return list
end

local function stateFor(playerNum)
	local st = players[playerNum]
	if not st then
		st = {
			combatUntil   = 0,
			last          = {},    -- perk name -> last observed cumulative XP
			pending       = {},    -- perk name -> bonus asked for but not yet seen in getXP()
			pendingExpiry = 0,
			granted       = 0.0,
			grants        = 0,
			lastGrantHour = nil,   -- in-game hour of the most recent bonus
			lastLogAt     = 0,
		}
		players[playerNum] = st
	end
	return st
end

--- Record a bonus and, under Debug, log it with the in-game hour it happened at.
--- The hour is the whole point: if bonuses appear at hour 13, the night gate is wrong.
--- Rate-limited to one line per second per player so a fight does not flood console.txt.
local function recordGrant(st, perkName, bonus, mult)
	st.granted       = st.granted + bonus
	st.grants        = st.grants + 1
	st.lastGrantHour = VZS.currentHour()

	if not VZS.opt("Debug") then return end
	local now = getTimestampMs()
	if now - st.lastLogAt < 1000 then return end
	st.lastLogAt = now

	VZS.log(string.format(
		"xp bonus +%.2f %s at hour %.2f (phase %s, profile %s, mult %.2f, %d grants total)",
		bonus, perkName, st.lastGrantHour or -1,
		VZS.isNightPhase() and "NIGHT" or "DAY",
		VZS.profile().label, mult, st.grants))
end

--- Any hit on a zombie opens the combat window for that player.
local function onHitZombie(zombie, wielder, bodyPart, weapon)
	if not wielder then return end
	if not instanceof(wielder, "IsoPlayer") then return end
	local ok, num = pcall(function() return wielder:getPlayerNum() end)
	if not ok or num == nil then return end

	local window = VZS.opt("XpWindow") or 1000
	stateFor(num).combatUntil = getTimestampMs() + window
end

local function onPlayerUpdate(player)
	if not player then return end

	-- Skip the whole per-tick loop when the feature is off. Baselines are dropped so
	-- re-enabling mid-game starts clean instead of paying out a huge accumulated delta.
	if not VZS.opt("Enable") or not VZS.opt("XpEnable") then
		if next(players) ~= nil then players = {} end
		return
	end

	if not tracked then VZS.xp.rebuild() end
	if #tracked == 0 then return end

	local okNum, num = pcall(function() return player:getPlayerNum() end)
	if not okNum or num == nil then return end

	local xp = player:getXp()
	if not xp then return end

	local now      = getTimestampMs()
	local st       = stateFor(num)
	local inCombat = now < st.combatUntil
	local mult     = inCombat and VZS.currentXpMultiplier() or 1.0

	-- A bonus we asked for should reappear as an XP gain shortly afterwards. If it never does,
	-- the server rejected or dropped it; clear the credit so it stops masking real gains.
	if st.pendingExpiry > 0 and now > st.pendingExpiry then
		st.pending       = {}
		st.pendingExpiry = 0
		VZS.debugLog("xp pending credit expired unconsumed (grant rejected or lost?)")
	end

	for i = 1, #tracked do
		local entry = tracked[i]
		local ok, current = pcall(function() return xp:getXP(entry.perk) end)
		if ok and current then
			local previous = st.last[entry.name]
			if previous == nil then
				st.last[entry.name] = current
			else
				local delta = current - previous

				-- Absorb XP that is just our own bonus arriving. Doing it by credit rather
				-- than by re-reading getXP() after the grant is what makes this work in
				-- multiplayer, where the grant round-trips through the server and lands
				-- several ticks later -- otherwise we would treat our own bonus as fresh
				-- combat XP and boost it again, and again, compounding without limit.
				if delta > 0 then
					local credit = st.pending[entry.name]
					if credit and credit > 0 then
						local used = (credit < delta) and credit or delta
						delta = delta - used
						st.pending[entry.name] = credit - used
					end
				end

				if delta > 0.0001 and mult > 1.0 then
					local bonus = delta * (mult - 1.0)
					if grantXp(player, entry, bonus) then
						st.pending[entry.name] = (st.pending[entry.name] or 0) + bonus
						st.pendingExpiry = now + PENDING_TTL
						recordGrant(st, entry.name, bonus, mult)
					end
				end

				st.last[entry.name] = current
			end
		end
	end
end

--- Appended to VZS.status().
function VZS.xp.status()
	VZS.log("  --- xp ---")
	VZS.log("  xp enabled     : " .. tostring(VZS.opt("XpEnable")) ..
		"  (window " .. tostring(VZS.opt("XpWindow")) .. "ms)")
	VZS.log("  tracked perks  : " .. tostring(tracked and #tracked or 0))
	VZS.log("  active mult    : " .. string.format("%.2f", VZS.currentXpMultiplier()))
	local now = getTimestampMs()
	for num, st in pairs(players) do
		VZS.log("  player " .. num .. "      : in combat " .. tostring(now < st.combatUntil) ..
			", grants " .. tostring(st.grants) ..
			", bonus XP " .. string.format("%.1f", st.granted) ..
			", last grant at hour " ..
			(st.lastGrantHour and string.format("%.2f", st.lastGrantHour) or "never"))
	end
end

--- One-line summary for the debug HUD.
function VZS.xp.hudLine()
	local st = players[0]
	if not st then return "xp: no player state yet" end
	return "xp: inCombat " .. tostring(getTimestampMs() < st.combatUntil) ..
		"   grants " .. tostring(st.grants) ..
		"   bonus " .. string.format("%.0f", st.granted) ..
		"   last at hour " ..
		(st.lastGrantHour and string.format("%.2f", st.lastGrantHour) or "never")
end

--- Zero the counters so you can measure a clean interval.
function VZS.xp.reset()
	players = {}
	VZS.log("xp counters reset")
end

Events.OnHitZombie.Add(onHitZombie)
Events.OnPlayerUpdate.Add(onPlayerUpdate)
Events.OnGameStart.Add(VZS.xp.rebuild)
