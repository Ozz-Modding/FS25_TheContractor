-- The job report (tcDebug jobReport): every field's verdict comes from the
-- generator's own checks, so a field the report calls offerable is exactly
-- one getDeadlineDay can date, and each rejection names the check that
-- turned it down. Plus the offer share it quotes, from pickJobType's split.

local TODAY = 40

local function setup()
    local world = stubs.install()
    TheContractor = { SaveKey = "TheContractor" }
    FinanceStats = { statNames = {}, statNameToIndex = {} }
    MoneyType = { LAST_ID = 0, register = function(name) return name end }
    TheContractorNegotiation = { rollInitialEagerness = function() return 1 end }

    g_currentMission.environment = {
        currentPeriod = 7,
        currentDayInPeriod = 2,
        daysPerPeriod = 3,
        currentHour = 9,
        currentMonotonicDay = TODAY,
    }
    g_currentMission.missionInfo.growthMode = 1

    -- Wheat is ready from growth state 5; grass is mow work.
    FruitType = { UNKNOWN = 0, WHEAT = 2, GRASS = 3 }
    local function crop(index, name)
        return {
            index = index,
            name = name,
            getIsCatchCrop = function() return false end,
            getIsHarvestReady = function(_, growthState) return growthState ~= nil and growthState >= 5 end,
            getSeasonalGrowthData = function() return nil end,
        }
    end
    local crops = { [FruitType.WHEAT] = crop(FruitType.WHEAT, "WHEAT"), [FruitType.GRASS] = crop(FruitType.GRASS, "GRASS") }
    g_fruitTypeManager = {
        getFruitTypeByIndex = function(_, index) return crops[index] end,
    }

    world:load("src/business/Job.lua")
    world:load("src/business/Jobs.lua")
    world:load("src/business/CropSpill.lua")
    world:load("src/business/JobGeneration.lua")
    world:load("src/util/TCJobReport.lua")
    TheContractorJobGeneration.isGrass = function(index) return index == FruitType.GRASS end

    -- Each field's crop prediction: world.readyOn[fieldId] the predicted
    -- ready day (nil: can't be predicted), world.readyUntil[fieldId] the
    -- last day it's still ready.
    world.readyOn, world.readyUntil = {}, {}
    TCCropPrediction = {
        getEstimatedHarvestReadyDate = function(field)
            local day = world.readyOn[field:getId()]
            return day ~= nil and { absoluteDay = day } or nil
        end,
        isHarvestReadyOnDay = function(field, day)
            local from = world.readyOn[field:getId()] or TODAY
            local to = world.readyUntil[field:getId()] or math.huge
            return day >= from and day <= to
        end,
    }
    TCEquipmentClass = {
        getMissingEquipment = function() return world.missing or {} end,
        isHarvester = function() return false end,
    }

    world.fields = {}
    -- def: { id, owner, fruit, growthState }
    function world:addField(def)
        local fieldState = { isValid = true, fruitTypeIndex = def.fruit or FruitType.WHEAT,
            growthState = def.growthState or 5 }
        local field = {
            getId = function() return def.id end,
            getOwner = function() return def.owner or 0 end,
            getFieldState = function() return fieldState end,
            getAreaHa = function() return 2 end,
            getPlannedFruitTypeIndex = function() return FruitType.UNKNOWN end,
        }
        table.insert(self.fields, field)
        return field
    end
    g_fieldManager = { getFields = function() return world.fields end }

    local tc = g_currentMission.TheContractor
    tc.Jobs = TheContractorJobs.new()
    tc.Farmers = { getCustomerIdForField = function() return nil end }
    world:addRelationships()
    tc.Company = { hasCompany = function() return true end }
    tc.Reputation = {
        getReputationScore = function() return 10 end,
        getReputationTier = function() return { key = "unknownContractor" } end,
        getStanding = function() return 0 end,
    }
    tc.Settings = { get = function() return 1 end }
    tc.JobGeneration = TheContractorJobGeneration.new()
    tc.JobGeneration.getHourlyChance = function() return 0.03 end
    tc.JobGeneration.getAvailabilitySnapshot = function()
        return { { jobType = "harvest", candidates = 1, datable = 1, fulfillable = 1 } }
    end
    TheContractorSettings = { ITEMS = { "jobPayRate" } }
    TCCalendar.formatDayShort = function(day) return tostring(day) end

    function world:addJob(farmId, id, fieldId, state)
        local job = TheContractorJob.new(id, farmId, "harvest", fieldId, 1, 1, 1, 1000)
        job.state = state
        tc.Jobs.jobsByFarm[farmId] = tc.Jobs.jobsByFarm[farmId] or {}
        tc.Jobs.jobsByFarm[farmId][id] = job
        return job
    end
    return world
end

local function verdicts(data)
    local result = {}
    for _, row in ipairs(data.fields) do
        result[row.fieldId] = row
    end
    return result
end

test("each field's verdict names the check that turned it down", function()
    local world = setup()
    world:addField({ id = 1, owner = 1 })
    world:addField({ id = 2 })
    world:addJob(1, 1, 2, TheContractorJob.STATE.OFFERED)
    world:addField({ id = 3, fruit = FruitType.GRASS })
    world:addField({ id = 4, growthState = 2 })      -- not ready, no prediction
    world:addField({ id = 5, growthState = 2 })      -- ready later
    world.readyOn[5] = TODAY + 3
    world:addField({ id = 6 })                       -- ready now

    local rows = verdicts(TCJobReport.collect(1, "harvest"))

    assertEquals(rows[1].verdict, "owned")
    assertEquals(rows[2].verdict, "protected")
    assertEquals(rows[3].verdict, "notEligible")
    assertEquals(rows[3].cropIneligibility, "grass")
    assertEquals(rows[4].verdict, "unpredictable")
    assertEquals(rows[5].verdict, "offerable")
    assertEquals(rows[5].workStartDay, TODAY + 3)
    assertEquals(rows[6].verdict, "offerable")
    assertEquals(rows[6].earliestDay, TODAY)
end)

test("late in the day a crop that goes over tonight has no workable deadline", function()
    local world = setup()
    g_currentMission.environment.currentHour = 18
    world:addField({ id = 1 })
    world.readyUntil[1] = TODAY

    local row = verdicts(TCJobReport.collect(1, "harvest"))[1]

    assertEquals(row.verdict, "notDoable")
    assertEquals(row.earliestDay, TODAY + 1)
    assertEquals(row.lastDoableDay, TODAY)
end)

test("the report's offerable fields are exactly the ones the generator can date", function()
    local world = setup()
    g_currentMission.environment.currentHour = 18
    world:addField({ id = 1 })
    world.readyUntil[1] = TODAY
    world:addField({ id = 2 })
    world:addField({ id = 3, growthState = 2 })
    world:addField({ id = 4, growthState = 2 })
    world.readyOn[4] = TODAY + 2

    local rows = verdicts(TCJobReport.collect(1, "harvest"))
    local jobDef = TheContractorJobGeneration.JOB_TYPES.harvest
    for _, field in ipairs(world.fields) do
        local dated = g_currentMission.TheContractor.JobGeneration:getDeadlineDay(field, jobDef) ~= nil
        assertEquals(rows[field:getId()].verdict == "offerable", dated, "field " .. field:getId())
    end
end)

test("what the farm lacks is noted on fields the roll could offer", function()
    local world = setup()
    world.missing = { "cutter" }
    world:addField({ id = 1 })
    world:addField({ id = 2, owner = 1 })

    local rows = verdicts(TCJobReport.collect(1, "harvest"))

    assertEquals(rows[1].missingEquipment[1], "cutter")
    assertEquals(rows[2].missingEquipment, nil)
end)

test("a type the save rules out gives every field that verdict", function()
    local world = setup()
    g_currentMission.missionInfo.weedsEnabled = false
    world:addField({ id = 1 })

    local data = TCJobReport.collect(1, "weed")

    assertEquals(data.typeRejection, "weedsOff")
    assertEquals(verdicts(data)[1].verdict, "typeRejected")
end)

test("the offer share follows pickJobType's split, harvest counting double", function()
    setup()
    local share = TheContractorJobGeneration.FULFILLABLE_TYPE_SHARE
    local snapshot = {
        { jobType = "harvest", datable = 3, fulfillable = 0 },
        { jobType = "plow", datable = 5, fulfillable = 5 },
        { jobType = "mow", datable = 2, fulfillable = 2 },
        { jobType = "lime", datable = 0, fulfillable = 0 },
    }

    -- Weights with work: harvest 2, plow 1, mow 1. Harvest without the kit
    -- only gets the open share.
    assertNear(TCJobReport.estimateTypeShare(snapshot, "harvest"), (1 - share) * 2 / 4, 1e-9)
    assertNear(TCJobReport.estimateTypeShare(snapshot, "plow"), share / 2 + (1 - share) / 4, 1e-9)
    assertEquals(TCJobReport.estimateTypeShare(snapshot, "lime"), 0)

    snapshot[2].fulfillable, snapshot[3].fulfillable = 0, 0
    assertNear(TCJobReport.estimateTypeShare(snapshot, "harvest"), 2 / 4, 1e-9)
end)

test("pickJobType picks harvest twice as often as a type without a weight", function()
    setup()
    local JOB_TYPES = TheContractorJobGeneration.JOB_TYPES
    local options = {
        { jobType = "harvest", jobDef = JOB_TYPES.harvest, candidates = { "a" }, fulfillable = { "a" } },
        { jobType = "plow", jobDef = JOB_TYPES.plow, candidates = { "b" }, fulfillable = { "b" } },
    }
    local random = math.random
    local picks = {}
    -- Rolls spread evenly over [0, 1): two thirds of the weight is harvest's.
    for i = 0, 29 do
        math.random = function() return (i + 0.5) / 30 end
        local option = TheContractorJobGeneration:pickJobType(options, true)
        picks[option.jobType] = (picks[option.jobType] or 0) + 1
    end
    math.random = random

    assertEquals(picks.harvest, 20)
    assertEquals(picks.plow, 10)
end)

test("the report formats a full map without failing", function()
    local world = setup()
    world:addField({ id = 1, owner = 1 })
    world:addField({ id = 2, fruit = FruitType.GRASS })
    world:addField({ id = 3, growthState = 2 })
    world:addField({ id = 4 })
    world:addJob(1, 1, 4, TheContractorJob.STATE.ACCEPTED)

    local lines = TCJobReport.format(TCJobReport.collect(1, "harvest"))

    assertTrue(#lines > 0)
end)
