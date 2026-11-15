describe("LiveCharacter", function()
	local dkjson = require "dkjson"
	local sampleFile = io.open("../spec/System/SampleCharacter.json", "r")
	local sampleText = sampleFile:read("*a")
	sampleFile:close()

	local function sampleCharacter()
		return dkjson.decode(sampleText).character
	end

	local realApi, realGetTime, realLogPath
	local now

	before_each(function()
		newBuild()
		realApi = main.api
		realGetTime = GetTime
		realLogPath = main.clientLogPath
		main.clientLogPath = "/nonexistent/Client.txt"
		now = 1000
		_G.GetTime = function()
			return now
		end
	end)

	after_each(function()
		main.api = realApi
		_G.GetTime = realGetTime
		main.clientLogPath = realLogPath
	end)

	local function stubApi(response)
		local calls = 0
		main.api = {
			DownloadCharacter = function(_, realm, name, callback)
				calls = calls + 1
				callback(response.data, response.errMsg, response.retryTime)
			end,
		}
		return function()
			return calls
		end
	end

	it("builds a live comparison entry from the character", function()
		local live = build.liveCharacter
		live:Link("pc", "testCharacter")
		live:ApplyCharacter(sampleCharacter())

		assert.is_true(live.entry.isLive)
		assert.are.equals("Live: testCharacter", live.entry.label)
		assert.are.equals(99, live.entry.characterLevel)
		assert.is_true(live.entry.spec:CountAllocNodes() > 0)
		assert.is_true(#live.entry.skillsTab.socketGroupList > 0)
		assert.is_not_nil(live.entry.calcsTab.mainOutput)
		assert.are.equals(live.entry, build.compareTab.compareEntries[1])
	end)

	it("replaces the live comparison entry on refresh", function()
		local live = build.liveCharacter
		live:Link("pc", "testCharacter")
		live:ApplyCharacter(sampleCharacter())
		live:ApplyCharacter(sampleCharacter())

		assert.are.equals(1, #build.compareTab.compareEntries)
		assert.are.equals(live.entry, build.compareTab.compareEntries[1])
	end)

	it("removes the live comparison entry when unlinked", function()
		local live = build.liveCharacter
		live:Link("pc", "testCharacter")
		live:ApplyCharacter(sampleCharacter())
		live:Unlink()

		assert.are.equals(0, #build.compareTab.compareEntries)
		assert.is_false(live:IsLinked())
	end)

	it("counts plan progress against the build's tree", function()
		build.importTab:ImportPassiveTreeAndJewels(sampleCharacter(), true)
		local live = build.liveCharacter
		live:Link("pc", "testCharacter")
		live:ApplyCharacter(sampleCharacter())

		local reached, planned, offPlan = live:GetProgress(build.spec)
		assert.is_true(planned > 0)
		assert.are.equals(planned, reached)
		assert.are.equals(0, offPlan)

		local removedId
		for nodeId, node in pairs(build.spec.allocNodes) do
			local allocatedNeighbours = 0
			for _, linkedNode in ipairs(node.linked) do
				if linkedNode.alloc then
					allocatedNeighbours = allocatedNeighbours + 1
				end
			end
			if node.type == "Normal" and allocatedNeighbours == 1 then
				removedId = nodeId
				break
			end
		end
		build.spec:DeallocNode(build.spec.nodes[removedId])
		reached, planned, offPlan = live:GetProgress(build.spec)
		assert.are.equals(planned, reached)
		assert.is_true(offPlan > 0)
	end)

	it("fetches on link and keeps a fallback refresh without a game log", function()
		local calls = stubApi({ data = { character = sampleCharacter() } })
		local live = build.liveCharacter
		live:Link("pc", "testCharacter")
		live:OnFrame()

		assert.are.equals(1, calls())
		assert.is_not_nil(live.entry)
		assert.are.equals(now + 60000, live.nextFetchAt)
	end)

	it("retries after the rate limit window", function()
		stubApi({ errMsg = "Response code: 429", retryTime = os.time() + 5 })
		local live = build.liveCharacter
		live:Link("pc", "testCharacter")
		live:OnFrame()

		assert.are.equals("Rate limited", live.errMsg)
		assert.is_true(live.nextFetchAt >= now + 4000)
	end)

	it("refetches after a zone change in the game log", function()
		local logPath = os.tmpname()
		local file = io.open(logPath, "wb")
		file:write("start\n")
		file:close()
		main.clientLogPath = logPath

		local calls = stubApi({ data = { character = sampleCharacter() } })
		local live = build.liveCharacter
		live:Link("pc", "testCharacter")
		live:OnFrame()
		assert.are.equals(1, calls())
		assert.is_nil(live.nextFetchAt)

		file = io.open(logPath, "ab")
		file:write("2026/11/15 09:20:37 266440343 cffb06be [INFO Client 30008] : You have entered Spider Lair.\n")
		file:close()
		now = now + 1000
		live:OnFrame()
		assert.are.equals(1, calls())
		now = now + 3000
		live:OnFrame()
		assert.are.equals(2, calls())
		os.remove(logPath)
	end)

	it("keeps a suspended coroutine while linked so the engine runs frames in the background", function()
		local live = build.liveCharacter
		live:Link("pc", "testCharacter")
		local keepAwake = live.keepAwake
		assert.are.equals("suspended", coroutine.status(keepAwake))
		assert.is_true(coroutine._list()[keepAwake])

		live:Unlink()
		assert.are.equals("dead", coroutine.status(keepAwake))
		assert.is_nil(live.keepAwake)
	end)

	it("stops the background coroutine when the build closes", function()
		local live = build.liveCharacter
		live:Link("pc", "testCharacter")
		local keepAwake = live.keepAwake
		build:Shutdown()
		assert.are.equals("dead", coroutine.status(keepAwake))
	end)

	it("launches the fetch from the main thread", function()
		local inCoroutine
		main.api = {
			DownloadCharacter = function()
				local co, isMain = coroutine.running()
				inCoroutine = co ~= nil and not isMain
			end,
		}
		build.liveCharacter:Link("pc", "testCharacter")
		build.liveCharacter:OnFrame()
		assert.is_false(inCoroutine)
	end)

	it("saves and restores the linked character with the build", function()
		stubApi({ errMsg = "offline" })
		build.liveCharacter:Link("pc", "testCharacter")
		local xmlText = build:SaveDB("code")
		loadBuildFromXML(xmlText)

		assert.is_true(build.liveCharacter:IsLinked())
		assert.are.equals("testCharacter", build.liveCharacter.name)
		assert.are.equals("pc", build.liveCharacter.realm)
	end)
end)
