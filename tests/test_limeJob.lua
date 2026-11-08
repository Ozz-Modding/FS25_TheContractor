-- Lime jobs (149): which fields are due lime, only on a save that needs it,
-- the spreader that does it, and the job measured by limed ground.

local function setup()
    local world = stubs.install()
    TheContractor = { SaveKey = "TheContractor" }
    FinanceStats = { statNames = {}, statNameToIndex = {} }
    MoneyType = { LAST_ID = 0, register = function(name) return name end }
    TheContractorNegotiation = { rollInitialEagerness = function() return 1 end }
    FruitType = { UNKNOWN = 0, WHEAT = 2, GRASS = 3, OILSEEDRADISH = 4 }

    world:load("src/business/Job.lua")
    world:load("src/business/Jobs.lua")
    world:load("src/business/CropSpill.lua")
    world:load("src/business/JobGeneration.lua")

    -- Growing 1-4, harvestable 5-6, withered 7, cut 8.
    local function crop(index, extra)
        local fruitType = { index = index, maxHarvestingGrowthState = 6, regrows = false,
            getIsCatchCrop = function() return false end,
            getIsCut = function(_, growthState) return growthState == 8 end }
        for key, value in pairs(extra or {}) do
            fruitType[key] = value
        end
        return fruitType
    end
    local crops = {
        [FruitType.WHEAT] = crop(FruitType.WHEAT),
        [FruitType.GRASS] = crop(FruitType.GRASS, { regrows = true }),
        [FruitType.OILSEEDRADISH] = crop(FruitType.OILSEEDRADISH,
            { getIsCatchCrop = function() return true end }),
    }
    g_fruitTypeManager = { getFruitTypeByIndex = function(_, index) return crops[index] end }

    Platform = { gameplay = { useLimeCounter = true } }
    g_currentMission.missionInfo.limeRequired = true

    world.fields = {}
    function world:addField(id, state)
        local fieldState = { isValid = true, fruitTypeIndex = FruitType.UNKNOWN, growthState = 0, limeLevel = 0 }
        for key, value in pairs(state or {}) do
            fieldState[key] = value
        end
        local field = {
            getId = function() return id end,
            getOwner = function() return 0 end,
            getFieldState = function() return fieldState end,
        }
        table.insert(self.fields, field)
        return field
    end
    g_fieldManager = { limeLevelMaxValue = 3, getFields = function() return world.fields end }

    local tc = g_currentMission.TheContractor
    tc.Jobs = TheContractorJobs.new()
    tc.Farmers = { getCustomerIdForField = function() return nil end }
    world:addRelationships()
    return world
end

local function lime()
    return TheContractorJobGeneration.JOB_TYPES.lime
end

local function candidateIds()
    local ids = {}
    for _, field in ipairs(TheContractorJobGeneration:getCandidateFields(1, lime())) do
        table.insert(ids, field:getId())
    end
    table.sort(ids)
    return table.concat(ids, ",")
end

test("generated like any field job, with nothing vanilla to lean on", function()
    setup()
    assertEquals(TheContractorJobGeneration.findJobType("LIME"), "lime")
    assertEquals(lime().vanillaMission, nil)
    assertEquals(lime().skill, "cropCare")
    assertEquals(lime().workAreaTypes[1], "SPRAYER")
end)

test("an empty field or a cut crop out of lime is due it", function()
    local world = setup()
    world:addField(1)
    world:addField(2, { fruitTypeIndex = FruitType.WHEAT, growthState = 8 })

    assertEquals(candidateIds(), "1,2")
end)

test("a field with lime left isn't", function()
    local world = setup()
    world:addField(1, { limeLevel = 1 })
    world:addField(2, { fruitTypeIndex = FruitType.WHEAT, growthState = 8, limeLevel = 3 })

    assertEquals(candidateIds(), "")
end)

test("nor is a crop lime wouldn't land on, or that could grow before the work", function()
    local world = setup()
    -- Just sown, growing, ready, withered.
    world:addField(1, { fruitTypeIndex = FruitType.WHEAT, growthState = 1 })
    world:addField(2, { fruitTypeIndex = FruitType.WHEAT, growthState = 3 })
    world:addField(3, { fruitTypeIndex = FruitType.WHEAT, growthState = 5 })
    world:addField(4, { fruitTypeIndex = FruitType.WHEAT, growthState = 7 })
    -- Cut grass grows back; a catch crop isn't a field to lime.
    world:addField(5, { fruitTypeIndex = FruitType.GRASS, growthState = 8 })
    world:addField(6, { fruitTypeIndex = FruitType.OILSEEDRADISH, growthState = 8 })

    assertEquals(candidateIds(), "")
end)

test("a save that doesn't need lime has no lime jobs", function()
    local world = setup()
    world:addField(1)

    g_currentMission.missionInfo.limeRequired = false
    assertEquals(TheContractorJobGeneration.getLimeRequired(), false)
    assertEquals(candidateIds(), "")

    g_currentMission.missionInfo.limeRequired = true
    Platform.gameplay.useLimeCounter = false
    assertEquals(candidateIds(), "")

    Platform.gameplay.useLimeCounter = true
    assertEquals(candidateIds(), "1")
end)

test("done with a spreader that takes lime, not one that only takes fertilizer", function()
    local world = setup()
    world:addFillType("LIME", "Lime")
    world:load("src/util/TCEquipmentClass.lua")
    local function spreader(fillTypes)
        local supported = {}
        for _, fillTypeIndex in ipairs(fillTypes) do
            supported[fillTypeIndex] = true
        end
        return {
            spec_sprayer = { fillUnitIndex = 1 },
            getFillUnitSupportsFillType = function(_, _, fillTypeIndex) return supported[fillTypeIndex] == true end,
        }
    end

    assertTrue(TCEquipmentClass.isJobImplement(spreader({ FillType.FERTILIZER, FillType.LIME }), lime()))
    assertEquals(TCEquipmentClass.isJobImplement(spreader({ FillType.FERTILIZER }), lime()), false)
end)

test("measured by the ground limed to the full level", function()
    local world = setup()
    local compared = {}
    local modifier = {}
    function modifier:setPolygonClipRegion() end
    function modifier:getPolygonMinMaxZ() return 0, 1 end
    -- Half the field limed to the full level.
    function modifier:executeGet() return 50, 50, 100 end
    DensityMapModifier = { new = function() return modifier end }
    DensityMapFilter = { new = function()
        return { setValueCompareParams = function(_, compareType, value)
            table.insert(compared, { compareType, value })
        end }
    end }
    DensityValueCompareType = { EQUAL = 2 }
    FieldDensityMap = { LIME_LEVEL = 5 }
    g_terrainNode = 1
    g_currentMission.fieldGroundSystem = {
        getDensityMapData = function(_, map) return map, 0, 2 end,
        getMaxValue = function(_, map) return map == FieldDensityMap.LIME_LEVEL and 3 or 0 end,
    }
    AbstractMission = { SUCCESS_FACTOR = 1 }
    MathUtil = MathUtil or {}
    MathUtil.haToSqm = function(ha) return ha * 10000 end
    local field = {
        getDensityMapPolygon = function() return { applyToModifier = function() end } end,
        getAreaHa = function() return 0.01 end,
    }
    g_fieldManager.getFieldById = function() return field end
    TCFieldPreparation = { isPreparing = function() return false end }
    world:load("src/util/TCJobProgress.lua")

    local job = TheContractorJob.new(1, 1, "lime", 1, 1, 1, 1, 1000)
    job.state = TheContractorJob.STATE.IN_PROGRESS
    g_currentMission.TheContractor.Jobs.getAllJobs = function() return { job } end
    TCJobProgress.update(TCJobProgress.POLL_INTERVAL_MS)

    assertEquals(#compared, 1)
    assertEquals(compared[1][1], DensityValueCompareType.EQUAL)
    assertEquals(compared[1][2], 3)
    assertNear(job.completionPercentage, 50, 1e-9)
end)

test("taken on, the whole field's out of lime, whatever was limed since the offer", function()
    local world = setup()
    TCJobProgress = { POLL_INTERVAL_MS = 3000, clearJob = function() end }
    FieldGroundType = {}
    world:load("src/util/TCFieldPreparation.lua")

    local applied = {}
    local fieldState = { isValid = true, fruitTypeIndex = FruitType.WHEAT, growthState = 8, limeLevel = 2 }
    function fieldState:createFieldUpdateTask()
        local task = { limeLevel = self.limeLevel, fruitTypeIndex = self.fruitTypeIndex }
        function task:setField() end
        function task:setGroundAngle() end
        function task:clearHeight() end
        return task
    end
    local field = {
        getFieldState = function() return fieldState end,
        getAngle = function() return 0 end,
    }
    g_fieldManager.getFieldById = function() return field end
    g_fieldManager.addFieldUpdateTask = function(_, task) table.insert(applied, task) end

    local job = TheContractorJob.new(1, 1, "lime", 7, 1, 1, 1, 1000)
    assertTrue(TCFieldPreparation.prepareFieldForJob(job))

    assertEquals(#applied, 1)
    assertEquals(applied[1].limeLevel, 0)
    assertEquals(applied[1].fruitTypeIndex, FruitType.WHEAT, "the stubble stays")
end)
