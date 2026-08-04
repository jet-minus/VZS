--[[
	Variable Zombie Speed - client side of the state sync.

	The server is the sole authority on phase, speed, toughness and the XP multiplier. This
	file receives that state and hands it to VZS.applyRemoteState(); the client stops consulting
	its own clock from the first packet onward (see VZS.isFollower).

	Why authority rather than "both machines read the same clock": PZ gives zombie ownership to
	the nearest player, and the server accepts the owner's positions. PathFindBehavior2 derives
	`zombie.running` from each machine's own copy of ZombieLore.Speed and never networks it. So
	a client holding a different value does not just see zombies wrongly - it moves them wrongly
	for everyone else too. Agreement has to be structural, not coincidental.
]]

require "VariableZombieSpeed/VZS_Core"

-- Ask again this often (ms) until the server has answered at least once.
local REQUEST_RETRY_MS = 5000

local lastRequestAt = 0

local function requestState()
	if not isClient() then return end
	local player = getPlayer()
	if not player then return end
	lastRequestAt = getTimestampMs()
	pcall(function()
		sendClientCommand(player, VZS.SYNC_MODULE, "requestState", {})
	end)
	VZS.debugLog("requested state from server")
end

local function onServerCommand(module, command, args)
	if module ~= VZS.SYNC_MODULE then return end
	if command ~= "state" then return end
	VZS.applyRemoteState(args)
end

--- Until the first packet lands the client is running on its own clock, which is exactly the
--- situation this whole mechanism exists to avoid. Retry rather than sit there diverging.
local function onEveryOneMinute()
	if not isClient() then return end
	if VZS.state.remoteApplied then return end
	if getTimestampMs() - lastRequestAt < REQUEST_RETRY_MS then return end
	requestState()
end

local function onStart()
	if not isClient() then return end
	requestState()
end

Events.OnServerCommand.Add(onServerCommand)
Events.OnGameStart.Add(onStart)
Events.OnConnected.Add(requestState)
Events.EveryOneMinute.Add(onEveryOneMinute)

--- Console helper: what has the server told us, and when?
function VZS.syncStatus()
	VZS.log("---- sync ----")
	VZS.log("  role           : " .. (isClient() and "MP client" or (isServer() and "server" or "singleplayer")))
	VZS.log("  following      : " .. tostring(VZS.isFollower()))
	VZS.log("  packets rcvd   : " .. tostring(VZS.state.syncsReceived or 0))
	if VZS.state.lastSyncAt then
		VZS.log("  last sync      : " .. tostring(getTimestampMs() - VZS.state.lastSyncAt) .. " ms ago")
	else
		VZS.log("  last sync      : never - still using the local clock")
	end
	VZS.log("  server night   : " .. tostring(VZS.state.night))
	VZS.log("  server xp mult : " .. tostring(VZS.state.remoteXp))
end
