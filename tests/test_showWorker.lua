-- 170: a worker entered in the show's ploughing match. The entry rules,
-- the booking on the day (at the show, not offered for work, one out on a
-- job going when back, back to idle after) and its undoing (withdrawn by
-- the player, or on its own when the worker's sick, away, gone or late,
-- with a message and their plot to a farmer), the score from skill,
-- tractor experience, morale and form, the run painted, placings paying the
-- farm, the morale boost, the sync, the save, and a deleted farm.
--
-- The real Show, EventDay, PublicEvents, Inbox, calendar, show scene, 168's
-- scoring, 169's match, and Staff, Worker, Training, Holidays, WorkingHours
-- and Morale's getters; the site, signs, crowd, farmers, companies and
-- rewards faked as tests/test_ploughingMatch.lua has them.

local SHOW_FIELD = 5
local HOST_ID = 7
local SHOW_DAY = 51

local function makeEngine(world)
    world.painted, world.deleted, world.spawned = {}, {}, {}
    world.minute = TCPloughMatch.toGameMinute(SHOW_DAY, 0)
    local engine = {
        getGameMinute = function() return world.minute end,
        readGround = function(_, grid, key)
            for _, cell in ipairs(grid.cells) do
                cell[key] = 0
            end
        end,
        readAngles = function() return nil end,
        sample = function() return nil end,
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
        end,
        paintStrips = function(_, frame, from, to, count)
            table.insert(world.painted, { number = frame.number, from = from, to = to, count = count })
        end,
        pickKit = function() return { tractorXml = "tractor.xml", ploughXml = "plough.xml" } end,
    }
    return engine
end

local function setup()
    local world = stubs.install()
    TheContractor = { SaveKey = "TheContractor" }
    Environment = { PERIODS_IN_YEAR = 12 }
    Enterable = {}
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
    TheContractorJob = { STATE = { OFFERED = 1, NEGOTIATING = 2 } }
    TheContractorJobGeneration = { JOB_TYPES = {} }
    WorkArea = { getIsAccessibleAtWorldPosition = function(vehicle, farmId) return false, farmId, true end }
    world.statusNotes = {}
    TCWorkerStatusChangedEvent = {
        new = function() return {} end,
        showNotification = function(worker, oldStatus, newStatus)
            table.insert(world.statusNotes, { worker = worker, from = oldStatus, to = newStatus })
        end,
    }

    world:load("src/util/TCCalendar.lua")
    world:load("src/util/TCNames.lua")
    world:load("src/util/TCWorkerAppearance.lua")
    world:load("src/business/Inbox.lua")
    world:load("src/business/Worker.lua")
    world:load("src/business/Staff.lua")
    world:load("src/business/Training.lua")
    world:load("src/business/Holidays.lua")
    world:load("src/business/WorkingHours.lua")
    world:load("src/business/Morale.lua")
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
    world:load("src/util/TCShowWorker.lua")
    world:load("src/util/TCPloughPlotActivatable.lua")
    world:load("src/business/PublicEvents.lua")
    world:load("src/business/EventDay.lua")
    world:load("src/business/Show.lua")
    world:load("src/business/PloughingMatch.lua")
    world:load("src/business/ShowWorker.lua")
    world:load("src/events/TCShowEvent.lua")
    world:load("src/events/TCPloughMatchEvent.lua")
    world:load("src/events/TCShowEntryEvent.lua")
    world:load("src/events/TCShowWorkerEvent.lua")

    for month = 1, 12 do
        world.texts["ui_month" .. month] = "Month " .. month
    end
    g_currentMission.environment = {
        currentYear = 1, currentPeriod = 1, currentDayInPeriod = 1, daysPerPeriod = 10,
        plannedDaysPerPeriod = 10, currentMonotonicDay = 1, currentHour = 0, dayTime = 0,
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

    -- Staff: the real roster and status changes.
    tc.Staff = setmetatable({ workersByFarm = {}, candidatePool = {} }, TheContractorStaff_mt)
    tc.HealthSafety = { onWorkerFellSick = function() end, getExtraDayChance = function() return 0 end }
    world.morale = {}
    tc.Morale = { adjust = function(_, farmId, workers, delta)
        for _, worker in ipairs(workers) do
            table.insert(world.morale, { farmId = farmId, workerId = worker.id, delta = delta })
        end
    end }
    function world:addWorker(def)
        local worker = TheContractorWorker.new(def.id, def.farmId or 1, def.name or ("Worker " .. def.id), 5,
            def.tiers or { medium = 6 }, 2500, 30, 0, nil, 0, { tillage = def.tillage or 6 })
        worker.status = def.status or TheContractorWorker.STATUS.IDLE
        worker.morale = def.morale or 80
        tc.Staff.workersByFarm[worker.farmId] = tc.Staff.workersByFarm[worker.farmId] or {}
        tc.Staff.workersByFarm[worker.farmId][worker.id] = worker
        return worker
    end

    -- The showground and five plots in a row (tests/test_ploughingMatch.lua's).
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
        clear = function(self) self.site = nil return "cleared" end,
    }
    TheContractorAuctionSite = { PREFERRED_LOTS = 120, CLOSE_HOURS = { 17, 18 },
        getFieldRefusal = function() return nil end }
    tc.AuctionSite = {
        site = nil, fieldId = 0, walkways = {},
        getWalkways = function(self) return self.walkways end,
        getScene = function(self) return self.site ~= nil and world.scene or nil end,
        startOpen = function(self, fieldId)
            self.site = { fieldId = fieldId }
            self.fieldId = fieldId
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

    world.money, world.reputation, world.opinions = {}, {}, {}
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
    tc.Notices = {
        nextId = 1,
        publish = function(self)
            self.nextId = self.nextId + 1
            return self.nextId - 1
        end,
        remove = function() end,
    }

    tc.PublicEvents = TheContractorPublicEvents.new()
    tc.Show = TheContractorShow.new()
    tc.Show:register(tc.Inbox)
    tc.PublicEvents:registerKind(tc.Show)
    tc.PloughingMatch = TheContractorPloughingMatch.new()
    tc.PloughingMatch:register(tc.Show)
    tc.ShowWorker = TheContractorShowWorker.new()
    tc.ShowWorker:register(tc.Show)
    -- Every roll in the middle: no noise, no jitter, no form.
    tc.PloughingMatch.random = function() return 0.5 end
    tc.ShowWorker.random = function() return 0.5 end
    tc.PloughingMatch.engine = makeEngine(world)
    world.match = tc.PloughingMatch
    world.showWorker = tc.ShowWorker
    world.tc = tc
    return world
end

local function setDay(day)
    local environment = g_currentMission.environment
    environment.currentMonotonicDay = day
    environment.currentHour = 0
    environment.dayTime = 0
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
    g_currentMission.environment.dayTime = hour * 3600000
    world.minute = TCPloughMatch.toGameMinute(SHOW_DAY, hour * 60)
    world.tc.Show:onHourChanged()
end

local function announce(world)
    getWorldTranslation = function(node) return node.x, 0, node.z end
    setDay(21)
    return world.tc.Show:announce(nil, SHOW_DAY, function() return 0 end)
end

local function workerPlot(world, farmId)
    local plot = world.match:getFarmPlot(farmId)
    return plot ~= nil and (plot.workerId or 0) > 0 and plot or nil
end

local function withdrawnMessages(world, farmId)
    local found = {}
    for _, message in ipairs(world.tc.Inbox:getMessages(farmId)) do
        if message.titleKey == "tc_showWorker_withdrawnTitle" then
            table.insert(found, message)
        end
    end
    return found
end

local STATUS = TheContractorWorker ~= nil and TheContractorWorker.STATUS or nil

-- Entering ---------------------------------------------------------------------------------------

test("entering: a company's worker, free on the day, with the tillage and the kit's tractor, one a farm, while entries are open", function()
    local world = setup()
    STATUS = TheContractorWorker.STATUS
    local P = TCShowWorker.PROBLEM
    local showWorker = world.showWorker
    world:addWorker({ id = 1 })
    world:addWorker({ id = 2, tillage = TCShowWorker.MIN_TILLAGE - 1 })
    world:addWorker({ id = 3, tiers = { small = 8, large = 7 } })
    world:addWorker({ id = 4, status = STATUS.SICK })
    local onHoliday = world:addWorker({ id = 5 })
    local leaving = world:addWorker({ id = 6 })
    leaving.leavesAtPeriod = 40
    world:addWorker({ id = 7 })
    world:addWorker({ id = 20, farmId = 3 })

    assertEquals(showWorker:getEntryProblem(1, 1), P.noShow)
    announce(world)
    onHoliday.holidayStartDay, onHoliday.holidayDays = SHOW_DAY - 1, 3
    assertEquals(showWorker:getEntryProblem(3, 20), P.noCompany)
    assertEquals(showWorker:getEntryProblem(1, 99), P.noWorker)
    assertEquals(showWorker:getEntryProblem(1, 2), P.skill)
    assertEquals(showWorker:getEntryProblem(1, 3), P.tractor, "no mid-size experience")
    assertEquals(showWorker:getEntryProblem(1, 4), P.sick)
    assertEquals(showWorker:getEntryProblem(1, 5), P.away, "on holiday on the day")
    assertEquals(showWorker:getEntryProblem(1, 6), P.leaving)
    assertEquals(showWorker:getEntryProblem(1, 1), nil)

    -- A client's request is for its own farm only.
    local connection = { getIsServer = function() return false end }
    g_currentMission.connectionsToPlayer = { [connection] = { farmId = 2 } }
    local request = TCShowEntryEvent.newEnterWorker(1, 1)
    local stream = world:newStream()
    request:writeStream(stream)
    TCShowEntryEvent.emptyNew():readStream(stream, connection)
    assertEquals(showWorker:getEntry(1), nil, "farm 2's player can't enter farm 1's worker")
    g_currentMission.connectionsToPlayer = { [connection] = { farmId = 1 } }
    stream = world:newStream()
    request:writeStream(stream)
    TCShowEntryEvent.emptyNew():readStream(stream, connection)
    local entry = showWorker:getEntry(1)
    assertEquals(entry.workerId, 1)
    assertEquals(entry.name, "Worker 1")
    assertEquals(showWorker:getEntryProblem(1, 7), P.entered, "one a farm")

    -- Withdrawn by the player while entries are open, and entered again.
    stream = world:newStream()
    TCShowEntryEvent.newWithdrawWorker(1):writeStream(stream)
    TCShowEntryEvent.emptyNew():readStream(stream, connection)
    assertEquals(showWorker:getEntry(1), nil)
    assertEquals(showWorker:withdraw(1), P.notEntered)
    assertEquals(select(1, showWorker:enter(1, 7)).workerId, 7)

    -- Entries close a week before.
    runToDay(world, world.tc.Show:getEvent().entriesCloseDay)
    assertEquals(showWorker:getEntryProblem(2, 1), P.closed)
    assertEquals(showWorker:withdraw(1), P.closed, "not once entries have closed")
    assertTrue(world.tc.Show:takesEntries(), "the ploughing takes entries, so they close")
end)

-- The day -----------------------------------------------------------------------------------------

test("on the day the worker's at the show, not offered for work, on their plot; one out on a job goes when back; back to idle after", function()
    local world = setup()
    STATUS = TheContractorWorker.STATUS
    local amy = world:addWorker({ id = 1, name = "Amy Hall" })
    local ben = world:addWorker({ id = 2, farmId = 2, name = "Ben Ross" })
    announce(world)
    world.showWorker:enter(1, 1)
    world.showWorker:enter(2, 2)
    assertEquals(amy.status, STATUS.IDLE, "nothing booked before the day")
    runToDay(world, SHOW_DAY - 1)
    ben.status = STATUS.ASSIGNED
    runToDay(world, SHOW_DAY)

    assertEquals(amy.status, STATUS.SHOW)
    assertTrue(not TheContractorWorkingHours.isAvailable(amy), "not offered for anything")
    assertTrue(TheContractorWorkingHours.isAway(amy), "no staying late")
    assertEquals(ben.status, STATUS.ASSIGNED, "still out on a job")
    -- Each farm's plot reserved for its worker.
    local plot1, plot2 = workerPlot(world, 1), workerPlot(world, 2)
    assertEquals(plot1.workerId, 1)
    assertEquals(plot2.workerId, 2)
    assertEquals(plot1.state, TCPloughMatch.STATE.TAKEN)
    assertEquals(world.match:getTakeProblem(3, 1), TCPloughMatch.PROBLEM.hasPlot, "the farm's one plot")
    -- Ben's back from his job: off to the show.
    world.tc.Staff:setWorkerStatus(2, 2, STATUS.IDLE)
    assertEquals(ben.status, STATUS.SHOW)

    -- The kit's the worker's: locked to everyone, their own farm too.
    setHour(world, 11)
    local L = TCPloughMatch.LOCK
    assertEquals(world.match:getLockedKit(1)[plot1.tractorId], L.WORKER)
    assertEquals(world.match:getLockedKit(2)[plot1.tractorId], L.WORKER)
    assertEquals(world.match:getFinishProblem(plot1.number, 1), TCPloughMatch.PROBLEM.worker)
    assertEquals(TCPloughPlotActivatable.getAction(world.match, plot1.number, 1), nil, "no prompt at its peg")

    -- Back to idle at midnight after.
    setHour(world, 16)
    runToDay(world, SHOW_DAY + 1)
    assertEquals(amy.status, STATUS.IDLE)
    assertEquals(ben.status, STATUS.IDLE)
    assertTrue(world.showWorker:getEntry(1) ~= nil, "the entry's kept for the Show tab")
end)

test("a worker who's sick on the day is withdrawn with a message, and the plot goes to a farmer", function()
    local world = setup()
    STATUS = TheContractorWorker.STATUS
    local amy = world:addWorker({ id = 1 })
    announce(world)
    world.showWorker:enter(1, 1)
    runToDay(world, SHOW_DAY - 1)
    -- Off sick the day before, for two days: still off on the day.
    amy.status = STATUS.SICK
    amy.sickDaysRemaining = 2
    -- (A day's sickness the day before would have them back for it.)
    assertEquals(TheContractorShowWorker.getWithdrawReason(amy, world.tc.Show:getEvent(), SHOW_DAY - 1),
        TCShowWorker.WITHDRAW.sick)
    assertEquals(TCShowWorker.isSickOn(SHOW_DAY - 1, SHOW_DAY, 1, 0), false)
    runToDay(world, SHOW_DAY)

    assertEquals(world.showWorker:getEntry(1), nil, "withdrawn")
    assertEquals(workerPlot(world, 1), nil)
    -- Plot 1 (the first open, reserved at the set-out) is a farmer's now.
    local plot = world.match:getPlot(1)
    assertEquals(plot.state, TCPloughMatch.STATE.FARMER)
    assertTrue(plot.farmerId > 0)
    assertEquals(plot.workerId, 0)
    assertTrue(world.match.runs[1].result ~= nil, "the farmer's score rolled")
    local used = {}
    for _, other in ipairs(world.match.plots) do
        if other.farmerId > 0 then
            assertTrue(not used[other.farmerId], "a farmer not on another plot")
            used[other.farmerId] = true
        end
    end
    local messages = withdrawnMessages(world, 1)
    assertEquals(#messages, 1)
    assertEquals(messages[1].bodyKey, "tc_showWorker_withdrawnBodyPlot")
    assertEquals(messages[1].args[2], "Worker 1")
    assertEquals(messages[1].args[3], "$l10n_" .. TCShowWorker.WITHDRAW.sick)
    assertEquals(amy.status, STATUS.SICK, "still off sick, not at the show")
end)

test("withdrawn on its own before the day: off sick through it, a holiday on it, or leaving", function()
    local world = setup()
    STATUS = TheContractorWorker.STATUS
    local amy = world:addWorker({ id = 1 })
    local ben = world:addWorker({ id = 2, farmId = 2 })
    announce(world)
    world.showWorker:enter(1, 1)
    world.showWorker:enter(2, 2)

    -- A short illness well before the day doesn't matter.
    setDay(30)
    world.tc.Staff:makeWorkerSick(1, amy, false, 2)
    world.showWorker:checkEntries()
    assertTrue(world.showWorker:getEntry(1) ~= nil, "back well before the day")
    -- One that runs into it does; before the day there's no plot to give.
    amy.status, amy.sickDaysRemaining = STATUS.IDLE, 0
    world.tc.Staff:makeWorkerSick(1, amy, false, 25)
    world.showWorker:checkEntries()
    assertEquals(world.showWorker:getEntry(1), nil)
    assertEquals(withdrawnMessages(world, 1)[1].bodyKey, "tc_showWorker_withdrawnBody")

    -- A holiday booked onto the day.
    ben.holidayStartDay, ben.holidayDays = SHOW_DAY, 2
    world.showWorker:checkEntries()
    assertEquals(world.showWorker:getEntry(2), nil)
    assertEquals(withdrawnMessages(world, 2)[1].args[3], "$l10n_" .. TCShowWorker.WITHDRAW.away)

    -- Leaving: the roster's leave path (here a retirement) withdraws them.
    world:addWorker({ id = 3, farmId = 2 })
    world.showWorker:enter(2, 3)
    local tc = world.tc
    tc.WorkingHours = TheContractorWorkingHours.new()
    tc.Finances = { recordWages = function() end }
    local noop = { refreshNotices = function() end, removeMessagesFor = function() end, onWorkerGone = function() end }
    tc.Holidays, tc.Training, tc.PayReviews, tc.Poaching = noop, noop, noop, noop
    TCWorkerRetiredEvent = { new = function() return {} end, showNotification = function() end }
    tc.Staff:retireWorker(2, 3)
    assertEquals(tc.Staff:getWorker(2, 3), nil)
    assertEquals(world.showWorker:getEntry(2), nil)
    local reasons = {}
    for _, message in ipairs(withdrawnMessages(world, 2)) do
        reasons[message.args[3]] = true
    end
    assertTrue(reasons["$l10n_" .. TCShowWorker.WITHDRAW.gone], "told they've gone")
end)

test("a worker still out on a job at 15:00 is withdrawn as late, the plot a farmer's", function()
    local world = setup()
    STATUS = TheContractorWorker.STATUS
    local amy = world:addWorker({ id = 1 })
    announce(world)
    world.showWorker:enter(1, 1)
    runToDay(world, SHOW_DAY - 1)
    amy.status = STATUS.ASSIGNED
    runToDay(world, SHOW_DAY)
    setHour(world, 11)
    world.match:updateMatch(TheContractorPloughingMatch.PAINT_MS)
    assertEquals(world.match.runs[1].result, nil, "no run while they're away")
    setHour(world, 15)
    assertEquals(world.showWorker:getEntry(1), nil)
    assertEquals(withdrawnMessages(world, 1)[1].args[3], "$l10n_" .. TCShowWorker.WITHDRAW.late)
    assertEquals(world.match:getPlot(1).state, TCPloughMatch.STATE.FARMER)
    -- Back from the job after the match: not to the show.
    world.tc.Staff:setWorkerStatus(1, 1, STATUS.IDLE)
    assertEquals(amy.status, STATUS.IDLE)
end)

-- The score ------------------------------------------------------------------------------------------

test("the score: tillage and tractor experience, scaled by morale, give or take form; quicker the better", function()
    setup()
    local mid = function() return 0.5 end
    local best = TCShowWorker.rollScore(10, 10, 1, mid)
    local average = TCShowWorker.rollScore(5, 5, 1, mid)
    local poor = TCShowWorker.rollScore(4, 1, 1, mid)
    assertTrue(best > average and average > poor, "better workers score higher")
    assertNear(average, TCPloughMatch.FARMER_SCORE.base, 3, "an average worker about a farmer's")
    assertTrue(TCShowWorker.rollScore(7, 3, 1, mid) > TCShowWorker.rollScore(3, 7, 1, mid),
        "tillage counts for more than the tractor")
    -- Morale through 056's getter: unhappy scores lower.
    local happy = TheContractorMorale.getQualityMultiplierFor(90)
    local unhappy = TheContractorMorale.getQualityMultiplierFor(10)
    assertTrue(TCShowWorker.rollScore(7, 7, happy, mid) > TCShowWorker.rollScore(7, 7, unhappy, mid))
    -- Form: a good or bad day, within FORM.
    local form = TCShowWorker.SCORE.form
    assertNear(TCShowWorker.rollScore(5, 5, 1, function() return 1 end) - average, form, 0.0001)
    assertNear(average - TCShowWorker.rollScore(5, 5, 1, function() return 0 end), form, 0.0001)
    assertTrue(TCShowWorker.rollScore(10, 10, 1, function() return 1 end) <= TCShowWorker.SCORE.max)
    -- Minutes: inside the limit, the able quicker.
    assertTrue(TCShowWorker.rollMinutes(10, 10, mid) < TCShowWorker.rollMinutes(4, 1, mid))
    for _, roll in ipairs({ 0, 0.5, 1 }) do
        local minutes = TCShowWorker.rollMinutes(1, 1, function() return roll end)
        assertTrue(minutes <= TCPloughScore.RULES.timeLimitMinutes)
    end
end)

test("the worker's run is rolled when they're there and the match is on, painted from then, hidden until the results", function()
    local world = setup()
    STATUS = TheContractorWorker.STATUS
    world:addWorker({ id = 1, tillage = 9, tiers = { medium = 9 }, morale = 90 })
    announce(world)
    world.showWorker:enter(1, 1)
    runToDay(world, SHOW_DAY)
    setHour(world, 8)
    world.match:updateMatch(TheContractorPloughingMatch.PAINT_MS)
    local plot = workerPlot(world, 1)
    local run = world.match.runs[plot.number]
    assertEquals(run.result, nil, "not before 11:00")
    setHour(world, 11)
    world.minute = world.minute + 1
    world.match:updateMatch(TheContractorPloughingMatch.PAINT_MS)
    assertTrue(run.result ~= nil)
    local expected = TCShowWorker.rollScore(9, 9, TheContractorMorale.getQualityMultiplierFor(90),
        function() return 0.5 end)
    assertNear(run.result.total, expected, 0.01, "the breakdown adds up to the rolled score")
    assertEquals(run.result.minutes, TCShowWorker.rollMinutes(9, 9, function() return 0.5 end))
    -- Painted as the time goes, from when they started.
    world.minute = world.minute + run.farmerMinutes / 2
    world.match:updateMatch(TheContractorPloughingMatch.PAINT_MS)
    local painted = 0
    for _, paint in ipairs(world.painted) do
        if paint.number == plot.number then
            painted = paint.to
        end
    end
    assertTrue(painted > 0 and painted < math.ceil(35 / TCPloughMatch.PLOUGH_WIDTH), "part way")

    -- Nothing of the score goes out before the results.
    local stream = world:newStream()
    TheContractorPloughingMatch.writeState(stream, world.match)
    local state = TheContractorPloughingMatch.readState(stream)
    assertEquals(state.plots[plot.number].card, nil)
    assertEquals(state.plots[plot.number].workerId, 1, "who's on it does")
end)

-- Afterwards --------------------------------------------------------------------------------------------

test("a placing pays the farm as if its player had ploughed and lifts the worker's morale; a poor run costs nothing", function()
    local world = setup()
    STATUS = TheContractorWorker.STATUS
    world:addWorker({ id = 1, tillage = 10, tiers = { medium = 10 }, morale = 95 })
    world:addWorker({ id = 2, farmId = 2, tillage = 4, tiers = { medium = 1 }, morale = 40 })
    announce(world)
    world.showWorker:enter(1, 1)
    world.showWorker:enter(2, 2)
    runToDay(world, SHOW_DAY)
    setHour(world, 11)
    world.match:updateMatch(TheContractorPloughingMatch.PAINT_MS)
    setHour(world, 15)
    local plot1 = workerPlot(world, 1)
    assertEquals(plot1.state, TCPloughMatch.STATE.FINISHED)
    setHour(world, 16)

    -- Farm 1's worker wins (the farmers score 80 in the middle).
    assertEquals(plot1.card.placing, 1)
    local placing = nil
    for _, record in ipairs(world.tc.Show:getResults().placings) do
        if record.farmId == 1 then
            placing = record
        end
    end
    assertEquals(placing.placing, 1)
    assertEquals(placing.paid, TCPloughMatch.PRIZES[1] * 6)
    assertEquals(world.reputation[1].farmId, 1)
    assertEquals(world.reputation[1].delta, TCPloughMatch.REPUTATION[1] * 10)
    assertEquals(world.match:getBest(1).wins, 1)
    -- Morale: farm 1's worker up by a win's; farm 2's poor run, nothing.
    assertEquals(#world.morale, 1)
    assertEquals(world.morale[1].workerId, 1)
    assertEquals(world.morale[1].delta, TCShowWorker.MORALE_BOOST[1])
    assertEquals(workerPlot(world, 2).card.placing, nil)
    assertEquals(TCShowWorker.getMoraleBoost(nil), 0)
    assertTrue(TCShowWorker.getMoraleBoost(1) > TCShowWorker.getMoraleBoost(3), "a win most")

    -- The scorecard names the worker.
    local card = nil
    for _, message in ipairs(world.tc.Inbox:getMessages(1)) do
        if message.titleKey == "tc_ploughMatch_cardTitle" then
            card = message
        end
    end
    assertEquals(card.bodyKey, "tc_ploughMatch_cardBodyWorker")
    assertEquals(card.args[#card.args], "Worker 1")
end)

-- Sync, save, farms --------------------------------------------------------------------------------------

test("the entries go to every machine, are saved, and a deleted farm's entry goes", function()
    local world = setup()
    world:addWorker({ id = 1, name = "Amy Hall" })
    announce(world)
    world.showWorker:enter(1, 1)
    local event = nil
    for i = #world.events, 1, -1 do
        if getmetatable(world.events[i]) == getmetatable(TCShowWorkerEvent.emptyNew()) then
            event = world.events[i]
            break
        end
    end
    assertTrue(event ~= nil, "sent")
    local stream = world:newStream()
    event:writeStream(stream)
    local client = TheContractorShowWorker.new()
    client:applyState(TheContractorShowWorker.readState(stream))
    assertEquals(client.showId, world.showWorker.showId)
    assertEquals(client:getEntry(1).workerId, 1)
    assertEquals(client:getEntry(1).name, "Amy Hall")

    -- Saved and loaded.
    local xml = {}
    world.showWorker:saveToXmlFile(xml)
    local loaded = TheContractorShowWorker.new()
    loaded:loadFromXMLFile(xml)
    assertEquals(loaded.showId, world.showWorker.showId)
    assertEquals(loaded:getEntry(1).workerId, 1)

    -- A plot's worker is saved with the match.
    runToDay(world, SHOW_DAY)
    local plot = workerPlot(world, 1)
    xml = {}
    world.match:saveToXmlFile(xml)
    local match = TheContractorPloughingMatch.new()
    match:loadFromXMLFile(xml)
    assertEquals(match.plots[plot.number].workerId, 1)

    -- A deleted farm: its entry and its plot's worker go.
    world.showWorker:forgetFarm(1)
    world.match:forgetFarm(1)
    assertEquals(world.showWorker:getEntry(1), nil)
    assertEquals(world.match.plots[plot.number].workerId, 0)
    assertEquals(world.match.plots[plot.number].state, TCPloughMatch.STATE.OPEN)
end)

test("a called-off show sends the worker home and drops the entries", function()
    local world = setup()
    STATUS = TheContractorWorker.STATUS
    local amy = world:addWorker({ id = 1 })
    announce(world)
    world.showWorker:enter(1, 1)
    runToDay(world, SHOW_DAY)
    assertEquals(amy.status, STATUS.SHOW)
    world.tc.Show:cancel(true)
    assertEquals(amy.status, STATUS.IDLE, "not sent straight back")
    assertEquals(#world.showWorker.entries, 0)
end)
