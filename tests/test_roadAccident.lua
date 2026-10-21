-- 079: road accidents on the real random events framework (068) and real
-- Claims (052): who's at fault, which machine is hit, the at-fault claim
-- (insured or not), the other driver's insurer paying an estimate later
-- (faster with an administrator), and who it's never rolled for. The rest
-- of the mod is faked.

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
        daysPerPeriod = 10,
        plannedDaysPerPeriod = 10,
        currentMonotonicDay = 1,
    }
    g_farmManager.getFarmById = function(_, farmId)
        return { farmId = farmId }
    end
    FinanceStats = { statNames = {}, statNameToIndex = {} }
    MoneyType = { LAST_ID = 0, TC_INSURANCE_PAYOUT = "tcInsurancePayout",
        register = function(name) return name end }

    world.money = {}
    g_currentMission.addMoney = function(_, amount, farmId, moneyType)
        table.insert(world.money, { amount = amount, farmId = farmId, moneyType = moneyType })
    end

    -- Vanilla's own repair price formula (Wearable.calculateRepairPrice).
    Wearable = {
        calculateRepairPrice = function(price, damage)
            return price * math.pow(damage, 1.5) * 0.09
        end,
    }
    -- Every machine faces +z with no rotation, so local z is world z less its own.
    getWorldTranslation = function(node)
        return node.x, 0, node.z
    end
    worldToLocal = function(node, x, y, z)
        return x - node.x, y, z - node.z
    end
    TCVehicleCondition = {
        isManagedByADS = function(vehicle)
            return vehicle.adsCondition ~= nil
        end,
    }
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
    TheContractorJobs = {
        getBaseReputationReward = function(job)
            return job.baseReputation or 20
        end,
    }
    TCClaimRecordedEvent = { new = function() return {} end }
    TCRandomEventIncidentEvent = { new = function() return {} end }

    world:load("src/util/TCCalendar.lua")
    world:load("src/util/TCConsole.lua")
    world:load("src/util/TCJobConsequences.lua")
    world:load("src/business/Settings.lua")
    world:load("src/business/RandomEvents.lua")
    world:load("src/business/Claims.lua")
    world:load("src/business/RoadAccident.lua")

    world.workers, world.messages, world.notices, world.removedNotices = {}, {}, {}, {}
    world.reputation, world.morale, world.logClaims = {}, {}, {}
    world.insured, world.hasAdmin = false, false
    world.courtesy, world.stolen = {}, {}
    world.recorded = { claims = 0, payouts = 0 }

    local tc = g_currentMission.TheContractor
    tc.Settings = TheContractorSettings.new()
    tc.Company = { companyNames = { [1] = "Test Contracting" } }
    tc.Staff = {
        getWorker = function(_, farmId, workerId)
            return world.workers[workerId]
        end,
    }
    tc.Allocation = {
        getWorkerJobRatings = function(_, worker, job, equipmentIds, isHauler)
            return { tractorRating = worker.rating }
        end,
    }
    tc.Overheads = {
        isActive = function(_, farmId, key)
            return key == TheContractorClaims.OVERHEAD_KEY and world.insured
        end,
    }
    tc.Office = {
        hasAdministrator = function()
            return world.hasAdmin
        end,
    }
    tc.Finances = {
        recordClaims = function(_, farmId, amount)
            world.recorded.claims = world.recorded.claims + amount
        end,
        recordInsurancePayout = function(_, farmId, amount)
            world.recorded.payouts = world.recorded.payouts + amount
        end,
    }
    tc.Reputation = {
        addReputation = function(_, farmId, delta)
            table.insert(world.reputation, delta)
        end,
    }
    tc.Morale = {
        adjust = function(_, farmId, workers, delta)
            for _, worker in ipairs(workers) do
                table.insert(world.morale, { workerId = worker.id, delta = delta })
            end
        end,
    }
    tc.Logbook = {
        getJobEntry = function(_, farmId, jobId)
            return world.logEntry
        end,
        recordClaim = function(_, farmId, jobId, claim)
            table.insert(world.logClaims, { jobId = jobId, claim = claim })
        end,
    }
    tc.CourtesyVehicle = {
        isCourtesy = function(_, vehicleId)
            return world.courtesy[vehicleId] == true
        end,
    }
    tc.Theft = {
        isStolen = function(_, vehicleId)
            return world.stolen[vehicleId] == true
        end,
    }
    tc.Inbox = {
        registerMessageKind = function() end,
        postMessage = function(_, farmId, kind, titleKey, bodyKey, args)
            -- Rendered as the client would, so a broken text fails here.
            local resolved = {}
            for i, arg in ipairs(args) do
                if type(arg) == "string" and string.sub(arg, 1, 7) == "$money_" then
                    resolved[i] = g_i18n:formatMoney(tonumber(string.sub(arg, 8)), 0, true, true)
                else
                    resolved[i] = arg
                end
            end
            table.insert(world.messages, {
                kind = kind,
                titleKey = titleKey,
                bodyKey = bodyKey,
                title = string.format(g_i18n:getText(titleKey), unpack(resolved)),
                body = string.format(g_i18n:getText(bodyKey), unpack(resolved)),
            })
            return #world.messages
        end,
    }
    tc.Notices = {
        publish = function(_, farmId, text)
            table.insert(world.notices, text)
            return #world.notices
        end,
        remove = function(_, noticeId)
            table.insert(world.removedNotices, noticeId)
        end,
    }
    tc.Claims = TheContractorClaims.new()
    tc.RandomEvents = TheContractorRandomEvents.new()
    tc.RoadAccident = TheContractorRoadAccident.new()
    tc.RoadAccident:register(tc.RandomEvents, tc.Inbox)

    function world:addWorker(id, rating)
        self.workers[id] = { id = id, name = "Worker " .. id, rating = rating }
        return id
    end

    -- def: { name, drivable, z (along the road: behind the tractor is
    -- less), price, damage, adsCondition, ads (can break down) }
    function world:addMachine(def)
        local vehicle = self:addVehicle({ name = def.name })
        vehicle.spec_drivable = def.drivable and {} or nil
        vehicle.rootNode = { x = 0, z = def.z or 0 }
        vehicle.uniqueId = "unique" .. vehicle.id
        vehicle.price = def.price or 100000
        vehicle.damage = def.damage or 0
        vehicle.adsCondition = def.adsCondition
        vehicle.breakdowns = {}
        if def.ads then
            vehicle.spec_AdvancedDamageSystem = {}
            function vehicle:addBreakdown(id, options)
                table.insert(self.breakdowns, options.breakdownProgress)
                return true
            end
        end
        function vehicle:getFullName() return self.name end
        function vehicle:getUniqueId() return self.uniqueId end
        function vehicle:getPrice() return self.price end
        function vehicle:getDamageAmount() return self.damage end
        function vehicle:getConditionLevel() return self.adsCondition end
        function vehicle:addDamageAmount(amount) self.damage = self.damage + amount end
        return vehicle
    end

    function world:addJob(def)
        return {
            id = def.id or 1,
            farmId = 1,
            fieldId = def.fieldId or 12,
            assignedWorkerId = def.workerId,
            assignedEquipmentIds = def.equipmentIds or {},
            haulerWorkerId = def.haulerId,
            haulageEquipmentIds = def.haulageIds or {},
            baseReputation = def.baseReputation,
        }
    end

    function world:nextDay()
        local environment = g_currentMission.environment
        environment.currentMonotonicDay = environment.currentMonotonicDay + 1
        tc.RandomEvents:advanceDueIncidents()
    end

    function world:runUntilClosed()
        for _ = 1, 80 do
            if next(tc.RandomEvents.incidents) == nil then
                return
            end
            self:nextDay()
        end
        error("incident never closed")
    end

    return world, tc
end

-- A fixed sequence of rolls for rollAccident, in its order: crew member,
-- scenario, target, fault, severity, claim.
local function rolls(values)
    local i = 0
    return function()
        i = i + 1
        return values[i] or 0.5
    end
end

-- A tractor with a trailer behind it, for worker 1.
local function standardJob(world, def)
    def = def or {}
    world:addWorker(1, def.rating or 10)
    local tractor = world:addMachine({ name = "Tractor", drivable = true, damage = def.damage })
    local trailer = world:addMachine({ name = "Trailer", z = -8, price = 40000 })
    return world:addJob({ workerId = 1, equipmentIds = { tractor.id, trailer.id }, baseReputation = def.baseReputation }),
        tractor, trailer
end

-- Fault -----------------------------------------------------------------------

test("fault chance: scenario base, plus road skill and the rig's wear, clamped", function()
    setup()
    local f = TheContractorRoadAccident.getFaultChance
    assertNear(f("rearEnded", 10, 0), 0.10, 1e-9)
    assertNear(f("clipped", 10, 0), 0.30, 1e-9)
    assertNear(f("rearEnded", 10, 0.5), 0.25, 1e-9)
    assertNear(f("clipped", 10, 0.5), 0.45, 1e-9)
    assertNear(f("rearEnded", 5, 0), 0.10 + 0.4 * 5 / 9, 1e-9)
    assertNear(f("clipped", 5, 0.5), 0.30 + 0.4 * 5 / 9 + 0.15, 1e-9)
    assertNear(f("rearEnded", 1, 0.5), 0.65, 1e-9)
    assertNear(f("clipped", 1, 0.5), 0.85, 1e-9)
    assertNear(f("clipped", 1, 1), 0.90, 1e-9, "capped")
end)

test("wear is vanilla damage, or ADS's condition on a machine ADS manages", function()
    local world = setup()
    assertNear(TheContractorRoadAccident.getVehicleWear(world:addMachine({ damage = 0.3 })), 0.3, 1e-9)
    assertNear(TheContractorRoadAccident.getVehicleWear(world:addMachine({ damage = 0, adsCondition = 0.6 })), 0.4,
        1e-9)
end)

test("the worst-worn machine in the rig counts toward fault", function()
    local world, tc = setup()
    world:addWorker(1, 10)
    local tractor = world:addMachine({ name = "Tractor", drivable = true })
    local trailer = world:addMachine({ name = "Trailer", z = -8, damage = 1 })
    local job = world:addJob({ workerId = 1, equipmentIds = { tractor.id, trailer.id } })
    -- rearEnded with a perfect driver: 10% base, + 30% for the wrecked trailer.
    local data = tc.RoadAccident:rollAccident(1, job, rolls({ 0, 0.1, 0, 0.39 }))
    assertTrue(data.atFault, "0.39 is under 0.40")
    data = tc.RoadAccident:rollAccident(1, job, rolls({ 0, 0.1, 0, 0.41 }))
    assertTrue(not data.atFault, "0.41 isn't")
end)

-- Who and what ------------------------------------------------------------------

test("never for a player-driven job, nothing to drive, or a courtesy tractor", function()
    local world, tc = setup()
    local trailer = world:addMachine({ name = "Trailer" })
    assertEquals(tc.RoadAccident:rollAccident(1, world:addJob({ equipmentIds = { trailer.id } }), rolls({})), nil,
        "the player drove it")
    world:addWorker(1, 8)
    assertEquals(tc.RoadAccident:rollAccident(1, world:addJob({ workerId = 1 }), rolls({})), nil, "no equipment")
    assertEquals(tc.RoadAccident:rollAccident(1, world:addJob({ workerId = 1, equipmentIds = { trailer.id } }),
        rolls({})), nil, "nothing drivable")

    local tractor = world:addMachine({ name = "Loan tractor", drivable = true })
    world.courtesy[tractor.id] = true
    assertEquals(tc.RoadAccident:rollAccident(1, world:addJob({ workerId = 1, equipmentIds = { tractor.id } }),
        rolls({})), nil, "a courtesy tractor isn't ours to damage")
end)

test("rear-ended hits the unit furthest back, clipped any unit; neither hits a courtesy one", function()
    local world, tc = setup()
    world:addWorker(1, 8)
    local tractor = world:addMachine({ name = "Tractor", drivable = true })
    local mower = world:addMachine({ name = "Front mower", z = 3 })
    local trailer = world:addMachine({ name = "Trailer", z = -6 })
    local second = world:addMachine({ name = "Second trailer", z = -14 })
    local job = world:addJob({ workerId = 1, equipmentIds = { tractor.id, mower.id, trailer.id, second.id } })

    assertEquals(tc.RoadAccident:rollAccident(1, job, rolls({ 0, 0.1, 0 })).vehicleName, "Second trailer")
    assertEquals(tc.RoadAccident:rollAccident(1, job, rolls({ 0, 0.9, 0 })).vehicleName, "Front mower", "clipped, first")
    assertEquals(tc.RoadAccident:rollAccident(1, job, rolls({ 0, 0.9, 0.99 })).vehicleName, "Second trailer",
        "clipped, last")

    world.courtesy[second.id] = true
    assertEquals(tc.RoadAccident:rollAccident(1, job, rolls({ 0, 0.1, 0 })).vehicleName, "Trailer", "skips it")

    local solo = world:addJob({ workerId = 1, equipmentIds = { tractor.id, mower.id } })
    assertEquals(tc.RoadAccident:rollAccident(1, solo, rolls({ 0, 0.1, 0 })).vehicleName, "Tractor",
        "nothing behind: the tractor")
end)

test("on a haulage job either worker can be on the road", function()
    local world, tc = setup()
    world:addWorker(1, 8)
    world:addWorker(2, 8)
    local combine = world:addMachine({ name = "Combine", drivable = true })
    local truck = world:addMachine({ name = "Tractor", drivable = true })
    local job = world:addJob({ workerId = 1, equipmentIds = { combine.id }, haulerId = 2,
        haulageIds = { truck.id } })
    assertEquals(tc.RoadAccident:rollAccident(1, job, rolls({ 0 })).workerName, "Worker 1")
    assertEquals(tc.RoadAccident:rollAccident(1, job, rolls({ 0.9 })).workerName, "Worker 2")
end)

test("the repair estimate is vanilla's repair price for the damage, unscaled", function()
    local world, tc = setup()
    local job, _, trailer = standardJob(world)
    local data = tc.RoadAccident:rollAccident(1, job, rolls({ 0, 0.1, 0, 0.99, 0.5 }))
    assertNear(data.severity, 0.25, 1e-9)
    assertEquals(data.vehicleId, trailer.id)
    assertEquals(data.repairEstimate, math.floor(40000 * math.pow(0.25, 1.5) * 0.09))
    assertEquals(data.claimAmount, 0, "no claim when it's theirs")
end)

-- Our fault ---------------------------------------------------------------------

test("our fault, insured: damage, morale, reputation now; the excess later, on the record", function()
    local world, tc = setup()
    world.insured = true
    local job, _, trailer = standardJob(world, { baseReputation = 12 })
    tc.RoadAccident.forcedFault = "ours"
    local incident = tc.RandomEvents:triggerEvent(1, "roadAccident", job)

    assertTrue(incident.data.atFault)
    assertTrue(trailer.damage > 0, "the trailer's damaged")
    assertEquals(world.morale[1].delta, TheContractorRoadAccident.MORALE_AT_FAULT)
    assertEquals(world.reputation[1], -12)
    assertEquals(#world.money, 0, "the claim isn't in yet")
    assertEquals(world.messages[1].bodyKey, "tc_roadAccident_" .. incident.data.scenario .. "_atFaultBody")

    world:runUntilClosed()
    local excess = tc.Settings:scaleCost(TheContractorClaims.EXCESS)
    assertEquals(world.money[1].amount, -excess)
    assertEquals(world.money[1].moneyType, MoneyType.TC_CLAIMS)
    assertEquals(world.recorded.claims, excess)
    assertEquals(tc.Claims:getRecentClaimCount(1), 1, "on the claims history")
    assertEquals(world.logClaims[1].claim.cause, "roadAccident")
    assertEquals(world.logClaims[1].claim.paid, excess)
    assertEquals(world.messages[2].bodyKey, "tc_roadAccident_claimBodyInsured")
    assertEquals(world.recorded.payouts, 0)
end)

test("our fault, uninsured: the whole claim, and the minimum reputation hit on a small job", function()
    local world, tc = setup()
    local job = standardJob(world, { baseReputation = 2 })
    tc.RoadAccident.forcedFault = "ours"
    local incident = tc.RandomEvents:triggerEvent(1, "roadAccident", job)
    local amount = incident.data.claimAmount
    assertTrue(amount >= tc.Settings:scaleCost(TheContractorRoadAccident.CLAIM_MIN) - 1)
    assertEquals(world.reputation[1], -TheContractorRoadAccident.MIN_REPUTATION_PENALTY)

    world:runUntilClosed()
    assertEquals(world.money[1].amount, -amount)
    assertEquals(tc.Claims:getRecentClaimCount(1), 0, "nothing on the history uninsured")
    assertEquals(world.messages[2].bodyKey, "tc_roadAccident_claimBodyUninsured")
end)

test("a job that also had a botch claim gets the two added together in the logbook", function()
    local world, tc = setup()
    local job = standardJob(world)
    world.logEntry = { claim = { cause = "ruts", amount = 10000, paid = 2500, insured = true, reputationPenalty = 10 } }
    tc.RoadAccident.forcedFault = "ours"
    local incident = tc.RandomEvents:triggerEvent(1, "roadAccident", job)
    world:runUntilClosed()
    local claim = world.logClaims[1].claim
    assertEquals(claim.cause, "ruts")
    assertEquals(claim.amount, 10000 + incident.data.claimAmount)
    assertEquals(claim.paid, 2500 + incident.data.claimAmount)
    assertTrue(not claim.insured)
end)

-- Their fault ------------------------------------------------------------------

test("their fault: no money until it's paid, then exactly the estimate; no morale or reputation", function()
    local world, tc = setup()
    local job, _, trailer = standardJob(world)
    tc.RoadAccident.forcedFault = "theirs"
    local incident = tc.RandomEvents:triggerEvent(1, "roadAccident", job)
    local estimate = incident.data.repairEstimate

    assertTrue(trailer.damage > 0, "the trailer's damaged")
    assertEquals(#world.morale, 0)
    assertEquals(#world.reputation, 0)
    assertEquals(incident.stage, "assessed")

    world:nextDay()
    while incident.stage == "assessed" do
        world:nextDay()
    end
    assertEquals(incident.stage, "paid")
    assertEquals(#world.money, 0, "estimated, not paid")
    assertEquals(world.messages[2].bodyKey, "tc_roadAccident_assessedBody")

    world:runUntilClosed()
    assertEquals(#world.money, 1)
    assertEquals(world.money[1].amount, estimate)
    assertEquals(world.money[1].moneyType, MoneyType.TC_INSURANCE_PAYOUT)
    assertEquals(world.recorded.payouts, estimate)
    assertEquals(world.recorded.claims, 0)
    assertEquals(tc.Claims:getRecentClaimCount(1), 0)
    assertEquals(#world.removedNotices, 1, "the payment notice comes down")
    assertEquals(world.messages[3].bodyKey, "tc_roadAccident_paidBody")
end)

test("their fault, with an administrator: paid sooner", function()
    local world, tc = setup()
    world.hasAdmin = true
    local job = standardJob(world)
    tc.RoadAccident.forcedFault = "theirs"
    local incident = tc.RandomEvents:triggerEvent(1, "roadAccident", job)
    while incident.stage == "assessed" do
        world:nextDay()
    end
    assertEquals(incident.stage, "paidFast")
end)

test("an ADS machine gets a breakdown instead of vanilla damage", function()
    local world, tc = setup()
    world:addWorker(1, 8)
    local tractor = world:addMachine({ name = "Tractor", drivable = true, adsCondition = 0.9, ads = true })
    local job = world:addJob({ workerId = 1, equipmentIds = { tractor.id } })
    tc.RoadAccident.forcedFault = "theirs"
    local incident = tc.RandomEvents:triggerEvent(1, "roadAccident", job)
    assertEquals(#tractor.breakdowns, 1)
    assertNear(tractor.breakdowns[1], incident.data.severity, 1e-9)
    assertEquals(tractor.damage, 0)
end)

test("a machine gone before the report still lets the incident finish", function()
    local world, tc = setup()
    local job, _, trailer = standardJob(world)
    tc.RoadAccident.forcedFault = "ours"
    local data = tc.RoadAccident:rollAccident(1, job, rolls({ 0, 0.1, 0 }))
    trailer.isDeleted = true
    tc.RandomEvents.eventTypes.roadAccident.canTrigger = function()
        return data
    end
    tc.RandomEvents:triggerEvent(1, "roadAccident", job)
    world:runUntilClosed()
    assertEquals(#world.money, 1, "the claim still came")
end)

test("the forced fault applies once", function()
    local world, tc = setup()
    local job = standardJob(world, { rating = 1, damage = 1 })
    tc.RoadAccident.forcedFault = "theirs"
    assertTrue(not tc.RoadAccident:rollAccident(1, job, rolls({ 0, 0.9, 0, 0 })).atFault)
    assertTrue(tc.RoadAccident:rollAccident(1, job, rolls({ 0, 0.9, 0, 0 })).atFault, "back to the roll")
end)

test("the saved machine is found again by its uniqueId", function()
    local world, tc = setup()
    local job, _, trailer = standardJob(world)
    tc.RoadAccident.forcedFault = "theirs"
    local incident = tc.RandomEvents:triggerEvent(1, "roadAccident", job)
    incident.data.vehicleId = 999
    tc.RoadAccident:resolveSavedVehicles()
    assertEquals(incident.data.vehicleId, trailer.id)
end)
