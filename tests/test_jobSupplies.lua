-- TCJobSupplies (032, 063): job tanks topped up from the farm's own stock,
-- holds when there's none, and the Overview notices for them.

local fakes = dofile("tests/fakes.lua")

local function setup()
    local world = stubs.install()
    fakes.installContractor(world)
    return world
end

local function poll()
    TCJobSupplies.update(TCJobSupplies.POLL_INTERVAL_MS)
end

local function addTractor(world, dieselLevel)
    return world:addVehicle({ name = "Tractor", dieselUsagePerHour = 40, dieselCapacity = 400, dieselLevel = dieselLevel })
end

local function dieselLevel(vehicle)
    return vehicle:getFillUnitFillLevel(vehicle.spec_motorized.consumersByFillType[FillType.DIESEL].fillUnitIndex)
end

test("a hired worker's diesel tank below 25% is topped up from storage", function()
    local world = setup()
    local tractor = addTractor(world, 90)
    local storage = world:addStorage({ levels = { [FillType.DIESEL] = 250 } })
    world:addJob({ workerId = 3, vehicles = { tractor }, working = true })

    poll()

    assertEquals(dieselLevel(tractor), 340, "tank")
    assertEquals(storage:getFillLevel(FillType.DIESEL), 0, "storage")
    assertEquals(#world.suppliesLogged, 0, "diesel logged as logbook supplies")
end)

test("a diesel tank at 25% or more is left alone while working", function()
    local world = setup()
    local tractor = addTractor(world, 100)
    local storage = world:addStorage({ levels = { [FillType.DIESEL] = 250 } })
    world:addJob({ workerId = 3, vehicles = { tractor }, working = true })

    poll()

    assertEquals(dieselLevel(tractor), 100, "tank")
    assertEquals(storage:getFillLevel(FillType.DIESEL), 250, "storage")
end)

test("a player-driven job's vehicle is never refuelled", function()
    local world = setup()
    local tractor = addTractor(world, 10)
    world:addStorage({ levels = { [FillType.DIESEL] = 250 } })
    local job = world:addJob({ jobType = "plough", vehicles = { tractor } })

    assertEquals(#TCJobSupplies.getJobTanks(job), 0, "player job tanks")
    poll()
    assertEquals(dieselLevel(tractor), 10, "tank")
    assertEquals(job.supplyStatus, nil, "status")
end)

test("stock is drawn from storages before pallets, and only the farm's own", function()
    local world = setup()
    world:addStorage({ levels = { [FillType.DIESEL] = 50 } })
    local otherFarm = world:addStorage({ farmId = 2, levels = { [FillType.DIESEL] = 1000 } })
    local ibc = world:addVehicle({ name = "IBC", isPallet = true,
        fillUnits = { { capacity = 1000, level = 100, fillType = FillType.DIESEL } } })

    assertEquals(TCJobSupplies.getFarmStock(1, FillType.DIESEL), 150, "stock")
    assertEquals(TCJobSupplies.drawFromStock(1, FillType.DIESEL, 120), 120, "taken")
    assertEquals(TCJobSupplies.getFarmStock(1, FillType.DIESEL), 30, "stock after")
    assertEquals(ibc:getFillUnitFillLevel(1), 30, "pallet")
    assertEquals(otherFarm:getFillLevel(FillType.DIESEL), 1000, "other farm's storage")
end)

test("with no diesel the job is held, the worker paused and a notice put up", function()
    local world = setup()
    local tractor = addTractor(world, 0)
    world:addStorage({ levels = { [FillType.DIESEL] = 0 } })
    local job = world:addJob({ workerId = 3, vehicles = { tractor }, working = true })

    poll()

    assertEquals(job.supplyStatus, TCJobSupplies.STATUS.NO_STOCK, "status")
    assertEquals(job.supplyFillTypeName, "DIESEL", "fill type")
    assertEquals(world.paused[1], job.id, "paused")

    local notices = g_currentMission.TheContractor.Notices:getNotices(1)
    assertEquals(#notices, 1, "notices")
    assertEquals(notices[1].text, "Out of Diesel: a job is on hold until you restock.", "notice text")
    assertTrue(notices[1].isTransient, "notice should be transient")
end)

test("a held job is set off again on the next poll", function()
    local world = setup()
    local tractor = addTractor(world, 0)
    local job = world:addJob({ workerId = 3, vehicles = { tractor }, working = true })
    poll()
    assertEquals(job.supplyStatus, TCJobSupplies.STATUS.NO_STOCK, "status")

    poll()
    assertEquals(world.started[1], job.id, "startJobForWorker called")
end)

test("the notice counts held jobs and comes down when none are left", function()
    local world = setup()
    local jobA = world:addJob({ workerId = 3, vehicles = { addTractor(world, 0) }, working = true })
    local jobB = world:addJob({ workerId = 4, vehicles = { addTractor(world, 0) }, working = true })
    local notices = g_currentMission.TheContractor.Notices

    poll()
    assertEquals(#notices:getNotices(1), 1, "one notice for both")
    assertEquals(notices:getNotices(1)[1].text, "Out of Diesel: 2 jobs are on hold until you restock.", "two")

    jobA.supplyStatus = nil
    poll()
    assertEquals(#notices:getNotices(1), 1, "still one notice")
    assertEquals(notices:getNotices(1)[1].text, "Out of Diesel: a job is on hold until you restock.", "one")

    jobB.supplyStatus = nil
    poll()
    assertEquals(#notices:getNotices(1), 0, "notices once nothing's held")
end)
