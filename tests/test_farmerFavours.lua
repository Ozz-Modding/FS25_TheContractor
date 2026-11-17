-- 116: farmer favours. The real FarmerFavours event type on 100's real Job,
-- Jobs, RepairContracts and ADS wrapper, 101's FieldBreakdowns (for its
-- headland spots), 110's Farmers and 113's Relationships, with
-- FS25_AdvancedDamageSystem's ADS_RepairContracts faked through
-- TCADSRepairContracts.getEnv (its targets included), the random events
-- framework faked down to the definition it's given, and yards and the rest
-- of the mod faked just enough.

local function setup(def)
    def = def or {}
    local world = stubs.install()
    world.today = 10
    world.calls = { invoices = {}, logged = {}, reputation = {}, spawned = {}, deleted = {}, released = {},
        prepared = {} }

    FinanceStats = { statNames = {}, statNameToIndex = {} }
    MoneyType = { LAST_ID = 0, register = function() return 1 end }
    MathUtil = {
        vector2Length = function(x, z) return math.sqrt(x * x + z * z) end,
        getYRotationFromDirection = function(x, z) return math.atan2(x, z) end,
    }
    g_terrainNode = 1
    getTerrainHeightAtWorldPos = function() return 0 end
    getWorldTranslation = function(node)
        if type(node) ~= "table" then
            return 0, 0, 0
        end
        return node.x or node[1] or 0, 0, node.z or node[2] or 0
    end
    VehiclePropertyState = { OWNED = 1, MISSION = 4 }
    VehicleLoadingState = { OK = 1 }
    Environment = { PERIODS_IN_YEAR = 12 }
    FarmlandManager = { NO_OWNER_FARM_ID = 0 }
    TheContractor = { SaveKey = "TheContractor" }

    g_currentMission.environment = {
        currentMonotonicDay = world.today,
        dayTime = 0,
        daysPerPeriod = 2,
        currentDayInPeriod = 1,
        getPeriodFromDay = function(_, day) return (day - 1) % 12 + 1 end,
        getDayInPeriodFromDay = function() return 1 end,
    }
    g_currentMission.getIsClient = function() return false end
    g_currentMission.placeableSystem = { placeables = {} }

    TheContractorNegotiation = { rollInitialEagerness = function() return 1 end, MAX_ROUNDS = 3 }
    -- The favour's own entry, as JobGeneration has it.
    TheContractorJobGeneration = {
        JOB_TYPES = { adsFavour = { workshopJob = true, playerOnly = true, noEquipment = true, favour = true } },
        getOperationSkill = function() return nil end,
        getFruitTypeIndexByName = function() return nil end,
        getTypeLabel = function(jobType) return jobType end,
    }
    TCFieldPreparation = { clearUpAfterJob = function() end }
    TCJobConsequences = {
        writeReports = function() end,
        readReports = function() return {} end,
        saveToXML = function() end,
        loadFromXML = function() end,
        resolveSavedVehicles = function() end,
    }
    TCJobCompletedEvent = { showNotification = function() end }
    TCJobMissedEvent = { showNotification = function() end }
    TCParking = {
        PLACE_HEIGHT_OFFSET = 0.3,
        DEFAULT_HEIGHT = 4,
        isAreaClear = function() return table.remove(world.spotBlocked or {}, 1) ~= true end,
        getShowSlotsSetting = function() return false end,
    }
    TCParkingSlotFilter = { getCategoryTitle = function(name) return name end, SUMMARY_MAX_NAMES = 2 }
    TheContractorRandomEvents = { DONE = "done", WAIT = "wait" }
    world.painted = {}
    FSDensityMapUtil = {
        convertToDensityMapAngle = function() return 0 end,
        updateCultivatorArea = function(sx, sz, wx, wz, hx, hz)
            table.insert(world.painted, { sx = sx, sz = sz })
        end,
        clearDecoArea = function() end,
    }
    g_currentMission.fieldGroundSystem = { getGroundAngleMaxValue = function() return 7 end }

    local tc = g_currentMission.TheContractor
    tc.Settings = {
        scaleCost = function(_, amount) return amount end,
        getADSMargin = function() return 0.4 end,
    }
    world:addRelationships()
    -- 129: a miss can leave the customer poor, so they complain.
    TCCalendar.getPeriodIndex = function() return 1 end
    tc.Reputation = {
        addReputation = function(_, farmId, delta) table.insert(world.calls.reputation, delta) end,
    }
    tc.Association = {
        hasLegalCover = function() return false end,
        getReputationBonus = function() return 0 end,
    }
    tc.Finances = { invoiceJob = function(_, job) table.insert(world.calls.invoices, job.id) end }
    tc.Logbook = {
        recordJobCompleted = function(_, job) table.insert(world.calls.logged, { "completed", job.id }) end,
        recordJobMissed = function(_, job) table.insert(world.calls.logged, { "missed", job.id }) end,
    }
    tc.Inbox = { postMessage = function() end, removeMessagesForJob = function() end }
    tc.Company = { hasCompany = function() return true end }
    g_farmManager.getFarmById = function() return { farmId = 1 } end

    -- ADS: each vehicle's status, its stock parts (ADS_Config's graded
    -- parts), and which of them a machine hasn't got (world.notFitted).
    world.status, world.prepareResults, world.notFitted, world.partGrades = {}, {}, {}, {}
    world.adsEnv = {
        ADS_RepairContracts = {
            getInfo = function() return { version = 1, targets = not def.noTargets or nil } end,
            prepareVehicle = function(vehicle, request)
                table.insert(world.calls.prepared, request)
                if world.notFitted[request.targets[1].consumable] then
                    return false, "targetNotApplicable"
                end
                if table.remove(world.prepareResults, 1) == false then
                    return false, "noApplicableFaults"
                end
                vehicle.quote = { price = 400, partsCost = world.partsCost or 180, laborHours = 0.5, minTools = {},
                    operatingHours = request.operatingHours or 2400, kind = request.kind,
                    items = { { id = "x", kind = request.kind == "maintenance" and "consumable" or "fault" } } }
                return true, "rc1"
            end,
            getQuote = function(vehicle) return vehicle.quote end,
            getStatus = function(vehicle)
                return { state = world.status[vehicle.id] or "open", items = {} }
            end,
            checkTampering = function() return false, {} end,
            checkFarmTools = function() return { canDo = true, missing = {} } end,
            getFarmTools = function(farmId) return { farmId = farmId, places = {}, tools = {} } end,
            registerListener = function(id, fn) world.listener = fn return true end,
            unregisterListener = function() world.listener = nil end,
            release = function(vehicle) table.insert(world.calls.released, vehicle.id) return true end,
            authorize = function(vehicle) vehicle.stage = "authorized" return true end,
            getStage = function(vehicle) return vehicle.stage or "inspection" end,
            isWorkLocked = function(vehicle) return vehicle.stage ~= "authorized" end,
        },
        -- The size each machine takes (world.partGrades by part, L by default).
        ADS_PartsShop = { getPartGrade = function(vehicle, partId) return world.partGrades[partId] or "L" end },
        ADS_Config = { SPARE_PARTS_BOX = { GRADED_PARTS = def.stockParts or {
            { id = "battery", nameKey = "Battery" },
            { id = "airFilter", nameKey = "Air filter" },
        } } },
    }
    TheContractorDrivers = { getModEnv = function() return world.adsEnv end }

    -- Fields: 100 m squares from (0, 0) on farmlands of their own id.
    world.fields = {}
    function world:addField(fieldId)
        local field = { id = fieldId, nodes = { { 0, 0 }, { 100, 0 }, { 100, 100 }, { 0, 100 } } }
        local farmland = { getId = function() return fieldId end }
        function field:getPolygonPoints() return self.nodes end
        function field:getId() return self.id end
        function field:getOwner() return 0 end
        function field:getName() return tostring(self.id) end
        function field:getFarmland() return farmland end
        table.insert(self.fields, field)
        return field
    end
    g_fieldManager = {
        getFields = function() return world.fields end,
        getFieldById = function(_, fieldId)
            for _, field in ipairs(world.fields) do
                if field.id == fieldId then
                    return field
                end
            end
            return nil
        end,
    }

    -- Yards (108): the synced spots per farmland, and which ground's open.
    world.yardSpots = {}
    world.isOpen = function() return true end
    tc.Yards = { getSpots = function(_, farmlandId) return world.yardSpots[farmlandId] end }
    TheContractorYards = { isOpenGround = function(farmlandId, x, z) return world.isOpen(x, z) end }

    world.models = def.models or {
        { xml = "small.xml", category = "TRACTORSS", specs = { AdvancedDamageSystem = true, drivable = true },
            width = 2, length = 4 },
        { xml = "medium.xml", category = "TRACTORSM", specs = { AdvancedDamageSystem = true, drivable = true },
            width = 3, length = 5 },
    }
    g_storeManager = {
        getItems = function()
            local items = {}
            for _, model in ipairs(world.models) do
                table.insert(items, { xmlFilename = model.xml, categoryName = model.category, name = model.xml })
            end
            return items
        end,
        getItemByXMLFilename = function(_, xml)
            for _, model in ipairs(world.models) do
                if model.xml == xml then
                    return { xmlFilename = model.xml, categoryName = model.category, name = model.xml }
                end
            end
            return nil
        end,
    }
    g_vehicleTypeManager = {
        getObjectTypeFromXML = function(_, xml)
            for _, model in ipairs(world.models) do
                if model.xml == xml then
                    return { specializationsByName = model.specs }
                end
            end
            return nil
        end,
    }
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
                table.insert(world.calls.spawned, self)
            end
            return data
        end,
    }
    function world:finishLoad(index)
        local data = self.calls.spawned[index or #self.calls.spawned]
        local vehicle = { name = "Tractor " .. data.storeItem.xmlFilename, propertyState = data.propertyState,
            farmId = data.farmId, rootNode = { x = data.x, z = data.z } }
        function vehicle:getFullName() return self.name end
        function vehicle:getUniqueId() return "vehicle" .. self.id end
        function vehicle:getOwnerFarmId() return self.farmId end
        function vehicle:delete()
            self.isDeleted = true
            table.insert(world.calls.deleted, self.id)
        end
        self:register(vehicle)
        table.insert(g_currentMission.vehicleSystem.vehicles, vehicle)
        data.callback(data.target, { vehicle }, VehicleLoadingState.OK, data.args)
        return vehicle
    end

    world:load("src/util/TCVehicleIds.lua")
    world:load("src/util/TCJoyriderRuts.lua")
    world:load("src/util/TCSiteClearance.lua")
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
    world:load("src/business/RepairContracts.lua")
    world:load("src/business/FieldBreakdowns.lua")
    world:load("src/business/Farmers.lua")
    world:load("src/business/FarmerFleet.lua")
    world:load("src/business/FarmerFavours.lua")

    TCADSRepairContracts.getEnv = function() return world.adsEnv end
    TCADSRepairContracts.detect()

    -- The farmers' land: farmland id -> acres (each with a field of that id).
    world.landList = {}
    TheContractorFarmerSplit = {
        getFieldFarmlands = function() return world.landList end,
        getFreeYards = function() return {} end,
    }
    tc.Farmers = TheContractorFarmers.new()
    tc.Farmers.officialId = 99
    tc.Farmers.people[99] = { id = 99, name = "The Official", isOfficial = true, farmlandIds = {} }
    -- 121: a farmer's fleet is made at setUp; here they have a small tractor
    -- unless they're given their machines.
    function world:addFarmer(id, name, acres, yardFarmlandId, machines)
        self:addField(id)
        table.insert(self.landList, { id = id, x = 0, z = 0, acres = acres, ownerFarmId = 0 })
        local farmer = { id = id, name = name, isOfficial = false, farmlandIds = { id }, yardFarmlandId = yardFarmlandId,
            targetAcres = acres, machines = machines or {
                { id = 1, role = "smallTractor", xmlFilename = "small.xml", seed = 4242, hoursPerMonth = 29, fitted = {} },
            } }
        tc.Farmers.people[id] = farmer
        return farmer
    end

    tc.Jobs = TheContractorJobs.new()
    tc.RepairContracts = TheContractorRepairContracts.new()
    tc.FarmerFavours = TheContractorFarmerFavours.new()

    local randomEvents = {}
    function randomEvents:registerEventType(key, definition) world.definition = definition end
    tc.FarmerFavours:register(randomEvents)

    function world:trigger(farmId)
        local data = self.definition.canTrigger(farmId or 1)
        if data == nil then
            return nil
        end
        local incident = { id = 1, farmId = farmId or 1, data = data }
        self.definition.stages[1].run(incident)
        return incident
    end

    return world, tc
end

-- A yard with one spot at (0, 0), its middle 10 m north.
local function addYard(world, farmlandId)
    world.yardSpots[farmlandId] = { x = 0, z = 10, spots = { { x = 0, z = 0 } } }
end

-- A favour offered by farmer 4 (Tom, 30 acres, a yard on farmland 50): asked,
-- placed, prepared.
local function makeOffer(world, tc)
    addYard(world, 50)
    world:addFarmer(4, "Tom Hargreaves", 30, 50)
    world:trigger()
    tc.RepairContracts:update(TheContractorRepairContracts.PLACE_CHECK_MS)
    local vehicle = world:finishLoad()
    return tc.Jobs:getAllJobs(1)[1], vehicle
end

-- The roll ------------------------------------------------------------------------------

test("no favours without ADS's targets or a stock part to ask for; no tool box needed", function()
    setup({ noTargets = true })
    assertEquals(TheContractorFarmerFavours.getRate(1), 0)

    local world = setup({ stockParts = {} })
    assertEquals(TheContractorFarmerFavours.getRate(1), 0)
    world:addFarmer(4, "Tom", 30)
    assertEquals(world.definition.canTrigger(1), nil)

    setup()
    assertNear(TheContractorFarmerFavours.getRate(1), TheContractorFarmerFavours.RATE_PER_PERIOD, 0.0001,
        "a farm with no ADS kit at all")
end)

test("a farmer with land who isn't asking already and hasn't fallen out with the farm", function()
    local world, tc = setup()
    tc.Farmers.people[7] = { id = 7, name = "No Land", isOfficial = false, farmlandIds = {} }
    assertEquals(world.definition.canTrigger(1), nil, "nobody with land, and never the official")
    world:addFarmer(4, "Tom", 30)
    assertEquals(world.definition.canTrigger(1).farmerId, 4)

    tc.Relationships:adjust(1, 4, -60)
    assertEquals(world.definition.canTrigger(1), nil, "fallen out")
    tc.Relationships:adjust(1, 4, 60)

    -- Another farm has a favour on with Tom: nobody else can have him.
    table.insert(tc.RepairContracts.arrivals, { farmId = 2, favour = true, farmerId = 4 })
    assertEquals(world.definition.canTrigger(1), nil)
    world:addFarmer(5, "Ann", 30)
    assertEquals(world.definition.canTrigger(1).farmerId, 5)
    -- And one favour at a time per farm.
    table.insert(tc.RepairContracts.arrivals, { farmId = 1, favour = true, farmerId = 5 })
    assertEquals(world.definition.canTrigger(1), nil)
end)

test("a farmer with a yard is likelier to be the one asking", function()
    local world = setup()
    world:addFarmer(4, "Tom", 30)
    world:addFarmer(5, "Ann", 30, 50)
    local random = math.random
    -- Equal weights would make 0.3 of the way through Tom's share; Ann's
    -- yard puts it in hers.
    math.random = function() return 0.3 end
    local data = world.definition.canTrigger(1)
    math.random = function() return 0.1 end
    local low = world.definition.canTrigger(1)
    math.random = random
    assertEquals(data.farmerId, 5)
    assertEquals(low.farmerId, 4, "a farmer without one can still ask")
end)

test("the console asks a farmer by id or name, and refuses anyone else", function()
    local world, tc = setup()
    world:addFarmer(4, "Tom Hargreaves", 30)
    world:addFarmer(5, "Ann Smith", 30)
    local console = world.definition.console
    assertEquals(console.prepareTrigger(1, { "tom", "hargreaves" }), nil)
    assertEquals(world.definition.canTrigger(1).farmerId, 4)
    assertEquals(console.prepareTrigger(1, { "5" }), nil)
    assertEquals(world.definition.canTrigger(1).farmerId, 5)
    console.clearTrigger()
    assertEquals(tc.FarmerFavours.forcedFarmerId, nil)
    assertTrue(console.prepareTrigger(1, { "nobody" }) ~= nil)
end)

-- The machines ------------------------------------------------------------------------------

test("121: a favour is about one of the farmer's machines that drives and ADS takes, never one that's out", function()
    local world, tc = setup()
    addYard(world, 50)
    world:addFarmer(4, "Tom", 30, 50, {
        { id = 1, role = "trailer", xmlFilename = "trailer.xml", seed = 1, fitted = {} },
        { id = 2, role = "mediumTractor", xmlFilename = "medium.xml", seed = 2, fitted = {} },
    })
    world:trigger()
    local entry = tc.RepairContracts.arrivals[1]
    assertEquals(entry.machineId, 2, "never the trailer")
    assertEquals(entry.seed, 2)

    -- The tractor's broken down in a field (101): nothing left to ask about.
    world, tc = setup()
    addYard(world, 50)
    world:addFarmer(4, "Tom", 30, 50)
    table.insert(tc.RepairContracts.arrivals, { farmId = 2, fieldId = 4, farmerId = 4, machineId = 1 })
    world:trigger()
    assertEquals(#tc.RepairContracts.arrivals, 1, "no favour queued")
end)

test("121: a telehandler comes with its bale fork, hitched on; both are the customer's and both are collected", function()
    local world, tc = setup({ models = {
        { xml = "teli.xml", category = "TELELOADERVEHICLES", specs = { AdvancedDamageSystem = true, drivable = true },
            width = 2.5, length = 5 },
        { xml = "baleFork.xml", category = "TELELOADERTOOLS", specs = { dynamicMountAttacher = true }, width = 2,
            length = 1.5 },
    } })
    localDirectionToWorld = function() return 0, 0, 1 end
    world.hitched = {}
    TCJobSiteSetup = { hitchImplement = function(attacher, implement)
        table.insert(world.hitched, { attacher.id, implement.id })
        return true
    end }
    addYard(world, 50)
    world:addFarmer(4, "Tom", 30, 50, {
        { id = 1, role = "telehandler", xmlFilename = "teli.xml", seed = 7, fitted = {} },
        { id = 2, role = "baleFork", attachedTo = 1, xmlFilename = "baleFork.xml", seed = 8, fitted = {} },
    })
    world:trigger()
    local entry = tc.RepairContracts.arrivals[1]
    assertEquals(entry.attachment.machineId, 2)
    tc.RepairContracts:update(TheContractorRepairContracts.PLACE_CHECK_MS)
    local vehicle = world:finishLoad()
    assertEquals(#tc.Jobs:getAllJobs(1), 0, "not offered until the fork's on")
    assertEquals(world.calls.spawned[2].storeItem.xmlFilename, "baleFork.xml")
    assertNear(world.calls.spawned[2].z - world.calls.spawned[1].z, 2.5 + 0.75 + TheContractorRepairContracts.CLEARANCE,
        0.001, "loaded in front of it")
    local fork = world:finishLoad()
    assertEquals(world.hitched[1][1], vehicle.id)
    assertEquals(world.hitched[1][2], fork.id)

    local job = tc.Jobs:getAllJobs(1)[1]
    assertEquals(job.workshop.attachmentId, fork.id)
    assertEquals(job.workshop.attachmentMachineId, 2)
    assertTrue(TheContractorRepairContracts.isContractVehicle(fork), "the customer's")
    assertTrue(not TheContractorRepairContracts.isWorkableVehicle(fork, 1), "but nothing for a workshop")
    assertTrue(TheContractorFarmerFleet.isMachineOut(4, 1))

    tc.Jobs:transitionJobState(1, job.id, TheContractorJob.STATE.DECLINED)
    assertEquals(#tc.RepairContracts.removals, 2)
    tc.RepairContracts:update(TheContractorRepairContracts.PLACE_CHECK_MS)
    assertTrue(vehicle.isDeleted and fork.isDeleted, "both taken away")
    assertTrue(not TheContractorFarmerFleet.isMachineOut(4, 1), "home again")
end)

test("121: a fork that won't hitch is left out, and the favour goes ahead without it", function()
    local world, tc = setup({ models = {
        { xml = "teli.xml", category = "TELELOADERVEHICLES", specs = { AdvancedDamageSystem = true, drivable = true },
            width = 2.5, length = 5 },
        { xml = "baleFork.xml", category = "TELELOADERTOOLS", specs = { dynamicMountAttacher = true }, width = 2,
            length = 1.5 },
    } })
    localDirectionToWorld = function() return 0, 0, 1 end
    TCJobSiteSetup = { hitchImplement = function() return false end }
    addYard(world, 50)
    world:addFarmer(4, "Tom", 30, 50, {
        { id = 1, role = "telehandler", xmlFilename = "teli.xml", seed = 7, fitted = {} },
        { id = 2, role = "baleFork", attachedTo = 1, xmlFilename = "baleFork.xml", seed = 8, fitted = {} },
    })
    world:trigger()
    tc.RepairContracts:update(TheContractorRepairContracts.PLACE_CHECK_MS)
    world:finishLoad()
    local fork = world:finishLoad()
    assertTrue(fork.isDeleted)
    local job = tc.Jobs:getAllJobs(1)[1]
    assertTrue(job ~= nil)
    assertEquals(job.workshop.attachmentId, nil)
end)

test("the stock parts, none refitted too soon", function()
    setup()
    local parts = TCADSRepairContracts.getStockParts()
    assertEquals(#parts, 2)
    local targets = TheContractorFarmerFavours.getTargets(parts, nil, 10, 2)
    assertEquals(#targets, 2)
    assertEquals(targets[1].request.consumable, "battery")
    assertEquals(targets[2].id, "airFilter")

    local refitDays = TheContractorFarmerFavours.REFIT_MONTHS * 2
    targets = TheContractorFarmerFavours.getTargets(parts, { battery = 10 - refitDays + 1 }, 10, 2)
    assertEquals(#targets, 1, "the battery's too new")
    assertEquals(targets[1].id, "airFilter")
    targets = TheContractorFarmerFavours.getTargets(parts, { battery = 10 - refitDays }, 10, 2)
    assertEquals(#targets, 2)
end)

-- Where it stands --------------------------------------------------------------------------

test("in the yard facing its middle, else on one of their fields, else nowhere", function()
    local world, tc = setup()
    local model = { width = 3, length = 5 }
    addYard(world, 50)
    local farmer = world:addFarmer(4, "Tom", 30, 50)
    local spot = TheContractorFarmerFavours.pickSpot(farmer, model, math.random)
    assertEquals(spot.yardFarmlandId, 50)
    assertEquals(spot.x, 0)
    assertNear(spot.rotY, 0, 0.0001, "facing the yard's middle, north")

    -- No room for its corners: the headland of their field.
    world.isOpen = function(x, z) return math.abs(x) < 1 and math.abs(z) < 1 end
    spot = TheContractorFarmerFavours.pickSpot(farmer, model, math.random)
    assertEquals(spot.yardFarmlandId, nil)
    assertEquals(spot.fieldId, 4)

    tc.Jobs.isFieldProtected = function() return true end
    assertEquals(TheContractorFarmerFavours.pickSpot(farmer, model, math.random), nil, "a job's on their only field")
end)

-- The offer ------------------------------------------------------------------------------

test("a favour: the farmer's machine in their yard, one part, the farmer the customer, the part to pay back", function()
    local world, tc = setup()
    world.notFitted.airFilter = true
    local job, vehicle = makeOffer(world, tc)
    local farmer = tc.Farmers:getPerson(4)
    assertEquals(#farmer.machines, 1)
    local machine = farmer.machines[1]

    assertEquals(#tc.RepairContracts.arrivals, 0)
    assertEquals(world.calls.spawned[1].storeItem.xmlFilename, "small.xml")
    assertEquals(world.calls.spawned[1].propertyState, VehiclePropertyState.MISSION)
    local request = world.calls.prepared[#world.calls.prepared]
    assertEquals(request.kind, "maintenance")
    assertEquals(request.fieldService, nil)
    assertEquals(request.seed, machine.seed)
    assertEquals(request.operatingHours, nil, "ADS ages it the first time")
    assertEquals(#request.targets, 1)
    assertEquals(request.targets[1].consumable, "battery")

    assertEquals(job.jobType, "adsFavour")
    assertEquals(job.state, TheContractorJob.STATE.OFFERED)
    assertEquals(job.customerId, 4)
    assertEquals(job:getPrice(), 180)
    assertEquals(job.workshop.yardFarmlandId, 50)
    assertEquals(job.workshop.targetId, "battery")
    assertEquals(job.workshop.serviceLevel, nil)
    assertEquals(TheContractorRepairContracts.getToolsWarning(job), nil, "fitted by hand")
    assertEquals(job.deadlineDay, world.today, "due today")
    assertEquals(job.workshop.offerExpiresDay, world.today)
    assertEquals(job.workshop.partGrade, "L")
    assertTrue(TheContractorRepairContracts.isFavourJob(job))
    assertTrue(TheContractorRepairContracts.isContractVehicle(vehicle))
    assertEquals(machine.hours, 2400, "aged by ADS's quote")
    assertEquals(machine.hoursDay, world.today)
end)

test("a machine without one of the parts gets the other; with neither, no favour", function()
    local world, tc = setup()
    world.notFitted.battery = true
    world.partGrades.airFilter = "M"
    local job = makeOffer(world, tc)
    assertEquals(job.workshop.targetId, "airFilter")
    assertEquals(job.workshop.partGrade, "M", "the size this machine takes")
    assertEquals(tc.Jobs:proposeCounterOffer(1, job.id, 100), nil, "nothing to haggle over")

    world, tc = setup()
    world.notFitted.battery, world.notFitted.airFilter = true, true
    local vehicle
    job, vehicle = makeOffer(world, tc)
    assertEquals(job, nil)
    assertTrue(vehicle.isDeleted)
end)

test("a part ADS turns down tries the next; none at all, and the machine and the favour go", function()
    local world, tc = setup()
    world.prepareResults = { false }
    local job = makeOffer(world, tc)
    assertEquals(#world.calls.prepared, 2)
    assertTrue(job ~= nil)

    world, tc = setup()
    world.prepareResults = { false, false }
    local vehicle
    job, vehicle = makeOffer(world, tc)
    assertEquals(job, nil)
    assertTrue(vehicle.isDeleted)
    assertEquals(#tc.RepairContracts.arrivals, 0)

    -- Nothing to pay back is no favour either.
    world, tc = setup()
    world.partsCost = 0
    job = makeOffer(world, tc)
    assertEquals(job, nil)
end)

test("a yard spot that's taken gets another of the farmer's", function()
    local world, tc = setup()
    addYard(world, 50)
    world:addFarmer(4, "Tom", 30, 50)
    world:trigger()
    world.spotBlocked = { true }
    world.isOpen = function(x, z) return math.abs(x) < 1 and math.abs(z) < 1 end
    tc.RepairContracts:update(TheContractorRepairContracts.PLACE_CHECK_MS)
    local entry = tc.RepairContracts.arrivals[1]
    assertEquals(entry.fieldId, 4, "moved to their field")
    assertEquals(entry.yardFarmlandId, nil)
    tc.RepairContracts:update(TheContractorRepairContracts.PLACE_CHECK_MS)
    world:finishLoad()
    assertEquals(tc.Jobs:getAllJobs(1)[1].workshop.fieldId, 4)
end)

-- Ending ------------------------------------------------------------------------------

test("done: billed the part, a little reputation, the farmer's thanks, and the part on the machine's record", function()
    local world, tc = setup()
    local job, vehicle = makeOffer(world, tc)
    assertEquals(TheContractorJobs.getAcceptProblem(job), nil)
    assertTrue(tc.Jobs:transitionJobState(1, job.id, TheContractorJob.STATE.ACCEPTED))
    assertEquals(vehicle.stage, "authorized", "accepted, so ADS lets the work start")
    tc.RepairContracts:resolveSavedVehicles()
    world.status[vehicle.id] = "done"
    world.listener(vehicle, { state = "done" })

    assertEquals(job.state, TheContractorJob.STATE.COMPLETED)
    assertEquals(world.calls.invoices[1], job.id)
    assertEquals(job.paymentAmount, 180)
    assertEquals(TheContractorRepairContracts.getSpeedFactor(job), 1)
    assertEquals(world.calls.reputation[1], tc.Jobs:calculateReputationReward(job))
    assertEquals(tc.Relationships:getScore(1, 4), TheContractorFarmerFavours.RELATIONSHIP_GAIN)
    local machine = tc.Farmers:getPerson(4).machines[1]
    assertEquals(machine.fitted[job.workshop.targetId], world.today)
    assertEquals(#tc.RepairContracts.removals, 1, "back in the shed")
end)

test("missed: the farmer remembers, and takes the machine back", function()
    local world, tc = setup()
    local job = makeOffer(world, tc)
    tc.Jobs:transitionJobState(1, job.id, TheContractorJob.STATE.ACCEPTED)
    g_currentMission.environment.currentMonotonicDay = job.deadlineDay + 1
    tc.Jobs:onDayChanged()
    assertEquals(job.state, TheContractorJob.STATE.MISSED)
    assertTrue(tc.Relationships:getScore(1, 4) < 0)
    assertEquals(#tc.RepairContracts.removals, 1)
end)

-- Saving and streaming ---------------------------------------------------------------

test("a favour's job streams and saves its part, yard and farmer; a queued one saves its spot", function()
    local world, tc = setup()
    local job = makeOffer(world, tc)
    local stream = world:newStream()
    TheContractorJobs.writeJob(stream, job)
    local copy = TheContractorJobs.readJob(stream)
    assertEquals(copy.workshop.targetNameKey, job.workshop.targetNameKey)
    assertEquals(copy.workshop.yardFarmlandId, 50)
    assertEquals(copy.workshop.partGrade, "L")

    local xmlFile = {}
    tc.Jobs:saveToXmlFile(xmlFile)
    local jobs = TheContractorJobs.new()
    jobs:loadFromXMLFile(xmlFile)
    local loaded = jobs:getJob(1, job.id).workshop
    assertEquals(loaded.farmerId, 4)
    assertEquals(loaded.machineId, 1)
    assertEquals(loaded.targetId, job.workshop.targetId)
    assertEquals(loaded.targetNameKey, job.workshop.targetNameKey)
    assertEquals(loaded.yardFarmlandId, 50)
    assertEquals(loaded.partGrade, "L")
    assertEquals(tc.Farmers:getCustomerIdForJob(jobs:getJob(1, job.id)), 4)

    world, tc = setup()
    addYard(world, 50)
    world:addFarmer(4, "Tom", 30, 50)
    world:trigger()
    local entry = tc.RepairContracts.arrivals[1]
    xmlFile = {}
    tc.RepairContracts:saveToXmlFile(xmlFile)
    local contracts = TheContractorRepairContracts.new()
    contracts:loadFromXMLFile(xmlFile)
    local copied = contracts.arrivals[1]
    assertTrue(copied.favour)
    assertEquals(copied.farmerId, 4)
    assertEquals(copied.machineId, entry.machineId)
    assertEquals(copied.yardFarmlandId, 50)
    assertEquals(copied.seed, entry.seed)
    assertNear(copied.x, entry.x, 0.001)
    assertEquals(copied.kind, nil)
end)

test("not placed by midnight, a favour's dropped", function()
    local world, tc = setup()
    addYard(world, 50)
    world:addFarmer(4, "Tom", 30, 50)
    world:trigger()
    TheContractorRepairContracts.ARRIVAL_CHANCE = 0
    g_currentMission.environment.currentMonotonicDay = world.today + 1
    tc.RepairContracts:onDayChanged()
    assertEquals(#tc.RepairContracts.arrivals, 0)
end)
