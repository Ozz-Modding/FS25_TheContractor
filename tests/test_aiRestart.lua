-- Vanilla's AI restart after a load: skipped for a contract job's vehicle
-- (Dispatch resumes the job itself), left alone for a staff driver's
-- helper and anyone else's. AIFieldWorker is cut down to the restart in
-- its onUpdate, as in ../Reference/FS25_Lua.

local function setup()
    local world = stubs.install()
    Enterable = {}
    TheContractorJob = { STATE = { ALLOCATED = "allocated", IN_PROGRESS = "in_progress", COMPLETED = "completed" } }

    -- Vanilla: the first server update of a vehicle saved with its AI on
    -- sends a start request, as a player's AI button does.
    world.startRequests = {}
    AIFieldWorker = {
        onUpdate = function(self, dt)
            local spec = self.spec_aiFieldWorker
            if self.isServer and spec.pendingAIFieldWorkerStart then
                table.insert(world.startRequests, self)
                spec.pendingAIFieldWorkerStart = false
            end
        end,
    }

    world:load("src/util/TCWorkerAppearance.lua")
    world:load("src/util/TCAIRestart.lua")

    world.workers = {}
    world.bindings = {}
    world.jobs = {}
    -- Saved equipment is only turned into object ids when something asks
    -- for a binding (Drivers:getBinding -> resolveSavedVehicles), as on the
    -- first frame after a load.
    world.unresolved = {}
    g_currentMission.TheContractor = {
        Staff = {
            getWorker = function(_, farmId, workerId)
                local worker = world.workers[workerId]
                return worker ~= nil and worker.farmId == farmId and worker or nil
            end,
        },
        Drivers = {
            getBinding = function(_, vehicle)
                for _, entry in ipairs(world.unresolved) do
                    table.insert(entry.job.assignedEquipmentIds, entry.vehicle.id)
                end
                world.unresolved = {}
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

local function addWorker(world, id)
    local worker = { id = id, farmId = 1, name = "Worker " .. id }
    world.workers[id] = worker
    return worker
end

-- A vehicle as it loads from a save with its AI on.
local function addVehicle(world, isServer)
    local vehicle = world:addVehicle({ farmId = 1 })
    vehicle.isServer = isServer ~= false
    vehicle.spec_aiFieldWorker = { pendingAIFieldWorkerStart = true }
    function vehicle:getFullName()
        return self.name
    end
    return vehicle
end

local function addContractJob(world, worker, vehicle, state)
    local job = { assignedWorkerId = worker.id, assignedEquipmentIds = {},
        state = state or TheContractorJob.STATE.IN_PROGRESS }
    table.insert(world.unresolved, { job = job, vehicle = vehicle })
    table.insert(world.jobs, job)
    return job
end

test("a contract job's vehicle isn't restarted by vanilla", function()
    local world = setup()
    local worker = addWorker(world, 3)
    local vehicle = addVehicle(world)
    addContractJob(world, worker, vehicle)

    AIFieldWorker.onUpdate(vehicle, 16)

    assertEquals(#world.startRequests, 0)
    assertEquals(vehicle.spec_aiFieldWorker.pendingAIFieldWorkerStart, false, "not tried again next frame")
end)

test("an allocated job's vehicle is skipped too", function()
    local world = setup()
    local worker = addWorker(world, 3)
    local vehicle = addVehicle(world)
    addContractJob(world, worker, vehicle, TheContractorJob.STATE.ALLOCATED)

    AIFieldWorker.onUpdate(vehicle, 16)

    assertEquals(#world.startRequests, 0)
end)

test("a staff driver's helper restarts as vanilla does", function()
    local world = setup()
    addWorker(world, 3)
    local vehicle = addVehicle(world)
    world.bindings[vehicle.id] = { farmId = 1, workerId = 3 }

    AIFieldWorker.onUpdate(vehicle, 16)

    assertEquals(#world.startRequests, 1)
end)

test("a helper on a vehicle that's on no job restarts as vanilla does", function()
    local world = setup()
    local worker = addWorker(world, 3)
    local vehicle = addVehicle(world)
    local other = addVehicle(world)
    other.spec_aiFieldWorker.pendingAIFieldWorkerStart = false
    addContractJob(world, worker, other)

    AIFieldWorker.onUpdate(vehicle, 16)

    assertEquals(#world.startRequests, 1)
end)

test("a finished job's vehicle restarts as vanilla does", function()
    local world = setup()
    local worker = addWorker(world, 3)
    local vehicle = addVehicle(world)
    addContractJob(world, worker, vehicle, TheContractorJob.STATE.COMPLETED)

    AIFieldWorker.onUpdate(vehicle, 16)

    assertEquals(#world.startRequests, 1)
end)

test("nothing's looked up for a vehicle with no restart pending", function()
    local world = setup()
    local worker = addWorker(world, 3)
    local vehicle = addVehicle(world)
    vehicle.spec_aiFieldWorker.pendingAIFieldWorkerStart = false
    addContractJob(world, worker, vehicle)

    AIFieldWorker.onUpdate(vehicle, 16)

    assertEquals(#world.unresolved, 1, "saved equipment left for its own resolve")
    assertEquals(#world.startRequests, 0)
end)
