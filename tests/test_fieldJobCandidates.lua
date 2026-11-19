-- A field with a live job on it is never offered again. The job freezes
-- vanilla's NPC fieldwork there (034), so the field still qualifies for the
-- same work, and before this a second plow offer could come for the same
-- field due a month after the first.

local function setup()
    local world = stubs.install()
    TheContractor = { SaveKey = "TheContractor" }
    FinanceStats = { statNames = {}, statNameToIndex = {} }
    MoneyType = { LAST_ID = 0, register = function(name) return name end }
    TheContractorNegotiation = { rollInitialEagerness = function() return 1 end }
    FruitType = { UNKNOWN = 0, WHEAT = 2 }

    world:load("src/business/Job.lua")
    world:load("src/business/Jobs.lua")
    world:load("src/business/CropSpill.lua")
    world:load("src/business/JobGeneration.lua")

    local wheat = { index = FruitType.WHEAT, name = "WHEAT", getIsCatchCrop = function() return false end }
    g_fruitTypeManager = {
        getFruitTypeByIndex = function(_, index)
            return index == FruitType.WHEAT and wheat or nil
        end,
    }

    world.fields = {}
    -- What's really on each field's ground (Field:updateState reads it into
    -- the cached field state); wheat unless set.
    world.groundFruit = {}
    function world:addField(id, owner)
        local fieldState = { isValid = true, fruitTypeIndex = FruitType.WHEAT }
        local field = {
            getId = function() return id end,
            getOwner = function() return owner or 0 end,
            getFieldState = function() return fieldState end,
            updateState = function()
                fieldState.fruitTypeIndex = world.groundFruit[id] or FruitType.WHEAT
            end,
        }
        table.insert(self.fields, field)
        return field
    end
    MowMission = MowMission or { NAME = "mow" }
    g_missionManager = {
        getMissionTypeDataByName = function() return { fruitTypeIndices = {} } end,
    }
    g_fieldManager = {
        getFields = function() return world.fields end,
    }

    local tc = g_currentMission.TheContractor
    tc.Jobs = TheContractorJobs.new()
    -- 113: each field's customer (none unless set).
    world.customers = {}
    tc.Farmers = {
        getCustomerIdForField = function(_, fieldId) return world.customers[fieldId] end,
    }
    world:addRelationships()
    function world:addJob(farmId, id, fieldId, state)
        local job = TheContractorJob.new(id, farmId, "harvest", fieldId, 1, 1, 1, 1000)
        job.state = state
        tc.Jobs.jobsByFarm[farmId] = tc.Jobs.jobsByFarm[farmId] or {}
        tc.Jobs.jobsByFarm[farmId][id] = job
        return job
    end

    return world
end

local function candidateIds()
    local ids = {}
    for _, field in ipairs(TheContractorJobGeneration:getCandidateFields(1,
        TheContractorJobGeneration.JOB_TYPES.harvest)) do
        table.insert(ids, field:getId())
    end
    table.sort(ids)
    return table.concat(ids, ",")
end

test("a field with a live job, any farm's, is not a candidate", function()
    local world = setup()
    for id = 1, 6 do
        world:addField(id)
    end
    local STATE = TheContractorJob.STATE
    world:addJob(1, 1, 1, STATE.OFFERED)
    world:addJob(1, 2, 2, STATE.ACCEPTED)
    world:addJob(1, 3, 3, STATE.IN_PROGRESS)
    world:addJob(2, 4, 4, STATE.OFFERED)

    assertEquals(candidateIds(), "5,6")
end)

test("a field whose job has ended is a candidate again", function()
    local world = setup()
    for id = 1, 3 do
        world:addField(id)
    end
    local STATE = TheContractorJob.STATE
    world:addJob(1, 1, 1, STATE.COMPLETED)
    world:addJob(1, 2, 2, STATE.DECLINED)
    world:addJob(1, 3, 3, STATE.MISSED)

    assertEquals(candidateIds(), "1,2,3")
end)

test("the farm's own fields are still left out", function()
    local world = setup()
    world:addField(1, 1)
    world:addField(2, 2)

    assertEquals(candidateIds(), "2")
end)

-- Vanilla only re-reads a field's cached state once a period (or when its
-- own NPC work there ends), so a field our job had just worked still read
-- as needing the work, and was offered again the same day.
local function offeredHarvestIds()
    TCEquipmentClass = { getMissingEquipment = function() return {} end }
    local ids = {}
    for _, option in ipairs(TheContractorJobGeneration:getJobTypeOptions(1, "harvest")) do
        for _, field in ipairs(option.candidates) do
            table.insert(ids, field:getId())
        end
    end
    table.sort(ids)
    return table.concat(ids, ",")
end

test("a field worked since vanilla last read it is read afresh before an offer", function()
    local world = setup()
    world:addField(1)
    world:addField(2)
    world:addJob(1, 1, 1, TheContractorJob.STATE.COMPLETED)
    -- Field 1 was harvested and cultivated; the cache still says wheat.
    world.groundFruit[1] = FruitType.UNKNOWN

    assertEquals(offeredHarvestIds(), "2")
end)

test("a field with a live job keeps the state its job is measured against", function()
    local world = setup()
    local field = world:addField(1)
    world:addJob(1, 1, 1, TheContractorJob.STATE.IN_PROGRESS)
    world.groundFruit[1] = FruitType.UNKNOWN

    offeredHarvestIds()

    assertEquals(field:getFieldState().fruitTypeIndex, FruitType.WHEAT)
end)

test("137: an announced auction's field gets no job from the announcement until it's over", function()
    local world = setup()
    for id = 1, 3 do
        world:addField(id)
    end
    local tc = g_currentMission.TheContractor
    local auction = { fieldId = 2 }
    -- 163: as tc.PublicEvents answers for every kind of day out.
    tc.PublicEvents = {
        isFieldInUse = function(_, fieldId) return auction ~= nil and auction.fieldId == fieldId end,
    }
    assertEquals(candidateIds(), "1,3")
    assertTrue(tc.Jobs:isFieldProtected(2))
    assertTrue(not tc.Jobs:hasLiveJob(2), "protected by the auction, not by a job")

    auction = nil
    assertEquals(candidateIds(), "1,2,3")
end)
