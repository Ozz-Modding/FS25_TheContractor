-- Growth gets harder as a stat goes up (GROWTH_LEVEL_MULTIPLIERS), the
-- basics come free of growthPotential (GROWTH_FREE_BELOW), and market value
-- pays ratings on a curve (SALARY_RATING_EXPONENT) so skill shows in pay.

local function setup()
    local world = stubs.install()
    FinanceStats = { statNames = {}, statNameToIndex = {} }
    Environment = { PERIODS_IN_YEAR = 12 }
    TCWorkerAppearance = { GENDER = { MALE = "male", FEMALE = "female" } }
    world:load("src/business/Worker.lua")
    world:load("src/business/Staff.lua")

    local staff = setmetatable({ workersByFarm = {} }, TheContractorStaff_mt)
    g_currentMission.TheContractor = { Staff = staff }

    world.grown = {}
    TCWorkerGrewEvent = {
        showNotification = function(worker, stat, oldValue, newValue)
            table.insert(world.grown, { stat = stat, oldValue = oldValue, newValue = newValue })
        end,
    }
    return world, staff
end

local function makeSkills(value)
    local skills = {}
    for _, skill in ipairs(TheContractorWorker.SKILLS) do
        skills[skill] = value
    end
    return skills
end

local function addWorker(staff, workSpeed, baling, potential)
    local skills = makeSkills(1)
    skills.baling = baling
    local worker = TheContractorWorker.new(1, 1, "John White", workSpeed, {}, 2000, 34, potential, 1, 0, skills, 5)
    staff.workersByFarm[1] = { [1] = worker }
    return worker
end

-- Average growth rolls (at `chance`) to take baling from `from` to from + 1.
local function rollsToGrow(staff, from, chance)
    local total, trials = 0, 2000
    for _ = 1, trials do
        local worker = addWorker(staff, 10, from, 10)
        local rolls = 0
        while worker:getSkill("baling") == from do
            rolls = rolls + 1
            staff:growWorker(1, worker.id, nil, "baling", chance)
        end
        total = total + rolls
    end
    return total / trials
end

test("growth chance falls as the stat rises, and is capped", function()
    setup()
    local previous = math.huge
    for value = 1, 9 do
        local chance = TheContractorStaff.getGrowthChance(0.3, value)
        assertTrue(chance <= previous, "no easier at " .. value)
        previous = chance
    end
    assertEquals(TheContractorStaff.getGrowthChance(0.3, 5), 0.3, "5 is the base rate")
    assertEquals(TheContractorStaff.getGrowthChance(0.6, 1), TheContractorStaff.GROWTH_MAX_CHANCE, "capped")
    assertEquals(TheContractorStaff.getGrowthChance(0.3, nil), 0.3, "a new certification is the base rate")
end)

test("a low skill moves up in a few jobs, a high one takes many", function()
    local _, staff = setup()
    math.randomseed(7)
    -- workSpeed 10 is maxed, so baling is the only stat that can grow.
    local chance = TheContractorStaff.GROWTH_BASE_CHANCE * TheContractorStaff.GROWTH_STRETCH_MULTIPLIER
    local low, high = rollsToGrow(staff, 1, chance), rollsToGrow(staff, 8, chance)
    assertTrue(low < 1.5, "1 -> 2 in about a job, took " .. low)
    assertTrue(high > 3 * low, "8 -> 9 several times slower, took " .. high)
end)

test("growing the basics spends no potential, and works with none left", function()
    local world, staff = setup()
    local worker = addWorker(staff, 10, 2, 0)
    staff:growWorker(1, worker.id, nil, "baling")
    assertEquals(worker:getSkill("baling"), 3, "2 -> 3 with no potential")
    assertEquals(worker.growthPotential, 0, "still none")

    staff:growWorker(1, worker.id, nil, "baling")
    assertEquals(worker:getSkill("baling"), 3, "3 needs potential")
    assertEquals(#world.grown, 1, "told once")

    worker = addWorker(staff, 10, 1, 4)
    staff:growWorker(1, worker.id, nil, "baling")
    assertEquals(worker.growthPotential, 4, "free with potential too")
    worker.skills.baling = 5
    staff:growWorker(1, worker.id, nil, "baling")
    assertEquals(worker.growthPotential, 3, "5 -> 6 spends a point")
end)

test("with no potential, only the free stats are picked", function()
    setup()
    local worker = TheContractorWorker.new(1, 1, "John White", 6, { small = 2 }, 2000, 60, 0, 1, 0, makeSkills(1), 5)
    worker.skills.baling = 7
    for _ = 1, 200 do
        local stat = TheContractorStaff.pickGrowth(worker, "small", 2, "baling", true)
        assertEquals(stat, "small", "only the tier at 2 is free")
    end
    worker.tierCapability.small = 3
    assertEquals(TheContractorStaff.pickGrowth(worker, "small", 3, "baling", true), nil, "nothing free")
end)

test("market value widens with skill", function()
    setup()
    local weakest = TheContractorStaff.getSalary(1, {}, makeSkills(1))
    local average = TheContractorStaff.getSalary(5, { small = 8, medium = 4 }, makeSkills(1))
    local best = TheContractorStaff.getSalary(10, { small = 10, medium = 10, large = 10 }, makeSkills(10))
    assertTrue(weakest > 1950 and weakest < 2100, "weakest about the living wage, got " .. weakest)
    assertTrue(best > 2 * weakest, "best over double the weakest, got " .. best)
    assertTrue(best - average > 2 * (average - weakest), "the top end costs most per point")
    -- 1950 + 5^2 x 8 + (8^2 + 4^2) x 4 + (1 + 1) x 4.5
    assertEquals(average, 2479, "the formula")
end)
