-- Cooldown (023, 062): a hired worker's equipment is hidden for the trip
-- back and then parked. A player-driven job has no cooldown: the player's
-- equipment stays where they left it.

local fakes = dofile("tests/fakes.lua")

local function setup()
    local world = stubs.install()
    fakes.installContractor(world)

    world.hidden, world.statuses, world.removedFromParking = {}, {}, {}
    TCEquipmentVisibility = {
        hideVehicles = function(vehicleIds)
            for _, vehicleId in ipairs(vehicleIds) do
                world.hidden[vehicleId] = true
            end
        end,
    }
    TheContractorJobs = { getSlowestWorker = function() return nil end }
    TheContractorWorker = {
        STATUS = { COOLDOWN = "cooldown", IDLE = "idle" },
        scaleBySpeed = function(_, slowest, fastest) return fastest end,
    }
    TCEquipmentCooldownStartedEvent = { new = function(entry) return entry end }

    local tc = g_currentMission.TheContractor
    tc.Parking = {
        removeVehicles = function(_, vehicleIds)
            for _, vehicleId in ipairs(vehicleIds) do
                table.insert(world.removedFromParking, vehicleId)
            end
        end,
    }
    tc.Staff = {
        setWorkerStatus = function(_, farmId, workerId, status)
            world.statuses[workerId] = status
        end,
    }

    world:load("src/business/Cooldown.lua")
    tc.Cooldown = TheContractorCooldown.new()
    return world, tc.Cooldown
end

test("a hired worker's equipment is hidden and buffered", function()
    local world, cooldown = setup()
    local tractor = world:addVehicle({})
    world:addJob({ workerId = 3, vehicles = { tractor } })

    cooldown:startCooldown(world.jobs[1])

    assertTrue(cooldown:isVehicleInCooldown(tractor.id), "in cooldown")
    assertTrue(world.hidden[tractor.id], "hidden")
    assertEquals(world.statuses[3], "cooldown")
end)

test("a player-driven job's equipment is left where the player left it", function()
    local world, cooldown = setup()
    local tractor = world:addVehicle({})
    world:addJob({ vehicles = { tractor } })

    cooldown:startCooldown(world.jobs[1])

    assertEquals(cooldown:isVehicleInCooldown(tractor.id), false, "in cooldown")
    assertEquals(world.hidden[tractor.id], nil, "hidden")
    assertEquals(next(cooldown.entriesByFarm), nil, "no cooldown entry, so nothing to park later")
end)
