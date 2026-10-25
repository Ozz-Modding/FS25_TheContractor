-- Advertising (012/027): one campaign per farm, and the one that's running
-- can't be bought again until it lapses.

local function setup()
    local world = stubs.install()
    TheContractor = { SaveKey = "TheContractor" }
    FinanceStats = { statNames = {}, statNameToIndex = {} }
    MoneyType = { LAST_ID = 0, register = function(name) return name end }
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
    local advertising = TheContractorAdvertising.new()
    g_currentMission.TheContractor = { Advertising = advertising }
    return world, advertising
end

test("the running campaign can't be bought again", function()
    local world, advertising = setup()
    assertTrue(advertising:canPurchase(1, "localNewspaper", 1), "can buy with nothing running")
    assertTrue(advertising:purchaseAdvertising(1, "localNewspaper", 1), "bought")
    assertEquals(advertising:getActiveLevel(1), "localNewspaper", "running")
    assertEquals(advertising.expiresOnDay[1], 15, "a month from today")

    assertTrue(advertising:isRunning(1, "localNewspaper"), "isRunning")
    assertTrue(not advertising:canPurchase(1, "localNewspaper", 3), "same level refused")
    assertTrue(advertising:canPurchase(2, "localNewspaper", 1), "another farm's ad doesn't block")
    assertEquals(#world.money, 1, "charged once")
end)

test("a different level still replaces the running one, starting today", function()
    local _, advertising = setup()
    TheContractorReputation = { TIERS = { { key = "newcomer" }, { key = "localContractor" } } }
    g_currentMission.TheContractor.Reputation = {
        getReputationTier = function() return { key = "localContractor" } end,
    }
    advertising:purchaseAdvertising(1, "localNewspaper", 2)
    assertTrue(advertising:canPurchase(1, "regionalMagazine", 1), "other level allowed")
    advertising:purchaseAdvertising(1, "regionalMagazine", 1)
    assertEquals(advertising:getActiveLevel(1), "regionalMagazine", "replaced")
    assertEquals(advertising.expiresOnDay[1], 15, "from today, not the old expiry")
end)

test("once it lapses it can be bought again", function()
    local _, advertising = setup()
    advertising:purchaseAdvertising(1, "localNewspaper", 1)
    advertising:onDayChanged(15)
    assertEquals(advertising:getActiveLevel(1), nil, "lapsed")
    assertTrue(advertising:canPurchase(1, "localNewspaper", 1), "can buy again")
end)
