-- 172: the staff's day off for the show. The ask (a few weeks before, to
-- each company farm with staff, Yes / No, gone on the day), the answer's
-- morale, the booking on the day (everyone who'd work at the show, not
-- offered for anything, one out on a job going when back, the sick and
-- away left be, 170's entrant ploughing anyway, office staff off and no
-- office work), back the day after, the staff's places in the crowd, the
-- sync, the save, a deleted farm, a moved day and a called-off show.
--
-- The real Show, EventDay, PublicEvents, Inbox, calendar, show scene, 169's
-- match, 170's entries, and Staff, Worker, Training, Holidays,
-- WorkingHours and Office; the site, signs, crowd, farmers, companies and
-- rewards faked as tests/test_showWorker.lua has them.

local SHOW_FIELD = 5
local HOST_ID = 7
local SHOW_DAY = 51

local function makeEngine(world)
    world.minute = TCPloughMatch.toGameMinute(SHOW_DAY, 0)
    return {
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
            match:onKitSpawned(number, ids[1], ids[2])
        end,
        processSpawnQueue = function() end,
        deleteVehicle = function() end,
        paintStrips = function() end,
        pickKit = function() return { tractorXml = "tractor.xml", ploughXml = "plough.xml" } end,
    }
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
    TheContractorFinances = { DELAY_WEIGHTS = { { periods = 1, weight = 1 } }, BAD_DEBT_CHANCE = 0.05,
        LATE_PAYER_CHANCE = 0.1 }
    WorkArea = { getIsAccessibleAtWorldPosition = function(vehicle, farmId) return false, farmId, true end }
    world.statusNotes = {}
    TCWorkerStatusChangedEvent = {
        new = function() return {} end,
        showNotification = function(worker, oldStatus, newStatus)
            table.insert(world.statusNotes, { worker = worker, from = oldStatus, to = newStatus })
        end,
    }
    world.workshopRefreshes = {}
    TCADSWorkshop = { refresh = function(farmId) table.insert(world.workshopRefreshes, farmId) end }

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
    world:load("src/business/Office.lua")
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
    world:load("src/util/TCShowDayOff.lua")
    world:load("src/util/TCPloughPlotActivatable.lua")
    world:load("src/business/PublicEvents.lua")
    world:load("src/business/EventDay.lua")
    world:load("src/business/Show.lua")
    world:load("src/business/PloughingMatch.lua")
    world:load("src/business/ShowWorker.lua")
    world:load("src/business/ShowDayOff.lua")
    world:load("src/events/TCShowEvent.lua")
    world:load("src/events/TCPloughMatchEvent.lua")
    world:load("src/events/TCShowWorkerEvent.lua")
    world:load("src/events/TCShowDayOffEvent.lua")

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
    world.people = { [7] = { id = 7, name = "Tom" }, [8] = { id = 8, name = "Ann" } }
    tc.Farmers = {
        getHolder = function() return world.people[HOST_ID] end,
        getPerson = function(_, id) return world.people[id] end,
        getFarmers = function() return { world.people[7], world.people[8] } end,
    }
    world.companies = { [1] = true, [2] = true }
    tc.Company = { hasCompany = function(_, farmId) return world.companies[farmId] == true end }
    tc.RandomEvents = { incidents = {}, getCompanyFarmIds = function() return { 1, 2 } end }
    tc.Inbox = TheContractorInbox.new()

    -- Staff: the real roster, status changes and office.
    tc.Staff = setmetatable({ workersByFarm = {}, candidatePool = {}, nextWorkerId = 1 }, TheContractorStaff_mt)
    tc.Office = TheContractorOffice.new()
    tc.HealthSafety = { onWorkerFellSick = function() end, getExtraDayChance = function() return 0 end }
    world.morale = {}
    tc.Morale = { adjust = function(_, farmId, workers, delta)
        for _, worker in ipairs(workers) do
            table.insert(world.morale, { farmId = farmId, workerId = worker.id, delta = delta })
        end
    end }
    function world:addWorker(def)
        local worker = TheContractorWorker.new(def.id, def.farmId or 1, def.name or ("Worker " .. def.id), 5,
            { medium = 6 }, 2500, 30, 0, nil, 0, { tillage = 6 })
        worker.status = def.status or TheContractorWorker.STATUS.IDLE
        worker.morale = 80
        tc.Staff.workersByFarm[worker.farmId] = tc.Staff.workersByFarm[worker.farmId] or {}
        tc.Staff.workersByFarm[worker.farmId][worker.id] = worker
        return worker
    end
    function world:addAdministrator(farmId, id)
        local member = { id = id, role = "administrator", farmId = farmId, name = "Office " .. id, salary = 2000,
            level = 1, hiredPeriod = 1, ageAtHire = 25 }
        tc.Office.membersByFarm[farmId] = { administrator = member }
        return member
    end

    -- The showground and five plots (tests/test_showWorker.lua's).
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
    -- 171's stands: the showground's scene and the slot of the day.
    tc.ShowStands = { getScene = function() return world.scene end }
    TheContractorShowStands = { getSlotNow = function() return world.slot or 0 end }

    g_currentMission.addMoney = function() end
    tc.Settings = { scaleCost = function(_, amount) return amount end }
    TCEconomyScale = { scale = function(amount) return amount end }
    TheContractorGoodNews = { getReputationReward = function(farmId, jobs) return jobs end }
    tc.Reputation = { addReputation = function() end }
    tc.Relationships = { adjust = function() end }
    tc.Notices = { publish = function() return 1 end, remove = function() end }

    tc.PublicEvents = TheContractorPublicEvents.new()
    tc.Show = TheContractorShow.new()
    tc.Show:register(tc.Inbox)
    tc.PublicEvents:registerKind(tc.Show)
    tc.PloughingMatch = TheContractorPloughingMatch.new()
    tc.PloughingMatch:register(tc.Show)
    tc.ShowWorker = TheContractorShowWorker.new()
    tc.ShowWorker:register(tc.Show)
    tc.ShowDayOff = TheContractorShowDayOff.new()
    tc.ShowDayOff:register(tc.Show, tc.Inbox)
    tc.PloughingMatch.random = function() return 0.5 end
    tc.ShowWorker.random = function() return 0.5 end
    tc.PloughingMatch.engine = makeEngine(world)
    world.dayOff = tc.ShowDayOff
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

-- Each midnight: the inbox's expiry, then the show (the order the game
-- happens to run them in doesn't matter: both are a no).
local function runToDay(world, day)
    while g_currentMission.environment.currentMonotonicDay < day do
        setDay(g_currentMission.environment.currentMonotonicDay + 1)
        world.tc.Inbox:onDayChanged()
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

local function askMessages(world, farmId)
    local found = {}
    for _, message in ipairs(world.tc.Inbox:getMessages(farmId)) do
        if message.kind == TheContractorShowDayOff.MESSAGE_KIND then
            table.insert(found, message)
        end
    end
    return found
end

local function moraleFor(world, farmId)
    local found = {}
    for _, change in ipairs(world.morale) do
        if change.farmId == farmId then
            table.insert(found, change)
        end
    end
    return found
end

local STATUS = TheContractorWorker ~= nil and TheContractorWorker.STATUS or nil
local ANSWER = TCShowDayOff ~= nil and TCShowDayOff.ANSWER or nil

-- The ask ------------------------------------------------------------------------------------------

test("the ask goes a few weeks before to each company farm with staff, with Yes and No, until the day", function()
    local world = setup()
    STATUS, ANSWER = TheContractorWorker.STATUS, TCShowDayOff.ANSWER
    world:addWorker({ id = 1 })
    world:addWorker({ id = 3, farmId = 3 })
    announce(world)
    local askDay = TheContractorShowDayOff.getAskDay(world.tc.Show:getEvent())
    assertEquals(askDay, TCShowDayOff.getAskDay(SHOW_DAY, 10))
    assertTrue(askDay > 21 and askDay < SHOW_DAY, "after the announcement, before the day")

    runToDay(world, askDay - 1)
    assertEquals(#askMessages(world, 1), 0, "not before its day")
    runToDay(world, askDay)
    local asks = askMessages(world, 1)
    assertEquals(#asks, 1)
    local ask = asks[1]
    assertEquals(ask.titleKey, "tc_showDayOff_askTitle")
    assertEquals(ask.actions[1].key, TheContractorShowDayOff.ACTION.YES.key)
    assertEquals(ask.actions[2].key, TheContractorShowDayOff.ACTION.NO.key)
    assertEquals(ask.expiresDay, SHOW_DAY, "the day before is the last to answer")
    assertEquals(TheContractorShowDayOff.getMessageArgs(ask)[1], string.format("$days_%d_%d", SHOW_DAY, SHOW_DAY))
    assertEquals(world.dayOff:getAnswer(1), ANSWER.ASKED)
    -- Farm 2 has nobody; farm 3 isn't a company.
    assertEquals(world.dayOff:getAnswer(2), nil)
    assertEquals(#askMessages(world, 3), 0)

    -- Asked once only.
    runToDay(world, askDay + 1)
    assertEquals(#askMessages(world, 1), 1)

    -- Farm 2 takes on an administrator: asked the next day.
    world:addAdministrator(2, 50)
    runToDay(world, askDay + 2)
    assertEquals(#askMessages(world, 2), 1)
    assertEquals(world.dayOff:getAnswer(2), ANSWER.ASKED)

    -- The show's day moves (161, or the console): the ask names the new
    -- day, worked out from the show's.
    world.tc.Show:getEvent().day = SHOW_DAY + 3
    assertEquals(TheContractorShowDayOff.getMessageArgs(ask)[1],
        string.format("$days_%d_%d", SHOW_DAY + 3, SHOW_DAY + 3))
    assertEquals(TheContractorShowDayOff.getAskDay(world.tc.Show:getEvent()), TCShowDayOff.getAskDay(SHOW_DAY + 3, 10))
end)

test("yes lifts everyone's morale; no, or no answer by the day, is a small knock and nobody's off", function()
    local world = setup()
    world:addWorker({ id = 1 })
    world:addWorker({ id = 2 })
    world:addWorker({ id = 3, farmId = 2 })
    local bea = world:addWorker({ id = 4, farmId = 2 })
    announce(world)
    runToDay(world, TheContractorShowDayOff.getAskDay(world.tc.Show:getEvent()))

    -- Farm 1 says yes.
    world.tc.Inbox:requestAction(1, askMessages(world, 1)[1].id, TheContractorShowDayOff.ACTION.YES.key)
    assertEquals(world.dayOff:getAnswer(1), ANSWER.YES)
    assertEquals(#askMessages(world, 1), 0, "answered, gone")
    local lifts = moraleFor(world, 1)
    assertEquals(#lifts, 2, "everyone on the roster")
    assertEquals(lifts[1].delta, TCShowDayOff.getMoraleDelta(true))
    assertTrue(lifts[1].delta > 0)
    -- An answer stands: no second go.
    assertTrue(not world.dayOff:answer(1, false, world.dayOff.showId))

    -- Farm 2 doesn't answer: a no as the day comes, the ask gone.
    runToDay(world, SHOW_DAY)
    assertEquals(world.dayOff:getAnswer(2), ANSWER.NO)
    assertEquals(#askMessages(world, 2), 0)
    local knocks = moraleFor(world, 2)
    assertEquals(#knocks, 2)
    assertEquals(knocks[1].delta, TCShowDayOff.getMoraleDelta(false))
    assertTrue(knocks[1].delta < 0)
    assertTrue(-knocks[1].delta < -TheContractorMorale.getHolidayRefusedDelta(1, false),
        "smaller than a refused holiday")
    -- Farm 2's staff work as usual.
    assertEquals(bea.status, STATUS.IDLE)
    assertTrue(not world.dayOff:isOffToday(2))
end)

test("no by the inbox is a no, and an ask left to the day is closed then even without the inbox's expiry", function()
    local world = setup()
    world:addWorker({ id = 1 })
    world:addWorker({ id = 3, farmId = 2 })
    announce(world)
    runToDay(world, TheContractorShowDayOff.getAskDay(world.tc.Show:getEvent()))
    world.tc.Inbox:requestAction(1, askMessages(world, 1)[1].id, TheContractorShowDayOff.ACTION.NO.key)
    assertEquals(world.dayOff:getAnswer(1), ANSWER.NO)
    assertEquals(moraleFor(world, 1)[1].delta, TCShowDayOff.getMoraleDelta(false))

    -- The show's day (only the show's midnight, no inbox tick): farm 2's ask
    -- is closed as a no.
    setDay(SHOW_DAY)
    world.tc.Show:onDayChanged()
    assertEquals(world.dayOff:getAnswer(2), ANSWER.NO)
    assertEquals(#askMessages(world, 2), 0)
end)

-- The day -----------------------------------------------------------------------------------------------

test("yes: on the day everyone who'd work is at the show and can't be given work; one out on a job goes when back; back the day after", function()
    local world = setup()
    local amy = world:addWorker({ id = 1 })
    local ben = world:addWorker({ id = 2 })
    local cal = world:addWorker({ id = 3 })
    local dot = world:addWorker({ id = 4 })
    local eve = world:addWorker({ id = 5, farmId = 2 })
    announce(world)
    runToDay(world, TheContractorShowDayOff.getAskDay(world.tc.Show:getEvent()))
    world.tc.Inbox:requestAction(1, askMessages(world, 1)[1].id, TheContractorShowDayOff.ACTION.YES.key)
    world.tc.Inbox:requestAction(2, askMessages(world, 2)[1].id, TheContractorShowDayOff.ACTION.NO.key)
    assertEquals(amy.status, STATUS.IDLE, "nothing booked before the day")

    runToDay(world, SHOW_DAY - 1)
    ben.status = STATUS.ASSIGNED
    cal.status = STATUS.SICK
    cal.sickDaysRemaining = 3
    dot.holidayStartDay, dot.holidayDays = SHOW_DAY, 2
    dot.status = STATUS.HOLIDAY
    runToDay(world, SHOW_DAY)

    assertEquals(amy.status, STATUS.SHOW)
    assertTrue(world.dayOff:isOffToday(1))
    assertTrue(not TheContractorWorkingHours.isAvailable(amy), "nothing can be allocated to them")
    assertTrue(TheContractorWorkingHours.isAway(amy))
    assertEquals(ben.status, STATUS.ASSIGNED, "still out on a job")
    assertEquals(cal.status, STATUS.SICK, "the sick stay so")
    assertEquals(dot.status, STATUS.HOLIDAY, "a holiday comes first")
    assertEquals(eve.status, STATUS.IDLE, "farm 2 said no")
    -- Every hour of the day too.
    setHour(world, 9)
    assertEquals(amy.status, STATUS.SHOW)
    -- Ben's back from his job: off to the show.
    world.tc.Staff:setWorkerStatus(1, 2, STATUS.IDLE)
    assertEquals(ben.status, STATUS.SHOW)
    -- Still there after the results.
    setHour(world, 17)
    assertEquals(amy.status, STATUS.SHOW)

    -- Back at midnight after.
    runToDay(world, SHOW_DAY + 1)
    assertEquals(amy.status, STATUS.IDLE)
    assertEquals(ben.status, STATUS.IDLE)
    assertTrue(not world.dayOff:isOffToday(1))
    assertEquals(world.dayOff:getAnswer(1), ANSWER.YES, "kept for the Show tab until the next show")
end)

test("the office staff are off too, with no office work, and ADS's workshop told", function()
    local world = setup()
    local member = world:addAdministrator(1, 60)
    local other = world:addAdministrator(2, 61)
    local office = world.tc.Office
    announce(world)
    runToDay(world, TheContractorShowDayOff.getAskDay(world.tc.Show:getEvent()))
    assertEquals(world.dayOff:getAnswer(1), ANSWER.ASKED, "an office alone is staff")
    world.tc.Inbox:requestAction(1, askMessages(world, 1)[1].id, TheContractorShowDayOff.ACTION.YES.key)
    assertEquals(#world.morale, 0, "office staff have no morale")

    runToDay(world, SHOW_DAY)
    setHour(world, 10)
    assertEquals(TheContractorOffice.getStatus(member), TheContractorOffice.STATUS.SHOW)
    assertEquals(TheContractorOffice.getStatus(other), TheContractorOffice.STATUS.AVAILABLE, "farm 2 didn't say yes")
    assertTrue(office:hasAdministrator(1), "still employed")
    assertTrue(not office:isAdministratorAtWork(1), "no office work")
    assertEquals(office:getDelayWeights(1), TheContractorFinances.DELAY_WEIGHTS, "no credit control on the day")
    assertEquals(office:getBadDebtChance(1), TheContractorFinances.BAD_DEBT_CHANCE)
    assertTrue(office:isAdministratorAtWork(2))
    assertEquals(world.workshopRefreshes[#world.workshopRefreshes], 1)

    -- The day after, back at work.
    local refreshes = #world.workshopRefreshes
    runToDay(world, SHOW_DAY + 1)
    setHour(world, 10)
    assertEquals(TheContractorOffice.getStatus(member), TheContractorOffice.STATUS.AVAILABLE)
    assertTrue(office:isAdministratorAtWork(1))
    assertEquals(office:getDelayWeights(1), TheContractorOffice.DELAY_WEIGHTS)
    assertTrue(#world.workshopRefreshes > refreshes, "ADS told they're back")
end)

test("a worker entered in the ploughing goes anyway, stays after the results, and isn't in the crowd", function()
    local world = setup()
    local amy = world:addWorker({ id = 1 })
    local ben = world:addWorker({ id = 2 })
    announce(world)
    world.tc.ShowWorker:enter(1, 1)
    runToDay(world, TheContractorShowDayOff.getAskDay(world.tc.Show:getEvent()))
    world.tc.Inbox:requestAction(1, askMessages(world, 1)[1].id, TheContractorShowDayOff.ACTION.YES.key)
    runToDay(world, SHOW_DAY)
    assertEquals(amy.status, STATUS.SHOW)
    assertEquals(ben.status, STATUS.SHOW)
    assertTrue(not world.dayOff:isInCrowd(amy), "at the plot")
    assertTrue(world.dayOff:isInCrowd(ben))

    -- The results are in: 170 is done with her, but it's still her day off.
    setHour(world, 11)
    setHour(world, 16)
    setHour(world, 17)
    assertTrue(not world.tc.ShowWorker:isDueToday(amy))
    assertEquals(amy.status, STATUS.SHOW)
    assertEquals(ben.status, STATUS.SHOW)
    runToDay(world, SHOW_DAY + 1)
    assertEquals(amy.status, STATUS.IDLE)
end)

-- The crowd ---------------------------------------------------------------------------------------------

test("the staff stand ringside where the farmers aren't, then on spectators' spots, the same on every machine", function()
    local world = setup()
    world:addWorker({ id = 1 })
    world:addWorker({ id = 2 })
    world:addWorker({ id = 3, status = STATUS.SICK })
    world:addAdministrator(1, 60)
    announce(world)
    runToDay(world, TheContractorShowDayOff.getAskDay(world.tc.Show:getEvent()))
    world.tc.Inbox:requestAction(1, askMessages(world, 1)[1].id, TheContractorShowDayOff.ACTION.YES.key)
    runToDay(world, SHOW_DAY)
    world.tc.Staff.workersByFarm[1][3].sickDaysRemaining = 5

    local staff = world.dayOff:getCrowdStaff()
    local ids = {}
    for i, entry in ipairs(staff) do
        ids[i] = entry.id
    end
    assertEquals(table.concat(ids, ","), "1,2,60", "the workers at the show and the office, not the sick")

    local layout = TCShowScene.layOut(world.scene)
    assertTrue(#layout.mingles > 0)
    -- A farmer on the first mingle: nobody of ours there.
    local farmerPlaces = { [HOST_ID] = layout.mingles[1] }
    world.slot = 1
    local placed = world.dayOff:getCrowdPlacesNow(farmerPlaces)
    assertEquals(#placed, 3)
    local seen = {}
    for _, entry in ipairs(placed) do
        local key = string.format("%.2f,%.2f", entry.place.x, entry.place.z)
        assertTrue(not seen[key], "one to a place")
        seen[key] = true
        assertTrue(not (entry.place.x == layout.mingles[1].x and entry.place.z == layout.mingles[1].z),
            "not on the farmer's place")
    end
    -- The same answer on another machine, whatever order it lists them in.
    local free = TCShowDayOff.getFreePlaces(layout, farmerPlaces)
    local a = TCShowDayOff.assignPlaces(9, 1, { 60, 2, 1 }, free)
    local b = TCShowDayOff.assignPlaces(9, 1, { 1, 2, 60 }, free)
    for _, id in ipairs({ 1, 2, 60 }) do
        assertEquals(a[id], b[id])
    end

    -- The mingles first, then the spectators' spots (their crowd figure
    -- stands aside).
    local mingleCount = #layout.mingles - 1
    assertTrue(not free[1].isCrowdSpot)
    assertTrue(free[mingleCount + 1].isCrowdSpot)
    local many = {}
    for i = 1, mingleCount + 2 do
        many[i] = 100 + i
    end
    local crowded = 0
    for _, place in pairs(TCShowDayOff.assignPlaces(9, 1, many, free)) do
        if place.isCrowdSpot then
            crowded = crowded + 1
        end
    end
    assertEquals(crowded, 2, "only past the free places")
    -- More staff than places: the rest aren't shown.
    local tooMany = {}
    for i = 1, #free + 3 do
        tooMany[i] = 200 + i
    end
    local count = 0
    for _ in pairs(TCShowDayOff.assignPlaces(9, 1, tooMany, free)) do
        count = count + 1
    end
    assertEquals(count, #free)
end)

-- Sync, save, farms, the console ----------------------------------------------------------------------

test("the answers go to every machine, are saved, a deleted farm's goes, and a new show starts them again", function()
    local world = setup()
    world:addWorker({ id = 1 })
    world:addWorker({ id = 2, farmId = 2 })
    announce(world)
    runToDay(world, TheContractorShowDayOff.getAskDay(world.tc.Show:getEvent()))
    world.tc.Inbox:requestAction(1, askMessages(world, 1)[1].id, TheContractorShowDayOff.ACTION.YES.key)

    local event = nil
    for i = #world.events, 1, -1 do
        if getmetatable(world.events[i]) == getmetatable(TCShowDayOffEvent.emptyNew()) then
            event = world.events[i]
            break
        end
    end
    assertTrue(event ~= nil, "sent")
    local stream = world:newStream()
    event:writeStream(stream)
    local client = TheContractorShowDayOff.new()
    client:applyState(TheContractorShowDayOff.readState(stream))
    assertEquals(client.showId, world.dayOff.showId)
    assertEquals(client:getAnswer(1), ANSWER.YES)
    assertEquals(client:getAnswer(2), ANSWER.ASKED)

    -- Saved and loaded.
    local xml = {}
    world.dayOff:saveToXmlFile(xml)
    local loaded = TheContractorShowDayOff.new()
    loaded:loadFromXMLFile(xml)
    assertEquals(loaded.showId, world.dayOff.showId)
    assertEquals(loaded:getAnswer(1), ANSWER.YES)
    assertEquals(loaded:getAnswer(2), ANSWER.ASKED)

    -- A deleted farm's answer goes.
    world.dayOff:forgetFarm(1)
    assertEquals(world.dayOff:getAnswer(1), nil)

    -- The next show: asked afresh.
    world.dayOff:reset(world.dayOff.showId + 1)
    assertEquals(world.dayOff:getAnswer(2), nil)
end)

test("a called-off show sends the staff home and drops the asks; the console asks and answers whatever the date", function()
    local world = setup()
    local amy = world:addWorker({ id = 1 })
    world:addWorker({ id = 2, farmId = 2 })
    announce(world)
    -- The console, before the ask's day.
    assertEquals(world.dayOff:getAnswer(1), nil)
    world.dayOff:consoleAsk(1, nil)
    assertEquals(world.dayOff:getAnswer(1), ANSWER.ASKED)
    assertEquals(#askMessages(world, 1), 1)
    world.dayOff:consoleAsk(1, "yes")
    assertEquals(world.dayOff:getAnswer(1), ANSWER.YES)
    assertEquals(#askMessages(world, 1), 0)
    assertEquals(moraleFor(world, 1)[1].delta, TCShowDayOff.getMoraleDelta(true))

    runToDay(world, SHOW_DAY - 1)
    assertEquals(#askMessages(world, 2), 1)
    runToDay(world, SHOW_DAY)
    assertEquals(amy.status, STATUS.SHOW)
    world.tc.Show:cancel(true)
    assertEquals(amy.status, STATUS.IDLE, "sent home")
    assertEquals(world.dayOff.showId, nil)
    assertEquals(world.dayOff:getAnswer(1), nil)
end)

test("a called-off show before the day takes the asks away", function()
    local world = setup()
    world:addWorker({ id = 1 })
    announce(world)
    runToDay(world, TheContractorShowDayOff.getAskDay(world.tc.Show:getEvent()))
    assertEquals(#askMessages(world, 1), 1)
    world.tc.Show:cancel(true)
    assertEquals(#askMessages(world, 1), 0)
    assertEquals(#world.morale, 0, "a no it wasn't")
end)
