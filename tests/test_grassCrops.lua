-- A map's own grasses (181): alfalfa, clover and the like are grass when
-- the map's mower turns them into a windrow its tedder dries. Then they're
-- mow, tedder and bale work with their own windrows, never a harvest job.
-- The converter tables are The Pichonniere Valley's and Witcombe's, cut down.

local function fillType(world, name)
    if FillType[name] == nil then
        world:addFillType(name, name)
    end
    return FillType[name]
end

-- map: "pichonniere" or "witcombe" (green rye mows into grass windrow
-- there, and there's no clover).
local function setup(map)
    local world = stubs.install()
    TheContractor = { SaveKey = "TheContractor" }
    FinanceStats = { statNames = {}, statNameToIndex = {} }
    MoneyType = { LAST_ID = 0, register = function(name) return name end }
    TheContractorNegotiation = { rollInitialEagerness = function() return 1 end }
    FruitType = { UNKNOWN = 0, WHEAT = 2, GRASS = 3, ALFALFA = 4, CLOVER = 5, GREENRYE = 6 }
    Season = { SPRING = 0, SUMMER = 1, AUTUMN = 2, WINTER = 3 }
    SeasonPeriod = { EARLY_SPRING = 1, MID_SPRING = 2, LATE_SPRING = 3, EARLY_SUMMER = 4 }
    g_currentMission.environment = { currentSeason = Season.SUMMER, currentPeriod = SeasonPeriod.EARLY_SUMMER }
    MowMission = { NAME = "mow" }
    world.mowData = {}
    g_missionManager = { getMissionTypeDataByName = function() return world.mowData end }
    -- Vanilla's bale rule stands in for straw crops: whatever the test says.
    world.vanillaBale = true
    BaleMission = { isAvailableForField = function() return world.vanillaBale end }

    local f = {
        grass = fillType(world, "GRASS_WINDROW"), dryGrass = fillType(world, "DRYGRASS_WINDROW"),
        straw = fillType(world, "STRAW"), alfalfa = fillType(world, "ALFALFA_WINDROW"),
        dryAlfalfa = fillType(world, "DRYALFALFA_WINDROW"), clover = fillType(world, "CLOVER_WINDROW"),
        dryClover = fillType(world, "DRYCLOVER_WINDROW"), greenRye = fillType(world, "GREENRYE_WINDROW"),
    }
    world.f = f

    -- Growing 1-4, harvestable 5-6 (harvest-ready 6), withered 7, cut 8.
    local function crop(index)
        return { index = index, maxHarvestingGrowthState = 6, regrows = false, cutState = 8,
            getIsCatchCrop = function() return false end,
            getIsCut = function(_, growthState) return growthState == 8 end,
            getIsHarvestable = function(_, growthState) return growthState == 5 or growthState == 6 end,
            getIsHarvestReady = function(_, growthState) return growthState == 6 end }
    end
    local crops = {}
    for _, index in pairs(FruitType) do
        if index ~= FruitType.UNKNOWN then
            crops[index] = crop(index)
        end
    end

    local mower = {
        [FruitType.GRASS] = { fillTypeIndex = f.grass },
        [FruitType.WHEAT] = { fillTypeIndex = f.straw },
        [FruitType.ALFALFA] = { fillTypeIndex = f.alfalfa },
    }
    local tedder = {
        [f.grass] = { targetFillTypeIndex = f.dryGrass },
        [f.dryGrass] = { targetFillTypeIndex = f.dryGrass },
        [f.straw] = { targetFillTypeIndex = f.straw },
        [f.alfalfa] = { targetFillTypeIndex = f.dryAlfalfa },
        [f.dryAlfalfa] = { targetFillTypeIndex = f.dryAlfalfa },
    }
    if map == "witcombe" then
        mower[FruitType.GREENRYE] = { fillTypeIndex = f.grass }
    else
        mower[FruitType.GREENRYE] = { fillTypeIndex = f.greenRye }
        mower[FruitType.CLOVER] = { fillTypeIndex = f.clover }
        tedder[f.clover] = { targetFillTypeIndex = f.dryClover }
        tedder[f.dryClover] = { targetFillTypeIndex = f.dryClover }
    end
    g_fruitTypeManager = {
        getFruitTypeByIndex = function(_, index) return crops[index] end,
        getFruitTypeByName = function(_, name) return crops[FruitType[name]] end,
        getConverterDataByName = function(_, name) return name == "MOWER" and mower or nil end,
        getWindrowFillTypeIndexByFruitTypeIndex = function(_, index)
            return index == FruitType.WHEAT and f.straw or nil
        end,
    }
    g_fillTypeManager.getConverterDataByName = function(_, name) return name == "TEDDER" and tedder or nil end

    world:load("src/business/Job.lua")
    world:load("src/business/Jobs.lua")
    world:load("src/business/CropSpill.lua")
    world:load("src/business/JobGeneration.lua")
    world:load("src/util/TCEquipmentClass.lua")
    FieldGroundType = {}
    world:load("src/util/TCFieldPreparation.lua")
    TheContractorJobGeneration.new()

    world.mowData.fruitTypeIndices = { [FruitType.GRASS] = true }

    function world:field(fruitTypeIndex, growthState)
        local fieldState = { isValid = true, fruitTypeIndex = fruitTypeIndex, growthState = growthState or 5 }
        return { getFieldState = function() return fieldState end }
    end
    return world
end

local function eligible(field, jobType)
    return TheContractorJobGeneration.isFieldEligible(field, TheContractorJobGeneration.JOB_TYPES[jobType])
end

local function job(jobType, fruitTypeName)
    local newJob = TheContractorJob.new(1, 1, jobType, 7, 3, 1, 1, 1000)
    newJob.fruitTypeName = fruitTypeName
    return newJob
end

test("The Pichonniere Valley: grass, alfalfa and clover are grass; green rye and wheat aren't", function()
    local world = setup("pichonniere")
    assertTrue(TheContractorJobGeneration.isGrass(FruitType.GRASS))
    assertTrue(TheContractorJobGeneration.isGrass(FruitType.ALFALFA))
    assertTrue(TheContractorJobGeneration.isGrass(FruitType.CLOVER))
    assertEquals(TheContractorJobGeneration.isGrass(FruitType.GREENRYE), false, "its windrow isn't tedded")
    assertEquals(TheContractorJobGeneration.isGrass(FruitType.WHEAT), false, "straw")

    local clover = TheContractorJobGeneration.getGrassWindrows(FruitType.CLOVER)
    assertEquals(clover.fresh, world.f.clover)
    assertEquals(clover.dry, world.f.dryClover)
end)

test("Witcombe: green rye mows into grass windrow, so it's grass; no clover there", function()
    setup("witcombe")
    assertTrue(TheContractorJobGeneration.isGrass(FruitType.GREENRYE))
    assertTrue(TheContractorJobGeneration.isGrass(FruitType.ALFALFA))
    assertEquals(TheContractorJobGeneration.isGrass(FruitType.CLOVER), false)
end)

test("only vanilla's grass is grass to joyriders", function()
    setup("pichonniere")
    assertTrue(TheContractorJobGeneration.isVanillaGrass(FruitType.GRASS))
    assertEquals(TheContractorJobGeneration.isVanillaGrass(FruitType.ALFALFA), false)
end)

test("an alfalfa field is mow, tedder and bale work, never a harvest", function()
    local world = setup("pichonniere")
    assertEquals(eligible(world:field(FruitType.ALFALFA, 6), "harvest"), false)
    assertTrue(eligible(world:field(FruitType.ALFALFA, 5), "mow"))
    assertTrue(eligible(world:field(FruitType.ALFALFA, 5), "tedder"))
    assertTrue(eligible(world:field(FruitType.ALFALFA, 6), "bale"))
    world.vanillaBale = false
    assertTrue(eligible(world:field(FruitType.ALFALFA, 6), "bale"), "not by vanilla's grass-only rule")
end)

test("grass work on a map grass waits for the crop: cuttable to mow, harvest-ready to bale", function()
    local world = setup("pichonniere")
    assertEquals(eligible(world:field(FruitType.CLOVER, 3), "mow"), false, "still growing")
    assertEquals(eligible(world:field(FruitType.CLOVER, 5), "bale"), false, "not harvest-ready")
    assertTrue(eligible(world:field(FruitType.CLOVER, 6), "bale"))
end)

test("grass work on a map grass keeps vanilla's seasons", function()
    local world = setup("pichonniere")
    g_currentMission.environment.currentPeriod = SeasonPeriod.MID_SPRING
    g_currentMission.environment.currentSeason = Season.SPRING
    assertEquals(eligible(world:field(FruitType.ALFALFA, 5), "mow"), false, "no mowing in early spring")
    assertTrue(eligible(world:field(FruitType.ALFALFA, 6), "bale"), "baling's only kept out of winter")
    g_currentMission.environment.currentSeason = Season.WINTER
    assertEquals(eligible(world:field(FruitType.ALFALFA, 6), "bale"), false)
end)

test("a straw crop: harvested, never mown or tedded, baled by vanilla's rule", function()
    local world = setup("pichonniere")
    assertTrue(eligible(world:field(FruitType.WHEAT, 6), "harvest"))
    assertEquals(eligible(world:field(FruitType.WHEAT, 5), "mow"), false)
    assertEquals(eligible(world:field(FruitType.WHEAT, 5), "tedder"), false)
    assertTrue(eligible(world:field(FruitType.WHEAT, 6), "bale"))
    world.vanillaBale = false
    assertEquals(eligible(world:field(FruitType.WHEAT, 6), "bale"), false)
end)

test("the windrows: tedding alfalfa works its fresh windrow, baling it its dry one", function()
    local world = setup("pichonniere")
    assertEquals(TCFieldPreparation.getJobWindrowFillType(job("tedder", "ALFALFA")), world.f.alfalfa)
    assertEquals(TCFieldPreparation.getJobWindrowFillType(job("bale", "ALFALFA")), world.f.dryAlfalfa)
    assertEquals(TCFieldPreparation.getJobWindrowFillType(job("bale", "CLOVER")), world.f.dryClover)
end)

test("the windrows: grass and straw as before, and a tedder job from before 181 is grass", function()
    local world = setup("pichonniere")
    assertEquals(TCFieldPreparation.getJobWindrowFillType(job("tedder", nil)), world.f.grass)
    assertEquals(TCFieldPreparation.getJobWindrowFillType(job("tedder", "GRASS")), world.f.grass)
    assertEquals(TCFieldPreparation.getJobWindrowFillType(job("bale", "GRASS")), world.f.dryGrass)
    assertEquals(TCFieldPreparation.getJobWindrowFillType(job("bale", "WHEAT")), world.f.straw)
end)

test("a baler has to take the crop's windrow", function()
    local world = setup("pichonniere")
    local function baler(fillTypes)
        local supported = {}
        for _, index in ipairs(fillTypes) do
            supported[index] = true
        end
        return { spec_baler = { fillUnitIndex = 1 },
            getFillUnitSupportsFillType = function(_, _, index) return supported[index] == true end }
    end
    local bale = TheContractorJobGeneration.JOB_TYPES.bale
    local strawBaler = baler({ world.f.straw, world.f.dryGrass })
    local anyBaler = baler({ world.f.straw, world.f.dryGrass, world.f.dryAlfalfa })

    assertEquals(TCEquipmentClass.isJobImplement(strawBaler, bale, FruitType.ALFALFA), false)
    assertTrue(TCEquipmentClass.isJobImplement(anyBaler, bale, FruitType.ALFALFA))
    assertTrue(TCEquipmentClass.isJobImplement(strawBaler, bale, FruitType.WHEAT))
    assertTrue(TCEquipmentClass.isJobImplement(strawBaler, bale, nil), "any crop")
end)

test("the converter tables are read once they're there, not before", function()
    local world = setup("pichonniere")
    local mower = g_fruitTypeManager.getConverterDataByName
    g_fruitTypeManager.getConverterDataByName = function() return nil end
    TheContractorJobGeneration.clearGrassWindrows()
    assertEquals(TheContractorJobGeneration.getGrassWindrows(FruitType.ALFALFA), nil)
    g_fruitTypeManager.getConverterDataByName = mower
    assertEquals(TheContractorJobGeneration.getGrassWindrows(FruitType.ALFALFA).dry, world.f.dryAlfalfa)
end)
