-- 081: spray drift complaints on the real random events framework (068) and
-- real Claims (052): the drift odds from crop care and wind, which jobs can
-- have one, the neighbouring field, cleared and upheld findings (insured or
-- not) and the logbook merge shared with 079. The rest of the mod is faked.

local function setup()
    local world = stubs.install()
    TheContractor = { SaveKey = "TheContractor" }
    world.texts.ui_on = "On"
    world.texts.ui_off = "Off"
    for month = 1, 12 do
        world.texts["ui_month" .. month] = "Month " .. month
    end

    world.wind = 0
    Environment = { PERIODS_IN_YEAR = 12 }
    g_currentMission.environment = {
        currentYear = 1,
        currentPeriod = 1,
        currentDayInPeriod = 1,
        daysPerPeriod = 10,
        plannedDaysPerPeriod = 10,
        currentMonotonicDay = 1,
        weather = {
            windUpdater = {
                getCurrentValues = function()
                    return 1, 0, world.wind, 1
                end,
            },
        },
    }
    g_farmManager.getFarmById = function(_, farmId)
        return { farmId = farmId }
    end
    FinanceStats = { statNames = {}, statNameToIndex = {} }
    MoneyType = { LAST_ID = 0, register = function(name) return name end }

    world.money = {}
    g_currentMission.addMoney = function(_, amount, farmId, moneyType)
        table.insert(world.money, { amount = amount, farmId = farmId, moneyType = moneyType })
    end

    -- Fields: { id, owner, x, z }.
    FarmlandManager = { NO_OWNER_FARM_ID = 0 }
    world.fields = {}
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
    }
    function world:addField(id, owner, x, z)
        local field = { id = id, owner = owner, x = x, z = z }
        function field:getId() return self.id end
        function field:getOwner() return self.owner end
        function field:getCenterOfFieldWorldPosition() return self.x, self.z end
        table.insert(self.fields, field)
        return field
    end

    TheContractorWorker = { MAX_SKILL = 10 }
    TheContractorTraining = { CERTIFICATIONS = { spraying = { skill = "cropCare", readySkill = 4 } } }
    TheContractorJobs = {
        getBaseReputationReward = function(job)
            return job.baseReputation or 20
        end,
    }
    TCClaimRecordedEvent = { new = function() return {} end }
    TCRandomEventIncidentEvent = { new = function() return {} end }

    world:load("src/util/TCCalendar.lua")
    world:load("src/util/TCConsole.lua")
    world:load("src/business/Settings.lua")
    world:load("src/business/RandomEvents.lua")
    world:load("src/business/Claims.lua")
    world:load("src/business/SprayDrift.lua")

    world.workers, world.messages, world.notices, world.removedNotices = {}, {}, {}, {}
    world.reputation, world.morale, world.logClaims = {}, {}, {}
    world.insured = false
    world.recorded = { claims = 0 }

    local tc = g_currentMission.TheContractor
    tc.Settings = TheContractorSettings.new()
    tc.Company = { companyNames = { [1] = "Test Contracting" } }
    tc.Staff = {
        getWorker = function(_, farmId, workerId)
            return world.workers[workerId]
        end,
    }
    tc.Allocation = {
        getWorkerJobRatings = function(_, worker, job, equipmentIds, isHauler)
            return { operationRating = worker.cropCare }
        end,
    }
    tc.Overheads = {
        isActive = function(_, farmId, key)
            return key == TheContractorClaims.OVERHEAD_KEY and world.insured
        end,
    }
    tc.Finances = {
        recordClaims = function(_, farmId, amount)
            world.recorded.claims = world.recorded.claims + amount
        end,
    }
    tc.Reputation = {
        addReputation = function(_, farmId, delta)
            table.insert(world.reputation, delta)
        end,
    }
    tc.Morale = {
        adjust = function(_, farmId, workers, delta)
            for _, worker in ipairs(workers) do
                table.insert(world.morale, { workerId = worker.id, delta = delta })
            end
        end,
    }
    tc.Logbook = {
        getJobEntry = function(_, farmId, jobId)
            return world.logEntry
        end,
        recordClaim = function(_, farmId, jobId, claim)
            table.insert(world.logClaims, { jobId = jobId, claim = claim })
        end,
    }
    tc.Inbox = {
        registerMessageKind = function() end,
        postMessage = function(_, farmId, kind, titleKey, bodyKey, args)
            -- Rendered as the client would, so a broken text fails here.
            local resolved = {}
            for i, arg in ipairs(args) do
                if type(arg) == "string" and string.sub(arg, 1, 7) == "$money_" then
                    resolved[i] = g_i18n:formatMoney(tonumber(string.sub(arg, 8)), 0, true, true)
                elseif type(arg) == "string" and string.sub(arg, 1, 6) == "$l10n_" then
                    resolved[i] = g_i18n:getText(string.sub(arg, 7))
                else
                    resolved[i] = arg
                end
            end
            table.insert(world.messages, {
                kind = kind,
                titleKey = titleKey,
                bodyKey = bodyKey,
                title = string.format(g_i18n:getText(titleKey), unpack(resolved)),
                body = string.format(g_i18n:getText(bodyKey), unpack(resolved)),
            })
            return #world.messages
        end,
    }
    tc.Notices = {
        publish = function(_, farmId, text)
            table.insert(world.notices, text)
            return #world.notices
        end,
        remove = function(_, noticeId)
            table.insert(world.removedNotices, noticeId)
        end,
    }
    tc.Claims = TheContractorClaims.new()
    tc.RandomEvents = TheContractorRandomEvents.new()
    tc.SprayDrift = TheContractorSprayDrift.new()
    tc.SprayDrift:register(tc.RandomEvents, tc.Inbox)

    function world:addWorker(id, cropCare)
        self.workers[id] = { id = id, name = "Worker " .. id, cropCare = cropCare }
        return id
    end

    function world:addJob(def)
        return {
            id = def.id or 1,
            farmId = 1,
            jobType = def.jobType or "herbicide",
            fieldId = def.fieldId or 12,
            assignedWorkerId = def.workerId,
            assignedEquipmentIds = {},
            baseReputation = def.baseReputation,
        }
    end

    function world:nextDay()
        local environment = g_currentMission.environment
        environment.currentMonotonicDay = environment.currentMonotonicDay + 1
        tc.RandomEvents:advanceDueIncidents()
    end

    function world:runUntilClosed()
        for _ = 1, 80 do
            if next(tc.RandomEvents.incidents) == nil then
                return
            end
            self:nextDay()
        end
        error("incident never closed")
    end

    return world, tc
end

-- A fixed sequence of rolls for rollComplaint, in its order: upheld,
-- complainant, claim. random(low, high) (picking among the framework's
-- hits) gives low.
local function rolls(values)
    local i = 0
    return function(low)
        if low ~= nil then
            return low
        end
        i = i + 1
        return values[i] or 0.5
    end
end

local function herbicideJob(world, def)
    def = def or {}
    world:addWorker(1, def.cropCare or 7)
    world:addField(12, 0, 0, 0)
    return world:addJob({ workerId = 1, baseReputation = def.baseReputation })
end

-- The odds -------------------------------------------------------------------------

test("drift chance: crop care and wind, the wind far worse for a poor operator, capped", function()
    setup()
    local d = TheContractorSprayDrift.getDriftChance
    assertNear(d(10, 0), 0.01, 1e-9)
    assertNear(d(10, 0.5), 0.06, 1e-9)
    assertNear(d(10, 1), 0.11, 1e-9)
    assertNear(d(7, 0), 0.06, 1e-9)
    assertNear(d(7, 1), 0.06 + 0.35, 1e-9)
    assertNear(d(4, 0), 0.11, 1e-9)
    assertNear(d(4, 0.5), 0.41, 1e-9)
    assertNear(d(4, 1), 0.71, 1e-9)
    assertNear(d(1, 1), 0.71, 1e-9, "below readySkill counts as readySkill")
    TheContractorSprayDrift.WIND_UNSKILLED = 5
    assertNear(d(4, 1), TheContractorSprayDrift.DRIFT_MAX, 1e-9, "capped")
end)

test("windiness runs from calm to strong; no weather reads as calm", function()
    setup()
    local w = TheContractorSprayDrift.getWindiness
    assertNear(w(0), 0, 1e-9)
    assertNear(w(2), 0, 1e-9)
    assertNear(w(4.5), 0.5, 1e-9)
    assertNear(w(12), 1, 1e-9)
    g_currentMission.environment.weather = nil
    assertEquals(TheContractorSprayDrift.getWindVelocity(), 0)
end)

test("a clean job still gets the odd unfounded complaint, never upheld more than it drifted", function()
    setup()
    local drift = TheContractorSprayDrift.getDriftChance(10, 0)
    local complaint = TheContractorSprayDrift.getComplaintChance(drift)
    assertNear(complaint, 0.01 + 0.99 * 0.02, 1e-9)
    assertNear(complaint * (drift / complaint), drift, 1e-9, "upheld overall is the drift chance")
end)

test("the framework rolls the job's own chance", function()
    local world, tc = setup()
    local job = herbicideJob(world, { cropCare = 4 })
    world.wind = 7
    local expected = TheContractorSprayDrift.getComplaintChance(0.71)
    assertNear(TheContractorRandomEvents.resolveJobChance(tc.RandomEvents:getEventType("sprayDrift"), 1, job),
        expected, 1e-9)
    assertTrue(tc.RandomEvents:onJobCompleted(job, rolls({ expected - 0.01 })) ~= nil, "under it: a complaint")
end)

-- Which jobs ------------------------------------------------------------------------

test("never for another job type, a player-sprayed job or one with a botch claim coming", function()
    local world, tc = setup()
    world:addWorker(1, 4)
    world.wind = 10
    local fertilize = world:addJob({ workerId = 1, jobType = "fertilize" })
    assertEquals(tc.SprayDrift:rollComplaint(1, fertilize, rolls({})), nil, "fertilize")
    assertEquals(tc.SprayDrift:getComplaintChanceForJob(1, fertilize), 0)
    assertEquals(tc.SprayDrift:rollComplaint(1, world:addJob({}), rolls({})), nil, "the player sprayed it")

    local job = world:addJob({ id = 7, workerId = 1 })
    table.insert(tc.Claims.pendingClaims, { jobId = 7 })
    assertEquals(tc.SprayDrift:rollComplaint(1, job, rolls({})), nil, "a botch claim's on its way")
    assertEquals(tc.SprayDrift:getComplaintChanceForJob(1, job), 0)
end)

test("the neighbouring field is the nearest NPC one, never ours or another player's", function()
    local world = setup()
    world:addField(12, 0, 0, 0)
    world:addField(13, 1, 10, 0)
    world:addField(14, 2, 20, 0)
    assertEquals(TheContractorSprayDrift.findNeighbourField(12), 0, "none")
    world:addField(15, 0, 100, 0)
    world:addField(16, 0, 50, 0)
    assertEquals(TheContractorSprayDrift.findNeighbourField(12), 16)
end)

-- Findings ---------------------------------------------------------------------------

test("cleared: the notice comes down, nothing else", function()
    local world, tc = setup()
    local job = herbicideJob(world, { cropCare = 10 })
    tc.SprayDrift.forcedUpheld = false
    local incident = tc.RandomEvents:triggerEvent(1, "sprayDrift", job)
    assertTrue(not incident.data.upheld)
    assertEquals(incident.stage, "findings")
    assertEquals(#world.notices, 1)
    assertTrue(string.find(world.messages[1].bodyKey, "_complaintBody$") ~= nil, "no neighbouring field")

    world:runUntilClosed()
    assertEquals(#world.money, 0)
    assertEquals(#world.reputation, 0)
    assertEquals(#world.morale, 0)
    assertEquals(#world.logClaims, 0)
    assertEquals(#world.removedNotices, 1)
    assertEquals(world.messages[2].bodyKey, "tc_sprayDrift_clearedBodyCalm")
end)

test("cleared on a breezy day says the wind was within limits", function()
    local world, tc = setup()
    local job = herbicideJob(world)
    world.wind = 5
    tc.SprayDrift.forcedUpheld = false
    tc.RandomEvents:triggerEvent(1, "sprayDrift", job)
    world:runUntilClosed()
    assertEquals(world.messages[2].bodyKey, "tc_sprayDrift_clearedBodyBreezy")
end)

test("upheld, insured: the excess, on the history and logbook, reputation and morale down", function()
    local world, tc = setup()
    world.insured = true
    local job = herbicideJob(world, { baseReputation = 12 })
    world:addField(16, 0, 50, 0)
    tc.SprayDrift.forcedUpheld = true
    local incident = tc.RandomEvents:triggerEvent(1, "sprayDrift", job)
    assertTrue(incident.data.upheld)
    assertEquals(incident.data.neighbourFieldId, 16)
    assertTrue(string.find(world.messages[1].bodyKey, "_complaintBodyField$") ~= nil)
    assertEquals(#world.money, 0, "nothing until the findings")

    world:runUntilClosed()
    local excess = tc.Settings:scaleCost(TheContractorClaims.EXCESS)
    assertEquals(world.money[1].amount, -math.min(excess, incident.data.claimAmount))
    assertEquals(world.money[1].moneyType, MoneyType.TC_CLAIMS)
    assertEquals(tc.Claims:getRecentClaimCount(1), 1)
    assertEquals(world.reputation[1], -12)
    assertEquals(world.morale[1].delta, TheContractorSprayDrift.MORALE_UPHELD)
    assertEquals(world.logClaims[1].claim.cause, "sprayDrift")
    assertEquals(world.messages[2].bodyKey, "tc_sprayDrift_upheldBodyInsured")
end)

test("upheld, uninsured: the whole claim, within the complainant's range", function()
    local world, tc = setup()
    local job = herbicideJob(world)
    -- rolls: upheld, organic grower, top of the range.
    local data = tc.SprayDrift:rollComplaint(1, job, rolls({ 0, 0.99, 1 }))
    assertTrue(data.upheld, "a roll of 0 is always upheld")
    assertEquals(data.complainant, "organicGrower")
    assertNear(data.claimAmount, tc.Settings:scaleCost(8000), 1e-6)

    tc.RandomEvents.eventTypes.sprayDrift.canTrigger = function()
        return data
    end
    tc.RandomEvents:triggerEvent(1, "sprayDrift", job)
    world:runUntilClosed()
    assertEquals(world.money[1].amount, -data.claimAmount)
    assertEquals(tc.Claims:getRecentClaimCount(1), 0)
    assertEquals(world.messages[2].bodyKey, "tc_sprayDrift_upheldBodyUninsured")
end)

test("a job with a claim in its logbook already gets the two added together", function()
    local world, tc = setup()
    local job = herbicideJob(world)
    world.logEntry = { claim = { cause = "roadAccident", amount = 9000, paid = 2500, insured = true,
        reputationPenalty = 10 } }
    tc.SprayDrift.forcedUpheld = true
    local incident = tc.RandomEvents:triggerEvent(1, "sprayDrift", job)
    world:runUntilClosed()
    local claim = world.logClaims[1].claim
    assertEquals(claim.cause, "roadAccident")
    assertEquals(claim.amount, 9000 + incident.data.claimAmount)
    assertEquals(claim.reputationPenalty, 10 + incident.data.reputationPenalty)
    assertTrue(not claim.insured)
end)

test("an operator who's left by the findings is skipped for morale", function()
    local world, tc = setup()
    local job = herbicideJob(world)
    tc.SprayDrift.forcedUpheld = true
    tc.RandomEvents:triggerEvent(1, "sprayDrift", job)
    world.workers[1] = nil
    world:runUntilClosed()
    assertEquals(#world.morale, 0)
    assertEquals(#world.money, 1, "the claim still came")
end)

test("every complainant's texts render", function()
    local world, tc = setup()
    local job = herbicideJob(world)
    world:addField(16, 0, 50, 0)
    for i, key in ipairs(TheContractorSprayDrift.COMPLAINANT_KEYS) do
        for _, withField in ipairs({ true, false }) do
            local data = tc.SprayDrift:rollComplaint(1, job, rolls({ 0, (i - 0.5) / 3 }))
            assertEquals(data.complainant, key)
            if not withField then
                data.neighbourFieldId = 0
            end
            tc.RandomEvents.eventTypes.sprayDrift.canTrigger = function()
                return data
            end
            tc.RandomEvents:triggerEvent(1, "sprayDrift", job)
            world:runUntilClosed()
        end
    end
    assertEquals(#world.messages, 12)
end)

test("the forced outcome applies once", function()
    local world, tc = setup()
    local job = herbicideJob(world, { cropCare = 10 })
    tc.SprayDrift.forcedUpheld = true
    assertTrue(tc.SprayDrift:rollComplaint(1, job, rolls({ 0.99 })).upheld)
    assertTrue(not tc.SprayDrift:rollComplaint(1, job, rolls({ 0.99 })).upheld, "back to the roll")
end)
