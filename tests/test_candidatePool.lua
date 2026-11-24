-- 174: the candidate pool turns over by the month, not the day, so a short
-- month brings as many new faces as a long one.
-- 175: the farmingScale setting picks the local labour market: large-scale
-- arable country has more (and better) large-tractor drivers, who cost more.

local function setup(farmingScale)
    local world = stubs.install()
    TheContractor = { SaveKey = "TheContractor" }
    world.texts.ui_on = "On"
    world.texts.ui_off = "Off"
    FinanceStats = { statNames = {}, statNameToIndex = {} }
    Environment = { PERIODS_IN_YEAR = 12 }
    TCWorkerAppearance = { GENDER = { MALE = "male", FEMALE = "female" } }
    world:load("src/business/Settings.lua")
    world:load("src/business/Worker.lua")
    world:load("src/business/Staff.lua")

    local settings = TheContractorSettings.new()
    if farmingScale ~= nil then
        settings:set("farmingScale", farmingScale)
    end
    g_currentMission.TheContractor = { Settings = settings }
    return world, settings
end

-- A Staff whose pool only counts: the turnover is what's under test, not
-- rolling a candidate.
local function countingStaff()
    local staff = { candidatePool = {}, nextId = 1, arrivals = 0 }
    setmetatable(staff, { __index = TheContractorStaff })
    function staff:addCandidateToPool()
        local count = 0
        for _ in pairs(self.candidatePool) do
            count = count + 1
        end
        if count >= TheContractorStaff.POOL_MAX_SIZE then
            return nil
        end
        self.candidatePool[self.nextId] = {}
        self.nextId = self.nextId + 1
        self.arrivals = self.arrivals + 1
        return true
    end
    function staff:removeCandidateFromPool(id)
        self.candidatePool[id] = nil
    end
    return staff
end

local function poolSize(staff)
    local count = 0
    for _ in pairs(staff.candidatePool) do
        count = count + 1
    end
    return count
end

-- Average pool size seen through each day, and newcomers per month.
local function simulate(daysPerPeriod, months)
    local staff = countingStaff()
    for _ = 1, TheContractorStaff.INITIAL_POOL_SIZE do
        staff:addCandidateToPool()
    end
    staff.arrivals = 0
    local total = 0
    local days = months * daysPerPeriod
    for _ = 1, days do
        staff:updateCandidatePool(daysPerPeriod)
        total = total + poolSize(staff)
    end
    return total / days, staff.arrivals / months
end

test("a month's arrivals and leaving odds are the same at any month length", function()
    setup()
    local S = TheContractorStaff
    for _, days in ipairs({ 1, 2, 3, 7, 15, 28 }) do
        local arrivals, leaveChance = S.getDailyPoolOdds(days)
        assertNear(arrivals * days, S.POOL_ARRIVALS_PER_MONTH, 0.0001, days .. " days: arrivals per month")
        assertNear((1 - leaveChance) ^ days, math.exp(-S.POOL_LEAVE_RATE), 0.0001, days .. " days: stay a month")
    end
end)

test("a 1-day month still brings a month's newcomers and keeps a decent pool", function()
    setup()
    local S = TheContractorStaff
    math.randomseed(21)
    for _, days in ipairs({ 1, 7, 28 }) do
        local averageSize, perMonth = simulate(days, 3000)
        assertTrue(averageSize >= 4.5 and averageSize <= S.POOL_MAX_SIZE, days .. " days: pool size " .. averageSize)
        -- The cap turns some away, more so in a 1-day month.
        assertTrue(perMonth >= 3 and perMonth <= S.POOL_ARRIVALS_PER_MONTH + 0.1,
            days .. " days: newcomers per month " .. perMonth)
    end
end)

test("the pool never goes over its cap, even when a day brings several", function()
    setup()
    math.randomseed(4)
    local staff = countingStaff()
    for _ = 1, 500 do
        staff:updateCandidatePool(1)
        assertTrue(poolSize(staff) <= TheContractorStaff.POOL_MAX_SIZE, "cap")
    end
end)

test("the farming scale setting defaults to mixed and Staff reads it", function()
    local _, settings = setup()
    assertEquals(settings:getFarmingScale(), "mixed", "default")
    assertEquals(TheContractorStaff.getFarmingScale(), "mixed", "Staff, default")
    settings:set("farmingScale", 3)
    assertEquals(TheContractorStaff.getFarmingScale(), "large", "Staff, large")
    settings:set("farmingScale", 1)
    assertEquals(TheContractorStaff.getFarmingScale(), "small", "Staff, small")
    g_currentMission.TheContractor = nil
    assertEquals(TheContractorStaff.getFarmingScale(), "mixed", "no settings")
end)

-- Shares of candidates (rolled through the real age and experience) with a
-- large rating at all and at 5 or more, and their median salary.
local function market(scale)
    local S = TheContractorStaff
    local rolls, anyLarge, goodLarge, salaries = 20000, 0, 0, {}
    for i = 1, rolls do
        local experience = S.getExperience(S.rollAge())
        local tiers = S.rollTierCapability(experience, scale)
        if tiers.large ~= nil then
            anyLarge = anyLarge + 1
            if tiers.large >= 5 then
                goodLarge = goodLarge + 1
            end
        end
        salaries[i] = S.getSalary(S.rollWorkSpeed(experience), tiers, S.rollSkills(experience))
    end
    table.sort(salaries)
    return anyLarge / rolls, goodLarge / rolls, salaries[math.floor(rolls / 2)]
end

test("large-scale country has more and better large-tractor drivers, who ask for more", function()
    setup()
    math.randomseed(9)
    local mixedAny, mixedGood, mixedPay = market("mixed")
    local largeAny, largeGood, largePay = market("large")
    local smallAny, smallGood, smallPay = market("small")
    TCLog.info("farming scale: mixed %.2f/%.2f %d, large %.2f/%.2f %d, small %.2f/%.2f %d",
        mixedAny, mixedGood, mixedPay, largeAny, largeGood, largePay, smallAny, smallGood, smallPay)
    assertTrue(largeAny > mixedAny * 1.5, "more large drivers")
    assertTrue(largeGood > mixedGood * 2, "more good large drivers")
    assertTrue(largePay > mixedPay, "large-scale pay")
    assertTrue(smallAny < mixedAny, "fewer large drivers in small-scale country")
    assertTrue(smallPay <= mixedPay, "small-scale pay")
end)

test("the ladder holds in large-scale country, and some school leavers have driven large", function()
    setup()
    local S = TheContractorStaff
    math.randomseed(13)
    local youngLarge = false
    for _ = 1, 3000 do
        local tiers = S.rollTierCapability(0, "large")
        youngLarge = youngLarge or tiers.large ~= nil
        tiers = S.rollTierCapability(1, "large")
        if tiers.large ~= nil then
            assertTrue(tiers.medium >= S.CERTIFY_THRESHOLD, "medium at the threshold below large")
            assertTrue(tiers.large <= tiers.medium, "large no better than medium")
        end
    end
    assertTrue(youngLarge, "a school leaver on large")
end)

test("the setting's choice is used when no scale is passed", function()
    setup(3)
    local S = TheContractorStaff
    math.randomseed(17)
    local youngLarge = false
    for _ = 1, 3000 do
        youngLarge = youngLarge or S.rollTierCapability(0).large ~= nil
    end
    assertTrue(youngLarge, "large-scale setting reaches the roll")
end)
