-- FS25_EconomyScale support (TCEconomyScale): its factor reaches job pay,
-- wages, fixed costs and the loose constants, and nothing already priced
-- by a vanilla getter (which that mod scales itself) is scaled twice.

local fakes = dofile("tests/fakes.lua")

local function setEconomyFactor(factor)
    g_currentMission.EconomyScale = factor ~= nil and { factor = factor } or nil
end

local function setup()
    local world = stubs.install()
    TheContractor = { SaveKey = "TheContractor" }
    world.texts.ui_on = "On"
    world.texts.ui_off = "Off"
    FinanceStats = { statNames = {}, statNameToIndex = {} }
    MoneyType = { LAST_ID = 0, register = function(name) return name end }
    Environment = { PERIODS_IN_YEAR = 12 }
    TCCalendar = { getPeriodIndex = function() return 40 end }
    TheContractorJobGeneration = { JOB_PAY_BASELINE = 0.8 }
    g_currentMission.environment = { daysPerPeriod = 5 }

    world.balance = 100000
    g_farmManager.getFarmById = function(_, farmId)
        return { farmId = farmId, getBalance = function() return world.balance end }
    end
    world.money = {}
    g_currentMission.addMoney = function(_, amount, farmId, moneyType)
        world.balance = world.balance + amount
        table.insert(world.money, { amount = amount, farmId = farmId, moneyType = moneyType })
    end

    world:load("src/business/Settings.lua")
    world:load("src/business/Overheads.lua")
    world:load("src/business/Staff.lua")
    world:load("src/business/Office.lua")
    world:load("src/business/Company.lua")
    world:load("src/business/Advertising.lua")
    world:load("src/business/Morale.lua")

    world.wages = 0
    g_currentMission.TheContractor = {
        Settings = TheContractorSettings.new(),
        Staff = setmetatable({ workersByFarm = {} }, TheContractorStaff_mt),
        Office = setmetatable({ membersByFarm = {} }, TheContractorOffice_mt),
        Finances = {
            recordWages = function(_, farmId, amount) world.wages = world.wages + amount end,
        },
    }
    return world, g_currentMission.TheContractor
end

test("without EconomyScale the factor is 1", function()
    setup()
    assertEquals(TCEconomyScale.getFactor(), 1, "factor")
    assertEquals(TCEconomyScale.scale(500), 500, "scaled")
end)

test("the factor is read live from EconomyScale, and nonsense is ignored", function()
    setup()
    setEconomyFactor(0.5)
    assertEquals(TCEconomyScale.getFactor(), 0.5, "half")
    assertEquals(TCEconomyScale.scale(501), 251, "rounded")
    setEconomyFactor(2)
    assertEquals(TCEconomyScale.getFactor(), 2, "changed")
    for _, bad in ipairs({ 0, -1, 0 / 0, "x" }) do
        setEconomyFactor(bad)
        assertEquals(TCEconomyScale.getFactor(), 1, "bad factor " .. tostring(bad))
    end
end)

test("fixed costs follow the factor", function()
    local _, tc = setup()
    local costBefore = tc.Settings:scaleCost(400)
    setEconomyFactor(0.5)
    assertEquals(tc.Settings:scaleCost(400), costBefore / 2, "fixed cost")
end)

local function newJob(world, price)
    world:load("src/business/Negotiation.lua")
    world:load("src/business/Job.lua")
    world:addRelationships()
    return TheContractorJob.new(1, 1, "plow", 7, 3, 1, 1, price)
end

test("new job prices are worked out without the factor", function()
    local _, tc = setup()
    local before = tc.Settings:getJobPayMultiplier()
    setEconomyFactor(0.5)
    assertEquals(tc.Settings:getJobPayMultiplier(), before, "job pay multiplier")
end)

test("an unpaid job's price follows the factor live, stored without it", function()
    local world = setup()
    local job = newJob(world, 10000)
    assertEquals(job:getPrice(), 10000, "no EconomyScale")

    setEconomyFactor(0.5)
    assertEquals(job:getPrice(), 5000, "half")
    assertEquals(job:getOfferedPrice(), 5000, "offered, half")
    setEconomyFactor(2)
    assertEquals(job:getPrice(), 20000, "changed again")
    assertEquals(job.basePrice, 10000, "stored price untouched")
end)

test("a price set at the current level is stored without the factor", function()
    local world = setup()
    local job = newJob(world, 10000)
    setEconomyFactor(0.5)
    job:setPrice(6000)
    assertEquals(job:getPrice(), 6000, "reads back as set")
    assertEquals(job.basePrice, 12000, "stored")
    assertEquals(job:getOfferedPrice(), 5000, "the original offer stays")
    setEconomyFactor(1)
    assertEquals(job:getPrice(), 12000, "follows the factor afterwards")
end)

test("a counter offer is judged at the current price level", function()
    local world = setup()
    local job = newJob(world, 10000)
    g_currentMission.TheContractor.Reputation = { getStanding = function() return 1 end }
    setEconomyFactor(0.5)
    local outcome, price = TheContractorNegotiation.resolveCounterOffer(job, 4800)
    assertEquals(outcome, TheContractorNegotiation.OUTCOME.ACCEPTED, "under the (scaled) price")
    assertEquals(price, 4800, "at the counter")
    outcome = TheContractorNegotiation.resolveCounterOffer(job, 9000)
    assertEquals(outcome, TheContractorNegotiation.OUTCOME.REJECTED, "nearly double the scaled offer")
end)

test("an overhead priced from vanilla values (unscaled) isn't scaled again", function()
    local _, tc = setup()
    local overheads = TheContractorOverheads.new()
    local scaled = { key = "scaled", annualCost = function() return 400 end }
    local vanilla = { key = "vanilla", unscaled = true, annualCost = function() return 1500 end }
    setEconomyFactor(0.5)
    assertEquals(overheads:getAnnualCost(1, scaled), tc.Settings:scaleCost(400), "1x UK overhead")
    assertEquals(overheads:getAnnualCost(1, vanilla), 1500, "fleet-value style overhead")
end)

test("salaries, the administrator and notice pay follow the factor, stored unscaled", function()
    local _, tc = setup()
    local worker = { id = 1, salary = 2600, hiredPeriod = 40 - 3 * 12, age = 40,
        isLeaving = function() return false end }
    tc.Staff.workersByFarm[1] = { [1] = worker }
    tc.Office.membersByFarm[1] = { administrator = { id = 9, role = "administrator", name = "Ann", salary = 2000, level = 1,
        hiredPeriod = 40, ageAtHire = 30 } }
    local noticeBefore = TheContractorStaff.getReleaseCost(worker).noticePay

    setEconomyFactor(0.5)
    assertEquals(TheContractorStaff.scalePay(2600), 1300, "scalePay")
    assertEquals(tc.Staff:getPayroll(1), 2300, "payroll")
    assertNear(TheContractorStaff.getReleaseCost(worker).noticePay, noticeBefore / 2, 1e-6, "notice pay")
    assertEquals(worker.salary, 2600, "stored salary untouched")
end)

test("company creation and advertising cost follow the factor", function()
    local world = setup()
    setEconomyFactor(0.5)
    assertEquals(TheContractorCompany.getCreationCost(), 250, "creation cost")
    local company = TheContractorCompany.new()
    company.applyCompanyCreation = function() end
    company:createCompany(1, "Test")
    assertEquals(world.money[1].amount, -250, "charged")

    assertEquals(TheContractorAdvertising.getCost("localNewspaper", 2), 500, "advertising")
end)

test("a bonus is charged scaled but lifts morale by its base amount", function()
    local world, tc = setup()
    local worker = { id = 1, name = "Bob" }
    tc.Staff.getWorker = function() return worker end
    local morale = TheContractorMorale.new()
    local adjusted
    morale.adjust = function(_, farmId, workers, delta, notify, amount)
        adjusted = { delta = delta, amount = amount }
    end

    setEconomyFactor(0.5)
    assertTrue(morale:requestBonus(1, 1, 500), "paid")
    assertEquals(world.money[1].amount, -250, "charged")
    assertEquals(world.wages, 250, "recorded as wages")
    assertEquals(adjusted.delta, TheContractorMorale.getBonusMorale(500), "morale from the base amount")
    assertEquals(adjusted.amount, 250, "notification shows what was paid")

    world.balance = 400
    assertTrue(TheContractorMorale.canAfford(1, 500), "affordable at the scaled cost")
    assertTrue(not TheContractorMorale.canAfford(1, 1000), "500 isn't enough for 1000 at half")
end)

test("the harvest bonus is charged scaled, morale from the base amount", function()
    local world, tc = setup()
    local workers = { { id = 1 }, { id = 2 } }
    tc.Staff.getRoster = function() return workers end
    local morale = TheContractorMorale.new()
    local adjusted
    morale.adjust = function(_, farmId, adjustedWorkers, delta, notify, amount)
        adjusted = { delta = delta, amount = amount }
    end

    setEconomyFactor(0.5)
    morale:onHarvestBonusAnswered(1, TheContractorMorale.ACTION.GENEROUS)
    local each = TCEconomyScale.scale(TheContractorMorale.HARVEST_GENEROUS)
    assertEquals(world.money[1].amount, -each * 2, "charged")
    assertEquals(adjusted.delta, TheContractorMorale.getBonusMorale(TheContractorMorale.HARVEST_GENEROUS), "morale")
    assertEquals(adjusted.amount, each, "notification amount")
end)

test("job diesel comes from the (already scaled) vanilla price, not scaled again", function()
    local world = stubs.install()
    fakes.installContractor(world)
    setEconomyFactor(0.5)
    local tractor = world:addVehicle({ dieselUsagePerHour = 40, isAIActive = true, fuelStep = 2 })
    local job = world:addJob({ workerId = 3, vehicles = { tractor }, working = true })
    TCJobSupplies.update(TCJobSupplies.POLL_INTERVAL_MS)

    Motorized.updateConsumers(tractor, 16, 1)

    assertNear(job.fuelCost, 2 * 1.5, 0.0001, "cost at the vanilla getter's price")
end)
