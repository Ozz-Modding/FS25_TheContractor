-- 127: an emergency refuel, end to end, with no ADS installed. The offer
-- (the farmer's the customer, on their field, due today, the reason and
-- the litres on the job, the machine held), accepting it (allocated to the
-- farm's players, the farmer's machine out on the field through 100's queue
-- with its tank emptied, the farmer by it), filling it (under the target
-- isn't done; at it, it's done, paid and thanked for), the machine and its
-- header collected once nobody's near, an ordinary miss, the client's copy
-- and the machine event, and a load (the machine sent for again). The real
-- Jobs, Job, JobGeneration, Allocation, RepairContracts, Farmers,
-- FarmerFleet, FieldBreakdowns, Relationships, TCJobSupplies,
-- TCYardFarmers and EmergencyRefuel, with vehicle loading, the field's
-- headland and the rest of the mod faked.

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
        currentYear = 1, currentPeriod = 4, currentDayInPeriod = 4, daysPerPeriod = 10, plannedDaysPerPeriod = 10,
        currentMonotonicDay = 24, dayTime = 36000000,
        getPeriodFromDay = function() return 4 end,
        getDayInPeriodFromDay = function(_, day) return day - 20 end,
    }
    g_farmManager.getFarmById = function(_, farmId) return { farmId = farmId } end
    world.dieselPrice = 1.6
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
    FruitType = { UNKNOWN = 0 }
    g_fruitTypeManager = { getFruitTypeByIndex = function() return nil end }

    -- The store: Tom's tractor (400 l of diesel), his combine (1000 l) and
    -- its header.
    world.models = {
        { xml = "tractor.xml", category = "TRACTORSM", width = 3, length = 5, tank = 400 },
        { xml = "combine.xml", category = "HARVESTERS", width = 4, length = 9, tank = 1000 },
        { xml = "header.xml", category = "CUTTERS", width = 6, length = 2 },
    }
    local function findModel(xml)
        for _, model in ipairs(world.models) do
            if model.xml == xml then
                return model
            end
        end
        return nil
    end
    g_storeManager = {
        getItems = function() return {} end,
        getItemByXMLFilename = function(_, xml)
            local model = findModel(xml)
            return model ~= nil and { xmlFilename = model.xml, categoryName = model.category, name = model.xml } or nil
        end,
    }
    g_vehicleTypeManager = { getObjectTypeFromXML = function() return { specializationsByName = {} } end }
    StoreItemUtil = {
        getSizeValues = function(xml)
            local model = findModel(xml)
            if model == nil then
                return {}
            end
            return { width = model.width, length = model.length, height = 3, widthOffset = 0, lengthOffset = 0 }
        end,
    }
    world.spawned, world.deleted = {}, {}
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
    -- The last vehicle asked for loads, full of diesel if it has a tank.
    function world:finishLoad()
        local data = self.spawned[#self.spawned]
        local model = findModel(data.storeItem.xmlFilename)
        local vehicle = self:addVehicle({ name = model.xml, farmId = data.farmId,
            dieselUsagePerHour = model.tank ~= nil and 10 or nil, dieselCapacity = model.tank })
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
    TCJobSiteSetup = { hitchImplement = function(vehicle, attachment)
        attachment.attacher = vehicle
        return true
    end }
    TCParking = { PLACE_HEIGHT_OFFSET = 0.3, DEFAULT_HEIGHT = 4, isAreaClear = function() return world.clear ~= false end }
    TCParkingSlotFilter = { getCategoryTitle = function(name) return name end }

    -- Tom's field 4 (farmland 4), nobody's working it.
    g_farmlandManager = { getFarmlandOwner = function() return 0 end }
    local farmland = { getId = function() return 4 end }
    world.field = { id = 4 }
    function world.field:getId() return 4 end
    function world.field:getName() return "4" end
    function world.field:getFarmland() return farmland end
    function world.field:getCenterOfFieldWorldPosition() return 200, 0 end
    function world.field:getAreaHa() return 2 end
    function world.field:getOwner() return 0 end
    function world.field:getFieldState() return { fruitTypeIndex = FruitType.UNKNOWN } end
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
    world:load("src/util/TCJobSupplies.lua")
    world:load("src/business/RepairContracts.lua")
    world:load("src/business/FieldBreakdowns.lua")
    world:load("src/business/Farmers.lua")
    world:load("src/business/FarmerFleet.lua")
    world:load("src/util/TCYardFarmers.lua")
    TCHaulage.emptyHarvestersAfterJob = function() end
    TCFieldPreparation = { prepareFieldForJob = function() end, clearUpAfterJob = function() end }
    TCFieldAccess = { refresh = function() end }
    TCJobSupplies.topUp = function() end
    TCJobAllocatedEvent = { new = function(job) return { job = job } end }
    TCJobMissedEvent = { showNotification = function() end }
    TCJobCompletedEvent = { showNotification = function() end }
    AIMessageSuccessFinishedJob = { new = function() return {} end }
    AIMessageSuccessStoppedByUser = { new = function() return {} end }
    world.players = {}
    TheContractorFallenTree = { getPlayerPositions = function() return world.players end }
    -- The headland: the first spot asked for, then another.
    world.spots = { { x = 100, z = 50, rotY = 0 }, { x = 140, z = 60, rotY = 1 } }
    world.spotIndex = 0
    TheContractorFieldBreakdowns.pickSpot = function(fieldId)
        world.spotIndex = math.min(world.spotIndex + 1, #world.spots)
        local spot = world.spots[world.spotIndex]
        return spot.x, spot.z, spot.rotY
    end
    world.clearedSpots = {}
    TheContractorFieldBreakdowns.clearSpot = function(entry)
        table.insert(world.clearedSpots, { fieldId = entry.fieldId, x = entry.x, z = entry.z })
    end
    TheContractorEmergencyRefuel.getTankCapacity = function(xml)
        local model = findModel(xml)
        return model ~= nil and model.tank or 0
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
    world.claims = {}
    tc.Claims = {
        rollForJob = function() end,
        chargeClaim = function(_, farmId, amount) table.insert(world.claims, amount) return amount end,
        addToJobLog = function() end,
    }
    world.logbook = {}
    tc.Logbook = {
        recordJobCompleted = function(_, job) table.insert(world.logbook, TheContractorEmergencyRefuel.getLogbookDelivery(job)) end,
        recordJobMissed = function(_, job) table.insert(world.logbook, TheContractorEmergencyRefuel.getLogbookDelivery(job)) end,
        onCrewChanged = function() end,
        onWorkStarted = function() end,
    }
    world.messages, world.messageKinds = {}, {}
    tc.Inbox = {
        registerMessageKind = function(_, kind, definition) world.messageKinds[kind] = definition end,
        postMessage = function(_, farmId, kind, titleKey, bodyKey, args, actions, payload)
            table.insert(world.messages, { kind = kind, bodyKey = bodyKey, args = args, payload = payload })
        end,
        removeMessagesForJob = function() end,
        getMessageJob = function(_, message)
            return message.payload ~= nil and tc.Jobs:getJob(1, message.payload.jobId) or nil
        end,
        getMessageCustomer = function(self, message)
            local job = self:getMessageJob(message)
            return job ~= nil and job:getCustomer() or nil
        end,
    }
    world:load("src/business/Inbox.lua")

    TheContractorFarmerSplit = {
        getFieldFarmlands = function() return { { id = 4, x = 200, z = 0, acres = 30 } } end,
        getFreeYards = function() return {} end,
    }
    tc.Farmers = TheContractorFarmers.new()
    tc.Farmers.people[4] = { id = 4, name = "Tom Hargreaves", isOfficial = false, farmlandIds = { 4 }, machines = {
        { id = 1, role = "mediumTractor", xmlFilename = "tractor.xml", seed = 9 },
        { id = 2, role = "combine", xmlFilename = "combine.xml", seed = 5 },
        { id = 3, role = "header", xmlFilename = "header.xml", seed = 6, attachedTo = 2 },
    } }

    tc.EmergencyRefuel = TheContractorEmergencyRefuel.new()
    world.definitions = {}
    local randomEvents = {}
    function randomEvents:registerEventType(key, definition) world.definitions[key] = definition end
    tc.EmergencyRefuel:register(randomEvents, tc.Inbox)
    world.definition = world.definitions.emergencyRefuel

    -- details: the console's, if any.
    function world:offer(details)
        if details ~= nil then
            assertEquals(self.definition.console.prepareTrigger(1, details), nil)
        end
        local data = self.definition.canTrigger(1)
        assertTrue(data ~= nil, "the farmer calls")
        self.definition.stages[1].run({ id = 1, farmId = 1, data = data })
        self.definition.console.clearTrigger()
        return tc.Jobs:getAllJobs(1)[1]
    end

    -- Accepted, and the machine out (and its header, if it has one).
    function world:acceptAndBringMachine(job)
        tc.Jobs:transitionJobState(1, job.id, TheContractorJob.STATE.ACCEPTED)
        tc.RepairContracts:update(TheContractorRepairContracts.PLACE_CHECK_MS)
        local machine = self:finishLoad()
        local header = nil
        if job.refuel.attachmentMachineId ~= nil then
            header = self:finishLoad()
        end
        return machine, header
    end

    -- The progress sweep (TCJobProgress, faked here) and the completion
    -- check after it.
    function world:measure(job)
        job.completionPercentage = 100 * TheContractorEmergencyRefuel.getCompletion(job)
        tc.Jobs:checkForCompletions()
    end

    function world:collect()
        tc.EmergencyRefuel:update(TheContractorEmergencyRefuel.COLLECT_CHECK_MS)
        tc.RepairContracts:update(TheContractorRepairContracts.PLACE_CHECK_MS)
    end

    return world, tc
end

-- Diesel into the machine's tank from the player's own (a fuel trailer).
local function fill(machine, liters)
    machine:addFillUnitFillLevel(1, 1, liters, FillType.DIESEL)
end

test("the offer: the farmer's the customer on their field, due today, the reason and the litres kept, the machine held", function()
    local world, tc = setup()
    local job = world:offer({ "gauge" })
    assertEquals(job.jobType, TheContractorEmergencyRefuel.JOB_TYPE)
    assertEquals(job.customerId, 4)
    assertEquals(job.fieldId, 4)
    assertEquals(job.state, TheContractorJob.STATE.OFFERED)
    assertEquals(job.deadlineDay, g_currentMission.environment.currentMonotonicDay, "due today")
    local refuel = job.refuel
    assertEquals(refuel.farmerId, 4)
    assertEquals(refuel.machineId, 1, "his tractor, out of harvest")
    assertEquals(refuel.reason, "gauge")
    assertEquals(refuel.liters, 100, "a quarter of the tank")
    assertEquals(refuel.x, 100)
    assertEquals(refuel.z, 50)
    local R = TheContractorEmergencyRefuel
    assertEquals(job:getPrice(), R.getBasePrice(100, R.getBasePricePerLiter(), tc.Settings:getJobPayMultiplier()))

    local message = world.messages[1]
    assertEquals(message.kind, R.MESSAGE_KIND)
    assertEquals(message.bodyKey, "tc_refuel_offerBody_gauge")
    assertEquals(message.args[1], "4", "the field")
    assertEquals(message.args[2], "$volume_100")
    assertEquals(message.payload.jobId, job.id)
    assertTrue(world.messageKinds.emergencyRefuel.endsWithJob)
    -- Shown with the machine first and the farmer last, both as they are now.
    local args = world.messageKinds.emergencyRefuel.getArgs(message)
    assertEquals(#args, 4)
    assertEquals(args[1], TheContractorFarmerFleet.getModelName("tractor.xml"))
    assertEquals(args[2], "4")
    assertEquals(args[4], "Tom Hargreaves")
    tc.Farmers.people[4].machines[1].xmlFilename = "combine.xml"
    assertEquals(world.messageKinds.emergencyRefuel.getArgs(message)[1], TheContractorFarmerFleet.getModelName("combine.xml"),
        "122's edit shows")

    assertEquals(#world.spawned, 0, "nothing's out until it's accepted")
    assertTrue(TheContractorFarmerFleet.isMachineOut(4, 1))
    assertEquals(world.definition.canTrigger(1), nil, "one at a time")
end)

test("accepted: the player's at once, the machine's on the field with an empty tank, and the farmer's by it", function()
    local world, tc = setup()
    local job = world:offer()
    local machine = world:acceptAndBringMachine(job)
    assertEquals(job.state, TheContractorJob.STATE.ALLOCATED)
    assertEquals(world.spawned[1].storeItem.xmlFilename, "tractor.xml")
    assertEquals(world.spawned[1].propertyState, VehiclePropertyState.MISSION)
    assertEquals(world.spawned[1].farmId, 1, "the player's farm, so its own diesel can go in")
    assertEquals(machine.fillUnits[1].level, 0, "run dry")
    assertEquals(job.refuel.machineVehicleId, machine.id)
    assertEquals(world.clearedSpots[1].fieldId, 4, "the crop round it cleared")
    assertTrue(TheContractorRepairContracts.isContractVehicle(machine), "not the farm's to sell or list")
    assertEquals(#tc.RepairContracts.arrivals, 0)

    local person = tc.Farmers.people[4]
    local standingJob, standingBy = TCYardFarmers.getMachineJob(person, tc.Jobs)
    assertEquals(standingJob, job)
    assertEquals(standingBy, machine)
end)

test("a spot that's taken gives way to another on the same field", function()
    local world, tc = setup()
    local job = world:offer()
    world.clear = false
    tc.Jobs:transitionJobState(1, job.id, TheContractorJob.STATE.ACCEPTED)
    tc.RepairContracts:update(TheContractorRepairContracts.PLACE_CHECK_MS)
    assertEquals(#world.spawned, 0)
    assertEquals(tc.RepairContracts.arrivals[1].x, 140, "the next spot on the headland")
    world.clear = true
    tc.RepairContracts:update(TheContractorRepairContracts.PLACE_CHECK_MS)
    local machine = world:finishLoad()
    assertEquals(machine.rootNode.x, 140)
end)

test("filled: under a quarter of the tank isn't done; at it, it's done, paid, and the farmer's grateful", function()
    local world, tc = setup()
    local job = world:offer()
    local machine = world:acceptAndBringMachine(job)

    fill(machine, 60)
    world:measure(job)
    assertEquals(job.state, TheContractorJob.STATE.ALLOCATED)

    fill(machine, 50)
    world:measure(job)
    assertEquals(job.state, TheContractorJob.STATE.COMPLETED)
    assertEquals(world.invoiced[1], job:getPrice())
    assertEquals(job.qualityScore, 100, "the player drove it")
    assertEquals(world.reputation[1], TheContractorJobGeneration.JOB_TYPES.emergencyRefuel.reputationReward)
    assertEquals(tc.Relationships:getScore(1, 4),
        TheContractorRelationships.COMPLETED_GAIN + TheContractorEmergencyRefuel.RELATIONSHIP_BONUS)
    assertEquals(world.logbook[1].requiredLiters, 100)
    assertEquals(world.logbook[1].deliveredLiters, 110)
    assertEquals(world.logbook[1].machineName, TheContractorFarmerFleet.getModelName("tractor.xml"))
    assertEquals(#world.claims, 0)
end)

test("collected once it's over and nobody's near, with its header, not before", function()
    local world, tc = setup()
    local job = world:offer({ "combine" })
    local machine, header = world:acceptAndBringMachine(job)
    assertEquals(job.refuel.machineId, 2)
    assertEquals(job.refuel.attachmentMachineId, 3)
    assertEquals(header.attacher, machine, "the header's on")
    assertEquals(job.refuel.liters, 250)
    assertTrue(TheContractorRepairContracts.isContractVehicle(header))
    fill(machine, 250)
    world:measure(job)
    assertEquals(job.state, TheContractorJob.STATE.COMPLETED)

    -- The player's beside it.
    table.insert(world.players, { x = machine.rootNode.x + 20, z = machine.rootNode.z })
    world:collect()
    assertEquals(#tc.RepairContracts.removals, 2)
    assertTrue(not machine.isDeleted and not header.isDeleted)

    -- And they've gone: both go, the header's hitch to the combine no matter.
    world.players[1].x = machine.rootNode.x + 500
    world:collect()
    assertTrue(machine.isDeleted)
    assertTrue(header.isDeleted)
    assertTrue(not TheContractorFarmerFleet.isMachineOut(4, 2), "home again")
    assertTrue(not TheContractorFarmerFleet.isMachineOut(4, 3))
end)

test("not collected while a player's in it", function()
    local world, tc = setup()
    local job = world:offer()
    local machine = world:acceptAndBringMachine(job)
    fill(machine, 100)
    world:measure(job)
    function machine:getIsControlled() return true end
    world:collect()
    assertTrue(not machine.isDeleted)
    function machine:getIsControlled() return false end
    world:collect()
    assertTrue(machine.isDeleted)
end)

test("a miss is an ordinary miss: no claim, and the machine goes home", function()
    local world, tc = setup()
    local job = world:offer()
    local machine = world:acceptAndBringMachine(job)
    fill(machine, 40)
    tc.Jobs:missJob(job)
    assertEquals(job.state, TheContractorJob.STATE.MISSED)
    assertEquals(#world.claims, 0)
    assertTrue(tc.Relationships:getScore(1, 4) < 0)
    assertEquals(world.logbook[1].deliveredLiters, 40)
    world:collect()
    assertTrue(machine.isDeleted)
end)

test("a client gets the job, its reason and litres, and the machine by its event", function()
    local world, tc = setup()
    local job = world:offer({ "headland" })
    local machine = world:acceptAndBringMachine(job)
    local stream = world:newStream()
    TheContractorJobs.writeJob(stream, job)
    local copy = TheContractorJobs.readJob(stream)
    assertEquals(copy.refuel.reason, "headland")
    assertEquals(copy.refuel.liters, 100)
    assertEquals(copy.refuel.machineVehicleId, machine.id)
    assertEquals(copy.customerId, 4)
    assertEquals(copy:getLocationText(), job:getLocationText())
    assertEquals(copy:getListFieldText(), "4", "its field, though it's offField")

    -- The machine coming out reaches a client by TCRefuelMachineEvent.
    Event = { new = function(mt) return setmetatable({}, mt) end }
    InitEventClass = function() end
    world:load("src/events/TCRefuelMachineEvent.lua")
    job.refuel.machineVehicleId = nil
    local event = TCRefuelMachineEvent.new(1, job.id, machine.id, 0)
    local eventStream = world:newStream()
    event:writeStream(eventStream)
    TCRefuelMachineEvent.emptyNew():readStream(eventStream)
    assertEquals(job.refuel.machineVehicleId, machine.id)
    assertEquals(job.refuel.attachmentVehicleId, nil)
end)

test("a load: the machine's kept by uniqueId, and a job taken on without it sends for it again, run dry", function()
    local world, tc = setup()
    local job = world:offer()
    tc.Jobs:transitionJobState(1, job.id, TheContractorJob.STATE.ACCEPTED)
    assertEquals(#tc.RepairContracts.arrivals, 1)
    assertEquals(tc.RepairContracts.arrivals[1].loanOwner, "EmergencyRefuel")
    assertEquals(tc.RepairContracts.arrivals[1].fieldId, 4)

    local xmlFile = {}
    tc.RepairContracts:saveToXmlFile(xmlFile)
    assertTrue(not hasXMLProperty(xmlFile, "TheContractor.repairContracts.arrival(0)"), "not saved")
    tc.RepairContracts.arrivals = {}
    tc.EmergencyRefuel:resolveSavedVehicles()
    assertEquals(#tc.RepairContracts.arrivals, 1)
    assertEquals(tc.RepairContracts.arrivals[1].jobId, job.id)

    tc.RepairContracts:update(TheContractorRepairContracts.PLACE_CHECK_MS)
    local machine = world:finishLoad()
    assertEquals(machine.fillUnits[1].level, 0)
    fill(machine, 30)
    local saved = {}
    tc.Jobs:saveToXmlFile(saved)
    tc.Jobs = TheContractorJobs.new()
    tc.Jobs:loadFromXMLFile(saved)
    local loaded = tc.Jobs:getJob(1, job.id)
    assertEquals(loaded.refuel.reason, job.refuel.reason)
    assertEquals(loaded.refuel.liters, 100)
    tc.EmergencyRefuel:resolveSavedVehicles()
    assertEquals(loaded.refuel.machineVehicleId, machine.id)
    assertEquals(#tc.RepairContracts.arrivals, 0)
    assertEquals(machine.fillUnits[1].level, 30, "what's gone in stays in")
end)

test("a declined offer never brings the machine out, and frees it", function()
    local world, tc = setup()
    local job = world:offer()
    tc.Jobs:transitionJobState(1, job.id, TheContractorJob.STATE.DECLINED)
    world:collect()
    assertEquals(#world.spawned, 0)
    assertEquals(#tc.RepairContracts.removals, 0)
    assertTrue(not TheContractorFarmerFleet.isMachineOut(4, 1))
end)
