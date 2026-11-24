-- A vehicle reloaded as a new object mid-session (TCVehicleReplace): vanilla's
-- reset and a configuration change give the copy a new object id. Everything
-- of ours holding the old id follows it to the new one, on the server and
-- then every client. The bug behind it: a harvest job's combine reset part
-- way through dropped off the job, so it was never emptied again.

-- A subsystem with just the state given, round the real class (its
-- remapVehicle is what's tested). Some keep their metatable local.
local function make(className, state)
    return setmetatable(state, _G[className .. "_mt"] or { __index = _G[className] })
end

local SUBSYSTEM_FILES = {
    "Job", "Jobs", "Cooldown", "Drivers", "Logbook", "Parking", "RandomEvents", "RepairContracts", "YardBales",
    "YardHaul", "EmergencyRefuel", "AuctionSite",
}

local world, sent, subscriptions

-- A VehicleSystem shaped like vanilla's: the uniqueId table, and a removal
-- that only clears the entry if it's still this vehicle.
local function installVehicleSystem()
    VehicleSystem = {}
    function VehicleSystem:getVehicleByUniqueId(uniqueId)
        return self.vehicleByUniqueId[uniqueId]
    end
    function VehicleSystem:addVehicle(vehicle)
        self.vehicleByUniqueId[vehicle.uniqueId] = vehicle
    end
    function VehicleSystem:removeVehicle(vehicle)
        if self.vehicleByUniqueId[vehicle.uniqueId] == vehicle then
            self.vehicleByUniqueId[vehicle.uniqueId] = nil
        end
    end
    g_currentMission.vehicleSystem = setmetatable({ vehicleByUniqueId = {}, vehicles = {} },
        { __index = VehicleSystem })
end

local function setup()
    world = stubs.install()
    TheContractor = { SaveKey = "TheContractor" }
    FinanceStats = { statNames = {}, statNameToIndex = {} }
    MoneyType = { LAST_ID = 0, register = function(name) return name end }
    FarmManager = { SPECTATOR_FARM_ID = 0 }
    MessageType = { VEHICLE_RESET = "vehicleReset" }
    subscriptions = {}
    g_messageCenter = {
        subscribe = function(_, messageType, callback, target)
            subscriptions[messageType] = { callback = callback, target = target }
        end,
        unsubscribeAll = function() subscriptions = {} end,
        publish = function(_, messageType, ...)
            local sub = subscriptions[messageType]
            if sub ~= nil then
                sub.callback(sub.target, ...)
            end
        end,
    }
    TCJobProgress = { POLL_INTERVAL_MS = 3000 }
    Environment = { tcHolidayHookInstalled = true }
    Event = { new = function(mt) return setmetatable({}, mt) end }
    InitEventClass = function() end
    Vehicle = { getIsMapHotspotVisible = function() return true end }
    CollisionFlag = { VEHICLE = 1, PLAYER = 2, DYNAMIC_OBJECT = 4, TREE = 8, STATIC_OBJECT = 16, BUILDING = 32 }
    GuiTopDownCursor = { getHitPlaceable = function() return nil end }
    sent = {}
    g_server = { broadcastEvent = function(_, event) table.insert(sent, event) end }

    installVehicleSystem()
    world:load("src/util/TCVehicleIds.lua")
    world:load("src/util/TCBallast.lua")
    world:load("src/util/TCEquipmentVisibility.lua")
    world:load("src/placeables/PlaceableTCParkingSlot.lua")
    world:load("src/util/TCParking.lua")
    -- What the auction site reaches for as it's loaded.
    world:load("src/business/FarmerFleet.lua")
    world:load("src/util/TCAuctionCrowd.lua")
    world:load("src/util/TCAuctionLayout.lua")
    for _, name in ipairs(SUBSYSTEM_FILES) do
        world:load("src/business/" .. name .. ".lua")
    end
    world:load("src/util/TCVehicleReplace.lua")
    world:load("src/events/TCVehicleReplacedEvent.lua")
    world:load("src/events/TCEquipmentVisibilityEvent.lua")
    g_currentMission.placeableSystem = { placeables = {} }
    TCEquipmentVisibility.hideVehicle = function(vehicle) vehicle.isHidden = true end
    TCEquipmentVisibility.revealVehicle = function(vehicle) vehicle.isHidden = false end
    TCVehicleReplace.install()
end

-- A vehicle in the fake system, as vanilla's loading leaves one: registered
-- (an object id) and in the uniqueId table.
local function spawn(uniqueId)
    local vehicle = world:addVehicle({ name = uniqueId })
    vehicle.uniqueId = uniqueId
    function vehicle:getUniqueId() return self.uniqueId end
    g_currentMission.vehicleSystem:addVehicle(vehicle)
    return vehicle
end

-- Vanilla's delete: out of the system, then unregistered.
local function delete(vehicle)
    g_currentMission.vehicleSystem:removeVehicle(vehicle)
    world.objects[vehicle.id] = nil
    vehicle.isDeleted = true
    vehicle.id = nil
end

-- Server state holding vehicle 1 (the combine) everywhere it can be held,
-- plus a header (2) that isn't reloaded.
local function setupHolders(combineId, headerId)
    local job = { id = 27, farmId = 1, jobType = "harvest" }
    job.assignedEquipmentIds = { combineId, headerId }
    job.haulageEquipmentIds = { combineId }
    job.washVehicleIds = { combineId }
    job.startCondition = { [combineId] = { damage = 0.1 } }
    job.workshop = { vehicleId = combineId, attachmentId = headerId }
    job.yardDelivery = { kitVehicleId = combineId, kitAttachmentId = headerId }
    job.yardHaul = { trailerVehicleId = combineId }
    job.refuel = { machineVehicleId = combineId, attachmentVehicleId = headerId }

    local tc = g_currentMission.TheContractor
    tc.Jobs = make("TheContractorJobs", { jobsByFarm = { [1] = { [27] = job } }, graceJobs = {} })
    tc.Cooldown = make("TheContractorCooldown", {
        entriesByFarm = { [1] = { [1] = { vehicleIds = { combineId, headerId } } } },
        vehicleIdsInCooldown = { [combineId] = true, [headerId] = true },
    })
    tc.Staff = { getWorker = function() return tc.worker end }
    tc.worker = { drivingVehicleId = combineId }
    tc.Drivers = make("TheContractorDrivers", {
        bindingsByVehicleId = { [combineId] = { vehicleId = combineId, farmId = 1, workerId = 3 } },
    })
    tc.Logbook = make("TheContractorLogbook", {
        vehicles = { [combineId] = { vehicleId = combineId, entries = { { kind = "job" } } } },
        jobEntriesByFarm = { [1] = { [27] = { equipment = { { vehicleId = combineId }, { vehicleId = headerId } } } } },
        pendingByJobId = { [27] = { start = { [combineId] = { damage = 0.1 } } } },
        driverSessions = { [combineId] = { farmId = 1 } },
        loadedDriverSessions = { [combineId] = { farmId = 1 } },
        playerSessions = { [combineId] = { farmId = 1 } },
    })
    tc.Parking = make("TheContractorParking", {
        queue = { { vehicleId = combineId, farmId = 1, batchId = 1 } },
        entryByVehicleId = {},
        parkAllByFarm = { [1] = { vehicleIds = { headerId, combineId } } },
    })
    tc.Parking.entryByVehicleId[combineId] = tc.Parking.queue[1]
    tc.RandomEvents = make("TheContractorRandomEvents", {
        incidents = {
            [1] = { data = { vehicleId = combineId, tractorId = headerId } },
            [2] = { data = { courtesyVehicleId = combineId } },
            [3] = { data = { amount = combineId } },
        },
    })
    tc.RepairContracts = make("TheContractorRepairContracts", { removals = { { vehicleId = combineId } } })
    tc.YardBales = make("TheContractorYardBales", {})
    tc.YardHaul = make("TheContractorYardHaul", {})
    tc.EmergencyRefuel = make("TheContractorEmergencyRefuel", {})
    local lot = { number = 1, vehicleId = combineId, attachmentId = headerId }
    tc.AuctionSite = make("TheContractorAuctionSite", {
        lots = { lot }, site = { lots = { lot } }, vehicleIdSet = { [combineId] = true, [headerId] = true },
    })

    local slot = { farmId = 1 }
    slot[PlaceableTCParkingSlot.KEY] = { filter = PlaceableTCParkingSlot.newFilter({ "TRACTORSL" }, { combineId }) }
    PlaceableTCParkingSlot.isSlot = function(placeable) return placeable[PlaceableTCParkingSlot.KEY] ~= nil end
    table.insert(g_currentMission.placeableSystem.placeables, slot)
    return job, slot
end

-- Detection --------------------------------------------------------------------

test("a configuration change (copy in first, old one removed) is followed", function()
    setup()
    local old = spawn("vehicleA")
    local oldId = old.id
    local replaced = {}
    TCVehicleReplace.replace = function(a, b) table.insert(replaced, { a, b }) end

    -- ChangeVehicleConfigEvent: the uniqueId's entry cleared, the copy loads,
    -- then the old one's deleted.
    g_currentMission.vehicleSystem.vehicleByUniqueId.vehicleA = nil
    local copy = spawn("vehicleA")
    delete(old)

    assertEquals(#replaced, 1, "replaced once")
    assertEquals(replaced[1][1], oldId, "old id")
    assertEquals(replaced[1][2], copy.id, "new id")
    assertEquals(#sent, 1, "clients told")
    assertEquals(sent[1].oldId, oldId, "event old id")
    assertEquals(sent[1].newId, copy.id, "event new id")
end)

test("a reset (VEHICLE_RESET, then the old one removed) is followed once", function()
    setup()
    local old = spawn("vehicleA")
    local oldId = old.id
    local replaced = {}
    TCVehicleReplace.replace = function(a, b) table.insert(replaced, { a, b }) end

    g_currentMission.vehicleSystem.vehicleByUniqueId.vehicleA = nil
    local copy = spawn("vehicleA")
    g_messageCenter:publish(MessageType.VEHICLE_RESET, old, copy)
    delete(old)

    assertEquals(#replaced, 1, "replaced once")
    assertEquals(replaced[1][1], oldId, "old id")
    assertEquals(replaced[1][2], copy.id, "new id")
    assertEquals(#sent, 1, "one event")
end)

test("a reset that deletes the old one before its copy loads is followed", function()
    setup()
    local old = spawn("vehicleA")
    local oldId = old.id
    local replaced = {}
    TCVehicleReplace.replace = function(a, b) table.insert(replaced, { a, b }) end

    delete(old)
    assertEquals(#replaced, 0, "nothing to follow yet")
    local copy = spawn("vehicleA")
    g_messageCenter:publish(MessageType.VEHICLE_RESET, old, copy)

    assertEquals(#replaced, 1, "replaced on the reset")
    assertEquals(replaced[1][1], oldId, "old id kept from the removal")
    assertEquals(replaced[1][2], copy.id, "new id")
end)

test("a vehicle sold or deleted with no copy changes nothing", function()
    setup()
    local old = spawn("vehicleA")
    spawn("vehicleB")
    local replaced = {}
    TCVehicleReplace.replace = function(a, b) table.insert(replaced, { a, b }) end

    delete(old)

    assertEquals(#replaced, 0, "nothing replaced")
    assertEquals(#sent, 0, "nothing sent")
end)

test("a client swaps the ids when the server tells it", function()
    setup()
    local replaced = {}
    TCVehicleReplace.replace = function(a, b) table.insert(replaced, { a, b }) end

    TCVehicleReplacedEvent.new(5, 9):run({ getIsServer = function() return true end })

    assertEquals(#replaced, 1, "replaced")
    assertEquals(replaced[1][1], 5, "old id")
    assertEquals(replaced[1][2], 9, "new id")
end)

-- What follows -------------------------------------------------------------------

test("every subsystem in the list can follow a vehicle", function()
    setup()
    setupHolders(1, 2)
    local tc = g_currentMission.TheContractor
    for _, key in ipairs(TCVehicleReplace.SUBSYSTEMS) do
        assertTrue(tc[key] ~= nil and tc[key].remapVehicle ~= nil, key .. " has remapVehicle")
    end
end)

test("the reset combine stays on its harvest job, and everything else holding it follows", function()
    setup()
    local job, slot = setupHolders(1, 2)
    local tc = g_currentMission.TheContractor

    TCVehicleReplace.replace(1, 50)

    assertEquals(job.assignedEquipmentIds[1], 50, "job equipment")
    assertEquals(job.assignedEquipmentIds[2], 2, "header untouched")
    assertEquals(job.haulageEquipmentIds[1], 50, "haulage equipment")
    assertEquals(job.washVehicleIds[1], 50, "wash list")
    assertTrue(job.startCondition[50] ~= nil and job.startCondition[1] == nil, "start condition")
    assertEquals(job.workshop.vehicleId, 50, "workshop machine")
    assertEquals(job.workshop.attachmentId, 2, "workshop attachment untouched")
    assertEquals(job.yardDelivery.kitVehicleId, 50, "yard kit")
    assertEquals(job.yardHaul.trailerVehicleId, 50, "yard trailer")
    assertEquals(job.refuel.machineVehicleId, 50, "refuel machine")

    assertEquals(tc.Cooldown.entriesByFarm[1][1].vehicleIds[1], 50, "cooldown entry")
    assertTrue(tc.Cooldown.vehicleIdsInCooldown[50] and tc.Cooldown.vehicleIdsInCooldown[1] == nil, "cooldown set")

    assertTrue(tc.Drivers.bindingsByVehicleId[50] ~= nil and tc.Drivers.bindingsByVehicleId[1] == nil, "binding")
    assertEquals(tc.Drivers.bindingsByVehicleId[50].vehicleId, 50, "binding's vehicle")
    assertEquals(tc.worker.drivingVehicleId, 50, "worker's vehicle")

    assertEquals(tc.Logbook.vehicles[50].vehicleId, 50, "logbook record")
    assertEquals(tc.Logbook.vehicles[1], nil, "old record gone")
    assertEquals(tc.Logbook.jobEntriesByFarm[1][27].equipment[1].vehicleId, 50, "job entry machine")
    assertEquals(tc.Logbook.jobEntriesByFarm[1][27].equipment[2].vehicleId, 2, "other machine untouched")
    assertTrue(tc.Logbook.pendingByJobId[27].start[50] ~= nil, "pending start")
    assertTrue(tc.Logbook.driverSessions[50] ~= nil, "driver session")
    assertTrue(tc.Logbook.loadedDriverSessions[50] ~= nil, "loaded driver session")
    assertTrue(tc.Logbook.playerSessions[50] ~= nil, "player session")

    assertEquals(tc.Parking.queue[1].vehicleId, 50, "parking queue")
    assertTrue(tc.Parking.entryByVehicleId[50] == tc.Parking.queue[1], "parking lookup")
    assertEquals(tc.Parking.parkAllByFarm[1].vehicleIds[2], 50, "park all run")
    local filter = slot[PlaceableTCParkingSlot.KEY].filter
    assertTrue(filter.vehicleSet[50] and filter.vehicleSet[1] == nil, "slot filter")
    assertEquals(filter.categories[1], "TRACTORSL", "slot filter categories kept")

    assertEquals(tc.RandomEvents.incidents[1].data.vehicleId, 50, "incident vehicle")
    assertEquals(tc.RandomEvents.incidents[1].data.tractorId, 2, "incident tractor untouched")
    assertEquals(tc.RandomEvents.incidents[2].data.courtesyVehicleId, 50, "courtesy vehicle")
    assertEquals(tc.RandomEvents.incidents[3].data.amount, 1, "a number that isn't a vehicle untouched")

    assertEquals(tc.RepairContracts.removals[1].vehicleId, 50, "collection queue")
    assertEquals(tc.AuctionSite.lots[1].vehicleId, 50, "auction lot")
    assertTrue(tc.AuctionSite.vehicleIdSet[50] and tc.AuctionSite.vehicleIdSet[1] == nil, "lot lock set")
end)

test("a hidden machine's copy is hidden again everywhere", function()
    setup()
    setupHolders(1, 2)
    local old = spawn("vehicleA")
    TCEquipmentVisibility.hideVehicles({ old.id })
    local copy = spawn("vehicleA")
    sent = {}

    TCVehicleReplace.replace(old.id, copy.id)

    assertTrue(TCEquipmentVisibility.isHidden(copy.id), "copy hidden")
    assertTrue(not TCEquipmentVisibility.isHidden(old.id), "old id forgotten")
    assertTrue(copy.isHidden, "copy hidden here")
    assertEquals(#sent, 1, "clients told to hide it")
    assertEquals(sent[1].isVisible, false, "as hidden")
end)
