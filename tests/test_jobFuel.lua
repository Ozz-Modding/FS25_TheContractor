-- TCJobFuel (029, 063): per-job fuel accounting, "helper buys fuel" off
-- for contract vehicles, and the travel burn.

local fakes = dofile("tests/fakes.lua")

local function setup()
    local world = stubs.install()
    fakes.installContractor(world)
    return world
end

local function dieselLevel(vehicle)
    return vehicle:getFillUnitFillLevel(vehicle.spec_motorized.consumersByFillType[FillType.DIESEL].fillUnitIndex)
end

-- 3 miles at 30 km/h, 0.45 load, 40 l/h: 579.4 s of driving.
local function expectedTravelLiters(usagePerHour, fuelUsageFactor)
    local travelMs = 3 * 1609.344 / (30 / 3.6) * 1000
    return usagePerHour / 3600000 * 0.45 * fuelUsageFactor * travelMs
end

test("contract vehicles burn their own tank whatever helper buys fuel says", function()
    local world = setup()
    local tractor = world:addVehicle({ dieselUsagePerHour = 40, isAIActive = true })
    world:addJob({ workerId = 3, vehicles = { tractor }, working = true })
    TCJobSupplies.update(TCJobSupplies.POLL_INTERVAL_MS)

    Motorized.updateConsumers(tractor, 16, 1)

    assertEquals(world.helperBuyFuelSeen, false, "helperBuyFuel inside updateConsumers")
    assertEquals(g_currentMission.missionInfo.helperBuyFuel, true, "setting put back")
end)

test("other vehicles still follow helper buys fuel", function()
    local world = setup()
    local tractor = world:addVehicle({ dieselUsagePerHour = 40, isAIActive = true })
    TCJobSupplies.update(TCJobSupplies.POLL_INTERVAL_MS)

    Motorized.updateConsumers(tractor, 16, 1)

    assertEquals(world.helperBuyFuelSeen, true, "helperBuyFuel inside updateConsumers")
end)

test("a contract job's fuel is priced without the helper surcharge", function()
    local world = setup()
    local tractor = world:addVehicle({ dieselUsagePerHour = 40, isAIActive = true, fuelStep = 2 })
    local job = world:addJob({ workerId = 3, vehicles = { tractor }, working = true })
    TCJobSupplies.update(TCJobSupplies.POLL_INTERVAL_MS)

    Motorized.updateConsumers(tractor, 16, 1)

    assertNear(job.fuelUsedLiters, 2, 0.0001, "liters")
    assertNear(job.fuelCost, 2 * 1.5, 0.0001, "cost")
end)

test("a vanilla helper on a player's job keeps the 1.5x surcharge", function()
    local world = setup()
    local tractor = world:addVehicle({ dieselUsagePerHour = 40, isAIActive = true, fuelStep = 2 })
    local job = world:addJob({ jobType = "plough", vehicles = { tractor } })
    TCJobSupplies.update(TCJobSupplies.POLL_INTERVAL_MS)

    Motorized.updateConsumers(tractor, 16, 1)

    assertNear(job.fuelCost, 2 * 1.5 * 1.5, 0.0001, "cost")
end)

test("setting off burns 3 miles of diesel, counted as the job's fuel", function()
    local world = setup()
    local tractor = world:addVehicle({ dieselUsagePerHour = 40, dieselLevel = 400 })
    local job = world:addJob({ workerId = 3, vehicles = { tractor }, state = TheContractorJob.STATE.ALLOCATED })
    local expected = expectedTravelLiters(40, 1.5)

    local ranDry = TCJobFuel.burnTravelFuel(job)

    assertEquals(ranDry, false, "ran dry")
    assertNear(400 - dieselLevel(tractor), expected, 0.0001, "burned")
    assertNear(expected, 4.345, 0.001, "about 4 l for a 40 l/h tractor")
    assertNear(job.fuelUsedLiters, expected, 0.0001, "job liters")
    assertNear(job.fuelCost, expected * 1.5, 0.0001, "job cost")
    assertEquals(world.farmStats[1].statName, "fuelUsage", "farm stat")
    assertNear(world.farmStats[1].delta, expected, 0.0001, "farm stat liters")
end)

test("the travel burn follows the game's fuel usage setting", function()
    local world = setup()
    local job = world:addJob({ workerId = 3, vehicles = { world:addVehicle({ dieselUsagePerHour = 40 }) } })

    g_currentMission.missionInfo.fuelUsage = 1
    job.fuelUsedLiters = 0
    TCJobFuel.burnTravelFuel(job)
    assertNear(job.fuelUsedLiters, expectedTravelLiters(40, 1), 0.0001, "low")

    g_currentMission.missionInfo.fuelUsage = 3
    job.fuelUsedLiters = 0
    TCJobFuel.burnTravelFuel(job)
    assertNear(job.fuelUsedLiters, expectedTravelLiters(40, 2.5), 0.0001, "high")
end)

test("the travel burn never takes more than is in the tank, and says when it ran dry", function()
    local world = setup()
    local tractor = world:addVehicle({ dieselUsagePerHour = 40, dieselLevel = 2 })
    local job = world:addJob({ workerId = 3, vehicles = { tractor } })

    assertEquals(TCJobFuel.burnTravelFuel(job), true, "ran dry")
    assertEquals(dieselLevel(tractor), 0, "tank")
    assertNear(job.fuelUsedLiters, 2, 0.0001, "job liters")
end)

test("the travel burn skips machines without a diesel tank", function()
    local world = setup()
    local plough = world:addVehicle({ name = "Plough" })
    local job = world:addJob({ workerId = 3, vehicles = { plough } })

    assertEquals(TCJobFuel.burnTravelFuel(job), false, "ran dry")
    assertEquals(job.fuelUsedLiters, 0, "job liters")
end)

test("the haulage rig burns the trip's diesel too", function()
    local world = setup()
    local combine = world:addVehicle({ dieselUsagePerHour = 40, dieselLevel = 400 })
    local haulTractor = world:addVehicle({ dieselUsagePerHour = 40, dieselLevel = 400 })
    local job = world:addJob({ workerId = 3, vehicles = { combine }, haulerId = 4, haulageVehicles = { haulTractor } })
    local expected = expectedTravelLiters(40, 1.5)

    TCJobFuel.burnTravelFuel(job)

    assertNear(400 - dieselLevel(haulTractor), expected, 0.0001, "haul tractor burned")
    assertNear(job.fuelUsedLiters, expected * 2, 0.0001, "job liters")
end)

test("each load carted burns a round trip from the haulage rig only", function()
    local world = setup()
    local combine = world:addVehicle({ dieselUsagePerHour = 40, dieselLevel = 400 })
    local haulTractor = world:addVehicle({ dieselUsagePerHour = 40, dieselLevel = 400 })
    local job = world:addJob({ workerId = 3, vehicles = { combine }, haulerId = 4, haulageVehicles = { haulTractor } })
    local expected = expectedTravelLiters(40, 1.5)

    assertEquals(TCJobFuel.burnCartingFuel(job), false, "ran dry")
    TCJobFuel.burnCartingFuel(job)

    assertNear(400 - dieselLevel(haulTractor), expected * 2, 0.0001, "two loads")
    assertEquals(dieselLevel(combine), 400, "combine untouched")
    assertNear(job.fuelUsedLiters, expected * 2, 0.0001, "job liters")
end)
