--[[
	Variable Zombie Speed - server side of the state sync.

	Answers a joining client's request for the current state, and re-broadcasts periodically so
	a client that missed a packet converges instead of drifting indefinitely.

	The change-driven broadcast lives in VZS_Core.evaluate(); this file only covers the two
	cases that are not a state change: a new arrival, and packet loss.
]]

require "VariableZombieSpeed/VZS_Core"

local function onClientCommand(module, command, player, args)
	if module ~= VZS.SYNC_MODULE then return end
	if command ~= "requestState" then return end
	if not player then return end

	VZS.debugLog("state requested by " .. tostring(player:getUsername()))
	VZS.sendStateTo(player)
end

--- Heartbeat.
---
--- Deliberately driven by the REAL clock rather than EveryTenMinutes. An in-game timer scales
--- with the DayLength sandbox setting, so the same code would fire every few real seconds on a
--- short-day server and only every several real minutes on a long-day one - the recovery
--- window would silently depend on an unrelated setting.
---
--- This is only a safety net. A dusk/dawn change is broadcast immediately by
--- VZS_Core.evaluate(); the heartbeat exists to recover a client whose state was changed
--- behind the server's back (an admin sandbox edit, another mod, VZS.desync). The payload is
--- five small fields, so even a 1 second interval is a few KB/s across a full server -
--- negligible beside PZ's continuous position traffic.
local nextBeatAt = 0

local function onTick()
	if not isServer() then return end
	if not VZS.opt("Enable") then return end
	if VZS.state.appliedSpeed == nil then return end

	local now = getTimestampMs()
	if now < nextBeatAt then return end

	local seconds = math.floor(VZS.opt("SyncInterval") or 10)
	if seconds < 1 then seconds = 1 end
	nextBeatAt = now + (seconds * 1000)

	VZS.broadcastState("heartbeat")
end

Events.OnClientCommand.Add(onClientCommand)
Events.OnTick.Add(onTick)
