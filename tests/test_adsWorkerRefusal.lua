-- 150: FS25_AdvancedDamageSystem's AI worker refusal. A machine ADS won't
-- let a hired worker drive can't be allocated to one, and a job ADS stops
-- for it, as it sets off or mid-shift, goes on hold until it's serviced.

-- A fake ADS: refusal and self-service on, and each vehicle's refusal
-- reasons as ADS_AIWorker.getRefusalReasons gives them.
local function installADS(world)
    local ads = { refusal = true, selfService = true, reasons = {} }
    local messageClass = {}
    ads.env = {
        ADS_AIWorker = {
            isRefusalEnabled = function() return ads.refusal end,
            isSelfServiceEnabled = function() return ads.selfService end,
            getRefusalReasons = function(vehicle) return ads.reasons[vehicle] or {} end,
        },
        ADS_AIMessageErrorPoorMaintenance = messageClass,
    }
    function ads.refusalMessage()
        return {
            isa = function(_, class) return class == messageClass end,
            getType = function() return AIMessageType.ERROR end,
            getMessage = function() return "refused" end,
        }
    end
    world:load("src/util/TCADSWorkerRefusal.lua")
    TCADSWorkerRefusal.getEnv = function() return ads.env end
    return ads
end

local function addADSVehicle(world, name)
    local vehicle = world:addVehicle({ name = name })
    vehicle.spec_AdvancedDamageSystem = {}
    return vehicle
end

-- The refusal itself -----------------------------------------------------------

test("a machine with a fluid, filter or grease point past its limit is refused", function()
    local world = stubs.install()
    local ads = installADS(world)
    local tractor = addADSVehicle(world, "Tractor")
    assertEquals(TCADSWorkerRefusal.isRefused(tractor), false, "in good order")

    ads.reasons[tractor] = { { key = "motorOil", operation = "replace", severity = 0.4 } }
    assertTrue(TCADSWorkerRefusal.isRefused(tractor))
    assertTrue(TCADSWorkerRefusal.getRefusedVehicle({ tractor.id }) == tractor)
end)

test("grease alone isn't, while ADS's worker greases it themselves", function()
    local world = stubs.install()
    local ads = installADS(world)
    local tractor = addADSVehicle(world, "Tractor")
    ads.reasons[tractor] = { { key = "chassisLubrication", operation = "lubricate", severity = 0.5 } }

    assertEquals(TCADSWorkerRefusal.isRefused(tractor), false)
    ads.selfService = false
    assertTrue(TCADSWorkerRefusal.isRefused(tractor))
end)

test("nothing's refused with ADS's refusal off, ADS absent or too old, or the machine outside ADS", function()
    local world = stubs.install()
    local ads = installADS(world)
    local tractor = addADSVehicle(world, "Tractor")
    ads.reasons[tractor] = { { key = "coolant", operation = "topUp", severity = 1 } }

    ads.refusal = false
    assertEquals(TCADSWorkerRefusal.isRefused(tractor), false, "refusal off")
    ads.refusal = true

    function tractor:getIsADSExcluded() return true end
    assertEquals(TCADSWorkerRefusal.isRefused(tractor), false, "excluded from ADS")
    tractor.getIsADSExcluded = nil

    local plain = world:addVehicle({ name = "No ADS" })
    ads.reasons[plain] = ads.reasons[tractor]
    assertEquals(TCADSWorkerRefusal.isRefused(plain), false, "no ADS on it")

    ads.env.ADS_AIWorker.getRefusalReasons = nil
    assertEquals(TCADSWorkerRefusal.isRefused(tractor), false, "an ADS without the refusal")

    TCADSWorkerRefusal.getEnv = function() return nil end
    assertEquals(TCADSWorkerRefusal.isRefused(tractor), false, "no ADS")
end)

test("ADS's stop message is told from any other", function()
    local world = stubs.install()
    local ads = installADS(world)
    assertTrue(TCADSWorkerRefusal.isRefusalMessage(ads.refusalMessage()))
    assertEquals(TCADSWorkerRefusal.isRefusalMessage({ isa = function() return false end }), false)
    assertEquals(TCADSWorkerRefusal.isRefusalMessage(nil), false)
end)

-- Allocating -----------------------------------------------------------------------

local function setupAllocation()
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
    world:load("src/business/Job.lua")
    world:load("src/business/Jobs.lua")
    world:load("src/business/YardBales.lua")
    world:load("src/business/YardHaul.lua")
    world:load("src/business/EmergencyRefuel.lua")
    world:load("src/business/CropSpill.lua")
    world:load("src/business/JobGeneration.lua")
    world:load("src/business/Allocation.lua")
    local ads = installADS(world)

    world.dispatched = {}
    TCFieldPreparation = { prepareFieldForJob = function() end }
    TCJobProgress = { clearJob = function() end }
    TCFieldAccess = { refresh = function() end }
    TCJobSupplies = { topUp = function() end }
    TCHaulage = { startDelivery = function() end, resumeDelivery = function() end }
    TCJobAllocatedEvent = { new = function(job) return { job = job } end }
    TheContractorWorker = { STATUS = { ASSIGNED = "assigned" } }
    TheContractorWorkingHours = { isAvailable = function() return true end }
    TCEquipmentClass = {
        isTractor = function() return true end,
        isHarvester = function() return false end,
        isTrailerFor = function() return false end,
    }

    local tc = g_currentMission.TheContractor
    tc.Jobs = TheContractorJobs.new()
    tc.Allocation = TheContractorAllocation.new()
    tc.Allocation.getMissingFromSelection = function() return {} end
    tc.Allocation.isVehicleFree = function() return true end
    tc.Allocation.assignCrewRoles = function(_, _, _, workerIds)
        return workerIds[1], nil, TheContractorAllocation.CAPABILITY.OK
    end
    tc.Staff = {
        getWorker = function(_, _, workerId) return { id = workerId, name = "John White" } end,
        setWorkerStatus = function() end,
    }
    tc.Dispatch = { startJobForWorker = function(_, job) table.insert(world.dispatched, job.id) end }
    tc.Parking = { isPending = function() return false end, sendToShop = function() return {} end }
    return world, tc, ads
end

local function addAcceptedJob(tc, id)
    local job = TheContractorJob.new(id, 1, "lime", 7, 1, 1, 1, 1000)
    job.state = TheContractorJob.STATE.ACCEPTED
    tc.Jobs:registerJob(job, false)
    return job
end

test("a hired worker can't be given a machine ADS would refuse", function()
    local world, tc, ads = setupAllocation()
    local job = addAcceptedJob(tc, 1)
    local tractor = addADSVehicle(world, "MT635")
    ads.reasons[tractor] = { { key = "airFilter", operation = "replace", severity = 0.3 } }

    assertTrue(not tc.Allocation:allocateJob(1, job.id, { 3 }, { tractor.id }, {}, nil, "Farmhand"))
    assertEquals(job.state, TheContractorJob.STATE.ACCEPTED)
    assertEquals(#world.dispatched, 0)
    assertTrue(TheContractorAllocation.getServiceRefusedVehicle({ tractor.id }) == tractor, "the picker's warning")

    ads.reasons[tractor] = nil
    assertTrue(tc.Allocation:allocateJob(1, job.id, { 3 }, { tractor.id }, {}, nil, "Farmhand"))
    assertEquals(world.dispatched[1], job.id)
end)

test("the player can still drive it on their own job", function()
    local world, tc, ads = setupAllocation()
    local job = addAcceptedJob(tc, 1)
    local tractor = addADSVehicle(world, "MT635")
    ads.reasons[tractor] = { { key = "motorOil", operation = "replace", severity = 0.3 } }

    assertTrue(tc.Allocation:allocateJob(1, job.id, {}, { tractor.id }, {}, nil, "Farmhand"))
    assertEquals(job.state, TheContractorJob.STATE.ALLOCATED)
end)

-- Dispatching ------------------------------------------------------------------------

local function setupDispatch()
    local world = stubs.install()
    TheContractorNegotiation = { rollInitialEagerness = function() return 1 end }
    world:load("src/business/Job.lua")
    TCAINotifications = { getVehicle = function(aiJob) return aiJob.vehicleParameter:getVehicle() end }
    world:load("src/business/Dispatch.lua")
    local ads = installADS(world)
    TCJobSupplies = { STATUS = { NEEDS_SERVICE = "needsService" },
        topUp = function() return 0, nil, nil, 0 end }
    TCJobSiteSetup = { selectJobSeed = function() end }
    world.fuelBurnt = 0
    TCJobFuel = { burnTravelFuel = function() world.fuelBurnt = world.fuelBurnt + 1 return false end }
    AIMessageType = { ERROR = 3, OK = 1 }
    AIMessageErrorOutOfFill = {}
    AIMessageErrorOutOfFuel = {}

    world.jobs = {}
    world.statuses = {}
    g_currentMission.TheContractor.Jobs = {
        getJobById = function(_, jobId) return world.jobs[jobId] end,
        setJobSupplyStatus = function(_, job, status, name)
            job.supplyStatus = status
            job.supplyFillTypeName = name
            table.insert(world.statuses, { status = status, name = name })
        end,
    }
    local dispatch = TheContractorDispatch.new()
    return world, dispatch, ads
end

local function addWorkerJob(world, state)
    local job = TheContractorJob.new(1, 1, "lime", 27, 1, 1, 1, 1000)
    job.state = state
    job.assignedWorkerId = 3
    local tractor = addADSVehicle(world, "MT635")
    job.assignedEquipmentIds = { tractor.id }
    world.jobs[job.id] = job
    return job, tractor
end

test("a worker doesn't set off with a machine ADS would refuse: the job waits for a service", function()
    local world, dispatch, ads = setupDispatch()
    local job, tractor = addWorkerJob(world, TheContractorJob.STATE.ALLOCATED)
    ads.reasons[tractor] = { { key = "coolant", operation = "topUp", severity = 0.2 } }

    dispatch:startJobForWorker(job)

    assertEquals(job.supplyStatus, "needsService")
    assertEquals(job.supplyFillTypeName, "MT635")
    assertEquals(dispatch:isJobActive(job), false, "not on the road")
    assertEquals(world.fuelBurnt, 0, "no trip's diesel for a trip not taken")
end)

test("ADS stopping the job, at the start or mid-shift, puts it on hold rather than leaving it stuck", function()
    local world, dispatch, ads = setupDispatch()
    local job, tractor = addWorkerJob(world, TheContractorJob.STATE.IN_PROGRESS)
    local aiJob = { vehicleParameter = { getVehicle = function() return tractor end } }
    dispatch.aiJobByOurJobId[job.id] = aiJob
    dispatch.ourJobIdByAIJob[aiJob] = job.id
    ads.reasons[tractor] = { { key = "hydraulicOilFilter", operation = "replace", severity = 0.6 } }

    dispatch:onAIJobStopped(aiJob, ads.refusalMessage())

    assertEquals(job.supplyStatus, "needsService")
    assertEquals(job.supplyFillTypeName, "MT635")
    assertEquals(dispatch:isJobActive(job), false, "free for the poll to restart")
    assertEquals(dispatch:takeRanOutOfFill(job.id), false, "not a supplies problem")
    assertEquals(job.state, TheContractorJob.STATE.IN_PROGRESS, "not completed")
end)

test("once it's serviced the worker carries on", function()
    local world, dispatch, ads = setupDispatch()
    local job, tractor = addWorkerJob(world, TheContractorJob.STATE.IN_PROGRESS)
    ads.reasons[tractor] = { { key = "motorOil", operation = "replace", severity = 0.6 } }
    dispatch:startJobForWorker(job, true)
    assertEquals(job.supplyStatus, "needsService")

    -- Still due a service: still held, and said once.
    dispatch:startJobForWorker(job, true)
    assertEquals(#world.statuses, 2)
    assertEquals(job.supplyStatus, "needsService")

    ads.reasons[tractor] = nil
    TCEquipmentVisibility = { setVisibleEverywhere = function() end }
    TCVehicleLock = { refresh = function() end }
    g_currentMission.TheContractor.Parking = { removeVehicles = function() end }
    g_currentMission.TheContractor.Jobs.markWorkStarted = function() end
    TCJobConsequences = { recordStartCondition = function() end }
    TCJobSiteSetup.detachForeignImplements = function() end
    dispatch:startJobForWorker(job, true)

    assertEquals(job.supplyStatus, nil, "off hold")
    assertTrue(dispatch:isJobActive(job), "back out to work")
end)
