-- 126: selling a load for a farmer, end to end. The offer (the farmer's the
-- customer, the reason and the load on the job, a haulage job to the
-- station), accepting it (allocated to the farm's players, the farmer's
-- trailer out full through 100's queue with no ADS), the load tipped at the
-- station through 035's tracker (only the fee paid), the trailer collected
-- once it's unhitched and nobody's near, a miss with the grain taken (a
-- claim, and far more lost) and one with it still in the trailer, the
-- stream, and a load (the trailer sent for again). The real Jobs, Job,
-- JobGeneration, Allocation, RepairContracts, Farmers, FarmerFleet,
-- FieldBreakdowns, Relationships, TCHaulage, YardBales and YardHaul, with
-- vehicle loading, the station, the yard's ground and the rest of the mod
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
    VehiclePropertyState = { OWNED = 1, MISSION = 4 }
    VehicleLoadingState = { OK = 1 }
    MathUtil = { getYRotationFromDirection = function(x, z) return math.atan2(x, z) end }
    g_terrainNode = 1
    getTerrainHeightAtWorldPos = function() return 0 end
    getWorldTranslation = function(node)
        return node.x or 0, 0, node.z or 0
    end
    localDirectionToWorld = function() return 0, 0, 1 end
    g_currentMission.environment = {
        currentYear = 1, currentPeriod = 3, currentDayInPeriod = 4, daysPerPeriod = 10, plannedDaysPerPeriod = 10,
        currentMonotonicDay = 24, dayTime = 36000000,
        getPeriodFromDay = function() return 3 end,
        getDayInPeriodFromDay = function(_, day) return day - 20 end,
    }
    g_farmManager.getFarmById = function(_, farmId) return { farmId = farmId } end
    TheContractorNegotiation = { rollInitialEagerness = function() return 1 end }
    TCJobConsequences = {
        saveToXML = function() end,
        loadFromXML = function() end,
        writeReports = function() end,
        readReports = function() return {} end,
        applyOnCompletion = function() end,
    }
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
    world.barley = world:addFillType("BARLEY", "Barley")

    -- Wheat on Tom's field.
    FruitType = { UNKNOWN = 0, WHEAT = 2 }
    g_fruitTypeManager = {
        getFruitTypeByIndex = function(_, index)
            return index == FruitType.WHEAT and { index = index, name = "WHEAT" } or nil
        end,
        getFillTypeIndexByFruitTypeIndex = function(_, index)
            return index == FruitType.WHEAT and FillType.WHEAT or nil
        end,
    }

    -- The Grain Mill buys wheat and barley. A load tipped there goes to the
    -- matching tracker with the highest completion above 0, as
    -- SellingStation:addFillLevelFromTool does, else it's sold (world.sold).
    world.station = { missions = {}, rootNode = { x = 2000, z = 0 }, getName = function() return "Grain Mill" end }
    function world.station:getEffectiveFillTypePrice(fillTypeIndex)
        return 0.5
    end
    world.station.owningPlaceable = { getUniqueId = function() return "mill" end }
    g_currentMission.placeableSystem = {
        placeables = {},
        getPlaceableByUniqueId = function(_, uniqueId)
            return uniqueId == "mill" and world.station.owningPlaceable or nil
        end,
    }
    g_currentMission.storageSystem.getPlaceableUnloadingStation = function() return world.station end
    g_currentMission.storageSystem.getPlaceableUnloadingStationIndex = function() return 1 end
    HarvestMission = { getSellingStationWithHighestPrice = function() return world.station end }
    world.sold = {}
    function world:sell(fillTypeIndex, farmId, liters)
        local best, bestCompletion = nil, 0
        for _, mission in pairs(self.station.missions) do
            if mission.fillTypeIndex == fillTypeIndex and mission.farmId == farmId and
                    mission:getCompletion() > bestCompletion then
                best, bestCompletion = mission, mission:getCompletion()
            end
        end
        if best ~= nil then
            best:fillSold(liters)
        else
            table.insert(self.sold, liters)
        end
    end

    -- The store: a trailer that carries wheat and barley, 20,000 l.
    world.models = {
        { xml = "trailer.xml", category = "TRAILERS", width = 2.5, length = 8 },
    }
    g_storeManager = {
        getItems = function() return {} end,
        getItemByXMLFilename = function(_, xml)
            for _, model in ipairs(world.models) do
                if model.xml == xml then
                    return { xmlFilename = model.xml, categoryName = model.category, name = model.xml }
                end
            end
            return nil
        end,
    }
    g_vehicleTypeManager = { getObjectTypeFromXML = function() return { specializationsByName = {} } end }
    StoreItemUtil = {
        getSizeValues = function(xml)
            for _, model in ipairs(world.models) do
                if model.xml == xml then
                    return { width = model.width, length = model.length, height = 3, widthOffset = 0, lengthOffset = 0 }
                end
            end
            return {}
        end,
    }
    world.spawned, world.deleted = {}, {}
    world.trailerCapacity = 20000
    VehicleLoadingData = {
        new = function()
            local data = {}
            function data:setStoreItem(storeItem) self.storeItem = storeItem end
            function data:setIgnoreShopOffset() end
            function data:setPosition(x, y, z) self.x, self.z = x, z end
            function data:setRotation(_, ry) self.rotY = ry end
            function data:setPropertyState(state) self.propertyState = state end
            function data:setOwnerFarmId(farmId) self.farmId = farmId end
            function data:load(callback, target, args)
                self.callback, self.target, self.args = callback, target, args
                table.insert(world.spawned, self)
            end
            return data
        end,
    }
    function world:finishLoad()
        local data = self.spawned[#self.spawned]
        local vehicle = self:addVehicle({ name = data.storeItem.xmlFilename, farmId = data.farmId,
            fillUnits = { { capacity = self.trailerCapacity, supported = { FillType.WHEAT, world.barley } } } })
        vehicle.propertyState = data.propertyState
        vehicle.rootNode = { x = data.x, z = data.z }
        function vehicle:getFullName() return self.name end
        function vehicle:getUniqueId() return "vehicle" .. self.id end
        function vehicle:getAttacherVehicle() return self.attacher end
        function vehicle:delete()
            self.isDeleted = true
            table.insert(world.deleted, self.id)
        end
        data.callback(data.target, { vehicle }, VehicleLoadingState.OK, data.args)
        return vehicle
    end
    TCJobSiteSetup = { hitchImplement = function() return true end }
    TCParking = { PLACE_HEIGHT_OFFSET = 0.3, DEFAULT_HEIGHT = 4, isAreaClear = function() return true end }
    TCParkingSlotFilter = { getCategoryTitle = function(name) return name end }

    -- Tom's yard on farmland 50: its middle at (0, 0), one spot 30 m north;
    -- the ground's all open. His field (wheat) is farmland 4.
    TheContractorYards = { isOpenGround = function() return true end }
    g_farmlandManager = { getFarmlandOwner = function() return 0 end }
    local farmland = { getId = function() return 4 end }
    world.field = { id = 4 }
    function world.field:getId() return 4 end
    function world.field:getName() return "4" end
    function world.field:getFarmland() return farmland end
    function world.field:getCenterOfFieldWorldPosition() return 200, 0 end
    function world.field:getAreaHa() return 2 end
    function world.field:getOwner() return 0 end
    function world.field:getFieldState() return { fruitTypeIndex = FruitType.WHEAT } end
    g_fieldManager = {
        getFields = function() return { world.field } end,
        getFieldById = function(_, fieldId) return fieldId == 4 and world.field or nil end,
    }

    world:load("src/util/TCVehicleIds.lua")
    world:load("src/util/TCJoyriderRuts.lua")
    world:load("src/placeables/PlaceableTCParkingSlot.lua")
    world:load("src/placeables/PlaceableTCRepairZone.lua")
    world:load("src/util/TCADSRepairContracts.lua")
    world:load("src/business/Job.lua")
    world:load("src/business/Jobs.lua")
    world:load("src/business/YardBales.lua")
    world:load("src/business/YardHaul.lua")
    world:load("src/business/EmergencyRefuel.lua")
    world:load("src/business/CropSpill.lua")
    world:load("src/business/JobGeneration.lua")
    world:load("src/util/TCEquipmentClass.lua")
    world:load("src/business/Allocation.lua")
    world:load("src/business/Settings.lua")
    world:load("src/business/RandomEvents.lua")
    TCJobProgress = { POLL_INTERVAL_MS = 3000, clearJob = function() end }
    world:load("src/util/TCHaulage.lua")
    world:load("src/business/RepairContracts.lua")
    world:load("src/business/FieldBreakdowns.lua")
    world:load("src/business/Farmers.lua")
    world:load("src/business/FarmerFleet.lua")
    TCHaulage.emptyHarvestersAfterJob = function() end
    TCFieldPreparation = { prepareFieldForJob = function() end, clearUpAfterJob = function() end }
    TCFieldAccess = { refresh = function() end }
    TCJobSupplies = { topUp = function() end }
    TCJobAllocatedEvent = { new = function(job) return { job = job } end }
    TCJobMissedEvent = { showNotification = function() end }
    TCJobCompletedEvent = { showNotification = function() end }
    AIMessageSuccessFinishedJob = { new = function() return {} end }
    AIMessageSuccessStoppedByUser = { new = function() return {} end }
    world.players = {}
    TheContractorFallenTree = { getPlayerPositions = function() return world.players end }
    TheContractorJobGeneration.isGrass = function() return false end
    -- The trailer as the store describes it.
    TheContractorYardHaul.getTrailerSpec = function(xml)
        return xml == "trailer.xml" and
            { capacity = 20000, fillTypes = { [FillType.WHEAT] = true, [world.barley] = true } } or nil
    end
    -- No ADS at all.
    TCADSRepairContracts.getEnv = function() return nil end
    TCADSRepairContracts.detect()

    local tc = g_currentMission.TheContractor
    tc.Settings = TheContractorSettings.new()
    tc.Jobs = TheContractorJobs.new()
    tc.Allocation = TheContractorAllocation.new()
    tc.RandomEvents = TheContractorRandomEvents.new()
    tc.RepairContracts = TheContractorRepairContracts.new()
    tc.Yards = { getSpots = function(_, farmlandId)
        return farmlandId == 50 and { x = 0, z = 0, spots = { { x = 0, z = 30 } } } or nil
    end }
    tc.Staff = { getWorker = function() return nil end, applyGrowthFromJob = function() end }
    tc.Dispatch = {
        isJobActive = function() return false end,
        stopJob = function() end,
        takeRanOutOfFill = function() end,
    }
    tc.Cooldown = { startCooldown = function() end }
    tc.Parking = { returnVehicles = function() end, returnHiddenVehicles = function() end,
        isPending = function() return false end, sendToShop = function() return {} end }
    world:addRelationships()
    world.reputation = {}
    tc.Reputation = {
        addReputation = function(_, farmId, delta) table.insert(world.reputation, delta) end,
        getStanding = function() return 0.5 end,
    }
    world.invoiced = {}
    tc.Finances = { invoiceJob = function(_, job) table.insert(world.invoiced, job.paymentAmount) end }
    tc.Association = { getReputationBonus = function() return 0 end }
    world.claims, world.claimLogs = {}, {}
    tc.Claims = {
        rollForJob = function() end,
        chargeClaim = function(_, farmId, amount, insured)
            table.insert(world.claims, { farmId = farmId, amount = amount, insured = insured })
            return amount
        end,
        addToJobLog = function(_, farmId, jobId, claim)
            table.insert(world.claimLogs, { jobId = jobId, claim = claim })
        end,
    }
    tc.Logbook = { recordJobCompleted = function() end, recordJobMissed = function() end,
        onCrewChanged = function() end, onWorkStarted = function() end }
    world.messages, world.messageKinds = {}, {}
    tc.Inbox = {
        registerMessageKind = function(_, kind, definition) world.messageKinds[kind] = definition end,
        postMessage = function(_, farmId, kind, titleKey, bodyKey, args, actions, payload)
            table.insert(world.messages, { kind = kind, bodyKey = bodyKey, args = args, payload = payload })
        end,
        removeMessagesForJob = function() end,
    }

    TheContractorFarmerSplit = { getFieldFarmlands = function() return { { id = 4, x = 200, z = 0, acres = 30 } } end }
    tc.Farmers = TheContractorFarmers.new()
    tc.Farmers.people[4] = { id = 4, name = "Tom Hargreaves", isOfficial = false, farmlandIds = { 4 },
        yardFarmlandId = 50, machines = {
            { id = 3, role = "trailer", xmlFilename = "trailer.xml", seed = 9, fitted = {} },
        } }

    tc.YardBales = TheContractorYardBales.new()
    tc.YardHaul = TheContractorYardHaul.new()
    world.definitions = {}
    local randomEvents = {}
    function randomEvents:registerEventType(key, definition) world.definitions[key] = definition end
    tc.YardBales:register(randomEvents, tc.Inbox)
    tc.YardHaul:register(randomEvents, tc.Inbox)
    world.definition = world.definitions.yardHaul

    function world:offer()
        local data = self.definition.canTrigger(1)
        assertTrue(data ~= nil, "the farmer asks")
        self.definition.stages[1].run({ id = 1, farmId = 1, data = data })
        return tc.Jobs:getAllJobs(1)[1]
    end

    -- Accepted, and the trailer out.
    function world:acceptAndBringTrailer(job)
        tc.Jobs:transitionJobState(1, job.id, TheContractorJob.STATE.ACCEPTED)
        tc.RepairContracts:update(TheContractorRepairContracts.PLACE_CHECK_MS)
        return self:finishLoad()
    end

    -- The progress sweep (TCJobProgress, faked here) and the completion
    -- check after it.
    function world:measure(job)
        job.completionPercentage = 100 * TheContractorYardHaul.getCompletion(job)
        tc.Jobs:checkForCompletions()
    end

    return world, tc
end

-- The trailer's tipped at the station: liters out of it, through the station.
local function tip(world, trailer, liters)
    trailer.fillUnits[1].level = trailer.fillUnits[1].level - liters
    world:sell(FillType.WHEAT, 1, liters)
end

test("the offer: the farmer's the customer, a haulage job to the selling point, the reason kept, the trailer held", function()
    local world, tc = setup()
    local job = world:offer()
    assertEquals(job.jobType, TheContractorYardHaul.JOB_TYPE)
    assertEquals(job.customerId, 4)
    assertEquals(job.fieldId, 4, "the farmer's field only says where it is")
    assertEquals(job.state, TheContractorJob.STATE.OFFERED)
    assertTrue(job.includesHaulage)
    assertEquals(job.deliveryStationUniqueId, "mill")
    assertTrue(job.deadlineDay - g_currentMission.environment.currentMonotonicDay >= 2)
    local haul = job.yardHaul
    assertEquals(haul.farmerId, 4)
    assertEquals(haul.yardFarmlandId, 50)
    assertEquals(haul.fillTypeName, "WHEAT", "the crop on the farmer's field")
    assertEquals(haul.machineId, 3)
    assertEquals(haul.x, 0)
    assertEquals(haul.z, 30)
    assertTrue(haul.liters >= 18000 and haul.liters <= 20000)

    local message = world.messages[1]
    assertEquals(message.kind, TheContractorYardHaul.MESSAGE_KIND)
    assertEquals(message.bodyKey, "tc_yardHaul_offerBody_" .. haul.reason)
    assertEquals(message.args[1], "$volume_" .. haul.liters)
    assertEquals(message.args[3], "Grain Mill")
    assertEquals(message.payload.jobId, job.id)
    assertTrue(world.messageKinds.yardHaul.endsWithJob)

    assertEquals(#world.spawned, 0, "nothing's out until it's accepted")
    assertTrue(TheContractorFarmerFleet.isMachineOut(4, 3))
    assertEquals(world.definition.canTrigger(1), nil, "one at a time")
end)

test("accepted: the player's at once, the trailer comes out to its spot full, and the station's counting", function()
    local world, tc = setup()
    local job = world:offer()
    local trailer = world:acceptAndBringTrailer(job)
    local haul = job.yardHaul
    assertEquals(job.state, TheContractorJob.STATE.ALLOCATED)
    assertEquals(world.spawned[1].storeItem.xmlFilename, "trailer.xml")
    assertEquals(world.spawned[1].propertyState, VehiclePropertyState.MISSION)
    assertEquals(world.spawned[1].farmId, 1, "the player's farm, so the sale's routed to the job")
    assertEquals(trailer.fillUnits[1].level, haul.liters)
    assertEquals(trailer.fillUnits[1].fillType, FillType.WHEAT)
    assertEquals(haul.trailerVehicleId, trailer.id)
    assertTrue(haul.filled)
    assertEquals(job.requiredLiters, haul.liters * TCHaulage.DELIVERY_SUCCESS_FACTOR)
    assertTrue(next(world.station.missions) ~= nil, "the tracker's at the station")
    assertTrue(TheContractorRepairContracts.isContractVehicle(trailer), "not the farm's to sell or list")
    assertTrue(not TheContractorRepairContracts.isWorkableVehicle(trailer, 1))
    assertEquals(#tc.RepairContracts.arrivals, 0)
end)

test("a smaller trailer than the store says: the load is what it holds, and what's to be delivered follows", function()
    local world, tc = setup()
    world.trailerCapacity = 15000
    local job = world:offer()
    local trailer = world:acceptAndBringTrailer(job)
    assertEquals(job.yardHaul.liters, 15000)
    assertEquals(trailer.fillUnits[1].level, 15000)
    assertEquals(job.requiredLiters, 15000 * TCHaulage.DELIVERY_SUCCESS_FACTOR)
end)

test("tipped at the station: the load goes to the job, it's done, and only the fee is paid", function()
    local world, tc = setup()
    local job = world:offer()
    local trailer = world:acceptAndBringTrailer(job)
    local haul = job.yardHaul

    tip(world, trailer, haul.liters / 2)
    world:measure(job)
    assertEquals(job.deliveredLiters, haul.liters / 2)
    assertEquals(job.state, TheContractorJob.STATE.ALLOCATED)

    tip(world, trailer, haul.liters / 2)
    world:measure(job)
    assertEquals(job.state, TheContractorJob.STATE.COMPLETED)
    assertEquals(world.invoiced[1], job:getPrice(), "the haulage fee")
    -- Only the share past the job's terms sold for the farm.
    assertEquals(#world.sold, 0)
    assertTrue(next(world.station.missions) == nil, "the tracker's gone")
    assertTrue(tc.Relationships:getScore(1, 4) > 0)
    assertTrue(world.reputation[1] > 0)
end)

test("collected once it's unhitched and nobody's near, not before", function()
    local world, tc = setup()
    local job = world:offer()
    local trailer = world:acceptAndBringTrailer(job)
    tip(world, trailer, job.yardHaul.liters)
    world:measure(job)
    assertEquals(job.state, TheContractorJob.STATE.COMPLETED)

    tc.YardHaul:update(TheContractorYardHaul.COLLECT_CHECK_MS)
    assertEquals(#tc.RepairContracts.removals, 1)
    assertTrue(tc.RepairContracts.removals[1].whenUnseen)

    -- Still on the player's tractor.
    trailer.attacher = { id = 99 }
    tc.RepairContracts:update(TheContractorRepairContracts.PLACE_CHECK_MS)
    assertTrue(not trailer.isDeleted)

    -- Unhitched, but the player's beside it.
    trailer.attacher = nil
    table.insert(world.players, { x = trailer.rootNode.x + 20, z = trailer.rootNode.z })
    tc.RepairContracts:update(TheContractorRepairContracts.PLACE_CHECK_MS)
    assertTrue(not trailer.isDeleted)

    -- And they've gone.
    world.players[1].x = trailer.rootNode.x + 500
    tc.RepairContracts:update(TheContractorRepairContracts.PLACE_CHECK_MS)
    assertTrue(trailer.isDeleted)
    assertTrue(not TheContractorFarmerFleet.isMachineOut(4, 3), "home again")
end)

test("the wait for the trailer to go unseen survives a save", function()
    local world, tc = setup()
    local job = world:offer()
    local trailer = world:acceptAndBringTrailer(job)
    tip(world, trailer, job.yardHaul.liters)
    world:measure(job)
    tc.YardHaul:update(TheContractorYardHaul.COLLECT_CHECK_MS)

    local xmlFile = {}
    tc.RepairContracts:saveToXmlFile(xmlFile)
    local loaded = TheContractorRepairContracts.new()
    loaded:loadFromXMLFile(xmlFile)
    assertTrue(loaded.removals[1].whenUnseen)
end)

test("the grain tipped elsewhere: at the deadline, a claim for it uninsured, and far more lost than a miss", function()
    local world, tc = setup()
    local job = world:offer()
    local trailer = world:acceptAndBringTrailer(job)
    local haul = job.yardHaul
    -- A quarter at the station, the rest into the farm's own silo.
    tip(world, trailer, haul.liters / 4)
    trailer.fillUnits[1].level = 0

    tc.Jobs:missJob(job)
    assertEquals(job.state, TheContractorJob.STATE.MISSED)
    assertEquals(haul.missingLiters, haul.liters * 3 / 4)
    assertEquals(#world.claims, 1)
    assertEquals(world.claims[1].amount, math.floor(haul.missingLiters * 0.5 + 0.5), "at the station's price")
    assertEquals(world.claims[1].insured, false)
    assertEquals(world.claimLogs[1].jobId, job.id)
    assertEquals(world.claimLogs[1].claim.cause, "grainTaken")
    local claimMessage = world.messages[#world.messages]
    assertEquals(claimMessage.kind, TheContractorYardHaul.CLAIM_KIND)
    assertEquals(claimMessage.payload.farmerId, 4)
    assertTrue(not world.messageKinds.yardHaulClaim.endsWithJob, "it outlives the job")

    -- The same miss with the grain still in the trailer, for comparison.
    local other, otherTc = setup()
    local otherJob = other:offer()
    local otherTrailer = other:acceptAndBringTrailer(otherJob)
    tip(other, otherTrailer, otherJob.yardHaul.liters / 4)
    otherTc.Jobs:missJob(otherJob)
    assertEquals(otherJob.yardHaul.missingLiters, 0)
    assertEquals(#other.claims, 0, "an ordinary miss")
    assertEquals(world.reputation[1], other.reputation[1] - TheContractorYardHaul.THEFT_REPUTATION)
    assertEquals(tc.Relationships:getScore(1, 4),
        otherTc.Relationships:getScore(1, 4) - TheContractorYardHaul.THEFT_RELATIONSHIP)
end)

test("a miss with the trailer still full is ordinary, and the trailer goes home", function()
    local world, tc = setup()
    local job = world:offer()
    local trailer = world:acceptAndBringTrailer(job)
    tc.Jobs:missJob(job)
    assertEquals(#world.claims, 0)
    assertTrue(tc.Relationships:getScore(1, 4) < 0)
    tc.YardHaul:update(TheContractorYardHaul.COLLECT_CHECK_MS)
    tc.RepairContracts:update(TheContractorRepairContracts.PLACE_CHECK_MS)
    assertTrue(trailer.isDeleted)
end)

test("a client gets the job, its load and its trailer", function()
    local world, tc = setup()
    local job = world:offer()
    local trailer = world:acceptAndBringTrailer(job)
    local stream = world:newStream()
    TheContractorJobs.writeJob(stream, job)
    local copy = TheContractorJobs.readJob(stream)
    assertEquals(copy.yardHaul.reason, job.yardHaul.reason)
    assertEquals(copy.yardHaul.liters, job.yardHaul.liters)
    assertEquals(copy.yardHaul.trailerVehicleId, trailer.id)
    assertEquals(copy.requiredLiters, job.requiredLiters)
    assertEquals(copy.deliveryStationName, "Grain Mill")
    assertEquals(copy:getLocationText(), job:getLocationText())
end)

test("a load: the trailer's kept by uniqueId, and a job taken on without it sends for it again", function()
    local world, tc = setup()
    local job = world:offer()
    tc.Jobs:transitionJobState(1, job.id, TheContractorJob.STATE.ACCEPTED)
    assertEquals(#tc.RepairContracts.arrivals, 1)
    assertEquals(tc.RepairContracts.arrivals[1].loanOwner, "YardHaul")

    local xmlFile = {}
    tc.RepairContracts:saveToXmlFile(xmlFile)
    assertTrue(not hasXMLProperty(xmlFile, "TheContractor.repairContracts.arrival(0)"), "not saved")
    tc.RepairContracts.arrivals = {}
    tc.YardHaul:resolveSavedVehicles()
    assertEquals(#tc.RepairContracts.arrivals, 1)
    assertEquals(tc.RepairContracts.arrivals[1].jobId, job.id)

    tc.RepairContracts:update(TheContractorRepairContracts.PLACE_CHECK_MS)
    local trailer = world:finishLoad()
    local saved = {}
    tc.Jobs:saveToXmlFile(saved)
    tc.Jobs = TheContractorJobs.new()
    tc.Jobs:loadFromXMLFile(saved)
    local loaded = tc.Jobs:getJob(1, job.id)
    assertTrue(loaded.yardHaul.filled)
    assertEquals(loaded.yardHaul.reason, job.yardHaul.reason)
    assertEquals(loaded.requiredLiters, job.requiredLiters)
    tc.YardHaul:resolveSavedVehicles()
    assertEquals(loaded.yardHaul.trailerVehicleId, trailer.id)
    assertEquals(#tc.RepairContracts.arrivals, 0)
end)

test("a declined offer never brings the trailer out, and frees it", function()
    local world, tc = setup()
    local job = world:offer()
    tc.Jobs:transitionJobState(1, job.id, TheContractorJob.STATE.DECLINED)
    tc.YardHaul:update(TheContractorYardHaul.COLLECT_CHECK_MS)
    assertEquals(#world.spawned, 0)
    assertEquals(#tc.RepairContracts.removals, 0)
    assertTrue(not TheContractorFarmerFleet.isMachineOut(4, 3))
end)
