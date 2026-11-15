-- Path of Building
--
-- Class: Live Character
-- Keeps a comparison copy of an in-game character, refreshed from the account API after each zone change.
--
local m_max = math.max
local m_floor = math.floor
local s_format = string.format

---@class LiveCharacter
local LiveCharacterClass = newClass("LiveCharacter")

local LOG_POLL_INTERVAL_MS = 1000
-- The server saves the character on zone change; fetching immediately can return the previous state.
local SAVE_DELAY_MS = 3000
local FALLBACK_REFRESH_MS = 60000

local blankBuildXML = [[<?xml version="1.0" encoding="UTF-8"?>
<PathOfBuilding><Build level="1" targetVersion="3_0" mainSocketGroup="1"/></PathOfBuilding>]]

function LiveCharacterClass:LiveCharacter(build)
	self.build = build
	self.realm = nil
	self.name = nil
	self.entry = nil
	self.level = nil
	self.lastUpdate = nil
	self.loading = false
	self.errMsg = nil
	self.nextFetchAt = nil
	self.nextLogPollAt = 0
	self.watcher = nil
	return self
end

function LiveCharacterClass:Load(xml, fileName)
	if xml.attrib.realm and xml.attrib.name then
		self:Link(xml.attrib.realm, xml.attrib.name)
	end
end

function LiveCharacterClass:Save(xml)
	xml.attrib = {
		realm = self.realm,
		name = self.name,
	}
end

function LiveCharacterClass:IsLinked()
	return self.name ~= nil
end

function LiveCharacterClass:Link(realm, name)
	self.realm = realm
	self.name = name
	self.entry = nil
	self.level = nil
	self.lastUpdate = nil
	self.errMsg = nil
	self.watcher = new("ClientLogWatcher"):ClientLogWatcher(main.clientLogPath)
	self.nextFetchAt = GetTime()
	self:StartKeepAwake()
end

function LiveCharacterClass:Unlink()
	self.realm = nil
	self.name = nil
	self.entry = nil
	self.watcher = nil
	self.nextFetchAt = nil
	self:StopKeepAwake()
	self.build.compareTab:SetLiveEntry(nil)
end

function LiveCharacterClass:RefreshNow()
	self.nextFetchAt = GetTime()
end

-- The engine skips frames while the window is unfocused unless a coroutine is suspended.
-- LaunchSubScript reads the main thread's stack, so the fetch itself must not run inside the coroutine.
function LiveCharacterClass:StartKeepAwake()
	if self.keepAwake then
		return
	end
	self.keepAwake = coroutine.create(function()
		while self.keepAwake do
			coroutine.yield()
		end
	end)
	coroutine.resume(self.keepAwake)
end

function LiveCharacterClass:StopKeepAwake()
	local keepAwake = self.keepAwake
	self.keepAwake = nil
	if keepAwake then
		coroutine.resume(keepAwake)
	end
end

function LiveCharacterClass:OnFrame()
	if not self.name then
		return
	end
	if main.clientLogPath and main.clientLogPath ~= self.watcher.path then
		self.watcher = new("ClientLogWatcher"):ClientLogWatcher(main.clientLogPath)
	end
	local now = GetTime()
	if now >= self.nextLogPollAt then
		self.nextLogPollAt = now + LOG_POLL_INTERVAL_MS
		if self.watcher:Poll() then
			self.nextFetchAt = now + SAVE_DELAY_MS
		end
	end
	if self.nextFetchAt and now >= self.nextFetchAt and not self.loading then
		self:Fetch()
	end
end

function LiveCharacterClass:Fetch()
	self.loading = true
	self.nextFetchAt = nil
	local realm, name = self.realm, self.name
	main.api:DownloadCharacter(realm, name, function(data, errMsg, retryTime)
		self.loading = false
		if realm ~= self.realm or name ~= self.name then
			return
		end
		if data and data.character then
			self.errMsg = nil
			self:ApplyCharacter(data.character)
		elseif retryTime then
			self.errMsg = "Rate limited"
			local waitSeconds = m_max(retryTime - os.time(), 1)
			self.nextFetchAt = GetTime() + waitSeconds * 1000
			return
		else
			self.errMsg = errMsg or "Could not fetch character"
		end
		if not self.watcher:IsAvailable() then
			self.nextFetchAt = GetTime() + FALLBACK_REFRESH_MS
		end
	end)
end

function LiveCharacterClass:ApplyCharacter(charData)
	local entry = new("CompareEntry"):CompareEntry(blankBuildXML, "Live: " .. charData.name)
	entry.isLive = true
	local importer = new("ImportTab"):ImportTab(entry)
	importer:ImportItemsAndSkills(charData, true, true, false)
	importer:ImportPassiveTreeAndJewels(charData, true)
	entry:Rebuild()
	if self.build.spec then
		self.build.spec:SetWindowTitleWithBuildClass()
	end
	self.entry = entry
	self.level = charData.level
	self.lastUpdate = os.time()
	self.build.compareTab:SetLiveEntry(entry)
end

local function isStartNode(node)
	return node.type == "ClassStart" or node.type == "AscendClassStart"
end

-- Returns how many of the plan's allocated nodes the live character has, the plan's total, and the live character's nodes outside the plan.
function LiveCharacterClass:GetProgress(planSpec)
	local liveSpec = self.entry and self.entry.spec
	if not liveSpec then
		return nil
	end
	local reached, planned, offPlan = 0, 0, 0
	for nodeId, node in pairs(planSpec.allocNodes) do
		if not isStartNode(node) then
			planned = planned + 1
			if liveSpec.allocNodes[nodeId] then
				reached = reached + 1
			end
		end
	end
	for nodeId, node in pairs(liveSpec.allocNodes) do
		if not isStartNode(node) and not planSpec.allocNodes[nodeId] then
			offPlan = offPlan + 1
		end
	end
	return reached, planned, offPlan
end

local function formatAge(seconds)
	if seconds < 60 then
		return s_format("%ds", seconds)
	end
	return s_format("%dm", m_floor(seconds / 60))
end

function LiveCharacterClass:GetStatus(planSpec)
	if not self.name then
		return nil
	end
	local parts = { "^7Live: " .. self.name }
	if self.entry then
		local reached, planned, offPlan = self:GetProgress(planSpec)
		local age = formatAge(os.time() - self.lastUpdate)
		local levelText = s_format("Level %d", self.level)
		local planText = s_format("%d/%d plan nodes", reached, planned)
		local offPlanColor = offPlan > 0 and colorCodes.NEGATIVE or ""
		local offPlanText = s_format("%s%d off-plan^7", offPlanColor, offPlan)
		table.insert(parts, levelText)
		table.insert(parts, planText)
		table.insert(parts, offPlanText)
		table.insert(parts, "updated " .. age .. " ago")
	end
	if self.loading then
		table.insert(parts, colorCodes.WARNING .. "Updating...")
	elseif self.errMsg then
		table.insert(parts, colorCodes.NEGATIVE .. self.errMsg)
	end
	return table.concat(parts, ", ")
end
