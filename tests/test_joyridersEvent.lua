-- Joyriders (072) on the real random events framework (068): which fields
-- can be hit, the plow offer on an NPC's field (keeping the damage at
-- allocation), the farm's own field (message only), the follow-on grass sow
-- job, and JobGeneration:createJobOnField. The ruts themselves are
-- test_joyriders.lua's.

local function setup()
    local world = stubs.install()
    TheContractor = { SaveKey = "TheContractor" }
    world.texts.ui_on = "On"
    world.texts.ui_off = "Off"
    for month = 1, 12 do
        world.texts["ui_month" .. month] = "Month " .. month
    end

    Environment = { PERIODS_IN_YEAR = 12 }
    Season = { SPRING = 0, SUMMER = 1, AUTUMN = 2, WINTER = 3 }
    world.season = Season.SUMMER
    g_currentMission.environment = {
        currentYear = 1,
        currentPeriod = 5,
        currentDayInPeriod = 1,
        daysPerPeriod = 3,
        plannedDaysPerPeriod = 3,
        currentMonotonicDay = 40,
        getSeasonAtDay = function()
            return world.season
        end,
        getPeriodFromDay = function(_, day)
            return 5
        end,
        getDayInPeriodFromDay = function(_, day)
            return day % 3 + 1
        end,
    }
    g_farmManager.getFarmById = function(_, farmId)
        return { farmId = farmId }
    end

    FarmlandManager = { NO_OWNER_FARM_ID = 0 }
    FruitType = { UNKNOWN = 0, GRASS = 1, WHEAT = 2 }
    FieldGroundType = { STUBBLE_TILLAGE = 2, CULTIVATED = 3, PLOWED = 5 }
    local fruitNames = { [FruitType.GRASS] = "GRASS", [FruitType.WHEAT] = "WHEAT" }
    g_fruitTypeManager = {
        getFruitTypeNameByIndex = function(_, index)
            return fruitNames[index]
        end,
        getFruitTypeByName = function(_, name)
            for index, fruitName in pairs(fruitNames) do
                if fruitName == name then
                    return { index = index, name = name }
                end
            end
            return nil
        end,
    }
    MowMission = { NAME = "mow" }
    g_missionManager = {
        getMissionTypeDataByName = function()
            return { fruitTypeIndices = { [FruitType.GRASS] = true } }
        end,
    }
    TCJobProgress = { POLL_INTERVAL_MS = 3000, clearJob = function() end }

    -- Fields: def { id, owner, fruit }.
    world.fields, world.protected = {}, {}
    function world:addField(def)
        local field = {
            id = def.id,
            owner = def.owner or 0,
            fieldState = { isValid = true, fruitTypeIndex = def.fruit or FruitType.GRASS },
            plannedFruitTypeIndex = def.planned or FruitType.WHEAT,
        }
        function field:getId() return self.id end
        function field:getOwner() return self.owner end
        function field:getFieldState() return self.fieldState end
        function field:getPlannedFruitTypeIndex() return self.plannedFruitTypeIndex end
        function field:getAngle() return 0 end
        table.insert(self.fields, field)
        return field
    end
    g_fieldManager = {
        getFields = function()
            return world.fields
        end,
        getFieldById = function(_, fieldId)
            for _, field in ipairs(world.fields) do
                if field.id == fieldId then
                    return field
                end
            end
            return nil
        end,
        addFieldUpdateTask = function(_, task)
            table.insert(world.fieldTasks, task)
        end,
    }
    world.fieldTasks = {}
    FieldUpdateTask = {
        new = function()
            local task = {}
            setmetatable(task, { __index = function()
                return function() end
            end })
            return task
        end,
    }

    world.painted = {}
    TCJoyriderRuts = {
        paintField = function(field)
            table.insert(world.painted, field.id)
            return { length = 100, insideLength = 90, pieces = 360, coverage = 0.5, targetCoverage = 0.5 }
        end,
    }

    world:load("src/util/TCCalendar.lua")
    world:load("src/util/TCConsole.lua")
    world:load("src/business/Settings.lua")
    world:load("src/business/RandomEvents.lua")
    world:load("src/business/JobGeneration.lua")
    world:load("src/util/TCFieldPreparation.lua")
    world:load("src/business/Joyriders.lua")
    -- For its text rendering only (getCustomerNamedArgs, 112); the inbox
    -- itself is faked below.
    world:load("src/business/Inbox.lua")

    TCRandomEventIncidentEvent = {
        new = function(incident, isClosed)
            return { incident = incident, isClosed = isClosed }
        end,
    }

    local tc = g_currentMission.TheContractor
    tc.Settings = TheContractorSettings.new()
    tc.Company = { companyNames = { [1] = "Test Contracting" } }

    -- Jobs: createJob records what it was given and hands back a plain job.
    world.jobs = {}
    tc.Jobs = {
        isFieldProtected = function(_, fieldId)
            return world.protected[fieldId] == true
        end,
        createJob = function(_, farmId, jobType, fieldId, requiredSkillLevel, targetPeriod, targetDayInPeriod, price,
                             equipmentAvailable, fruitTypeName, deadlineDay, includesHaulage, deliveryStation,
                             startState)
            local job = { id = #world.jobs + 1, farmId = farmId, jobType = jobType, fieldId = fieldId,
                requiredSkillLevel = requiredSkillLevel, targetPeriod = targetPeriod,
                targetDayInPeriod = targetDayInPeriod, price = price, equipmentAvailable = equipmentAvailable,
                fruitTypeName = fruitTypeName, deadlineDay = deadlineDay, includesHaulage = includesHaulage,
                startState = startState, spawnedBaleIds = {} }
            table.insert(world.jobs, job)
            return job
        end,
    }

    -- JobGeneration: real createJobOnField, with the dating and pricing it
    -- leans on faked (they have their own tests).
    world.noDeadline = {}
    tc.JobGeneration = TheContractorJobGeneration.new()
    tc.JobGeneration.getDeadlineDay = function(_, field, jobDef, sameMonth)
        if world.noDeadline[jobDef] then
            return nil
        end
        world.sameMonth = sameMonth
        return 42
    end
    tc.JobGeneration.rollRequiredSkillLevel = function()
        return 3
    end
    tc.JobGeneration.canFulfill = function()
        return true
    end
    tc.JobGeneration.estimatePrice = function()
        return 5000
    end

    world.messages = {}
    tc.Inbox = {
        registerMessageKind = function(_, kind, definition)
            world.kind = { kind = kind, definition = definition }
        end,
        getKind = function(_, kind)
            return world.kind ~= nil and world.kind.kind == kind and world.kind.definition or nil
        end,
        -- No farmers here (110), so the offers name nobody.
        getMessageCustomer = function()
            return nil
        end,
        postMessage = function(_, farmId, kind, titleKey, bodyKey, args, actions, payload)
            -- Rendered as the client would, so a broken text fails here.
            local message = { farmId = farmId, kind = kind, titleKey = titleKey, bodyKey = bodyKey, args = args,
                payload = payload }
            local title = TheContractorInbox.getTitle(message)
            local body = TheContractorInbox.getBody(message)
            table.insert(world.messages, { farmId = farmId, kind = kind, titleKey = titleKey, bodyKey = bodyKey,
                args = args, title = title, body = body, payload = payload })
            return #world.messages
        end,
    }

    tc.RandomEvents = TheContractorRandomEvents.new()
    tc.Joyriders = TheContractorJoyriders.new()
    tc.Joyriders:register(tc.RandomEvents, tc.Inbox)
    return world, tc
end

local function eligibleIds(tc, farmId)
    local ids = {}
    for _, field in ipairs(tc.Joyriders:getEligibleFields(farmId)) do
        table.insert(ids, field.id)
    end
    table.sort(ids)
    return table.concat(ids, ",")
end

test("registered as a random event with its own inbox kind", function()
    local _, tc = setup()
    local definition = tc.RandomEvents:getEventType("joyriders")
    assertTrue(definition ~= nil)
    assertEquals(definition.cooldownPeriods, 6)
    assertNear(definition.ratePerPeriod(1), 0.03, 1e-9)
end)

test("only grass fields of an NPC or the farm's own, with no live job, outside winter", function()
    local world, tc = setup()
    world:addField({ id = 1 })                          -- NPC grass
    world:addField({ id = 2, owner = 1 })               -- our own grass
    world:addField({ id = 3, owner = 2 })               -- another player's farm
    world:addField({ id = 4, fruit = FruitType.WHEAT }) -- not grass
    world:addField({ id = 5 })                          -- has a job on it
    world:addField({ id = 6, fruit = FruitType.UNKNOWN }) -- bare
    world.protected[5] = true

    assertEquals(eligibleIds(tc, 1), "1,2")
    assertEquals(eligibleIds(tc, 2), "1,3", "farm 2's own field is fair game for farm 2's event")

    world.season = Season.WINTER
    assertEquals(tc.Joyriders:pickField(1), nil, "never in winter")
    assertEquals(tc.RandomEvents:triggerEvent(1, "joyriders"), nil)

    world.season = Season.AUTUMN
    world.fields = { world.fields[4] }
    assertEquals(tc.Joyriders:pickField(1), nil, "no grass, no event")
end)

test("an NPC's field: torn up and a plow job offered that keeps the damage", function()
    local world, tc = setup()
    world:addField({ id = 12 })

    local incident = tc.RandomEvents:triggerEvent(1, "joyriders")
    assertTrue(incident ~= nil)
    assertEquals(incident.data.fieldId, 12)
    assertEquals(incident.data.isOwnField, false)
    assertEquals(#tc.RandomEvents:getIncidents(1), 0, "done in one stage")
    assertEquals(tc.RandomEvents:getCooldownLeft(1, "joyriders"), 6)

    assertEquals(table.concat(world.painted, ","), "12", "ruts painted")
    assertEquals(#world.jobs, 1, "one job")
    local job = world.jobs[1]
    assertEquals(job.jobType, "plow")
    assertEquals(job.fieldId, 12)
    assertEquals(job.farmId, 1)
    assertEquals(job.keepFieldState, true)
    assertEquals(job.followOnSow, true)
    assertEquals(job.price, 5000)
    assertEquals(job.deadlineDay, 42)
    assertEquals(world.sameMonth, true, "due this month")

    assertEquals(#world.messages, 1)
    assertEquals(world.messages[1].kind, "joyriders")
    assertEquals(world.messages[1].bodyKey, "tc_joyriders_offerBody", "the job offer")
    assertEquals(world.messages[1].args[1], 12, "the field")
    assertEquals(world.messages[1].payload.jobId, job.id)
end)

test("the farm's own field: torn up, a message and no job", function()
    local world, tc = setup()
    world:addField({ id = 7, owner = 1 })

    local incident = tc.RandomEvents:triggerEvent(1, "joyriders")
    assertEquals(incident.data.isOwnField, true)
    assertEquals(table.concat(world.painted, ","), "7")
    assertEquals(#world.jobs, 0, "no job on our own field")
    assertEquals(#world.messages, 1)
    assertEquals(world.messages[1].titleKey, "tc_joyriders_ownTitle")
    assertEquals(world.messages[1].args[1], 7, "the field")
end)

test("a field that's stopped being grass by the time the stage runs is left alone", function()
    local world, tc = setup()
    local field = world:addField({ id = 9 })
    field.fieldState.fruitTypeIndex = FruitType.WHEAT
    local result = tc.Joyriders:onDamage({ id = 1, farmId = 1, data = { fieldId = 9, isOwnField = false } })
    assertEquals(result, TheContractorRandomEvents.DONE)
    assertEquals(#world.painted, 0)
    assertEquals(#world.jobs, 0)
    assertEquals(#world.messages, 0)
end)

test("allocating a joyrider plow job leaves the field as it is, unless the grass has gone", function()
    local world, tc = setup()
    local field = world:addField({ id = 12 })
    tc.RandomEvents:triggerEvent(1, "joyriders")
    local job = world.jobs[1]

    assertEquals(TCFieldPreparation.prepareFieldForJob(job), true)
    assertEquals(#world.fieldTasks, 0, "no field update: ruts and grass stay")

    -- Someone's cultivated it since: back to the usual stubble, so their
    -- work can't count as ours.
    field.fieldState.fruitTypeIndex = FruitType.UNKNOWN
    TCFieldPreparation.prepareFieldForJob(job)
    assertEquals(#world.fieldTasks, 1, "prepared as usual")

    -- An ordinary plow job is prepared as usual.
    field.fieldState.fruitTypeIndex = FruitType.GRASS
    local ordinary = tc.Jobs:createJob(1, "plow", 12, 3, 5, 1, 1000)
    TCFieldPreparation.prepareFieldForJob(ordinary)
    assertEquals(#world.fieldTasks, 2)
end)

test("finishing the plowing: half the time a grass sow job follows", function()
    local world, tc = setup()
    local field = world:addField({ id = 12, planned = FruitType.WHEAT })
    tc.RandomEvents:triggerEvent(1, "joyriders")
    local plowJob = world.jobs[1]
    world.messages = {}

    -- Over the chance: nothing.
    assertEquals(tc.Joyriders:onJobCompleted(plowJob, function() return 0.6 end), nil)
    assertEquals(#world.jobs, 1)
    assertEquals(field.plannedFruitTypeIndex, FruitType.WHEAT, "plan untouched")

    -- Under it: a sow job, with the field planned to grass.
    local sowJob = tc.Joyriders:onJobCompleted(plowJob, function() return 0.4 end)
    assertTrue(sowJob ~= nil)
    assertEquals(sowJob.jobType, "sow")
    assertEquals(sowJob.fieldId, 12)
    assertEquals(field.plannedFruitTypeIndex, FruitType.GRASS, "sows grass")
    assertEquals(sowJob.fruitTypeName, "GRASS", "the crop to sow is on the job, for clients to show")
    assertTrue(not sowJob.keepFieldState and not sowJob.followOnSow, "an ordinary sow job")
    assertEquals(#world.messages, 1)
    assertEquals(world.messages[1].titleKey, "tc_joyriders_sowTitle")
    assertEquals(world.messages[1].args[1], 12, "the field")
    assertEquals(world.messages[1].payload.jobId, sowJob.id)
end)

test("no follow-on sow job when grass can't be sown now, and the plan is put back", function()
    local world, tc = setup()
    local field = world:addField({ id = 12, planned = FruitType.WHEAT })
    tc.RandomEvents:triggerEvent(1, "joyriders")
    local plowJob = world.jobs[1]
    world.messages = {}

    world.noDeadline[TheContractorJobGeneration.JOB_TYPES.sow] = true
    assertEquals(tc.Joyriders:onJobCompleted(plowJob, function() return 0.1 end), nil)
    assertEquals(#world.jobs, 1, "no sow job")
    assertEquals(field.plannedFruitTypeIndex, FruitType.WHEAT, "plan put back")
    assertEquals(#world.messages, 0)

    -- An ordinary job never leads to one.
    local ordinary = tc.Jobs:createJob(1, "plow", 12, 3, 5, 1, 1000)
    world.noDeadline = {}
    assertEquals(tc.Joyriders:onJobCompleted(ordinary, function() return 0 end), nil)
end)

test("createJobOnField dates, prices and flags the job like an offer, without haulage", function()
    local world, tc = setup()
    local field = world:addField({ id = 3 })

    local job = tc.JobGeneration:createJobOnField(1, "plow", field)
    assertEquals(job.jobType, "plow")
    assertEquals(job.fieldId, 3)
    assertEquals(job.requiredSkillLevel, 3)
    assertEquals(job.deadlineDay, 42)
    assertEquals(job.targetPeriod, 5)
    assertEquals(job.targetDayInPeriod, 42 % 3 + 1)
    assertEquals(job.price, 5000)
    assertEquals(job.equipmentAvailable, true)
    assertEquals(job.includesHaulage, false)
    assertEquals(job.fruitTypeName, nil, "plow doesn't record a crop")

    field.plannedFruitTypeIndex = FruitType.UNKNOWN
    assertEquals(tc.JobGeneration:createJobOnField(1, "sow", field).fruitTypeName, nil, "sow with no plan has none")

    assertEquals(tc.JobGeneration:createJobOnField(1, "nonsense", field), nil)
    assertEquals(tc.JobGeneration:createJobOnField(1, "plow", nil), nil)
    world.noDeadline[TheContractorJobGeneration.JOB_TYPES.plow] = true
    assertEquals(tc.JobGeneration:createJobOnField(1, "plow", field), nil, "can't be dated")
end)

test("sameMonth keeps the deadline in the current month, unless it's too late in its last day", function()
    local world, tc = setup()
    local field = world:addField({ id = 3 })
    local environment = g_currentMission.environment
    environment.currentHour = 0
    local random = math.random
    math.random = function(low, high)
        return high -- the most slack
    end
    local plow = TheContractorJobGeneration.JOB_TYPES.plow
    local getDeadlineDay = TheContractorJobGeneration.getDeadlineDay

    -- Day 40 is the 2nd of 3 in its month: due by the 3rd (day 41), not day 42.
    assertEquals(getDeadlineDay(tc.JobGeneration, field, plow, false), 42)
    assertEquals(getDeadlineDay(tc.JobGeneration, field, plow, true), 41)

    -- On the month's last day it's due that day, with time left.
    environment.currentMonotonicDay = 41
    assertEquals(getDeadlineDay(tc.JobGeneration, field, plow, true), 41)
    -- Too late in that day, it's tomorrow (next month) at the earliest.
    environment.currentHour = 20
    assertEquals(getDeadlineDay(tc.JobGeneration, field, plow, true), 42)
    math.random = random
end)
