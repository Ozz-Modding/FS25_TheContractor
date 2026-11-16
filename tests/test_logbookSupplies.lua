-- 158: a job's logbook entry has the supplies it used, not what was loaded:
-- what was in its tanks when they were first topped up, plus what went in
-- from stock, less what's left when the crew comes off it. Each has what it
-- would cost to buy, and that comes off the margin.

local fakes = dofile("tests/fakes.lua")

local function setup()
    local world = stubs.install()
    fakes.installContractor(world)
    fakes.JOB_TYPES.fertilize = { implementSpec = "spec_sprayer", supplyFillTypeNames = { "FERTILIZER" } }
    TCEquipmentClass.isJobImplement = function(vehicle)
        return vehicle.spec_sprayer ~= nil
    end
    world:load("src/business/Logbook.lua")
    local tc = g_currentMission.TheContractor
    tc.Logbook = TheContractorLogbook.new()
    tc.Staff = {
        getWorker = function()
            return { name = "Tom Smith" }
        end,
    }
    world.dieselPrice = 2
    return world, tc
end

local function addSprayer(world, level)
    local sprayer = world:addVehicle({ name = "Sprayer",
        fillUnits = { { capacity = 1000, level = level, fillType = FillType.FERTILIZER } } })
    sprayer.spec_sprayer = { fillUnitIndex = 1 }
    return sprayer
end

local function setLevel(vehicle, level)
    vehicle.fillUnits[1].level = level
end

local function getPendingSupplies(tc, job)
    return tc.Logbook.pendingByJobId[job.id].supplies
end

test("what's used is what was in the tanks, plus what was loaded, less what's left", function()
    local world, tc = setup()
    world:addStorage({ levels = { [FillType.FERTILIZER] = 5000 } })
    local sprayer = addSprayer(world, 200)
    local job = world:addJob({ jobType = "fertilize", vehicles = { sprayer } })

    TCJobSupplies.topUp(job)
    assertEquals(sprayer:getFillUnitFillLevel(1), 1000, "filled")
    setLevel(sprayer, 300)
    tc.Logbook:onCrewChanged(job)

    assertEquals(getPendingSupplies(tc, job).FERTILIZER, 700, "200 there + 800 loaded - 300 left")
end)

test("topping up again doesn't count the tank twice, and diesel isn't a supply", function()
    local world, tc = setup()
    world:addStorage({ levels = { [FillType.FERTILIZER] = 5000, [FillType.DIESEL] = 5000 } })
    local tractor = world:addVehicle({ name = "Tractor", dieselUsagePerHour = 40, dieselCapacity = 400,
        dieselLevel = 100 })
    local sprayer = addSprayer(world, 0)
    local job = world:addJob({ jobType = "fertilize", workerId = 3, vehicles = { tractor, sprayer } })

    TCJobSupplies.topUp(job)
    setLevel(sprayer, 100)
    TCJobSupplies.topUp(job, true)
    assertEquals(sprayer:getFillUnitFillLevel(1), 1000, "topped up")
    setLevel(sprayer, 400)
    tc.Logbook:onCrewChanged(job)

    local supplies = getPendingSupplies(tc, job)
    assertEquals(supplies.FERTILIZER, 1500, "1000 + 900 loaded - 400 left")
    assertEquals(supplies.DIESEL, nil, "diesel")
end)

test("the next crew's tanks are counted afresh", function()
    local world, tc = setup()
    world:addStorage({ levels = { [FillType.FERTILIZER] = 5000 } })
    local sprayer = addSprayer(world, 0)
    local job = world:addJob({ jobType = "fertilize", vehicles = { sprayer } })

    TCJobSupplies.topUp(job)
    setLevel(sprayer, 300)
    tc.Logbook:onCrewChanged(job)

    -- Back on with the same sprayer, still holding 300.
    TCJobSupplies.topUp(job)
    setLevel(sprayer, 0)
    tc.Logbook:onCrewChanged(job)

    assertEquals(getPendingSupplies(tc, job).FERTILIZER, 1700, "700, then 300 there + 700 loaded")
end)

test("something in a tank that isn't the job's product isn't counted", function()
    local world, tc = setup()
    local sprayer = world:addVehicle({ name = "Sprayer", fillUnits = { { capacity = 1000, level = 500,
        fillType = FillType.LIQUIDFERTILIZER, supported = { FillType.FERTILIZER, FillType.LIQUIDFERTILIZER } } } })
    sprayer.spec_sprayer = { fillUnitIndex = 1 }
    local job = world:addJob({ jobType = "fertilize", vehicles = { sprayer } })

    TCJobSupplies.topUp(job)
    tc.Logbook:onCrewChanged(job)

    local supplies = getPendingSupplies(tc, job)
    assertEquals(supplies.LIQUIDFERTILIZER, nil, "wrong fill")
    assertEquals(supplies.FERTILIZER, nil, "nothing loaded")
end)

test("the entry's supplies are what was used, priced, in name order", function()
    setup()
    g_currentMission.economyManager.getCostPerLiter = function(_, fillTypeIndex)
        return fillTypeIndex == FillType.SEEDS and 3 or 0.5
    end

    local supplies = TheContractorLogbook.getSuppliesUsed({ SEEDS = 400, FERTILIZER = 1000, LIQUIDFERTILIZER = 0.4 })

    assertEquals(#supplies, 2, "under a litre dropped")
    assertEquals(supplies[1].fillTypeName, "FERTILIZER")
    assertEquals(supplies[1].cost, 500)
    assertEquals(supplies[2].fillTypeName, "SEEDS")
    assertEquals(supplies[2].liters, 400)
    assertEquals(supplies[2].cost, 1200)
end)

test("supplies come off the margin; an entry from before has no cost", function()
    setup()
    local entry = { price = 5000, fuelCost = 100, labourCost = 200, wearCost = 50,
        supplies = { { fillTypeName = "SEEDS", liters = 400, cost = 1200 },
            { fillTypeName = "FERTILIZER", liters = 1000, cost = 500 } } }
    assertEquals(TheContractorLogbook.getSuppliesCost(entry), 1700)
    assertEquals(TheContractorLogbook.getMargin(entry), 2950)

    local older = { price = 5000, fuelCost = 100, supplies = { { fillTypeName = "SEEDS", liters = 400 } } }
    assertEquals(TheContractorLogbook.getSuppliesCost(older), 0)
    assertEquals(TheContractorLogbook.getMargin(older), 4900)
end)

test("a supply's cost streams, and its absence on an older entry", function()
    local world = setup()
    local stream = world:newStream()
    TheContractorLogbook.writeJobEntry(stream, { jobId = 1, farmId = 1, outcome = "completed", fieldId = 7, day = 1,
        crew = {}, equipment = {}, supplies = { { fillTypeName = "SEEDS", liters = 400, cost = 1200 },
            { fillTypeName = "FERTILIZER", liters = 1000 } } })
    local entry = TheContractorLogbook.readJobEntry(stream)
    assertEquals(entry.supplies[1].cost, 1200)
    assertEquals(entry.supplies[2].cost, nil)
end)

test("whether the tanks were counted survives a save, and an older save's were", function()
    local world, tc = setup()
    world:addStorage({ levels = { [FillType.FERTILIZER] = 5000 } })
    local sprayer = addSprayer(world, 0)
    local job = world:addJob({ jobType = "fertilize", vehicles = { sprayer } })
    TCJobSupplies.topUp(job)

    local xmlFile = {}
    tc.Logbook:saveToXmlFile(xmlFile)
    local loaded = TheContractorLogbook.new()
    loaded:loadFromXMLFile(xmlFile)
    assertTrue(loaded.pendingByJobId[job.id].tanksCounted, "counted")
    assertEquals(loaded.pendingByJobId[job.id].supplies.FERTILIZER, 1000)

    for key in pairs(xmlFile) do
        if string.find(key, "#tanksCounted", 1, true) ~= nil then
            xmlFile[key] = nil
        end
    end
    local older = TheContractorLogbook.new()
    older:loadFromXMLFile(xmlFile)
    assertTrue(older.pendingByJobId[job.id].tanksCounted, "an older save counted what was loaded")
end)
