-- 080: the job quality score as a product of skill headroom, reliability,
-- morale, kit condition and form on the day, so 100 is rare; the
-- reputation reward following it (full only at 100, a loss below
-- REPUTATION_ZERO_QUALITY); and growth and job news rebalanced around it.
-- Real Jobs, Allocation, Morale and Staff's growth multiplier; workers and
-- the rest of completeJob faked.

local function setup()
    local world = stubs.install()
    TheContractor = { SaveKey = "TheContractor" }
    TheContractorWorker = { MAX_SKILL = 10 }
    FinanceStats = { statNames = {}, statNameToIndex = {} }
    MoneyType = { LAST_ID = 0, register = function(name) return name end }
    TCEquipmentClass = {
        getSizeTier = function()
            return nil
        end,
    }
    world:load("src/business/Allocation.lua")
    world:load("src/business/Job.lua")
    world:load("src/business/Jobs.lua")
    world:load("src/business/JobGeneration.lua")
    world:load("src/business/Morale.lua")

    world.workers = {}
    world.member = false
    local tc = g_currentMission.TheContractor
    tc.Allocation = TheContractorAllocation.new()
    tc.Jobs = TheContractorJobs.new()
    tc.Staff = {
        getWorker = function(_, farmId, workerId)
            return world.workers[workerId]
        end,
    }
    tc.Association = {
        getReputationBonus = function(_, farmId, reward)
            return world.member and math.max(1, math.floor(reward * 0.1 + 0.5)) or 0
        end,
    }
    -- A base reward of 20 for every job, whatever its field.
    TheContractorJobs.getBaseReputationReward = function()
        return 20
    end
    return world, tc
end

-- skills: operation skill -> rating. No tractor tier, so the operation
-- skill is the weakest rating.
local function addWorker(world, id, skills, morale)
    world.workers[id] = {
        id = id,
        morale = morale or 80,
        getSkill = function(_, skill)
            return skills[skill]
        end,
        getTierCapability = function()
            return nil
        end,
    }
    return id
end

-- def: { workerId, haulerId, required, stuck, damage, adsCondition }
local function makeJob(def)
    local job = {
        farmId = 1,
        jobType = "cultivate",
        requiredSkillLevel = def.required or 6,
        assignedWorkerId = def.workerId,
        haulerWorkerId = def.haulerId,
        assignedEquipmentIds = {},
        haulageEquipmentIds = {},
        stuckInterventions = def.stuck or 0,
        getOperationSkill = function()
            return "tillage"
        end,
    }
    if def.damage ~= nil or def.adsCondition ~= nil then
        job.startCondition = { [1] = { damage = def.damage or 0, wear = 0, adsCondition = def.adsCondition } }
    end
    return job
end

local function roll(value)
    return function()
        return value
    end
end

-- Factors -------------------------------------------------------------------

test("skill: headroom over the requirement, scaled down under it", function()
    setup()
    local f = TheContractorJobs.getSkillFactorFor
    assertNear(f(6, 6), 0.90, 1e-9, "at the level")
    assertNear(f(7, 6), 0.94, 1e-9, "one over")
    assertNear(f(8, 6), 0.97, 1e-9, "two over")
    assertNear(f(9, 6), 1.00, 1e-9, "three over")
    assertNear(f(10, 6), 1.00, 1e-9, "more than three over")
    assertNear(f(4, 6), 0.90 * (0.5 + 0.5 * 4 / 6), 1e-9, "two under")
    assertNear(f(3, 6), 0.675, 1e-9, "three under")
end)

test("reliability: each time it got stuck costs, down to a floor", function()
    setup()
    local f = TheContractorJobs.getReliabilityFactor
    assertNear(f(0), 1, 1e-9)
    assertNear(f(1), 0.85, 1e-9)
    assertNear(f(2), 0.70, 1e-9)
    assertNear(f(3), 0.55, 1e-9)
    assertNear(f(5), 0.55, 1e-9, "floored")
end)

test("morale: full from 70, a little less to 30, more below", function()
    setup()
    local f = TheContractorMorale.getQualityMultiplierFor
    assertNear(f(100), 1, 1e-9)
    assertNear(f(70), 1, 1e-9)
    assertNear(f(50), 0.98, 1e-9)
    assertNear(f(30), 0.96, 1e-9)
    assertNear(f(15), 0.93, 1e-9)
    assertNear(f(0), 0.90, 1e-9)
end)

test("morale: the crew's lowest counts, and a player-driven job is 1", function()
    local world = setup()
    addWorker(world, 1, {}, 90)
    addWorker(world, 2, {}, 50)
    assertNear(TheContractorMorale.getJobQualityMultiplier(makeJob({ workerId = 1, haulerId = 2 })), 0.98, 1e-9)
    assertNear(TheContractorMorale.getJobQualityMultiplier(makeJob({})), 1, 1e-9)
end)

test("condition: the worst start damage, after an allowance; ADS by its condition", function()
    setup()
    local f = TheContractorJobs.getConditionFactor
    assertNear(f(makeJob({})), 1, 1e-9, "no baseline")
    assertNear(f(makeJob({ damage = 0.1 })), 1, 1e-9, "within the allowance")
    assertNear(f(makeJob({ damage = 0.3 })), 1 - 0.1 * 0.2 / 0.9, 1e-9, "30% damaged")
    assertNear(f(makeJob({ damage = 1 })), 0.9, 1e-9, "wrecked")
    assertNear(f(makeJob({ damage = 0, adsCondition = 0.7 })), 1 - 0.1 * 0.2 / 0.9, 1e-9, "ADS at 70%")

    local job = makeJob({ damage = 0.05 })
    job.startCondition[2] = { damage = 0.55, wear = 0 }
    assertNear(f(job), 1 - 0.1 * 0.45 / 0.9, 1e-9, "the worst machine counts")
end)

test("form: 1 one time in six, else 0.90 to 1", function()
    setup()
    local f = TheContractorJobs.getFormFactor
    assertNear(f(0), 0.90, 1e-9)
    assertNear(f(0.5), 0.96, 1e-9)
    assertNear(f(5 / 6), 1, 1e-9, "the top sixth")
    assertNear(f(1), 1, 1e-9)
    assertTrue(f(5 / 6 - 0.01) < 1)
end)

-- The score -------------------------------------------------------------------

test("a perfect crew scores 100 only on a good day", function()
    local world, tc = setup()
    addWorker(world, 1, { tillage = 9 }, 80)
    local job = makeJob({ workerId = 1, damage = 0.05 })
    assertEquals(tc.Jobs:calculateQualityScore(job, roll(1)), 100)
    assertEquals(tc.Jobs:calculateQualityScore(job, roll(0)), 90)
end)

test("an ordinary qualified crew lands in the low-to-mid 80s", function()
    local world, tc = setup()
    addWorker(world, 1, { tillage = 6 }, 50)
    local job = makeJob({ workerId = 1, damage = 0.3 })
    assertEquals(tc.Jobs:calculateQualityScore(job, roll(1)), 86)
    assertEquals(tc.Jobs:calculateQualityScore(job, roll(0)), 77)

    job.stuckInterventions = 1
    assertEquals(tc.Jobs:calculateQualityScore(job, roll(1)), 73, "stuck once")
end)

test("100 needs every factor at its best: nearly isn't rounded up", function()
    local world, tc = setup()
    addWorker(world, 1, { tillage = 8 }, 80)
    assertEquals(tc.Jobs:calculateQualityScore(makeJob({ workerId = 1 }), roll(1)), 97, "two over, not three")

    addWorker(world, 2, { tillage = 9 }, 69)
    assertTrue(tc.Jobs:calculateQualityScore(makeJob({ workerId = 2 }), roll(1)) < 100, "morale under 70")
    addWorker(world, 3, { tillage = 9 }, 80)
    assertEquals(tc.Jobs:calculateQualityScore(makeJob({ workerId = 3 }), roll(1)), 100, "all at their best")
    assertTrue(tc.Jobs:calculateQualityScore(makeJob({ workerId = 3, damage = 0.2 }), roll(1)) < 100, "worn kit")
    assertTrue(tc.Jobs:calculateQualityScore(makeJob({ workerId = 3, stuck = 1 }), roll(1)) < 100, "stuck")
    assertTrue(tc.Jobs:calculateQualityScore(makeJob({ workerId = 3 }), roll(0.8)) < 100, "an off day")
end)

test("a player-driven job always scores 100", function()
    local _, tc = setup()
    assertEquals(tc.Jobs:calculateQualityScore(makeJob({ stuck = 3, damage = 1 }), roll(0)), 100)
end)

test("a haulage crew blends both workers' skill", function()
    local world, tc = setup()
    addWorker(world, 1, { tillage = 9 }, 80)
    addWorker(world, 2, { haulage = 6 }, 80)
    local job = makeJob({ workerId = 1, haulerId = 2 })
    local weight = TheContractorJobs.OPERATOR_SCORE_WEIGHT
    assertNear(tc.Jobs:getCrewSkillFactor(job), weight + (1 - weight) * 0.9, 1e-9)
    assertEquals(tc.Jobs:calculateQualityScore(job, roll(1)), 96)
end)

-- Reputation ----------------------------------------------------------------

test("the reputation share: full at 100, none at 50, a loss below", function()
    setup()
    local f = TheContractorJobs.getQualityReputationFactor
    assertNear(f(100), 1, 1e-9)
    assertNear(f(83), 0.66, 1e-9)
    assertNear(f(50), 0, 1e-9)
    assertNear(f(40), -0.2, 1e-9)
    assertNear(f(0), -1, 1e-9, "never as bad as a missed job")
    assertTrue(-f(0) < TheContractorJobs.MISSED_JOB_PENALTY_MULTIPLIER)
end)

test("the reward follows quality, with the minimum and the association bonus only when it's positive", function()
    local world, tc = setup()
    local function reward(quality)
        return tc.Jobs:calculateReputationReward({ farmId = 1, qualityScore = quality })
    end
    assertEquals(reward(100), 20, "full")
    assertEquals(reward(83), 13, "an ordinary crew")
    assertEquals(reward(51), 1, "the minimum")
    assertEquals(reward(50), 0, "nothing")
    assertEquals(reward(49), 0, "a hair under rounds to nothing")
    assertEquals(reward(44), -2, "a loss")
    assertEquals(reward(nil), 20, "no score counts as 100")

    world.member = true
    assertEquals(reward(100), 22, "member's bonus")
    assertEquals(reward(44), -2, "no bonus on a loss")
end)

test("completeJob scores quality before the reward, so a poor job loses reputation", function()
    local world, tc = setup()
    local changes = {}
    tc.Finances = { invoiceJob = function() end }
    tc.Reputation = {
        addReputation = function(_, farmId, delta)
            table.insert(changes, delta)
        end,
    }
    tc.Claims = { rollForJob = function() end }
    tc.Inbox = { removeMessagesForJob = function() end }
    tc.Dispatch = { stopJob = function() end }
    tc.Cooldown = { startCooldown = function() end }
    tc.Logbook = { recordJobCompleted = function() end }
    tc.Staff.applyGrowthFromJob = function() end
    tc.RandomEvents = { onJobCompleted = function() end }
    TCJobConsequences = { applyOnCompletion = function() end }
    TCJobProgress = { clearJob = function() end }
    TCHaulage = { stopDelivery = function() end, emptyHarvestersAfterJob = function() end }
    TCFieldPreparation = { clearUpAfterJob = function() end }
    TCJobCompletedEvent = { showNotification = function() end }
    AIMessageSuccessFinishedJob = { new = function() return {} end }
    TheContractorNegotiation = { rollInitialEagerness = function() return 1 end }
    g_currentMission.environment = { currentMonotonicDay = 10, dayTime = 0 }
    tc.Jobs.calculateQualityScore = function()
        return 44
    end

    local job = TheContractorJob.new(1, 1, "cultivate", 7, 1, 1, 1, 1000)
    job.state = TheContractorJob.STATE.IN_PROGRESS
    job.assignedWorkerId = 3
    job.completionPercentage = 100
    tc.Jobs:registerJob(job, false)

    tc.Jobs:completeJob(job)
    assertEquals(job.qualityScore, 44)
    assertEquals(changes[1], -2)
end)

-- Knock-on --------------------------------------------------------------------

test("growth: an ordinary job grows at the base rate, capped above", function()
    setup()
    Enterable = {}
    Environment = { PERIODS_IN_YEAR = 12 }
    dofile("src/util/TCCalendar.lua")
    dofile("src/util/TCWorkerAppearance.lua")
    dofile("src/business/Worker.lua")
    dofile("src/business/Staff.lua")
    local f = TheContractorStaff.getGrowthQualityMultiplier
    assertNear(f(85), 1, 1e-9)
    assertNear(f(69), 0.69 / 0.85, 1e-9)
    assertNear(f(100), TheContractorStaff.GROWTH_QUALITY_MAX, 1e-9, "capped")
end)

test("job news needs 85 or better", function()
    local world = setup()
    world.texts.ui_on = "On"
    world.texts.ui_off = "Off"
    dofile("src/util/TCConsole.lua")
    dofile("src/business/Settings.lua")
    dofile("src/business/RandomEvents.lua")
    dofile("src/business/GoodNews.lua")
    dofile("src/business/JobNews.lua")
    local definition = { minJobQuality = TheContractorJobNews.MIN_JOB_QUALITY }
    assertTrue(not TheContractorRandomEvents.meetsJobQuality(definition, { qualityScore = 84 }))
    assertTrue(TheContractorRandomEvents.meetsJobQuality(definition, { qualityScore = 85 }))
end)
