-- Vanilla AI helper notifications for our workers: dropped for a contract
-- job, under the worker's name for a staff driver, untouched for anyone
-- else's helper. Vanilla's AIJob/AIJobVehicle are cut down to the parts
-- the hooks wrap, as in ../Reference/FS25_Lua.

local function setup()
    local world = stubs.install()
    Enterable = {}
    FSBaseMission.INGAME_NOTIFICATION_INFO = "info"
    TheContractorJob = { STATE = { ALLOCATED = "allocated", IN_PROGRESS = "in_progress", COMPLETED = "completed" } }

    -- Vanilla: the helper's title, and stop() showing the message built
    -- from it to the farm that started the job.
    world.helperTitle = "AI Worker B"
    AIJob = {
        start = function(self, farmId)
            self.startedFarmId = farmId
        end,
        getHelperName = function(self)
            return world.helperTitle
        end,
        showNotification = function(self, aiMessage)
            g_currentMission:addIngameNotification(FSBaseMission.INGAME_NOTIFICATION_OK,
                string.format(aiMessage.text, self:getHelperName()))
        end,
    }
    AIJobVehicle = {
        aiBlock = function(self)
            g_currentMission:addIngameNotification(FSBaseMission.INGAME_NOTIFICATION_CRITICAL,
                string.format(g_i18n:getText("ai_messageErrorBlockedByObject"), world.helperTitle))
            self:raiseAIEvent("onAIJobVehicleBlock", "onAIImplementJobVehicleBlock")
        end,
    }
    -- Vanilla's texts are just the name here, so a notification is the
    -- name it was shown under.
    world.texts["ai_messageErrorBlockedByObject"] = "%s"

    world:load("src/util/TCWorkerAppearance.lua")
    world:load("src/util/TCAINotifications.lua")

    g_localPlayer = { farmId = 1 }
    world.workers = {}
    world.bindings = {}
    world.jobs = {}
    g_currentMission.TheContractor = {
        Staff = {
            getWorker = function(_, farmId, workerId)
                local worker = world.workers[workerId]
                return worker ~= nil and worker.farmId == farmId and worker or nil
            end,
        },
        Drivers = {
            getBinding = function(_, vehicle)
                return world.bindings[vehicle.id]
            end,
        },
        Jobs = {
            getAllJobs = function(_, farmId)
                return world.jobs
            end,
        },
    }
    return world
end

local function addWorker(world, id, name)
    local worker = { id = id, farmId = 1, name = name }
    world.workers[id] = worker
    return worker
end

local function addVehicle(world)
    local vehicle = world:addVehicle({ farmId = 1 })
    vehicle.isClient = true
    vehicle.raised = {}
    function vehicle:getAIJobFarmId()
        return 1
    end
    function vehicle:raiseAIEvent(eventName)
        table.insert(self.raised, eventName)
    end
    return vehicle
end

local function addContractJob(world, worker, vehicle)
    local job = { assignedWorkerId = worker.id, assignedEquipmentIds = { vehicle.id },
        state = TheContractorJob.STATE.ALLOCATED }
    table.insert(world.jobs, job)
    return job
end

-- An AI job on `vehicle`, set up like vanilla's: a vehicle parameter, and
-- AIJob's functions through its metatable, as a subclass finds them.
local function newAIJob(vehicle)
    local aiJob = setmetatable({}, { __index = AIJob })
    aiJob.vehicleParameter = {
        getVehicle = function()
            return vehicle
        end,
    }
    return aiJob
end

local finished = { text = "%s" }

test("a contract job's finish and blocked messages are dropped", function()
    local world = setup()
    local worker = addWorker(world, 3, "Ross")
    local vehicle = addVehicle(world)
    local job = addContractJob(world, worker, vehicle)

    local aiJob = newAIJob(vehicle)
    aiJob:start(1)
    AIJobVehicle.aiBlock(vehicle)
    -- The contract job's finished before the AI job reports stopping.
    job.state = TheContractorJob.STATE.COMPLETED
    aiJob:showNotification(finished)

    assertEquals(#world.notifications, 0)
    assertEquals(vehicle.raised[1], "onAIJobVehicleBlock", "the block still reaches the AI")
end)

test("a staff driver's messages use the worker's name", function()
    local world = setup()
    addWorker(world, 3, "Ross")
    local vehicle = addVehicle(world)
    world.bindings[vehicle.id] = { farmId = 1, workerId = 3 }

    local aiJob = newAIJob(vehicle)
    aiJob:start(1)
    assertEquals(aiJob:getHelperName(), "Ross", "map list")
    AIJobVehicle.aiBlock(vehicle)
    aiJob:showNotification(finished)

    assertEquals(#world.notifications, 2)
    assertEquals(world.notifications[1].text, "Ross")
    assertEquals(world.notifications[2].text, "Ross")
    assertEquals(#vehicle.raised, 1)
end)

test("a worker renamed mid-job is shown under the new name", function()
    local world = setup()
    local worker = addWorker(world, 3, "Ross")
    local vehicle = addVehicle(world)
    world.bindings[vehicle.id] = { farmId = 1, workerId = 3 }

    local aiJob = newAIJob(vehicle)
    aiJob:start(1)
    worker.name = "Rosie"
    aiJob:showNotification(finished)
    assertEquals(world.notifications[1].text, "Rosie")

    -- Gone from the roster by the end: the name from the start.
    world.workers[3] = nil
    assertEquals(aiJob:getHelperName(), "Ross")
end)

test("someone else's helper is left alone", function()
    local world = setup()
    local vehicle = addVehicle(world)

    local aiJob = newAIJob(vehicle)
    aiJob:start(1)
    AIJobVehicle.aiBlock(vehicle)
    aiJob:showNotification(finished)

    assertEquals(#world.notifications, 2)
    assertEquals(world.notifications[1].text, "AI Worker B")
    assertEquals(world.notifications[2].text, "AI Worker B")
end)

test("the same AI job started again forgets its last driver", function()
    local world = setup()
    addWorker(world, 3, "Ross")
    local vehicle = addVehicle(world)
    world.bindings[vehicle.id] = { farmId = 1, workerId = 3 }

    local aiJob = newAIJob(vehicle)
    aiJob:start(1)
    world.bindings[vehicle.id] = nil
    aiJob:start(1)
    assertEquals(aiJob:getHelperName(), "AI Worker B")
end)

test("a job with no vehicle parameter is left alone", function()
    local world = setup()
    local aiJob = setmetatable({}, { __index = AIJob })
    aiJob:start(1)
    aiJob:showNotification(finished)
    assertEquals(world.notifications[1].text, "AI Worker B")
end)
