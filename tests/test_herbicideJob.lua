-- Herbicide jobs (179): vanilla's sprayer only clears the weeds in a crop
-- that's still growing (FSDensityMapUtil.updateHerbicideArea), but its
-- HerbicideMission.isAvailableForField lets a withered crop through. So a
-- herbicide job is only offered on a growing crop, and one whose crop has
-- ripened or withered since the offer is put back to its last growing
-- state when it's taken on.

local currentWorld

local function setup()
    local world = stubs.install()
    currentWorld = world
    TheContractor = { SaveKey = "TheContractor" }
    FinanceStats = { statNames = {}, statNameToIndex = {} }
    MoneyType = { LAST_ID = 0, register = function(name) return name end }
    TheContractorNegotiation = { rollInitialEagerness = function() return 1 end }
    FruitType = { UNKNOWN = 0, WHEAT = 2, POTATO = 3 }

    world:load("src/business/Job.lua")
    world:load("src/business/Jobs.lua")
    world:load("src/business/CropSpill.lua")
    world:load("src/business/JobGeneration.lua")

    -- Wheat: growing 1-4, ready 5-6, withered 7, cut 8. Potatoes: growing
    -- 1-3, prepared for harvest from 4.
    local function crop(index, minHarvest, minPreparing)
        local fruitType = { index = index, minHarvestingGrowthState = minHarvest,
            minPreparingGrowthState = minPreparing }
        function fruitType:getIsGrowing(growthState)
            local maxGrowing = self.minHarvestingGrowthState - 1
            if self.minPreparingGrowthState >= 0 then
                maxGrowing = math.min(maxGrowing, self.minPreparingGrowthState - 1)
            end
            return growthState > 0 and growthState <= maxGrowing
        end
        return fruitType
    end
    world.crops = {
        [FruitType.WHEAT] = crop(FruitType.WHEAT, 5, -1),
        [FruitType.POTATO] = crop(FruitType.POTATO, 6, 4),
    }
    g_fruitTypeManager = { getFruitTypeByIndex = function(_, index) return world.crops[index] end }

    -- Vanilla's rule, as permissive as the real one about a withered crop.
    HerbicideMission = {
        isAvailableForField = function(field)
            local state = field:getFieldState()
            return state.fruitTypeIndex ~= FruitType.UNKNOWN and state.weedState > 0
        end,
    }
    TheContractorJobGeneration.JOB_TYPES.herbicide.vanillaMission = HerbicideMission
    MowMission = { NAME = "mow" }
    g_missionManager = { getMissionTypeDataByName = function() return nil end }
    return world
end

local function newField(state)
    local fieldState = { isValid = true, fruitTypeIndex = FruitType.WHEAT, growthState = 3, weedState = 2 }
    for key, value in pairs(state or {}) do
        fieldState[key] = value
    end
    return {
        getFieldState = function() return fieldState end,
        getAngle = function() return 0 end,
    }
end

local function eligible(state)
    return TheContractorJobGeneration.isFieldEligible(newField(state), TheContractorJobGeneration.JOB_TYPES.herbicide)
end

test("offered on a growing crop with weeds, never on a ripe, withered or cut one", function()
    setup()
    assertTrue(eligible({ growthState = 1 }), "just sown")
    assertTrue(eligible({ growthState = 4 }), "last growing state")
    assertEquals(eligible({ growthState = 5 }), false, "ready")
    assertEquals(eligible({ growthState = 7 }), false, "withered")
    assertEquals(eligible({ growthState = 8 }), false, "cut")
    assertEquals(eligible({ growthState = 2, weedState = 0 }), false, "no weeds: vanilla's rule still applies")
    assertEquals(eligible({ fruitTypeIndex = FruitType.POTATO, growthState = 4 }), false, "being prepared")
end)

test("a crop's last growing state stops short of ready, and of being prepared", function()
    local world = setup()
    assertEquals(TheContractorJobGeneration.getLastGrowingState(world.crops[FruitType.WHEAT]), 4)
    assertEquals(TheContractorJobGeneration.getLastGrowingState(world.crops[FruitType.POTATO]), 3)
end)

local function prepare(state)
    TCJobProgress = { POLL_INTERVAL_MS = 3000, clearJob = function() end }
    FieldGroundType = {}
    currentWorld:load("src/util/TCFieldPreparation.lua")

    local applied = {}
    local field = newField(state)
    local fieldState = field:getFieldState()
    function fieldState:createFieldUpdateTask()
        local task = { growthState = self.growthState, weedState = self.weedState }
        function task:setField() end
        function task:setGroundAngle() end
        function task:clearHeight() end
        return task
    end
    g_fieldManager = {
        getFieldById = function() return field end,
        addFieldUpdateTask = function(_, task) table.insert(applied, task) end,
    }
    local job = TheContractorJob.new(1, 1, "herbicide", 7, 1, 1, 1, 1000)
    job.startState = 2
    assertTrue(TCFieldPreparation.prepareFieldForJob(job))
    assertEquals(#applied, 1)
    return applied[1]
end

test("taken on after the crop withered: back to its last growing state, weeds as offered", function()
    setup()
    local task = prepare({ growthState = 7, weedState = 0 })
    assertEquals(task.growthState, 4)
    assertEquals(task.weedState, 2)
end)

test("taken on after the crop ripened: back to growing too", function()
    setup()
    assertEquals(prepare({ growthState = 5 }).growthState, 4)
end)

test("a crop still growing is left as it is", function()
    setup()
    assertEquals(prepare({ growthState = 2 }).growthState, 2)
end)
