-- Machinery insurance (070) on the real overheads (051), random events
-- (068) and theft (069): levels of cover in Overheads, the fleet-value
-- premium, the payout, cover judged on the day of the theft, and both claim
-- paths (Submit claim, or an administrator).

local function setup(daysPerPeriod)
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
        daysPerPeriod = daysPerPeriod or 3,
        plannedDaysPerPeriod = daysPerPeriod or 3,
        currentMonotonicDay = 1,
    }
    world.balance = 1000000
    g_farmManager.getFarmById = function(_, farmId)
        return { farmId = farmId, getBalance = function() return world.balance end }
    end
    g_farmManager.getFarmByUserId = function()
        return { farmId = 1 }
    end

    world.money = {}
    g_currentMission.addMoney = function(_, amount, farmId, moneyType)
        world.balance = world.balance + amount
        table.insert(world.money, { amount = amount, farmId = farmId, moneyType = moneyType })
    end

    FinanceStats = { statNames = {}, statNameToIndex = {} }
    world.moneyTypes = {}
    MoneyType = {
        LAST_ID = 0,
        register = function(name, l10nKey)
            world.moneyTypes[name] = l10nKey
            return name
        end,
    }
    VehiclePropertyState = { OWNED = 2, LEASED = 3 }
    Vehicle.getCanBeSold = function() return true end
    Vehicle.getIsInUse = function() return false end
    TheContractorJob = { STATE = { ALLOCATED = "allocated", IN_PROGRESS = "in_progress" } }

    world.hidden, world.messages, world.notices, world.stats = {}, {}, {}, {}
    TCEquipmentVisibility = {
        isHidden = function(vehicleId) return world.hidden[vehicleId] == true end,
        setVisibleEverywhere = function(vehicleIds, isVisible)
            for _, vehicleId in ipairs(vehicleIds) do
                world.hidden[vehicleId] = not isVisible or nil
            end
        end,
    }
    TCVehicleLock = {
        isLocked = function() return false end,
        refresh = function() end,
    }
    TCJobSiteSetup = { unhitchVehicles = function() end }
    TCEquipmentClass = { getCategory = function() return nil end }
    TheContractorDrivers = { isVehicleDriven = function() return false end }
    TCVehicleIds = {
        getObjectId = function(uniqueId)
            for id, object in pairs(world.objects) do
                if object.uniqueId == uniqueId and not object.isDeleted then
                    return id
                end
            end
            return nil
        end,
    }

    world:load("src/util/TCCalendar.lua")
    world:load("src/util/TCConsole.lua")
    world:load("src/business/Settings.lua")
    world:load("src/business/Overheads.lua")
    world:load("src/business/RandomEvents.lua")
    world:load("src/business/MachineryInsurance.lua")
    world:load("src/business/Theft.lua")

    TCRandomEventIncidentEvent = { new = function() return {} end }
    TCOverheadStateEvent = { new = function() return {} end }
    TCInsuranceClaimRecordedEvent = { new = function() return {} end }

    local tc = g_currentMission.TheContractor
    tc.Settings = TheContractorSettings.new()
    tc.Company = {
        companyNames = { [1] = "Test Contracting" },
        hasCompany = function(_, farmId) return farmId == 1 end,
    }
    tc.Staff = { workersByFarm = {}, getHeadcount = function() return 0 end }
    tc.Jobs = { getAllJobs = function() return {} end }
    tc.Cooldown = { isVehicleInCooldown = function() return false end }
    tc.Parking = {
        isPending = function() return false end,
        returnHiddenVehicles = function() end,
    }
    tc.Drivers = { hasDriver = function() return false end }
    tc.Logbook = { recordTheftRecovered = function() end }
    world.adminEmployed = false
    tc.Office = { hasAdministrator = function() return world.adminEmployed end }
    tc.Finances = {}
    for _, name in ipairs({ "recordOverheads", "recordClaims", "recordInsurancePayout" }) do
        tc.Finances[name] = function(_, farmId, amount)
            world.stats[name] = (world.stats[name] or 0) + amount
        end
    end
    world.removedNotices = {}
    tc.Notices = {
        publish = function(_, farmId, text, ttlMonths)
            table.insert(world.notices, text)
            world.lastNoticeTtl = ttlMonths
            return #world.notices
        end,
        remove = function(_, noticeId) table.insert(world.removedNotices, noticeId) end,
    }
    world.kinds = {}
    tc.Inbox = {
        registerMessageKind = function(_, kind, definition) world.kinds[kind] = definition end,
        postMessage = function(_, farmId, kind, titleKey, bodyKey, args, actions, payload, expiresInDays)
            -- Rendered as the client would, so a broken text fails here.
            local rendered = {}
            for i, arg in ipairs(args or {}) do
                if type(arg) == "string" and arg:sub(1, 6) == "$l10n_" then
                    arg = g_i18n:getText(arg:sub(7))
                elseif type(arg) == "string" and arg:sub(1, 7) == "$money_" then
                    arg = tostring(math.floor(tonumber(arg:sub(8))))
                end
                rendered[i] = arg
            end
            table.insert(world.messages, { farmId = farmId, kind = kind, titleKey = titleKey, bodyKey = bodyKey,
                body = string.format(g_i18n:getText(bodyKey), unpack(rendered)), actions = actions,
                payload = payload or {}, expiresInDays = expiresInDays, args = args or {} })
            return #world.messages
        end,
        removeMessage = function(_, messageId) world.messages[messageId].removed = true end,
    }

    tc.Overheads = TheContractorOverheads.new()
    tc.RandomEvents = TheContractorRandomEvents.new()
    tc.MachineryInsurance = TheContractorMachineryInsurance.new()
    tc.MachineryInsurance:register(tc.Overheads, tc.Inbox, tc.RandomEvents)
    tc.Theft = TheContractorTheft.new()
    tc.Theft:register(tc.RandomEvents, tc.Inbox, tc.MachineryInsurance)

    -- def: { name, value, farmId, propertyState, drivable (default true), isPallet, antiTheft (096) }
    function world:addMachine(def)
        local vehicle = self:addVehicle({ name = def.name, farmId = def.farmId })
        vehicle.spec_drivable = def.drivable ~= false and {} or nil
        vehicle.propertyState = def.propertyState or VehiclePropertyState.OWNED
        vehicle.isPallet = def.isPallet
        vehicle.uniqueId = "unique" .. vehicle.id
        vehicle.value = def.value or 50000
        vehicle.implements = {}
        function vehicle:getFullName() return self.name end
        function vehicle:getUniqueId() return self.uniqueId end
        function vehicle:getSellPrice() return self.value end
        function vehicle:getIsControlled() return false end
        function vehicle:getAttachedImplements() return self.implements end
        function vehicle:getAttacherVehicle() return nil end
        function vehicle:delete() self.isDeleted = true end
        if def.antiTheft then
            function vehicle:hasBreakdown(id) return id == "ANTI_THEFT_SYSTEM" end
        end
        return vehicle
    end

    function world:today()
        return g_currentMission.environment.currentMonotonicDay
    end

    function world:nextDay()
        local environment = g_currentMission.environment
        environment.currentMonotonicDay = environment.currentMonotonicDay + 1
        environment.currentDayInPeriod = environment.currentDayInPeriod + 1
        if environment.currentDayInPeriod > environment.daysPerPeriod then
            environment.currentDayInPeriod = 1
            environment.currentPeriod = environment.currentPeriod + 1
            if environment.currentPeriod > 12 then
                environment.currentPeriod = 1
                environment.currentYear = environment.currentYear + 1
            end
        end
        tc.RandomEvents:advanceDueIncidents()
    end

    -- Days until the incident leaves its current stage (or closes).
    function world:runPastStage(incident)
        local stage = incident.stage
        for _ = 1, 200 do
            local open = tc.RandomEvents:getIncident(incident.id)
            if open == nil or open.stage ~= stage then
                return
            end
            self:nextDay()
        end
        error("stage " .. stage .. " never ended")
    end

    function world:lastMessage()
        return self.messages[#self.messages]
    end

    function world:insure(levelKey)
        tc.Overheads:handleRequest(1, "machineryInsurance", TheContractorOverheads.REQUEST.ENABLE,
            TheContractorOverheads.BILLING.ANNUAL, levelKey)
    end

    return world, tc
end

local SCALE = 5 -- TheContractorSettings.COST_BASELINE at the default job pay rate

test("an overhead without levels is priced and taken out as before", function()
    local world, tc = setup()
    local overheads = tc.Overheads
    overheads:registerOverhead({ key = "plain", l10nKey = "tc_overhead_healthSafety", mandatory = false,
        annualCost = function() return 100 end })
    local definition = overheads:getDefinition("plain")

    assertEquals(TheContractorOverheads.getLevel(definition, "basic"), nil, "no levels")
    assertEquals(overheads:getAnnualCost(1, definition), 100 * SCALE, "scaled 1x UK price")
    overheads:handleRequest(1, "plain", TheContractorOverheads.REQUEST.ENABLE, TheContractorOverheads.BILLING.ANNUAL,
        "basic")
    assertEquals(overheads:getState(1, "plain"), nil, "a level on an overhead without levels is refused")

    overheads:handleRequest(1, "plain", TheContractorOverheads.REQUEST.ENABLE, TheContractorOverheads.BILLING.ANNUAL)
    local state = overheads:getState(1, "plain")
    assertTrue(state.enabled, "taken out")
    assertEquals(state.level, nil, "no level")
    assertEquals(state.termCost, 100 * SCALE, "priced")

    local stream = world:newStream()
    TheContractorOverheads.writeState(stream, state)
    local copy = TheContractorOverheads.readState(stream)
    assertEquals(copy.level, nil, "no level over the wire")
    assertEquals(copy.pendingLevel, nil, "no pending level over the wire")
end)

test("the premium is a share of the fleet's value, unscaled, plus the claims loading", function()
    local world, tc = setup()
    world:addMachine({ name = "Tractor", value = 100000 })
    world:addMachine({ name = "Plough", value = 50000, drivable = false })
    world:addMachine({ name = "Leased", value = 80000, propertyState = VehiclePropertyState.LEASED })
    world:addMachine({ name = "Pallet", value = 900, isPallet = true })
    world:addMachine({ name = "Neighbours", value = 70000, farmId = 2 })
    local insurance = tc.MachineryInsurance
    local definition = tc.Overheads:getDefinition("machineryInsurance")

    assertEquals(insurance:getFleetValue(1), 150000, "owned vehicles only")
    assertNear(tc.Overheads:getAnnualCost(1, definition, "basic"), 1500, 1e-6, "basic 1%, not scaled")
    assertNear(tc.Overheads:getAnnualCost(1, definition, "standard"), 2100, 1e-6, "standard 1.4%")
    assertNear(tc.Overheads:getAnnualCost(1, definition, "comprehensive"), 2700, 1e-6, "comprehensive 1.8%")
    assertNear(tc.Overheads:getAnnualCost(1, definition), 1500, 1e-6, "no level: the first")

    -- Two claims in the last 3 years, one older.
    insurance:applyClaimRecorded(1, { periodIndex = 1, amount = 1 })
    g_currentMission.environment.currentPeriod = 12
    g_currentMission.environment.currentYear = 4 -- period index 48
    insurance:applyClaimRecorded(1, { periodIndex = 20, amount = 1 })
    insurance:applyClaimRecorded(1, { periodIndex = 47, amount = 1 })
    assertEquals(insurance:getRecentClaimCount(1), 2, "two recent")
    assertNear(insurance:getPremium(1, "standard"), 2100 * 1.7, 1e-6, "+35% a claim")

    local count, percent = definition.getRenewalLoading(1)
    assertEquals(count, 2, "loading count")
    assertEquals(percent, 70, "loading percent")
end)

test("a stolen vehicle drops out of the fleet value", function()
    local world, tc = setup()
    world:addMachine({ name = "Tractor", value = 100000 })
    world:addMachine({ name = "Loader", value = 40000 })
    tc.RandomEvents:triggerEvent(1, "theft")
    local value = tc.MachineryInsurance:getFleetValue(1)
    assertTrue(value == 100000 or value == 40000, "one gone: " .. value)
end)

test("levels: taken out at a level, changed from renewal, saved and synced", function()
    local world, tc = setup()
    world:addMachine({ name = "Tractor", value = 100000 })
    local overheads = tc.Overheads

    world:insure("platinum")
    assertEquals(overheads:getState(1, "machineryInsurance"), nil, "an unknown level is refused")

    world:insure("standard")
    local state = overheads:getState(1, "machineryInsurance")
    assertEquals(state.level, "standard", "standard")
    assertNear(state.termCost, 1400, 1e-6, "priced at standard")
    assertNear(world.money[1].amount, -1400 * (1 - TheContractorOverheads.ANNUAL_DISCOUNT), 1e-6, "charged annually")
    assertEquals(tc.MachineryInsurance:getCoverLevel(1, "theft"), "standard", "covered")
    assertEquals(tc.MachineryInsurance:getCoverLevel(1, "fire"), nil, "not a peril it covers")

    overheads:handleRequest(1, "machineryInsurance", TheContractorOverheads.REQUEST.SET_LEVEL, nil, "comprehensive")
    assertEquals(state.pendingLevel, "comprehensive", "from renewal")
    assertEquals(state.level, "standard", "still standard this term")
    assertEquals(tc.MachineryInsurance:getCoverLevel(1, "theft"), "standard", "covered at standard till then")

    -- Save, load, stream: the level and the pending level come through.
    local xmlFile = {}
    overheads:saveToXmlFile(xmlFile)
    local loaded = TheContractorOverheads.new()
    loaded:loadFromXMLFile(xmlFile)
    assertEquals(loaded:getState(1, "machineryInsurance").level, "standard", "level saved")
    assertEquals(loaded:getState(1, "machineryInsurance").pendingLevel, "comprehensive", "pending level saved")
    local stream = world:newStream()
    TheContractorOverheads.writeState(stream, state)
    local copy = TheContractorOverheads.readState(stream)
    assertEquals(copy.level, "standard", "level streamed")
    assertEquals(copy.pendingLevel, "comprehensive", "pending level streamed")

    -- The renewal notice quotes the new level; switching back re-quotes.
    g_currentMission.environment.currentPeriod = state.renewalPeriod - 1
    overheads:onPeriodChanged()
    assertNear(state.quotedCost, 1800, 1e-6, "quoted at comprehensive")
    overheads:handleRequest(1, "machineryInsurance", TheContractorOverheads.REQUEST.SET_LEVEL, nil, "standard")
    assertEquals(state.pendingLevel, nil, "back to standard")
    assertNear(state.quotedCost, 1400, 1e-6, "re-quoted")
    overheads:handleRequest(1, "machineryInsurance", TheContractorOverheads.REQUEST.SET_LEVEL, nil, "basic")

    g_currentMission.environment.currentPeriod = state.renewalPeriod
    overheads:onPeriodChanged()
    state = overheads:getState(1, "machineryInsurance")
    assertEquals(state.level, "basic", "renewed at basic")
    assertEquals(state.pendingLevel, nil, "nothing pending")
    assertNear(state.termCost, 1000, 1e-6, "priced at basic")
end)

test("the payout is value x the level's share, less the scaled excess", function()
    setup()
    local payout, excess = TheContractorMachineryInsurance.getSettlement(100000, "basic")
    assertEquals(payout, 80000 - 1000 * SCALE, "basic: 80%")
    assertEquals(excess, 1000 * SCALE, "basic excess")
    payout, excess = TheContractorMachineryInsurance.getSettlement(100000, "standard")
    assertEquals(payout, 90000 - 500 * SCALE, "standard")
    assertEquals(excess, 500 * SCALE, "standard excess")
    payout = TheContractorMachineryInsurance.getSettlement(100000, "comprehensive")
    assertEquals(payout, 100000 - 250 * SCALE, "comprehensive")
    payout, excess = TheContractorMachineryInsurance.getSettlement(1000, "basic")
    assertEquals(payout, 0, "never below nothing")
    assertEquals(excess, 800, "the excess takes what there is")
    assertEquals(TheContractorMachineryInsurance.getSettlement(100000, ""), 0, "uninsured")
end)

test("uninsured on the day of the theft gets nothing, even if insured afterwards", function()
    local world, tc = setup()
    local tractor = world:addMachine({ name = "Fendt 724", value = 100000 })
    world:addMachine({ name = "Plough", value = 20000, drivable = false })
    tc.Theft.forcedOutcome = TheContractorTheft.OUTCOME.LOST

    local incident = tc.RandomEvents:triggerEvent(1, "theft")
    assertEquals(incident.data.coverLevel, "", "uninsured on the day")
    world:insure("comprehensive")
    world:runPastStage(incident)

    assertEquals(tc.RandomEvents:getIncident(incident.id), nil, "over")
    assertTrue(tractor.isDeleted, "written off")
    assertEquals(world:lastMessage().bodyKey, "tc_theft_lostBody", "plain written-off message")
    assertEquals(world.stats.recordInsurancePayout, nil, "nothing paid")
    assertEquals(#world.money, 1, "only the premium moved money")
end)

test("no administrator: Submit claim, then it settles 1-2 months later", function()
    local world, tc = setup(28)
    local tractor = world:addMachine({ name = "Fendt 724", value = 100000 })
    world:insure("standard")
    tc.Theft.forcedOutcome = TheContractorTheft.OUTCOME.LOST

    local incident = tc.RandomEvents:triggerEvent(1, "theft")
    assertEquals(incident.data.coverLevel, "standard", "insured on the day")
    world:runPastStage(incident)

    assertEquals(incident.stage, "claim", "waiting for the claim")
    assertEquals(incident.nextStageDay, 0, "no timer")
    assertTrue(tractor.isDeleted, "gone at the police report")
    assertTrue(not tc.Theft:isStolen(tractor.id), "nothing left to be stolen")
    assertEquals(incident.data.value, 100000, "the claim keeps its value")
    assertTrue(world.messages[1].removed, "the stolen message is taken down")
    local lost = world.messages[#world.messages - 1]
    assertEquals(lost.bodyKey, "tc_theft_lostBodyInsured", "told they can claim")
    local claim = world:lastMessage()
    assertEquals(claim.kind, "insuranceClaim", "claim message")
    assertEquals(claim.actions[1].key, "submitClaim", "Submit claim")
    assertEquals(claim.expiresInDays, 28, "a month to answer")
    assertEquals(claim.args[2], "$l10n_" .. TheContractorMachineryInsurance.getLevelTextKey("standard"),
        "names the level")
    assertTrue(world.kinds.insuranceClaim.getConfirmText(claim, "submitClaim") ~= nil, "Submit claim asks first")
    local noticeCount = #world.notices

    -- Survives a save and load while it waits.
    local xmlFile = {}
    tc.RandomEvents:saveToXmlFile(xmlFile)
    local randomEvents = TheContractorRandomEvents.new()
    local insurance = TheContractorMachineryInsurance.new()
    insurance:register(tc.Overheads, tc.Inbox, randomEvents)
    local theft = TheContractorTheft.new()
    theft:register(randomEvents, tc.Inbox, insurance)
    randomEvents:loadFromXMLFile(xmlFile)
    tc.RandomEvents, tc.MachineryInsurance, tc.Theft = randomEvents, insurance, theft
    theft:resolveSavedVehicles()
    incident = randomEvents:getIncident(incident.id)
    assertEquals(incident.stage, "claim", "still waiting after a reload")

    world.kinds.insuranceClaim.onAction(1, claim, "submitClaim")
    local wait = incident.nextStageDay - world:today()
    assertEquals(incident.stage, "claimSettle", "submitted")
    assertTrue(wait >= 28 and wait <= 56, "1-2 months at 28 days: " .. wait)
    assertEquals(#world.notices, noticeCount + 1, "claim notice")
    assertEquals(world.lastNoticeTtl, nil, "up until it settles")
    local claimNoticeId = incident.data.claimNoticeId
    assertEquals(claimNoticeId, noticeCount + 1, "its id kept")
    world.kinds.insuranceClaim.onAction(1, claim, "submitClaim")
    assertEquals(incident.nextStageDay - world:today(), wait, "a second submit changes nothing")
    assertEquals(#world.notices, noticeCount + 1, "and puts up no second notice")

    world:runPastStage(incident)
    assertEquals(randomEvents:getIncident(incident.id), nil, "over")
    local payout = 90000 - 500 * SCALE
    local paid = world.money[#world.money]
    assertEquals(paid.amount, payout, "paid value less excess")
    assertEquals(paid.moneyType, "tcInsurancePayout", "as an insurance payout")
    assertEquals(world.stats.recordClaims, 500 * SCALE, "excess recorded as a claim")
    assertEquals(world.stats.recordInsurancePayout, payout, "payout recorded")
    assertEquals(insurance:getRecentClaimCount(1), 1, "on the claims history")
    assertEquals(world.removedNotices[1], claimNoticeId, "claim notice taken down")
    assertEquals(world:lastMessage().titleKey, "tc_insurance_settledTitle", "settled message")
    assertEquals(world:lastMessage().args[6], "$money_" .. payout, "says what was paid")
end)

test("an unanswered claim goes in when its message expires", function()
    local world, tc = setup(28)
    world:addMachine({ name = "Fendt 724", value = 100000 })
    world:insure("basic")
    tc.Theft.forcedOutcome = TheContractorTheft.OUTCOME.LOST
    local incident = tc.RandomEvents:triggerEvent(1, "theft")
    world:runPastStage(incident)

    world.kinds.insuranceClaim.onExpire(1, world:lastMessage())
    local wait = incident.nextStageDay - world:today()
    assertEquals(incident.stage, "claimSettle", "submitted")
    assertTrue(wait >= 28 and wait <= 56, "same 1-2 months: " .. wait)
    world:runPastStage(incident)
    assertEquals(world.stats.recordInsurancePayout, 80000 - 1000 * SCALE, "basic pays 80% less excess")
end)

test("with an administrator the claim goes in at once and settles in 0.5-1 month", function()
    local world, tc = setup(28)
    local tractor = world:addMachine({ name = "Fendt 724", value = 100000 })
    world:insure("comprehensive")
    world.adminEmployed = true
    tc.Theft.forcedOutcome = TheContractorTheft.OUTCOME.LOST
    local incident = tc.RandomEvents:triggerEvent(1, "theft")
    world:runPastStage(incident)

    assertEquals(incident.stage, "claimSettleFast", "submitted by the administrator")
    local wait = incident.nextStageDay - world:today()
    assertTrue(wait >= 14 and wait <= 28, "0.5-1 month at 28 days: " .. wait)
    local message = world:lastMessage()
    assertEquals(message.bodyKey, "tc_insurance_claimByAdminBody", "told it's in")
    assertEquals(message.actions, nil, "nothing to answer")
    assertTrue(world.notices[incident.data.claimNoticeId] ~= nil, "claim notice")

    world:runPastStage(incident)
    assertEquals(world.stats.recordInsurancePayout, 100000 - 250 * SCALE, "comprehensive")
    assertTrue(tractor.isDeleted, "gone")
    assertEquals(#world.removedNotices, 1, "claim notice taken down")
end)

test("a recovered vehicle needs no claim", function()
    local world, tc = setup()
    local tractor = world:addMachine({ name = "Fendt 724", value = 100000 })
    tractor.addDamageAmount = function() end
    tractor.addDirtAmount = function() end
    TCVehicleCondition = { capture = function() return {} end }
    world:insure("standard")
    tc.Theft.forcedOutcome = TheContractorTheft.OUTCOME.RECOVERED
    local incident = tc.RandomEvents:triggerEvent(1, "theft")
    world:runPastStage(incident)

    assertEquals(tc.RandomEvents:getIncident(incident.id), nil, "over")
    assertTrue(not tractor.isDeleted, "kept")
    assertEquals(world.stats.recordInsurancePayout, nil, "nothing claimed")
end)

test("the claims history saves, loads and reaches a joining client", function()
    local world, tc = setup()
    tc.MachineryInsurance:applyClaimRecorded(1, { periodIndex = 1, amount = 90000 })

    local xmlFile = {}
    tc.MachineryInsurance:saveToXmlFile(xmlFile)
    local loaded = TheContractorMachineryInsurance.new()
    loaded:loadFromXMLFile(xmlFile)
    assertEquals(loaded:getRecentClaimCount(1), 1, "loaded")

    local stream = world:newStream()
    tc.MachineryInsurance:writeInitialClientState(stream)
    local client = TheContractorMachineryInsurance.new()
    client:readInitialClientState(stream)
    assertEquals(client.historyByFarm[1][1].amount, 90000, "streamed")
end)

test("the payout money type is registered with its Finances screen text", function()
    local world = setup()
    assertEquals(world.moneyTypes.tcInsurancePayout, "tc_moneyType_insurancePayout", "registered")
    assertTrue(FinanceStats.statNameToIndex.tcInsurancePayout ~= nil, "a finance stat")
    assertTrue(g_i18n:getText("finance_tcInsurancePayout") ~= nil, "finance_ text")
end)

test("096: a vehicle with an anti-theft system is 15% cheaper to cover", function()
    local world, tc = setup()
    world:addMachine({ name = "Tractor", value = 100000, antiTheft = true })
    world:addMachine({ name = "Loader", value = 50000 })
    local insurance = tc.MachineryInsurance
    local definition = tc.Overheads:getDefinition("machineryInsurance")

    local total, insured, fitted = insurance:getFleetValue(1)
    assertEquals(total, 150000, "real value")
    assertNear(insured, 135000, 1e-6, "priced value")
    assertEquals(fitted, 1, "one fitted")
    assertNear(tc.Overheads:getAnnualCost(1, definition, "basic"), 1350, 1e-6, "basic 1% of the priced value")
end)

test("096: the discount is only described where ADS can fit the system", function()
    local _, tc = setup()
    local definition = tc.Overheads:getDefinition("machineryInsurance")
    assertEquals(definition.getDescriptionKey(), "tc_overhead_machineryInsurance_desc", "no ADS")
    g_modIsLoaded = { FS25_AdvancedDamageSystem = true }
    local key = definition.getDescriptionKey()
    g_modIsLoaded = nil
    assertEquals(key, "tc_overhead_machineryInsurance_desc_antiTheft", "ADS")
end)
