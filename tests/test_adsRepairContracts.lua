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
    g_cameraManager = def.hasCamera and { getActiveCamera = function() return 5 end } or nil
    VehiclePropertyState = { OWNED = 1, MISSION = 4 }
    VehicleLoadingState = { OK = 1 }
    Environment = { PERIODS_IN_YEAR = 12 }
    TheContractor = { SaveKey = "TheContractor" }

    g_currentMission.environment = {
        currentMonotonicDay = world.today,
        dayTime = 0,
        daysPerPeriod = 1,
        getPeriodFromDay = function(_, day) return (day - 1) % 12 + 1 end,
        getDayInPeriodFromDay = function() return 1 end,
    }
    g_currentMission.getIsClient = function() return def.hasCamera == true end
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
    TCIdleStaff = { isSeen = function() return world.cameraSees == true end }
    TCParking = {
        PLACE_HEIGHT_OFFSET = 0.3,
        DEFAULT_HEIGHT = 4,
        isAreaClear = function() return world.bayBlocked ~= true end,
        getShowSlotsSetting = function() return false end,
    }
    TCParkingSlotFilter = { getCategoryTitle = function(name) return name end, SUMMARY_MAX_NAMES = 2 }

    local tc = g_currentMission.TheContractor
    tc.Settings = { scaleCost = function(_, amount) return amount end }
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
    world.status, world.farmTools, world.tampering, world.prepareResults = {}, {}, {}, {}
    world.adsEnv = {
        ADS_RepairContracts = {
            getInfo = function() return { version = 1 } end,
            prepareVehicle = function(vehicle, request)
                local result = table.remove(world.prepareResults, 1)
                if result == false then
                    return false, "noApplicableFaults"
                end
                world.prepared = request
                vehicle.quote = { price = world.quotePrice or 1000, minTools = { "lift" }, serviceLevel = "workshop",
                    operatingHours = 2450 }
                return true, "rc1"
            end,
            getQuote = function(vehicle) return vehicle.quote end,
            getStatus = function(vehicle)
                return world.status[vehicle.id] ~= nil and { state = world.status[vehicle.id] } or { state = "open" }
            end,
            checkTampering = function(vehicle)
                local findings = world.tampering[vehicle.id] or {}
                return #findings > 0, findings
            end,
            checkFarmTools = function(vehicle, farmId)
                return world.farmTools[vehicle.id] or { canDo = true, missing = {} }
            end,
            registerListener = function(id, fn) world.listener = fn return true end,
            unregisterListener = function() world.listener = nil end,
            release = function(vehicle) table.insert(world.calls.released, vehicle.id) return true end,
        },
        ADS_Maintenance = { getPartPrice = function(vehicle, componentId) return world.partPrice end },
        AdvancedDamageSystem = { PART_TYPES = { OEM = "OEM" } },
    }
    world.modTexts.FS25_AdvancedDamageSystem = { ads_ws_tool_lift = "Lift", ads_ws_tool_machining = "Machining" }

    TheContractorDrivers = { getModEnv = function() return world.adsEnv end }

    world:load("src/util/TCVehicleIds.lua")
    world:load("src/placeables/PlaceableTCParkingSlot.lua")
    world:load("src/placeables/PlaceableTCRepairZone.lua")
    world:load("src/util/TCADSRepairContracts.lua")
    world:load("src/business/Job.lua")
    world:load("src/business/Jobs.lua")
    world:load("src/business/RepairContracts.lua")
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
    local job = tc.Jobs:getAllJobs(1)[1]
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
    assertEquals(TCRepairZoneActivatable.getSummary(world:addZone({ uniqueId = "z2" }),
        PlaceableTCParkingSlot.newFilter()), "Any tractor")
end)

test("severity rises with standing, always 1-3", function()
    setup()
    local pick = TheContractorRepairContracts.pickSeverity
    assertEquals(pick(0, function() return 0 end), 1)
    assertEquals(pick(0, function() return 0.99 end), 1)
    assertEquals(pick(1, function() return 0.99 end), 3)
    assertEquals(pick(1, function() return 0 end), 3)
    assertEquals(pick(0.5, function() return 0.5 end), 2)
end)

-- Arrivals ----------------------------------------------------------------------------

test("nothing runs while the queue is empty", function()
    local world, tc = setup()
    world:addZone()
    local looked = false
    TheContractorRepairContracts.isBaySeen = function()
        looked = true
        return false
    end
    tc.RepairContracts:update(60000)
    assertEquals(looked, false)
    assertEquals(#world.calls.spawned, 0)
end)

test("an arrival waits while its bay's seen, then comes anyway after the fallback", function()
    local world, tc = setup({ hasCamera = true })
    local zone = world:addZone()
    tc.RepairContracts:queueArrival(1, zone, 1, ADS_KIND.REPAIR, 1)
    world.cameraSees = true

    tc.RepairContracts:update(TheContractorRepairContracts.PLACE_CHECK_MS)
    assertEquals(#world.calls.spawned, 0, "the player's looking at it")

    tc.RepairContracts:update(TheContractorRepairContracts.PLACE_FALLBACK_MS)
    assertEquals(#world.calls.spawned, 1, "placed anyway once it's waited long enough")
    local data = world.calls.spawned[1]
    assertEquals(data.propertyState, VehiclePropertyState.MISSION)
    assertEquals(data.farmId, 1)
    assertNear(data.x, 2, 0.001, "centred in bay 1")
    assertNear(data.z, 4.5, 0.001)
end)

test("in multiplayer there's no seen check at all", function()
    local world, tc = setup({ hasCamera = true })
    g_currentMission.missionDynamicInfo = { isMultiplayer = true }
    local zone = world:addZone()
    tc.RepairContracts:queueArrival(1, zone, 1, ADS_KIND.REPAIR, 1)
    world.cameraSees = true
    tc.RepairContracts:update(TheContractorRepairContracts.PLACE_CHECK_MS)
    assertEquals(#world.calls.spawned, 1)
end)

test("an arrival comes straight away when no one can see the bay", function()
    local world, tc = setup({ hasCamera = true })
    local zone = world:addZone()
    tc.RepairContracts:queueArrival(1, zone, 2, ADS_KIND.REPAIR, 1)
    world.cameraSees = true
    tc.RepairContracts:update(TheContractorRepairContracts.PLACE_CHECK_MS)
    assertEquals(#world.calls.spawned, 0, "the host's camera sees it")
    world.cameraSees = false
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
    assertEquals(job.workshop.offerExpiresDay, world.today + TheContractorRepairContracts.OFFER_DAYS)
    assertEquals(job.deadlineDay, world.today + TheContractorRepairContracts.OFFER_DAYS +
        TheContractorRepairContracts.DUE_DAYS)
    assertTrue(job:getPrice() >= 1149 and job:getPrice() <= 1250, "quote plus 15-25%, floored")
    assertEquals(job:getLocationText(), "fendt942.xml")
    assertTrue(TheContractorRepairContracts.isContractVehicle(second))
    assertTrue(repairContracts:isBayTaken("zone1", 1))
    assertTrue(not repairContracts:isBayTaken("zone1", 2))
end)

test("the price is stored without EconomyScale's factor and follows it", function()
    local world, tc = setup()
    g_currentMission.EconomyScale = { factor = 2 }
    world.quotePrice = 2000
    local job = makeOffer(world, tc)
    local margin = job.basePrice / 1000 - 1
    assertTrue(margin >= 0.149 and margin <= 0.25, "base is the quote / factor plus the margin (floored)")
    g_currentMission.EconomyScale.factor = 3
    assertNear(job:getPrice(), job.basePrice * 3, 0.001)
end)

test("the daily roll only fills free bays", function()
    local world, tc = setup()
    world:addZone()
    TheContractorRepairContracts.ARRIVAL_CHANCE = 1
    tc.RepairContracts:onDayChanged()
    assertEquals(#tc.RepairContracts.arrivals, 3)
    tc.RepairContracts:onDayChanged()
    assertEquals(#tc.RepairContracts.arrivals, 3, "every bay's taken now")
end)

-- Accepting -----------------------------------------------------------------------------

test("missing equipment blocks accepting and counter offers, live", function()
    local world, tc = setup()
    local job, vehicle = makeOffer(world, tc)
    world.farmTools[vehicle.id] = { canDo = false, missing = { "lift", "machining" } }

    local problem = TheContractorJobs.getAcceptProblem(job)
    assertEquals(problem, "You haven't the equipment for this job yet. Requires: Lift, Machining.")
    assertEquals(tc.Jobs:transitionJobState(1, job.id, TheContractorJob.STATE.ACCEPTED), false)
    assertEquals(tc.Jobs:proposeCounterOffer(1, job.id, 900), nil)
    assertEquals(job.state, TheContractorJob.STATE.OFFERED)

    world.farmTools[vehicle.id] = { canDo = true, missing = {} }
    assertEquals(TheContractorJobs.getAcceptProblem(job), nil)
    assertEquals(tc.Jobs:transitionJobState(1, job.id, TheContractorJob.STATE.ACCEPTED), true)
end)

test("an offer lapses after its days and the customer takes the machine", function()
    local world, tc = setup()
    local job, vehicle = makeOffer(world, tc)
    g_currentMission.environment.currentMonotonicDay = job.workshop.offerExpiresDay + 1
    tc.Jobs:onDayChanged()
    assertEquals(job.state, TheContractorJob.STATE.DECLINED)
    assertEquals(world.calls.released[1], vehicle.id)
    assertEquals(#tc.RepairContracts.removals, 1)

    tc.RepairContracts:update(TheContractorRepairContracts.PLACE_CHECK_MS)
    assertTrue(vehicle.isDeleted, "collected once out of sight")
    assertEquals(#tc.RepairContracts.removals, 0)
end)

test("a machine isn't taken from under someone driving it", function()
    local world, tc = setup()
    local job, vehicle = makeOffer(world, tc)
    function vehicle:getIsControlled() return true end
    tc.Jobs:transitionJobState(1, job.id, TheContractorJob.STATE.DECLINED)
    tc.RepairContracts:update(TheContractorRepairContracts.PLACE_FALLBACK_MS)
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
    assertEquals(world.calls.reputation[1], TheContractorRepairContracts.REPUTATION_BY_SEVERITY[2])
    assertEquals(world.calls.logged[1][1], "completed")
    assertEquals(#tc.RepairContracts.removals, 1)
    assertEquals(job:getSummaryText(), "Workshop Repair on the fendt942.xml")
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
    local base = TheContractorRepairContracts.REPUTATION_BY_SEVERITY[2]
    assertEquals(world.calls.reputation[1], -math.floor(math.max(10, base * 1.5)))
    assertEquals(#tc.RepairContracts.pendingClaims, 0)
    assertEquals(#world.calls.messages, 0)
end)

test("tampered at the deadline: no pay, double the loss, and a claim over the threshold", function()
    local world, tc = setup()
    world.partPrice = 4000
    local job = missAccepted(world, tc, { { kind = "component", id = "engine", accepted = 0.8, current = 0.3 } })
    assertEquals(#world.calls.invoices, 0, "not paid")
    local base = math.floor(math.max(10, TheContractorRepairContracts.REPUTATION_BY_SEVERITY[2] * 1.5))
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

-- The rest ------------------------------------------------------------------------------

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
    assertEquals(copy.workshop.zoneUniqueId, nil, "server-only")

    local xmlFile = {}
    tc.Jobs:saveToXmlFile(xmlFile)
    local jobs = TheContractorJobs.new()
    jobs:loadFromXMLFile(xmlFile)
    local loaded = jobs:getJob(1, job.id)
    assertEquals(loaded.workshop.vehicleUniqueId, "vehicle" .. vehicle.id)
    assertEquals(loaded.workshop.zoneUniqueId, "zone1")
    assertEquals(loaded.workshop.offerExpiresDay, job.workshop.offerExpiresDay)
    TCVehicleIds.getObjectId = function(uniqueId) return uniqueId == "vehicle" .. vehicle.id and vehicle.id or nil end
    jobs:resolveSavedVehicles()
    assertEquals(loaded.workshop.vehicleId, vehicle.id)
end)

test("the queue, collections and claims survive a save", function()
    local world, tc = setup()
    local zone = world:addZone()
    local repairContracts = tc.RepairContracts
    repairContracts:queueArrival(1, zone, 2, ADS_KIND.MAINTENANCE, 3)
    table.insert(repairContracts.removals, { farmId = 1, vehicleId = 7, uniqueId = "v7", zoneUniqueId = "zone1",
        bayIndex = 3, waitMs = 0 })
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
