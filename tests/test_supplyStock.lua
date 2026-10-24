-- TCSupplyStock (064): the Supplies tab's list of supplies, their stock,
-- the room for them in storage, and the jobs held for them.

local fakes = dofile("tests/fakes.lua")

local function setup()
    local world = stubs.install()
    fakes.installContractor(world)
    TCEquipmentClass.SEED_TANK_FILL_TYPE = FillType.SEEDS
    TheContractorJobGeneration.JOB_TYPES = {
        fertilize = { implementSpec = "spec_sprayer",
            supplyFillTypeNames = { "FERTILIZER", "LIQUIDFERTILIZER", "MANURE", "LIQUIDMANURE" } },
        herbicide = { implementSpec = "spec_sprayer", supplyFillTypeNames = { "HERBICIDE" } },
        -- A product the game doesn't know is just skipped.
        lime = { implementSpec = "spec_sprayer", supplyFillTypeNames = { "NOT_A_FILLTYPE" } },
        harvest = { cropDependent = true },
    }
    world:load("src/util/TCSupplyStock.lua")
    return world
end

local function findSupply(supplies, fillTypeIndex)
    for _, supply in ipairs(supplies) do
        if supply.fillTypeIndex == fillTypeIndex then
            return supply
        end
    end
    return nil
end

local function names(fillTypes)
    local result = {}
    for _, fillTypeIndex in ipairs(fillTypes) do
        table.insert(result, g_fillTypeManager:getFillTypeNameByIndex(fillTypeIndex))
    end
    return table.concat(result, ",")
end

test("the supplies are what jobs draw: diesel, seed, job products, then consumables", function()
    local world = setup()
    local planter = world:addVehicle({ name = "Planter" })
    planter.spec_sowingMachine = { seedFillType = FillType.POTATO }
    local baler = world:addVehicle({ name = "Baler",
        fillUnits = { { capacity = 2, supported = { FillType.BALENET } } } })
    baler.spec_consumable = { types = { { fillUnitIndex = 1 } } }
    -- Another farm's machines add nothing.
    local otherPlanter = world:addVehicle({ name = "Other planter", farmId = 2 })
    otherPlanter.spec_sowingMachine = { seedFillType = FillType.WHEAT }

    assertEquals(names(TCSupplyStock.getSupplyFillTypes(1)),
        "DIESEL,SEEDS,POTATO,FERTILIZER,LIQUIDFERTILIZER,MANURE,LIQUIDMANURE,HERBICIDE,BALENET")
end)

test("a supply the farm has none of still gets a row", function()
    setup()
    local supply = findSupply(TCSupplyStock.getSupplies(1), FillType.HERBICIDE)
    assertTrue(supply ~= nil, "herbicide row")
    assertEquals(supply.amount, 0, "amount")
    assertEquals(supply.capacity, nil, "capacity")
    assertTrue(supply.isLow, "none is low")
end)

test("stock matches TCJobSupplies.getFarmStock: storages plus pallets, the farm's own", function()
    local world = setup()
    world:addStorage({ levels = { [FillType.DIESEL] = 300 }, capacities = { [FillType.DIESEL] = 1000 } })
    world:addStorage({ farmId = 2, levels = { [FillType.DIESEL] = 5000 } })
    world:addVehicle({ name = "IBC", isPallet = true,
        fillUnits = { { capacity = 1000, level = 200, fillType = FillType.DIESEL } } })
    world:addVehicle({ name = "IBC", isPallet = true,
        fillUnits = { { capacity = 1000, level = 100, fillType = FillType.DIESEL } } })

    local supply = findSupply(TCSupplyStock.getSupplies(1), FillType.DIESEL)
    assertEquals(supply.amount, TCJobSupplies.getFarmStock(1, FillType.DIESEL), "same as getFarmStock")
    assertEquals(supply.amount, 600, "amount")
    assertEquals(supply.storedAmount, 300, "stored")
    assertEquals(#supply.pallets, 1, "pallets grouped by name")
    assertEquals(supply.pallets[1].count, 2, "pallet count")
    assertEquals(supply.pallets[1].amount, 300, "pallet amount")
end)

test("a dedicated storage's capacity is its own; pallets don't add room", function()
    local world = setup()
    world:addStorage({ levels = { [FillType.DIESEL] = 300 }, capacities = { [FillType.DIESEL] = 1000 } })
    world:addVehicle({ name = "IBC", isPallet = true,
        fillUnits = { { capacity = 1000, level = 200, fillType = FillType.DIESEL } } })

    local supply = findSupply(TCSupplyStock.getSupplies(1), FillType.DIESEL)
    assertEquals(supply.capacity, 1000, "capacity")
    assertNear(supply.ratio, 0.3, 0.0001, "ratio is stored over capacity")
end)

test("in a shared storage the room shown is what's left after the neighbours", function()
    local world = setup()
    -- 10,000 shared between seed and wheat: 1,000 seed and 6,000 wheat
    -- leave 3,000 of room for seed.
    world:addStorage({ capacity = 10000, levels = { [FillType.SEEDS] = 1000, [FillType.WHEAT] = 6000 } })

    local supply = findSupply(TCSupplyStock.getSupplies(1), FillType.SEEDS)
    assertEquals(supply.capacity, 4000, "capacity")
    assertNear(supply.ratio, 0.25, 0.0001, "ratio")
    assertEquals(findSupply(TCSupplyStock.getSupplies(1), FillType.WHEAT), nil, "wheat isn't a supply")
end)

test("capacity adds up across storages, and each is listed with its own", function()
    local world = setup()
    world:addStorage({ levels = { [FillType.LIQUIDMANURE] = 100 }, capacities = { [FillType.LIQUIDMANURE] = 1000 } })
    world:addStorage({ levels = { [FillType.LIQUIDMANURE] = 0 }, capacities = { [FillType.LIQUIDMANURE] = 3000 } })

    local supply = findSupply(TCSupplyStock.getSupplies(1), FillType.LIQUIDMANURE)
    assertEquals(supply.capacity, 4000, "capacity")
    assertEquals(#supply.storages, 2, "empty storage listed too")
    assertEquals(supply.storages[2].capacity, 3000, "its capacity")
end)

test("a pallets-only supply has no capacity or ratio", function()
    local world = setup()
    world:addVehicle({ name = "Herbicide IBC", isPallet = true,
        fillUnits = { { capacity = 1000, level = 400, fillType = FillType.HERBICIDE } } })

    local supply = findSupply(TCSupplyStock.getSupplies(1), FillType.HERBICIDE)
    assertEquals(supply.amount, 400, "amount")
    assertEquals(supply.capacity, nil, "capacity")
    assertEquals(supply.ratio, nil, "ratio")
end)

test("Low is a set amount in stock, not a share of the storage", function()
    local world = setup()
    -- A huge, nearly empty silo doesn't make 12,000 seed low.
    world:addStorage({ levels = { [FillType.SEEDS] = 12000 }, capacities = { [FillType.SEEDS] = 500000 } })
    assertTrue(not findSupply(TCSupplyStock.getSupplies(1), FillType.SEEDS).isLow, "12,000 seed isn't low")

    -- And 9,000 in a full small one is.
    world = setup()
    world:addStorage({ levels = { [FillType.SEEDS] = 9000 }, capacities = { [FillType.SEEDS] = 9000 } })
    assertTrue(findSupply(TCSupplyStock.getSupplies(1), FillType.SEEDS).isLow, "9,000 seed is low")
end)

test("pallets count towards the amount judged", function()
    local world = setup()
    world:addStorage({ levels = { [FillType.SEEDS] = 0 }, capacities = { [FillType.SEEDS] = 500000 } })
    world:addVehicle({ name = "Seed bag", isPallet = true,
        fillUnits = { { capacity = 20000, level = 17000, fillType = FillType.SEEDS } } })
    assertTrue(not findSupply(TCSupplyStock.getSupplies(1), FillType.SEEDS).isLow, "17,000 in bags isn't low")
end)

test("supplies counted in pieces have their own threshold", function()
    setup()
    assertEquals(TCSupplyStock.getLowAmount(FillType.BALENET), TCSupplyStock.LOW_AMOUNT_PIECES)
    assertEquals(TCSupplyStock.getLowAmount(FillType.SEEDS), 10000)
    assertEquals(TCSupplyStock.getLowAmount(FillType.HERBICIDE), TCSupplyStock.LOW_AMOUNT_VOLUME)
end)

test("storages are named after the placeable that holds them", function()
    local world = setup()
    local silo = world:addStorage({ levels = { [FillType.SEEDS] = 10 } })
    local extension = world:addStorage({ levels = { [FillType.SEEDS] = 20 } })
    local unnamed = world:addStorage({ levels = { [FillType.SEEDS] = 30 } })
    world:addPlaceable({ name = "Farm silo", specs = { spec_silo = { storages = { silo } } } })
    world:addPlaceable({ name = "Silo extension", specs = { spec_siloExtension = { storage = extension } } })

    local supply = findSupply(TCSupplyStock.getSupplies(1), FillType.SEEDS)
    local byAmount = {}
    for _, storage in ipairs(supply.storages) do
        byAmount[storage.amount] = storage.name
    end
    assertEquals(byAmount[10], "Farm silo", "silo")
    assertEquals(byAmount[20], "Silo extension", "extension")
    assertEquals(byAmount[30], "Storage", "fallback")
    assertTrue(unnamed ~= nil)
end)

test("a storage kept out of sight is named through its stations", function()
    local world = setup()
    local deep = world:addStorage({ levels = { [FillType.SEEDS] = 10 } })
    local stationOnly = world:addStorage({ levels = { [FillType.SEEDS] = 20 } })
    -- A mod's building keeping its storage further down than the specs.
    local shed = world:addPlaceable({ name = "Seed shed", specs = { spec_modShed = { a = { b = { deep } } } } })
    deep.unloadingStations = { [{ owningPlaceable = shed }] = true }
    stationOnly.loadingStations = { [{ stationName = "Seed bunker" }] = true }

    local supply = findSupply(TCSupplyStock.getSupplies(1), FillType.SEEDS)
    local byAmount = {}
    for _, storage in ipairs(supply.storages) do
        byAmount[storage.amount] = storage.name
    end
    assertEquals(byAmount[10], "Seed shed", "through the station's building")
    assertEquals(byAmount[20], "Seed bunker", "the station's own name")
end)

test("jobs held for a supply are listed against it", function()
    local world = setup()
    local held = world:addJob({ workerId = 3 })
    held.supplyStatus = TCJobSupplies.STATUS.NO_STOCK
    held.supplyFillTypeName = "DIESEL"
    local wrongFill = world:addJob({ workerId = 4 })
    wrongFill.supplyStatus = TCJobSupplies.STATUS.WRONG_FILL
    wrongFill.supplyFillTypeName = "DIESEL"
    local finished = world:addJob({ workerId = 5, state = TheContractorJob.STATE.COMPLETED })
    finished.supplyStatus = TCJobSupplies.STATUS.NO_STOCK
    finished.supplyFillTypeName = "DIESEL"

    local supply = findSupply(TCSupplyStock.getSupplies(1), FillType.DIESEL)
    assertEquals(#supply.heldJobs, 1, "held jobs")
    assertEquals(supply.heldJobs[1], held, "the held one")
    assertEquals(#findSupply(TCSupplyStock.getSupplies(1), FillType.SEEDS).heldJobs, 0, "seed")
end)

test("pallets in an object storage get a row named after it", function()
    local world = setup()
    world:addVehicle({ name = "IBC", isPallet = true,
        fillUnits = { { capacity = 1000, level = 200, fillType = FillType.DIESEL } } })
    world:addObjectStorage({ name = "Storage Rack", pallets = {
        { fillType = FillType.DIESEL, fillLevel = 1000 },
        { fillType = FillType.DIESEL, fillLevel = 600 },
    } })

    local supply = findSupply(TCSupplyStock.getSupplies(1), FillType.DIESEL)
    assertEquals(supply.amount, TCJobSupplies.getFarmStock(1, FillType.DIESEL), "same as getFarmStock")
    assertEquals(supply.amount, 1800, "amount")
    assertEquals(#supply.pallets, 2, "loose group and the rack")
    assertEquals(supply.pallets[2].name, "Storage Rack", "named after the storage")
    assertEquals(supply.pallets[2].count, 2, "count")
    assertEquals(supply.pallets[2].amount, 1600, "amount")
    assertTrue(supply.pallets[2].isStored and not supply.pallets[1].isStored, "stored flag")
    assertEquals(supply.capacity, nil, "a pallet storage adds no capacity")
end)
