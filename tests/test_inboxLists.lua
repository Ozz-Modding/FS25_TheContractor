-- The Inbox's two tables: a message's chip is its category (what sort of
-- message, never what it's about: a job offer is a Job), and a job's Field
-- cell is a number or "-", never words (a field's name, a farmer's yard's
-- farmland id, "-" for a repair zone or a job whose field only says where
-- it is). The real Inbox, Job and JobGeneration.

local function setup()
    local world = stubs.install()
    TheContractor = { SaveKey = "TheContractor" }
    TheContractorNegotiation = { rollInitialEagerness = function() return 1 end }
    world:load("src/business/Job.lua")
    world:load("src/business/JobGeneration.lua")
    world:load("src/business/Inbox.lua")
    g_fieldManager = { getFieldById = function(_, fieldId)
        return fieldId == 12 and { getName = function() return "12" end } or nil
    end }
    local inbox = TheContractorInbox.new()
    g_currentMission.TheContractor.Inbox = inbox
    return world, inbox
end

local function newJob(jobType, fieldId)
    return TheContractorJob.new(1, 1, jobType, fieldId or 12, 1, 1, 1, 1000)
end

test("a message's category: its kind's; a job offer's is job; anything else a plain message", function()
    local _, inbox = setup()
    inbox:registerMessageKind("holidayRequest", { category = "holiday" })
    inbox:registerMessageKind("fallenTree", { endsWithJob = true })
    inbox:registerMessageKind("yardHaulClaim", { category = "claim" })
    inbox:registerMessageKind("odd", { category = "nonsense" })
    assertEquals(inbox:getCategory({ kind = "holidayRequest" }), "holiday")
    assertEquals(inbox:getCategory({ kind = "fallenTree" }), "job")
    assertEquals(inbox:getCategory({ kind = "yardHaulClaim" }), "claim")
    assertEquals(inbox:getCategory({ kind = "odd" }), TheContractorInbox.DEFAULT_CATEGORY)
    assertEquals(inbox:getCategory({ kind = "unregistered" }), TheContractorInbox.DEFAULT_CATEGORY)
end)

test("every category has its chip text", function()
    setup()
    for category in pairs(TheContractorInbox.CATEGORIES) do
        assertTrue(g_i18n:getText("tc_inbox_chip_" .. category) ~= nil)
    end
end)

test("the Field cell: a field job's field", function()
    setup()
    assertEquals(newJob("plow"):getListFieldText(), "12")
end)

test("the Field cell: a job in a farmer's yard is the yard's farmland id", function()
    setup()
    local haul = newJob("yardHaul")
    haul.yardHaul = { farmerId = 1, yardFarmlandId = 40 }
    assertEquals(haul:getListFieldText(), "40")
    local bales = newJob("yardBales")
    bales.yardDelivery = { farmerId = 1, yardFarmlandId = 41 }
    assertEquals(bales:getListFieldText(), "41")
    local noYard = newJob("yardBales")
    noYard.yardDelivery = { farmerId = 1 }
    assertEquals(noYard:getListFieldText(), "-")
end)

test("the Field cell: a workshop job's breakdown field, a farmer's yard, or a repair zone's -", function()
    setup()
    local breakdown = newJob("adsBreakdown", 0)
    breakdown.workshop = { fieldId = 12 }
    assertEquals(breakdown:getListFieldText(), "12")
    local favour = newJob("adsFavour", 0)
    favour.workshop = { yardFarmlandId = 40 }
    assertEquals(favour:getListFieldText(), "40")
    local repair = newJob("adsRepair", 0)
    repair.workshop = {}
    assertEquals(repair:getListFieldText(), "-")
end)

test("the Field cell: a job whose field only says where it is is -, but a refuel's machine is on its field", function()
    setup()
    assertEquals(newJob("fallenTree"):getListFieldText(), "-")
    local refuel = newJob("emergencyRefuel")
    refuel.refuel = { farmerId = 1 }
    assertEquals(refuel:getListFieldText(), "12")
end)
