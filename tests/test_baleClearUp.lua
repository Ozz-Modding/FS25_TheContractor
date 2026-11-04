-- A bale job's crop is the customer's (032, 076): the bales the farm baled
-- on the job's farmland are cleared up, and those still held in one of the
-- farm's balers there (a square baler's chute, a round baler's chamber) are
-- left in it, so the baler keeps working, and deleted once it drops them.

local FIELD_FARMLAND = 5

local function setup()
    local world = stubs.install()
    world:addFillType("STRAW", "Straw")
    world:addFillType("GRASS", "Grass")
    FruitType = { UNKNOWN = 0, GRASS = 1, WHEAT = 2 }
    FieldGroundType = {}
    g_fruitTypeManager = {
        getFruitTypeByName = function(_, name)
            return name == "WHEAT" and { index = FruitType.WHEAT, name = "WHEAT" } or nil
        end,
        getWindrowFillTypeIndexByFruitTypeIndex = function(_, index)
            return index == FruitType.WHEAT and FillType.STRAW or nil
        end,
    }
    TheContractorNegotiation = { rollInitialEagerness = function() return 1 end }
    world:load("src/business/Job.lua")
    world:load("src/business/JobGeneration.lua")
    world:load("src/util/TCFieldPreparation.lua")
    TCFieldPreparation.reset()

    -- A node is { x, z }. The field's farmland is everything west of x = 100.
    getWorldTranslation = function(node)
        return node.x, 0, node.z
    end
    g_farmlandManager = {
        getFarmlandIdAtWorldPosition = function(_, x)
            return x < 100 and FIELD_FARMLAND or FIELD_FARMLAND + 1
        end,
    }
    local field = {
        getFarmland = function()
            return { id = FIELD_FARMLAND }
        end,
    }
    g_fieldManager = {
        getFieldById = function()
            return field
        end,
    }

    -- No jobs to lay out again on the first update (resumeAfterLoad).
    g_currentMission.TheContractor.Jobs = { getAllJobs = function() return {} end }

    Bale = {}
    world.items = {}
    g_currentMission.itemSystem = { itemsToSave = {} }
    return world
end

local function addJob()
    local job = TheContractorJob.new(1, 1, "bale", 7, 3, 1, 1, 1000)
    job.fruitTypeName = "WHEAT"
    job.state = TheContractorJob.STATE.COMPLETED
    return job
end

-- def: { x, farmId (1), fillType (straw), mounted }
local function addBale(world, def)
    local bale = {
        nodeId = { x = def.x or 10, z = 0 },
        ownerFarmId = def.farmId or 1,
        fillType = def.fillType or FillType.STRAW,
        mounted = def.mounted == true,
    }
    function bale:isa(class) return class == Bale end
    function bale:getOwnerFarmId() return self.ownerFarmId end
    function bale:getFillType() return self.fillType end
    function bale:getIsMounted() return self.mounted end
    function bale:delete()
        self.isDeleted = true
        g_currentMission.itemSystem.itemsToSave[self] = nil
    end
    g_currentMission.itemSystem.itemsToSave[bale] = { item = bale }
    return bale
end

-- def: { x, farmId (1) }; bales is the list of bales it's holding.
local function addBaler(world, def, bales)
    local baler = world:addVehicle({ farmId = def.farmId or 1 })
    baler.rootNode = { x = def.x or 10, z = 0 }
    baler.spec_baler = { bales = {} }
    for _, bale in ipairs(bales) do
        table.insert(baler.spec_baler.bales, { baleObject = bale })
    end
    baler.getOwnerFarmId = function(self) return def.farmId or 1 end
    return baler
end

-- The baler lets go of a bale, as Baler:dropBale does.
local function drop(baler, bale)
    for index, entry in ipairs(baler.spec_baler.bales) do
        if entry.baleObject == bale then
            table.remove(baler.spec_baler.bales, index)
            return
        end
    end
end

test("the farm's bales of the job's crop on its farmland go, nobody else's", function()
    local world = setup()
    local job = addJob()
    local ours = addBale(world, {})
    local otherFarm = addBale(world, { farmId = 2 })
    local otherCrop = addBale(world, { fillType = FillType.GRASS })
    local offFarmland = addBale(world, { x = 150 })
    local loaded = addBale(world, { mounted = true })

    TCFieldPreparation.removeBaledCrop(job)
    assertTrue(ours.isDeleted, "ours")
    assertEquals(otherFarm.isDeleted, nil, "another farm's")
    assertEquals(otherCrop.isDeleted, nil, "another crop")
    assertEquals(offFarmland.isDeleted, nil, "off the farmland")
    assertEquals(loaded.isDeleted, nil, "loaded on something")
end)

test("a bale held in a baler stays in it, and goes once the baler drops it", function()
    local world = setup()
    local job = addJob()
    local first = addBale(world, {})
    local second = addBale(world, {})
    local baler = addBaler(world, {}, { first, second })

    TCFieldPreparation.removeBaledCrop(job)
    assertEquals(first.isDeleted, nil, "left in the baler")
    assertEquals(#baler.spec_baler.bales, 2, "the baler still has both")

    TCFieldPreparation.update(16)
    assertEquals(first.isDeleted, nil, "still held")

    drop(baler, first)
    TCFieldPreparation.update(16)
    assertTrue(first.isDeleted, "dropped, so deleted")
    assertEquals(second.isDeleted, nil, "the next one's still held")

    drop(baler, second)
    TCFieldPreparation.update(16)
    assertTrue(second.isDeleted, "and then that one")
end)

test("a held bale goes if its baler is deleted", function()
    local world = setup()
    local job = addJob()
    local bale = addBale(world, {})
    local baler = addBaler(world, {}, { bale })

    TCFieldPreparation.removeBaledCrop(job)
    baler.isDeleted = true
    TCFieldPreparation.update(16)
    assertTrue(bale.isDeleted)
end)

test("only the farm's balers on the job's farmland, holding the job's crop", function()
    local world = setup()
    local job = addJob()
    local otherFarm = addBale(world, {})
    local otherFarmBaler = addBaler(world, { farmId = 2 }, { otherFarm })
    local away = addBale(world, {})
    local awayBaler = addBaler(world, { x = 150 }, { away })
    local grass = addBale(world, { fillType = FillType.GRASS })
    local grassBaler = addBaler(world, {}, { grass })

    TCFieldPreparation.removeBaledCrop(job)
    drop(otherFarmBaler, otherFarm)
    drop(awayBaler, away)
    drop(grassBaler, grass)
    TCFieldPreparation.update(16)
    assertEquals(otherFarm.isDeleted, nil, "another farm's baler")
    assertEquals(away.isDeleted, nil, "a baler off the farmland")
    assertEquals(grass.isDeleted, nil, "another crop")
end)

test("a held bale of any farm's is never taken for one on the ground", function()
    local world = setup()
    local job = addJob()
    -- Another farm's baler, but the bale is ours (it's owned by whoever the
    -- farmland says): it's on a joint in that baler, so it's left alone.
    local bale = addBale(world, {})
    addBaler(world, { farmId = 2 }, { bale })

    TCFieldPreparation.removeBaledCrop(job)
    assertEquals(bale.isDeleted, nil)
end)

test("bale completion clear-up runs for a bale job only, and only on the server", function()
    local world = setup()
    local job = addJob()
    local bale = addBale(world, {})

    local other = addJob()
    other.jobType = "mow"
    TCFieldPreparation.clearUpAtCompletion(other)
    assertEquals(bale.isDeleted, nil, "not a bale job")

    g_currentMission.getIsServer = function() return false end
    TCFieldPreparation.clearUpAtCompletion(job)
    assertEquals(bale.isDeleted, nil, "a client")

    g_currentMission.getIsServer = function() return true end
    TCFieldPreparation.clearUpAtCompletion(job)
    assertTrue(bale.isDeleted, "the server")
end)

test("reset forgets the bales waiting to drop", function()
    local world = setup()
    local job = addJob()
    local bale = addBale(world, {})
    local baler = addBaler(world, {}, { bale })

    TCFieldPreparation.removeBaledCrop(job)
    TCFieldPreparation.reset()
    drop(baler, bale)
    TCFieldPreparation.update(16)
    assertEquals(bale.isDeleted, nil)
end)
