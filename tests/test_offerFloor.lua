-- The daily offer floor: a farm with no offer from the hourly roll by
-- 08:00-09:00 gets one forced then, so a new company doesn't go days
-- without work.

local function setup(chance)
    local world = stubs.install()
    TheContractor = { SaveKey = "TheContractor" }
    FinanceStats = { statNames = {}, statNameToIndex = {} }
    MoneyType = { LAST_ID = 0, register = function(name) return name end }
    world:load("src/business/JobGeneration.lua")

    g_currentMission.environment = { currentMonotonicDay = 10, daysPerPeriod = 3 }
    local generation = TheContractorJobGeneration.new()
    generation.getHourlyChance = function() return chance or 0 end
    generation.getOfferSource = function() return "reputation" end
    generation.offers = 0
    generation.canOffer = true
    generation.tryGenerateJob = function(self)
        if not self.canOffer then
            return nil
        end
        self.offers = self.offers + 1
        return { id = self.offers }
    end
    return world, generation
end

local function runHours(generation, firstHour, lastHour)
    for hour = firstHour, lastHour do
        generation:rollForFarm(1, hour)
    end
end

test("a day with no rolled offer gets one by 09:00", function()
    local _, generation = setup(0)
    runHours(generation, 0, 23)
    assertEquals(1, generation.offers)
end)

test("the floor offer can come at 08:00 or 09:00", function()
    local _, generation = setup(0)
    local at8, at9 = 0, 0
    for _ = 1, 200 do
        generation.lastOfferDayByFarm = {}
        generation.offers = 0
        generation:rollForFarm(1, 8)
        if generation.offers == 1 then
            at8 = at8 + 1
        else
            generation:rollForFarm(1, 9)
            assertEquals(1, generation.offers)
            at9 = at9 + 1
        end
    end
    assertTrue(at8 > 50 and at9 > 50, "at8 " .. at8 .. ", at9 " .. at9)
end)

test("a rolled offer earlier in the day means no floor offer", function()
    local _, generation = setup(1)
    runHours(generation, 3, 3)
    assertEquals(1, generation.offers)
    generation.getHourlyChance = function() return 0 end
    runHours(generation, 4, 23)
    assertEquals(1, generation.offers)
end)

test("yesterday's offer doesn't count for today", function()
    local _, generation = setup(0)
    runHours(generation, 0, 23)
    g_currentMission.environment.currentMonotonicDay = 11
    runHours(generation, 0, 23)
    assertEquals(2, generation.offers)
end)

test("no work to offer means no offer, and no retry after 09:00", function()
    local _, generation = setup(0)
    generation.canOffer = false
    runHours(generation, 0, 9)
    generation.canOffer = true
    runHours(generation, 10, 23)
    assertEquals(0, generation.offers)
end)
