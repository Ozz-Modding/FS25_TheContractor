-- Fixed costs follow the job pay setting (TheContractorSettings:scaleCost):
-- COST_BASELINE x 1x UK at the default rate, in proportion otherwise.

local function setup(jobPayRate)
    local world = stubs.install()
    TheContractor = { SaveKey = "TheContractor" }
    -- A vanilla key Settings reads at load.
    world.texts.ui_on = "On"
    world.texts.ui_off = "Off"
    FinanceStats = { statNames = {}, statNameToIndex = {} }
    MoneyType = { LAST_ID = 0, register = function() return 1 end }
    world:load("src/business/Settings.lua")
    world:load("src/business/Overheads.lua")

    local settings = TheContractorSettings.new()
    if jobPayRate ~= nil then
        settings:set("jobPayRate", jobPayRate)
    end
    g_currentMission.TheContractor = {
        Settings = settings,
        Staff = { getHeadcount = function() return 3 end },
    }
    return settings, TheContractorOverheads.new()
end

test("at the default job pay rate costs are COST_BASELINE x UK", function()
    local settings = setup()
    assertEquals(settings:getCostMultiplier(), TheContractorSettings.COST_BASELINE, "multiplier")
    assertEquals(settings:scaleCost(400), 400 * TheContractorSettings.COST_BASELINE, "scaled")
end)

test("costs move in proportion with the job pay rate", function()
    local settings = setup(50)
    assertNear(settings:getCostMultiplier(), TheContractorSettings.COST_BASELINE / 2, 0.0001, "multiplier")
    assertEquals(settings:scaleCost(250), math.floor(250 * TheContractorSettings.COST_BASELINE / 2 + 0.5), "scaled")
end)

test("an overhead's annual cost is its 1x UK price scaled", function()
    local _, overheads = setup()
    local definition = overheads.definitionsByKey.employersLiability
    local uk = TheContractorOverheads.EMPLOYERS_LIABILITY_BASE + 3 * TheContractorOverheads.EMPLOYERS_LIABILITY_PER_WORKER
    assertEquals(overheads:getAnnualCost(1, definition), uk * TheContractorSettings.COST_BASELINE, "annual cost")
end)
