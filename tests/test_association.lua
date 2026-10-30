-- Legal cover's member price (053) follows the membership mid-term: joining
-- or leaving the association reprices the rest of the cover's term through
-- Overheads:repriceMidTerm (refund or charge on annual, the next bills on
-- monthly), re-quoting a renewal already quoted.

-- Read once the files are loaded (setup).
local BASELINE, ANNUAL

local function setup()
    local world = stubs.install()
    TheContractor = { SaveKey = "TheContractor" }
    world.texts.ui_on = "On"
    world.texts.ui_off = "Off"
    for month = 1, 12 do
        world.texts["ui_month" .. month] = "Month " .. month
    end

    Environment = { PERIODS_IN_YEAR = 12 }
    g_currentMission.environment = {
        currentYear = 1,
        currentPeriod = 1,
        currentDayInPeriod = 1,
        daysPerPeriod = 3,
        plannedDaysPerPeriod = 3,
        currentMonotonicDay = 1,
    }
    world.balance = 1000000
    g_farmManager.getFarmById = function(_, farmId)
        return { farmId = farmId, getBalance = function() return world.balance end }
    end
    world.money = {}
    g_currentMission.addMoney = function(_, amount, farmId, moneyType)
        world.balance = world.balance + amount
        table.insert(world.money, { amount = amount, farmId = farmId, moneyType = moneyType })
    end

    FinanceStats = { statNames = {}, statNameToIndex = {} }
    MoneyType = { LAST_ID = 0, register = function(name) return name end }
    TCOverheadStateEvent = { new = function() return {} end }

    world:load("src/util/TCCalendar.lua")
    world:load("src/business/Settings.lua")
    world:load("src/business/Overheads.lua")
    world:load("src/business/Association.lua")

    local tc = g_currentMission.TheContractor
    tc.Settings = TheContractorSettings.new()
    tc.Company = { hasCompany = function(_, farmId) return farmId == 1 end }
    tc.Staff = { workersByFarm = {}, getHeadcount = function() return 0 end }
    world.overheadsPaid = 0
    tc.Finances = {
        recordOverheads = function(_, farmId, amount) world.overheadsPaid = world.overheadsPaid + amount end,
    }
    world.notices = {}
    tc.Notices = {
        publish = function(_, farmId, text) table.insert(world.notices, text) end,
    }
    world.messages = {}
    tc.Inbox = {
        registerMessageKind = function() end,
        postMessage = function(_, farmId, kind, titleKey, bodyKey, args, actions, payload)
            local message = { id = #world.messages + 1, farmId = farmId, kind = kind, args = args,
                payload = payload or {} }
            world.messages[message.id] = message
            return message.id
        end,
        getMessages = function(_, farmId)
            local result = {}
            for _, message in pairs(world.messages) do
                if message.farmId == farmId and not message.removed then
                    table.insert(result, message)
                end
            end
            return result
        end,
        removeMessage = function(_, messageId) world.messages[messageId].removed = true end,
    }

    tc.Overheads = TheContractorOverheads.new()
    tc.Association = TheContractorAssociation.new()
    tc.Association:register(tc.Overheads, tc.Inbox)

    function world:takeOut(key, billing)
        tc.Overheads:handleRequest(1, key, TheContractorOverheads.REQUEST.ENABLE, billing)
    end

    function world:nextPeriod()
        local environment = g_currentMission.environment
        environment.currentPeriod = environment.currentPeriod + 1
        if environment.currentPeriod > 12 then
            environment.currentPeriod = 1
            environment.currentYear = environment.currentYear + 1
        end
        tc.Overheads:onPeriodChanged()
    end

    function world:legal()
        return tc.Overheads:getState(1, TheContractorAssociation.LEGAL_COVER_KEY)
    end

    BASELINE = TheContractorSettings.COST_BASELINE
    ANNUAL = TheContractorOverheads.ANNUAL_DISCOUNT
    return world, tc
end

test("joining refunds the rest of an annual legal cover's term", function()
    local world, tc = setup()
    local full = TheContractorAssociation.LEGAL_COVER_COST * BASELINE
    local member = TheContractorAssociation.LEGAL_COVER_MEMBER_COST * BASELINE
    world:takeOut("legalExpenses", "annual")
    assertNear(world:legal().termCost, full, 0.01, "full price first")

    local balance = world.balance
    world:takeOut("tradeAssociation", "annual")
    local membership = TheContractorAssociation.MEMBERSHIP_COST * BASELINE * (1 - ANNUAL)
    local refund = (full - member) * (1 - ANNUAL) * 11 / 12
    assertNear(world.balance - balance, refund - membership, 0.01, "refund for the 11 months after this one")
    assertNear(world:legal().termCost, member, 0.01, "repriced")
    assertEquals(#world.notices, 1, "a notice")
end)

test("joining lowers a monthly legal cover's next bills", function()
    local world, tc = setup()
    local member = TheContractorAssociation.LEGAL_COVER_MEMBER_COST * BASELINE
    world:takeOut("legalExpenses", "monthly")
    world:takeOut("tradeAssociation", "annual")
    assertNear(world:legal().termCost, member, 0.01, "repriced")

    local balance = world.balance
    world:nextPeriod()
    assertNear(balance - world.balance, member / 12, 0.01, "next month at the member price")
    assertEquals(#world.notices, 1, "a notice")
end)

test("leaving charges the rest of an annual term at the full price", function()
    local world, tc = setup()
    local full = TheContractorAssociation.LEGAL_COVER_COST * BASELINE
    local member = TheContractorAssociation.LEGAL_COVER_MEMBER_COST * BASELINE
    world:takeOut("tradeAssociation", "monthly")
    world:takeOut("legalExpenses", "annual")
    assertNear(world:legal().termCost, member, 0.01, "member price")
    tc.Overheads:handleRequest(1, "tradeAssociation", TheContractorOverheads.REQUEST.CANCEL)
    assertTrue(tc.Association:isMember(1), "still a member this month")

    local balance = world.balance
    world:nextPeriod()
    assertTrue(not tc.Association:isMember(1), "membership ended")
    -- The new month is the second of twelve: ten left after it.
    local charge = (full - member) * (1 - ANNUAL) * 10 / 12
    assertNear(balance - world.balance, charge, 0.01, "charged the difference")
    assertNear(world:legal().termCost, full, 0.01, "full price again")
    assertEquals(#world.notices, 1, "a notice")
end)

test("a renewal already quoted is quoted again at the member price", function()
    local world, tc = setup()
    local member = TheContractorAssociation.LEGAL_COVER_MEMBER_COST * BASELINE
    world:takeOut("legalExpenses", "annual")
    for _ = 1, 11 do
        world:nextPeriod()
    end
    local old = world.messages[1]
    assertTrue(old ~= nil and old.kind == TheContractorOverheads.RENEWAL_MESSAGE_KIND, "renewal notice out")

    local balance = world.balance
    world:takeOut("tradeAssociation", "annual")
    assertTrue(old.removed, "old notice taken down")
    assertNear(world:legal().quotedCost, member, 0.01, "re-quoted")
    local new = world.messages[2]
    assertTrue(new ~= nil and not new.removed, "new notice")
    assertEquals(new.args[4], "$money_" .. TheContractorOverheads.getChargeAmount(member, "annual"), "new price")
    -- Last month of the term: nothing left to refund, so no notice.
    assertNear(balance - world.balance, TheContractorAssociation.MEMBERSHIP_COST * BASELINE * (1 - ANNUAL), 0.01,
        "only the membership")
    assertEquals(#world.notices, 0, "no notice")

    world:nextPeriod()
    assertNear(world:legal().termCost, member, 0.01, "renewed at the member price")
end)

test("joining without legal cover changes nothing", function()
    local world, tc = setup()
    world:takeOut("tradeAssociation", "annual")
    assertEquals(world:legal(), nil, "no cover")
    assertEquals(#world.notices, 0, "no notice")
end)
