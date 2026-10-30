-- Job news (074) on the real random events framework (068): the kettle
-- (morale for the job's workers), paid before you've asked (the job's
-- outstanding invoice paid now) and a worker stepping up (a free point on
-- their weakest rating, and morale). Each only after good work, and only
-- with something to act on. Real Finances, Staff and Worker; faked Jobs,
-- Allocation, Morale and Inbox.

local function setup()
    local world = stubs.install()
    TheContractor = { SaveKey = "TheContractor" }
    world.texts.ui_on = "On"
    world.texts.ui_off = "Off"
    for month = 1, 12 do
        world.texts["ui_month" .. month] = "Month " .. month
    end

    Environment = { PERIODS_IN_YEAR = 12 }
    Enterable = {}
    g_currentMission.environment = {
        currentYear = 1,
        currentPeriod = 5,
        currentDayInPeriod = 1,
        daysPerPeriod = 3,
        plannedDaysPerPeriod = 3,
        currentMonotonicDay = 40,
        getPeriodFromDay = function()
            return 5
        end,
    }
    FinanceStats = { statNames = {}, statNameToIndex = {} }
    MoneyType = { LAST_ID = 0, TC_JOB_PAYOUT = "tcJobPayout", register = function(name) return name end }
    TheContractorJob = { STATE = { COMPLETED = "completed" } }

    world:load("src/util/TCCalendar.lua")
    world:load("src/util/TCConsole.lua")
    world:load("src/business/Settings.lua")
    world:load("src/business/RandomEvents.lua")
    world:load("src/business/Finances.lua")
    world:load("src/util/TCWorkerAppearance.lua")
    world:load("src/business/Worker.lua")
    world:load("src/business/Staff.lua")
    world:load("src/business/GoodNews.lua")
    world:load("src/business/JobNews.lua")

    TCRandomEventIncidentEvent = {
        new = function(incident, isClosed)
            return { incident = incident, isClosed = isClosed }
        end,
    }
    TCInvoiceStatusChangedEvent = { new = function() return {} end }
    TCFinanceYearStatsEvent = { new = function() return {} end }
    world.grown = {}
    TCWorkerGrewEvent = {
        new = function() return {} end,
        showNotification = function(worker, stat, oldValue, value)
            table.insert(world.grown, { workerId = worker.id, stat = stat, oldValue = oldValue, value = value })
        end,
    }
    g_server = { broadcastEvent = function() end }

    local tc = g_currentMission.TheContractor
    tc.Settings = TheContractorSettings.new()
    tc.Company = { companyNames = { [1] = "Test Contracting" } }
    tc.Finances = TheContractorFinances.new()
    tc.Staff = setmetatable({ workersByFarm = {}, candidatePool = {} }, TheContractorStaff_mt)

    world.jobs = {}
    tc.Jobs = {
        getJob = function(_, farmId, jobId)
            for _, job in ipairs(world.jobs) do
                if job.farmId == farmId and job.id == jobId then
                    return job
                end
            end
            return nil
        end,
        getJobsByState = function(_, farmId, state)
            local result = {}
            for _, job in ipairs(world.jobs) do
                if job.farmId == farmId and job.state == state then
                    table.insert(result, job)
                end
            end
            return result
        end,
    }

    -- The tier a job's machines need is its first "equipment id" here.
    tc.Allocation = {
        getWorkerJobRatings = function(_, worker, job, equipmentIds, isHauler)
            local tier = equipmentIds[1]
            local skill = isHauler and "haulage" or job.skill
            return {
                tractorTier = tier,
                tractorRating = tier ~= nil and worker:getTierCapability(tier) or nil,
                operationSkill = skill,
                operationRating = skill ~= nil and worker:getSkill(skill) or nil,
            }
        end,
    }

    world.morale = {}
    tc.Morale = {
        adjust = function(_, farmId, workers, delta)
            for _, worker in ipairs(workers) do
                table.insert(world.morale, { workerId = worker.id, delta = delta })
            end
        end,
    }

    world.money = {}
    g_currentMission.addMoney = function(_, amount, farmId, moneyType)
        table.insert(world.money, { amount = amount, farmId = farmId, moneyType = moneyType })
    end

    world.messages = {}
    tc.Inbox = {
        registerMessageKind = function() end,
        postMessage = function(_, farmId, kind, titleKey, bodyKey, args)
            -- Rendered as the client would, so a broken text fails here.
            local resolved = {}
            for i, arg in ipairs(args) do
                if type(arg) == "string" and string.sub(arg, 1, 6) == "$l10n_" then
                    resolved[i] = g_i18n:getText(string.sub(arg, 7))
                elseif type(arg) == "string" and string.sub(arg, 1, 7) == "$money_" then
                    resolved[i] = string.sub(arg, 8)
                else
                    resolved[i] = arg
                end
            end
            table.insert(world.messages, { farmId = farmId, kind = kind, titleKey = titleKey, bodyKey = bodyKey,
                args = args, title = g_i18n:getText(titleKey),
                body = string.format(g_i18n:getText(bodyKey), unpack(resolved)) })
            return #world.messages
        end,
    }

    tc.RandomEvents = TheContractorRandomEvents.new()
    tc.JobNews = TheContractorJobNews.new()
    tc.JobNews:register(tc.RandomEvents)

    -- def: { id, fieldId, quality, workerId, tier, skill, haulerId, haulerTier }
    function world:addJob(def)
        local job = {
            id = def.id or (#self.jobs + 1),
            farmId = 1,
            fieldId = def.fieldId or 12,
            state = "completed",
            qualityScore = def.quality or 90,
            completedAt = def.completedAt or (#self.jobs + 1),
            assignedWorkerId = def.workerId,
            assignedEquipmentIds = { def.tier },
            haulerWorkerId = def.haulerId,
            haulageEquipmentIds = { def.haulerTier },
            skill = def.skill,
        }
        function job:getWorkerIds()
            local ids = {}
            table.insert(ids, self.assignedWorkerId)
            table.insert(ids, self.haulerWorkerId)
            return ids
        end
        table.insert(self.jobs, job)
        return job
    end

    function world:addWorker(id, name, tiers, skills)
        local worker = TheContractorWorker.new(id, 1, name, 5, tiers or { small = 6 }, 30000, 30, 0, nil, nil,
            skills or {})
        tc.Staff.workersByFarm[1] = tc.Staff.workersByFarm[1] or {}
        tc.Staff.workersByFarm[1][id] = worker
        return worker
    end

    function world:addInvoice(jobId, status, amount)
        local invoice = { id = tc.Finances.nextInvoiceId, farmId = 1, jobId = jobId, amount = amount or 5000,
            issuedDay = 40, dueDay = 46, status = status or TheContractorFinances.STATUS.OUTSTANDING,
            isBadDebt = true, isLate = false }
        tc.Finances:applyInvoiceIssued(invoice)
        return invoice
    end

    return world, tc
end

-- Rolls every job event at chance, picks the first that hit.
local function always(low)
    return low or 0
end

local function force(tc, key, job)
    return tc.RandomEvents:triggerEvent(1, key, job)
end

test("three job events, each with its odds, the quality floor and a texts set", function()
    local world, tc = setup()
    for _, key in ipairs({ "kettle", "paidEarly", "stepsUp" }) do
        local definition = tc.RandomEvents:getEventType(key)
        assertTrue(definition ~= nil, key)
        assertTrue(definition.chancePerJob > 0, key .. " chance")
        assertEquals(definition.ratePerPeriod, nil, key .. " never in the daily roll")
        assertEquals(definition.minJobQuality, 85, key .. " quality")
        assertTrue(world.texts["tc_jobNews_" .. key .. "_eventName"] ~= nil, key .. " name")
        assertTrue(world.texts["tc_jobNews_" .. key .. "_title"] ~= nil, key .. " title")
    end
end)

test("the kettle: morale for everyone on the job, named in the message", function()
    local world, tc = setup()
    world:addWorker(1, "Dave Smith")
    world:addWorker(2, "Sam Jones")
    local job = world:addJob({ workerId = 1, haulerId = 2, fieldId = 7 })

    assertTrue(force(tc, "kettle", job) ~= nil)
    assertEquals(#world.morale, 2)
    assertEquals(world.morale[1].delta, TheContractorJobNews.KETTLE_MORALE)
    assertEquals(world.morale[2].workerId, 2)
    assertEquals(world.messages[1].kind, "goodNews")
    assertEquals(world.messages[1].bodyKey, "tc_jobNews_kettle_bodyTwo", "both named")
    assertEquals(table.concat(world.messages[1].args, "|"), "Dave Smith|Sam Jones|7")

    local solo = world:addJob({ workerId = 1 })
    force(tc, "kettle", solo)
    assertEquals(world.messages[2].bodyKey, "tc_jobNews_kettle_bodyOne", "the one worker")
    assertEquals(table.concat(world.messages[2].args, "|"), "Dave Smith|12")
end)

test("the kettle needs hired workers on the job", function()
    local world, tc = setup()
    local playerJob = world:addJob({})
    assertEquals(force(tc, "kettle", playerJob), nil)

    -- A worker who's left the roster since doesn't count.
    local gone = world:addJob({ workerId = 9 })
    assertEquals(force(tc, "kettle", gone), nil)
    assertEquals(#world.messages, 0)
end)

test("paid before you've asked: the job's outstanding invoice is paid now", function()
    local world, tc = setup()
    local job = world:addJob({ fieldId = 3 })
    local invoice = world:addInvoice(job.id, nil, 4200)

    assertTrue(force(tc, "paidEarly", job) ~= nil)
    assertEquals(invoice.status, TheContractorFinances.STATUS.PAID, "paid, bad debt or not")
    assertEquals(invoice.settledDay, 40)
    assertEquals(#world.money, 1)
    assertEquals(world.money[1].amount, 4200)
    assertEquals(world.money[1].moneyType, "tcJobPayout")
    assertEquals(tc.Finances:getYearStats(1).received, 4200)
    assertEquals(world.messages[1].titleKey, "tc_jobNews_paidEarly_title")
    assertEquals(world.messages[1].args[1], 3, "the job's field")
    assertEquals(world.messages[1].args[2], "$money_4200", "what was paid")
end)

test("paid before you've asked needs an invoice that isn't due yet", function()
    local world, tc = setup()
    -- lateInvoices off: no invoice kept.
    assertEquals(force(tc, "paidEarly", world:addJob({})), nil)
    local overdue = world:addJob({})
    world:addInvoice(overdue.id, TheContractorFinances.STATUS.OVERDUE)
    assertEquals(force(tc, "paidEarly", overdue), nil, "overdue isn't before you've asked")
    local paid = world:addJob({})
    world:addInvoice(paid.id, TheContractorFinances.STATUS.PAID)
    assertEquals(force(tc, "paidEarly", paid), nil, "already paid")
    assertEquals(#world.money, 0)
end)

test("a worker steps up: a free point on their weakest rating, and morale", function()
    local world, tc = setup()
    local worker = world:addWorker(1, "Amy Hill", { small = 6 }, { tillage = 3 })
    worker.growthPotential = 0
    local job = world:addJob({ workerId = 1, tier = "small", skill = "tillage", fieldId = 4 })

    assertTrue(force(tc, "stepsUp", job) ~= nil)
    assertEquals(worker:getSkill("tillage"), 4, "tillage was the weaker")
    assertEquals(worker.growthPotential, 0, "outside their potential")
    assertEquals(world.grown[1].stat, "tillage")
    assertEquals(world.morale[1].delta, TheContractorJobNews.STEPS_UP_MORALE)
    assertEquals(world.messages[1].titleKey, "tc_jobNews_stepsUp_title")
    assertEquals(table.concat(world.messages[1].args, "|"), "Amy Hill|4|$l10n_tc_growth_stat_tillage|4",
        "who, where, what and to what")
end)

test("the least experienced worker steps up, and only if they're inexperienced", function()
    local world, tc = setup()
    world:addWorker(1, "Operator", { medium = 5 }, { harvesting = 5 })
    local hauler = world:addWorker(2, "Hauler", { small = 2 }, { haulage = 4 })
    local job = world:addJob({ workerId = 1, tier = "medium", skill = "harvesting", haulerId = 2,
        haulerTier = "small" })

    local picked, stat = TheContractorJobNews.pickSteppingUp(job)
    assertEquals(picked, hauler, "the hauler's 2 is lower than the operator's 5")
    assertEquals(stat, "small", "a tier counts")
    force(tc, "stepsUp", job)
    assertEquals(hauler:getTierCapability("small"), 3)

    local veteran = world:addWorker(3, "Veteran", { large = 8 }, { tillage = 6 })
    assertEquals(force(tc, "stepsUp", world:addJob({ workerId = 3, tier = "large", skill = "tillage" })), nil,
        "6 is past STEPS_UP_MAX_RATING")
    assertEquals(veteran:getSkill("tillage"), 6)
    assertEquals(force(tc, "stepsUp", world:addJob({})), nil, "no workers")
end)

test("an uncertified tier isn't raised: their skill is", function()
    local world, tc = setup()
    local worker = world:addWorker(1, "New Starter", { small = 4 }, { seeding = 5 })
    local job = world:addJob({ workerId = 1, tier = "medium", skill = "seeding" })
    local _, stat = TheContractorJobNews.pickSteppingUp(job)
    assertEquals(stat, "seeding")
    force(tc, "stepsUp", job)
    assertEquals(worker:getTierCapability("medium"), nil)
    assertEquals(worker:getSkill("seeding"), 6)
end)

test("on completion: good work only, one event at most, then cooldowns", function()
    local world, tc = setup()
    world:addWorker(1, "Dave Smith", { small = 3 }, { tillage = 3 })
    local poor = world:addJob({ workerId = 1, tier = "small", skill = "tillage", quality = 84 })
    world:addInvoice(poor.id)
    assertEquals(tc.RandomEvents:onJobCompleted(poor, always), nil, "84% quality")

    local good = world:addJob({ workerId = 1, tier = "small", skill = "tillage", quality = 85 })
    world:addInvoice(good.id)
    local incident = tc.RandomEvents:onJobCompleted(good, always)
    assertEquals(incident.eventType, "kettle", "the first registered, picked by the fake random")
    assertEquals(#world.messages, 1, "only one")

    local next = world:addJob({ workerId = 1, tier = "small", skill = "tillage", quality = 95 })
    world:addInvoice(next.id)
    assertEquals(tc.RandomEvents:onJobCompleted(next, always).eventType, "paidEarly", "kettle cooling down")
    assertEquals(tc.RandomEvents:getCooldownLeft(1, "kettle"), TheContractorJobNews.KETTLE_COOLDOWN_PERIODS)
end)

test("tcCompany event kettle uses the latest completed job with workers", function()
    local world, tc = setup()
    world:addWorker(1, "Dave Smith")
    world:addJob({ workerId = 1, fieldId = 5, completedAt = 10 })
    world:addJob({ fieldId = 6, completedAt = 30 })
    world:addJob({ workerId = 1, fieldId = 8, completedAt = 20 })
    assertTrue(force(tc, "kettle") ~= nil)
    assertEquals(world.messages[1].args[2], 8, "the latest job's field")
end)
