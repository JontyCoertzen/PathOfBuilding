describe("ClientLogWatcher", function()
	local logPath
	local zoneLine = "2026/11/15 09:20:30 266433750 cffb06be [INFO Client 30008] : You have entered Stately Hideout.\n"
	local otherLine = "2026/11/15 09:20:29 266432343 1186a803 [DEBUG Client 30008] Generating level 60 area \"HideoutCourts\" with seed 1\n"

	local function writeLog(text, mode)
		local file = io.open(logPath, mode)
		file:write(text)
		file:close()
	end

	before_each(function()
		logPath = os.tmpname()
		writeLog(zoneLine, "wb")
	end)

	after_each(function()
		os.remove(logPath)
	end)

	it("ignores zone changes already in the log when first polled", function()
		local watcher = new("ClientLogWatcher"):ClientLogWatcher(logPath)
		assert.is_false(watcher:Poll())
		assert.is_true(watcher:IsAvailable())
	end)

	it("reports a zone change appended after the first poll", function()
		local watcher = new("ClientLogWatcher"):ClientLogWatcher(logPath)
		watcher:Poll()
		writeLog(zoneLine, "ab")
		assert.is_true(watcher:Poll())
		assert.is_false(watcher:Poll())
	end)

	it("does not report lines that are not zone changes", function()
		local watcher = new("ClientLogWatcher"):ClientLogWatcher(logPath)
		watcher:Poll()
		writeLog(otherLine, "ab")
		assert.is_false(watcher:Poll())
	end)

	it("waits for a partially written line to finish", function()
		local watcher = new("ClientLogWatcher"):ClientLogWatcher(logPath)
		watcher:Poll()
		local partial = zoneLine:sub(1, 70)
		local rest = zoneLine:sub(71)
		writeLog(partial, "ab")
		assert.is_false(watcher:Poll())
		writeLog(rest, "ab")
		assert.is_true(watcher:Poll())
	end)

	it("starts again from the end when the log is truncated", function()
		local watcher = new("ClientLogWatcher"):ClientLogWatcher(logPath)
		watcher:Poll()
		writeLog("", "wb")
		assert.is_false(watcher:Poll())
		writeLog(zoneLine, "ab")
		assert.is_true(watcher:Poll())
	end)

	it("is unavailable when the log does not exist", function()
		local watcher = new("ClientLogWatcher"):ClientLogWatcher(logPath .. ".missing")
		assert.is_false(watcher:Poll())
		assert.is_false(watcher:IsAvailable())
	end)
end)
