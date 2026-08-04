--[[
	Variable Zombie Speed - server-side XP authority.

	In multiplayer the client cannot grant itself XP. All three Lua XP globals share this shape:

	    if (GameServer.server) { GameServer.addXp(...); }
	    if (GameClient.client) return;          // client does nothing at all
	    player.getXp().AddXP(...);              // singleplayer only

	So VZS_Xp.lua detects the combat XP gain client-side (where OnHitZombie and OnPlayerUpdate
	fire) and sends the computed bonus here, where addXpNoMultiplier() routes into
	GameServer.addXp() and actually lands.

	This file is inert in singleplayer: OnClientCommand never fires there, and the client
	grants locally instead.
]]

require "VariableZombieSpeed/VZS_Core"

-- Must match VZS_Xp.lua.
local MODULE  = "VZS"
local COMMAND = "grantXp"

-- Never trust a number off the wire. This is well above any plausible single-tick bonus
-- (a heavy weapon swing is single-digit XP) while still bounding a buggy or hostile client.
local MAX_PER_MESSAGE = 250.0

-- Only the perks VZS_Xp.lua actually tracks.
local ALLOWED = {
	Axe = true, Blunt = true, SmallBlunt = true, LongBlade = true, SmallBlade = true,
	Spear = true, Maintenance = true, Aiming = true, Reloading = true,
	Strength = true, Fitness = true,
}

local rejected = 0

local function onClientCommand(module, command, player, args)
	if module ~= MODULE or command ~= COMMAND then return end
	if not player or not args then return end

	-- Re-check the sandbox switches server-side; a client must not be able to pay itself
	-- while the feature is disabled for the world.
	if not VZS.opt("Enable") or not VZS.opt("XpEnable") then
		rejected = rejected + 1
		return
	end

	local name   = args.perk
	local amount = tonumber(args.amount)

	if type(name) ~= "string" or not ALLOWED[name] then
		rejected = rejected + 1
		VZS.debugLog("xp grant rejected: bad perk " .. tostring(name))
		return
	end
	if not amount or amount ~= amount or amount <= 0 then   -- also rejects NaN
		rejected = rejected + 1
		return
	end
	if amount > MAX_PER_MESSAGE then
		VZS.log("WARNING: clamped XP grant of " .. string.format("%.1f", amount) ..
			" for " .. name .. " from " .. tostring(player:getUsername()))
		amount = MAX_PER_MESSAGE
	end

	local perk = Perks and Perks[name]
	if not perk then
		rejected = rejected + 1
		return
	end

	local ok, err = pcall(function() addXpNoMultiplier(player, perk, amount) end)
	if not ok then
		VZS.log("ERROR: server XP grant failed -> " .. tostring(err))
		return
	end

	VZS.debugLog("granted " .. string.format("%.2f", amount) .. " " .. name ..
		" to " .. tostring(player:getUsername()))
end

Events.OnClientCommand.Add(onClientCommand)

function VZS.xpServerStatus()
	VZS.log("xp server: listening on " .. MODULE .. "." .. COMMAND ..
		", rejected " .. tostring(rejected) .. " message(s)")
end
