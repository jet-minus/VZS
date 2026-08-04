--[[
	Variable Zombie Speed - on-screen debug readout.

	Only drawn when the "Debug logging" sandbox option is on. Refreshes the zombie census
	once a second so the per-frame cost stays negligible.
]]

require "VariableZombieSpeed/VZS_Core"

local HUD = {
	lines      = {},
	nextCensus = 0,
	textMgr    = nil,
}

local LINE_COUNT = 8

local function refresh()
	local hour    = VZS.currentHour()
	local profile = VZS.profile()
	local night   = VZS.isNightPhase(profile)

	HUD.lines[1] = "VZS v" .. VZS.VERSION .. (VZS.opt("Enable") and "" or "  [DISABLED]")

	HUD.lines[2] = "season " .. VZS.seasonName() ..
		"   profile " .. profile.label ..
		(VZS.opt("SeasonMode") == 2 and "" or "  (single-profile mode)")

	HUD.lines[3] = "hour " .. (hour and string.format("%.2f", hour) or "?") ..
		"   window " .. string.format("%.2f", profile.nightStart) ..
		" -> " .. string.format("%.2f", profile.nightEnd) ..
		(VZS.opt("TimeMode") == 2 and "  (using game dusk/dawn)" or "")

	HUD.lines[4] = "phase " .. (night and "NIGHT" or "DAY") ..
		(VZS.state.override and ("  FORCED:" .. VZS.state.override) or "") ..
		"   speed " .. tostring(VZS.SPEED_NAMES[VZS.targetSpeed(profile)]) ..
		" (applied " .. tostring(VZS.SPEED_NAMES[VZS.state.appliedSpeed]) .. ")"

	-- This is the multiplier the current phase *would* apply to combat XP. It is not a
	-- statement that a bonus is being paid right now - line 6 shows that.
	HUD.lines[5] = "toughness " .. tostring(VZS.TOUGH_NAMES[VZS.state.appliedToughness]) ..
		"   combat XP x" .. string.format("%.2f", VZS.currentXpMultiplier()) ..
		" (potential)"

	HUD.lines[6] = (VZS.xp and VZS.xp.hudLine and VZS.xp.hudLine()) or "xp: module not loaded"

	HUD.lines[7] = VZS.speedCensusString() ..
		(VZS.state.refreshing and "   [refreshing]" or "")

	HUD.lines[8] = "engine active phase: " .. tostring(VZS.engineActivePhase()) ..
		"   fallbacks: " .. tostring(VZS.state.fallbackCount) ..
		"   drift: " .. tostring(VZS.state.driftCount or 0) ..
		"   remote skipped: " .. tostring(VZS.state.skippedRemote or 0) ..
		(VZS.state.lastError and ("   ERR: " .. tostring(VZS.state.lastError)) or "")
end

local function draw()
	-- OnPreUIDraw also fires from MainScreenState.render, i.e. on the main menu, where no world
	-- exists yet. Nothing below is meaningful there and several accessors are not safe to call.
	if getPlayer() == nil then return end
	if not VZS.opt("Debug") then return end

	local now = getTimestampMs()
	if now >= HUD.nextCensus then
		HUD.nextCensus = now + 1000
		refresh()
	end

	HUD.textMgr = HUD.textMgr or getTextManager()
	if not HUD.textMgr then return end

	local x, y = 20, 120
	for i = 1, LINE_COUNT do
		local line = HUD.lines[i]
		if line and line ~= "" then
			local cy = y + (16 * (i - 1))
			HUD.textMgr:DrawString(UIFont.Small, x + 1, cy + 1, line, 0.0, 0.0, 0.0, 0.6)
			HUD.textMgr:DrawString(UIFont.Small, x, cy, line, 1.0, 0.85, 0.3, 1.0)
		end
	end
end

Events.OnPreUIDraw.Add(draw)
