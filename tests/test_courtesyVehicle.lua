-- Courtesy vehicle (071) on the real random events (068), theft (069),
-- machinery insurance (070) and overheads (051), against a fake store:
-- picking by power, lending only on comprehensive cover, returning it at
-- settlement (waiting until it's free), and save/load and a joining client.

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
    MoneyType = { LAST_ID = 0, register = function(name) return name end }
    VehiclePropertyState = { OWNED = 2, LEASED = 3, MISSION = 4 }
    Vehicle.getCanBeSold = function() return true end
    Vehicle.getIsInUse = function() return false end
    -- Vanilla's shape: a MISSION vehicle only works a mission's field.
    WorkArea = {
        getIsAccessibleAtWorldPosition = function(vehicle, farmId, x, z, workAreaType)
            return vehicle.propertyState ~= VehiclePropertyState.MISSION, farmId, true
        end,
    }
    TheContractorJob = { STATE = { ALLOCATED = "allocated", IN_PROGRESS = "in_progress" } }

    -- The store: def { xml, name, category, price, power, motors = { { power, isDefault } },
    -- powerConfig, showInStore }.
    world.storeItems = {}
    StoreSpecies = { VEHICLE = 2, PLACEABLE = 1 }
    g_storeManager = {
        getItems = function() return world.storeItems end,
        getItemByXMLFilename = function(_, xmlFilename)
            for _, item in ipairs(world.storeItems) do
                if string.lower(item.xmlFilename) == string.lower(xmlFilename) then
                    return item
                end
            end
            return nil
        end,
    }
    ConfigurationUtil = {
        getDefaultConfigIdFromItems = function(items)
            for index, item in ipairs(items) do
                if item.isDefault then
                    return index
                end
            end
            return 1
        end,
    }
    function world:addStoreItem(def)
        local item = {
            xmlFilename = def.xml,
            name = def.name or def.xml,
            categoryName = def.category or "TRACTORSM",
            price = def.price or 100000,
            species = def.species or StoreSpecies.VEHICLE,
            showInStore = def.showInStore ~= false,
            specs = { power = def.power, powerConfig = def.powerConfig },
        }
        if def.motors ~= nil then
            item.configurations = { motor = def.motors }
        end
        table.insert(self.storeItems, item)
        return item
    end

    -- Vehicle loading is asynchronous: load() queues, finishLoads() runs
    -- the callbacks the way VehicleLoadingData does once they're in.
    VehicleLoadingState = { OK = 1, ERROR = 2 }
    world.pendingLoads = {}
    VehicleLoadingData = {
        new = function()
            local data = {}
            function data:setStoreItem(storeItem) self.storeItem = storeItem end
            function data:setLoadingPlace(places, usedPlaces) self.places = places end
            function data:setPropertyState(propertyState) self.propertyState = propertyState end
            function data:setOwnerFarmId(farmId) self.farmId = farmId end
            function data:load(callback, target, args)
                table.insert(world.pendingLoads, { data = self, callback = callback, target = target, args = args })
            end
            return data
        end,
    }
    g_currentMission.storeSpawnPlaces = { "shop" }
    g_currentMission.usedStorePlaces = {}

    world.slotFree = true
    world.placed = {}
    TCParking = {
        findSpot = function(vehicle, farmId)
            if world.slotFree then
                return 10, 0, 20, 0
            end
            return nil
        end,
        placeVehicle = function(vehicle, x, y, z, rotY)
            table.insert(world.placed, vehicle.id)
        end,
    }

    world.hidden, world.messages, world.notices, world.stats = {}, {}, {}, {}
    world.cooldown, world.jobs, world.pending, world.removedFromParking = {}, {}, {}, {}
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
    world.unhitched = {}
    TCJobSiteSetup = {
        unhitchVehicles = function(vehicleIds)
            for _, vehicleId in ipairs(vehicleIds) do
                table.insert(world.unhitched, vehicleId)
            end
        end,
    }
    TCEquipmentClass = { getCategory = function() return nil end }
    TheContractorDrivers = { isVehicleDriven = function(vehicle) return vehicle.aiActive == true end }
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
    world:load("src/business/CourtesyVehicle.lua")

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
    tc.Jobs = { getAllJobs = function() return world.jobs end }
    tc.Cooldown = { isVehicleInCooldown = function(_, vehicleId) return world.cooldown[vehicleId] == true end }
    tc.Parking = {
        isPending = function(_, vehicleId) return world.pending[vehicleId] == true end,
        returnHiddenVehicles = function() end,
        removeVehicles = function(_, vehicleIds)
            for _, vehicleId in ipairs(vehicleIds) do
                if world.pending[vehicleId] then
                    world.pending[vehicleId] = nil
                    table.insert(world.removedFromParking, vehicleId)
                end
            end
        end,
    }
    tc.Drivers = { hasDriver = function(_, vehicle) return vehicle.hasStaffDriver == true end }
    tc.Logbook = { recordTheftRecovered = function() end }
    tc.Administrator = { isEmployed = function() return true end }
    tc.Finances = {}
    for _, name in ipairs({ "recordOverheads", "recordClaims", "recordInsurancePayout" }) do
        tc.Finances[name] = function(_, farmId, amount)
            world.stats[name] = (world.stats[name] or 0) + amount
        end
    end
    tc.Notices = {
        publish = function(_, farmId, text) table.insert(world.notices, text) end,
    }
    world.kinds = {}
    tc.Inbox = {
        registerMessageKind = function(_, kind, definition) world.kinds[kind] = definition end,
        postMessage = function(_, farmId, kind, titleKey, bodyKey, args, actions, payload)
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
                body = string.format(g_i18n:getText(bodyKey), unpack(rendered)) })
        end,
    }

    function world:build()
        tc.Overheads = tc.Overheads or TheContractorOverheads.new()
        tc.RandomEvents = TheContractorRandomEvents.new()
        tc.MachineryInsurance = TheContractorMachineryInsurance.new()
        tc.MachineryInsurance:register(tc.Overheads, tc.Inbox, tc.RandomEvents)
        tc.CourtesyVehicle = TheContractorCourtesyVehicle.new()
        tc.CourtesyVehicle:register(tc.RandomEvents, tc.Inbox)
        tc.Theft = TheContractorTheft.new()
        tc.Theft:register(tc.RandomEvents, tc.Inbox, tc.MachineryInsurance, tc.CourtesyVehicle)
    end
    world:build()

    -- def: { name, xml, configurations, value, farmId, propertyState }
    function world:addMachine(def)
        local vehicle = self:addVehicle({ name = def.name, farmId = def.farmId })
        vehicle.spec_drivable = {}
        vehicle.propertyState = def.propertyState or VehiclePropertyState.OWNED
        vehicle.uniqueId = "unique" .. vehicle.id
        vehicle.configFileName = def.xml
        vehicle.configurations = def.configurations or {}
        vehicle.value = def.value or 50000
        vehicle.implements = {}
        function vehicle:getFullName() return self.name end
        function vehicle:getUniqueId() return self.uniqueId end
        function vehicle:getSellPrice() return self.value end
        function vehicle:getIsControlled() return self.controlled == true end
        function vehicle:getAttachedImplements() return self.implements end
        function vehicle:getAttacherVehicle() return nil end
        function vehicle:delete() self.isDeleted = true end
        vehicle.getCanBeSold = Vehicle.getCanBeSold
        return vehicle
    end

    -- Runs the queued vehicle loads: each becomes a machine of its store item.
    function world:finishLoads()
        local loads = self.pendingLoads
        self.pendingLoads = {}
        for _, load in ipairs(loads) do
            local vehicle = self:addMachine({ name = load.data.storeItem.name, xml = load.data.storeItem.xmlFilename,
                farmId = load.data.farmId, propertyState = load.data.propertyState, value = 0 })
            load.callback(load.target, { vehicle }, VehicleLoadingState.OK, load.args)
        end
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

    function world:insure(levelKey)
        tc.Overheads:handleRequest(1, "machineryInsurance", TheContractorOverheads.REQUEST.ENABLE,
            TheContractorOverheads.BILLING.ANNUAL, levelKey)
    end

    function world:lastMessage()
        return self.messages[#self.messages]
    end

    -- A tractor stolen and not found on a farm insured at levelKey: past
    -- the police report, with any courtesy vehicle loaded. Returns the
    -- incident, the stolen tractor and the courtesy vehicle (or nil).
    function world:loseTractor(levelKey, stolenDef)
        if levelKey ~= nil then
            self:insure(levelKey)
        end
        local stolen = self:addMachine(stolenDef or { name = "Fendt 724", xml = "data/fendt724.xml", value = 100000 })
        tc.Theft.forcedOutcome = TheContractorTheft.OUTCOME.LOST
        local incident = tc.RandomEvents:triggerEvent(1, "theft")
        self:runPastStage(incident)
        self:finishLoads()
        local courtesyId = incident.data.courtesyVehicleId
        return incident, stolen, courtesyId ~= nil and NetworkUtil.getObject(courtesyId) or nil
    end

    return world, tc
end

-- A small tractor range: the stolen Fendt 724 is 240 hp.
local function addTractorRange(world)
    world:addStoreItem({ xml = "data/fendt724.xml", name = "Fendt 724", power = 240, price = 200000 })
    world:addStoreItem({ xml = "data/small.xml", name = "Small", power = 120, price = 80000 })
    world:addStoreItem({ xml = "data/below.xml", name = "Below", power = 230, price = 150000 })
    world:addStoreItem({ xml = "data/above.xml", name = "Above", power = 260, price = 220000 })
    world:addStoreItem({ xml = "data/big.xml", name = "Big", power = 400, price = 350000 })
end

local function candidate(name, power, price)
    return { storeItem = { xmlFilename = "data/" .. name .. ".xml" }, name = name, power = power, price = price or 0 }
end

test("picks the closest power at or above, a different model, ties by price then name", function()
    setup()
    local pick = TheContractorCourtesyVehicle.pickStoreItem
    local candidates = { candidate("stolen", 240), candidate("b", 230), candidate("c", 260), candidate("d", 400) }
    assertEquals(pick(candidates, 240, "data/stolen.xml").name, "c", "closest above, never the same model")
    table.insert(candidates, candidate("same", 240, 5))
    assertEquals(pick(candidates, 240, "data/stolen.xml").name, "same", "equal power counts as at or above")

    local ties = { candidate("zed", 260, 100), candidate("cheap", 260, 50), candidate("alpha", 260, 50) }
    assertEquals(pick(ties, 240, "x").name, "alpha", "cheapest, then by name")

    local below = { candidate("low", 100), candidate("near", 200), candidate("mid", 150) }
    assertEquals(pick(below, 240, "x").name, "near", "nothing above: the closest below")
    assertEquals(pick({ candidate("stolen", 240) }, 240, "DATA/STOLEN.XML"), nil, "only the same model: nothing")
end)

test("the stolen vehicle's power comes from its configured motor", function()
    setup()
    local configured = TheContractorCourtesyVehicle.getConfiguredPower
    local item = { specs = { power = 200 },
        configurations = { motor = { { power = 180 }, { power = 220, isDefault = true } } } }
    assertEquals(configured(item, { motor = 1 }), 180, "motor config")
    assertEquals(configured(item, {}), 200, "no configuration: the base spec")
    assertEquals(configured(item, TheContractorCourtesyVehicle.getDefaultConfigurations(item)), 220, "default motor")

    local withHp = { specs = { power = 200, powerConfig = { engine = { 150, 300 } } } }
    assertEquals(configured(withHp, { engine = 2 }), 300, "a config with its own hp")
    assertEquals(configured({ specs = {} }, {}), nil, "no power spec")
end)

test("falls back to the tractor categories, then to the same model", function()
    local world = setup()
    local telehandler = world:addStoreItem({ xml = "data/tele.xml", category = "TELELOADERVEHICLES", power = 140 })
    world:addStoreItem({ xml = "data/plough.xml", category = "TELELOADERVEHICLES" })
    world:addStoreItem({ xml = "data/hidden.xml", category = "TELELOADERVEHICLES", power = 150, showInStore = false })
    world:addStoreItem({ xml = "data/tractor.xml", category = "TRACTORSS", power = 145 })
    world:addStoreItem({ xml = "data/combine.xml", category = "HARVESTERS", power = 141 })

    local picked = TheContractorCourtesyVehicle.pickForStolen(telehandler, 140)
    assertEquals(picked.storeItem.xmlFilename, "data/tractor.xml", "a tractor, not the hidden item or a combine")

    world.storeItems = { telehandler }
    picked = TheContractorCourtesyVehicle.pickForStolen(telehandler, 140)
    assertEquals(picked.storeItem, telehandler, "nothing else: the same model")
end)

test("comprehensive cover lends one after the police report, parked, free to run and unsellable", function()
    local world, tc = setup()
    addTractorRange(world)
    local incident, stolen, courtesy = world:loseTractor("comprehensive",
        { name = "Fendt 724", xml = "data/fendt724.xml", value = 100000, configurations = {} })

    assertTrue(courtesy ~= nil, "lent")
    assertEquals(courtesy.name, "Above", "260 hp for a 240 hp tractor")
    assertEquals(courtesy.propertyState, VehiclePropertyState.MISSION, "a mission vehicle: no leasing or upkeep")
    assertEquals(courtesy:getOwnerFarmId(), 1, "the farm's to use")
    assertEquals(world.placed[1], courtesy.id, "in a parking slot")
    assertEquals(incident.data.courtesyUniqueId, courtesy.uniqueId, "kept by uniqueId for the save")
    assertEquals(incident.data.courtesyName, "Above", "name kept")
    assertTrue(tc.CourtesyVehicle:isCourtesy(courtesy.id), "a courtesy vehicle")
    assertTrue(not tc.CourtesyVehicle:isCourtesy(stolen.id), "the stolen one isn't")

    local lent = world:lastMessage()
    assertEquals(lent.titleKey, "tc_courtesy_lentTitle", "told")
    assertTrue(lent.body:find("Above in place of your stolen Fendt 724. It's at one of your parking slots", 1, true)
        ~= nil, "what and where: " .. lent.body)

    assertEquals(courtesy:getCanBeSold(), false, "can't be sold")
    assertTrue(stolen.isDeleted, "the stolen one's gone from the fleet at the police report")
    for _, entry in ipairs(tc.Theft:getEligibleVehicles(1)) do
        assertTrue(entry.vehicle ~= courtesy, "can't be stolen")
    end
    assertEquals(tc.MachineryInsurance:getFleetValue(1), 0, "not part of the insured fleet")
end)

test("no slot free: it stays at the shop and the message says so", function()
    local world = setup()
    addTractorRange(world)
    world.slotFree = false
    local _, _, courtesy = world:loseTractor("comprehensive")
    assertTrue(courtesy ~= nil, "lent")
    assertEquals(#world.placed, 0, "not moved")
    assertTrue(world:lastMessage().body:find("It's at the shop", 1, true) ~= nil, "at the shop")
end)

test("only comprehensive, only a vehicle with a power spec, only when it's not recovered", function()
    local world, tc = setup()
    addTractorRange(world)
    world:loseTractor("standard")
    assertEquals(#world.pendingLoads, 0, "standard: none")

    world, tc = setup()
    addTractorRange(world)
    world:loseTractor(nil)
    assertEquals(#world.pendingLoads, 0, "uninsured: none")

    world, tc = setup()
    world:addStoreItem({ xml = "data/quad.xml", name = "Quad", category = "ANIMALSVEHICLES" })
    addTractorRange(world)
    world:loseTractor("comprehensive", { name = "Quad", xml = "data/quad.xml" })
    assertEquals(#world.pendingLoads, 0, "no power spec: none")

    world, tc = setup()
    addTractorRange(world)
    world:insure("comprehensive")
    local tractor = world:addMachine({ name = "Fendt 724", xml = "data/fendt724.xml" })
    tractor.addDamageAmount = function() end
    tractor.addDirtAmount = function() end
    TCVehicleCondition = { capture = function() return {} end }
    tc.Theft.forcedOutcome = TheContractorTheft.OUTCOME.RECOVERED
    local incident = tc.RandomEvents:triggerEvent(1, "theft")
    world:runPastStage(incident)
    assertEquals(#world.pendingLoads, 0, "recovered: none")
end)

test("goes back at settlement at once if it's free", function()
    local world, tc = setup()
    addTractorRange(world)
    local incident, stolen, courtesy = world:loseTractor("comprehensive")
    assertEquals(incident.stage, "claimSettleFast", "waiting on the insurer")

    world:runPastStage(incident)
    assertEquals(tc.RandomEvents:getIncident(incident.id), nil, "over")
    assertTrue(stolen.isDeleted, "stolen one written off")
    assertTrue(courtesy.isDeleted, "courtesy collected")
    assertEquals(world.unhitched[#world.unhitched], courtesy.id, "anything hitched left behind")
    assertEquals(world:lastMessage().titleKey, "tc_courtesy_returnedTitle", "told")
    assertEquals(world.notices[#world.notices], "Courtesy Above collected by your insurer", "notice")
end)

test("busy at settlement: told, then collected the day it's free", function()
    local world, tc = setup()
    addTractorRange(world)
    local incident, _, courtesy = world:loseTractor("comprehensive")
    local job = { state = "in_progress", getAllEquipmentIds = function() return { courtesy.id } end }
    world.jobs = { job }

    world:runPastStage(incident)
    assertEquals(incident.stage, "courtesyRetry", "waiting for it")
    assertEquals(incident.nextStageDay, world:today() + 1, "tried again tomorrow")
    assertTrue(not courtesy.isDeleted, "kept while on a job")
    assertEquals(world:lastMessage().titleKey, "tc_courtesy_dueTitle", "told it's due back")
    local messageCount = #world.messages

    -- Off the job, but cooling down, then someone's sat in it.
    job.state = "completed"
    world.cooldown[courtesy.id] = true
    world:nextDay()
    assertTrue(not courtesy.isDeleted, "kept in a cooldown")
    world.cooldown[courtesy.id] = nil
    courtesy.controlled = true
    world:nextDay()
    assertTrue(not courtesy.isDeleted, "kept while driven")
    assertEquals(#world.messages, messageCount, "told only once")

    -- Free, but waiting to be parked: taken from the queue.
    courtesy.controlled = false
    world.pending[courtesy.id] = true
    world:nextDay()
    assertTrue(courtesy.isDeleted, "collected")
    assertEquals(world.removedFromParking[1], courtesy.id, "out of the parking queue")
    assertEquals(tc.RandomEvents:getIncident(incident.id), nil, "over")
    assertEquals(world:lastMessage().titleKey, "tc_courtesy_returnedTitle", "told")
end)

test("out on a job at settlement: flagged on the job, collected as its equipment comes home", function()
    local world, tc = setup()
    addTractorRange(world)
    local incident, _, courtesy = world:loseTractor("comprehensive")
    local job = { state = "in_progress", getAllEquipmentIds = function() return { 900, courtesy.id } end }
    world.jobs = { job }

    -- Not due before settlement: it's the farm's to use and park.
    assertEquals(tc.CourtesyVehicle:getDueOnJob(job), nil, "not due yet")
    job.state = "completed"
    local left = tc.CourtesyVehicle:collectDueVehicles({ courtesy.id })
    assertEquals(left[1], courtesy.id, "parked as normal before settlement")
    job.state = "in_progress"

    world:runPastStage(incident)
    assertEquals(incident.stage, "courtesyRetry", "waiting for it")
    assertEquals(tc.CourtesyVehicle:getDueOnJob(job), "Above", "flagged on the job")
    left = tc.CourtesyVehicle:collectDueVehicles({ 900, courtesy.id })
    assertEquals(#left, 2, "still on the job: kept")
    assertTrue(not courtesy.isDeleted, "kept")

    -- The job's over and its equipment comes home through the parking queue.
    job.state = "completed"
    left = tc.CourtesyVehicle:collectDueVehicles({ 900, courtesy.id })
    assertEquals(#left, 1, "only the rest is parked")
    assertEquals(left[1], 900, "the implement")
    assertTrue(courtesy.isDeleted, "collected there and then")
    assertEquals(tc.RandomEvents:getIncident(incident.id), nil, "over")
    assertEquals(world:lastMessage().titleKey, "tc_courtesy_returnedTitle", "told")
end)

test("the incident ending before it loads: it's deleted", function()
    local world, tc = setup()
    addTractorRange(world)
    world:insure("comprehensive")
    world:addMachine({ name = "Fendt 724", xml = "data/fendt724.xml" })
    tc.Theft.forcedOutcome = TheContractorTheft.OUTCOME.LOST
    local incident = tc.RandomEvents:triggerEvent(1, "theft")
    world:runPastStage(incident)
    assertEquals(#world.pendingLoads, 1, "loading")
    tc.RandomEvents:closeIncident(incident)
    world:finishLoads()
    local vehicle = world.objects[world.nextObjectId - 1]
    assertTrue(vehicle.isDeleted, "deleted")
end)

test("survives a save and load, and reaches a joining client", function()
    local world, tc = setup()
    addTractorRange(world)
    local incident, _, courtesy = world:loseTractor("comprehensive")

    -- A joining client knows it's a courtesy vehicle (it can't sell it).
    local stream = world:newStream()
    tc.RandomEvents:writeInitialClientState(stream)
    local client = TheContractorRandomEvents.new()
    client:readInitialClientState(stream)
    local clientCourtesy = TheContractorCourtesyVehicle.new()
    clientCourtesy:register(client, tc.Inbox)
    assertTrue(clientCourtesy:isCourtesy(courtesy.id), "client sees it")

    local xmlFile = {}
    tc.RandomEvents:saveToXmlFile(xmlFile)

    -- A new session: the courtesy vehicle loads under a new object id.
    world.objects[courtesy.id] = nil
    world:register(courtesy)
    world:build()
    tc.RandomEvents:loadFromXMLFile(xmlFile)
    tc.Theft:resolveSavedVehicles()
    tc.CourtesyVehicle:resolveSavedVehicles()
    local loaded = tc.RandomEvents:getIncident(incident.id)
    assertEquals(loaded.data.courtesyVehicleId, courtesy.id, "found again")
    assertTrue(tc.CourtesyVehicle:isCourtesy(courtesy.id), "still a courtesy vehicle")

    world:runPastStage(loaded)
    assertTrue(courtesy.isDeleted, "collected at settlement as normal")
end)

test("gone after a load: nothing happens at settlement", function()
    local world, tc = setup()
    addTractorRange(world)
    local incident, _, courtesy = world:loseTractor("comprehensive")
    local xmlFile = {}
    tc.RandomEvents:saveToXmlFile(xmlFile)

    courtesy.isDeleted = true
    world:build()
    tc.RandomEvents:loadFromXMLFile(xmlFile)
    tc.CourtesyVehicle:resolveSavedVehicles()
    local loaded = tc.RandomEvents:getIncident(incident.id)
    assertEquals(loaded.data.courtesyVehicleId, 0, "dropped")

    local messageCount = #world.messages
    world:runPastStage(loaded)
    assertEquals(tc.RandomEvents:getIncident(incident.id), nil, "over")
    assertEquals(world:lastMessage().titleKey, "tc_insurance_settledTitle", "only the settlement")
    assertEquals(#world.messages, messageCount + 1, "no courtesy message")
end)

test("the level picker and tcFinance insurance mention it", function()
    local world, tc = setup()
    assertTrue(TheContractorMachineryInsurance.getLevelDescription("comprehensive"):find("courtesy vehicle", 1, true)
        ~= nil, "comprehensive")
    assertTrue(TheContractorMachineryInsurance.getLevelDescription("standard"):find("courtesy", 1, true) == nil,
        "standard")

    addTractorRange(world)
    world:loseTractor("comprehensive")
    TCConsole.reset()
    TheContractorMachineryInsurance.registerConsoleCommands()
    local text = TCConsole.dispatch(TCConsole.groups.finance, { "insurance" })
    assertTrue(text:find("courtesy Above", 1, true) ~= nil, "open claim lists it: " .. text)
end)

test("a lent machine works the farm's fields like the one it replaces", function()
    local world = setup()
    addTractorRange(world)
    local _, _, courtesy = world:loseTractor("comprehensive")
    local mission = world:addMachine({ name = "Contract machine", propertyState = VehiclePropertyState.MISSION })

    local accessible = WorkArea.getIsAccessibleAtWorldPosition
    assertEquals(accessible(courtesy, 1, 0, 0, 1), true, "courtesy: judged as owned")
    assertEquals(courtesy.propertyState, VehiclePropertyState.MISSION, "still a mission vehicle after")
    assertEquals(accessible(mission, 1, 0, 0, 1), false, "any other mission vehicle: as vanilla")
end)
