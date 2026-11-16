-- 157: candidates' starting stats follow their age (experience), and ages
-- lean young, so the pool has young, cheap, unskilled people with room to
-- grow as well as older ones who are good now.

local function setup()
    local world = stubs.install()
    FinanceStats = { statNames = {}, statNameToIndex = {} }
    Environment = { PERIODS_IN_YEAR = 12 }
    TCWorkerAppearance = { GENDER = { MALE = "male", FEMALE = "female" } }
    world:load("src/business/Worker.lua")
    world:load("src/business/Staff.lua")
    return world
end

local function countAbove(skills, value)
    local count = 0
    for _, skill in ipairs(TheContractorWorker.SKILLS) do
        if skills[skill] > value then
            count = count + 1
        end
    end
    return count
end

local function median(values)
    table.sort(values)
    return values[math.floor(#values / 2) + 1]
end

test("experience runs from nothing at the youngest age to full at EXPERIENCE_FULL_AGE", function()
    setup()
    local S = TheContractorStaff
    assertEquals(S.getExperience(S.MIN_AGE), 0, "school leaver")
    assertEquals(S.getExperience(S.EXPERIENCE_FULL_AGE), 1, "full")
    assertEquals(S.getExperience(S.MAX_AGE), 1, "capped")
    local midAge = (S.MIN_AGE + S.EXPERIENCE_FULL_AGE) / 2
    assertNear(S.getExperience(midAge), 0.5, 0.001, "halfway")
    assertEquals(S.getExperience(nil), 1, "no age (an old save) is full")
end)

test("a school leaver rolls within the YOUNG_ limits", function()
    setup()
    local S = TheContractorStaff
    math.randomseed(7)
    local sawNoTier, sawNoSpecialism = false, false
    for _ = 1, 3000 do
        assertTrue(S.rollWorkSpeed(0) <= S.YOUNG_WORK_SPEED_MAX, "work speed")

        local caps = S.rollTierCapability(0)
        assertEquals(caps.large, nil, "never large")
        sawNoTier = sawNoTier or next(caps) == nil

        local skills = S.rollSkills(0)
        local specialisms = countAbove(skills, S.YOUNG_SKILL_BASE_MAX)
        assertTrue(specialisms <= S.YOUNG_SPECIALISMS_MAX, "specialism count")
        sawNoSpecialism = sawNoSpecialism or specialisms == 0
        for _, skill in ipairs(TheContractorWorker.SKILLS) do
            assertTrue(skills[skill] >= S.SKILL_BASE_MIN and skills[skill] <= S.YOUNG_SPECIALISM_MAX, "skill range")
        end
    end
    assertTrue(sawNoTier, "some have no tractor experience")
    assertTrue(sawNoSpecialism, "some have no specialism")
end)

test("full experience rolls the whole range, as before 157", function()
    setup()
    local S = TheContractorStaff
    math.randomseed(11)
    local topSpeed, sawLarge, topSkill = 0, false, 0
    for _ = 1, 3000 do
        topSpeed = math.max(topSpeed, S.rollWorkSpeed(1))
        sawLarge = sawLarge or S.rollTierCapability(1).large ~= nil

        local skills = S.rollSkills()
        local specialisms = countAbove(skills, S.SKILL_BASE_MAX)
        assertTrue(specialisms >= S.SPECIALISMS_MIN and specialisms <= S.SPECIALISMS_MAX, "specialism count")
        for _, skill in ipairs(TheContractorWorker.SKILLS) do
            topSkill = math.max(topSkill, skills[skill])
        end
    end
    assertEquals(topSpeed, TheContractorWorker.MAX_SKILL, "work speed reaches the top")
    assertTrue(sawLarge, "large tractors turn up")
    assertEquals(topSkill, S.SPECIALISM_MAX, "a specialism reaches the top")
end)

test("ages lean young but cover the whole range", function()
    setup()
    local S = TheContractorStaff
    math.randomseed(3)
    local ages, youngest, oldest, under25 = {}, math.huge, 0, 0
    local rolls = 5000
    for i = 1, rolls do
        ages[i] = S.rollAge()
        youngest = math.min(youngest, ages[i])
        oldest = math.max(oldest, ages[i])
        if ages[i] < 25 then
            under25 = under25 + 1
        end
    end
    assertEquals(youngest, S.MIN_AGE, "youngest")
    assertEquals(oldest, S.MAX_AGE, "oldest")
    assertTrue(median(ages) < (S.MIN_AGE + S.MAX_AGE) / 2, "median below the middle of the range")
    -- Uniform would give 7/43 (~16%) under 25.
    assertTrue(under25 / rolls > 0.25, "over a quarter under 25")
end)

test("young candidates ask for less than experienced ones", function()
    setup()
    local S = TheContractorStaff
    math.randomseed(5)
    local function salaries(experience)
        local list = {}
        for i = 1, 2000 do
            list[i] = S.getSalary(S.rollWorkSpeed(experience), S.rollTierCapability(experience),
                S.rollSkills(experience))
        end
        return list
    end
    local young, full = salaries(0), salaries(1)
    assertTrue(median(young) < median(full), "median")
    assertTrue(young[#young] < full[#full], "the best of them")
end)
