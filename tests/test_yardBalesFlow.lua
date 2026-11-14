-- 124: bales to a farmer's yard, end to end. The offer (the farmer's the
-- customer, the area and the order on the job), accepting it (allocated to
-- the farm's players, the telehandler and its fork out through 100's queue
-- with no ADS), the bales delivered (taken, the excess invoiced, the job
-- done), the kit collected, a miss, and a load (the kit's loan isn't saved:
-- the job sends for it again). The real Jobs, Job, JobGeneration,
-- Allocation, RepairContracts, Farmers, FarmerFleet, FieldBreakdowns,
-- Relationships and YardBales, with vehicle loading, the yard's ground and
-- the rest of the mod faked.

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
    getLinearVelocity = function() return 0, 0, 0 end
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
    world.straw = world:addFillType("STRAW", "Straw")
    world:addFillType("DRYGRASS_WINDROW", "Hay")
    g_currentMission.economyManager.getPricePerLiter = function() return 0.25 end

    -- Bales.
    Bale = {}
    world.items = {}
    g_currentMission.itemSystem = {
        itemsToSave = world.items,
        getItemByUniqueId = function(_, uniqueId)
            local entry = world.items[uniqueId]
            return entry ~= nil and entry.item or nil
        end,
    }
    world.baleCount = 0
    function world:addBale(x, z)
        self.baleCount = self.baleCount + 1
        local bale = { fillType = world.straw, fillLevel = 4000, ownerFarmId = 1, nodeId = { x = x, z = z },
            uniqueId = "bale" .. self.baleCount }
        function bale:isa(class) return class == Bale end
        function bale:getOwnerFarmId() return self.ownerFarmId end
        function bale:setOwnerFarmId(farmId) self.ownerFarmId = farmId end
        function bale:setCanBeSold() end
        function bale:getUniqueId() return self.uniqueId end
        function bale:getIsMounted() return false end
        function bale:delete()
            self.isDeleted = true
            world.items[self.uniqueId] = nil
        end
        self.items[bale.uniqueId] = { item = bale }
        return bale
    end

    -- The store: a telehandler and a bale fork, neither of them ADS's.
    world.models = {
        { xml = "teli.xml", category = "TELELOADERVEHICLES", width = 2.5, length = 5 },
        { xml = "baleFork.xml", category = "TELELOADERTOOLS", width = 2, length = 1.5 },
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
    world.spawned, world.deleted, world.hitched = {}, {}, {}
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
        local vehicle = { name = data.storeItem.xmlFilename, propertyState = data.propertyState,
            farmId = data.farmId, rootNode = { x = data.x, z = data.z } }
        function vehicle:getFullName() return self.name end
        function vehicle:getUniqueId() return "vehicle" .. self.id end
        function vehicle:getOwnerFarmId() return self.farmId end
        function vehicle:delete()
            self.isDeleted = true
            table.insert(world.deleted, self.id)
        end
        self:register(vehicle)
        table.insert(g_currentMission.vehicleSystem.vehicles, vehicle)
        data.callback(data.target, { vehicle }, VehicleLoadingState.OK, data.args)
        return vehicle
    end
    TCJobSiteSetup = { hitchImplement = function(attacher, implement)
        table.insert(world.hitched, { attacher.id, implement.id })
        return true
    end }
    TCParking = { PLACE_HEIGHT_OFFSET = 0.3, DEFAULT_HEIGHT = 4, isAreaClear = function() return true end }
    TCParkingSlotFilter = { getCategoryTitle = function(name) return name end }

    -- Tom's yard on farmland 50: its middle at (0, 0), one spot 30 m north;
    -- the ground's all open. His field is farmland 4.
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
    function world.field:getFieldState() return { fruitTypeIndex = 0 } end
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
    world:load("src/util/TCLotInspections.lua")
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
    TheContractorFallenTree = { getPlayerPositions = function() return {} end }
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
    -- 129: a miss can leave the customer poor, so they complain.
    TCCalendar = { getPeriodIndex = function() return 1 end }
    world.reputation = {}
    tc.Reputation = {
        addReputation = function(_, farmId, delta) table.insert(world.reputation, delta) end,
        getStanding = function() return 0.5 end,
    }
    world.invoiced = {}
    tc.Finances = { invoiceJob = function(_, job) table.insert(world.invoiced, job.paymentAmount) end }
    tc.Association = { getReputationBonus = function() return 0 end }
    tc.Claims = { rollForJob = function() end }
    tc.Logbook = { recordJobCompleted = function() end, recordJobMissed = function() end,
        onCrewChanged = function() end }
    world.messages = {}
    tc.Inbox = {
        registerMessageKind = function(_, kind, definition) world.messageKind = definition end,
        postMessage = function(_, farmId, kind, titleKey, bodyKey, args, actions, payload)
            table.insert(world.messages, { kind = kind, bodyKey = bodyKey, args = args, payload = payload })
        end,
        removeMessagesForJob = function() end,
    }

    TheContractorFarmerSplit = {
        getFieldFarmlands = function() return { { id = 4, x = 200, z = 0, acres = 30 } } end,
        getFreeYards = function() return {} end,
    }
    tc.Farmers = TheContractorFarmers.new()
    tc.Farmers.people[4] = { id = 4, name = "Tom Hargreaves", isOfficial = false, farmlandIds = { 4 },
        yardFarmlandId = 50, machines = {
            { id = 1, role = "telehandler", xmlFilename = "teli.xml", seed = 7, fitted = {} },
            { id = 2, role = "baleFork", attachedTo = 1, xmlFilename = "baleFork.xml", seed = 8, fitted = {} },
        } }

    tc.YardBales = TheContractorYardBales.new()
    local randomEvents = {}
    function randomEvents:registerEventType(key, definition) world.definition = definition end
    tc.YardBales:register(randomEvents, tc.Inbox)

    -- Ten straw bales of the farm's, out of the way.
    world.bales = {}
    for i = 1, 10 do
        table.insert(world.bales, world:addBale(500 + i * 3, 500))
    end

    function world:offer()
        local data = self.definition.canTrigger(1)
        assertTrue(data ~= nil, "the farmer asks")
        self.definition.stages[1].run({ id = 1, farmId = 1, data = data })
        return tc.Jobs:getAllJobs(1)[1]
    end

    -- Accepted, and the telehandler and its fork out.
    function world:acceptAndBringKit(job)
        tc.Jobs:transitionJobState(1, job.id, TheContractorJob.STATE.ACCEPTED)
        tc.RepairContracts:update(TheContractorRepairContracts.PLACE_CHECK_MS)
        local telehandler = self:finishLoad()
        local fork = self:finishLoad()
        return telehandler, fork
    end

    return world, tc
end

local function updateYardBales(tc)
    tc.YardBales:update(TheContractorYardBales.COUNT_INTERVAL_MS)
end

test("the offer: the farmer's the customer, and the order and drop area are on the job, the kit held", function()
    local world, tc = setup()
    local job = world:offer()
    assertEquals(job.jobType, TheContractorYardBales.JOB_TYPE)
    assertEquals(job.customerId, 4)
    assertEquals(job.fieldId, 4, "the farmer's field only says where it is")
    assertEquals(job.state, TheContractorJob.STATE.OFFERED)
    assertEquals(job.deadlineDay - g_currentMission.environment.currentMonotonicDay >= 2, true)
    local yard = job.yardDelivery
    assertEquals(yard.farmerId, 4)
    assertEquals(yard.yardFarmlandId, 50)
    assertEquals(yard.fillTypeName, "STRAW")
    assertEquals(yard.x, 0)
    assertEquals(yard.z, 30)
    assertEquals(job.requiredLiters, yard.baleCount * 4000)
    assertEquals(job.workTotal, yard.baleCount)
    assertTrue(yard.baleCount >= 6 and yard.baleCount <= 7)

    local message = world.messages[1]
    assertEquals(message.kind, TheContractorYardBales.MESSAGE_KIND)
    assertEquals(message.payload.jobId, job.id)
    assertTrue(world.messageKind.endsWithJob)

    -- Nothing's out yet, but the telehandler's spoken for.
    assertEquals(#world.spawned, 0)
    assertTrue(TheContractorFarmerFleet.isMachineOut(4, 1))
    assertEquals(world.definition.canTrigger(1), nil, "one order at a time")
end)

test("accepted: the player's at once, and the telehandler comes out by the area with its fork on, no ADS", function()
    local world, tc = setup()
    local job = world:offer()
    local telehandler, fork = world:acceptAndBringKit(job)
    assertEquals(job.state, TheContractorJob.STATE.ALLOCATED)
    assertEquals(world.spawned[1].storeItem.xmlFilename, "teli.xml")
    assertEquals(world.spawned[1].propertyState, VehiclePropertyState.MISSION)
    assertEquals(world.spawned[2].storeItem.xmlFilename, "baleFork.xml")
    assertEquals(world.hitched[1][1], telehandler.id)
    assertEquals(world.hitched[1][2], fork.id)
    assertTrue(not TheContractorYardBales.isInArea(job.yardDelivery, telehandler.rootNode.x, telehandler.rootNode.z),
        "beside the area, not in it")
    assertEquals(job.yardDelivery.kitVehicleId, telehandler.id)
    assertEquals(job.yardDelivery.kitAttachmentId, fork.id)
    assertEquals(#tc.RepairContracts.arrivals, 0)
    assertTrue(TheContractorRepairContracts.isContractVehicle(telehandler), "not the farm's to sell or list")
    assertTrue(TheContractorRepairContracts.isContractVehicle(fork))
    assertTrue(not TheContractorRepairContracts.isWorkableVehicle(telehandler, 1), "nothing for a workshop")
end)

local function countDeleted(world, count)
    local deleted = 0
    for i = 1, count do
        if world.bales[i].isDeleted then
            deleted = deleted + 1
        end
    end
    return deleted
end

test("delivered: each bale goes as it's put down, the job's done at the order, and the kit goes home", function()
    local world, tc = setup()
    local job = world:offer()
    local telehandler, fork = world:acceptAndBringKit(job)
    local yard = job.yardDelivery

    -- All but one bale short of the order: delivered, gone, not done.
    for i = 1, yard.baleCount - 1 do
        world.bales[i].nodeId.x, world.bales[i].nodeId.z = yard.x + i - 3, yard.z
    end
    updateYardBales(tc)
    assertEquals(job.deliveredLiters, (yard.baleCount - 1) * 4000)
    assertEquals(countDeleted(world, yard.baleCount - 1), yard.baleCount - 1)
    assertEquals(job.state, TheContractorJob.STATE.ALLOCATED)

    -- One more, and a spare: just the order's taken, the spare stays.
    local last, spare = world.bales[yard.baleCount], world.bales[yard.baleCount + 1]
    last.nodeId.x, last.nodeId.z = yard.x, yard.z + 2
    spare.nodeId.x, spare.nodeId.z = yard.x, yard.z - 2
    updateYardBales(tc)
    assertEquals(job.state, TheContractorJob.STATE.COMPLETED)
    assertEquals(yard.takenBales, yard.baleCount)
    assertEquals(yard.excessLiters, 0)
    assertEquals(world.invoiced[1], job:getPrice())
    assertEquals(countDeleted(world, yard.baleCount + 1), yard.baleCount, "one bale over stays the farm's")

    -- The kit's collected on the next looks.
    updateYardBales(tc)
    assertEquals(#tc.RepairContracts.removals, 2)
    tc.RepairContracts:update(TheContractorRepairContracts.PLACE_CHECK_MS)
    assertTrue(telehandler.isDeleted and fork.isDeleted)
    assertTrue(not TheContractorFarmerFleet.isMachineOut(4, 1), "home again")
end)

test("going over by part of a bale takes the whole bale and pays the excess", function()
    local world, tc = setup()
    local job = world:offer()
    world:acceptAndBringKit(job)
    local yard = job.yardDelivery
    -- A smaller order than the bales come in: 1,000 l short of a whole bale.
    job.requiredLiters = yard.baleCount * 4000 - 1000
    for i = 1, yard.baleCount do
        world.bales[i].nodeId.x, world.bales[i].nodeId.z = yard.x + i - 3, yard.z
    end
    updateYardBales(tc)
    assertEquals(job.state, TheContractorJob.STATE.COMPLETED)
    assertEquals(yard.excessLiters, 1000)
    assertEquals(world.invoiced[1], job:getPrice() + TCEconomyScale.scale(1000 * yard.pricePerLiter))
end)

test("a part delivery survives a save: the order and what's in come back with the job", function()
    local world, tc = setup()
    local job = world:offer()
    world:acceptAndBringKit(job)
    local bale = world.bales[1]
    bale.nodeId.x, bale.nodeId.z = job.yardDelivery.x, job.yardDelivery.z
    updateYardBales(tc)
    local required = job.requiredLiters

    local xmlFile = {}
    tc.Jobs:saveToXmlFile(xmlFile)
    tc.Jobs = TheContractorJobs.new()
    tc.Jobs:loadFromXMLFile(xmlFile)
    local loaded = tc.Jobs:getJob(1, job.id)
    assertEquals(loaded.requiredLiters, required)
    assertEquals(loaded.deliveredLiters, 4000)
    assertEquals(loaded.yardDelivery.takenBales, 1)
end)

test("missed: what was delivered stays delivered, the kit goes home, and the farmer remembers", function()
    local world, tc = setup()
    local job = world:offer()
    local telehandler = world:acceptAndBringKit(job)
    local bale = world.bales[1]
    bale.nodeId.x, bale.nodeId.z = job.yardDelivery.x, job.yardDelivery.z
    updateYardBales(tc)
    assertTrue(bale.isDeleted)
    tc.Jobs:missJob(job)
    assertEquals(job.state, TheContractorJob.STATE.MISSED)
    assertTrue(tc.Relationships:getScore(1, 4) < 0)
    updateYardBales(tc)
    tc.RepairContracts:update(TheContractorRepairContracts.PLACE_CHECK_MS)
    assertTrue(telehandler.isDeleted)
end)

test("a load: the kit's loan isn't saved, and a job taken on without its kit sends for it again", function()
    local world, tc = setup()
    local job = world:offer()
    tc.Jobs:transitionJobState(1, job.id, TheContractorJob.STATE.ACCEPTED)
    assertEquals(#tc.RepairContracts.arrivals, 1)

    local xmlFile = {}
    tc.RepairContracts:saveToXmlFile(xmlFile)
    assertTrue(not hasXMLProperty(xmlFile, "TheContractor.repairContracts.arrival(0)"), "not saved")

    tc.RepairContracts.arrivals = {}
    tc.YardBales:resolveSavedVehicles()
    assertEquals(#tc.RepairContracts.arrivals, 1)
    assertEquals(tc.RepairContracts.arrivals[1].jobId, job.id)
    assertTrue(tc.RepairContracts.arrivals[1].loan)

    -- One that's out already keeps it, by uniqueId.
    tc.RepairContracts:update(TheContractorRepairContracts.PLACE_CHECK_MS)
    local telehandler = world:finishLoad()
    world:finishLoad()
    local saved = {}
    TheContractorYardBales.saveToXML(saved, "job", job.yardDelivery)
    job.yardDelivery = TheContractorYardBales.loadFromXML(saved, "job")
    tc.YardBales:resolveSavedVehicles()
    assertEquals(job.yardDelivery.kitVehicleId, telehandler.id)
    assertEquals(#tc.RepairContracts.arrivals, 0)
end)

test("a declined offer never brings the kit out, and frees it", function()
    local world, tc = setup()
    local job = world:offer()
    tc.Jobs:transitionJobState(1, job.id, TheContractorJob.STATE.DECLINED)
    updateYardBales(tc)
    assertEquals(#world.spawned, 0)
    assertEquals(#tc.RepairContracts.removals, 0)
    assertTrue(not TheContractorFarmerFleet.isMachineOut(4, 1))
end)
