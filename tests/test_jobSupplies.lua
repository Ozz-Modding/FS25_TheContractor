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
    assertEquals(TCJobSupplies.getNoticeCount(1, "DIESEL"), 1, "for the one job")
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
    assertEquals(TCJobSupplies.getNoticeCount(1, "DIESEL"), 2, "two")

    jobA.supplyStatus = nil
    poll()
    assertEquals(#notices:getNotices(1), 1, "still one notice")
    assertEquals(TCJobSupplies.getNoticeCount(1, "DIESEL"), 1, "one")

    jobB.supplyStatus = nil
    poll()
    assertEquals(#notices:getNotices(1), 0, "notices once nothing's held")
end)

test("topUp reports the diesel it loaded apart from the total", function()
    local world = setup()
    local tractor = addTractor(world, 0)
    world:addStorage({ levels = { [FillType.DIESEL] = 1000 } })
    local job = world:addJob({ workerId = 3, vehicles = { tractor }, state = TheContractorJob.STATE.ALLOCATED })

    local loaded, status, _, fuelLoaded = TCJobSupplies.topUp(job)

    assertEquals(status, nil, "status")
    assertEquals(loaded, 400, "loaded")
    assertEquals(fuelLoaded, 400, "diesel loaded")
end)

test("refuelling adds a flat 3 minutes, supplies 5 plus filling time", function()
    assertEquals(TCJobSupplies.getLoadingMinutes(0, 0), 0, "nothing loaded")
    assertEquals(TCJobSupplies.getLoadingMinutes(nil, nil), 0, "nil")
    assertEquals(TCJobSupplies.getLoadingMinutes(0, 4), 3, "a few litres of diesel")
    assertEquals(TCJobSupplies.getLoadingMinutes(0, 400), 3, "a full tank of diesel")
    assertEquals(TCJobSupplies.getLoadingMinutes(3000, 0), 6.5, "3000 l of seed")
    assertEquals(TCJobSupplies.getLoadingMinutes(3000, 4), 9.5, "seed and diesel")
end)

test("a two-worker haulage job's tractor is refuelled from stock too", function()
    local world = setup()
    local combine = addTractor(world, 400)
    local haulTractor = addTractor(world, 0)
    local storage = world:addStorage({ levels = { [FillType.DIESEL] = 1000 } })
    local job = world:addJob({ workerId = 3, vehicles = { combine }, haulerId = 4, haulageVehicles = { haulTractor },
        state = TheContractorJob.STATE.ALLOCATED })

    local _, status, _, fuelLoaded = TCJobSupplies.topUp(job)

    assertEquals(status, nil, "status")
    assertEquals(dieselLevel(haulTractor), 400, "haul tractor tank")
    assertEquals(fuelLoaded, 400, "diesel loaded")
    assertEquals(storage:getFillLevel(FillType.DIESEL), 600, "storage")
end)

test("a haulage job with no diesel for the haul tractor is held", function()
    local world = setup()
    local job = world:addJob({ workerId = 3, vehicles = { addTractor(world, 400) }, haulerId = 4,
        haulageVehicles = { addTractor(world, 0) }, state = TheContractorJob.STATE.ALLOCATED })

    local _, status, fillTypeName = TCJobSupplies.topUp(job)

    assertEquals(status, TCJobSupplies.STATUS.NO_STOCK, "status")
    assertEquals(fillTypeName, "DIESEL", "fill type")
end)

-- Object storages (vanilla's pallet sheds, StorageRack) --------------------

local function storedLevels(placeable)
    local levels = {}
    for _, object in ipairs(placeable.spec_objectStorage.storedObjects) do
        table.insert(levels, object.palletAttributes ~= nil and object.palletAttributes.fillLevel or "bale")
    end
    return table.concat(levels, ",")
end

test("pallets put away in an object storage count as stock, the farm's own only", function()
    local world = setup()
    local rack = world:addObjectStorage({ name = "Storage Rack", pallets = {
        { fillType = FillType.DIESEL, fillLevel = 1000 },
        { fillType = FillType.DIESEL, fillLevel = 1000 },
        { fillType = FillType.SEEDS, fillLevel = 500 },
        { fillType = FillType.DIESEL, fillLevel = 0 },
    } })
    -- A bale in a shed is no pallet.
    table.insert(rack.spec_objectStorage.storedObjects, { baleAttributes = { fillType = FillType.DIESEL, fillLevel = 4000 } })
    world:addObjectStorage({ farmId = 2, pallets = { { fillType = FillType.DIESEL, fillLevel = 1000 } } })
    world:addStorage({ levels = { [FillType.DIESEL] = 50 } })

    local sources = TCJobSupplies.getStoredPalletSources(1, FillType.DIESEL)
    assertEquals(#sources, 1, "one storage")
    assertEquals(sources[1].placeable, rack, "the farm's rack")
    assertEquals(sources[1].count, 2, "pallets with diesel in")
    assertEquals(sources[1].level, 2000, "their diesel")
    assertEquals(TCJobSupplies.getFarmStock(1, FillType.DIESEL), 2050, "farm stock")
end)

test("a client reads vanilla's groups of identical pallets", function()
    local world = setup()
    local rack = world:addObjectStorage({ pallets = {
        { fillType = FillType.DIESEL, fillLevel = 1000 },
        { fillType = FillType.DIESEL, fillLevel = 1000 },
        { fillType = FillType.DIESEL, fillLevel = 1000 },
        { fillType = FillType.DIESEL, fillLevel = 400 },
    } })
    -- What a client is sent: one sample per group, no owner.
    local spec = rack.spec_objectStorage
    for _, info in ipairs(spec.objectInfos) do
        info.objects = { { palletAttributes = { fillType = info.objects[1].palletAttributes.fillType,
            fillLevel = info.objects[1].palletAttributes.fillLevel } } }
    end
    spec.storedObjects = {}
    g_currentMission.getIsServer = function() return false end

    local sources = TCJobSupplies.getStoredPalletSources(1, FillType.DIESEL)
    assertEquals(sources[1].count, 4, "count")
    assertEquals(sources[1].level, 3400, "level")
end)

test("stored pallets are drawn last, emptied one at a time, and an empty one goes", function()
    local world = setup()
    world:addStorage({ levels = { [FillType.DIESEL] = 100 } })
    local ibc = world:addVehicle({ name = "IBC", isPallet = true,
        fillUnits = { { capacity = 1000, level = 100, fillType = FillType.DIESEL } } })
    local rack = world:addObjectStorage({ pallets = {
        { fillType = FillType.SEEDS, fillLevel = 500 },
        { fillType = FillType.DIESEL, fillLevel = 1000 },
        { fillType = FillType.DIESEL, fillLevel = 1000 },
    } })

    -- 100 from storage, 100 from the IBC, 1,000 empties one stored pallet
    -- and 300 comes out of the next.
    assertEquals(TCJobSupplies.drawFromStock(1, FillType.DIESEL, 1500), 1500, "taken")
    assertEquals(ibc:getFillUnitFillLevel(1), 0, "loose pallet first")
    assertEquals(storedLevels(rack), "500,700", "seed untouched, one emptied and gone, one drawn on")
    assertEquals(rack.spec_objectStorage.numStoredObjects, 2, "count kept up")
    assertEquals(rack.spec_objectStorage.infosDirty, 1, "groups rebuilt and synced")
    local stat = world.farmStats[#world.farmStats]
    assertEquals(stat.statName, "storedPallets", "stat")
    assertEquals(stat.delta, -1, "one pallet gone")
    assertEquals(TCJobSupplies.getFarmStock(1, FillType.DIESEL), 700, "stock after")
end)

test("more asked for than there is takes what's there", function()
    local world = setup()
    local rack = world:addObjectStorage({ pallets = { { fillType = FillType.DIESEL, fillLevel = 300 } } })
    assertEquals(TCJobSupplies.drawFromStock(1, FillType.DIESEL, 1000), 300, "taken")
    assertEquals(#rack.spec_objectStorage.storedObjects, 0, "empty pallet gone")
end)

test("a storage handing pallets out isn't drawn on", function()
    local world = setup()
    local rack = world:addObjectStorage({ pallets = { { fillType = FillType.DIESEL, fillLevel = 1000 } } })
    rack.spec_objectStorage.objectSpawn.isActive = true

    assertEquals(TCJobSupplies.drawFromStock(1, FillType.DIESEL, 200), 0, "taken")
    assertEquals(storedLevels(rack), "1000", "untouched")
    assertEquals(rack.spec_objectStorage.infosDirty, 0, "not marked")
end)

test("with FS25_RedDiesel: a red tractor is topped up with red from stock, never white", function()
    local world = setup()
    local red = world:addFillType("RED_DIESEL", "Red diesel")
    local tractor = world:addVehicle({ name = "Tractor", dieselUsagePerHour = 40, dieselCapacity = 400,
        dieselLevel = 90, dieselFillType = red })
    local white = world:addStorage({ levels = { [FillType.DIESEL] = 1000 } })
    local redTank = world:addStorage({ levels = { [red] = 250 } })
    world:addJob({ workerId = 3, vehicles = { tractor }, working = true })

    poll()

    assertEquals(tractor.fillUnits[1].level, 340, "tank")
    assertEquals(tractor.fillUnits[1].fillType, red, "red")
    assertEquals(redTank:getFillLevel(red), 0, "red stock")
    assertEquals(white:getFillLevel(FillType.DIESEL), 1000, "white stock")
end)
