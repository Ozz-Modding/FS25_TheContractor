-- Standing spot filters (120): a spot kept for some of the farm's staff.
-- Only they stand there; they take one of their own spots before any open
-- one (picking among their own day by day), and fall back to an open spot
-- when theirs are taken by others they're kept for. A filter naming only
-- staff who've left is open again. The filter saves and streams with the
-- spot, and the server only takes the farm's own spot and staff.

local world

local function setup()
    world = stubs.install()
    Event = { new = function(mt) return setmetatable({}, mt) end }
    InitEventClass = function() end
    dofile("src/business/Worker.lua")
    dofile("src/business/WorkingHours.lua")
    dofile("src/business/Office.lua")
    dofile("src/placeables/PlaceableTCParkingSlot.lua")
    dofile("src/placeables/PlaceableTCStandingSpot.lua")
    dofile("src/util/TCParkingSlotFilter.lua")
    dofile("src/placeables/PlaceableTCSeatSpot.lua")
    dofile("src/util/TCIdleStaff.lua")
    dofile("src/util/TCStandingSpotActivatable.lua")
    dofile("src/events/TCStandingSpotFilterEvent.lua")

    entityExists = function() return true end
    getWorldTranslation = function(node) return node.x, 0, node.z end
    localDirectionToWorld = function(node) return 0, 0, 1 end
    MathUtil = {
        getYRotationFromDirection = function(dx, dz) return math.atan2(dx, dz) end,
        vector2Length = function(x, z) return math.sqrt(x * x + z * z) end,
    }

    g_currentMission.environment = { currentMonotonicDay = 1, dayTime = 12 * 3600000 }
    g_currentMission.placeableSystem = { placeables = {} }
    local staff = { workersByFarm = {} }
    function staff:getRoster(farmId)
        local roster = {}
        for _, worker in pairs(self.workersByFarm[farmId] or {}) do
            table.insert(roster, worker)
        end
        return roster
    end
    g_currentMission.TheContractor.Staff = staff
    g_currentMission.TheContractor.Office = TheContractorOffice.new()
end

local function addSpot(farmId, x, staffIds)
    local spot = { farmId = farmId }
    spot[PlaceableTCStandingSpot.KEY] = {
        standNode = { x = x, z = 0 },
        filter = PlaceableTCStandingSpot.newFilter(staffIds),
    }
    function spot:getOwnerFarmId() return self.farmId end
    world:register(spot)
    table.insert(g_currentMission.placeableSystem.placeables, spot)
    return spot
end

local function addWorker(farmId, id, status)
    local workersByFarm = g_currentMission.TheContractor.Staff.workersByFarm
    workersByFarm[farmId] = workersByFarm[farmId] or {}
    local worker = { id = id, farmId = farmId, name = "Worker " .. id, status = status or TheContractorWorker.STATUS.IDLE }
    workersByFarm[farmId][id] = worker
    return worker
end

local function key(x)
    return TCIdleStaff.getSpotKey(x, 0)
end

local function set(...)
    local result = {}
    for _, id in ipairs({ ... }) do
        result[id] = true
    end
    return result
end

test("a kept spot only takes its own people, and stays empty without them", function()
    setup()
    local keys = { key(0), key(3) }
    for day = 1, 20 do
        local assignment = TCIdleStaff.assign(1, day, { 1, 2 }, keys, { [key(0)] = set(1) })
        assertEquals(assignment[1], key(0), "day " .. day .. ": worker 1 on their spot")
        assertEquals(assignment[2], key(3), "day " .. day .. ": worker 2 on the open one")
    end

    -- Worker 1's away: their spot stays empty, worker 3 has nowhere.
    local assignment = TCIdleStaff.assign(1, 1, { 2, 3 }, keys, { [key(0)] = set(1) })
    assertEquals(assignment[2] ~= nil and assignment[3] ~= nil, false, "only one of them stands")
    assertTrue(assignment[2] ~= key(0) and assignment[3] ~= key(0), "nobody else on worker 1's spot")
end)

test("a worker with several kept spots picks among them, never an open one", function()
    setup()
    local keys = { key(0), key(3), key(6), key(9) }
    local reservedFor = { [key(0)] = set(1), [key(3)] = set(1) }
    local seen = {}
    for day = 1, 30 do
        local spotKey = TCIdleStaff.assign(1, day, { 1, 2, 3 }, keys, reservedFor)[1]
        assertTrue(spotKey == key(0) or spotKey == key(3), "day " .. day .. ": on one of their own")
        seen[spotKey] = true
    end
    assertTrue(seen[key(0)] and seen[key(3)], "both of their spots get used")
end)

test("staff sharing a kept spot all fit when their other spots allow it", function()
    setup()
    -- Worker 1 is kept for both spots, worker 2 only the first: worker 1
    -- has to take the second whatever the day's scores.
    local keys = { key(0), key(3), key(6) }
    local reservedFor = { [key(0)] = set(1, 2), [key(3)] = set(1) }
    for day = 1, 30 do
        local assignment = TCIdleStaff.assign(1, day, { 1, 2, 3 }, keys, reservedFor)
        assertEquals(assignment[2], key(0), "day " .. day)
        assertEquals(assignment[1], key(3), "day " .. day)
        assertEquals(assignment[3], key(6), "day " .. day)
    end
end)

test("with their kept spots taken, a worker falls back to an open one", function()
    setup()
    local keys = { key(0), key(3) }
    local assignment = TCIdleStaff.assign(1, 1, { 1, 2 }, keys, { [key(0)] = set(1, 2) })
    local onKept = assignment[1] == key(0) and 1 or 2
    assertEquals(assignment[3 - onKept], key(3), "the other one's on the open spot")
end)

test("getWanted keeps spots for their staff, and opens one whose staff have all left", function()
    setup()
    addWorker(1, 1)
    addWorker(1, 2)
    local kept = addSpot(1, 0, { 1 })
    addSpot(1, 5)
    local wanted = TCIdleStaff.getWanted()
    assertEquals(wanted[1].spot.placeable, kept)
    assertTrue(wanted[1].spot.keptFor ~= nil, "marked as kept")
    assertTrue(wanted[2].spot.placeable ~= kept, "worker 2 elsewhere")

    -- Worker 1 out on a job: worker 2 still doesn't take it.
    g_currentMission.TheContractor.Staff.workersByFarm[1][1].status = TheContractorWorker.STATUS.ASSIGNED
    wanted = TCIdleStaff.getWanted()
    assertTrue(wanted[2].spot.placeable ~= kept, "kept while they're out")

    -- Worker 1 leaves the company, and their spot is anyone's.
    g_currentMission.TheContractor.Staff.workersByFarm[1][1] = nil
    addWorker(1, 3)
    wanted = TCIdleStaff.getWanted()
    assertTrue(wanted[2] ~= nil and wanted[3] ~= nil, "both stand")
    assertTrue(wanted[2].spot.placeable == kept or wanted[3].spot.placeable == kept, "the spot's in use")
end)

test("a spot can be kept for office staff", function()
    setup()
    addWorker(1, 1)
    local kept = addSpot(1, 0, { 7 })
    addSpot(1, 5)
    g_currentMission.TheContractor.Office.membersByFarm[1] = {
        administrator = { id = 7, role = "administrator", farmId = 1, name = "Ann", level = 1 },
    }
    local wanted = TCIdleStaff.getWanted()
    assertEquals(wanted[7].spot.placeable, kept)
    assertTrue(wanted[1].spot.placeable ~= kept, "the worker elsewhere")
end)

test("the event sets the farm's own spot, keeps only its staff, and broadcasts", function()
    setup()
    local broadcasts = {}
    g_server = { broadcastEvent = function(_, event) table.insert(broadcasts, event) end }
    addWorker(1, 1)
    addWorker(2, 2)
    local spot = addSpot(1, 0)
    local otherSpot = addSpot(2, 10)
    local request = PlaceableTCStandingSpot.newFilter({ 1, 2, 99 })

    TCStandingSpotFilterEvent.new(otherSpot.id, 1, request):run({})
    assertEquals(0, #broadcasts, "not farm 1's spot")
    assertEquals(0, #PlaceableTCStandingSpot.getFilter(otherSpot).staffIds)

    TCStandingSpotFilterEvent.new(spot.id, 1, request):run({})
    assertEquals(1, #broadcasts)
    assertEquals("1", table.concat(PlaceableTCStandingSpot.getFilter(spot).staffIds, ","),
        "another farm's worker and a stranger dropped")
    assertEquals("1", table.concat(broadcasts[1].filter.staffIds, ","), "the cleaned filter goes out")
end)

test("a filter streams and saves with the spot", function()
    setup()
    local spot = addSpot(1, 0, { 5, 2 })
    local stream = world:newStream()
    PlaceableTCStandingSpot.onWriteStream(spot, stream)
    local joined = addSpot(1, 0)
    PlaceableTCStandingSpot.onReadStream(joined, stream)
    assertEquals("2,5", table.concat(PlaceableTCStandingSpot.getFilter(joined).staffIds, ","))

    local values = {}
    local xmlFile = {
        setInt = function(_, path, value) values[path] = value end,
        getInt = function(_, path) return values[path] end,
    }
    PlaceableTCStandingSpot.saveToXMLFile(spot, xmlFile, "spot")
    local loaded = addSpot(1, 0)
    PlaceableTCStandingSpot.loadFromXMLFile(loaded, xmlFile, "spot")
    local filter = PlaceableTCStandingSpot.getFilter(loaded)
    assertEquals("2,5", table.concat(filter.staffIds, ","))
    assertTrue(filter.staffSet[5], "lookup set rebuilt")
end)
