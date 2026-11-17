-- Advertising (012/027): campaigns stack, each on its own clock in months,
-- and an offer from the hourly roll says whether an advert brought it.

local function setup(standing)
    local world = stubs.install()
    TheContractor = { SaveKey = "TheContractor" }
    FinanceStats = { statNames = {}, statNameToIndex = {} }
    MoneyType = { LAST_ID = 0, register = function(name) return name end }
    -- Day 10 of 5-day months: month 1's last day.
    g_currentMission.environment = { currentDay = 10, daysPerPeriod = 5 }

    world.balance = 1000000
    g_farmManager.getFarmById = function(_, farmId)
        return { farmId = farmId, getBalance = function() return world.balance end }
    end
    world.money = {}
    g_currentMission.addMoney = function(_, amount, farmId, moneyType)
        world.balance = world.balance + amount
        table.insert(world.money, { amount = amount, farmId = farmId, moneyType = moneyType })
    end

    world:load("src/business/Advertising.lua")
    world:load("src/business/JobGeneration.lua")
    TheContractorReputation = { TIERS = { { key = "newcomer" }, { key = "localContractor" },
        { key = "establishedContractor" }, { key = "regionalContractor" } } }
    local advertising = TheContractorAdvertising.new()
    g_currentMission.TheContractor = {
        Advertising = advertising,
        Reputation = {
            getStanding = function() return standing or 1 end,
            getReputationTier = function() return { key = "regionalContractor" } end,
        },
    }
    return world, advertising
end

local function setDay(day)
    g_currentMission.environment.currentDay = day
end

test("campaigns stack, and their bonuses add up", function()
    local _, advertising = setup()
    advertising:purchaseAdvertising(1, "localNewspaper", 1)
    assertTrue(advertising:canPurchase(1, "regionalMagazine", 2), "another level alongside")
    advertising:purchaseAdvertising(1, "regionalMagazine", 2)

    local campaigns = advertising:getCampaigns(1)
    assertEquals(#campaigns, 2, "both running")
    assertEquals(campaigns[1].levelKey, "localNewspaper", "in level order")
    assertEquals(campaigns[2].levelKey, "regionalMagazine", "in level order")
    assertNear(advertising:getChanceBonus(1), 0.04 + 0.07, 1e-9, "bonuses add")
    assertTrue(not advertising:isRunning(2, "localNewspaper"), "another farm's ads are its own")
end)

test("a new campaign runs the rest of this month, then the months bought", function()
    local _, advertising = setup()
    advertising:purchaseAdvertising(1, "localNewspaper", 1)
    assertEquals(advertising.campaigns[1].localNewspaper, 3, "lapses at the start of month 3")
end)

test("bought on a month's first day, that month is the first paid for", function()
    local _, advertising = setup()
    setDay(11)
    advertising:purchaseAdvertising(1, "localNewspaper", 6)
    assertEquals(advertising.campaigns[1].localNewspaper, 8, "lapses six months on")
    assertEquals(advertising:getMonthsRemaining(1, "localNewspaper"), 6, "six full months")
end)

test("buying a running campaign extends it from its own end", function()
    local world, advertising = setup()
    advertising:purchaseAdvertising(1, "localNewspaper", 1)
    assertTrue(advertising:canPurchase(1, "localNewspaper", 2), "can extend")
    advertising:purchaseAdvertising(1, "localNewspaper", 2)
    assertEquals(advertising.campaigns[1].localNewspaper, 5, "two more months on the end")
    assertEquals(#advertising:getCampaigns(1), 1, "still one campaign")
    assertEquals(#world.money, 2, "charged for each")
end)

test("each campaign lapses on its own", function()
    local _, advertising = setup()
    advertising:purchaseAdvertising(1, "localNewspaper", 1)
    advertising:purchaseAdvertising(1, "regionalMagazine", 3)
    setDay(15)
    advertising:onDayChanged()
    assertTrue(advertising:isRunning(1, "localNewspaper"), "still in its paid month")
    setDay(16)
    advertising:onDayChanged()
    assertTrue(not advertising:isRunning(1, "localNewspaper"), "lapsed")
    assertTrue(advertising:isRunning(1, "regionalMagazine"), "the other runs on")
    setDay(26)
    advertising:onDayChanged()
    assertEquals(advertising.campaigns[1], nil, "nothing left running")
end)

test("months left counts full months, not days", function()
    local _, advertising = setup()
    advertising:purchaseAdvertising(1, "localNewspaper", 6)
    assertEquals(advertising:getMonthsRemaining(1, "localNewspaper"), 6, "six full months after the rest of this one")
    setDay(11)
    assertEquals(advertising:getMonthsRemaining(1, "localNewspaper"), 6, "first day of the first paid month")
    setDay(12)
    assertEquals(advertising:getMonthsRemaining(1, "localNewspaper"), 5, "that month underway")
    setDay(40)
    assertEquals(advertising:getMonthsRemaining(1, "localNewspaper"), 0, "the last month underway")
    assertEquals(advertising:getMonthsRemaining(1, "regionalMagazine"), 0, "not running")
end)

test("a change of days per month doesn't move the expiry", function()
    local _, advertising = setup()
    advertising:purchaseAdvertising(1, "localNewspaper", 2)
    -- Vanilla rescales currentDay with the new length: day 10 of 5-day
    -- months becomes day 19 of 10-day ones, still month 1's last day.
    g_currentMission.environment.daysPerPeriod = 10
    setDay(19)
    assertEquals(advertising:getMonthsRemaining(1, "localNewspaper"), 2, "the same two months")
    setDay(40)
    advertising:onDayChanged()
    assertTrue(advertising:isRunning(1, "localNewspaper"), "running in its last month")
    setDay(41)
    advertising:onDayChanged()
    assertTrue(not advertising:isRunning(1, "localNewspaper"), "lapsed")
end)

test("campaigns save, load and reach a joining client", function()
    local world, advertising = setup()
    advertising:purchaseAdvertising(1, "localNewspaper", 1)
    advertising:purchaseAdvertising(1, "onlineAds", 6)
    advertising:purchaseAdvertising(2, "regionalMagazine", 2)

    local xmlFile = {}
    advertising:saveToXmlFile(xmlFile)
    local loaded = TheContractorAdvertising.new()
    loaded:loadFromXMLFile(xmlFile)
    assertEquals(loaded.campaigns[1].localNewspaper, 3, "farm 1 local")
    assertEquals(loaded.campaigns[1].onlineAds, 8, "farm 1 online")
    assertEquals(loaded.campaigns[2].regionalMagazine, 4, "farm 2")

    local stream = world:newStream()
    advertising:writeInitialClientState(stream)
    local client = TheContractorAdvertising.new()
    client:readInitialClientState(stream)
    assertEquals(client.campaigns[1].onlineAds, 8, "client farm 1")
    assertEquals(client.campaigns[2].regionalMagazine, 4, "client farm 2")
end)

test("an old save's single campaign loads as one of the stack", function()
    local _, advertising = setup()
    advertising:loadFromXMLFile({
        ["TheContractor.advertising.farm(0)#farmId"] = 1,
        ["TheContractor.advertising.farm(0)#level"] = "regionalMagazine",
        ["TheContractor.advertising.farm(0)#expiresOnDay"] = 15,
    })
    assertEquals(advertising.campaigns[1].regionalMagazine, 3, "a mid-month day: the month after")
    assertEquals(TheContractorAdvertising.getLegacyExpiryMonth(16), 3, "a month's first day: that month")
end)

test("a campaign past the offer cap would add less, or nothing", function()
    -- Standing 1: reputation alone gives 0.35 of MAX_HOURLY_CHANCE's 0.5.
    local _, advertising = setup(1)
    assertNear(advertising:getAddedShare(1, "localNewspaper"), 1, 1e-9, "room for all of it")
    advertising:purchaseAdvertising(1, "onlineAds", 1)
    -- 0.35 + 0.15 is the cap.
    assertNear(advertising:getAddedShare(1, "localNewspaper"), 0, 1e-9, "nothing left to add")
    assertNear(advertising:getAddedShare(1, "onlineAds"), 1, 1e-9, "extending changes nothing")

    local _, other = setup(1)
    other:purchaseAdvertising(1, "nationalMagazine", 1)
    -- 0.35 + 0.11 leaves 0.04 of regional's 0.07.
    assertNear(other:getAddedShare(1, "regionalMagazine"), 0.04 / 0.07, 1e-9, "part of it")
end)

test("an offer is the advert's only if it wouldn't have come without it", function()
    local _, advertising = setup(0)
    local generation = TheContractorJobGeneration.new()
    -- Standing 0: reputation's chance is 0.08, and an ad works at half.
    local dpp = g_currentMission.environment.daysPerPeriod
    assertEquals(generation:getOfferSource(1, 0.05 / dpp), "reputation", "no adverts")

    advertising:purchaseAdvertising(1, "localNewspaper", 1)
    advertising:purchaseAdvertising(1, "regionalMagazine", 1)
    -- Bands: reputation to 0.08, local to 0.10, regional to 0.135.
    assertEquals(generation:getOfferSource(1, 0.079 / dpp), "reputation", "within reputation's chance")
    assertEquals(generation:getOfferSource(1, 0.09 / dpp), "localNewspaper", "local's share")
    assertEquals(generation:getOfferSource(1, 0.13 / dpp), "regionalMagazine", "regional's share")
end)

test("the hourly roll tags its offers, and the daily floor's is word of mouth", function()
    local _, advertising = setup(0)
    local generation = TheContractorJobGeneration.new()
    g_currentMission.environment.currentMonotonicDay = 10
    advertising:purchaseAdvertising(1, "localNewspaper", 1)
    local sources = {}
    generation.tryGenerateJob = function(_, farmId, onlyJobType, offerSource)
        table.insert(sources, offerSource)
        return { id = #sources }
    end

    local hourWeight = (TheContractorJobGeneration.HOUR_WEIGHTS[12] or 1) * TheContractorJobGeneration.HOUR_WEIGHT_SCALE
    local dpp = g_currentMission.environment.daysPerPeriod
    local random = math.random
    math.random = function() return 0.09 / dpp * hourWeight end
    generation:rollForFarm(1, 12)
    math.random = random
    assertEquals(sources[1], "localNewspaper", "rolled in the advert's share")

    generation.lastOfferDayByFarm = {}
    generation:rollForFarm(1, TheContractorJobGeneration.FLOOR_LAST_HOUR)
    assertEquals(sources[#sources], "reputation", "the floor's")
end)
