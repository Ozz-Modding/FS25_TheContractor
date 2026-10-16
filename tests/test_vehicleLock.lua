-- TCVehicleLock: equipment away on a hired-worker job (travelling, working
-- or on hold), in a cooldown, waiting to be parked or stolen can't be sold.
-- The server refuses the SellVehicleEvent with vanilla's "in use" reply;
-- anything else sells as normal.

local STATE = { ALLOCATED = "allocated", IN_PROGRESS = "in_progress", COMPLETED = "completed" }

local function setup()
    local world = stubs.install()

    -- Vanilla's server half, reduced to what the hook decides between.
    world.sold, world.replies = {}, {}
    SellVehicleEvent = { SELL_VEHICLE_IN_USE = 1 }
    function SellVehicleEvent.run(event, connection)
        table.insert(world.sold, event.vehicle.id)
    end
    function SellVehicleEvent.newServerToClient(errorCode, sellPrice, isDirectSell, isOwned, ownerFarmId)
        return { errorCode = errorCode, sellPrice = sellPrice, isOwned = isOwned, ownerFarmId = ownerFarmId }
    end
    VehiclePropertyState = { OWNED = 1 }
    TheContractorJob = { STATE = STATE }

    world.jobs, world.cooldown, world.parking, world.stolen = {}, {}, {}, {}
    local tc = g_currentMission.TheContractor
    tc.Jobs = {
        getAllJobs = function(_, farmId)
            local result = {}
            for _, job in ipairs(world.jobs) do
                if job.farmId == farmId then
                    table.insert(result, job)
                end
            end
            return result
        end,
    }
    tc.Cooldown = { vehicleIdsInCooldown = world.cooldown }
    tc.Parking = { entryByVehicleId = world.parking }
    tc.Theft = {
        getStolenVehicleIds = function()
            return world.stolen
        end,
    }

    world:load("src/util/TCVehicleLock.lua")
    TCVehicleLock.reset()
    return world
end

local function addSellable(world, name)
    local vehicle = world:addVehicle({ name = name })
    vehicle.propertyState = VehiclePropertyState.OWNED
    return vehicle
end

local function addJob(world, state, workerId, vehicles)
    local ids = {}
    for _, vehicle in ipairs(vehicles) do
        table.insert(ids, vehicle.id)
    end
    local job = { farmId = 1, state = state, assignedWorkerId = workerId }
    function job:getAllEquipmentIds() return ids end
    table.insert(world.jobs, job)
    return job
end

-- A client's request: the server runs it with that client's connection.
local function sell(world, vehicle)
    local connection = {}
    function connection:getIsServer() return false end
    function connection:sendEvent(event) table.insert(world.replies, event) end
    SellVehicleEvent.run({ vehicle = vehicle, isDirectSell = false }, connection)
end

local function assertRefused(world, vehicle, label)
    sell(world, vehicle)
    assertEquals(#world.sold, 0, label .. ": not sold")
    assertEquals(#world.replies, 1, label .. ": one reply")
    assertEquals(world.replies[1].errorCode, SellVehicleEvent.SELL_VEHICLE_IN_USE, label .. ": in use")
    assertEquals(world.replies[1].sellPrice, 0, label .. ": nothing paid")
end

test("a travelling job's equipment can't be sold", function()
    local world = setup()
    local tractor = addSellable(world, "Tractor")
    addJob(world, STATE.ALLOCATED, 7, { tractor })

    assertRefused(world, tractor, "allocated")
end)

test("an in-progress job's equipment can't be sold, AI running or not", function()
    local world = setup()
    local plough = addSellable(world, "Plough")
    addJob(world, STATE.IN_PROGRESS, 7, { plough })

    assertRefused(world, plough, "in progress")
end)

-- Worked out live: no refresh has run since the job was allocated.
test("a job allocated since the last refresh already counts", function()
    local world = setup()
    local tractor = addSellable(world, "Tractor")
    TCVehicleLock.refresh()
    addJob(world, STATE.ALLOCATED, 7, { tractor })

    assertRefused(world, tractor, "fresh allocation")
end)

test("cooldown, the parking queue and stolen vehicles can't be sold", function()
    local world = setup()
    local inCooldown = addSellable(world, "Cooldown")
    local queued = addSellable(world, "Queued")
    local stolen = addSellable(world, "Stolen")
    world.cooldown[inCooldown.id] = true
    world.parking[queued.id] = {}
    world.stolen[stolen.id] = true

    assertRefused(world, inCooldown, "cooldown")
    world.replies = {}
    assertRefused(world, queued, "parking queue")
    world.replies = {}
    assertRefused(world, stolen, "stolen")
end)

test("something hitched to a job's machine can't be sold either", function()
    local world = setup()
    local tractor = addSellable(world, "Tractor")
    local trailer = addSellable(world, "Trailer")
    function trailer:getAttacherVehicle() return tractor end
    addJob(world, STATE.IN_PROGRESS, 7, { tractor })

    assertRefused(world, trailer, "hitched")
end)

test("idle equipment, a player's own job and a finished job's sell as normal", function()
    local world = setup()
    local idle = addSellable(world, "Idle")
    local playerJob = addSellable(world, "Player job")
    local finished = addSellable(world, "Finished")
    addJob(world, STATE.IN_PROGRESS, nil, { playerJob })
    addJob(world, STATE.COMPLETED, 7, { finished })

    sell(world, idle)
    sell(world, playerJob)
    sell(world, finished)

    assertEquals(#world.sold, 3, "all sold")
    assertEquals(#world.replies, 0, "vanilla replies itself")
end)

-- The client's half (the server's reply arriving) is vanilla's business.
test("the reply arriving on the client goes straight to vanilla", function()
    local world = setup()
    local tractor = addSellable(world, "Tractor")
    addJob(world, STATE.ALLOCATED, 7, { tractor })

    local connection = {}
    function connection:getIsServer() return true end
    SellVehicleEvent.run({ vehicle = tractor }, connection)

    assertEquals(#world.sold, 1, "passed through")
end)
