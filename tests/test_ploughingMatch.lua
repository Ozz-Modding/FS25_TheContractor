-- 169: the show's ploughing match. The plots from the show's scene (their
-- frames and pegs), who gets one and taking one, the lent kit's lock, the
-- time from each ploughman's first run, farmers' rolled scores and their
-- breakdowns, placings and prizes through the real Show, the scorecards,
-- each farm's best, the kit's plough working only its plot, the sync, a
-- save mid-match, a deleted farm and a retired farmer, and picking the kit
-- from the store.
--
-- The real Show, EventDay, PublicEvents, Inbox, calendar, show scene and
-- 168's scoring; the site, signs, crowd, farmers, companies and rewards are
-- faked as tests/test_showLivestock.lua has them. The engine's half (the
-- ground, the path, loading the kit, painting) is the match's ENGINE table,
-- swapped for a fake that reads the test's own ground and path.

local SHOW_FIELD = 5
local HOST_ID = 7
local SHOW_DAY = 51

-- The engine's half, faked: the ground's what world.ploughed[number] says
-- (a function of a cell's u, v and whether it's inside the plot; nothing
-- before), the path's
-- world.paths[tractorId] taken a sample at a time, the kit spawned at once
-- as vehicles with uniqueIds, and the game clock's world.minute.
local function makeEngine(world)
    world.ploughed, world.paths, world.painted, world.deleted, world.spawned = {}, {}, {}, {}, {}
    world.minute = TCPloughMatch.toGameMinute(SHOW_DAY, 0)
    local engine = {
        getGameMinute = function() return world.minute end,
        readGround = function(frame, grid, key)
            local ploughed = world.ploughed[frame.number]
            for _, cell in ipairs(grid.cells) do
                cell[key] = key == "ploughed" and ploughed ~= nil and ploughed(cell.u, cell.v, cell.inside) and 1 or 0
            end
        end,
        readAngles = function() return nil end,
        sample = function(vehicleId)
            local path = world.paths[vehicleId]
            return path ~= nil and table.remove(path, 1) or nil
        end,
        spawnKit = function(match, number)
            local ids = {}
            for i, name in ipairs({ "tractor", "plough" }) do
                local vehicle = { uniqueId = string.format("%s%d", name, number) }
                function vehicle:getUniqueId() return self.uniqueId end
                world:register(vehicle)
                table.insert(g_currentMission.vehicleSystem.vehicles, vehicle)
                ids[i] = vehicle.id
            end
            table.insert(world.spawned, number)
            match:onKitSpawned(number, ids[1], ids[2])
        end,
        processSpawnQueue = function() end,
        deleteVehicle = function(vehicleId)
            table.insert(world.deleted, vehicleId)
            local vehicle = world.objects[vehicleId]
            if vehicle ~= nil then
                vehicle.isDeleted = true
            end
        end,
        paintStrips = function(_, frame, from, to, count)
            table.insert(world.painted, { number = frame.number, from = from, to = to, count = count })
        end,
        pickKit = function() return { tractorXml = "tractor.xml", ploughXml = "plough.xml" } end,
    }
    world.engine = engine
    return engine
end

local function setup()
    local world = stubs.install()
    TheContractor = { SaveKey = "TheContractor" }
    Environment = { PERIODS_IN_YEAR = 12 }
    FinanceStats = { statNames = {}, statNameToIndex = {} }
    MoneyType = { LAST_ID = 0, register = function(name) return name end }
    Event = { new = function(mt) return setmetatable({}, mt) end }
    InitEventClass = function() end
    MessageType = { DAY_CHANGED = 1, HOUR_CHANGED = 2, FARMLAND_OWNER_CHANGED = 3 }
    g_messageCenter = { subscribe = function() end, unsubscribeAll = function() end }
    world.events = {}
    g_server = { broadcastEvent = function(_, event) table.insert(world.events, event) end }
    TCMessagePostedEvent = { new = function(message) return { posted = message } end }
    TCMessageRemovedEvent = { new = function(id) return { removed = id } end }
    TheContractorStaff = { scalePay = function(pay) return pay end }
    TheContractorJob = { STATE = { OFFERED = 1, NEGOTIATING = 2 } }
    TheContractorJobGeneration = { JOB_TYPES = {} }
    -- The work area patch's vanilla half: every vehicle refused, so what
    -- the patch lets through is its own.
    WorkArea = { getIsAccessibleAtWorldPosition = function(vehicle, farmId, x, z) return false, farmId, true end }

    world:load("src/util/TCCalendar.lua")
    world:load("src/business/Inbox.lua")
    world:load("src/util/TCAuctionAttendance.lua")
    world:load("src/util/TCADSUsedLots.lua")
    world:load("src/util/TCLotInspections.lua")
    world:load("src/util/TCAuctionLayout.lua")
    world:load("src/util/TCAuctionScene.lua")
    world:load("src/util/TCShowSite.lua")
    world:load("src/util/TCShowScene.lua")
    world:load("src/util/TCVehicleIds.lua")
    world:load("src/util/TCPloughScore.lua")
    world:load("src/util/TCPloughMatch.lua")
    world:load("src/util/TCPloughPlotActivatable.lua")
    world:load("src/business/PublicEvents.lua")
    world:load("src/business/EventDay.lua")
    world:load("src/business/Show.lua")
    world:load("src/business/PloughingMatch.lua")
    world:load("src/events/TCShowEvent.lua")
    world:load("src/events/TCPloughMatchEvent.lua")
    world:load("src/events/TCPloughPlotEvent.lua")

    for month = 1, 12 do
        world.texts["ui_month" .. month] = "Month " .. month
    end
    g_currentMission.environment = {
        currentYear = 1, currentPeriod = 1, currentDayInPeriod = 1, daysPerPeriod = 10,
        plannedDaysPerPeriod = 10, currentMonotonicDay = 1, currentHour = 0,
        daylight = { latitude = 55 },
    }
    world.fields = {}
    g_fieldManager = { getFieldById = function(_, id) return world.fields[id] end }
    local field = { id = SHOW_FIELD, owner = 0 }
    function field:getId() return self.id end
    function field:getOwner() return self.owner end
    function field:getName() return tostring(self.id) end
    function field:getFarmland() return { getId = function() return field.id end } end
    function field:getIndicatorPosition() return 100, 200 end
    world.fields[SHOW_FIELD] = field

    local tc = g_currentMission.TheContractor
    tc.hasResolvedSavedVehicles = true
    world.people = {
        [7] = { id = 7, name = "Tom" }, [8] = { id = 8, name = "Ann" },
        [9] = { id = 9, name = "Bob" }, [10] = { id = 10, name = "Sue" },
    }
    tc.Farmers = {
        getHolder = function() return world.people[HOST_ID] end,
        getPerson = function(_, id) return world.people[id] end,
        getFarmers = function()
            local farmers = {}
            for _, id in ipairs({ 7, 8, 9, 10 }) do
                if world.people[id] ~= nil then
                    table.insert(farmers, world.people[id])
                end
            end
            return farmers
        end,
    }
    world.companies = { [1] = true, [2] = true }
    tc.Company = { hasCompany = function(_, farmId) return world.companies[farmId] == true end }
    tc.RandomEvents = { incidents = {}, getCompanyFarmIds = function() return { 1, 2 } end }
    tc.Inbox = TheContractorInbox.new()

    -- The showground (as the real scene) and five plots in a row west of
    -- it, 35 m with 6 m between, running north-south: they face west,
    -- away from the showground, their near edges at x = 17.5.
    local rect = { cx = 100, cz = 50, angle = 0, halfU = 60, halfV = 30 }
    local entrance = { x = rect.cx + rect.halfU + 10, z = rect.cz }
    world.scene = TCAuctionLayout.getScene(TCAuctionLayout.layOutOpenRect(rect, entrance), entrance, 99)
    world.scene.dressing = "show"
    world.scene.plots = {}
    for i = 1, 5 do
        table.insert(world.scene.plots, { cx = 0, cz = (i - 3) * 41, angle = 0, half = 17.5 })
    end
    world.plan = { mode = "single", showFieldId = SHOW_FIELD, ploughFieldId = SHOW_FIELD, showRect = rect,
        ploughRect = rect, plots = world.scene.plots, entrance = { x = entrance.x, z = entrance.z, distance = 10 } }
    tc.ShowSite = {
        site = nil,
        pickBest = function() return { plan = world.plan, problems = {} } end,
        planOn = function() return { plan = world.plan, problems = {} } end,
        setPlan = function(self, plan) self.site = { plan = plan, dressed = false } end,
        dress = function(self) self.site.dressed = true return "dressed" end,
        paintPenGround = function() return 0 end,
        clear = function(self) self.site = nil return "cleared" end,
    }
    TheContractorAuctionSite = { PREFERRED_LOTS = 120, CLOSE_HOURS = { 17, 18 },
        getFieldRefusal = function() return nil end }
    tc.AuctionSite = {
        site = nil, fieldId = 0, walkways = {},
        getWalkways = function(self) return self.walkways end,
        getScene = function(self) return self.site ~= nil and world.scene or nil end,
        startOpen = function(self, fieldId, dressing, eventId, options)
            self.site = { fieldId = fieldId }
            self.fieldId = fieldId
            world.startOptions = options
        end,
        clear = function(self) self.site, self.fieldId = nil, 0 end,
    }
    tc.AuctionSigns = {
        month = 0, signs = {}, face = nil,
        place = function(self, month, face) self.month, self.signs, self.face = month, { {} }, face end,
        clear = function(self) self.month, self.signs, self.face = 0, {}, nil end,
        describe = function() return "" end,
    }
    TCAuctionCrowd = {
        DEFAULT_PEOPLE = 60, active = nil,
        getUnavailableReason = function() return "none in tests" end,
        getFieldPolygon = function() return {} end,
        getAuctionPeople = function(lotCount) return lotCount end,
        stop = function() end,
    }
    TheContractorFallenTree = { sampleRoads = function() return {} end }

    world.money, world.reputation, world.opinions, world.notices = {}, {}, {}, {}
    g_currentMission.addMoney = function(_, amount, farmId, moneyType)
        table.insert(world.money, { amount = amount, farmId = farmId, moneyType = moneyType })
    end
    tc.Settings = { scaleCost = function(_, amount) return amount * 2 end }
    TCEconomyScale = { scale = function(amount) return amount * 3 end }
    TheContractorGoodNews = { getReputationReward = function(farmId, jobs) return jobs * 10 end }
    tc.Reputation = { addReputation = function(_, farmId, delta)
        table.insert(world.reputation, { farmId = farmId, delta = delta })
    end }
    tc.Relationships = { adjust = function(_, farmId, customerId, delta, reason)
        table.insert(world.opinions, { farmId = farmId, customerId = customerId, delta = delta, reason = reason })
    end }
    world.removedNotices = {}
    tc.Notices = {
        nextId = 1,
        publish = function(self, farmId, text)
            table.insert(world.notices, farmId)
            self.nextId = self.nextId + 1
            return self.nextId - 1
        end,
        remove = function(_, id) table.insert(world.removedNotices, id) end,
    }

    tc.PublicEvents = TheContractorPublicEvents.new()
    tc.Show = TheContractorShow.new()
    tc.Show:register(tc.Inbox)
    tc.PublicEvents:registerKind(tc.Show)
    tc.PloughingMatch = TheContractorPloughingMatch.new()
    tc.PloughingMatch:register(tc.Show)
    -- Every roll in the middle: a skill of 0, no noise, no jitter.
    tc.PloughingMatch.random = function() return 0.5 end
    world.match = tc.PloughingMatch
    world.tc = tc
    world.match.engine = makeEngine(world)
    return world
end

-- The calendar (year 1, ten days a month), as tests/test_show.lua.
local function setDay(day)
    local environment = g_currentMission.environment
    environment.currentMonotonicDay = day
    environment.currentHour = 0
    environment.currentPeriod = math.floor((day - 1) / 10) + 1
    environment.currentDayInPeriod = (day - 1) % 10 + 1
end

local function runToDay(world, day)
    while g_currentMission.environment.currentMonotonicDay < day do
        setDay(g_currentMission.environment.currentMonotonicDay + 1)
        world.tc.Show:onDayChanged()
    end
end

local function setHour(world, hour)
    g_currentMission.environment.currentHour = hour
    world.minute = TCPloughMatch.toGameMinute(SHOW_DAY, hour * 60)
    world.tc.Show:onHourChanged()
end

local function announce(world)
    getWorldTranslation = function(node) return node.x, 0, node.z end
    setDay(21)
    return world.tc.Show:announce(nil, SHOW_DAY, function() return 0 end)
end

-- The show announced and run to its day: the plots out, the kit spawned.
local function showDay(world)
    announce(world)
    runToDay(world, SHOW_DAY)
    setHour(world, 8)
end

local function frameOf(world, number)
    return TCShowScene.getPlotFrames(world.scene)[number]
end

-- A run along a plot at across-position v, a sample a metre (in from its
-- near edge or back), each heading off the line by heading degrees.
local function runSamples(frame, v, reverse, wobble)
    local samples = {}
    for i = 0, frame.size - 1 do
        local u = reverse and frame.size - 1 - i or i
        local offset = wobble ~= nil and wobble(u) or 0
        local x, z = TCPloughScore.toWorld(frame, u + 0.5, v + offset)
        local sign = reverse and -1 or 1
        table.insert(samples, { t = 0, x = x, z = z, hx = frame.dirX * sign, hz = frame.dirZ * sign, speed = 8,
            dir = 1, lowered = true })
    end
    return samples
end

-- A whole plot's path, runs every width metres back and forth, the plough
-- raised to turn outside it between them.
local function plotPath(frame, width, wobble)
    local samples = {}
    local v = -frame.size * 0.5 + width * 0.5
    local reverse = false
    while v < frame.size * 0.5 do
        for _, sample in ipairs(runSamples(frame, v, reverse, wobble)) do
            table.insert(samples, sample)
        end
        local x, z = TCPloughScore.toWorld(frame, -5, v)
        table.insert(samples, { t = 0, x = x, z = z, hx = 1, hz = 0, speed = 5, dir = 1, lowered = false })
        v = v + width
        reverse = not reverse
    end
    return samples
end

-- A plot's run, its samples taken by the server's sampling as the game
-- clock moves on over `minutes`.
local function plough(world, number, samples, minutes)
    local plot = world.match:getPlot(number)
    world.paths[plot.tractorId] = samples
    local step = minutes / #samples
    for _ = 1, #samples do
        world.minute = world.minute + step
        world.match:updateMatch(TheContractorPloughingMatch.SAMPLE_MS)
    end
end

local function placingsOf(world)
    local list = {}
    for _, placing in ipairs(world.tc.Show:getResults().placings) do
        if placing.titleKey == TheContractorPloughingMatch.TITLE_KEY then
            table.insert(list, placing)
        end
    end
    return list
end

local function lastEvent(world, class)
    for i = #world.events, 1, -1 do
        if getmetatable(world.events[i]) == getmetatable(class.emptyNew()) then
            return world.events[i]
        end
    end
    return nil
end

-- The plots --------------------------------------------------------------------------------------

test("the plots from the scene face across their row, away from the showground, with pegs at the corners and a start peg", function()
    local world = setup()
    local frames = TCShowScene.getPlotFrames(world.scene)
    assertEquals(#frames, 5)
    for i, frame in ipairs(frames) do
        assertEquals(frame.number, i)
        assertNear(frame.dirX, -1, 0.0001)
        assertNear(frame.dirZ, 0, 0.0001)
        assertNear(frame.x, 17.5, 0.0001, "near edge on the showground's side")
        assertNear(frame.z, (i - 3) * 41, 0.0001)
        assertEquals(frame.size, 35)
    end
    -- The start peg outside the near edge, left of the middle.
    local x, z = TCShowScene.getStartPeg(frames[3])
    local u, v = TCPloughScore.toLocal(frames[3], x, z)
    assertNear(u, TCShowScene.PLOT.startPegU, 0.0001)
    assertNear(v, TCShowScene.PLOT.startPegV, 0.0001)

    local props = TCShowScene.layOut(world.scene).props
    local pegs, starts = 0, 0
    for _, prop in ipairs(props) do
        if prop.kind == "plotPeg" then
            pegs = pegs + 1
        elseif prop.kind == "plotStartPeg" then
            starts = starts + 1
        end
    end
    assertEquals(pegs, 20)
    assertEquals(starts, 5)

    -- A scene with no plots (an auction's) has none.
    world.scene.plots = nil
    assertEquals(#TCShowScene.getPlotFrames(world.scene), 0)
end)

test("the show sets the plots out on its scene; each company can have one, farmers fill the rest, each with its kit", function()
    local world = setup()
    showDay(world)
    assertEquals(world.startOptions.plots, world.plan.plots, "the plan's plots go on the scene")
    local match = world.match
    assertTrue(match.setOut)
    assertEquals(#match.plots, 5)
    local S = TCPloughMatch.STATE
    assertEquals(match.plots[1].state, S.OPEN)
    assertEquals(match.plots[2].state, S.OPEN)
    local farmers = {}
    for i = 3, 5 do
        assertEquals(match.plots[i].state, S.FARMER)
        assertTrue(match.plots[i].farmerId > 0)
        farmers[match.plots[i].farmerId] = true
    end
    local count = 0
    for _ in pairs(farmers) do
        count = count + 1
    end
    assertEquals(count, 3, "three different farmers")
    assertEquals(#world.spawned, 5, "every plot's kit")
    for _, plot in ipairs(match.plots) do
        assertTrue(plot.tractorId ~= nil and plot.ploughId ~= nil)
    end
    -- Pure: more companies than plots leaves no farmers.
    local states = TCPloughMatch.planPlots(4, 6)
    for _, state in ipairs(states) do
        assertEquals(state, S.OPEN)
    end
    assertEquals(#TCPloughMatch.planPlots(4, 0), 4)
    assertEquals(TCPloughMatch.planPlots(4, 0)[1], S.FARMER)
end)

test("taking a plot: a company's, one a farm, a free one, until the match is over", function()
    local world = setup()
    local match = world.match
    local P = TCPloughMatch.PROBLEM
    assertEquals(match:getTakeProblem(1, 1), P.noMatch, "nothing's out before the day")
    showDay(world)
    assertEquals(match:getTakeProblem(1, 3), P.noCompany)
    assertEquals(match:getTakeProblem(3, 1), P.taken, "a farmer's")
    assertEquals(match:takePlot(1, 1), nil)
    assertEquals(match.plots[1].farmId, 1)
    assertEquals(match.plots[1].state, TCPloughMatch.STATE.TAKEN)
    assertEquals(match:getFarmPlot(1), match.plots[1])
    assertEquals(match:getTakeProblem(2, 1), P.hasPlot)
    assertEquals(match:getTakeProblem(1, 2), P.taken)
    assertEquals(world.notices[#world.notices], 1, "the farm's told")

    -- A client's request is for its own farm only.
    local connection = { getIsServer = function() return false end }
    g_currentMission.connectionsToPlayer = { [connection] = { farmId = 1 } }
    local request = TCPloughPlotEvent.new(TCPloughPlotEvent.TAKE, 2, 2)
    local stream = world:newStream()
    request:writeStream(stream)
    TCPloughPlotEvent.emptyNew():readStream(stream, connection)
    assertEquals(match.plots[2].farmId, 0, "farm 1's player can't take one for farm 2")
    g_currentMission.connectionsToPlayer = { [connection] = { farmId = 2 } }
    stream = world:newStream()
    request:writeStream(stream)
    TCPloughPlotEvent.emptyNew():readStream(stream, connection)
    assertEquals(match.plots[2].farmId, 2)

    -- The prompt at the start peg.
    assertEquals(TCPloughPlotActivatable.getAction(match, 2, 1), nil, "farm 1 has its own")
    local x, z = TCShowScene.getStartPeg(frameOf(world, 1))
    assertEquals(TCPloughPlotActivatable.findNearest(match, x + 1, z), 1)
    assertEquals(TCPloughPlotActivatable.findNearest(match, x + 10, z), nil)

    match.plots[3].state = TCPloughMatch.STATE.OPEN
    world.companies[3] = true
    assertEquals(match:getTakeProblem(3, 3), nil, "a free plot, before 15:00")
    match:endMatch()
    assertEquals(match:getTakeProblem(3, 3), P.closed, "not once it's over")
end)

-- The kit's lock ------------------------------------------------------------------------------------

test("the kit: nobody before 11:00, then only the plot's farm until its run's finished", function()
    local world = setup()
    local match = world.match
    local L = TCPloughMatch.LOCK
    showDay(world)
    match:takePlot(1, 1)
    local plot1, plot2, plot3 = match.plots[1], match.plots[2], match.plots[3]

    local locked = match:getLockedKit(1)
    assertEquals(locked[plot1.tractorId], L.NOT_STARTED, "farm 1's own before 11:00")
    assertEquals(locked[plot1.ploughId], L.NOT_STARTED, "and its plough")
    assertEquals(TCPloughPlotActivatable.getAction(match, 1, 1), nil, "nothing to finish yet")

    setHour(world, 11)
    assertTrue(match.started)
    locked = match:getLockedKit(1)
    assertEquals(locked[plot1.tractorId], nil, "farm 1 can drive its own")
    assertEquals(locked[plot1.ploughId], nil)
    assertEquals(locked[plot2.tractorId], L.FREE, "a free plot's")
    assertEquals(locked[plot3.tractorId], L.NOT_YOURS, "a farmer's")
    assertEquals(match:getLockedKit(2)[plot1.tractorId], L.NOT_YOURS, "farm 2 can't drive farm 1's")
    assertEquals(TCPloughPlotActivatable.getAction(match, 1, 1), TCPloughPlotActivatable.ACTION.FINISH)

    -- Farm 2 takes plot 2 late: its kit's ready at once.
    match:takePlot(2, 2)
    assertEquals(match:getLockedKit(2)[plot2.tractorId], nil)
    assertEquals(match:getLockedKit(1)[plot2.tractorId], L.NOT_YOURS, "and nobody else's")

    -- Finished: locked again, for its own farm too.
    assertEquals(match:finishPlot(1, 2), TCPloughMatch.PROBLEM.notYours)
    assertEquals(match:finishPlot(1, 1), nil)
    assertEquals(match:getLockedKit(1)[plot1.tractorId], L.FINISHED)
    assertEquals(match:finishPlot(1, 1), TCPloughMatch.PROBLEM.finished)

    -- 15:00: everyone's done.
    setHour(world, 15)
    assertEquals(match:getLockedKit(2)[plot2.tractorId], L.FINISHED)

    -- The kit's plough works only its own plot and its margin.
    local plough = world.objects[plot2.ploughId]
    local frame = frameOf(world, 2)
    local x, z = TCPloughScore.toWorld(frame, 10, 0)
    assertEquals(WorkArea.getIsAccessibleAtWorldPosition(plough, 1, x, z), true)
    x, z = TCPloughScore.toWorld(frame, -3, 0)
    assertEquals(WorkArea.getIsAccessibleAtWorldPosition(plough, 1, x, z), true, "in the margin")
    x, z = TCPloughScore.toWorld(frame, 10, 25)
    assertEquals(WorkArea.getIsAccessibleAtWorldPosition(plough, 1, x, z), false, "past its margin")
    x, z = TCPloughScore.toWorld(frameOf(world, 1), 10, 0)
    assertEquals(WorkArea.getIsAccessibleAtWorldPosition(plough, 1, x, z), false, "a neighbour's plot")
    local other = { id = 999 }
    assertEquals(WorkArea.getIsAccessibleAtWorldPosition(other, 1, x, z), false, "anything else is vanilla's")
end)

-- Time ------------------------------------------------------------------------------------------------

test("the time counts from a ploughman's first run, and going over the limit costs marks", function()
    local world = setup()
    local match = world.match
    showDay(world)
    match:takePlot(1, 1)
    match:takePlot(2, 2)
    setHour(world, 11)
    world.ploughed[1] = function(_, _, inside) return inside end
    world.ploughed[2] = function(_, _, inside) return inside end
    local frame1, frame2 = frameOf(world, 1), frameOf(world, 2)

    -- Farm 1 waits an hour, then ploughs well in 150 minutes.
    world.minute = world.minute + 60
    plough(world, 1, plotPath(frame1, 1.4), 150)
    local run1 = match.runs[1]
    assertNear(TCPloughMatch.getMinutesUsed(run1.firstMinute, run1.lastMinute), 150, 1, "not the hour it waited")
    match:finishPlot(1, 1)
    assertNear(match.runs[1].result.total, 100, 0.01)
    assertEquals(match.runs[1].result.parts.coverage.max, TCPloughScore.RULES.weights.coverage)

    -- Farm 2 ploughs as well but takes 200: 20 over.
    plough(world, 2, plotPath(frame2, 1.4), 200)
    match:finishPlot(2, 2)
    local over = 200 - TCPloughScore.RULES.timeLimitMinutes
    assertNear(match.runs[2].result.total, 100 - over * TCPloughScore.RULES.minutePenalty, 0.5)
end)

-- Farmers -----------------------------------------------------------------------------------------------

test("a farmer's score comes from their hidden skill, kept, with a breakdown that adds up to it", function()
    local world = setup()
    local R = TCPloughMatch.FARMER_SCORE
    assertEquals(TCPloughMatch.rollFarmerScore(1, function() return 1 end), math.min(R.max, R.base + R.spread + R.noise))
    assertEquals(TCPloughMatch.rollFarmerScore(-1, function() return 0 end), R.base - R.spread - R.noise)
    assertTrue(TCPloughMatch.rollFarmerScore(0.8, function() return 0.5 end) >
        TCPloughMatch.rollFarmerScore(-0.8, function() return 0.5 end), "the better ploughman scores higher")
    local minutes = TCPloughMatch.rollFarmerMinutes(function() return 0.99 end)
    assertTrue(minutes <= TCPloughScore.RULES.timeLimitMinutes, "a farmer finishes in time")

    -- The breakdown's marks come to the total, each within its part.
    local rolls = { 0.1, 0.9, 0.3, 0.7, 0.5, 0.2, 0.8 }
    local i = 0
    local card = TCPloughMatch.makeBreakdown(72, 160, function()
        i = i + 1
        return rolls[(i - 1) % #rolls + 1]
    end, TCPloughScore.RULES.weights, TCPloughScore.PARTS)
    local marks, max = 0, 0
    for _, name in ipairs(TCPloughScore.PARTS) do
        local part = card.parts[name]
        assertTrue(part.marks >= 0 and part.marks <= part.max, name)
        marks, max = marks + part.marks, max + part.max
    end
    assertNear(marks / max * 100, 72, 0.01)
    assertNear(card.total, 72, 0.01)
    assertEquals(card.minutes, 160)

    -- In the match: rolled when the plots are set out, the skill kept.
    showDay(world)
    local match = world.match
    local farmerId = match.plots[3].farmerId
    local skill = match.skills[farmerId]
    assertEquals(skill, 0, "the middle roll")
    assertNear(match.runs[3].result.total, R.base, 0.01)
    match.skills[farmerId] = 0.9
    assertEquals(match:getSkill(farmerId), 0.9, "rolled once and kept")
end)

test("farmers' plots are painted ploughed as the hours go, and all of it by the end", function()
    local world = setup()
    local match = world.match
    showDay(world)
    setHour(world, 11)
    local minutes = match.runs[3].farmerMinutes
    local strips = math.ceil(35 / TCPloughMatch.PLOUGH_WIDTH)
    world.minute = world.minute + minutes / 2
    match:paintFarmers(false)
    local halfway = nil
    for _, paint in ipairs(world.painted) do
        if paint.number == 3 then
            halfway = paint
        end
    end
    assertEquals(halfway.from, 1)
    assertEquals(halfway.to, math.floor(strips / 2 + 0.0001))
    assertEquals(halfway.count, strips)
    setHour(world, 15)
    assertEquals(match.runs[3].painted, strips, "all of it")
    assertEquals(match.runs[1].painted, 0, "a player's plot isn't painted")
end)

-- Results ------------------------------------------------------------------------------------------------

test("results at 16:00: every run ranked against the farmers, the top three paid, scorecards and bests", function()
    local world = setup()
    local match = world.match
    showDay(world)
    match:takePlot(1, 1)
    setHour(world, 11)
    -- Farm 1 ploughs it all, straight; farm 2 comes late and leaves half.
    world.ploughed[1] = function(_, _, inside) return inside end
    plough(world, 1, plotPath(frameOf(world, 1), 1.4), 150)
    match:takePlot(2, 2)
    world.ploughed[2] = function(_, v, inside) return inside and v < 0 end
    local half = {}
    for _, sample in ipairs(plotPath(frameOf(world, 2), 1.4)) do
        local _, v = TCPloughScore.toLocal(frameOf(world, 2), sample.x, sample.z)
        if v < 0 then
            table.insert(half, sample)
        end
    end
    plough(world, 2, half, 90)
    setHour(world, 15)
    assertTrue(match.over)
    assertEquals(match.plots[2].state, TCPloughMatch.STATE.FINISHED, "scored at 15:00")
    assertTrue(match.runs[2].result.total < 80, "half a plot")

    -- No scorecards for anyone before the results.
    assertEquals(match.plots[1].card, nil)
    setHour(world, 16)
    assertTrue(match.resultsGiven)
    local placings = placingsOf(world)
    assertEquals(#placings, 3)
    assertEquals(placings[1].farmId, 1)
    assertEquals(placings[1].placing, 1)
    -- The farmers at 80 each, by plot number.
    assertEquals(placings[2].farmerId, match.plots[3].farmerId)
    assertEquals(placings[3].farmerId, match.plots[4].farmerId)
    -- Paid: the match's own prize scaled (x2 settings, x3 EconomyScale).
    assertEquals(placings[1].paid, TCPloughMatch.PRIZES[1] * 6)
    assertEquals(world.money[1].farmId, 1)
    assertEquals(world.reputation[1].delta, TCPloughMatch.REPUTATION[1] * 10)
    assertEquals(world.opinions[1].customerId, HOST_ID)
    assertEquals(world.opinions[1].delta, TCPloughMatch.OPINION[1])

    -- Every plot's card, farmers' too, placed or not.
    assertEquals(match.plots[1].card.placing, 1)
    assertEquals(match.plots[2].card.placing, nil)
    assertNear(match.plots[3].card.total, 80, 0.01)
    assertEquals(match.plots[5].card.placing, nil)

    -- Each ploughing farm's scorecard by inbox.
    local cards = {}
    for _, message in ipairs(world.tc.Inbox:getMessages(1)) do
        if message.titleKey == "tc_ploughMatch_cardTitle" then
            table.insert(cards, message)
        end
    end
    assertEquals(#cards, 1)
    assertEquals(cards[1].args[1], "1")
    assertEquals(cards[1].args[2], "$l10n_" .. TheContractorShow.getPlacingNameKey(1))
    assertEquals(cards[1].args[5], string.format("%.1f/%d", match.plots[1].card.parts.coverage.marks,
        TCPloughScore.RULES.weights.coverage))
    assertEquals(cards[1].args[8], "-", "no furrow angle on this map")
    local farm2Cards = 0
    for _, message in ipairs(world.tc.Inbox:getMessages(2)) do
        if message.titleKey == "tc_ploughMatch_cardTitle" then
            farm2Cards = farm2Cards + 1
            assertEquals(message.args[2], "$l10n_tc_ploughMatch_unplaced")
        end
    end
    assertEquals(farm2Cards, 1)

    -- Bests.
    assertNear(match:getBest(1).bestScore, match.plots[1].card.total, 0.0001)
    assertEquals(match:getBest(1).wins, 1)
    assertEquals(match:getBest(2).wins, 0)
    assertEquals(match:getBest(2).matches, 1)

    -- The kit's taken away, and the match's notices.
    assertEquals(#world.deleted, 10)
    for _, plot in ipairs(match.plots) do
        assertEquals(plot.tractorId, nil)
    end
    assertTrue(#world.removedNotices > 0)
end)

test("placings: highest first, ties by plot, three placed, nothing for a run that scored nothing", function()
    setup()
    local ranked = TCPloughMatch.rankPlots({
        { score = 70, number = 4 }, { score = 90, number = 2 }, { score = 70, number = 1 },
        { score = 60, number = 3 },
    })
    assertEquals(ranked[1].number, 2)
    assertEquals(ranked[2].number, 1, "a tie to the lower plot")
    assertEquals(ranked[3].number, 4)
    assertEquals(ranked[3].placing, 3)
    assertEquals(ranked[4].placing, nil)
    local zero = TCPloughMatch.rankPlots({ { score = 50, number = 1 }, { score = 0, number = 2 } })
    assertEquals(zero[2].placing, nil, "an untouched plot")

    local best = {}
    TCPloughMatch.addBest(best, 1, 80, 2)
    TCPloughMatch.addBest(best, 1, 70, 1)
    assertEquals(best[1].bestScore, 80)
    assertEquals(best[1].wins, 1)
    assertEquals(best[1].matches, 2)
end)

-- Sync and save --------------------------------------------------------------------------------------

test("every machine gets the plots and the kit's ids, never a score before the results or a farmer's skill", function()
    local world = setup()
    local match = world.match
    showDay(world)
    match:takePlot(1, 1)
    setHour(world, 11)
    world.ploughed[1] = function(_, _, inside) return inside end
    plough(world, 1, plotPath(frameOf(world, 1), 1.4), 150)
    match:finishPlot(1, 1)

    local function toClient()
        local sent = lastEvent(world, TCPloughMatchEvent)
        local stream = world:newStream()
        sent:writeStream(stream)
        local client = TheContractorPloughingMatch.new()
        world.tc.PloughingMatch = client
        local received = TCPloughMatchEvent.emptyNew()
        received:readStream(stream, { getIsServer = function() return false end })
        assertEquals(#client.plots, 0, "not from a client")
        received:run({ getIsServer = function() return true end })
        world.tc.PloughingMatch = match
        return client
    end
    local client = toClient()
    assertEquals(#client.plots, 5)
    assertTrue(client.started)
    assertEquals(client.plots[1].farmId, 1)
    assertEquals(client.plots[1].state, TCPloughMatch.STATE.FINISHED)
    assertEquals(client.plots[1].tractorId, match.plots[1].tractorId)
    assertEquals(client.plots[3].farmerId, match.plots[3].farmerId)
    assertEquals(client.plots[1].card, nil, "no score before the results")
    assertEquals(client.plots[3].card, nil)
    assertEquals(next(client.runs), nil, "no runs")
    assertEquals(next(client.skills), nil, "no skills")
    -- The client locks the kit for its own player the same.
    assertEquals(client:getLockedKit(2)[client.plots[1].tractorId], TCPloughMatch.LOCK.FINISHED)

    setHour(world, 16)
    client = toClient()
    assertTrue(client.resultsGiven)
    assertNear(client.plots[1].card.total, match.plots[1].card.total, 0.0001)
    assertEquals(client.plots[1].card.placing, 1)
    assertNear(client.plots[1].card.parts.coverage.marks, match.plots[1].card.parts.coverage.marks, 0.0001)
    assertEquals(client.plots[1].card.parts.furrowAngle, nil)
    assertNear(client.plots[3].card.total, 80, 0.01)
    assertEquals(client:getBest(1).wins, 1)
    assertEquals(next(client.skills), nil, "still no skills")
end)

test("a save mid-match keeps the plots, the drivers, the ground and the run so far; a joining client gets them", function()
    local world = setup()
    local match = world.match
    showDay(world)
    match:takePlot(1, 1)
    setHour(world, 11)
    world.ploughed[1] = function(_, _, inside) return inside end
    local path = plotPath(frameOf(world, 1), 1.4)
    local firstHalf, secondHalf = {}, {}
    for i, sample in ipairs(path) do
        table.insert(i <= #path / 2 and firstHalf or secondHalf, sample)
    end
    plough(world, 1, firstHalf, 75)

    local xmlFile = {}
    match:saveToXmlFile(xmlFile)
    local loaded = TheContractorPloughingMatch.new()
    loaded.engine = world.engine
    loaded.random = match.random
    world.tc.PloughingMatch = loaded
    world.match = loaded
    loaded:loadFromXMLFile(xmlFile)
    assertTrue(loaded.setOut and loaded.started and not loaded.over)
    assertEquals(loaded.plots[1].farmId, 1)
    assertEquals(loaded.plots[1].state, TCPloughMatch.STATE.TAKEN)
    assertEquals(loaded.plots[3].farmerId, match.plots[3].farmerId)
    assertEquals(loaded.plots[1].tractorId, nil, "until vehicles exist")
    assertEquals(loaded.skills[match.plots[3].farmerId], 0)
    assertTrue(#loaded.runs[1].savedRuns > 5, "the runs so far")
    loaded:resolveSavedVehicles()
    assertEquals(loaded.plots[1].tractorId, match.plots[1].tractorId)
    assertEquals(loaded.plots[5].ploughId, match.plots[5].ploughId)
    assertEquals(#world.spawned, 5, "nothing missing, nothing spawned again")
    assertNear(loaded.runs[3].result.total, 80, 0.01, "the farmer's rolled score")

    -- The rest of the run after the load scores as one that never stopped.
    plough(world, 1, secondHalf, 75)
    loaded:finishPlot(1, 1)
    assertNear(loaded.runs[1].result.total, 100, 0.5)
    assertNear(TCPloughMatch.getMinutesUsed(loaded.runs[1].firstMinute, loaded.runs[1].lastMinute), 150, 1)

    -- A joining client.
    local stream = world:newStream()
    loaded:writeInitialClientState(stream)
    local client = TheContractorPloughingMatch.new()
    client:readInitialClientState(stream)
    assertEquals(#client.plots, 5)
    assertEquals(client.plots[1].state, TCPloughMatch.STATE.FINISHED)

    -- A kit that's gone by the load is spawned again.
    local again = TheContractorPloughingMatch.new()
    again.engine = world.engine
    world.tc.PloughingMatch = again
    again:loadFromXMLFile(xmlFile)
    local vehicles = g_currentMission.vehicleSystem.vehicles
    for i = #vehicles, 1, -1 do
        if vehicles[i].id == match.plots[2].tractorId then
            table.remove(vehicles, i)
        end
    end
    again:resolveSavedVehicles()
    assertEquals(world.spawned[#world.spawned], 2)
    assertTrue(again.plots[2].tractorId ~= match.plots[2].tractorId)
end)

test("the ground's packed for the save and unpacked the same", function()
    setup()
    local frame = TCPloughScore.newPlot(0, 0, 0, 1, 35)
    local grid = TCPloughScore.makeGrid(frame)
    grid.cells[10].before = 1
    grid.cells[200].before = 0.25
    local text = TCPloughMatch.packGrid(grid, "before")
    local copy = TCPloughScore.makeGrid(frame)
    TCPloughMatch.unpackGrid(copy, "before", text)
    assertEquals(copy.cells[10].before, 1)
    assertEquals(copy.cells[200].before, 0.25)
    assertEquals(copy.cells[11].before, 0)
end)

-- Farms and farmers ------------------------------------------------------------------------------------

test("a deleted farm's plot is free again and its best forgotten; a retired farmer's plot passes on", function()
    local world = setup()
    local match = world.match
    showDay(world)
    match:takePlot(1, 1)
    match.best = { [1] = { bestScore = 90, wins = 2, matches = 3 } }
    match:forgetFarm(1)
    assertEquals(match.plots[1].farmId, 0)
    assertEquals(match.plots[1].state, TCPloughMatch.STATE.OPEN)
    assertEquals(match:getBest(1), nil)

    local farmerId = match.plots[3].farmerId
    world.tc.PublicEvents:replaceHost(farmerId, 20)
    assertEquals(match.plots[3].farmerId, 20)
    assertEquals(match.skills[farmerId], nil)
end)

test("a cancelled show takes the kit away and the plots with it", function()
    local world = setup()
    local match = world.match
    showDay(world)
    world.tc.Show:cancel(true)
    assertEquals(#world.deleted, 10)
    assertEquals(#match.plots, 0)
    assertTrue(not match.setOut)
end)

-- The kit --------------------------------------------------------------------------------------------------

test("the kit: a mounted reversible plough nearest 1.4 m, and the smallest mid-size tractor with the power for it", function()
    setup()
    local plough = TCPloughMatch.pickPlough({
        { xmlFilename = "wide", width = 2.4, reversible = true, mounted = true, price = 1 },
        { xmlFilename = "conventional", width = 1.4, reversible = false, mounted = true, price = 1 },
        { xmlFilename = "semi", width = 1.4, reversible = true, mounted = false, price = 1 },
        { xmlFilename = "fourFurrow", width = 1.6, reversible = true, mounted = true, price = 9000 },
        { xmlFilename = "threeFurrow", width = 1.2, reversible = true, mounted = true, price = 8000 },
    })
    assertEquals(plough.xmlFilename, "threeFurrow", "nearest 1.4 (a tie), then the cheaper")
    assertEquals(TCPloughMatch.pickPlough({ { width = 1.4, reversible = false, mounted = true, xmlFilename = "c" } })
        .xmlFilename, "c", "a conventional one when there's no other")
    assertEquals(TCPloughMatch.pickPlough({ { width = 3, reversible = true, mounted = true, xmlFilename = "big" },
        { width = 1.4, reversible = true, mounted = false, xmlFilename = "trailed" } }).xmlFilename, "big",
        "a mounted one out of the range before one that isn't mounted")
    assertEquals(TCPloughMatch.pickPlough({ { width = 1.4, reversible = true, mounted = false, xmlFilename = "trailed" } })
        .xmlFilename, "trailed", "anything rather than nothing")
    assertEquals(TCPloughMatch.pickPlough({}), nil)

    local tractor = TCPloughMatch.pickTractor({
        { power = 80, price = 1, name = "small" }, { power = 130, price = 5, name = "big" },
        { power = 110, price = 9, name = "mid" }, { power = 110, price = 7, name = "midCheap" },
    }, 100)
    assertEquals(tractor.name, "midCheap")
    assertEquals(TCPloughMatch.pickTractor({ { power = 80, name = "a" }, { power = 85, name = "b" } }, 100).name, "b",
        "the most powerful when none has enough")
end)
