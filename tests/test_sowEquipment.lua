-- Sow jobs: only a sowing machine whose own seed list takes the job's crop
-- counts as the implement (TCEquipmentClass.canSowFruit), so a grain drill
-- never goes out to put in parsnips; and a sow job for a planted crop is
-- labelled "plant" (TheContractorJobGeneration.getTypeLabel), the suffix of
-- its tc_jobType_ and tc_equipment_*_implement_ keys.

local WHEAT, PARSNIP, POTATO = 2, 3, 4

local function setup()
    local world = stubs.install()
    TheContractorNegotiation = { rollInitialEagerness = function() return 1 end }
    FruitType = { UNKNOWN = 0, WHEAT = WHEAT, PARSNIP = PARSNIP, POTATO = POTATO }
    world:load("src/business/Job.lua")
    world:load("src/business/JobGeneration.lua")
    world:load("src/util/TCEquipmentClass.lua")

    local fruitTypes = {
        [WHEAT] = { index = WHEAT, name = "WHEAT" },
        [PARSNIP] = { index = PARSNIP, name = "PARSNIP" },
        [POTATO] = { index = POTATO, name = "POTATO" },
    }
    g_fruitTypeManager = {
        categories = {},
        getFruitTypeByIndex = function(_, index) return fruitTypes[index] end,
        getFruitTypeByName = function(_, name)
            for _, fruitType in pairs(fruitTypes) do
                if fruitType.name == name then
                    return fruitType
                end
            end
            return nil
        end,
    }
    return world
end

local function sowDef()
    return TheContractorJobGeneration.JOB_TYPES.sow
end

local function sowingMachine(seeds, capacity)
    return {
        spec_sowingMachine = { seeds = seeds, fillUnitIndex = 1 },
        getFillUnitCapacity = function() return capacity or 1000 end,
    }
end

local grainDrill = sowingMachine({ WHEAT })
local vegetablePlanter = sowingMachine({ PARSNIP })
local tractor = { isTractor = true }

local function stubTractors()
    local isTractor = TCEquipmentClass.isTractor
    TCEquipmentClass.isTractor = function(vehicle)
        return vehicle.isTractor == true or isTractor(vehicle)
    end
end

test("a sowing machine takes only the crops in its own seed list", function()
    setup()
    assertTrue(TCEquipmentClass.canSowFruit(grainDrill, WHEAT), "drill, wheat")
    assertTrue(not TCEquipmentClass.canSowFruit(grainDrill, PARSNIP), "drill, parsnips")
    assertTrue(TCEquipmentClass.canSowFruit(vegetablePlanter, PARSNIP), "planter, parsnips")
    assertTrue(not TCEquipmentClass.canSowFruit(vegetablePlanter, WHEAT), "planter, wheat")
end)

test("with no crop known, or no seed list to read, any sowing machine counts", function()
    setup()
    assertTrue(TCEquipmentClass.canSowFruit(grainDrill, nil), "no crop")
    assertTrue(TCEquipmentClass.canSowFruit(grainDrill, FruitType.UNKNOWN), "unknown crop")
    assertTrue(TCEquipmentClass.canSowFruit(sowingMachine(nil), PARSNIP), "no seed list")
    assertTrue(not TCEquipmentClass.canSowFruit({}, nil), "not a sowing machine")
end)

test("a grain drill isn't a parsnip job's implement, nor offered for it", function()
    setup()
    assertTrue(not TCEquipmentClass.isJobImplement(grainDrill, sowDef(), PARSNIP), "drill")
    assertTrue(TCEquipmentClass.isJobImplement(vegetablePlanter, sowDef(), PARSNIP), "planter")
    assertEquals(TCEquipmentClass.getJobRole(grainDrill, sowDef(), PARSNIP), nil)
    assertEquals(TCEquipmentClass.getJobRole(vegetablePlanter, sowDef(), PARSNIP), "implement")
end)

test("a farm with only a grain drill is missing the implement for parsnips", function()
    setup()
    stubTractors()
    local missing = TCEquipmentClass.getMissingEquipment({ grainDrill, tractor }, sowDef(), PARSNIP)
    assertEquals(#missing, 1)
    assertEquals(missing[1], "implement")
    assertEquals(#TCEquipmentClass.getMissingEquipment({ grainDrill, tractor }, sowDef(), WHEAT), 0, "wheat")
    assertEquals(#TCEquipmentClass.getMissingEquipment({ vegetablePlanter, tractor }, sowDef(), PARSNIP), 0,
        "planter")
end)

test("a seed tank is only asked for by a machine that can do the crop", function()
    setup()
    stubTractors()
    local tanklessDrill = sowingMachine({ WHEAT }, 0)
    local missing = TCEquipmentClass.getMissingEquipment({ tanklessDrill, vegetablePlanter, tractor }, sowDef(),
        PARSNIP)
    assertEquals(#missing, 0, "the planter has its own hopper; the drill doesn't count")
end)

test("fulfillable sow fields go by each field's planned crop", function()
    setup()
    stubTractors()
    local function field(planned)
        return {
            getFieldState = function() return {} end,
            getPlannedFruitTypeIndex = function() return planned end,
        }
    end
    local wheatField, parsnipField = field(WHEAT), field(PARSNIP)
    local result = TheContractorJobGeneration.getFulfillableFields({ grainDrill, tractor }, sowDef(),
        { wheatField, parsnipField })
    assertEquals(#result, 1)
    assertTrue(result[1] == wheatField, "only the wheat field")
end)

test("a sow job for a planted crop is labelled plant, a drilled one sow", function()
    setup()
    assertEquals(TheContractorJobGeneration.getTypeLabel("sow", PARSNIP), "plant")
    assertEquals(TheContractorJobGeneration.getTypeLabel("sow", POTATO), "plant")
    assertEquals(TheContractorJobGeneration.getTypeLabel("sow", WHEAT), "sow")
    assertEquals(TheContractorJobGeneration.getTypeLabel("sow", nil), "sow", "crop not known")
    assertEquals(TheContractorJobGeneration.getTypeLabel("plow", PARSNIP), "plow", "only sow jobs")
end)

test("a job's label comes from its recorded crop, so clients get it too", function()
    setup()
    local job = TheContractorJob.new(1, 1, "sow", 5, 1, 1, 1, 1000)
    job.fruitTypeName = "PARSNIP"
    assertEquals(job:getTypeLabel(), "plant")
    job.fruitTypeName = "WHEAT"
    assertEquals(job:getTypeLabel(), "sow")
end)

test("the plant label's texts exist alongside sow's", function()
    setup()
    for _, prefix in ipairs({ "tc_jobType_", "tc_equipment_need_implement_", "tc_equipment_missing_implement_" }) do
        assertTrue(g_i18n:hasText(prefix .. "plant"), prefix .. "plant")
        assertTrue(g_i18n:hasText(prefix .. "sow"), prefix .. "sow")
    end
end)

-- Seed choice at dispatch (TCJobSiteSetup.selectJobSeed) ----------------------

-- A sowing machine set to seeds[currentSeed], recording every change.
local function seedableMachine(world, id, seeds, currentSeed)
    local vehicle = {
        id = id,
        spec_sowingMachine = { seeds = seeds, currentSeed = currentSeed },
        setCalls = {},
        getName = function() return "Machine " .. id end,
    }
    function vehicle:setSeedFruitType(fruitTypeIndex)
        table.insert(self.setCalls, fruitTypeIndex)
        for i, index in ipairs(self.spec_sowingMachine.seeds) do
            if index == fruitTypeIndex then
                self.spec_sowingMachine.currentSeed = i
            end
        end
    end
    world.objects[id] = vehicle
    return vehicle
end

local function sowJob(world, fruitTypeName, equipmentIds, jobType)
    world:load("src/util/TCJobSiteSetup.lua")
    local job = TheContractorJob.new(1, 1, jobType or "sow", 5, 1, 1, 1, 1000)
    job.fruitTypeName = fruitTypeName
    job.assignedEquipmentIds = equipmentIds
    return job
end

test("a planter left on another crop is set to the job's before the worker goes", function()
    local world = setup()
    local planter = seedableMachine(world, 10, { POTATO, PARSNIP }, 1)
    local job = sowJob(world, "PARSNIP", { 10 })

    assertEquals(TCJobSiteSetup.selectJobSeed(job), 1)
    assertEquals(#planter.setCalls, 1)
    assertEquals(planter.setCalls[1], PARSNIP)
    assertEquals(planter.spec_sowingMachine.currentSeed, 2)
end)

test("a machine already on the job's crop isn't touched", function()
    local world = setup()
    local planter = seedableMachine(world, 10, { POTATO, PARSNIP }, 2)
    assertEquals(TCJobSiteSetup.selectJobSeed(sowJob(world, "PARSNIP", { 10 })), 0)
    assertEquals(#planter.setCalls, 0)
end)

test("a machine that can't take the crop, or a job that isn't sowing, changes nothing", function()
    local world = setup()
    local drill = seedableMachine(world, 10, { WHEAT }, 1)
    assertEquals(TCJobSiteSetup.selectJobSeed(sowJob(world, "PARSNIP", { 10 })), 0, "drill on parsnips")
    assertEquals(TCJobSiteSetup.selectJobSeed(sowJob(world, "PARSNIP", { 10 }, "plow")), 0, "plow job")
    -- No crop recorded, and the field has no plan either.
    g_fieldManager = { getFieldById = function() return { getPlannedFruitTypeIndex = function() return nil end } end }
    assertEquals(TCJobSiteSetup.selectJobSeed(sowJob(world, nil, { 10 })), 0, "no crop known")
    assertEquals(#drill.setCalls, 0)
end)
