-- Path of Building
--
-- Class: Client Log Watcher
-- Tails the game client's Client.txt and reports when the player has changed zones.
--

---@class ClientLogWatcher
local ClientLogWatcherClass = newClass("ClientLogWatcher")

local defaultPaths = {
	"C:/Program Files (x86)/Grinding Gear Games/Path of Exile/logs/Client.txt",
	"C:/Program Files (x86)/Steam/steamapps/common/Path of Exile/logs/Client.txt",
	"C:/Program Files/Epic Games/PathOfExile/logs/Client.txt",
}

local zoneEnteredMarker = "] : You have entered "

local function findDefaultPath()
	for _, path in ipairs(defaultPaths) do
		local file = io.open(path, "rb")
		if file then
			file:close()
			return path
		end
	end
end

function ClientLogWatcherClass:ClientLogWatcher(path)
	self.path = path or findDefaultPath()
	self.offset = nil
	return self
end

function ClientLogWatcherClass:IsAvailable()
	return self.offset ~= nil
end

-- Returns true when a zone change was logged since the previous poll.
-- The first successful poll only records the end of the file, so history is ignored.
function ClientLogWatcherClass:Poll()
	local file = self.path and io.open(self.path, "rb")
	if not file then
		self.offset = nil
		return false
	end
	local size = file:seek("end")
	if not self.offset or size < self.offset then
		self.offset = size
		file:close()
		return false
	end
	if size == self.offset then
		file:close()
		return false
	end
	file:seek("set", self.offset)
	local chunk = file:read(size - self.offset)
	file:close()
	local lastNewline = chunk:match(".*()\n")
	if not lastNewline then
		return false
	end
	self.offset = self.offset + lastNewline
	local completeLines = chunk:sub(1, lastNewline)
	return completeLines:find(zoneEnteredMarker, 1, true) ~= nil
end
