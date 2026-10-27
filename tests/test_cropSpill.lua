-- 106: a tipped trailer's spilt crop. Where it goes (the heap's line and
-- the site, in the field), how much (90% of the trailer, capped), the urgent
-- job (accepted and allocated to the farm's players at once, for nothing,
-- due tomorrow, 80% to deliver), when it's done (delivered), what a miss
-- costs (reputation, a claim at 50%), the land access
-- on the site, and the job's spill through the save and the stream. The
-- real Jobs, Allocation, JobGeneration and haulage tracker, with the
-- density map (tipping and measuring the heap) and the rest of the mod
-- faked.

local function setup()
    local world = stubs.install()
    TheContractor = { SaveKey = "TheContractor" }
    world.texts.ui_on = "On"
    world.texts.ui_off = "Off"
    FinanceStats = { statNames = {}, statNameToIndex = {} }
    MoneyType = { LAST_ID = 0, register = function(name) return name end }
    FarmManager.SPECTATOR_FARM_ID = 0
    Environment = { PERIODS_IN_YEAR = 12 }
    g_currentMission.environment = {
        currentYear = 1, currentPeriod = 3, currentDayInPeriod = 4, daysPerPeriod = 10, plannedDaysPerPeriod = 10,
        currentMonotonicDay = 24, dayTime = 36000000,
        getPeriodFromDay = function(_, day) return 3 end,
        getDayInPeriodFromDay = function(_, day) return 5 end,
    }
    g_farmManager.getFarmById = function(_, farmId) return { farmId = farmId } end
    world.farms = { { farmId = 1 }, { farmId = 2 } }
    TheContractorNegotiation = { rollInitialEagerness = function() return 1 end }
    TCJobConsequences = {
        saveToXML = function() end,
        loadFromXML = function() end,
        writeReports = function() end,
        readReports = function() return {} end,
        applyOnCompletion = function() end,
    }
    TCVehicleIds = { saveList = function() end, loadList = function() return {} end }
    math.clamp = math.clamp or function(value, low, high)
        return math.max(low, math.min(high, value))
    end
    table.hasElement = table.hasElement or function(list, value)
        for _, element in ipairs(list) do
            if element == value then
                return true
            end
        end
        return false
    end

    -- Engine classes the spill's access hooks patch as it loads.
    world.vanillaAccess = false
    Shovel = { getCanShovelAtPosition = function() return world.vanillaAccess end }
    Dischargeable = { getCanDischargeToLand = function() return world.vanillaAccess end }
    FarmlandManager = { getCanAccessLandAtWorldPosition = function() return world.vanillaAccess end }
    localToWorld = function(node, x, y, z)
        return node.x + x, 0, node.z + z
    end

    world:load("src/business/Job.lua")
    world:load("src/business/Jobs.lua")
    world:load("src/business/CropSpill.lua")
    world:load("src/business/JobGeneration.lua")
    world:load("src/util/TCEquipmentClass.lua")
    world:load("src/business/Allocation.lua")
    world:load("src/business/Settings.lua")
    world:load("src/business/RandomEvents.lua")
    TCJobProgress = { POLL_INTERVAL_MS = 3000, clearJob = function() end }
    world:load("src/util/TCHaulage.lua")

    world.calls = {}
    local function record(name)
        return function(...)
            table.insert(world.calls, { name = name, args = { ... } })
        end
    end
    function world.called(name)
        for _, call in ipairs(world.calls) do
            if call.name == name then
                return call
            end
        end
        return nil
    end
    TCFieldPreparation = {
        prepareFieldForJob = function(job)
            -- The real one returns at once for a spill (its jobDef.spill).
            table.insert(world.calls, { name = "prepareField", spill = TheContractorJobGeneration.JOB_TYPES[
                job.jobType].spill })
        end,
        clearUpAfterJob = record("clearUp"),
    }
    TCFieldAccess = { refresh = function() end }
    TCJobSupplies = { topUp = function() end }
    TCJobAllocatedEvent = { new = function(job) return { job = job } end }
    TCHaulage.emptyHarvestersAfterJob = function() end

    -- The customer's selling point: the harvest job's, by uniqueId.
    world.station = { missions = {}, price = 0.4, getName = function() return "Grain Mill" end }
    function world.station:getEffectiveFillTypePrice(fillTypeIndex)
        return self.price
    end
    world.station.owningPlaceable = { getUniqueId = function() return "mill" end }
    g_currentMission.placeableSystem = {
        getPlaceableByUniqueId = function(_, uniqueId)
            return uniqueId == "mill" and world.station.owningPlaceable or nil
        end,
    }
    g_currentMission.storageSystem.getPlaceableUnloadingStation = function() return world.station end
    g_currentMission.storageSystem.getPlaceableUnloadingStationIndex = function() return 1 end
    HarvestMission = { getSellingStationWithHighestPrice = function() return world.bestStation end }

    FruitType = { UNKNOWN = 0, WHEAT = 2 }
    g_fruitTypeManager = {
        getFruitTypeByName = function(_, name)
            return name == "WHEAT" and { index = FruitType.WHEAT } or nil
        end,
        getFruitTypeByIndex = function(_, index)
            return index == FruitType.WHEAT and { index = index, name = "WHEAT" } or nil
        end,
        getFillTypeIndexByFruitTypeIndex = function(_, index)
            return index == FruitType.WHEAT and FillType.WHEAT or nil
        end,
    }
    world.fields = { [12] = { getName = function() return "12" end, getAreaHa = function() return 0.5 end,
        getFieldState = function() return { fruitTypeIndex = FruitType.UNKNOWN } end } }
    g_fieldManager = { getFieldById = function(_, fieldId) return world.fields[fieldId] end }

    -- The density map: the heap's tipped whole (or world.landed).
    world.landed = nil
    world.canTip = true
    world.tipped, world.cleared = {}, {}
    world.realTipHeap = TheContractorCropSpill.tipHeap
    TheContractorCropSpill.canTip = function() return world.canTip end
    TheContractorCropSpill.tipHeap = function(fillTypeIndex, liters, plan)
        table.insert(world.tipped, { fillTypeIndex = fillTypeIndex, liters = liters, plan = plan })
        return world.landed or liters, 6
    end
    TheContractorCropSpill.clearSite = function(job) table.insert(world.cleared, job.id) end

    local tc = g_currentMission.TheContractor
    tc.Settings = TheContractorSettings.new()
    tc.Jobs = TheContractorJobs.new()
    tc.Allocation = TheContractorAllocation.new()
    tc.CropSpill = TheContractorCropSpill.new()
    tc.RandomEvents = TheContractorRandomEvents.new()
    tc.Staff = { getWorker = function() return nil end, applyGrowthFromJob = function() end }
    tc.Dispatch = {
        isJobActive = function() return false end,
        stopJob = function() end,
        takeRanOutOfFill = function() end,
        startJobForWorker = record("dispatch"),
    }
    tc.Cooldown = { startCooldown = function() end }
    tc.Parking = { returnVehicles = function() end, returnHiddenVehicles = function() end,
        isPending = function() return false end, sendToShop = function() return {} end }
    world.reputation = {}
    tc.Reputation = {
        addReputation = function(_, farmId, delta) table.insert(world.reputation, delta) end,
        getStanding = function() return 0.5 end,
    }
    world.invoiced = {}
    tc.Finances = { invoiceJob = function(_, job) table.insert(world.invoiced, job.paymentAmount) end }
    tc.Association = { getReputationBonus = function() return 0 end }
    tc.Claims = {
        rollForJob = function() end,
        isInsured = function() return world.insured == true end,
        chargeClaim = function(_, farmId, amount, insured)
            local paid = insured and 500 or amount
            table.insert(world.calls, { name = "claim", amount = amount, insured = insured, paid = paid })
            return paid
        end,
        addToJobLog = function(_, farmId, jobId, claim)
            table.insert(world.calls, { name = "claimLogged", jobId = jobId, claim = claim })
        end,
    }
    tc.Logbook = {
        recordJobCompleted = function() end,
        recordJobMissed = record("logMissed"),
        onCrewChanged = function() end,
    }
    world.messages = {}
    tc.Inbox = {
        registerMessageKind = function(_, kind, definition) world.messageKind = definition end,
        postMessage = function(_, farmId, kind, titleKey, bodyKey, args, actions, payload)
            table.insert(world.messages, { kind = kind, titleKey = titleKey, bodyKey = bodyKey, args = args,
                payload = payload })
            return #world.messages
        end,
        removeMessagesForJob = function() end,
    }
    tc.CropSpill:register(tc.Inbox)
    TCJobMissedEvent = { showNotification = function() end }
    TCJobCompletedEvent = { showNotification = function() end }
    AIMessageSuccessFinishedJob = { new = function() return {} end }
    AIMessageSuccessStoppedByUser = { new = function() return {} end }

    -- A harvest & haul job of wheat on field 12, done, to the Grain Mill.
    function world:addHarvestJob()
        local job = TheContractorJob.new(7, 1, "harvest", 12, 1, 3, 4, 5000)
        job.fruitTypeName = "WHEAT"
        job.includesHaulage = true
        job.deliveryStationUniqueId = "mill"
        job.deliveryStationIndex = 1
        job.deliveryStationName = "Grain Mill"
        job.state = TheContractorJob.STATE.COMPLETED
        tc.Jobs:registerJob(job, false)
        return job
    end

    -- A grain trailer with room for capacity litres of wheat.
    function world:addTrailer(capacity)
        local trailer = self:addVehicle({ name = "Grain trailer",
            fillUnits = { { capacity = capacity, supported = { FillType.WHEAT } } } })
        trailer.size = { width = 3, length = 9, height = 3.5 }
        function trailer:getFullName() return self.name end
        return trailer
    end

    -- 105's spot: the trailer's wheels at x = -0.5, facing north, its top
    -- 3.5 m east at x = 3.
    world.data = { x = -0.5, z = 0, dirX = 0, dirZ = 1, sideX = 1, sideZ = 0 }

    function world:spill(capacity)
        return tc.CropSpill:spill(1, self.harvestJob or self:addHarvestJob(), self:addTrailer(capacity or 15000),
            self.data, 3)
    end

    return world, tc
end

local function rolls(values)
    local i = 0
    return function()
        i = i + 1
        return values[i] or 0.5
    end
end

-- Where -------------------------------------------------------------------------------

test("the heap goes just past the trailer's top, and the site round it", function()
    setup()
    -- Its wheels at x = -0.5, its top 3.5 m east at x = 3.
    local plan = TheContractorCropSpill.planSpill({ x = -0.5, z = 0, dirX = 0, dirZ = 1, sideX = 1, sideZ = 0 },
        { length = 9, height = 3.5 })
    assertNear(plan.heapStartX, 4.5, 1e-9, "1.5 m past its top")
    assertNear(plan.heapEndX, 4.5, 1e-9)
    assertNear(plan.heapStartZ, -3.6, 1e-9, "along most of its length")
    assertNear(plan.heapEndZ, 3.6, 1e-9)
    assertNear(plan.x, 4.5, 1e-9, "the site on the heap")
    assertNear(plan.z, 0, 1e-9)
    assertNear(plan.radius, 3.6 + 8, 1e-9, "8 m past the heap's ends")
end)

-- How much ------------------------------------------------------------------------------

test("90% of the trailer's capacity for the crop, at most 12,000 l", function()
    local world = setup()
    assertNear(TheContractorCropSpill.getSpillLiters(10000), 9000, 1e-9)
    assertEquals(TheContractorCropSpill.getSpillLiters(30000), 12000)

    local trailer = world:addVehicle({ fillUnits = { { capacity = 400, supported = { FillType.DIESEL } },
        { capacity = 8000, supported = { FillType.WHEAT, FillType.POTATO } } } })
    assertEquals(TheContractorCropSpill.getCapacity(trailer, FillType.WHEAT), 8000)
    assertEquals(TheContractorCropSpill.getCapacity(trailer, FillType.SEEDS), 0)
end)

test("tipping: a heap kept off vehicles, then without, then spread wide, each taking what's left", function()
    local world = setup()
    g_terrainNode = {}
    getTerrainHeightAtWorldPos = function() return 10 end
    world.tipCalls = {}
    -- How much each step's calls can put down in all (5000 l a call at
    -- most), keyed innerRadius/occlusion.
    world.capacityLeft = { ["0/true"] = 0, ["0/false"] = 0, ["10/false"] = 100000 }
    DensityMapHeightUtil = {
        tipToGroundAroundLine = function(vehicle, delta, fillTypeIndex, sx, sy, sz, ex, ey, ez, innerRadius, radius,
                                         lineOffset, limitToLineHeight, occlusionAreas, useOcclusionAreas)
            table.insert(world.tipCalls, { innerRadius = innerRadius, radius = radius,
                useOcclusionAreas = useOcclusionAreas, sy = sy })
            local key = innerRadius .. "/" .. tostring(useOcclusionAreas)
            local dropped = math.min(delta, 5000, world.capacityLeft[key])
            world.capacityLeft[key] = world.capacityLeft[key] - dropped
            return dropped, lineOffset + 1
        end,
    }
    local plan = TheContractorCropSpill.planSpill(world.data, { length = 9, height = 3.5 })

    local tipped, reach = world.realTipHeap(FillType.WHEAT, 12000, plan)
    assertEquals(tipped, 12000, "all of it, spread wide")
    assertEquals(reach, 40)
    assertEquals(world.tipCalls[1].useOcclusionAreas, true, "kept off vehicles first")
    assertEquals(world.tipCalls[1].innerRadius, 0)
    assertEquals(world.tipCalls[1].sy, 10, "on the ground")
    assertEquals(world.tipCalls[2].useOcclusionAreas, false)
    assertEquals(world.tipCalls[3].innerRadius, 10, "Easy Dev Controls' spread")
    assertEquals(world.tipCalls[3].radius, 40)

    -- Part of it by the trailer, the rest spread wide.
    world.tipCalls = {}
    world.capacityLeft = { ["0/true"] = 3000, ["0/false"] = 0, ["10/false"] = 100000 }
    tipped, reach = world.realTipHeap(FillType.WHEAT, 7000, plan)
    assertEquals(tipped, 7000)
    assertEquals(reach, 40)

    -- All of it by the trailer: no wider steps.
    world.tipCalls = {}
    world.capacityLeft = { ["0/true"] = 100000, ["0/false"] = 0, ["10/false"] = 0 }
    tipped, reach = world.realTipHeap(FillType.WHEAT, 7000, plan)
    assertEquals(tipped, 7000)
    assertEquals(reach, 6)
    for _, call in ipairs(world.tipCalls) do
        assertEquals(call.innerRadius, 0, "never spread wide")
    end
end)

test("the site reaches as far as the crop can have spread", function()
    setup()
    local plan = TheContractorCropSpill.planSpill({ x = -0.5, z = 0, dirX = 0, dirZ = 1, sideX = 1, sideZ = 0 },
        { length = 9, height = 3.5 })
    assertNear(TheContractorCropSpill.getSiteRadius(plan, 0), plan.radius, 1e-9, "at least the planned site")
    assertNear(TheContractorCropSpill.getSiteRadius(plan, 40), 3.6 + 40, 1e-9, "the heap's ends and the spread")
end)

-- The job --------------------------------------------------------------------------------

test("the spill: tipped, and an urgent job accepted and allocated to the farm's players at once", function()
    local world, tc = setup()
    local job = world:spill(10000)
    assertTrue(job ~= nil, "a spill job")

    local tip = world.tipped[1]
    assertEquals(tip.fillTypeIndex, FillType.WHEAT, "the harvest job's crop")
    assertNear(tip.liters, 9000, 1e-9)

    assertEquals(job.jobType, "spillRecovery")
    assertEquals(job.fieldId, 12)
    assertEquals(job.fruitTypeName, "WHEAT")
    assertEquals(job:getPrice(), 0, "for nothing")
    assertEquals(job.deadlineDay, 25, "the end of tomorrow")
    assertEquals(job.state, TheContractorJob.STATE.ALLOCATED, "no choice")
    assertEquals(job.assignedWorkerId, nil, "the farm's players")
    assertEquals(#job.assignedEquipmentIds, 0)
    assertEquals(world.called("dispatch"), nil, "nothing dispatched")
    assertTrue(job:needsPlayerDelivery())
    assertEquals(job.deliveryStationName, "Grain Mill", "to the customer's selling point")
    assertNear(job.requiredLiters, 7200, 1e-9, "80% of what was spilt")
    assertEquals(job.deliveredLiters, 0)
    assertTrue(TheContractorJobGeneration.isPlayerOnly(job))
    assertEquals(world.called("prepareField").spill, true, "field preparation leaves the field alone")

    local spill = job.spill
    assertEquals(spill.fillTypeName, "WHEAT")
    assertNear(spill.liters, 9000, 1e-9)
    assertNear(spill.pricePerLiter, 0.4, 1e-9)
    assertEquals(spill.sourceJobId, 7)
    assertEquals(spill.incidentId, 3)
    assertEquals(spill.reputationPenalty, 20, "the minimum for a small field")
    assertEquals(job:getLocationText(), "12", "on its field")

    -- The urgent notification as it arrived.
    local notification = world.notifications[1]
    assertEquals(notification.type, "critical")
    assertEquals(notification.text,
        "Urgent: Wheat spilt in Field 12. Deliver 7200 l of it to Grain Mill by the end of tomorrow.")
    assertEquals(TheContractorJobs.getUnallocateProblem(job), "tc_unallocate_problemSpill", "it's theirs to clear")
end)

test("the amount on the job is what actually landed", function()
    local world = setup()
    world.landed = 6000
    local job = world:spill(10000)
    assertNear(job.spill.liters, 6000, 1e-9)
    assertNear(job.requiredLiters, 4800, 1e-9)
end)

test("a missed spill costs twice the harvest job's reputation", function()
    local world = setup()
    world.harvestJob = world:addHarvestJob()
    world.fields[12].getAreaHa = function() return 10 end
    local job = world:spill(10000)
    local base = TheContractorJobs.getBaseReputationReward(world.harvestJob)
    assertTrue(base * 2 > 20, "more than the minimum")
    assertEquals(job.spill.reputationPenalty, math.floor(base * 2))
end)

test("no spill: no crop, one that can't lie on the ground, nowhere to take it, or next to nothing landing", function()
    local world, tc = setup()
    world.canTip = false
    assertEquals(world:spill(), nil, "can't be tipped")
    world.canTip = true

    world.harvestJob = world:addHarvestJob()
    world.harvestJob.fruitTypeName = nil
    assertEquals(world:spill(), nil, "no crop")
    world.harvestJob.fruitTypeName = "WHEAT"

    world.harvestJob.deliveryStationUniqueId = nil
    assertEquals(world:spill(), nil, "nowhere takes it")
    world.bestStation = world.station
    assertTrue(world:spill() ~= nil, "the best-paying selling point instead")

    world.landed = 100
    assertEquals(world:spill(), nil, "next to nothing landed")
    assertTrue(string.find(world.warnings[#world.warnings], "only 100 of 12000 l of WHEAT", 1, true) ~= nil,
        "always says why: " .. world.warnings[#world.warnings])
    assertEquals(world:spill(100), nil, "next to no room in the trailer")
end)

test("the job type: player only, never generated, nothing to equip, no reward or job events", function()
    setup()
    local jobDef = TheContractorJobGeneration.JOB_TYPES.spillRecovery
    assertTrue(jobDef.playerOnly and jobDef.noEquipment and jobDef.deliveryOnly and jobDef.serverMeasured)
    assertTrue(jobDef.spill and jobDef.noReward and jobDef.noJobEvents)
    for _, key in ipairs(TheContractorJobGeneration.JOB_TYPE_KEYS) do
        assertTrue(key ~= "spillRecovery", "never generated")
    end
    assertEquals(TheContractorRandomEvents.canHaveJobEvents({ jobType = "spillRecovery" }), false)
    assertEquals(TheContractorRandomEvents.canHaveJobEvents({ jobType = "harvest" }), true)
end)

-- Done ---------------------------------------------------------------------------------

test("done once 80% is delivered, from wherever", function()
    local world = setup()
    local job = world:spill(10000)
    job.deliveredLiters = 3600
    assertNear(TheContractorCropSpill.getCompletion(job), 0.5, 1e-9)
    assertEquals(TheContractorCropSpill.getStatusText(job), "Urgent: 50% delivered")
    job.deliveredLiters = 7200
    assertNear(TheContractorCropSpill.getCompletion(job), 1, 1e-9)
    assertEquals(TheContractorCropSpill.getStatusText(job), "Urgent: 100% delivered")
end)

test("done: no pay, no invoice, no reputation, and what's left of it cleared away", function()
    local world, tc = setup()
    local job = world:spill(10000)
    job.deliveredLiters = 7200
    job.completionPercentage = 100
    tc.Jobs:completeJob(job)

    assertEquals(job.state, TheContractorJob.STATE.COMPLETED)
    assertEquals(job.paymentAmount, 0)
    assertEquals(world.reputation[1], 0, "nothing for putting it right")
    assertEquals(world.cleared[1], job.id, "the site cleared")
    assertTrue(not TheContractorCropSpill.isOnSite(1, 0, 0), "no longer theirs to work")
end)

-- Missed ---------------------------------------------------------------------------------

test("missed: the whole reputation penalty, whatever was delivered, and the site cleared", function()
    local world, tc = setup()
    local job = world:spill(10000)
    job.deliveredLiters = 5000
    job.completionPercentage = 69
    tc.CropSpill:setForcedClaim(false)
    tc.Jobs:missJob(job)

    assertEquals(job.state, TheContractorJob.STATE.MISSED)
    assertEquals(world.reputation[1], -20)
    assertEquals(world.cleared[1], job.id)
    assertEquals(world.called("claim"), nil, "no claim this time")
    assertEquals(#world.messages, 0)
end)

test("a claim for the crop that never arrived and the farmer's clear-up, insured or not", function()
    local world, tc = setup()
    local job = world:spill(10000)
    job.deliveredLiters = 4000
    tc.CropSpill:onJobMissed(job, rolls({ 0.2 }))

    local cleanup = tc.Settings:scaleCost(TheContractorCropSpill.CLEANUP_COST)
    local expected = math.floor(5000 * 0.4 + cleanup)
    local claim = world.called("claim")
    assertEquals(claim.amount, expected)
    assertEquals(claim.insured, false)
    assertEquals(world.called("claimLogged").claim.cause, "cropSpill")
    local message = world.messages[1]
    assertEquals(message.kind, "cropSpill")
    assertEquals(message.bodyKey, "tc_spill_claimBodyUninsured")
    assertEquals(message.args[2], "$money_" .. expected)
    assertEquals(message.args[3], "$money_" .. expected, "the lot, uninsured")

    world.insured = true
    world.messages = {}
    tc.CropSpill:onJobMissed(job, rolls({ 0.2 }))
    assertEquals(world.messages[1].bodyKey, "tc_spill_claimBodyInsured")
    assertEquals(world.messages[1].args[3], "$money_500", "the excess")

    world.messages = {}
    tc.CropSpill:onJobMissed(job, rolls({ 0.7 }))
    assertEquals(#world.messages, 0, "half the time there's no claim")
end)

test("the console's forced claim is read once", function()
    local world, tc = setup()
    local job = world:spill(10000)
    tc.CropSpill:setForcedClaim(true)
    tc.CropSpill:onJobMissed(job, rolls({ 0.9 }))
    assertEquals(#world.messages, 1, "forced")
    tc.CropSpill:onJobMissed(job, rolls({ 0.9 }))
    assertEquals(#world.messages, 1, "then back to the roll")
end)

-- Land access ------------------------------------------------------------------------------

test("while it's open, the site is the farm's to shovel, tip and level on, and only theirs", function()
    local world, tc = setup()
    local job = world:spill(10000)
    tc.CropSpill:update(TheContractorCropSpill.SITE_REFRESH_MS)
    -- The heap at x = 4.5, the site 11.6 m round it.
    assertTrue(TheContractorCropSpill.isOnSite(1, 4.5, 0), "the heap")
    assertTrue(TheContractorCropSpill.isOnSite(1, 4.5, 10), "by the end of it")
    assertTrue(not TheContractorCropSpill.isOnSite(1, 4.5, 15), "too far")
    assertTrue(not TheContractorCropSpill.isOnSite(2, 4.5, 0), "another farm's")

    local loader = { getActiveFarm = function() return 1 end }
    assertTrue(Shovel.getCanShovelAtPosition(loader, { node = { x = 4.5, z = 0 }, width = 2 }), "the shovel")
    assertTrue(not Shovel.getCanShovelAtPosition(loader, { node = { x = 4.5, z = 40 }, width = 2 }))
    assertTrue(Dischargeable.getCanDischargeToLand(loader, { info = { node = { x = 6, z = 0 }, width = 1,
        zOffset = 0 } }), "tipping to the ground")
    assertTrue(FarmlandManager:getCanAccessLandAtWorldPosition(1, 4.5, 5), "the leveler")
    assertTrue(not FarmlandManager:getCanAccessLandAtWorldPosition(2, 4.5, 5))
    local otherFarm = { getActiveFarm = function() return 2 end }
    assertTrue(not Shovel.getCanShovelAtPosition(otherFarm, { node = { x = 4.5, z = 0 }, width = 2 }))

    world.vanillaAccess = true
    assertTrue(Shovel.getCanShovelAtPosition(otherFarm, { node = { x = 4.5, z = 0 }, width = 2 }),
        "vanilla's answer still counts")
    world.vanillaAccess = false

    job.state = TheContractorJob.STATE.MISSED
    TheContractorCropSpill.refreshSites()
    assertTrue(not TheContractorCropSpill.isOnSite(1, 4.5, 0), "gone once it's over")
end)

-- Save and stream ---------------------------------------------------------------------------

test("the spill goes through the save and the stream with its job", function()
    local world, tc = setup()
    local job = world:spill(10000)

    local stream = world:newStream()
    TheContractorJobs.writeJob(stream, job)
    local copy = TheContractorJobs.readJob(stream)
    assertTrue(copy.spill ~= nil, "streamed")
    for _, name in ipairs({ "fillTypeName", "liters", "x", "z", "radius", "pricePerLiter", "reputationPenalty",
        "sourceJobId", "incidentId" }) do
        assertEquals(copy.spill[name], job.spill[name], name)
    end

    local xmlFile = {}
    tc.Jobs:saveToXmlFile(xmlFile)
    local loaded = TheContractorJobs.new()
    loaded:loadFromXMLFile(xmlFile)
    local saved = loaded:getJob(1, job.id)
    assertTrue(saved.spill ~= nil, "saved")
    assertEquals(saved.spill.fillTypeName, "WHEAT")
    assertNear(saved.spill.radius, job.spill.radius, 1e-9)
    assertEquals(saved.spill.reputationPenalty, 20)
    assertEquals(loaded:getJob(1, 7).spill, nil, "another job has none")

    local plain = world:newStream()
    TheContractorCropSpill.writeStream(plain, nil)
    assertEquals(TheContractorCropSpill.readStream(plain), nil)
end)

test("the urgent notification is only for the farm's own players", function()
    local world = setup()
    g_currentMission.getFarmId = function() return 2 end
    world:spill(10000)
    assertEquals(#world.notifications, 0)
end)
