-- 100: ADS repair contracts. The real Job, Jobs, RepairContracts, the ADS
-- wrapper and the repair zone placeable, with FS25_AdvancedDamageSystem's
-- ADS_RepairContracts faked through TCADSRepairContracts.getEnv, and the
-- rest of the mod (Finances, Inbox, Logbook, ...) faked just enough.

local ADS_KIND = { REPAIR = "repair", MAINTENANCE = "maintenance" }

local function setup(def)
    def = def or {}
    local world = stubs.install()
    world.today = 10
    world.calls = { invoices = {}, logged = {}, messages = {}, notices = {}, charged = {}, claimLogs = {},
        reputation = {}, spawned = {}, deleted = {}, released = {} }

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
        return node.x or 0, 0, node.z or 0
    end
    VehiclePropertyState = { OWNED = 1, MISSION = 4 }
    VehicleLoadingState = { OK = 1 }
    Environment = { PERIODS_IN_YEAR = 12 }
    TheContractor = { SaveKey = "TheContractor" }
    Event = { new = function(mt) return setmetatable({}, mt) end }
    InitEventClass = function() end

    g_currentMission.environment = {
        currentMonotonicDay = world.today,
        dayTime = 0,
        daysPerPeriod = 1,
        -- TCCalendar's: today's period as the day's below.
        currentYear = 1,
        currentPeriod = (world.today - 1) % 12 + 1,
        plannedDaysPerPeriod = 1,
        currentDayInPeriod = 1,
        getPeriodFromDay = function(_, day) return (day - 1) % 12 + 1 end,
        getDayInPeriodFromDay = function() return 1 end,
    }
    g_currentMission.getIsClient = function() return false end
    g_currentMission.placeableSystem = { placeables = {} }
    g_currentMission.playerSystem = { players = {} }
    function g_currentMission.playerSystem:getPlayerCount() return #self.players end
    function g_currentMission.playerSystem:getPlayerByIndex(i) return self.players[i] end

    -- The mod's own subsystems this touches.
    TheContractorNegotiation = { rollInitialEagerness = function() return 1 end, MAX_ROUNDS = 3 }
    TheContractorJobGeneration = {
        JOB_TYPES = {},
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
        isAreaClear = function() return world.bayBlocked ~= true end,
        getShowSlotsSetting = function() return false end,
    }
    TCParkingSlotFilter = { getCategoryTitle = function(name) return name end, SUMMARY_MAX_NAMES = 2 }

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
        hasLegalCover = function() return world.legalCover == true end,
        getReputationBonus = function() return 0 end,
    }
    tc.Finances = { invoiceJob = function(_, job) table.insert(world.calls.invoices, job.id) end }
    tc.Logbook = {
        recordJobCompleted = function(_, job, reward) table.insert(world.calls.logged, { "completed", job.id, reward }) end,
        recordJobMissed = function(_, job, penalty) table.insert(world.calls.logged, { "missed", job.id, penalty }) end,
    }
    tc.Inbox = {
        postMessage = function(_, farmId, kind, titleKey, bodyKey, args)
            table.insert(world.calls.messages, { kind = kind, titleKey = titleKey, bodyKey = bodyKey, args = args })
        end,
        removeMessagesForJob = function() end,
    }
    tc.Notices = { publish = function(_, farmId, text) table.insert(world.calls.notices, text) end }
    tc.Claims = {
        chargeClaim = function(_, farmId, amount, insured)
            table.insert(world.calls.charged, { amount = amount, insured = insured })
            return amount
        end,
        addToJobLog = function(_, farmId, jobId, claim) table.insert(world.calls.claimLogs, claim) end,
    }
    tc.Company = { hasCompany = function() return true end }
    g_farmManager.getFarmById = function() return { farmId = 1 } end

    -- ADS's repair contracts, per vehicle: world.status[vehicle.id] etc.
    -- 102: world.stages[vehicle.id] (inspection until authorized) and
    -- world.inspectionDates[vehicle.id] (a service's last inspection).
    world.status, world.farmTools, world.tampering, world.prepareResults = {}, {}, {}, {}
    world.stages, world.inspectionDates, world.calls.authorized = {}, {}, {}
    world.fitted = {}
    world.adsEnv = {
        ADS_RepairContracts = {
            getInfo = function() return { version = 1 } end,
            prepareVehicle = function(vehicle, request)
                local result = table.remove(world.prepareResults, 1)
                if result == false then
                    return false, "noApplicableFaults"
                end
                world.prepared = request
                vehicle.quote = { price = world.quotePrice or 1500, partsCost = world.partsCost or 1000,
                    laborHours = world.laborHours or 0, minTools = { "lift" }, serviceLevel = "workshop",
                    operatingHours = 2450 }
                world.stages[vehicle.id] = "inspection"
                return true, "rc1"
            end,
            authorize = function(vehicle)
                table.insert(world.calls.authorized, vehicle.id)
                world.stages[vehicle.id] = "authorized"
                return true
            end,
            getStage = function(vehicle) return world.stages[vehicle.id] end,
            isWorkLocked = function(vehicle) return world.stages[vehicle.id] == "inspection" end,
            getQuote = function(vehicle) return vehicle.quote end,
            getStatus = function(vehicle)
                if world.status[vehicle.id] == "noContract" then
                    return nil, "noContract"
                end
                return world.status[vehicle.id] ~= nil and { state = world.status[vehicle.id] } or { state = "open" }
            end,
            checkTampering = function(vehicle)
                local findings = world.tampering[vehicle.id] or {}
                return #findings > 0, findings
            end,
            checkFarmTools = function(vehicle, farmId)
                return world.farmTools[vehicle.id] or { canDo = true, missing = {} }
            end,
            getFarmTools = function(farmId)
                local places = {}
                for _, id in ipairs(world.farmPlaces or {}) do
                    table.insert(places, { id = id, tools = {} })
                end
                return { farmId = farmId, places = places, tools = {} }
            end,
            registerListener = function(id, fn) world.listener = fn return true end,
            unregisterListener = function() world.listener = nil end,
            release = function(vehicle) table.insert(world.calls.released, vehicle.id) return true end,
            -- 186: world.fitted[vehicle.id].
            getFittedParts = function(vehicle) return world.fitted[vehicle.id] or {} end,
        },
        ADS_Consumables = {
            getTierIndex = function(tier) return ({ LIZARD = 1, ORIGINAL = 2, PREMIUM = 3 })[tier] end,
        },
        ADS_Maintenance = {
            getPartPrice = function(vehicle, componentId) return world.partPrice end,
            getLastInspectionDate = function(vehicle) return world.inspectionDates[vehicle.id] end,
        },
        AdvancedDamageSystem = { PART_TYPES = { OEM = "OEM" } },
        -- 102: the own workshop upgrades and the tools each brings.
        ADS_OwnWorkshop = {
            getEquipmentIds = function() return { "lift", "crane", "machiningShop", "diagnosticBench" } end,
            getEquipmentConfig = function(id)
                local tools = { lift = { "lift" }, crane = { "lightCrane", "heavyCrane" },
                    machiningShop = { "machining" }, diagnosticBench = { "scanner", "bench" } }
                return { TOOLS = tools[id] }
            end,
        },
    }
    world.modTexts.FS25_AdvancedDamageSystem = { ads_ws_tool_lift = "Lift", ads_ws_tool_machining = "Machining",
        ads_ws_tool_jack = "jack and stands", ads_own_equipment_lift = "vehicle lift",
        ads_own_equipment_crane = "overhead crane", ads_own_equipment_machiningShop = "machine tools",
        ads_own_equipment_diagnosticBench = "diag. bench" }

    TheContractorDrivers = { getModEnv = function() return world.adsEnv end }

    world:load("src/util/TCVehicleIds.lua")
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
    world:load("src/business/FarmerFleet.lua")
    world:load("src/util/TCRepairZoneActivatable.lua")

    TCADSRepairContracts.getEnv = function() return world.adsEnv end
    TCADSRepairContracts.detect()

    tc.Jobs = TheContractorJobs.new()
    tc.RepairContracts = TheContractorRepairContracts.new()

    -- A repair zone: a 12 m x 9 m rectangle of 3 bays at the origin, its arrow
    -- along +z.
    function world:addZone(zoneDef)
        zoneDef = zoneDef or {}
        local zone = {
            uniqueId = zoneDef.uniqueId or "zone1",
            farmId = 1,
            [PlaceableTCRepairZone.KEY] = {
                startNode = { x = 0, z = 0 },
                widthNode = { x = zoneDef.width or 12, z = 0 },
                heightNode = { x = 0, z = zoneDef.length or 9 },
                zoneType = zoneDef.zoneType or PlaceableTCRepairZone.ZONE_TYPE.VEHICLE,
                bays = zoneDef.bays or 3,
                filter = PlaceableTCParkingSlot.newFilter(zoneDef.categories),
            },
        }
        function zone:getUniqueId() return self.uniqueId end
        function zone:getOwnerFarmId() return self.farmId end
        table.insert(g_currentMission.placeableSystem.placeables, zone)
        return zone
    end

    -- Store items: models[i] = { xml, category, specs = {...}, width, length }.
    world.models = def.models or {
        { xml = "fendt942.xml", category = "TRACTORSL", specs = { AdvancedDamageSystem = true, drivable = true },
            width = 3, length = 6 },
    }
    g_storeManager = {
        getItems = function()
            local items = {}
            for _, model in ipairs(world.models) do
                table.insert(items, { xmlFilename = model.xml, categoryName = model.category, name = model.xml,
                    rotation = 0 })
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
        getCategoryByName = function(_, name) return name ~= "BOGUS" and { title = name } or nil end,
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

    -- Vanilla's spawning: records the request; world:finishLoad() runs the
    -- callback with a new vehicle.
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
        local vehicle = { name = data.storeItem.xmlFilename, propertyState = data.propertyState, farmId = data.farmId }
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

    return world, tc
end

-- A ready-made offer: a zone, an arrival placed and loaded, the job.
local function makeOffer(world, tc)
    local zone = world:addZone()
    tc.RepairContracts:queueArrival(1, zone, 1, ADS_KIND.REPAIR, 2)
    tc.RepairContracts:update(TheContractorRepairContracts.PLACE_CHECK_MS)
    local vehicle = world:finishLoad()
    -- The new machine's job (a test may make more than one).
    local job = nil
    for _, candidate in ipairs(tc.Jobs:getAllJobs(1)) do
        if candidate.workshop.vehicleId == vehicle.id then
            job = candidate
        end
    end
    return job, vehicle, zone
end

-- Models and bays ------------------------------------------------------------------

test("models: ADS's specialization, drivable, a tractor or a harvester by zone type", function()
    setup()
    local vehicle, harvester = PlaceableTCRepairZone.ZONE_TYPE.VEHICLE, PlaceableTCRepairZone.ZONE_TYPE.HARVESTER
    local isType = TheContractorRepairContracts.isTypeForZone
    assertTrue(isType({ AdvancedDamageSystem = true, drivable = true }, vehicle))
    assertTrue(not isType({ AdvancedDamageSystem = true, drivable = true }, harvester))
    assertTrue(isType({ AdvancedDamageSystem = true, drivable = true, combine = true }, harvester))
    assertTrue(not isType({ AdvancedDamageSystem = true, drivable = true, combine = true }, vehicle))
    assertTrue(not isType({ drivable = true }, vehicle), "no ADS, no contract")
    assertTrue(not isType({ AdvancedDamageSystem = true }, vehicle), "not drivable")

    local isCandidate = TheContractorRepairContracts.isCandidateStoreItem
    assertTrue(isCandidate({ xmlFilename = "a", categoryName = "TRACTORSM" }, vehicle))
    assertTrue(not isCandidate({ xmlFilename = "a", categoryName = "TELELOADERS" }, vehicle))
    assertTrue(isCandidate({ xmlFilename = "a", categoryName = "FORAGEHARVESTERS" }, harvester))
    assertTrue(not isCandidate({ xmlFilename = "a", categoryName = "TRACTORSM", bundleInfo = {} }, vehicle))
end)

test("a zone splits into equal bays, and a model has to fit one", function()
    local world = setup({ models = {
        { xml = "small.xml", category = "TRACTORSS", specs = { AdvancedDamageSystem = true, drivable = true },
            width = 2.5, length = 5 },
        { xml = "wide.xml", category = "TRACTORSL", specs = { AdvancedDamageSystem = true, drivable = true },
            width = 3.8, length = 7 },
        { xml = "combine.xml", category = "HARVESTERS",
            specs = { AdvancedDamageSystem = true, drivable = true, combine = true }, width = 3.5, length = 9 },
    } })
    local zone = world:addZone()
    local bay2 = PlaceableTCRepairZone.getBayArea(zone, 2)
    assertNear(bay2.x, 4, 0.001, "the second bay starts 4 m along")
    assertNear(bay2.width, 4, 0.001)
    assertNear(bay2.length, 9, 0.001)
    assertEquals(PlaceableTCRepairZone.getBayArea(zone, 4), nil, "no fourth bay")

    local models = g_currentMission.TheContractor.RepairContracts:getModelsForZone(zone)
    assertEquals(#models, 1, "the 3.8 m tractor doesn't fit a 4 m bay with clearance; the combine's the wrong type")
    assertEquals(models[1].xmlFilename, "small.xml")
end)

test("a zone's filter narrows its models by category", function()
    local world = setup({ models = {
        { xml = "small.xml", category = "TRACTORSS", specs = { AdvancedDamageSystem = true, drivable = true },
            width = 2.5, length = 5 },
        { xml = "medium.xml", category = "TRACTORSM", specs = { AdvancedDamageSystem = true, drivable = true },
            width = 2.8, length = 6 },
    } })
    local repairContracts = g_currentMission.TheContractor.RepairContracts
    local zone = world:addZone({ categories = { "TRACTORSM" } })
    local models = repairContracts:getModelsForZone(zone)
    assertEquals(#models, 1)
    assertEquals(models[1].xmlFilename, "medium.xml")
    local choices = repairContracts:getCategoryChoices(zone, PlaceableTCRepairZone.getFilter(zone))
    assertEquals(table.concat(choices, ","), "TRACTORSM,TRACTORSS", "the dialog offers both")

    local sanitised = TCRepairZoneActivatable.sanitise(PlaceableTCParkingSlot.newFilter({ "TRACTORSM", "BOGUS" }))
    assertEquals(table.concat(sanitised.categories, ","), "TRACTORSM", "the server drops unknown categories")
end)

test("severity is 20% 1, 30% 2, 50% 3", function()
    setup()
    local pick = TheContractorRepairContracts.pickSeverity
    assertEquals(pick(function() return 0 end), 1)
    assertEquals(pick(function() return 0.19 end), 1)
    assertEquals(pick(function() return 0.2 end), 2)
    assertEquals(pick(function() return 0.49 end), 2)
    assertEquals(pick(function() return 0.5 end), 3)
    assertEquals(pick(function() return 0.999 end), 3)
end)

test("the work's due in the fewest days at 1 day per period, rising to the most at full length", function()
    setup()
    local getDueDays = TheContractorRepairContracts.getDueDays
    local minDays = TheContractorRepairContracts.MIN_DUE_DAYS
    local maxDays = TheContractorRepairContracts.MAX_DUE_DAYS
    local full = TheContractorRepairContracts.FULL_DUE_DAYS_PER_PERIOD
    assertTrue(minDays < maxDays)
    assertEquals(getDueDays(1), minDays)
    assertEquals(getDueDays(nil), minDays)
    assertEquals(getDueDays(full), maxDays)
    assertEquals(getDueDays(28), maxDays)
    -- Never falls as the periods get longer, and stays within the limits.
    local last = minDays
    for daysPerPeriod = 1, 28 do
        local days = getDueDays(daysPerPeriod)
        assertTrue(days >= last and days >= minDays and days <= maxDays)
        last = days
    end
end)

-- Arrivals ----------------------------------------------------------------------------

test("nothing runs while the queue is empty", function()
    local world, tc = setup()
    world:addZone()
    tc.RepairContracts:update(60000)
    assertEquals(#world.calls.spawned, 0)
end)

test("an arrival is placed on the next look at the queue", function()
    local world, tc = setup()
    local zone = world:addZone()
    tc.RepairContracts:queueArrival(1, zone, 1, ADS_KIND.REPAIR, 1)

    tc.RepairContracts:update(TheContractorRepairContracts.PLACE_CHECK_MS - 1)
    assertEquals(#world.calls.spawned, 0, "not looked at yet")

    tc.RepairContracts:update(1)
    assertEquals(#world.calls.spawned, 1)
    local data = world.calls.spawned[1]
    assertEquals(data.propertyState, VehiclePropertyState.MISSION)
    assertEquals(data.farmId, 1)
    assertNear(data.x, 2, 0.001, "centred in bay 1")
    assertNear(data.z, 4.5, 0.001)
end)

test("an arrival goes in its own bay", function()
    local world, tc = setup()
    local zone = world:addZone()
    tc.RepairContracts:queueArrival(1, zone, 2, ADS_KIND.REPAIR, 1)
    tc.RepairContracts:update(TheContractorRepairContracts.PLACE_CHECK_MS)
    assertEquals(#world.calls.spawned, 1)
    assertNear(world.calls.spawned[1].x, 6, 0.001, "bay 2's centre")
end)

test("a blocked bay waits, and is given up after a few days", function()
    local world, tc = setup()
    local zone = world:addZone()
    local repairContracts = tc.RepairContracts
    repairContracts:queueArrival(1, zone, 1, ADS_KIND.REPAIR, 1)
    world.bayBlocked = true
    repairContracts:update(TheContractorRepairContracts.PLACE_CHECK_MS)
    assertEquals(#world.calls.spawned, 0)
    for _ = 1, TheContractorRepairContracts.ARRIVAL_GIVE_UP_DAYS + 1 do
        TheContractorRepairContracts.ARRIVAL_CHANCE = 0
        repairContracts:onDayChanged()
    end
    assertEquals(#repairContracts.arrivals, 0)
end)

test("a model ADS turns down is swapped, and the offer goes up for one it takes", function()
    local world, tc = setup()
    world.prepareResults = { false, true }
    local zone = world:addZone()
    local repairContracts = tc.RepairContracts
    repairContracts:queueArrival(1, zone, 1, ADS_KIND.REPAIR, 2)
    repairContracts:update(TheContractorRepairContracts.PLACE_CHECK_MS)
    local first = world:finishLoad()
    assertTrue(first.isDeleted, "turned down: deleted")
    assertEquals(#repairContracts.arrivals, 1, "still queued, for another go")
    assertEquals(#tc.Jobs:getAllJobs(1), 0)

    repairContracts:update(TheContractorRepairContracts.PLACE_CHECK_MS)
    local second = world:finishLoad()
    assertEquals(#repairContracts.arrivals, 0)
    assertEquals(world.prepared.kind, "repair")
    assertEquals(world.prepared.severity, 2)

    local job = tc.Jobs:getAllJobs(1)[1]
    assertEquals(job.jobType, "adsRepair")
    assertEquals(job.fieldId, 0)
    assertEquals(job.state, TheContractorJob.STATE.OFFERED)
    assertEquals(job.workshop.vehicleId, second.id)
    assertEquals(job.workshop.bayIndex, 1)
    assertEquals(job.deadlineDay, world.today + TheContractorRepairContracts.getDueDays(1),
        "due getDueDays' days after today")
    assertEquals(job.workshop.offerExpiresDay, job.deadlineDay - 1, "the offer lapses the day before it's due")
    assertEquals(job:getPrice(), 1400, "held at the parts plus the 40% benchmark until a price is agreed")
    assertEquals(job.workshop.quotePrice, 1500)
    assertEquals(job.workshop.partsCost, 1000)
    assertEquals(job.workshop.baseParts, 1000)
    assertEquals(job.workshop.baseLabour, 0)
    assertNear(job.workshop.benchmarkMargin, 0.4, 0.0001)
    assertTrue(job.workshop.refusalMargin >= 0.8 - 1e-6 and job.workshop.refusalMargin <= 1.2 + 1e-6,
        "the customer's ceiling, 2-3 times the benchmark")
    assertEquals(world.stages[second.id], "inspection", "ADS allows only inspections until it's agreed")
    assertTrue(TheContractorRepairContracts.isContractVehicle(second))
    assertTrue(repairContracts:isBayTaken("zone1", 1))
    assertTrue(not repairContracts:isBayTaken("zone1", 2))
end)

test("the price is stored without EconomyScale's factor and follows it", function()
    local world, tc = setup()
    g_currentMission.EconomyScale = { factor = 2, adsHooksInstalled = true }
    world.partsCost = 2000
    local job = makeOffer(world, tc)
    assertEquals(job.workshop.baseParts, 1000, "the parts / factor")
    assertNear(job.basePrice, 1400, 0.001, "plus the benchmark")
    g_currentMission.EconomyScale.factor = 3
    assertNear(job:getPrice(), job.basePrice * 3, 0.001)
end)

test("a job with few parts still pays MIN_PRICE, before EconomyScale's factor", function()
    local world, tc = setup()
    g_currentMission.EconomyScale = { factor = 2, adsHooksInstalled = true }
    world.quotePrice = 5000
    world.partsCost = 200
    local job = makeOffer(world, tc)
    assertEquals(job.basePrice, TheContractorRepairContracts.MIN_PRICE)
    assertNear(job:getPrice(), TheContractorRepairContracts.MIN_PRICE * 2, 0.001)
end)

test("the cost is the parts plus the labour hours at LABOUR_RATE, divided out of EconomyScale's factor", function()
    local world, tc = setup()
    g_currentMission.EconomyScale = { factor = 2, adsHooksInstalled = true }
    -- scaleCost (faked as 1x) would apply the factor, so its labour is divided by it too.
    tc.Settings.scaleCost = function(_, amount) return amount * 5 * 2 end
    world.partsCost, world.laborHours = 2000, 3
    local job = makeOffer(world, tc)
    assertEquals(job.workshop.baseParts, 1000)
    assertNear(job.workshop.baseLabour, 3 * TheContractorRepairContracts.LABOUR_RATE * 5, 0.001)
    assertEquals(job.workshop.laborHours, 3)
    local cost = TheContractorRepairContracts.getJobBaseCost(job)
    assertNear(TheContractorRepairContracts.getPriceForMargin(job, 0.5), cost * 1.5 * 2, 0.001,
        "the price at a margin, scaled now")
end)

test("an EconomyScale that doesn't scale ADS leaves the parts as ADS quoted them", function()
    local world, tc = setup()
    -- An older EconomyScale: it scales our labour (scaleCost) but not ADS.
    g_currentMission.EconomyScale = { factor = 2 }
    tc.Settings.scaleCost = function(_, amount) return amount * 5 * 2 end
    world.partsCost, world.laborHours = 2000, 3
    local job = makeOffer(world, tc)
    assertEquals(job.workshop.baseParts, 2000, "ADS's vanilla parts are already a base amount")
    assertNear(job.workshop.baseLabour, 3 * TheContractorRepairContracts.LABOUR_RATE * 5, 0.001,
        "labour still has the factor divided out")
    assertEquals(TCEconomyScale.getADSFactor(), 1)
    g_currentMission.EconomyScale.adsHooksInstalled = true
    assertEquals(TCEconomyScale.getADSFactor(), 2, "the factor once EconomyScale scales ADS")
    g_currentMission.EconomyScale = nil
    assertEquals(TCEconomyScale.getADSFactor(), 1, "and 1 without EconomyScale")
end)

test("the margin factor: 1.25 for nothing, 1 at the benchmark, 0 at twice, a loss of half at three times", function()
    setup()
    local factor = TheContractorRepairContracts.getMarginFactorFor
    assertNear(factor(0, 0.4), 1.25, 0.0001)
    assertNear(factor(0.2, 0.4), 1.125, 0.0001)
    assertNear(factor(0.4, 0.4), 1, 0.0001)
    assertNear(factor(0.6, 0.4), 0.5, 0.0001)
    assertNear(factor(0.8, 0.4), 0, 0.0001)
    assertNear(factor(1.2, 0.4), -0.5, 0.0001)
    assertNear(factor(2.0, 0.4), -0.5, 0.0001, "flat past the last point")
    assertNear(factor(0.05, 0), factor(0.05, TheContractorRepairContracts.MIN_BENCHMARK), 0.0001,
        "a 0% setting still has a curve")
    assertEquals(TheContractorRepairContracts.getMarginFactor({ workshop = {} }), 1, "no agreed margin: no change")
end)

test("the customer's view: fair to the benchmark, steep to 1.75 times, a rip-off past it", function()
    setup()
    local steps = TheContractorRepairContracts.getMarginSteps()
    assertEquals(#steps, 41, "0% to 200% in 5% steps")
    local function reaction(index) return TheContractorRepairContracts.getReaction(steps[index], 0.4) end
    assertEquals(reaction(1), "fair")
    assertEquals(reaction(9), "fair", "40%, the benchmark itself")
    assertEquals(reaction(10), "steep")
    assertEquals(reaction(14), "steep", "65%")
    assertEquals(reaction(15), "ripOff", "70% is 1.75 times 40%")
    assertTrue(TheContractorRepairContracts.isOverchargeMargin(steps[15], 0.4))
end)

test("the quote options: every margin that comes to the minimum price is one minimum charge", function()
    setup()
    local options = TheContractorRepairContracts.getQuoteOptions(1000)
    assertEquals(#options, 41, "over the minimum at every margin: all of them")
    assertTrue(not options[1].isMinimum)

    options = TheContractorRepairContracts.getQuoteOptions(500)
    assertEquals(#options, 31, "0-50% folded into one")
    assertTrue(options[1].isMinimum)
    assertNear(options[1].margin, 0.5, 0.0001, "at the highest margin still at the minimum")
    assertNear(options[2].margin, 0.55, 0.0001)
    assertTrue(not options[2].isMinimum)

    options = TheContractorRepairContracts.getQuoteOptions(200)
    assertEquals(#options, 1, "the minimum at every margin")
    assertNear(options[1].margin, TheContractorRepairContracts.MARGIN_MAX, 0.0001)
end)

test("a minimum charge: always taken, no reputation lost, never overcharging", function()
    local base = TheContractorRepairContracts.REPUTATION_BY_KIND.repair[2]
    local world, tc = setup()
    tc.Notices = { publish = function() return 1 end, remove = function() end }
    world.partsCost = 200
    local job, vehicle = makeOffer(world, tc)
    job.workshop.refusalMargin = 0.1
    assertEquals(TheContractorRepairContracts.getJobReaction(job, 2.0), "minimum")
    assertEquals(tc.RepairContracts:proposeQuote(1, job.id, 2.0), "accepted", "over the ceiling, but the minimum")
    assertEquals(job:getPrice(), TheContractorRepairContracts.MIN_PRICE)
    assertTrue(TheContractorRepairContracts.isJobMinimumCharge(job))
    assertEquals(TheContractorRepairContracts.getMarginFactor(job), 1, "a 1000% margin, but no loss")
    tc.RepairContracts:resolveSavedVehicles()
    world.listener(vehicle, { state = "done" })
    assertEquals(world.calls.reputation[1], math.floor(base * 1.5), "as at the benchmark")
    assertTrue(not tc.RepairContracts:isOvercharging(1))

    -- Cheaper than the benchmark still earns its bonus.
    world, tc = setup()
    world.partsCost = 600
    job = makeOffer(world, tc)
    job.workshop.margin = 0.2
    assertTrue(TheContractorRepairContracts.isJobMinimumCharge(job))
    assertNear(TheContractorRepairContracts.getMarginFactor(job), 1.125, 0.0001)
end)

test("the price is agreed through a quote, not counter offers or a plain accept", function()
    local world, tc = setup()
    local job = makeOffer(world, tc)
    local price = job:getPrice()
    assertEquals(TheContractorJobs.getAcceptProblem(job), nil)
    assertEquals(tc.Jobs:proposeCounterOffer(1, job.id, price * 2), nil)
    assertEquals(job.state, TheContractorJob.STATE.OFFERED)
    assertEquals(job:getPrice(), price)

    world:load("src/events/TCRespondToJobOfferEvent.lua")
    TCRespondToJobOfferEvent.new(1, job.id, true):run(nil)
    assertEquals(job.state, TheContractorJob.STATE.OFFERED, "Accept on a workshop job does nothing")
    TCRespondToJobOfferEvent.new(1, job.id, false):run(nil)
    assertEquals(job.state, TheContractorJob.STATE.DECLINED, "it can still be turned down")
end)

test("the margin settings: 40% in zones, 50% in the field, on the menu only with ADS", function()
    local world = setup()
    world.texts.ui_on, world.texts.ui_off = "On", "Off"
    world:load("src/business/Settings.lua")
    assertEquals(TheContractorSettings.getDefaultValue("adsWorkshopMargin"), 40)
    assertEquals(TheContractorSettings.getDefaultValue("adsFieldMargin"), 50)
    local settings = TheContractorSettings.new()
    assertNear(settings:getADSMargin(), 0.4, 0.0001)
    assertNear(settings:getADSMargin(true), 0.5, 0.0001)
    local realIsActive = TCADSRepairContracts.isActive
    for _, id in ipairs({ "adsWorkshopMargin", "adsFieldMargin" }) do
        local definition = TheContractorSettings.DEFINITIONS[id]
        assertTrue(definition.isShown(), "ADS is loaded in these tests")
        TCADSRepairContracts.isActive = function() return false end
        assertTrue(not definition.isShown())
        TCADSRepairContracts.isActive = realIsActive
    end
end)

test("the hourly roll only fills free bays", function()
    local world, tc = setup()
    world:addZone()
    TheContractorRepairContracts.ARRIVAL_CHANCE = 1
    g_currentMission.environment.currentHour = TheContractorRepairContracts.ARRIVAL_HOURS[1]
    tc.RepairContracts:onHourChanged()
    assertEquals(#tc.RepairContracts.arrivals, 3)
    tc.RepairContracts:onHourChanged()
    assertEquals(#tc.RepairContracts.arrivals, 3, "every bay's taken now")
end)

test("customers only come in ARRIVAL_HOURS, never at the day change", function()
    local world, tc = setup()
    world:addZone()
    TheContractorRepairContracts.ARRIVAL_CHANCE = 1
    g_currentMission.environment.currentHour = 0
    tc.RepairContracts:onDayChanged()
    tc.RepairContracts:onHourChanged()
    g_currentMission.environment.currentHour = TheContractorRepairContracts.ARRIVAL_HOURS[1] - 1
    tc.RepairContracts:onHourChanged()
    g_currentMission.environment.currentHour = TheContractorRepairContracts.ARRIVAL_HOURS[2] + 1
    tc.RepairContracts:onHourChanged()
    assertEquals(#tc.RepairContracts.arrivals, 0)
    g_currentMission.environment.currentHour = TheContractorRepairContracts.ARRIVAL_HOURS[2]
    tc.RepairContracts:onHourChanged()
    assertEquals(#tc.RepairContracts.arrivals, 3, "the last hour still rolls")
end)

test("the hourly chances add up to the day's", function()
    local hours = TheContractorRepairContracts.ARRIVAL_HOURS[2] - TheContractorRepairContracts.ARRIVAL_HOURS[1] + 1
    for _, daily in ipairs({ 0, 0.1, 0.25, 0.5, 1 }) do
        local hourly = TheContractorRepairContracts.getHourlyChance(daily)
        assertNear(1 - (1 - hourly) ^ hours, daily, 0.0001)
    end
end)

-- Accepting -----------------------------------------------------------------------------

test("missing equipment warns but never blocks: the dealer can do the rest", function()
    local world, tc = setup()
    local job, vehicle = makeOffer(world, tc)
    world.farmTools[vehicle.id] = { canDo = false, missing = { "lift", "machining" }, items = {},
        plan = { canDo = false, partsCost = 300, laborHours = 2, subcontractCost = 900 } }

    assertEquals(TheContractorJobs.getAcceptProblem(job), nil)
    assertTrue(TheContractorRepairContracts.getToolsWarning(job) ~= nil, "warned")
    local kit = TheContractorRepairContracts.getMissingKit(job)
    assertEquals(#kit.names, 2, "a chip per upgrade")
    assertEquals(kit.noteKey, "tc_repairQuote_kitNote_subcontract")
    assertEquals(tc.RepairContracts:proposeQuote(1, job.id, 0.4), "accepted")
    assertEquals(job.state, TheContractorJob.STATE.ACCEPTED)
end)

test("only a machine that's gone, or ADS, stops a job being taken on", function()
    local world, tc = setup()
    local job, vehicle = makeOffer(world, tc)
    world.status[vehicle.id] = "noContract"
    assertTrue(TheContractorJobs.getAcceptProblem(job) ~= nil, "ADS won't contract it")
    assertEquals(tc.RepairContracts:proposeQuote(1, job.id, 0.4), nil)
    job.workshop.vehicleId = 0
    assertTrue(TheContractorJobs.getAcceptProblem(job) ~= nil, "the machine's gone")
end)

test("an offer lapses after its days and the customer takes the machine", function()
    local world, tc = setup()
    local job, vehicle = makeOffer(world, tc)
    g_currentMission.environment.currentMonotonicDay = job.workshop.offerExpiresDay + 1
    tc.Jobs:onDayChanged()
    assertEquals(job.state, TheContractorJob.STATE.DECLINED)
    assertEquals(#world.calls.released, 0, "the contract stays on until it's collected")
    assertEquals(#tc.RepairContracts.removals, 1)
    assertTrue(not tc.RepairContracts.removals[1].judgeTamper, "an offer never let anyone near the parts")

    tc.RepairContracts:update(TheContractorRepairContracts.PLACE_CHECK_MS)
    assertTrue(vehicle.isDeleted, "collected on the next look")
    assertEquals(world.calls.released[1], vehicle.id)
    assertEquals(#tc.RepairContracts.removals, 0)
end)

test("a machine isn't taken from under someone driving it", function()
    local world, tc = setup()
    local job, vehicle = makeOffer(world, tc)
    function vehicle:getIsControlled() return true end
    tc.Jobs:transitionJobState(1, job.id, TheContractorJob.STATE.DECLINED)
    tc.RepairContracts:update(TheContractorRepairContracts.PLACE_CHECK_MS)
    assertTrue(not vehicle.isDeleted)
    function vehicle:getIsControlled() return false end
    tc.RepairContracts:update(TheContractorRepairContracts.PLACE_CHECK_MS)
    assertTrue(vehicle.isDeleted)
end)

-- Completing -------------------------------------------------------------------------------

test("ADS saying done completes an accepted job: invoiced, reputation, logged, collected", function()
    local world, tc = setup()
    local job, vehicle = makeOffer(world, tc)
    tc.Jobs:transitionJobState(1, job.id, TheContractorJob.STATE.ACCEPTED)
    tc.RepairContracts:resolveSavedVehicles()

    world.status[vehicle.id] = "done"
    world.listener(vehicle, { state = "done" })
    assertEquals(job.state, TheContractorJob.STATE.COMPLETED)
    assertEquals(job.qualityScore, 100)
    assertEquals(world.calls.invoices[1], job.id)
    local base = TheContractorRepairContracts.REPUTATION_BY_KIND.repair[2]
    assertEquals(world.calls.reputation[1], math.floor(base * 1.5), "done at once: the full speed bonus")
    assertEquals(world.calls.logged[1][1], "completed")
    assertEquals(#tc.RepairContracts.removals, 1)
end)

test("a finished job's machine is collected an hour later, not at once", function()
    local world, tc = setup()
    local job, vehicle = makeOffer(world, tc)
    tc.Jobs:transitionJobState(1, job.id, TheContractorJob.STATE.ACCEPTED)
    tc.RepairContracts:resolveSavedVehicles()
    local environment = g_currentMission.environment
    environment.dayTime = 23 * 60 * 60 * 1000 + 30 * 60 * 1000

    world.status[vehicle.id] = "done"
    world.listener(vehicle, { state = "done" })
    assertEquals(job.state, TheContractorJob.STATE.COMPLETED)
    tc.RepairContracts:update(TheContractorRepairContracts.PLACE_CHECK_MS)
    assertTrue(not vehicle.isDeleted, "still there just after")

    -- Past midnight, but not yet the hour.
    environment.currentMonotonicDay = environment.currentMonotonicDay + 1
    environment.dayTime = 29 * 60 * 1000
    tc.RepairContracts:update(TheContractorRepairContracts.PLACE_CHECK_MS)
    assertTrue(not vehicle.isDeleted, "a minute short")

    environment.dayTime = 30 * 60 * 1000
    tc.RepairContracts:update(TheContractorRepairContracts.PLACE_CHECK_MS)
    assertTrue(vehicle.isDeleted, "collected once the hour's up")
    assertEquals(#tc.RepairContracts.removals, 0)
end)

test("reputation by kind: a service least, a repair more, a field breakdown most", function()
    setup()
    local function base(kind, severity)
        return TheContractorRepairContracts.getBaseReputation({ workshop = { kind = kind, severity = severity } })
    end
    for severity = 1, 3 do
        assertTrue(base("maintenance", severity) < base("repair", severity))
        assertTrue(base("repair", severity) < base("breakdown", severity))
    end
    assertTrue(base("repair", 1) < base("repair", 3), "bigger jobs earn more")
end)

test("speed: the full bonus in the first quarter of the time, none past three quarters", function()
    setup()
    -- Accepted at midnight of day 10, due by the end of day 11: 48 hours.
    local function factor(kind, hours)
        local start = 10 * 24 * 60
        return TheContractorRepairContracts.getSpeedFactor({ deadlineDay = 11, completedAt = start + hours * 60,
            workshop = { kind = kind, acceptedAt = start } })
    end
    assertNear(factor("repair", 2), 1.5, 0.0001)
    assertNear(factor("repair", 12), 1.5, 0.0001, "a quarter of the time")
    assertNear(factor("repair", 24), 1.25, 0.0001, "half way")
    assertNear(factor("repair", 36), 1, 0.0001, "three quarters")
    assertNear(factor("repair", 47), 1, 0.0001)
    assertNear(factor("breakdown", 2), 1.5, 0.0001)
    assertNear(factor("maintenance", 2), 1, 0.0001, "nobody's waiting on a service")
    assertEquals(TheContractorRepairContracts.getSpeedFactor({ deadlineDay = 11, completedAt = 100,
        workshop = { kind = "repair" } }), 1, "accepted before it was kept")
end)

test("a slow repair earns the plain reward; the turnaround counts from acceptance", function()
    local world, tc = setup()
    local job, vehicle = makeOffer(world, tc)
    tc.Jobs:transitionJobState(1, job.id, TheContractorJob.STATE.ACCEPTED)
    assertEquals(job.workshop.acceptedAt, TheContractorJobs.getGameMinutes())
    local stream = world:newStream()
    TheContractorJobs.writeJob(stream, job)
    assertEquals(TheContractorJobs.readJob(stream).workshop.acceptedAt, job.workshop.acceptedAt)
    local xmlFile = {}
    tc.Jobs:saveToXmlFile(xmlFile)
    local jobs = TheContractorJobs.new()
    jobs:loadFromXMLFile(xmlFile)
    assertEquals(jobs:getJob(1, job.id).workshop.acceptedAt, job.workshop.acceptedAt)
    tc.RepairContracts:resolveSavedVehicles()
    g_currentMission.environment.currentMonotonicDay = job.deadlineDay
    g_currentMission.environment.dayTime = 23 * 60 * 60 * 1000
    world.status[vehicle.id] = "done"
    world.listener(vehicle, { state = "done" })
    assertEquals(job.state, TheContractorJob.STATE.COMPLETED)
    assertEquals(world.calls.reputation[1], TheContractorRepairContracts.REPUTATION_BY_KIND.repair[2])
    assertTrue(TheContractorRepairContracts.getTurnaroundMinutes(job) > 0)
end)

test("work done before the offer's accepted counts as soon as it is", function()
    local world, tc = setup()
    local job, vehicle = makeOffer(world, tc)
    world.status[vehicle.id] = "done"
    tc.Jobs:transitionJobState(1, job.id, TheContractorJob.STATE.ACCEPTED)
    assertEquals(job.state, TheContractorJob.STATE.COMPLETED)
end)

test("a status reached before the save is picked up after loading", function()
    local world, tc = setup()
    local job, vehicle = makeOffer(world, tc)
    tc.Jobs:transitionJobState(1, job.id, TheContractorJob.STATE.ACCEPTED)
    world.status[vehicle.id] = "done"
    tc.RepairContracts:resolveSavedVehicles()
    assertEquals(job.state, TheContractorJob.STATE.COMPLETED)
end)

test("after loading, a job whose machine is gone ends with no penalty", function()
    local world, tc = setup()
    local job = makeOffer(world, tc)
    tc.Jobs:transitionJobState(1, job.id, TheContractorJob.STATE.ACCEPTED)
    job.workshop.vehicleId = 0
    tc.RepairContracts:resolveSavedVehicles()
    assertEquals(job.state, TheContractorJob.STATE.MISSED)
    assertEquals(world.calls.reputation[1], 0)
end)

test("after loading without ADS, an accepted job ends with no penalty and an offer is left to lapse", function()
    local world, tc = setup()
    local job, _, zone = makeOffer(world, tc)
    tc.Jobs:transitionJobState(1, job.id, TheContractorJob.STATE.ACCEPTED)
    tc.RepairContracts:queueArrival(1, zone, 2, ADS_KIND.REPAIR, 2)
    tc.RepairContracts:update(TheContractorRepairContracts.PLACE_CHECK_MS)
    world:finishLoad()
    local offer = nil
    for _, other in ipairs(tc.Jobs:getAllJobs(1)) do
        if other ~= job then
            offer = other
        end
    end
    assertEquals(offer.state, TheContractorJob.STATE.OFFERED)
    TCADSRepairContracts.getEnv = function() return nil end
    TCADSRepairContracts.detect()
    tc.RepairContracts:resolveSavedVehicles()
    assertEquals(job.state, TheContractorJob.STATE.MISSED)
    assertEquals(world.calls.reputation[1], 0)
    assertEquals(offer.state, TheContractorJob.STATE.OFFERED)
end)

test("after loading, a job whose machine lost its ADS contract ends with no penalty", function()
    local world, tc = setup()
    local job, vehicle = makeOffer(world, tc)
    tc.Jobs:transitionJobState(1, job.id, TheContractorJob.STATE.ACCEPTED)
    world.status[vehicle.id] = "noContract"
    tc.RepairContracts:resolveSavedVehicles()
    assertEquals(job.state, TheContractorJob.STATE.MISSED)
    assertEquals(world.calls.reputation[1], 0)
end)

test("after loading, a workable job is left open", function()
    local world, tc = setup()
    local job = makeOffer(world, tc)
    tc.Jobs:transitionJobState(1, job.id, TheContractorJob.STATE.ACCEPTED)
    tc.RepairContracts:resolveSavedVehicles()
    assertEquals(job.state, TheContractorJob.STATE.ACCEPTED)
    assertEquals(#world.calls.reputation, 0)
end)

test("a machine ADS stops managing ends the job with no penalty", function()
    local world, tc = setup()
    local job, vehicle = makeOffer(world, tc)
    tc.Jobs:transitionJobState(1, job.id, TheContractorJob.STATE.ACCEPTED)
    tc.RepairContracts:onStatusChanged(vehicle, { state = "invalid" })
    assertEquals(job.state, TheContractorJob.STATE.MISSED)
    assertEquals(world.calls.reputation[1], 0)
end)

-- Tampering -------------------------------------------------------------------------------

local function missAccepted(world, tc, findings)
    local job, vehicle = makeOffer(world, tc)
    tc.Jobs:transitionJobState(1, job.id, TheContractorJob.STATE.ACCEPTED)
    if findings ~= nil then
        world.status[vehicle.id] = "tampered"
        world.tampering[vehicle.id] = findings
    end
    g_currentMission.environment.currentMonotonicDay = job.deadlineDay + 1
    tc.Jobs:onDayChanged()
    return job, vehicle
end

test("an honest miss costs the usual reputation and nothing else", function()
    local world, tc = setup()
    local job = missAccepted(world, tc, nil)
    assertEquals(job.state, TheContractorJob.STATE.MISSED)
    local base = TheContractorRepairContracts.REPUTATION_BY_KIND.repair[2]
    assertEquals(world.calls.reputation[1], -math.floor(math.max(10, base * 1.5)))
    assertEquals(#tc.RepairContracts.pendingClaims, 0)
    assertEquals(#world.calls.messages, 0)
end)

test("tampered at the deadline: no pay, double the loss, and a claim over the threshold", function()
    local world, tc = setup()
    world.partPrice = 4000
    local job = missAccepted(world, tc, { { kind = "component", id = "engine", accepted = 0.8, current = 0.3 } })
    assertEquals(#world.calls.invoices, 0, "not paid")
    local base = math.floor(math.max(10, TheContractorRepairContracts.REPUTATION_BY_KIND.repair[2] * 1.5))
    assertEquals(world.calls.reputation[1], -math.floor(base * TheContractorRepairContracts.TAMPER_REPUTATION_MULTIPLIER))
    assertEquals(world.calls.messages[1].bodyKey, "tc_repair_tamperedBodyClaim")

    local claim = tc.RepairContracts.pendingClaims[1]
    assertEquals(claim.amount, 2000, "half the engine's resource at its part price")
    g_currentMission.environment.currentMonotonicDay = claim.notifyDay
    tc.RepairContracts:onDayChanged()
    assertEquals(world.calls.charged[1].amount, 2000)
    assertEquals(world.calls.charged[1].insured, false, "public liability doesn't cover it")
    assertEquals(world.calls.claimLogs[1].cause, "tampering")
    assertEquals(#tc.RepairContracts.pendingClaims, 0)
end)

test("a tampering claim values the part at today's price level", function()
    local world, tc = setup()
    -- ADS's list price stays vanilla whatever EconomyScale does.
    g_currentMission.EconomyScale = { factor = 2, adsHooksInstalled = true }
    world.partPrice = 4000
    missAccepted(world, tc, { { kind = "component", id = "engine", accepted = 0.8, current = 0.3 } })
    assertEquals(tc.RepairContracts.pendingClaims[1].amount, 4000, "half the engine at twice its vanilla price")
end)

test("legal cover halves the claim; a small loss brings none", function()
    local world, tc = setup()
    world.partPrice = 4000
    world.legalCover = true
    missAccepted(world, tc, { { kind = "component", id = "engine", accepted = 0.8, current = 0.3 } })
    assertEquals(tc.RepairContracts.pendingClaims[1].amount, 1000)

    world, tc = setup()
    missAccepted(world, tc, { { kind = "battery", id = "battery", accepted = 0.9, current = 0.7 } })
    assertEquals(#tc.RepairContracts.pendingClaims, 0, "a battery's under the threshold")
    assertEquals(world.calls.messages[1].bodyKey, "tc_repair_tamperedBody")
end)

-- Finished and paid, then waiting for its customer.
local function finishAccepted(world, tc)
    local job, vehicle = makeOffer(world, tc)
    tc.Jobs:transitionJobState(1, job.id, TheContractorJob.STATE.ACCEPTED)
    tc.RepairContracts:resolveSavedVehicles()
    world.status[vehicle.id] = "done"
    world.listener(vehicle, { state = "done" })
    return job, vehicle
end

local function collectAfterTheHour(tc)
    local environment = g_currentMission.environment
    environment.dayTime = environment.dayTime + TheContractorRepairContracts.COLLECT_DELAY_HOURS * 60 * 60 * 1000
    tc.RepairContracts:update(TheContractorRepairContracts.PLACE_CHECK_MS)
end

test("stripped after it's finished: found as it's collected, double the loss and a claim, the pay stands", function()
    local world, tc = setup()
    world.partPrice = 4000
    local job, vehicle = finishAccepted(world, tc)
    assertEquals(job.state, TheContractorJob.STATE.COMPLETED)
    assertEquals(#world.calls.released, 0, "still under contract while it waits")
    job.customerId = 7
    local messages = #world.calls.messages

    world.status[vehicle.id] = "tampered"
    world.tampering[vehicle.id] = { { kind = "component", id = "engine", accepted = 0.8, current = 0.3 } }
    collectAfterTheHour(tc)
    assertTrue(vehicle.isDeleted, "collected")
    assertEquals(world.calls.released[1], vehicle.id, "released as it goes")
    assertEquals(#world.calls.invoices, 1, "the pay stands")
    local penalty = math.floor(TheContractorJobs.getFullMissPenalty(job) *
        TheContractorRepairContracts.TAMPER_REPUTATION_MULTIPLIER)
    assertEquals(world.calls.reputation[#world.calls.reputation], -penalty)
    assertEquals(#world.calls.messages, messages + 1)
    assertEquals(world.calls.messages[#world.calls.messages].bodyKey, "tc_repair_tamperedPaidBodyClaim")
    assertEquals(tc.RepairContracts.pendingClaims[1].amount, 2000)
    assertEquals(tc.Relationships:getScore(1, 7), -TheContractorRelationships.MISSED_LOSS, "the customer had paid")
end)

test("a finished job's machine collected as it was left costs nothing", function()
    local world, tc = setup()
    local job, vehicle = finishAccepted(world, tc)
    local reputation, messages = #world.calls.reputation, #world.calls.messages
    collectAfterTheHour(tc)
    assertTrue(vehicle.isDeleted)
    assertEquals(world.calls.released[1], vehicle.id)
    assertEquals(#world.calls.reputation, reputation)
    assertEquals(#world.calls.messages, messages)
    assertEquals(#tc.RepairContracts.pendingClaims, 0)
end)

test("tampered at the deadline is judged once, not again as it's collected", function()
    local world, tc = setup()
    world.partPrice = 4000
    local _, vehicle = missAccepted(world, tc, { { kind = "component", id = "engine", accepted = 0.8, current = 0.3 } })
    assertTrue(not tc.RepairContracts.removals[1].judgeTamper)
    tc.RepairContracts:update(TheContractorRepairContracts.PLACE_CHECK_MS)
    assertTrue(vehicle.isDeleted)
    assertEquals(#world.calls.reputation, 1)
    assertEquals(#world.calls.messages, 1)
    assertEquals(#tc.RepairContracts.pendingClaims, 1)
end)

test("an honest miss stripped before it's collected is found then, unpaid", function()
    local world, tc = setup()
    local _, vehicle = missAccepted(world, tc, nil)
    function vehicle:getIsControlled() return true end
    tc.RepairContracts:update(TheContractorRepairContracts.PLACE_CHECK_MS)
    world.status[vehicle.id] = "tampered"
    world.tampering[vehicle.id] = { { kind = "battery", id = "battery", accepted = 0.9, current = 0.7 } }
    function vehicle:getIsControlled() return false end
    tc.RepairContracts:update(TheContractorRepairContracts.PLACE_CHECK_MS)
    assertTrue(vehicle.isDeleted)
    assertEquals(#world.calls.reputation, 2, "the miss, then the tampering")
    assertEquals(world.calls.messages[1].bodyKey, "tc_repair_tamperedBody")
end)

test("a deleted farm's machine is still collected but judged against nobody", function()
    local world, tc = setup()
    local job, vehicle = finishAccepted(world, tc)
    local reputation = #world.calls.reputation
    tc.RepairContracts:forgetFarm(1)
    world.status[vehicle.id] = "tampered"
    world.tampering[vehicle.id] = { { kind = "battery", id = "battery", accepted = 0.9, current = 0.7 } }
    collectAfterTheHour(tc)
    assertTrue(vehicle.isDeleted)
    assertEquals(world.calls.released[1], vehicle.id)
    assertEquals(#world.calls.reputation, reputation)
end)

-- Substandard parts (186) ------------------------------------------------------------

local function component(id, partType, used)
    return { kind = "component", id = id, nameKey = "ads_" .. id, partType = partType, used = used == true }
end

local function consumable(id, tier, acceptedTier)
    return { kind = "consumable", id = id, nameKey = "ads_" .. id, tier = tier, acceptedTier = acceptedTier }
end

-- Completes a job with math.random's [0, 1) roll fixed at `roll`.
local function finishWithRoll(world, tc, parts, roll)
    local job, vehicle = makeOffer(world, tc)
    world.fitted[vehicle.id] = parts
    local random = math.random
    math.random = function(low, high)
        if low ~= nil then
            return low
        end
        return roll
    end
    tc.Jobs:transitionJobState(1, job.id, TheContractorJob.STATE.ACCEPTED)
    tc.RepairContracts:resolveSavedVehicles()
    world.status[vehicle.id] = "done"
    world.listener(vehicle, { state = "done" })
    math.random = random
    return job, vehicle
end

test("substandard: a used part is the worst grade, aftermarket or one tier down the middle, new or better none", function()
    setup()
    local GRADE = TheContractorRepairContracts.SUBSTANDARD_GRADE
    local grade = TheContractorRepairContracts.getSubstandardGrade
    assertEquals(grade(component("engine", "USED", true)), GRADE.USED)
    assertEquals(grade(component("engine", "OEM", true)), GRADE.USED, "taken out of another machine")
    assertEquals(grade(component("engine", "AFTERMARKET", false)), GRADE.AFTERMARKET)
    assertEquals(grade(component("engine", "OEM", false)), nil)
    assertEquals(grade(component("engine", "PREMIUM", false)), nil)
    assertEquals(grade(consumable("battery", "LIZARD", "PREMIUM")), GRADE.USED, "two tiers down")
    assertEquals(grade(consumable("battery", "LIZARD", "ORIGINAL")), GRADE.AFTERMARKET, "one tier down")
    assertEquals(grade(consumable("battery", "PREMIUM", "ORIGINAL")), nil, "better is never held against you")
    assertEquals(grade(consumable("battery", "MYSTERY", "ORIGINAL")), nil, "a tier ADS can't rank")
end)

test("substandard: each part's own chance, the found ones' shares summed into the knock", function()
    local world, tc = setup()
    local parts = { component("engine", "USED", true), component("gearbox", "AFTERMARKET", false),
        component("brakes", "OEM", false) }
    -- 0.5: the used part's found (0.75), the aftermarket one isn't (0.45).
    local job = finishWithRoll(world, tc, parts, 0.5)
    assertEquals(job.state, TheContractorJob.STATE.COMPLETED)
    local discovery = tc.RepairContracts.pendingDiscoveries[1]
    assertEquals(discovery.jobId, job.id)
    assertEquals(discovery.partKeys, "ads_engine")
    assertEquals(discovery.share, TheContractorRepairContracts.SUBSTANDARD.used.share)
    assertEquals(discovery.penalty, math.floor(TheContractorJobs.getFullMissPenalty(job) *
        TheContractorRepairContracts.SUBSTANDARD.used.share))
    assertEquals(discovery.notifyDay, world.today + TheContractorRepairContracts.SUBSTANDARD_DELAY[1])
    assertEquals(job.qualityScore, 100, "the quality score isn't touched")

    world, tc = setup()
    job = finishWithRoll(world, tc, parts, 0)
    discovery = tc.RepairContracts.pendingDiscoveries[1]
    assertEquals(discovery.partKeys, "ads_engine,ads_gearbox", "both found")
    assertEquals(discovery.share, TheContractorRepairContracts.SUBSTANDARD.used.share +
        TheContractorRepairContracts.SUBSTANDARD.aftermarket.share)

    world, tc = setup()
    finishWithRoll(world, tc, parts, 0.8)
    assertEquals(#tc.RepairContracts.pendingDiscoveries, 0, "nobody notices")
end)

test("substandard: the knock is capped however many parts are found", function()
    local world, tc = setup()
    local parts = {}
    for i = 1, 5 do
        table.insert(parts, component("part" .. i, "USED", true))
    end
    local job = finishWithRoll(world, tc, parts, 0)
    local discovery = tc.RepairContracts.pendingDiscoveries[1]
    assertEquals(discovery.share, TheContractorRepairContracts.SUBSTANDARD_MAX_SHARE)
    assertEquals(discovery.penalty, math.floor(TheContractorJobs.getFullMissPenalty(job) *
        TheContractorRepairContracts.SUBSTANDARD_MAX_SHARE))
end)

test("substandard: new parts bring nothing", function()
    local world, tc = setup()
    finishWithRoll(world, tc, { component("engine", "OEM", false), consumable("battery", "PREMIUM", "ORIGINAL") }, 0)
    assertEquals(#tc.RepairContracts.pendingDiscoveries, 0)
end)

test("substandard: found out on its day, reputation, a farmer's opinion and a message, no money", function()
    local world, tc = setup()
    local job = finishWithRoll(world, tc, { component("engine", "USED", true) }, 0)
    job.customerId = 7
    local discovery = tc.RepairContracts.pendingDiscoveries[1]
    local reputation, invoices = #world.calls.reputation, #world.calls.invoices

    g_currentMission.environment.currentMonotonicDay = discovery.notifyDay - 1
    tc.RepairContracts:onDayChanged()
    assertEquals(#world.calls.reputation, reputation, "not yet")

    g_currentMission.environment.currentMonotonicDay = discovery.notifyDay
    tc.RepairContracts:onDayChanged()
    assertEquals(world.calls.reputation[#world.calls.reputation], -discovery.penalty)
    assertEquals(tc.Relationships:getScore(1, 7),
        -math.floor(TheContractorRelationships.MISSED_LOSS * discovery.share + 0.5))
    local message = world.calls.messages[#world.calls.messages]
    assertEquals(message.kind, TheContractorRepairContracts.SUBSTANDARD_KIND)
    assertEquals(message.bodyKey, "tc_repair_substandardBody")
    assertEquals(message.args[2], "ads_engine")
    assertEquals(message.args[3], discovery.penalty)
    assertEquals(#world.calls.invoices, invoices)
    assertEquals(#world.calls.charged, 0, "no money")
    assertEquals(#tc.RepairContracts.pendingDiscoveries, 0)
end)

test("substandard: an ADS without getFittedParts judges nothing and the job finishes as before", function()
    local world, tc = setup()
    world.adsEnv.ADS_RepairContracts.getFittedParts = nil
    TCADSRepairContracts.detect()
    assertTrue(TCADSRepairContracts.isActive(), "it's optional")
    local job = finishWithRoll(world, tc, { component("engine", "USED", true) }, 0)
    assertEquals(job.state, TheContractorJob.STATE.COMPLETED)
    assertEquals(#tc.RepairContracts.pendingDiscoveries, 0)
end)

test("substandard: a finding to come survives a save, keeps its job, and goes with a deleted farm", function()
    local world, tc = setup()
    local job = finishWithRoll(world, tc, { component("engine", "USED", true) }, 0)
    local discovery = tc.RepairContracts.pendingDiscoveries[1]
    tc.Finances.invoicesById, tc.Claims.pendingClaims = {}, {}
    tc.Cooldown = { entriesByFarm = {} }
    tc.RandomEvents = { incidents = {} }
    tc.Inbox.messagesById = {}
    tc.RepairContracts.removals = {}
    assertTrue(TheContractorJobs.getHeldJobIds()[job.id], "its job is kept")

    local xmlFile = {}
    tc.RepairContracts:saveToXmlFile(xmlFile)
    local loaded = TheContractorRepairContracts.new()
    loaded:loadFromXMLFile(xmlFile)
    local copy = loaded.pendingDiscoveries[1]
    assertEquals(copy.farmId, discovery.farmId)
    assertEquals(copy.jobId, discovery.jobId)
    assertEquals(copy.partKeys, discovery.partKeys)
    assertEquals(copy.penalty, discovery.penalty)
    assertNear(copy.share, discovery.share, 0.0001)
    assertEquals(copy.notifyDay, discovery.notifyDay)

    tc.RepairContracts:forgetFarm(1)
    assertEquals(#tc.RepairContracts.pendingDiscoveries, 0)
end)

test("a machine still to be collected keeps its job in the save", function()
    local world, tc = setup()
    tc.Finances.invoicesById, tc.Claims.pendingClaims = {}, {}
    tc.Cooldown = { entriesByFarm = {} }
    tc.RandomEvents = { incidents = {} }
    tc.Inbox.messagesById = {}
    local job = finishAccepted(world, tc)
    assertTrue(TheContractorJobs.getHeldJobIds()[job.id], "held while it waits")
    collectAfterTheHour(tc)
    assertTrue(not TheContractorJobs.getHeldJobIds()[job.id], "let go once it's gone")
end)

-- The rest ------------------------------------------------------------------------------

test("a job from before the parts were kept has none, streamed or saved", function()
    local world, tc = setup()
    local job = makeOffer(world, tc)
    job.workshop.partsCost = nil
    local stream = world:newStream()
    TheContractorJobs.writeJob(stream, job)
    assertEquals(TheContractorJobs.readJob(stream).workshop.partsCost, nil)
    local xmlFile = {}
    tc.Jobs:saveToXmlFile(xmlFile)
    local jobs = TheContractorJobs.new()
    jobs:loadFromXMLFile(xmlFile)
    assertEquals(jobs:getJob(1, job.id).workshop.partsCost, nil)
end)

test("a workshop job streams, saves and loads its machine and contract", function()
    local world, tc = setup()
    local job, vehicle = makeOffer(world, tc)

    local stream = world:newStream()
    TheContractorJobs.writeJob(stream, job)
    local copy = TheContractorJobs.readJob(stream)
    assertEquals(copy.workshop.vehicleId, vehicle.id)
    assertEquals(copy.workshop.kind, "repair")
    assertEquals(table.concat(copy.workshop.requiredTools, ","), "lift")
    assertEquals(copy.workshop.operatingHours, 2450)
    assertEquals(copy.workshop.partsCost, 1000)
    assertEquals(copy.workshop.acceptedAt, nil, "not accepted yet")
    assertEquals(copy.workshop.zoneUniqueId, nil, "server-only")

    local xmlFile = {}
    tc.Jobs:saveToXmlFile(xmlFile)
    local jobs = TheContractorJobs.new()
    jobs:loadFromXMLFile(xmlFile)
    local loaded = jobs:getJob(1, job.id)
    assertEquals(loaded.workshop.vehicleUniqueId, "vehicle" .. vehicle.id)
    assertEquals(loaded.workshop.zoneUniqueId, "zone1")
    assertEquals(loaded.workshop.offerExpiresDay, job.workshop.offerExpiresDay)
    assertEquals(loaded.workshop.partsCost, 1000)
    TCVehicleIds.getObjectId = function(uniqueId) return uniqueId == "vehicle" .. vehicle.id and vehicle.id or nil end
    jobs:resolveSavedVehicles()
    assertEquals(loaded.workshop.vehicleId, vehicle.id)
end)

test("the save drops declined jobs and keeps the newest finished of each kind, and any still named", function()
    local world, tc = setup()
    local keep = TheContractorJobs.KEEP_FINISHED_JOBS
    tc.Finances.invoicesById = {}
    tc.Claims.pendingClaims = {}
    tc.Cooldown = { entriesByFarm = { [1] = {} } }
    tc.RandomEvents = { incidents = {} }
    tc.Inbox.messagesById = {}

    local function finished(i, jobType, workshop, state)
        local job = tc.Jobs:createJob(1, jobType, workshop ~= nil and 0 or 5, 1, 1, 1, 1000, true, nil, i, false,
            nil, nil, workshop)
        job.state = state or TheContractorJob.STATE.COMPLETED
        if job.state == TheContractorJob.STATE.COMPLETED then
            job.completedAt = i * 24 * 60
        end
        return job
    end

    -- Workshop jobs: keep + 6 finished, the first the oldest (a missed one,
    -- finishing at the end of its deadline day).
    local workshop = {}
    for i = 1, keep + 6 do
        local state = i == 1 and TheContractorJob.STATE.MISSED or nil
        table.insert(workshop, finished(i, "adsRepair", { vehicleName = "Machine " .. i, kind = "repair",
            quotePrice = 800 }, state))
    end
    -- Field jobs: keep + 2, the oldest two finished first.
    local field = {}
    for i = 1, keep + 2 do
        table.insert(field, finished(i, "plow"))
    end
    local declined = finished(500, "plow", nil, TheContractorJob.STATE.DECLINED)
    local offered = tc.Jobs:createJob(1, "plow", 5, 1, 1, 1, 1000, true, nil, 1)
    local accepted = tc.Jobs:createJob(1, "adsRepair", 0, 1, 1, 1, 1000, true, nil, 1, false, nil, nil,
        { vehicleName = "Open", kind = "repair", quotePrice = 800 })
    accepted.state = TheContractorJob.STATE.ACCEPTED

    -- Old ones something still names.
    tc.Finances.invoicesById[1] = { id = 1, jobId = workshop[2].id }
    tc.Claims.pendingClaims[1] = { jobId = workshop[3].id }
    tc.RepairContracts.pendingClaims = { { jobId = workshop[4].id } }
    tc.Cooldown.entriesByFarm[1][1] = { id = 1, jobId = workshop[5].id }
    tc.RandomEvents.incidents[1] = { id = 1, data = { jobId = workshop[6].id } }
    tc.Inbox.messagesById[1] = { id = 1, payload = { jobId = field[1].id } }
    field[2].graceRemainingMs = 1000

    local xmlFile = {}
    tc.Jobs:saveToXmlFile(xmlFile)
    local jobs = TheContractorJobs.new()
    jobs:loadFromXMLFile(xmlFile)
    local function isSaved(job) return jobs:getJob(1, job.id) ~= nil end

    assertTrue(not isSaved(workshop[1]), "the oldest workshop job goes")
    assertTrue(isSaved(workshop[2]), "an invoice names it")
    assertTrue(isSaved(workshop[3]), "a claim is pending on it")
    assertTrue(isSaved(workshop[4]), "a tampering claim is pending on it")
    assertTrue(isSaved(workshop[5]), "its cooldown is running")
    assertTrue(isSaved(workshop[6]), "an incident names it")
    assertTrue(isSaved(workshop[7]) and isSaved(workshop[keep + 6]), "the newest " .. keep .. " stay")
    assertTrue(isSaved(field[1]), "an inbox message names it")
    assertTrue(isSaved(field[2]), "its grace period is running")
    assertTrue(isSaved(field[3]) and isSaved(field[keep + 2]), "field jobs keep their own " .. keep)
    assertTrue(not isSaved(declined), "declined jobs are never saved")
    assertTrue(isSaved(offered) and isSaved(accepted), "unfinished jobs always stay")
    assertEquals(jobs.nextJobId, tc.Jobs.nextJobId, "ids carry on from where they were")

    -- With nothing naming them, the old ones go.
    tc.Finances.invoicesById, tc.Claims.pendingClaims, tc.RepairContracts.pendingClaims = {}, {}, {}
    tc.Cooldown.entriesByFarm[1], tc.RandomEvents.incidents, tc.Inbox.messagesById = {}, {}, {}
    field[2].graceRemainingMs = nil
    xmlFile = {}
    tc.Jobs:saveToXmlFile(xmlFile)
    jobs = TheContractorJobs.new()
    jobs:loadFromXMLFile(xmlFile)
    for i = 1, 6 do
        assertTrue(not isSaved(workshop[i]), "workshop job " .. i)
    end
    assertTrue(not isSaved(field[1]) and not isSaved(field[2]))
    assertEquals(#jobs:getAllJobs(1), 2 * keep + 2)
end)

test("the queue, collections and claims survive a save", function()
    local world, tc = setup()
    local zone = world:addZone()
    local repairContracts = tc.RepairContracts
    repairContracts:queueArrival(1, zone, 2, ADS_KIND.MAINTENANCE, 3)
    table.insert(repairContracts.removals, { farmId = 1, vehicleId = 7, uniqueId = "v7", zoneUniqueId = "zone1",
        bayIndex = 3, waitMs = 0, collectAfter = 1234.5, jobId = 4, judgeTamper = true })
    table.insert(repairContracts.pendingClaims, { farmId = 1, jobId = 4, vehicleName = "Fendt", amount = 900,
        notifyDay = 12 })

    local xmlFile = {}
    repairContracts:saveToXmlFile(xmlFile)
    local loaded = TheContractorRepairContracts.new()
    loaded:loadFromXMLFile(xmlFile)
    assertEquals(#loaded.arrivals, 1)
    assertEquals(loaded.arrivals[1].kind, "maintenance")
    assertEquals(loaded.arrivals[1].severity, 3)
    assertEquals(loaded.arrivals[1].bayIndex, 2)
    assertEquals(loaded.removals[1].uniqueId, "v7")
    assertEquals(loaded.removals[1].collectAfter, 1234.5)
    assertEquals(loaded.removals[1].jobId, 4)
    assertEquals(loaded.removals[1].judgeTamper, true)
    assertEquals(loaded.pendingClaims[1].amount, 900)
end)

test("a customer's machine is kept out of the farm's own lists", function()
    local world, tc = setup()
    local _, vehicle = makeOffer(world, tc)
    local own = world:addVehicle({ name = "Our tractor" })
    assertTrue(TheContractorRepairContracts.isContractVehicle(vehicle))
    assertTrue(not TheContractorRepairContracts.isContractVehicle(own))

    world:load("src/business/JobGeneration.lua")
    local vehicles = TheContractorJobGeneration.getFarmVehicles(1)
    assertEquals(#vehicles, 1)
    assertEquals(vehicles[1], own)
end)

test("vanilla's workshop lists a customer's machine standing in it, while its job's open", function()
    local world, tc = setup()
    local job, vehicle = makeOffer(world, tc)
    local own = world:addVehicle({ name = "Our tractor" })
    function table.hasElement(list, value)
        for _, element in ipairs(list) do
            if element == value then
                return true
            end
        end
        return false
    end
    entityExists = function() return true end
    vehicle.rootNode, own.rootNode = 2, 1
    for _, v in ipairs({ vehicle, own }) do
        v.rootVehicle = v
        function v:getChildVehicles() return { self } end
    end
    g_currentMission.nodeToObject = { [11] = vehicle, [12] = own }
    local sellingPoint = { vehicleShapesInRange = { [11] = true, [12] = true } }
    -- Vanilla's own list: the farm's own machine only (MISSION isn't shown).
    local function vanilla() return { own } end

    local listed = TheContractorRepairContracts.determineCurrentVehicles(sellingPoint, vanilla)
    assertEquals(#listed, 2)
    assertEquals(listed[1], own, "sorted by root node, as vanilla does")
    assertEquals(listed[2], vehicle)

    tc.Jobs:transitionJobState(1, job.id, TheContractorJob.STATE.DECLINED)
    TheContractorRepairContracts.clearCache()
    listed = TheContractorRepairContracts.determineCurrentVehicles(sellingPoint, vanilla)
    assertEquals(#listed, 1, "not once the customer's taking it back")
end)

test("service vehicle mods' workshops list a customer's machine too", function()
    local world, tc = setup()
    local job, vehicle = makeOffer(world, tc)
    local own = world:addVehicle({ name = "Our tractor" })
    function table.hasElement(list, value)
        for _, element in ipairs(list) do
            if element == value then
                return true
            end
        end
        return false
    end
    entityExists = function() return true end
    local shown = {}
    setVisibility = function(node, visible) shown[node] = visible end
    vehicle.rootNode, own.rootNode = 2, 1
    for _, v in ipairs({ vehicle, own }) do
        v.rootVehicle = v
        function v:getChildVehicles() return { self } end
    end
    g_currentMission.nodeToObject = { [11] = vehicle, [12] = own }
    world:load("src/util/TCServiceVehicleMods.lua")

    -- Shaped like GtX's ServiceVehicleWorkshop (FS25_FST99Service) and
    -- Rockstar's MobileWorkshop: both only take a vehicle that shows in the
    -- vehicles overview, which MISSION never does.
    local markers = {}
    local ServiceVehicleWorkshop = {}
    function ServiceVehicleWorkshop:determineCurrentVehicles()
        local vehicles = {}
        for shapeId in pairs(self.vehicleShapesInRange) do
            if g_currentMission.nodeToObject[shapeId] == own then
                table.insert(vehicles, own)
            end
        end
        self.currentVehicles = vehicles
        setVisibility(self.infoTextsNode, #vehicles > 0)
        self:updateTriggerMarkers(#vehicles > 0)
        return vehicles
    end
    function ServiceVehicleWorkshop:updateTriggerMarkers(hasVehicles) table.insert(markers, hasVehicles) end
    local MobileWorkshop = {}
    function MobileWorkshop:getIsValidVehicle(v, farmId)
        return v == own and v:getOwnerFarmId() == farmId
    end
    g_modIsLoaded = { FS25_FST99Service = true, FS25_mobileWorkshop = true, FS25_Other = true }
    FS25_FST99Service = { ServiceVehicleWorkshop = ServiceVehicleWorkshop }
    FS25_mobileWorkshop = { MobileWorkshop = MobileWorkshop }
    FS25_Other = {}
    TCServiceVehicleMods.install()
    TCServiceVehicleMods.install()

    -- The customer's machine alone in the service truck's trigger.
    local workshop = setmetatable({ vehicleShapesInRange = { [11] = true }, infoTextsNode = 99 },
        { __index = ServiceVehicleWorkshop })
    local listed = workshop:determineCurrentVehicles()
    assertEquals(#listed, 1)
    assertEquals(listed[1], vehicle)
    assertEquals(workshop.currentVehicles, listed)
    assertEquals(shown[99], true, "info board back on")
    assertEquals(markers[#markers], true, "markers back on")
    -- With the farm's own machine as well.
    workshop.vehicleShapesInRange[12] = true
    listed = workshop:determineCurrentVehicles()
    assertEquals(#listed, 2, "hooked once, however many loads")
    assertEquals(listed[1], own)

    assertTrue(MobileWorkshop:getIsValidVehicle(vehicle, 1))
    assertTrue(MobileWorkshop:getIsValidVehicle(own, 1))
    assertTrue(not MobileWorkshop:getIsValidVehicle(vehicle, 2), "not another farm's")

    tc.Jobs:transitionJobState(1, job.id, TheContractorJob.STATE.DECLINED)
    TheContractorRepairContracts.clearCache()
    assertEquals(#workshop:determineCurrentVehicles(), 1, "not once the customer's taking it back")
    assertTrue(not MobileWorkshop:getIsValidVehicle(vehicle, 1))
end)

-- Progress shown in Job details -------------------------------------------------

local function setContract(world, vehicle, kind, items, doneIds, visibleIds)
    vehicle.quote.kind = kind
    vehicle.quote.items = items
    world.adsEnv.ADS_RepairContracts.getStatus = function()
        local statusItems = {}
        for _, item in ipairs(items) do
            if item.kind ~= "service" then
                table.insert(statusItems, { id = item.id, kind = item.kind, done = doneIds[item.id] == true })
            end
        end
        return { state = "open", items = statusItems }
    end
    vehicle.getActiveBreakdowns = function()
        local active = {}
        for _, item in ipairs(items) do
            if item.kind == "fault" and not doneIds[item.id] then
                active[item.id] = { isVisible = visibleIds[item.id] == true }
            end
        end
        return active
    end
end

local REPAIR_ITEMS = {
    { id = "inspection", kind = "service", nameKey = "ads_spec_inspection_visual", procedure = "inspection", price = 100 },
    { id = "TURBO", kind = "fault", nameKey = "ads_component_turbocharger", procedure = "repairComponent", price = 600 },
    { id = "PUMP", kind = "fault", nameKey = "ads_component_engine_oil_pump", procedure = "replaceComponent",
        price = 800 },
}

test("progress names and counts no fault until it's found", function()
    local world, tc = setup()
    local _, vehicle = makeOffer(world, tc)
    setContract(world, vehicle, "repair", REPAIR_ITEMS, {}, {})
    local progress = TCADSRepairContracts.getProgress(vehicle)
    assertEquals(progress.total, nil, "no count before the inspection")
    assertEquals(progress.fixed, 0)
    assertEquals(#progress.items, 0, "the inspection isn't listed, and no fault is")
end)

test("progress counts every fault once they're all known, fixed ones included", function()
    local world, tc = setup()
    local _, vehicle = makeOffer(world, tc)
    setContract(world, vehicle, "repair", REPAIR_ITEMS, { TURBO = true }, { PUMP = true })
    local progress = TCADSRepairContracts.getProgress(vehicle)
    assertEquals(progress.total, 2)
    assertEquals(progress.fixed, 1)
    assertEquals(progress.items[1].operation, "repair")
    assertTrue(progress.items[1].done)
    assertEquals(progress.items[2].operation, "replacement", "how the dealer priced it")
    assertEquals(progress.items[2].price, 800)
    assertTrue(not progress.items[2].done)
end)

test("a fixed fault with another still hidden gives no total", function()
    local world, tc = setup()
    local _, vehicle = makeOffer(world, tc)
    setContract(world, vehicle, "repair", REPAIR_ITEMS, { TURBO = true }, {})
    local progress = TCADSRepairContracts.getProgress(vehicle)
    assertEquals(progress.total, nil)
    assertEquals(progress.fixed, 1)
    assertEquals(#progress.items, 1)
end)

local SERVICE_ITEMS = {
    { id = "c1", kind = "consumable", nameKey = "ads_ws_consumable_motor_oil", procedure = "replaceFluid", price = 90 },
    { id = "c2", kind = "consumable", nameKey = "ads_ws_consumable_oil_filter", procedure = "replaceConsumable",
        price = 40 },
}

test("a service's consumables are known only once it's been inspected", function()
    local world, tc = setup()
    local _, vehicle = makeOffer(world, tc)
    setContract(world, vehicle, "maintenance", SERVICE_ITEMS, {}, {})
    local progress = TCADSRepairContracts.getProgress(vehicle)
    assertEquals(progress.total, nil, "ADS shows nothing of it before an inspection")
    assertEquals(#progress.items, 0)
    assertTrue(not TCADSRepairContracts.isInspected(vehicle))
    world.inspectionDates[vehicle.id] = 0
    assertTrue(not TCADSRepairContracts.isInspected(vehicle), "0 is an empty log, not an inspection")
    world.inspectionDates[vehicle.id] = { day = 3 }
    assertTrue(TCADSRepairContracts.isInspected(vehicle))
    assertEquals(TCADSRepairContracts.getProgress(vehicle).total, 2)
end)

test("an inspected service's consumables are listed and counted", function()
    local world, tc = setup()
    local _, vehicle = makeOffer(world, tc)
    setContract(world, vehicle, "maintenance", SERVICE_ITEMS, { c2 = true }, {})
    world.inspectionDates[vehicle.id] = { day = 3 }
    local progress = TCADSRepairContracts.getProgress(vehicle)
    assertEquals(progress.total, 2)
    assertEquals(progress.fixed, 1)
    assertEquals(progress.items[1].operation, "change", "what it needs, for the checklist")
    assertEquals(progress.items[2].operation, "replace")
end)

test("a stock part on a service's checklist carries the size the machine takes", function()
    local world, tc = setup()
    local _, vehicle = makeOffer(world, tc)
    world.adsEnv.ADS_PartsShop = { getPartGrade = function(_, partId)
        return partId == "airFilter" and "M" or nil
    end }
    setContract(world, vehicle, "maintenance", {
        { id = "c1", kind = "consumable", consumableId = "airFilter", nameKey = "ads_ws_consumable_air_filter",
            procedure = "replaceConsumable", price = 160 },
        { id = "c2", kind = "consumable", consumableId = "oilFilter", nameKey = "ads_ws_consumable_oil_filter",
            procedure = "replaceConsumable", price = 40 },
    }, {}, {})
    world.inspectionDates[vehicle.id] = { day = 3 }
    local progress = TCADSRepairContracts.getProgress(vehicle)
    assertEquals(progress.items[1].grade, "M")
    assertEquals(progress.items[2].grade, nil, "not a stock part")
end)

test("every operation the checklist can show has its text", function()
    setup()
    local operations = { service = true }
    for _, operation in pairs(TCADSRepairContracts.OPERATIONS) do
        operations[operation] = true
    end
    for operation in pairs(operations) do
        assertTrue(g_i18n:getText("tc_repair_methodChip_" .. operation) ~= nil, operation)
    end
end)

-- 102: inspect, negotiate, then accept -------------------------------------------

-- A repair offer with one hidden fault (TURBO), one that can be repaired with
-- machining or replaced by hand.
local function makeFaultOffer(world, tc)
    local job, vehicle = makeOffer(world, tc)
    setContract(world, vehicle, "repair", {
        { id = "inspection", kind = "service", nameKey = "ads_spec_inspection_visual", procedure = "inspection",
            price = 100 },
        { id = "TURBO", kind = "fault", nameKey = "ads_component_turbocharger", procedure = "repairComponent",
            price = 600 },
    }, {}, {})
    world.farmTools[vehicle.id] = {
        canDo = true, missing = { "machining" },
        items = {
            { id = "TURBO", kind = "fault", canDo = true, subcontractPrice = 600, options = {
                { operation = "repair", tools = { "machining" }, canDo = false, missing = { "machining" },
                    partsCost = 0, laborHours = 3 },
                { operation = "replacement", tools = {}, canDo = true, place = "player", missing = {},
                    partsCost = 1200, laborHours = 1.5 },
            } },
        },
        plan = { canDo = true, partsCost = 1200, laborHours = 2, subcontractCost = 0 },
    }
    return job, vehicle
end

local function findFault(vehicle)
    local getActiveBreakdowns = vehicle.getActiveBreakdowns
    vehicle.getActiveBreakdowns = function(self)
        local breakdowns = getActiveBreakdowns(self)
        breakdowns.TURBO = { isVisible = true }
        return breakdowns
    end
end

test("a repair can't be priced until every fault's been found", function()
    local world, tc = setup()
    local job, vehicle = makeFaultOffer(world, tc)
    assertTrue(not TCADSRepairContracts.isInspected(vehicle))
    assertTrue(not TheContractorRepairContracts.isReadyToQuote(job))
    assertEquals(tc.RepairContracts:proposeQuote(1, job.id, 0.4), nil, "refused out of hand")
    assertEquals(job.state, TheContractorJob.STATE.OFFERED)

    findFault(vehicle)
    assertTrue(TCADSRepairContracts.isInspected(vehicle))
    assertTrue(TheContractorRepairContracts.isReadyToQuote(job))
end)

test("the farm's plan names no fault and gives no totals before the inspection", function()
    local world, tc = setup()
    local job, vehicle = makeFaultOffer(world, tc)
    local plan = TCADSRepairContracts.getFarmPlan(vehicle, 1)
    assertEquals(#plan.faults, 0)
    assertEquals(plan.plan, nil)
    assertEquals(plan.missing, nil)
    assertEquals(TheContractorRepairContracts.getToolsWarning(job), nil, "no warning that gives it away either")
    assertEquals(TheContractorRepairContracts.getMissingKit(job), nil, "nor missing kit")

    findFault(vehicle)
    plan = TCADSRepairContracts.getFarmPlan(vehicle, 1)
    assertEquals(#plan.faults, 1)
    local options = plan.faults[1].options
    assertEquals(options[1].operation, "repair")
    assertTrue(not options[1].canDo, "no machining")
    assertEquals(options[1].missing[1], "machining")
    assertEquals(options[2].operation, "replacement")
    assertTrue(options[2].canDo, "hand tools, at the tool box")
    assertEquals(options[2].partsCost, 1200)
    assertEquals(plan.faults[1].subcontractPrice, 600)
    assertEquals(plan.plan.partsCost, 1200)
    assertEquals(plan.plan.laborHours, 2)
    assertTrue(plan.plan.canDo)
    assertEquals(plan.repairNeeds[1], "machining", "a full repair needs the machining it lacks")
end)

test("each found fault as a checklist: repair needs an upgrade, replace is available", function()
    local world, tc = setup()
    local job, vehicle = makeFaultOffer(world, tc)
    findFault(vehicle)
    local plan = TCADSRepairContracts.getFarmPlan(vehicle, 1)
    local rows = TCADSRepairContracts.getFaultChecklist(plan.faults[1])
    assertEquals(rows[1].operation, "repair")
    assertEquals(rows[1].status, "missing")
    assertEquals(rows[1].missing[1], "machining")
    assertEquals(rows[2].operation, "replacement")
    assertEquals(rows[2].status, "available")
    assertEquals(rows[2].partsCost, 1200)
    assertTrue(TheContractorRepairContracts.getToolsWarning(job) ~= nil, "warned")
    assertEquals(#TheContractorRepairContracts.getMissingKit(job).names, 1, "the one upgrade missing")
    assertEquals(TheContractorRepairContracts.getMissingKit(job).noteKey, "tc_repairQuote_kitNote_replaceOnly")

    -- A fault ADS won't let anyone repair: always repair then replace, the repair not possible.
    rows = TCADSRepairContracts.getFaultChecklist({ options = { { operation = "replacement", tools = {}, canDo = true } } })
    assertEquals(#rows, 2)
    assertEquals(rows[1].status, "notPossible")
    assertEquals(rows[2].status, "available")
end)

test("tools are named as the upgrades that bring them, once each", function()
    setup()
    assertEquals(#TCADSRepairContracts.getUpgradeNameList({ "machining" }), 1)
    assertEquals(#TCADSRepairContracts.getUpgradeNameList({ "lightCrane", "heavyCrane", "scanner" }), 2,
        "both cranes come with one upgrade")
    assertEquals(#TCADSRepairContracts.getUpgradeNameList({ "jack" }), 1, "no upgrade brings it: named itself")
end)

test("a quote under the ceiling: accepted at that price, and ADS lets the work start", function()
    local world, tc = setup()
    local job, vehicle = makeOffer(world, tc)
    job.workshop.refusalMargin = 1.0
    assertEquals(tc.RepairContracts:proposeQuote(1, job.id, 0.6), "accepted")
    assertEquals(job.state, TheContractorJob.STATE.ACCEPTED)
    assertNear(job.workshop.margin, 0.6, 0.0001)
    assertNear(job:getPrice(), 1600, 0.001, "the parts plus 60%")
    assertEquals(world.stages[vehicle.id], "authorized")
    assertEquals(tc.RepairContracts:proposeQuote(1, job.id, 0.6), nil, "only once")
end)

test("a quote over the ceiling: the customer takes the machine elsewhere", function()
    local world, tc = setup()
    local job, vehicle = makeOffer(world, tc)
    job.workshop.refusalMargin = 1.0
    assertEquals(tc.RepairContracts:proposeQuote(1, job.id, 1.05), "refused")
    assertEquals(job.state, TheContractorJob.STATE.DECLINED)
    assertEquals(#tc.RepairContracts.removals, 1)
    assertEquals(world.stages[vehicle.id], "inspection", "never authorized")
    tc.RepairContracts:update(TheContractorRepairContracts.PLACE_CHECK_MS)
    assertEquals(world.calls.released[1], vehicle.id, "released as it's collected")
end)

test("a quote at the least price, out of range, or for another farm", function()
    local world, tc = setup()
    world.partsCost = 200
    local job = makeOffer(world, tc)
    assertEquals(tc.RepairContracts:proposeQuote(1, job.id, -0.1), nil)
    assertEquals(tc.RepairContracts:proposeQuote(1, job.id, TheContractorRepairContracts.MARGIN_MAX + 0.1), nil)
    assertEquals(tc.RepairContracts:proposeQuote(2, job.id, 0.4), nil)
    assertEquals(tc.RepairContracts:proposeQuote(1, job.id, 0), "accepted", "nothing over the cost is fine")
    assertEquals(job:getPrice(), TheContractorRepairContracts.MIN_PRICE, "never under MIN_PRICE")
end)

test("the console forces the next answer, once", function()
    local world, tc = setup()
    local registered = {}
    TCConsole = { register = function(group, name, def) registered[name] = def end }
    TheContractorRepairContracts.registerConsoleCommands()
    local command = registered.quoteOutcome
    assertEquals(command.run(1, { "bogus" }), false)
    command.run(1, { "refused" })
    local job = makeOffer(world, tc)
    assertEquals(tc.RepairContracts:proposeQuote(1, job.id, 0), "refused")
    assertEquals(tc.RepairContracts.forcedQuoteOutcome, nil)

    command.run(1, { "accepted" })
    local zone = world:addZone({ uniqueId = "zone2" })
    tc.RepairContracts:queueArrival(1, zone, 1, ADS_KIND.REPAIR, 2)
    tc.RepairContracts:update(TheContractorRepairContracts.PLACE_CHECK_MS)
    world:finishLoad()
    local other = nil
    for _, candidate in ipairs(tc.Jobs:getAllJobs(1)) do
        if candidate.state == TheContractorJob.STATE.OFFERED then
            other = candidate
        end
    end
    other.workshop.refusalMargin = 0.1
    assertEquals(tc.RepairContracts:proposeQuote(1, other.id, 2.0), "accepted")
    command.run(1, { "refused" })
    command.run(1, { "clear" })
    assertEquals(tc.RepairContracts.forcedQuoteOutcome, nil)
end)

-- Completes an accepted job at a margin, done at once (the full speed bonus).
local function completeAtMargin(world, tc, margin)
    local job, vehicle = makeOffer(world, tc)
    job.workshop.refusalMargin = 3
    tc.RepairContracts:proposeQuote(1, job.id, margin)
    tc.RepairContracts:resolveSavedVehicles()
    world.listener(vehicle, { state = "done" })
    return job
end

test("reputation follows the margin: more under the benchmark, a loss well over it", function()
    local base = TheContractorRepairContracts.REPUTATION_BY_KIND.repair[2]
    local world, tc = setup()
    local job = completeAtMargin(world, tc, 0.4)
    assertEquals(world.calls.reputation[1], math.floor(base * 1.5), "the benchmark: as before")
    assertEquals(job.workshop.reputationReward, world.calls.reputation[1], "kept for the completed view")

    world, tc = setup()
    completeAtMargin(world, tc, 0)
    assertEquals(world.calls.reputation[1], math.floor(base * 1.5 * 1.25))

    world, tc = setup()
    completeAtMargin(world, tc, 1.2)
    assertEquals(world.calls.reputation[1], -math.floor(base * 0.5), "a loss, whatever the speed")
end)

test("a rip-off marks the farm for three months: fewer arrivals and breakdowns, a notice, saved", function()
    local world, tc = setup()
    local published, removed = {}, {}
    tc.Notices = {
        publish = function(_, farmId, text)
            table.insert(published, text)
            return #published
        end,
        remove = function(_, noticeId) table.insert(removed, noticeId) end,
    }
    completeAtMargin(world, tc, 0.4)
    assertTrue(not tc.RepairContracts:isOvercharging(1), "a fair price: nothing")

    completeAtMargin(world, tc, 0.7)
    assertTrue(tc.RepairContracts:isOvercharging(1))
    assertEquals(tc.RepairContracts:getArrivalFactor(1), TheContractorRepairContracts.OVERCHARGE_ARRIVAL_FACTOR)
    assertEquals(tc.RepairContracts.overcharged[1].untilDay, world.today + 3, "3 months at 1 day each")
    assertEquals(#published, 1)

    completeAtMargin(world, tc, 0.8)
    assertEquals(removed[1], 1, "the old notice comes down")
    assertEquals(tc.RepairContracts.overcharged[1].noticeId, 2)

    local xmlFile = {}
    tc.RepairContracts:saveToXmlFile(xmlFile)
    local loaded = TheContractorRepairContracts.new()
    loaded:loadFromXMLFile(xmlFile)
    assertEquals(loaded.overcharged[1].untilDay, world.today + 3)
    assertEquals(loaded.overcharged[1].noticeId, 2)

    TheContractorRepairContracts.ARRIVAL_CHANCE = 0
    g_currentMission.environment.currentMonotonicDay = world.today + 3
    tc.RepairContracts:onDayChanged()
    assertTrue(not tc.RepairContracts:isOvercharging(1))
    assertEquals(removed[2], 2)
end)

test("a workshop job's cost, margins and reputation stream and save; the ceiling only saves", function()
    local world, tc = setup()
    world.laborHours = 2
    local job = completeAtMargin(world, tc, 0.5)
    local stream = world:newStream()
    TheContractorJobs.writeJob(stream, job)
    local copy = TheContractorJobs.readJob(stream).workshop
    assertNear(copy.baseParts, job.workshop.baseParts, 0.01)
    assertNear(copy.baseLabour, job.workshop.baseLabour, 0.01)
    assertNear(copy.laborHours, 2, 0.0001)
    assertNear(copy.benchmarkMargin, 0.4, 0.0001)
    assertNear(copy.margin, 0.5, 0.0001)
    assertEquals(copy.reputationReward, job.workshop.reputationReward)
    assertEquals(copy.refusalMargin, nil, "the customer's ceiling stays on the server")

    local xmlFile = {}
    tc.Jobs:saveToXmlFile(xmlFile)
    local jobs = TheContractorJobs.new()
    jobs:loadFromXMLFile(xmlFile)
    local saved = jobs:getJob(1, job.id).workshop
    assertNear(saved.margin, 0.5, 0.0001)
    assertNear(saved.refusalMargin, 3, 0.0001)
    assertEquals(saved.reputationReward, job.workshop.reputationReward)
end)

test("accepting through tcJob state still lets ADS start the work", function()
    local world, tc = setup()
    local job, vehicle = makeOffer(world, tc)
    tc.Jobs:transitionJobState(1, job.id, TheContractorJob.STATE.ACCEPTED)
    assertEquals(world.stages[vehicle.id], "authorized")
    assertEquals(TheContractorRepairContracts.getMarginFactor(job), 1, "no margin agreed: no change")
end)

test("without ADS's stage gate the feature stays off", function()
    local world = setup()
    world.adsEnv.ADS_RepairContracts.authorize = nil
    TCADSRepairContracts.detect()
    assertTrue(not TCADSRepairContracts.isActive())
end)

-- Parts services --------------------------------------------------------------------------

-- ADS takes targets and has the two stock parts; a machine without one of
-- `lacking` refuses any request naming it. Every request is kept.
local function enableParts(world, lacking)
    local api = world.adsEnv.ADS_RepairContracts
    api.getInfo = function() return { version = 1, targets = true } end
    world.adsEnv.ADS_Config = { SPARE_PARTS_BOX = { GRADED_PARTS = {
        { id = "battery", nameKey = "ads_ws_consumable_battery" },
        { id = "airFilter", nameKey = "ads_ws_consumable_air_filter" },
    } } }
    world.requests = {}
    local prepare = api.prepareVehicle
    api.prepareVehicle = function(vehicle, request)
        table.insert(world.requests, request)
        for _, target in ipairs(request.targets or {}) do
            if lacking ~= nil and lacking[target.consumable] then
                return false, "targetNotApplicable"
            end
        end
        return prepare(vehicle, request)
    end
end

test("arrivals split 50% repair, 30% service, 20% parts service; no parts service without ADS's targets", function()
    setup()
    local pick = TheContractorRepairContracts.pickKind
    local function at(roll, hasParts)
        return pick(function() return roll end, hasParts)
    end
    assertEquals(at(0.49, true), "repair")
    assertEquals(at(0.5, true), "maintenance")
    assertEquals(at(0.79, true), "maintenance")
    assertEquals(at(0.8, true), "parts")
    assertEquals(at(0.99, false), "maintenance", "its share goes to the others")
    assertEquals(at(0.62, false), "repair")
    assertTrue(not TheContractorRepairContracts.canServiceParts(), "ADS without targets")
end)

test("a parts service's targets: one or both stock parts, then each on its own", function()
    setup()
    local parts = { { id = "battery" }, { id = "airFilter" } }
    local both, one = 0, 0
    for seed = 1, 40 do
        math.randomseed(seed)
        local sets = TheContractorRepairContracts.getPartTargetSets(parts, math.random)
        if #sets[1] == 2 then
            both = both + 1
            assertEquals(#sets, 3)
            assertEquals(#sets[2], 1)
            assertEquals(#sets[3], 1)
            assertTrue(sets[2][1].consumable ~= sets[3][1].consumable)
        else
            one = one + 1
            assertEquals(#sets, 2, "then the other part")
            assertTrue(sets[1][1].consumable ~= sets[2][1].consumable)
        end
    end
    assertTrue(both > 0 and one > 0, "both on " .. both .. " of 40")
    assertEquals(#TheContractorRepairContracts.getPartTargetSets({}, math.random), 0)
end)

test("a parts service is an ordinary service job of only the parts the machine takes, with labour", function()
    local world, tc = setup()
    enableParts(world, { airFilter = true })
    world.partsCost, world.laborHours = 400, 1
    local zone = world:addZone()
    for seed = 1, 6 do
        math.randomseed(seed)
        world.requests = {}
        tc.Jobs = TheContractorJobs.new()
        tc.RepairContracts = TheContractorRepairContracts.new()
        tc.RepairContracts:queueArrival(1, zone, 1, "parts", 2)
        assertTrue(tc.RepairContracts.arrivals[1].stockParts)
        tc.RepairContracts:update(TheContractorRepairContracts.PLACE_CHECK_MS)
        world:finishLoad()
        assertEquals(#tc.RepairContracts.arrivals, 0)

        local last = world.requests[#world.requests]
        assertEquals(last.kind, "maintenance")
        assertEquals(#last.targets, 1, "the battery alone, once the air filter's refused")
        assertEquals(last.targets[1].consumable, "battery")
        local job = tc.Jobs:getAllJobs(1)[1]
        assertEquals(job.jobType, "adsMaintenance")
        assertEquals(job.state, TheContractorJob.STATE.OFFERED)
        assertTrue(job.workshop.baseLabour > 0, "labour charged")
        assertEquals(world.stages[job.workshop.vehicleId], "inspection", "found on inspection")
    end
end)

test("a machine with neither part gets an ordinary service; a queued parts service keeps its kind over a save", function()
    local world, tc = setup()
    enableParts(world, { battery = true, airFilter = true })
    local zone = world:addZone()
    tc.RepairContracts:queueArrival(1, zone, 1, "parts", 2)

    local xmlFile = {}
    tc.RepairContracts:saveToXmlFile(xmlFile)
    local loaded = TheContractorRepairContracts.new()
    loaded:loadFromXMLFile(xmlFile)
    assertTrue(loaded.arrivals[1].stockParts)
    assertEquals(loaded.arrivals[1].kind, "maintenance")

    tc.RepairContracts:update(TheContractorRepairContracts.PLACE_CHECK_MS)
    world:finishLoad()
    assertEquals(world.requests[#world.requests].targets, nil)
    assertEquals(tc.Jobs:getAllJobs(1)[1].jobType, "adsMaintenance")
end)
