-- 094: unallocating a job. The crew and kit go back the way a missed job's
-- do (cooldown if work was done, the parking queue if the kit had left,
-- straight back otherwise), but the field is left alone and the job goes
-- back to accepted with its progress. The next allocation carries on from
-- there: no fresh field, no progress reset, and a player's deliveries so
-- far still count. The earlier crew goes on the job's logbook entry.

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

    world:load("src/business/Job.lua")
    world:load("src/business/Jobs.lua")
    world:load("src/business/YardBales.lua")
    world:load("src/business/YardHaul.lua")
    world:load("src/business/EmergencyRefuel.lua")
    world:load("src/business/CropSpill.lua")
    world:load("src/business/JobGeneration.lua")
    world:load("src/business/Allocation.lua")
    world:load("src/business/Logbook.lua")

    -- What's called out to, recorded.
    world.calls = {}
    local function record(name)
        return function(...)
            table.insert(world.calls, { name = name, args = { ... } })
        end
    end
    local function called(name)
        for _, call in ipairs(world.calls) do
            if call.name == name then
                return call
            end
        end
        return nil
    end
    world.called = called

    TCFieldPreparation = {
        prepareFieldForJob = record("prepareField"),
        clearUpAfterJob = record("clearUp"),
    }
    TCJobProgress = { clearJob = record("clearProgress") }
    TCFieldAccess = { refresh = record("refreshAccess") }
    TCJobSupplies = { topUp = record("topUp") }
    TCJobAllocatedEvent = { new = function(job) return { job = job } end }
    AIMessageSuccessStoppedByUser = { new = function() return {} end }
    TheContractorWorker = { STATUS = { ASSIGNED = "assigned", IDLE = "idle", COOLDOWN = "cooldown" }, MAX_SKILL = 10 }
    TCEquipmentClass = {
        isTractor = function() return true end,
        isHarvester = function() return false end,
        isTrailerFor = function() return false end,
    }

    -- The real resumeDelivery; the station lookups faked.
    world:load("src/util/TCHaulage.lua")
    TCHaulage.emptyHarvestersAfterJob = record("emptyHarvesters")
    TCHaulage.resolveDeliveryStation = function() return { missions = {} } end
    TCHaulage.getDeliveryFillType = function() return 1 end
    TCHaulage.getRequiredLiters = function() return 10000 end

    local tc = g_currentMission.TheContractor
    tc.Jobs = TheContractorJobs.new()
    tc.Allocation = TheContractorAllocation.new()
    tc.Allocation.getMissingFromSelection = function() return {} end
    tc.Allocation.isVehicleFree = function() return true end
    tc.Allocation.previewWorkerCapability = function() return TheContractorAllocation.CAPABILITY.CAPABLE end
    tc.Logbook = TheContractorLogbook.new()
    tc.Inbox = { removeMessagesForJob = function() end }

    world.workers = {}
    world.statuses = {}
    tc.Staff = {
        getWorker = function(_, farmId, workerId)
            return world.workers[workerId]
        end,
        setWorkerStatus = function(_, farmId, workerId, status)
            world.statuses[workerId] = status
        end,
    }
    -- active: the crew's out (on the road, or the AI running).
    world.active = {}
    tc.Dispatch = {
        isJobActive = function(_, job) return world.active[job.id] == true end,
        stopJob = record("stopJob"),
        takeRanOutOfFill = record("forgetRanOut"),
        startJobForWorker = record("dispatch"),
    }
    -- Like the real one, takes the job's crew and kit as they are now.
    tc.Cooldown = {
        startCooldown = function(_, job)
            table.insert(world.calls, { name = "cooldown", workerIds = job:getWorkerIds(),
                vehicleIds = job:getAllEquipmentIds() })
        end,
    }
    tc.Parking = {
        isPending = function() return false end,
        sendToShop = function() return {} end,
        returnVehicles = record("parkVehicles"),
        returnHiddenVehicles = record("parkHidden"),
    }
    return world, tc
end

local function addWorker(world, id, name)
    world.workers[id] = { id = id, name = name, isIdle = function() return true end }
    return id
end

-- An allocated job, with a crew of workerIds (none: player-driven) and one
-- tractor.
local function addJob(world, tc, def)
    local job = TheContractorJob.new(def.id or 1, 1, def.jobType or "cultivate", 7, 1, 1, 1, 1000)
    job.state = def.state or TheContractorJob.STATE.ALLOCATED
    job.assignedWorkerId = def.workerId
    job.haulerWorkerId = def.haulerId
    job.allocatedPlayerName = def.workerId == nil and "Farmhand" or nil
    job.completionPercentage = def.done or 0
    job.isTravelling = def.isTravelling == true
    job.includesHaulage = def.includesHaulage == true
    local tractor = world:addVehicle({ name = "Tractor" })
    job.assignedEquipmentIds = { tractor.id }
    tc.Jobs:registerJob(job, false)
    return job, tractor
end

-- Unallocating ---------------------------------------------------------------

test("a player-driven job goes back to accepted, its kit left where it is", function()
    local world, tc = setup()
    local job = addJob(world, tc, { done = 40 })

    assertTrue(tc.Jobs:unallocateJob(1, job.id))
    assertEquals(job.state, TheContractorJob.STATE.ACCEPTED)
    assertTrue(job.wasUnallocated)
    assertEquals(job.completionPercentage, 40, "progress kept")
    assertEquals(job.allocatedPlayerName, nil)
    assertEquals(#job.assignedEquipmentIds, 0)
    -- (Cooldown:startCooldown itself skips a job with no workers.)
    assertEquals(world.called("parkVehicles"), nil)
    assertEquals(world.called("parkHidden"), nil)
    assertTrue(world.called("refreshAccess") ~= nil, "the field's no longer theirs to work")
end)

test("the field is left alone: nothing's cleared up", function()
    local world, tc = setup()
    local job = addJob(world, tc, { jobType = "bale", done = 20 })
    job.spawnedBaleIds = { "bale1" }

    tc.Jobs:unallocateJob(1, job.id)
    assertEquals(world.called("clearUp"), nil)
    assertEquals(#job.spawnedBaleIds, 1)
end)

test("a hired crew that's made a start goes into cooldown, kit and all", function()
    local world, tc = setup()
    local worker = addWorker(world, 4, "Tom Smith")
    local job, tractor = addJob(world, tc, { workerId = worker, done = 30,
        state = TheContractorJob.STATE.IN_PROGRESS })
    world.active[job.id] = true

    assertTrue(tc.Jobs:unallocateJob(1, job.id))
    local cooldown = world.called("cooldown")
    assertTrue(cooldown ~= nil)
    assertEquals(cooldown.vehicleIds[1], tractor.id, "while the job still had its kit")
    assertEquals(cooldown.workerIds[1], worker)
    assertTrue(world.called("stopJob") ~= nil, "the AI's stopped")
    assertTrue(world.called("emptyHarvesters") ~= nil)
    assertEquals(job.assignedWorkerId, nil)
    assertEquals(job.state, TheContractorJob.STATE.ACCEPTED)
end)

test("a hired crew on the road with nothing done: workers idle, kit to the parking queue", function()
    local world, tc = setup()
    local worker = addWorker(world, 4, "Tom Smith")
    local job, tractor = addJob(world, tc, { workerId = worker, isTravelling = true })
    world.active[job.id] = true

    tc.Jobs:unallocateJob(1, job.id)
    assertEquals(world.called("cooldown"), nil)
    local parked = world.called("parkVehicles")
    assertTrue(parked ~= nil)
    assertEquals(parked.args[3][1], tractor.id)
    assertEquals(world.statuses[worker], "idle")
    assertEquals(job.isTravelling, false)
end)

test("a hired crew still in the yard: workers idle, only hidden kit is parked", function()
    local world, tc = setup()
    local worker = addWorker(world, 4, "Tom Smith")
    local job = addJob(world, tc, { workerId = worker })

    tc.Jobs:unallocateJob(1, job.id)
    assertEquals(world.called("parkVehicles"), nil)
    assertTrue(world.called("parkHidden") ~= nil)
    assertEquals(world.statuses[worker], "idle")
end)

test("a missed job's release still clears its field up", function()
    local world, tc = setup()
    local job = addJob(world, tc, { jobType = "bale" })
    tc.Jobs:releaseMissedJobResources(job)
    assertTrue(world.called("clearUp") ~= nil)
end)

test("only an allocated or in-progress job can be unallocated", function()
    local world, tc = setup()
    for i, state in ipairs({ TheContractorJob.STATE.ACCEPTED, TheContractorJob.STATE.COMPLETED,
        TheContractorJob.STATE.MISSED, TheContractorJob.STATE.OFFERED }) do
        local job = addJob(world, tc, { id = i, state = state })
        assertTrue(not tc.Jobs:unallocateJob(1, job.id), state)
        assertEquals(job.state, state)
    end
    assertTrue(not tc.Jobs:unallocateJob(1, 99), "no such job")
    assertTrue(not tc.Jobs:unallocateJob(2, 1), "another farm's")
    assertEquals(TheContractorJobs.getUnallocateProblem(nil), "tc_unallocate_problemGone")
end)

test("tcJob state <job> accepted unallocates; from an offer it's a plain accept", function()
    local world, tc = setup()
    local job = addJob(world, tc, { done = 10 })
    assertTrue(tc.Jobs:forceJobState(1, job.id, TheContractorJob.STATE.ACCEPTED))
    assertTrue(job.wasUnallocated)

    local offer = addJob(world, tc, { id = 2, state = TheContractorJob.STATE.OFFERED })
    assertTrue(tc.Jobs:forceJobState(1, offer.id, TheContractorJob.STATE.ACCEPTED))
    assertEquals(offer.state, TheContractorJob.STATE.ACCEPTED)
    assertTrue(not offer.wasUnallocated)
end)

-- Allocating again ----------------------------------------------------------------

test("allocating again carries on: no fresh field, progress kept", function()
    local world, tc = setup()
    local job = addJob(world, tc, { done = 40 })
    tc.Jobs:unallocateJob(1, job.id)
    world.calls = {}

    local tractor = world:addVehicle({ name = "Other tractor" })
    assertTrue(tc.Allocation:allocateJob(1, job.id, {}, { tractor.id }, {}, false, "Second"))
    assertEquals(world.called("prepareField"), nil)
    assertEquals(job.completionPercentage, 40)
    assertEquals(job.allocatedPlayerName, "Second")
    assertTrue(not job.wasUnallocated, "only once")

    -- A fresh job still gets its field prepared and starts from 0.
    local other = addJob(world, tc, { id = 2, state = TheContractorJob.STATE.ACCEPTED, done = 5 })
    assertTrue(tc.Allocation:allocateJob(1, other.id, {}, { tractor.id }, {}, false, "Second"))
    assertTrue(world.called("prepareField") ~= nil)
    assertEquals(other.completionPercentage, 0)
end)

test("a player's deliveries so far still count when a player takes it on again", function()
    local world, tc = setup()
    local job = addJob(world, tc, { jobType = "harvest", includesHaulage = true, done = 50 })
    job.requiredLiters = 8000
    job.deliveredLiters = 3000
    tc.Jobs:unallocateJob(1, job.id)
    assertEquals(job.deliveredLiters, 3000)

    TCHaulage.resumeDelivery(job)
    assertEquals(job.requiredLiters, 8000)
    assertEquals(job.deliveredLiters, 3000)
end)

test("after a hired crew, a player only delivers what's left on the field", function()
    local world, tc = setup()
    local worker = addWorker(world, 4, "Tom Smith")
    local job = addJob(world, tc, { jobType = "harvest", includesHaulage = true, workerId = worker, done = 60 })
    job.requiredLiters = 5000
    tc.Jobs:unallocateJob(1, job.id)
    assertEquals(job.requiredLiters, 0, "a hired crew's carting isn't counted")

    TCHaulage.resumeDelivery(job)
    assertNear(job.requiredLiters, 4000, 0.01)
    assertEquals(job.deliveredLiters, 0)
end)

-- Logbook and save -----------------------------------------------------------------

test("the earlier crew goes on the job's logbook entry", function()
    local world, tc = setup()
    addWorker(world, 4, "Tom Smith")
    addWorker(world, 5, "Ann Jones")
    local job = addJob(world, tc, { workerId = 4, haulerId = 5 })
    tc.Jobs:unallocateJob(1, job.id)
    assertEquals(tc.Logbook.pendingByJobId[job.id].earlierCrew, "Tom Smith, Ann Jones")

    job.state = TheContractorJob.STATE.ALLOCATED
    job.allocatedPlayerName = "Farmhand"
    tc.Jobs:unallocateJob(1, job.id)
    assertEquals(tc.Logbook.pendingByJobId[job.id].earlierCrew, "Tom Smith, Ann Jones; Farmhand")

    local stream = world:newStream()
    TheContractorLogbook.writeJobEntry(stream, { jobId = 1, farmId = 1, outcome = "completed", fieldId = 7, day = 1,
        earlierCrew = "Farmhand", crew = {}, equipment = {}, supplies = {} })
    assertEquals(TheContractorLogbook.readJobEntry(stream).earlierCrew, "Farmhand")
end)

test("a breakdown entry's field streams, and a workshop entry's lack of one", function()
    local world = setup()
    local stream = world:newStream()
    TheContractorLogbook.writeJobEntry(stream, { jobId = 1, farmId = 1, outcome = "completed", fieldId = 0, day = 1,
        jobType = "adsBreakdown", location = "Tractor, Field 12", workshopFieldId = 12, crew = {}, equipment = {},
        supplies = {} })
    TheContractorLogbook.writeJobEntry(stream, { jobId = 2, farmId = 1, outcome = "completed", fieldId = 0, day = 1,
        jobType = "adsRepair", location = "Tractor", crew = {}, equipment = {}, supplies = {} })
    assertEquals(TheContractorLogbook.readJobEntry(stream).workshopFieldId, 12)
    assertEquals(TheContractorLogbook.readJobEntry(stream).workshopFieldId, nil)
end)

test("the carry-on flag survives a save", function()
    local world, tc = setup()
    local job = addJob(world, tc, { done = 40 })
    tc.Jobs:unallocateJob(1, job.id)
    addJob(world, tc, { id = 2 })

    local xmlFile = {}
    tc.Jobs:saveToXmlFile(xmlFile)
    local loaded = TheContractorJobs.new()
    loaded:loadFromXMLFile(xmlFile)
    assertTrue(loaded:getJob(1, 1).wasUnallocated)
    assertTrue(not loaded:getJob(1, 2).wasUnallocated)
    assertEquals(loaded:getJob(1, 1).completionPercentage, 40)
end)
