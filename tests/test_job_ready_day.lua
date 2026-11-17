-- 132: a job's ready day. Offers get one from getDeadlineDay (a future
-- harvest's predicted ready day, today for anything else), allocation is
-- refused before it (the field's still forced into the job's start state
-- once it's allowed), it streams and saves with the job, and an older
-- save's unready harvest is given one at the first update.

local TODAY = 40
local READY = 60

local function setup()
    local world = stubs.install()
    TheContractor = { SaveKey = "TheContractor" }
    FinanceStats = { statNames = {}, statNameToIndex = {} }
    MoneyType = { LAST_ID = 0, register = function(name) return name end }
    TheContractorNegotiation = { rollInitialEagerness = function() return 1 end }
    TCJobConsequences = {
        saveToXML = function() end,
        loadFromXML = function() end,
        writeReports = function() end,
        readReports = function() return {} end,
    }
    TCVehicleIds = { saveList = function() end, loadList = function() return {} end }
    math.clamp = math.clamp or function(value, low, high)
        return math.max(low, math.min(high, value))
    end

    Environment = { PERIODS_IN_YEAR = 12 }
    Season = { SPRING = 0, SUMMER = 1, AUTUMN = 2, WINTER = 3 }
    g_currentMission.environment = {
        currentYear = 1,
        currentPeriod = 6,
        currentDayInPeriod = 1,
        daysPerPeriod = 10,
        currentHour = 0,
        currentMonotonicDay = TODAY,
        getSeasonAtDay = function() return Season.SUMMER end,
        getPeriodFromDay = function(_, day) return math.floor(day / 10) % 12 + 1 end,
        getDayInPeriodFromDay = function(_, day) return day % 10 + 1 end,
    }

    -- Wheat, harvest-ready from growth state 5.
    FruitType = { UNKNOWN = 0, WHEAT = 2 }
    local wheat = {
        index = FruitType.WHEAT,
        name = "WHEAT",
        getIsHarvestReady = function(_, growthState) return growthState >= 5 end,
    }
    g_fruitTypeManager = {
        getFruitTypeByIndex = function(_, index) return index == FruitType.WHEAT and wheat or nil end,
        getFruitTypeNameByIndex = function(_, index) return index == FruitType.WHEAT and "WHEAT" or nil end,
        getFruitTypeByName = function(_, name) return name == "WHEAT" and wheat or nil end,
    }

    world.fields = {}
    function world:addField(def)
        local field = {
            id = def.id,
            fieldState = { isValid = true, fruitTypeIndex = FruitType.WHEAT, growthState = def.growthState or 2 },
        }
        function field:getId() return self.id end
        function field:getFieldState() return self.fieldState end
        function field:getPlannedFruitTypeIndex() return FruitType.UNKNOWN end
        self.fields[def.id] = field
        return field
    end
    g_fieldManager = {
        getFieldById = function(_, fieldId) return world.fields[fieldId] end,
    }

    -- 010's prediction: ready on READY, for three days.
    world.readyOn = READY
    TCCropPrediction = {
        getEstimatedHarvestReadyDate = function()
            return world.readyOn ~= nil and { absoluteDay = world.readyOn } or nil
        end,
        isHarvestReadyOnDay = function(_, day)
            return day >= world.readyOn and day <= world.readyOn + 2
        end,
    }

    world:load("src/business/Job.lua")
    world:load("src/business/Jobs.lua")
    world:load("src/business/YardBales.lua")
    world:load("src/business/YardHaul.lua")
    world:load("src/business/EmergencyRefuel.lua")
    world:load("src/util/TCLotInspections.lua")
    world:load("src/business/CropSpill.lua")
    world:load("src/business/JobGeneration.lua")
    world:load("src/business/Allocation.lua")

    world.calls = {}
    local function record(name)
        return function(...)
            table.insert(world.calls, { name = name, args = { ... } })
        end
    end
    function world.called(name)
        for _, call in ipairs(world.calls) do
            if call.name == name then
                return call
            end
        end
        return nil
    end

    TCFieldPreparation = { prepareFieldForJob = record("prepareField") }
    TCJobProgress = { POLL_INTERVAL_MS = 3000, clearJob = function() end }
    TCFieldAccess = { refresh = function() end }
    TCJobSupplies = { topUp = function() end }
    TCHaulage = { startDelivery = function() end, resumeDelivery = function() end }
    TCJobAllocatedEvent = { new = function(job) return { job = job } end }
    TCJobCreatedEvent = { new = function(job) return { job = job } end }
    TheContractorWorker = { STATUS = { ASSIGNED = "assigned", IDLE = "idle" }, MAX_SKILL = 10 }
    TCEquipmentClass = {
        isTractor = function() return true end,
        isHarvester = function() return false end,
        isTrailerFor = function() return false end,
    }

    local tc = g_currentMission.TheContractor
    tc.Jobs = TheContractorJobs.new()
    tc.JobGeneration = TheContractorJobGeneration.new()
    tc.Allocation = TheContractorAllocation.new()
    tc.Allocation.getMissingFromSelection = function() return {} end
    tc.Allocation.isVehicleFree = function() return true end
    tc.Allocation.previewWorkerCapability = function() return TheContractorAllocation.CAPABILITY.CAPABLE end
    tc.Parking = { isPending = function() return false end, sendToShop = function() return {} end }
    tc.Staff = { getWorker = function() return nil end, setWorkerStatus = function() end }
    tc.Inbox = { removeMessagesForJob = function() end }
    return world, tc
end

-- An accepted job on field 7, ready from readyDay (nil: now).
local function addAcceptedJob(tc, id, jobType, readyDay)
    local job = TheContractorJob.new(id, 1, jobType, 7, 1, 1, 1, 1000)
    job.state = TheContractorJob.STATE.ACCEPTED
    job.deadlineDay = READY + 2
    job.readyDay = readyDay
    tc.Jobs:registerJob(job, false)
    return job
end

local function setToday(day)
    g_currentMission.environment.currentMonotonicDay = day
end

-- The offer's dates --------------------------------------------------------------

test("an unready harvest is ready from its predicted day; other work from today", function()
    local world, tc = setup()
    local field = world:addField({ id = 7 })
    local random = math.random
    math.random = function(_, high) return high end

    local deadlineDay, readyDay = tc.JobGeneration:getDeadlineDay(field,
        TheContractorJobGeneration.JOB_TYPES.harvest)
    assertEquals(readyDay, READY)
    assertEquals(deadlineDay, READY + TheContractorJobGeneration.MAX_EXTRA_DAYS)

    _, readyDay = tc.JobGeneration:getDeadlineDay(field, TheContractorJobGeneration.JOB_TYPES.plow)
    assertEquals(readyDay, TODAY)

    -- Late in the day the offer's deadline moves to tomorrow, but work could
    -- still start today.
    g_currentMission.environment.currentHour = 22
    _, readyDay = tc.JobGeneration:getDeadlineDay(field, TheContractorJobGeneration.JOB_TYPES.plow)
    assertEquals(readyDay, TODAY)

    -- A crop that's ready already is ready today.
    g_currentMission.environment.currentHour = 0
    field.fieldState.growthState = 5
    world.readyOn = TODAY
    _, readyDay = tc.JobGeneration:getDeadlineDay(field, TheContractorJobGeneration.JOB_TYPES.harvest)
    assertEquals(readyDay, TODAY)
    math.random = random
end)

test("createJob keeps the ready day it's given", function()
    local _, tc = setup()
    local job = tc.Jobs:createJob(1, "harvest", 7, 1, 7, 3, 1000, true, "WHEAT", READY + 2, false, nil, nil, nil,
        nil, nil, nil, nil, READY)
    assertEquals(job.readyDay, READY)
    local now = tc.Jobs:createJob(1, "plow", 7, 1, 5, 1, 1000, true, nil, TODAY + 1)
    assertEquals(now.readyDay, nil)
end)

test("isReady turns true on the ready day", function()
    local _, tc = setup()
    local job = addAcceptedJob(tc, 1, "harvest", READY)
    assertTrue(not job:isReady())
    assertEquals(job:getFutureReadyDay(), READY)
    setToday(READY - 1)
    assertTrue(not job:isReady())
    setToday(READY)
    assertTrue(job:isReady())
    assertEquals(job:getFutureReadyDay(), nil)

    local now = addAcceptedJob(tc, 2, "plow", nil)
    assertTrue(now:isReady())
    assertEquals(now:getFutureReadyDay(), nil)
end)

-- Allocation ---------------------------------------------------------------------

test("allocation is refused before the ready day, the field untouched", function()
    local world, tc = setup()
    local job = addAcceptedJob(tc, 1, "harvest", READY)
    local tractor = world:addVehicle({ name = "Combine" })

    assertTrue(not tc.Allocation:allocateJob(1, job.id, {}, { tractor.id }, {}, nil, "Farmhand"))
    assertEquals(job.state, TheContractorJob.STATE.ACCEPTED)
    assertEquals(world.called("prepareField"), nil)
    assertEquals(#job.assignedEquipmentIds, 0)
end)

test("from the ready day it allocates, and the field is still forced into the job's start state", function()
    local world, tc = setup()
    local job = addAcceptedJob(tc, 1, "harvest", READY)
    local tractor = world:addVehicle({ name = "Combine" })

    setToday(READY)
    assertTrue(tc.Allocation:allocateJob(1, job.id, {}, { tractor.id }, {}, nil, "Farmhand"))
    assertEquals(job.state, TheContractorJob.STATE.ALLOCATED)
    local prepared = world.called("prepareField")
    assertTrue(prepared ~= nil)
    assertEquals(prepared.args[1], job)
end)

test("a job with no ready day allocates at once", function()
    local world, tc = setup()
    local job = addAcceptedJob(tc, 1, "plow", nil)
    local tractor = world:addVehicle({ name = "Tractor" })
    assertTrue(tc.Allocation:allocateJob(1, job.id, {}, { tractor.id }, {}, nil, "Farmhand"))
    assertTrue(world.called("prepareField") ~= nil)
end)

-- Stream and save ----------------------------------------------------------------

test("the ready day streams, and its absence too", function()
    local world, tc = setup()
    local stream = world:newStream()
    TheContractorJobs.writeJob(stream, addAcceptedJob(tc, 1, "harvest", READY))
    TheContractorJobs.writeJob(stream, addAcceptedJob(tc, 2, "plow", nil))
    assertEquals(TheContractorJobs.readJob(stream).readyDay, READY)
    assertEquals(TheContractorJobs.readJob(stream).readyDay, nil)
end)

test("the ready day survives a save", function()
    local _, tc = setup()
    addAcceptedJob(tc, 1, "harvest", READY)
    addAcceptedJob(tc, 2, "plow", nil)
    local xmlFile = {}
    tc.Jobs:saveToXmlFile(xmlFile)

    local loaded = TheContractorJobs.new()
    loaded:loadFromXMLFile(xmlFile)
    loaded:resolveLegacyReadyDays()
    assertEquals(loaded:getJob(1, 1).readyDay, READY)
    assertEquals(loaded:getJob(1, 2).readyDay, nil)
end)

-- What brought an offer (Job.offerSource) rides on the same stream and save.
test("the offer source streams and survives a save, and its absence too", function()
    local world, tc = setup()
    local fromAdvert = addAcceptedJob(tc, 1, "harvest", nil)
    fromAdvert.offerSource = "localNewspaper"
    addAcceptedJob(tc, 2, "plow", nil)

    local stream = world:newStream()
    TheContractorJobs.writeJob(stream, tc.Jobs:getJob(1, 1))
    TheContractorJobs.writeJob(stream, tc.Jobs:getJob(1, 2))
    assertEquals(TheContractorJobs.readJob(stream).offerSource, "localNewspaper")
    assertEquals(TheContractorJobs.readJob(stream).offerSource, nil)

    local xmlFile = {}
    tc.Jobs:saveToXmlFile(xmlFile)
    local loaded = TheContractorJobs.new()
    loaded:loadFromXMLFile(xmlFile)
    assertEquals(loaded:getJob(1, 1).offerSource, "localNewspaper")
    assertEquals(loaded:getJob(1, 2).offerSource, nil)
end)

-- Older saves --------------------------------------------------------------------

test("an older save's unready harvest is given its predicted ready day", function()
    local world, tc = setup()
    world:addField({ id = 7 })
    local harvest = addAcceptedJob(tc, 1, "harvest", nil)
    local plow = addAcceptedJob(tc, 2, "plow", nil)
    local allocated = addAcceptedJob(tc, 3, "harvest", nil)
    allocated.state = TheContractorJob.STATE.ALLOCATED

    tc.Jobs:resolveLegacyReadyDays()
    assertEquals(harvest.readyDay, READY)
    assertEquals(plow.readyDay, nil)
    assertEquals(allocated.readyDay, nil, "already out: left alone")
end)

test("an older save's ripe or unpredictable harvest stays ready now; a late prediction stops at the deadline", function()
    local world, tc = setup()
    local field = world:addField({ id = 7, growthState = 5 })
    local job = addAcceptedJob(tc, 1, "harvest", nil)
    assertEquals(TheContractorJobs.getLegacyReadyDay(job), nil, "ripe")

    field.fieldState.growthState = 2
    world.readyOn = nil
    assertEquals(TheContractorJobs.getLegacyReadyDay(job), nil, "no prediction")

    world.readyOn = job.deadlineDay + 10
    assertEquals(TheContractorJobs.getLegacyReadyDay(job), job.deadlineDay)

    world.readyOn = TODAY
    assertEquals(TheContractorJobs.getLegacyReadyDay(job), nil, "ready today")
end)

test("the backfill runs on the first update after loading a save without ready days", function()
    local world, tc = setup()
    world:addField({ id = 7 })
    local job = addAcceptedJob(tc, 1, "harvest", nil)
    local xmlFile = {}
    tc.Jobs:saveToXmlFile(xmlFile)

    local loaded = TheContractorJobs.new()
    loaded:loadFromXMLFile(xmlFile)
    loaded.checkForCompletions = function() end
    loaded.updateGracePeriods = function() end
    assertEquals(loaded:getJob(1, job.id).readyDay, nil)
    loaded:update(0)
    assertEquals(loaded:getJob(1, job.id).readyDay, READY)
    assertTrue(not loaded.hasLegacyReadyDays)
end)
