-- 101: field breakdowns. The real FieldBreakdowns event type on 100's real
-- Job, Jobs, RepairContracts and ADS wrapper, with
-- FS25_AdvancedDamageSystem's ADS_RepairContracts faked through
-- TCADSRepairContracts.getEnv, the random events framework faked down to
-- the definition it's given, and the rest of the mod faked just enough.

local function setup(def)
    def = def or {}
    local world = stubs.install()
    world.today = 10
    world.calls = { invoices = {}, logged = {}, messages = {}, reputation = {}, spawned = {}, deleted = {},
        released = {} }

    FinanceStats = { statNames = {}, statNameToIndex = {} }
    MoneyType = { LAST_ID = 0, register = function() return 1 end }
    MathUtil = {
        vector2Length = function(x, z) return math.sqrt(x * x + z * z) end,
        getYRotationFromDirection = function(x, z) return math.atan2(x, z) end,
    }
    g_terrainNode = 1
    getTerrainHeightAtWorldPos = function() return 0 end
    -- Field polygon nodes are { x, z }, a vehicle's root node { x = , z = }.
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
        daysPerPeriod = 1,
        currentDayInPeriod = 1,
        getPeriodFromDay = function(_, day) return (day - 1) % 12 + 1 end,
        getDayInPeriodFromDay = function() return 1 end,
    }
    g_currentMission.getIsClient = function() return false end
    g_currentMission.placeableSystem = { placeables = {} }

    TheContractorNegotiation = { rollInitialEagerness = function() return 1 end, MAX_ROUNDS = 3 }
    TheContractorJobGeneration = {
        JOB_TYPES = {},
        getOperationSkill = function() return nil end,
        getFruitTypeIndexByName = function() return nil end,
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
    -- The ground painted under a placed breakdown (TCJoyriderRuts).
    world.painted = {}
    FSDensityMapUtil = {
        convertToDensityMapAngle = function() return 0 end,
        updateCultivatorArea = function(sx, sz, wx, wz, hx, hz)
            table.insert(world.painted, { sx = sx, sz = sz, wx = wx, wz = wz, hx = hx, hz = hz })
        end,
        clearDecoArea = function() end,
    }
    g_currentMission.fieldGroundSystem = { getGroundAngleMaxValue = function() return 7 end }
    -- Fields are in maize (cut at 10) unless a test says otherwise.
    FruitType = { UNKNOWN = 0, MAIZE = 5 }
    g_fruitTypeManager = {
        getFruitTypeByIndex = function(_, index)
            return index == FruitType.MAIZE and { getIsCut = function(_, state) return state == 10 end } or nil
        end,
    }

    local tc = g_currentMission.TheContractor
    tc.Settings = {
        scaleCost = function(_, amount) return amount end,
        getADSMargin = function(_, isField)
            if isField then
                return world.adsFieldMargin or 0.5
            end
            return world.adsMargin or 0.4
        end,
    }
    world:addRelationships()
    tc.Reputation = {
        getStanding = function() return world.standing or 0 end,
        addReputation = function(_, farmId, delta) table.insert(world.calls.reputation, delta) end,
    }
    tc.Association = {
        hasLegalCover = function() return false end,
        getReputationBonus = function() return 0 end,
    }
    tc.Finances = { invoiceJob = function(_, job) table.insert(world.calls.invoices, job.id) end }
    tc.Logbook = {
        recordJobCompleted = function(_, job, reward) table.insert(world.calls.logged, { "completed", job.id }) end,
        recordJobMissed = function(_, job, penalty) table.insert(world.calls.logged, { "missed", job.id }) end,
    }
    tc.Inbox = {
        postMessage = function(_, farmId, kind, titleKey, bodyKey, args)
            table.insert(world.calls.messages, { kind = kind, titleKey = titleKey, bodyKey = bodyKey })
        end,
        removeMessagesForJob = function() end,
    }
    tc.Company = { hasCompany = function() return true end }
    g_farmManager.getFarmById = function() return { farmId = 1 } end

    -- ADS: the farm's places (world.farmPlaces) and each vehicle's status.
    world.status, world.prepareResults, world.farmPlaces = {}, {}, def.farmPlaces or {}
    world.adsEnv = {
        ADS_RepairContracts = {
            getInfo = function() return { version = 1 } end,
            prepareVehicle = function(vehicle, request)
                if table.remove(world.prepareResults, 1) == false then
                    return false, "noApplicableFaults"
                end
                world.prepared = request
                vehicle.quote = { price = 1200, partsCost = 800, minTools = { "jack" }, serviceLevel = request.fieldService,
                    fieldService = request.fieldService, operatingHours = 3100 }
                return true, "rc1"
            end,
            getQuote = function(vehicle) return vehicle.quote end,
            getStatus = function(vehicle)
                return { state = world.status[vehicle.id] or "open" }
            end,
            checkTampering = function() return false, {} end,
            checkFarmTools = function() return { canDo = true, missing = {} } end,
            getFarmTools = function(farmId)
                local places = {}
                for _, id in ipairs(world.farmPlaces) do
                    table.insert(places, { id = id, tools = {} })
                end
                return { farmId = farmId, places = places, tools = {} }
            end,
            registerListener = function(id, fn) world.listener = fn return true end,
            unregisterListener = function() world.listener = nil end,
            release = function(vehicle) table.insert(world.calls.released, vehicle.id) return true end,
            -- 102: the stage gate.
            authorize = function(vehicle) vehicle.stage = "authorized" return true end,
            getStage = function(vehicle) return vehicle.stage or "inspection" end,
            isWorkLocked = function(vehicle) return vehicle.stage ~= "authorized" end,
        },
    }
    if def.noADS then
        world.adsEnv = nil
    end
    TheContractorDrivers = { getModEnv = function() return world.adsEnv end }

    -- Fields: a 100 m square from (0, 0) to (100, 100), def { id, owner, small }.
    world.fields = {}
    function world:addField(fieldDef)
        local size = fieldDef.small and 10 or 100
        local field = { id = fieldDef.id, owner = fieldDef.owner or 0,
            nodes = { { 0, 0 }, { size, 0 }, { size, size }, { 0, size } },
            fieldState = { fruitTypeIndex = FruitType.MAIZE, growthState = 4 } }
        function field:getPolygonPoints() return self.nodes end
        function field:getFieldState() return self.fieldState end
        function field:getId() return self.id end
        function field:getOwner() return self.owner end
        function field:getName() return tostring(self.id) end
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

    world.models = def.models or {
        { xml = "fendt942.xml", category = "TRACTORSL", specs = { AdvancedDamageSystem = true, drivable = true },
            width = 3, length = 6 },
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
        local vehicle = { name = data.storeItem.xmlFilename, propertyState = data.propertyState, farmId = data.farmId,
            rootNode = { x = data.x, z = data.z } }
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
    world:load("src/placeables/PlaceableTCParkingSlot.lua")
    world:load("src/placeables/PlaceableTCRepairZone.lua")
    world:load("src/util/TCADSRepairContracts.lua")
    world:load("src/business/Job.lua")
    world:load("src/business/Jobs.lua")
    world:load("src/business/YardBales.lua")
    world:load("src/business/YardHaul.lua")
    world:load("src/business/EmergencyRefuel.lua")
    world:load("src/business/CropSpill.lua")
    world:load("src/business/RepairContracts.lua")
    world:load("src/business/FarmerFleet.lua")
    world:load("src/business/FieldBreakdowns.lua")

    TCADSRepairContracts.getEnv = function() return world.adsEnv end
    TCADSRepairContracts.detect()

    tc.Jobs = TheContractorJobs.new()
    tc.RepairContracts = TheContractorRepairContracts.new()
    tc.FieldBreakdowns = TheContractorFieldBreakdowns.new()

    -- The framework, down to the definition the event type gives it.
    local randomEvents = {}
    function randomEvents:registerEventType(key, definition) world.definition = definition end
    tc.FieldBreakdowns:register(randomEvents)

    -- The incident 068 would open now, its stage run straight away.
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

-- A breakdown offered on field 3: triggered, placed, prepared.
local function makeOffer(world, tc, fieldService)
    world:addField({ id = 3 })
    tc.FieldBreakdowns.forcedFieldService = fieldService
    world:trigger()
    tc.RepairContracts:update(TheContractorRepairContracts.PLACE_CHECK_MS)
    local vehicle = world:finishLoad()
    return tc.Jobs:getAllJobs(1)[1], vehicle
end

-- The roll -----------------------------------------------------------------------------

test("the rate: none without ADS, a quarter until the farm has a tool box or a van", function()
    setup({ noADS = true })
    assertEquals(TheContractorFieldBreakdowns.getRate(1), 0)

    local world = setup()
    local full = TheContractorFieldBreakdowns.RATE_PER_PERIOD
    assertNear(TheContractorFieldBreakdowns.getRate(1), full * TheContractorFieldBreakdowns.NO_KIT_RATE_FACTOR, 0.0001)
    world.farmPlaces = { "ownWorkshop" }
    assertNear(TheContractorFieldBreakdowns.getRate(1), full * TheContractorFieldBreakdowns.NO_KIT_RATE_FACTOR, 0.0001,
        "a workshop can't go out to a field")
    world.farmPlaces = { "player" }
    assertNear(TheContractorFieldBreakdowns.getRate(1), full, 0.0001)
    world.farmPlaces = { "ownMobile" }
    assertNear(TheContractorFieldBreakdowns.getRate(1), full, 0.0001)
end)

test("the field service: mostly a tool box's with only a tool box, even odds otherwise", function()
    local world = setup()
    local pick = TheContractorFieldBreakdowns.pickFieldService
    local share = TheContractorFieldBreakdowns.TOOL_BOX_PLAYER_SHARE
    world.farmPlaces = { "player" }
    assertEquals(pick(1, function() return share - 0.01 end), "player")
    assertEquals(pick(1, function() return share + 0.01 end), "mobile")
    world.farmPlaces = { "player", "ownMobile" }
    assertEquals(pick(1, function() return 0.49 end), "player")
    assertEquals(pick(1, function() return 0.51 end), "mobile")
    world.farmPlaces = {}
    assertEquals(pick(1, function() return 0.6 end), "mobile")
end)

test("only an NPC's field with no live job, one breakdown at a time, never without ADS", function()
    local world, tc = setup()
    world:addField({ id = 1, owner = 1 })
    assertEquals(world.definition.canTrigger(1), nil, "the farm's own field")
    world:addField({ id = 2 })
    tc.Jobs.isFieldProtected = function(_, fieldId) return fieldId == 2 end
    assertEquals(world.definition.canTrigger(1), nil, "a job's on it")
    world:addField({ id = 3 })
    local data = world.definition.canTrigger(1)
    assertEquals(data.fieldId, 3)
    assertTrue(data.severity >= 1 and data.severity <= 3)

    world:trigger()
    assertEquals(#tc.RepairContracts.arrivals, 1)
    assertEquals(world.definition.canTrigger(1), nil, "one already on its way")

    world = setup({ noADS = true })
    world:addField({ id = 3 })
    assertEquals(world.definition.canTrigger(1), nil)
end)

test("the console forces the field service, and refuses anything else", function()
    local world, tc = setup()
    world:addField({ id = 3 })
    local console = world.definition.console
    assertEquals(console.prepareTrigger(1, { "Mobile" }), nil)
    assertEquals(world.definition.canTrigger(1).fieldService, "mobile")
    console.clearTrigger()
    assertEquals(tc.FieldBreakdowns.forcedFieldService, nil)
    assertTrue(console.prepareTrigger(1, { "tow" }) ~= nil, "refused")
    assertEquals(tc.FieldBreakdowns.forcedFieldService, nil)
    assertEquals(console.prepareTrigger(1, {}), nil)
end)

-- How far (x, z) is from the 100 m square field's nearest edge.
local function edgeDistance(x, z)
    return math.min(x, z, 100 - x, 100 - z)
end

test("a spot on the headland, within 10 m of the edge, facing in; none on a field too small", function()
    local world = setup()
    world:addField({ id = 3 })
    world:addField({ id = 4, small = true })
    local model = { width = 3, length = 6 }
    local gap = TheContractorFieldBreakdowns.EDGE_GAP
    for seed = 1, 20 do
        math.randomseed(seed)
        local x, z, rotY = TheContractorFieldBreakdowns.pickSpot(3, model, math.random)
        local distance = edgeDistance(x, z)
        assertTrue(distance >= 3 + gap - 0.01, "clear of every edge, got " .. distance)
        assertTrue(distance <= TheContractorFieldBreakdowns.MAX_EDGE_DEPTH + 0.01, "near the edge, got " .. distance)
        -- It came in over the edge behind it, and the field's ahead.
        local function onField(distance)
            local px, pz = x + math.sin(rotY) * distance, z + math.cos(rotY) * distance
            return px > 0 and px < 100 and pz > 0 and pz < 100
        end
        assertTrue(not onField(-12) and onField(6), "facing in")
    end
    assertTrue(TheContractorFieldBreakdowns.pickSpot(4, model, math.random) ~= nil, "a tractor fits a 10 m field")
    assertEquals(TheContractorFieldBreakdowns.pickSpot(4, { width = 4, length = 10 }, math.random), nil)

    -- A machine too big for 10 m goes as far in as it must.
    local depth = TheContractorFieldBreakdowns.getEdgeDepth({ width = 6, length = 20 })
    assertNear(depth[1], 10 + gap, 0.001)
    assertNear(depth[2], 10 + gap, 0.001)
end)

test("once it's placed, its ruts in from the edge and the crop round it are cleared, on the field only", function()
    local world, tc = setup()
    local job, vehicle = makeOffer(world, tc, "player")
    assertTrue(job ~= nil)
    assertTrue(#world.painted >= 3, "two ruts and the patch")
    for _, call in ipairs(world.painted) do
        local mx, mz = (call.wx + call.hx) / 2, (call.wz + call.hz) / 2
        assertTrue(mx > 0 and mx < 100 and mz > 0 and mz < 100, "painted on the field")
    end
    -- The patch is last, on the machine, 2 m bigger than it all round.
    local patch = world.painted[#world.painted]
    local data = world.calls.spawned[1]
    assertNear((patch.wx + patch.hx) / 2, data.x, 0.001)
    assertNear((patch.wz + patch.hz) / 2, data.z, 0.001)
    local margin = TCJoyriderRuts.MACHINE_PATCH_MARGIN * 2
    assertNear(math.sqrt((patch.wx - patch.sx) ^ 2 + (patch.wz - patch.sz) ^ 2), 3 + margin, 0.001)
    assertNear(math.sqrt((patch.hx - patch.sx) ^ 2 + (patch.hz - patch.sz) ^ 2), 6 + margin, 0.001)
end)

test("a spot that's retried leaves nothing painted until the machine's there", function()
    local world, tc = setup()
    world:addField({ id = 3 })
    world:trigger()
    world.spotBlocked = { true }
    tc.RepairContracts:update(TheContractorRepairContracts.PLACE_CHECK_MS)
    world.prepareResults = { false }
    tc.RepairContracts:update(TheContractorRepairContracts.PLACE_CHECK_MS)
    world:finishLoad()
    assertEquals(#world.painted, 0)
end)

-- The offer -----------------------------------------------------------------------------

test("a breakdown is placed on its spot, prepared as ADS's breakdown and offered due today", function()
    local world, tc = setup()
    local job, vehicle = makeOffer(world, tc, "mobile")
    assertEquals(#tc.RepairContracts.arrivals, 0)
    local data = world.calls.spawned[1]
    assertEquals(data.propertyState, VehiclePropertyState.MISSION)
    assertTrue(data.x > 0 and data.x < 100 and data.z > 0 and data.z < 100, "on the field")

    assertEquals(world.prepared.kind, "breakdown")
    assertEquals(world.prepared.fieldService, "mobile")

    assertEquals(job.jobType, "adsBreakdown")
    assertEquals(job.fieldId, 0)
    assertEquals(job.state, TheContractorJob.STATE.OFFERED)
    assertEquals(job.deadlineDay, world.today)
    assertEquals(job.workshop.offerExpiresDay, world.today)
    assertEquals(job.workshop.fieldId, 3)
    assertEquals(job.workshop.kind, "breakdown")
    assertEquals(job.workshop.serviceLevel, "mobile")
    assertEquals(job.workshop.zoneUniqueId, nil)
    assertTrue(job:getPrice() >= 1119 and job:getPrice() <= 1280, "the parts plus the field's 40-60%, floored")
    assertTrue(TheContractorRepairContracts.isBreakdownJob(job))
    assertTrue(TheContractorRepairContracts.isContractVehicle(vehicle))
end)

test("it's placed on the next look at the queue", function()
    local world, tc = setup()
    world:addField({ id = 3 })
    world:trigger()
    tc.RepairContracts:update(TheContractorRepairContracts.PLACE_CHECK_MS)
    assertEquals(#world.calls.spawned, 1)
end)

test("a taken spot gets another, and a model ADS turns down another model", function()
    local world, tc = setup()
    world:addField({ id = 3 })
    world:trigger()
    local entry = tc.RepairContracts.arrivals[1]
    entry.x, entry.z = -1, -1
    world.spotBlocked = { true }
    tc.RepairContracts:update(TheContractorRepairContracts.PLACE_CHECK_MS)
    assertEquals(#world.calls.spawned, 0)
    assertTrue(entry.x > 0 and entry.z > 0, "moved to another spot on the field")

    world.prepareResults = { false }
    tc.RepairContracts:update(TheContractorRepairContracts.PLACE_CHECK_MS)
    local first = world:finishLoad()
    assertTrue(first.isDeleted)
    assertEquals(#tc.RepairContracts.arrivals, 1, "another go")
    tc.RepairContracts:update(TheContractorRepairContracts.PLACE_CHECK_MS)
    world:finishLoad()
    assertEquals(#tc.Jobs:getAllJobs(1), 1)
end)

test("one not placed by midnight is dropped", function()
    local world, tc = setup()
    world:addField({ id = 3 })
    world:trigger()
    TheContractorRepairContracts.ARRIVAL_CHANCE = 0
    g_currentMission.environment.currentMonotonicDay = world.today + 1
    tc.RepairContracts:onDayChanged()
    assertEquals(#tc.RepairContracts.arrivals, 0)
end)

-- Accepting ------------------------------------------------------------------------------

test("without a tool box or a van for a tool box job, or a van for a mobile one, it warns but can be taken on", function()
    local world, tc = setup()
    local job = makeOffer(world, tc, "player")
    assertEquals(TheContractorJobs.getAcceptProblem(job), nil, "a hired mobile workshop can always go out")
    assertTrue(TheContractorRepairContracts.getToolsWarning(job) ~= nil, "warned")
    assertEquals(#TheContractorRepairContracts.getMissingKit(job).names, 2, "a tool box or a van would do")
    assertEquals(tc.Jobs:proposeCounterOffer(1, job.id, 900), nil, "priced through a quote instead")
    world.farmPlaces = { "ownWorkshop" }
    assertTrue(TheContractorRepairContracts.getToolsWarning(job) ~= nil, "the workshop can't go out to it")
    world.farmPlaces = { "player" }
    assertEquals(TheContractorRepairContracts.getToolsWarning(job), nil)

    world, tc = setup()
    job = makeOffer(world, tc, "mobile")
    world.farmPlaces = { "player" }
    assertTrue(TheContractorRepairContracts.getToolsWarning(job) ~= nil, "warned")
    assertEquals(#TheContractorRepairContracts.getMissingKit(job).names, 1, "only a van will do")
    world.farmPlaces = { "ownMobile" }
    assertEquals(TheContractorRepairContracts.getToolsWarning(job), nil)
    assertEquals(TheContractorRepairContracts.getMissingKit(job), nil)
    assertEquals(tc.RepairContracts:proposeQuote(1, job.id, 0.5), "accepted", "priced against the field benchmark")
    assertNear(job.workshop.benchmarkMargin, 0.5, 0.0001)
end)

test("fewer breakdowns while the farm's known for overcharging", function()
    local world, tc = setup({ farmPlaces = { "player" } })
    local rate = TheContractorFieldBreakdowns.getRate(1)
    tc.RepairContracts.overcharged[1] = { untilDay = world.today + 3 }
    assertNear(TheContractorFieldBreakdowns.getRate(1), rate * TheContractorRepairContracts.OVERCHARGE_ARRIVAL_FACTOR,
        0.0001)
end)

-- Ending --------------------------------------------------------------------------------

test("a lapsed offer: the customer has it recovered from where it stands", function()
    local world, tc = setup()
    local job, vehicle = makeOffer(world, tc, "player")
    g_currentMission.environment.currentMonotonicDay = world.today + 1
    tc.Jobs:onDayChanged()
    assertEquals(job.state, TheContractorJob.STATE.DECLINED)
    assertEquals(#world.calls.reputation, 0, "an offer let go costs nothing")
    assertEquals(world.calls.released[1], vehicle.id)
    tc.RepairContracts:update(TheContractorRepairContracts.PLACE_CHECK_MS)
    assertTrue(vehicle.isDeleted)
end)

test("done in ADS completes it; left undone it's missed at midnight", function()
    local world, tc = setup({ farmPlaces = { "player" } })
    local job, vehicle = makeOffer(world, tc, "player")
    tc.Jobs:transitionJobState(1, job.id, TheContractorJob.STATE.ACCEPTED)
    tc.RepairContracts:resolveSavedVehicles()
    world.status[vehicle.id] = "done"
    world.listener(vehicle, { state = "done" })
    assertEquals(job.state, TheContractorJob.STATE.COMPLETED)
    assertEquals(world.calls.invoices[1], job.id)

    world, tc = setup({ farmPlaces = { "player" } })
    job, vehicle = makeOffer(world, tc, "player")
    tc.Jobs:transitionJobState(1, job.id, TheContractorJob.STATE.ACCEPTED)
    g_currentMission.environment.currentMonotonicDay = world.today + 1
    tc.Jobs:onDayChanged()
    assertEquals(job.state, TheContractorJob.STATE.MISSED)
    assertTrue(world.calls.reputation[1] < 0)
    assertEquals(#tc.RepairContracts.removals, 1)
end)

-- Saving and streaming -------------------------------------------------------------------

test("a breakdown's field streams and saves with the job, and a queued one saves its spot", function()
    local world, tc = setup()
    local job = makeOffer(world, tc, "mobile")
    local stream = world:newStream()
    TheContractorJobs.writeJob(stream, job)
    local copy = TheContractorJobs.readJob(stream)
    assertEquals(copy.workshop.fieldId, 3)
    assertEquals(copy.workshop.serviceLevel, "mobile")

    local xmlFile = {}
    tc.Jobs:saveToXmlFile(xmlFile)
    local jobs = TheContractorJobs.new()
    jobs:loadFromXMLFile(xmlFile)
    assertEquals(jobs:getJob(1, job.id).workshop.fieldId, 3)

    world, tc = setup()
    world:addField({ id = 3 })
    tc.FieldBreakdowns.forcedFieldService = "player"
    world:trigger()
    local entry = tc.RepairContracts.arrivals[1]
    xmlFile = {}
    tc.RepairContracts:saveToXmlFile(xmlFile)
    local loaded = TheContractorRepairContracts.new()
    loaded:loadFromXMLFile(xmlFile)
    local copied = loaded.arrivals[1]
    assertEquals(copied.fieldId, 3)
    assertEquals(copied.kind, "breakdown")
    assertEquals(copied.fieldService, "player")
    assertNear(copied.x, entry.x, 0.001)
    assertNear(copied.rotY, entry.rotY, 0.001)
    assertEquals(copied.zoneUniqueId, nil)
end)

-- 121: the farmer's own machine ------------------------------------------------------------

-- Farmer 4 holding field 3 (farmland 3), with these machines, on 110's real
-- Farmers.
local function addFarmer(world, tc, machines)
    world:load("src/business/Farmers.lua")
    local field = world:addField({ id = 3 })
    local farmland = { getId = function() return 3 end }
    function field:getFarmland() return farmland end
    tc.Farmers = TheContractorFarmers.new()
    tc.Farmers.officialId = 99
    tc.Farmers.people[99] = { id = 99, name = "The Official", isOfficial = true, farmlandIds = {} }
    local farmer = { id = 4, name = "Tom", isOfficial = false, farmlandIds = { 3 }, targetAcres = 50,
        machines = machines }
    tc.Farmers.people[4] = farmer
    return farmer
end

local COMBINE_MODELS = {
    { xml = "fendt942.xml", category = "TRACTORSL", specs = { AdvancedDamageSystem = true, drivable = true },
        width = 3, length = 6 },
    { xml = "lexion.xml", category = "HARVESTERS", specs = { AdvancedDamageSystem = true, drivable = true,
        combine = true }, width = 4, length = 9 },
    { xml = "header.xml", category = "CUTTERS", specs = { cutter = true }, width = 9, length = 2 },
    { xml = "trailer.xml", category = "TRAILERS", specs = { trailer = true }, width = 3, length = 8 },
}

local function combineFleet()
    return {
        { id = 1, role = "largeTractor", xmlFilename = "fendt942.xml", seed = 11, hours = 2000, hoursDay = 10,
            hoursPerMonth = 30, fitted = {} },
        { id = 2, role = "combine", xmlFilename = "lexion.xml", seed = 22, hoursPerMonth = 30, fitted = {} },
        { id = 3, role = "header", attachedTo = 2, xmlFilename = "header.xml", seed = 33, fitted = {} },
        { id = 4, role = "trailer", xmlFilename = "trailer.xml", seed = 44, fitted = {} },
    }
end

test("121: a breakdown on a farmer's field is their own machine: its seed and age, the farmer the customer", function()
    local world, tc = setup()
    addFarmer(world, tc, {
        { id = 1, role = "mediumTractor", xmlFilename = "fendt942.xml", seed = 99, hours = 2000, hoursDay = 10,
            hoursPerMonth = 30, fitted = {} },
    })
    tc.FieldBreakdowns.forcedFieldService = "mobile"
    world:trigger()
    local entry = tc.RepairContracts.arrivals[1]
    assertEquals(entry.farmerId, 4)
    assertEquals(entry.machineId, 1)
    assertEquals(entry.seed, 99)
    assertNear(entry.operatingHours, 2000, 0.001)
    tc.RepairContracts:update(TheContractorRepairContracts.PLACE_CHECK_MS)
    world:finishLoad()
    assertEquals(world.prepared.seed, 99)
    assertNear(world.prepared.operatingHours, 2000, 0.001)

    local job = tc.Jobs:getAllJobs(1)[1]
    assertTrue(TheContractorRepairContracts.isBreakdownJob(job))
    assertTrue(not TheContractorRepairContracts.isFavourJob(job))
    assertEquals(job.workshop.farmerId, 4)
    assertEquals(job.workshop.machineId, 1)
    assertEquals(job.customerId, 4)
    assertTrue(TheContractorFarmerFleet.isMachineOut(4, 1))
    assertTrue(TheContractorFieldBreakdowns.hasOpenBreakdown(1), "still one at a time")
end)

test("121: its first time out, ADS's age becomes the machine's", function()
    local world, tc = setup()
    local farmer = addFarmer(world, tc, {
        { id = 1, role = "mediumTractor", xmlFilename = "fendt942.xml", seed = 99, hoursPerMonth = 30, fitted = {} },
    })
    world:trigger()
    tc.RepairContracts:update(TheContractorRepairContracts.PLACE_CHECK_MS)
    world:finishLoad()
    assertEquals(world.prepared.operatingHours, nil, "ADS ages it")
    assertEquals(farmer.machines[1].hours, 3100)
    assertEquals(farmer.machines[1].hoursDay, world.today)
end)

test("121: their combine HARVESTER_SHARE of the time, never in winter, else the rest", function()
    local world, tc = setup({ models = COMBINE_MODELS })
    local farmer = addFarmer(world, tc, combineFleet())
    local low = function() return 0.1 end
    local high = function() return 0.9 end
    assertEquals(TheContractorFieldBreakdowns.pickFarmerMachine(farmer, tc.RepairContracts, low).machine.id, 2)
    assertEquals(TheContractorFieldBreakdowns.pickFarmerMachine(farmer, tc.RepairContracts, high).machine.id, 1,
        "never the trailer or the header")

    Season = { WINTER = 4 }
    g_currentMission.environment.getSeasonAtDay = function() return Season.WINTER end
    assertEquals(TheContractorFieldBreakdowns.pickFarmerMachine(farmer, tc.RepairContracts, low).machine.id, 1)
    g_currentMission.environment.getSeasonAtDay = nil

    -- Only a combine: always it.
    farmer.machines = { combineFleet()[2] }
    assertEquals(TheContractorFieldBreakdowns.pickFarmerMachine(farmer, tc.RepairContracts, high).machine.id, 2)
end)

test("121: a combine comes with its header, the spot found for both", function()
    local world, tc = setup({ models = COMBINE_MODELS })
    local farmer = addFarmer(world, tc, { combineFleet()[2], combineFleet()[3] })
    world:trigger()
    local entry = tc.RepairContracts.arrivals[1]
    assertEquals(entry.machineId, 2)
    assertEquals(entry.attachment.machineId, 3)
    assertEquals(entry.attachment.xmlFilename, "header.xml")
    local footprint = tc.RepairContracts:getArrivalModel(entry)
    assertEquals(footprint.width, 9, "as wide as the header")
    assertEquals(footprint.length, 11, "the combine and the header")
    assertEquals(footprint.xmlFilename, "lexion.xml")
end)

test("121: no farmer, or nothing of theirs ADS can take: a random model and no customer", function()
    local world, tc = setup()
    addFarmer(world, tc, { { id = 1, role = "trailer", xmlFilename = "trailer.xml", seed = 1, fitted = {} } })
    world:trigger()
    local entry = tc.RepairContracts.arrivals[1]
    assertEquals(entry.machineId, nil)
    assertEquals(entry.farmerId, nil)
    assertEquals(entry.xmlFilename, "fendt942.xml")
end)

test("121: a farmer's machine ADS turns down is loaded again, then dropped, never swapped", function()
    local world, tc = setup()
    addFarmer(world, tc, {
        { id = 1, role = "mediumTractor", xmlFilename = "fendt942.xml", seed = 99, hoursPerMonth = 30, fitted = {} },
    })
    world:trigger()
    for _ = 1, TheContractorRepairContracts.PREPARE_RETRIES do
        world.prepareResults = { false }
        tc.RepairContracts:update(TheContractorRepairContracts.PLACE_CHECK_MS)
        world:finishLoad()
        local entry = tc.RepairContracts.arrivals[1]
        assertEquals(entry.machineId, 1)
        assertEquals(entry.seed, 99)
    end
    world.prepareResults = { false }
    tc.RepairContracts:update(TheContractorRepairContracts.PLACE_CHECK_MS)
    world:finishLoad()
    assertEquals(#tc.RepairContracts.arrivals, 0)
    assertEquals(#tc.Jobs:getAllJobs(1), 0)
end)

test("121: the farmer's machine and its attachment stream and save with the job and the queue", function()
    local world, tc = setup({ models = COMBINE_MODELS })
    addFarmer(world, tc, { combineFleet()[2], combineFleet()[3] })
    localDirectionToWorld = function() return 0, 0, 1 end
    TCJobSiteSetup = { hitchImplement = function() return true end }
    world:trigger()

    local xmlFile = {}
    tc.RepairContracts:saveToXmlFile(xmlFile)
    local loaded = TheContractorRepairContracts.new()
    loaded:loadFromXMLFile(xmlFile)
    local copied = loaded.arrivals[1]
    assertEquals(copied.farmerId, 4)
    assertEquals(copied.machineId, 2)
    assertEquals(copied.attachment.machineId, 3)
    assertEquals(copied.attachment.xmlFilename, "header.xml")
    assertNear(copied.attachment.length, 2, 0.001)

    tc.RepairContracts:update(TheContractorRepairContracts.PLACE_CHECK_MS)
    world:finishLoad()
    local header = world:finishLoad()
    local job = tc.Jobs:getAllJobs(1)[1]
    assertEquals(job.workshop.attachmentId, header.id)

    local stream = world:newStream()
    TheContractorJobs.writeJob(stream, job)
    assertEquals(TheContractorJobs.readJob(stream).workshop.attachmentId, header.id)

    xmlFile = {}
    tc.Jobs:saveToXmlFile(xmlFile)
    local jobs = TheContractorJobs.new()
    jobs:loadFromXMLFile(xmlFile)
    local workshop = jobs:getJob(1, job.id).workshop
    assertEquals(workshop.farmerId, 4)
    assertEquals(workshop.machineId, 2)
    assertEquals(workshop.attachmentMachineId, 3)
    assertEquals(workshop.attachmentId, nil, "until the vehicles are back")
    jobs:resolveSavedVehicles()
    assertEquals(workshop.attachmentId, header.id)

    -- Waiting to be collected, the machine's still out.
    tc.Jobs:transitionJobState(1, job.id, TheContractorJob.STATE.DECLINED)
    xmlFile = {}
    tc.RepairContracts:saveToXmlFile(xmlFile)
    loaded = TheContractorRepairContracts.new()
    loaded:loadFromXMLFile(xmlFile)
    assertEquals(#loaded.removals, 2)
    assertEquals(loaded.removals[1].machineId, 2)
    assertEquals(loaded.removals[2].machineId, 3)
end)

-- 123: in the farmer's yard ------------------------------------------------------------------

-- The farmer's yard 5: one synced spot 20 m north of its middle, well off
-- field 3; world.isOpen says which ground's open, world.yardOwner who owns it.
local function addYard(world, tc, farmer)
    farmer.yardFarmlandId = 5
    world.yardOwner = 0
    world.isOpen = function() return true end
    tc.Yards = {
        getSpots = function(_, farmlandId)
            return farmlandId == 5 and { x = 0, z = 500, spots = { { x = 0, z = 520 } } } or nil
        end,
    }
    TheContractorYards = { isOpenGround = function(_, x, z) return world.isOpen(x, z) end }
    g_farmlandManager = { getFarmlandOwner = function() return world.yardOwner end }
end

-- A random() whose first roll is first, then math.random's.
local function firstRoll(first)
    local used = false
    return function()
        if not used then
            used = true
            return first
        end
        return math.random()
    end
end

local TRACTOR = { id = 1, role = "mediumTractor", xmlFilename = "fendt942.xml", seed = 99, hours = 2000,
    hoursDay = 10, hoursPerMonth = 30, fitted = {} }

test("123: a farmer's machine breaks down in their yard YARD_SHARE of the time, facing its middle", function()
    local world, tc = setup()
    local farmer = addFarmer(world, tc, {})
    addYard(world, tc, farmer)
    local model = { width = 3, length = 6 }
    local share = TheContractorFieldBreakdowns.YARD_SHARE

    local spot = TheContractorFieldBreakdowns.pickFarmerSpot(farmer, 3, model, firstRoll(share * 0.5))
    assertEquals(spot.yardFarmlandId, 5)
    assertEquals(spot.fieldId, nil)
    assertEquals(spot.x, 0)
    assertEquals(spot.z, 520)
    assertNear(math.abs(spot.rotY), math.pi, 0.0001, "facing the yard's middle, south")

    spot = TheContractorFieldBreakdowns.pickFarmerSpot(farmer, 3, model, firstRoll(share + (1 - share) * 0.5))
    assertEquals(spot.yardFarmlandId, nil)
    assertEquals(spot.fieldId, 3)

    -- No room for its corners, a player owns the yard, or no yard: the field.
    world.isOpen = function(x, z) return math.abs(x) < 1 end
    assertEquals(TheContractorFieldBreakdowns.pickFarmerSpot(farmer, 3, model, firstRoll(0)).fieldId, 3)
    world.isOpen = function() return true end
    world.yardOwner = 1
    assertEquals(TheContractorFieldBreakdowns.pickFarmerSpot(farmer, 3, model, firstRoll(0)).fieldId, 3)
    world.yardOwner = 0
    farmer.yardFarmlandId = nil
    assertEquals(TheContractorFieldBreakdowns.pickFarmerSpot(farmer, 3, model, firstRoll(0)).fieldId, 3)
end)

test("123: a yard breakdown is offered due today with the yard and no field, retried in the yard, and saved", function()
    local world, tc = setup()
    local farmer = addFarmer(world, tc, { TRACTOR })
    addYard(world, tc, farmer)
    TheContractorFieldBreakdowns.YARD_SHARE = 1
    tc.FieldBreakdowns.forcedFieldService = "player"
    world:trigger()

    local entry = tc.RepairContracts.arrivals[1]
    assertEquals(entry.yardFarmlandId, 5)
    assertEquals(entry.fieldId, nil)
    assertEquals(entry.kind, "breakdown")
    assertTrue(TheContractorFieldBreakdowns.hasOpenBreakdown(1), "still one at a time")

    local xmlFile = {}
    tc.RepairContracts:saveToXmlFile(xmlFile)
    local loaded = TheContractorRepairContracts.new()
    loaded:loadFromXMLFile(xmlFile)
    local copied = loaded.arrivals[1]
    assertEquals(copied.yardFarmlandId, 5)
    assertEquals(copied.fieldId, nil)
    assertEquals(copied.kind, "breakdown")
    assertEquals(copied.machineId, 1)
    assertNear(copied.z, 520, 0.001)

    -- Its spot's taken: another in the same yard.
    entry.x, entry.z = -1, -1
    world.spotBlocked = { true }
    tc.RepairContracts:update(TheContractorRepairContracts.PLACE_CHECK_MS)
    assertEquals(#world.calls.spawned, 0)
    assertEquals(entry.yardFarmlandId, 5)
    assertEquals(entry.z, 520)

    tc.RepairContracts:update(TheContractorRepairContracts.PLACE_CHECK_MS)
    world:finishLoad()
    assertEquals(world.prepared.kind, "breakdown")
    assertEquals(#world.painted, 0, "no ruts in a yard")
    local job = tc.Jobs:getAllJobs(1)[1]
    assertTrue(TheContractorRepairContracts.isBreakdownJob(job))
    assertEquals(job.deadlineDay, world.today)
    assertEquals(job.workshop.yardFarmlandId, 5)
    assertEquals(job.workshop.fieldId, nil)
    assertEquals(job.workshop.serviceLevel, "player")
    assertEquals(job.customerId, 4)
    assertEquals(job.workshop.benchmarkMargin, 0.5, "priced against the field margin, as a breakdown")

    local stream = world:newStream()
    TheContractorJobs.writeJob(stream, job)
    local copy = TheContractorJobs.readJob(stream)
    assertEquals(copy.workshop.yardFarmlandId, 5)
    assertEquals(copy.workshop.fieldId, nil)
    xmlFile = {}
    tc.Jobs:saveToXmlFile(xmlFile)
    local jobs = TheContractorJobs.new()
    jobs:loadFromXMLFile(xmlFile)
    assertEquals(jobs:getJob(1, job.id).workshop.yardFarmlandId, 5)
end)

test("123: a yard breakdown with no room left in the yard is dropped, and one not placed by midnight too", function()
    local world, tc = setup()
    local farmer = addFarmer(world, tc, { TRACTOR })
    addYard(world, tc, farmer)
    TheContractorFieldBreakdowns.YARD_SHARE = 1
    world:trigger()
    world.isOpen = function() return false end
    world.spotBlocked = { true }
    tc.RepairContracts:update(TheContractorRepairContracts.PLACE_CHECK_MS)
    assertEquals(#tc.RepairContracts.arrivals, 0)

    world.isOpen = function() return true end
    world:trigger()
    assertEquals(tc.RepairContracts.arrivals[1].yardFarmlandId, 5)
    TheContractorRepairContracts.ARRIVAL_CHANCE = 0
    g_currentMission.environment.currentMonotonicDay = world.today + 1
    tc.RepairContracts:onDayChanged()
    assertEquals(#tc.RepairContracts.arrivals, 0)
end)

-- The map marker --------------------------------------------------------------------------

test("a marker on the machine while it's offered or taken on, gone after", function()
    local world, tc = setup()
    FarmManager.SPECTATOR_FARM_ID = 0
    world.shown = {}
    AbstractFieldMissionHotspot = {
        new = function()
            local hotspot = {}
            function hotspot:setWorldRadius(radius) self.radius = radius end
            function hotspot:setWorldPosition(x, z) self.x, self.z = x, z end
            function hotspot:delete() self.deleted = true end
            return hotspot
        end,
    }
    g_currentMission.hud = {}
    function g_currentMission:addMapHotspot(hotspot) world.shown[hotspot] = true end
    function g_currentMission:removeMapHotspot(hotspot) world.shown[hotspot] = nil end
    world:load("src/util/TCJobHotspots.lua")
    TCJobHotspots.reset()

    local job, vehicle = makeOffer(world, tc, "player")
    TCJobHotspots.refresh()
    local hotspot = next(world.shown)
    assertTrue(hotspot ~= nil)
    assertEquals(hotspot.radius, TCJobHotspots.MACHINE_RADIUS)
    assertNear(hotspot.x, vehicle.rootNode.x, 0.001)
    assertNear(hotspot.z, vehicle.rootNode.z, 0.001)

    vehicle.rootNode.x = 50
    TCJobHotspots.refresh()
    assertNear(hotspot.x, 50, 0.001, "it follows the machine")

    tc.Jobs:transitionJobState(1, job.id, TheContractorJob.STATE.DECLINED)
    TCJobHotspots.refresh()
    assertEquals(next(world.shown), nil)
    assertTrue(hotspot.deleted)
end)
