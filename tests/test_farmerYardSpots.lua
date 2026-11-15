-- 154: standing spots and seats in a farmer's yard. A spot on a farmland
-- no player owns is that yard's farmer's: our staff, the filter prompt and
-- the filter event leave it alone; the farmer picks only between a yard's
-- placed spots when it has any (the same on every machine, one farmer a
-- spot, sitting on a seat, facing the arrow); placing one there is for the
-- host or an admin on a yard; and a player buying the land removes them.

local world

local function setup()
    world = stubs.install()
    TheContractor = { SaveKey = "TheContractor" }
    Event = { new = function(mt) return setmetatable({}, mt) end }
    InitEventClass = function() end
    dofile("src/business/Worker.lua")
    dofile("src/business/WorkingHours.lua")
    dofile("src/business/Office.lua")
    dofile("src/business/Yards.lua")
    dofile("src/placeables/PlaceableTCParkingSlot.lua")
    dofile("src/placeables/PlaceableTCStandingSpot.lua")
    dofile("src/placeables/PlaceableTCSeatSpot.lua")
    dofile("src/util/TCParkingSlotFilter.lua")
    dofile("src/util/TCSeatTypes.lua")
    dofile("src/util/TCIdleStaff.lua")
    dofile("src/util/TCShelter.lua")
    dofile("src/util/TCFarmerYardSpots.lua")
    dofile("src/util/TCYardFarmers.lua")
    dofile("src/util/TCStandingSpotActivatable.lua")
    dofile("src/events/TCStandingSpotFilterEvent.lua")
    PlaceablePropertyState = { CONSTRUCTION_PREVIEW = 4, OWNED = 1 }

    -- Nodes are plain tables holding their position.
    entityExists = function() return true end
    getWorldTranslation = function(node) return node.x, 0, node.z end
    localDirectionToWorld = function(node) return node.dirX or 0, 0, node.dirZ or 1 end
    world.physics = {}
    addToPhysics = function(node) world.physics[node] = true end
    removeFromPhysics = function(node) world.physics[node] = false end
    g_terrainNode = 1
    getTerrainHeightAtWorldPos = function() return 0 end
    MathUtil = {
        getYRotationFromDirection = function(dx, dz) return math.atan2(dx, dz) end,
        vector2Length = function(x, z) return math.sqrt(x * x + z * z) end,
        vector3Length = function(x, y, z) return math.sqrt(x * x + y * y + z * z) end,
    }

    -- Farmlands 1-9, each 100 m wide along x; farmland 3 is farm 1's.
    world.owners = { [3] = 1 }
    g_farmlandManager = {
        getIsValidFarmlandId = function(_, farmlandId)
            return farmlandId ~= nil and farmlandId >= 1 and farmlandId <= 9
        end,
        getFarmlandOwner = function(_, farmlandId)
            return world.owners[farmlandId] or 0
        end,
        getFarmlandIdAtWorldPosition = function(_, x, z)
            return math.floor(x / 100)
        end,
        getFarmlandById = function(_, farmlandId)
            return { id = farmlandId, xWorldPos = farmlandId * 100 + 50, zWorldPos = 0 }
        end,
    }

    g_currentMission.environment = { currentMonotonicDay = 10, dayTime = 12 * 3600000 }
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
    world.farmers = {}
    g_currentMission.TheContractor.Farmers = {
        getFarmers = function()
            return world.farmers
        end,
    }
    world.yards = TheContractorYards.new()
    g_currentMission.TheContractor.Yards = world.yards
end

-- A standing spot owned by farmId at x (its farmland is x / 100), its
-- arrow pointing dirX, dirZ.
local function addSpot(farmId, x, def)
    def = def or {}
    local spot = { farmId = farmId, propertyState = def.propertyState or PlaceablePropertyState.OWNED }
    spot[PlaceableTCStandingSpot.KEY] = {
        standNode = { x = x, z = 0, dirX = def.dirX, dirZ = def.dirZ },
        blockerNode = { name = "blocker" .. x },
        isBlockerActive = false,
        filter = PlaceableTCStandingSpot.newFilter(def.staffIds),
    }
    function spot:getOwnerFarmId() return self.farmId end
    function spot:getFarmlandId() return math.floor(x / 100) end
    function spot:onSell() self.sold = true end
    function spot:delete() self.markedForDeletion = true end
    world:register(spot)
    table.insert(g_currentMission.placeableSystem.placeables, spot)
    return spot
end

local function addSeat(farmId, x, def)
    local seat = addSpot(farmId, x, def)
    seat[PlaceableTCStandingSpot.KEY].keepBlocker = true
    seat[PlaceableTCSeatSpot.KEY] = { typeKey = "woodenChair", seatType = TCSeatTypes.get("woodenChair"),
        node = { name = "seat" .. x }, model = { name = "chair" .. x } }
    return seat
end

local function addWorker(farmId, id)
    local workersByFarm = g_currentMission.TheContractor.Staff.workersByFarm
    workersByFarm[farmId] = workersByFarm[farmId] or {}
    local worker = { id = id, farmId = farmId, name = "Worker " .. id, status = TheContractorWorker.STATUS.IDLE }
    workersByFarm[farmId][id] = worker
    return worker
end

local function addFarmer(id, yardFarmlandId)
    local person = { id = id, name = "Farmer " .. id, yardFarmlandId = yardFarmlandId, farmlandIds = {} }
    table.insert(world.farmers, person)
    return person
end

-- A yard's generated spots: count of them in a row from x.
local function generated(count, x)
    local entry = { x = x, z = 0, spots = {} }
    for i = 1, count do
        table.insert(entry.spots, { x = x + i * 4, z = 0 })
    end
    return entry
end

local function setHour(hour)
    g_currentMission.environment.dayTime = hour * 3600000
end

test("a spot on land no player owns is a farmer's yard spot; on a farm's own land it isn't", function()
    setup()
    local own = addSpot(1, 350)
    local yard = addSpot(1, 550)
    local nowhere = addSpot(1, 50)
    assertEquals(nil, TCFarmerYardSpots.getYardFarmlandId(own))
    assertEquals(5, TCFarmerYardSpots.getYardFarmlandId(yard))
    assertEquals(nil, TCFarmerYardSpots.getYardFarmlandId(nowhere), "farmland 0 isn't a farmland")
    -- A test fake without a farmland (or anything without one) is never a yard's.
    own.getFarmlandId = nil
    assertTrue(not TCFarmerYardSpots.isYardSpot(own))
end)

test("our staff never stand on a farmer's yard spot, and get no prompt or filter for one", function()
    setup()
    local own = addSpot(1, 350)
    local yard = addSpot(1, 550)
    addWorker(1, 7)
    addWorker(1, 8)

    local wanted = TCIdleStaff.getWanted()
    local placed = 0
    for _, entry in pairs(wanted) do
        assertTrue(entry.spot.placeable == own, "only the farm's own spot")
        placed = placed + 1
    end
    assertEquals(1, placed)

    assertEquals(nil, TCStandingSpotActivatable.getOwnSpotNear(550, 0))
    assertTrue(TCStandingSpotActivatable.getOwnSpotNear(350, 0) == own)

    -- The server ignores a filter sent for one.
    TCStandingSpotFilterEvent.new(yard.id, 1, PlaceableTCStandingSpot.newFilter({ 7 })):run({})
    assertEquals(0, #PlaceableTCStandingSpot.getFilter(yard).staffIds)
end)

test("a yard with placed spots: the farmer only uses those, a seat, facing its arrow", function()
    setup()
    world.yards:applySpots(5, generated(8, 500))
    addFarmer(2, 5)
    local seat = addSeat(1, 560, { dirX = 1, dirZ = 0 })

    local entry = TCYardFarmers.getWanted()[2]
    assertTrue(entry.spot.placeable == seat)
    assertTrue(entry.spot.seat ~= nil, "sits")
    assertNear(math.pi / 2, entry.spot.yaw, 0.0001)

    -- Through the whole day, never a generated spot.
    for hour = 7, 18 do
        setHour(hour)
        assertTrue(TCYardFarmers.getWanted()[2].spot.placeable == seat)
    end
end)

test("the farmer picks between a yard's placed spots by slot, every one used, the same on every machine", function()
    setup()
    world.yards:applySpots(5, generated(8, 500))
    addFarmer(2, 5)
    local spots = { addSpot(1, 520), addSpot(1, 540), addSpot(1, 560) }
    -- Another yard's spot and the construction cursor's preview never count.
    addSpot(1, 620)
    addSpot(1, 580, { propertyState = PlaceablePropertyState.CONSTRUCTION_PREVIEW })

    local used = {}
    for day = 1, 20 do
        g_currentMission.environment.currentMonotonicDay = day
        for hour = 7, 18, 3 do
            setHour(hour)
            local first = TCYardFarmers.getWanted()[2].spot
            assertEquals(first.key, TCYardFarmers.getWanted()[2].spot.key, "the same answer every time")
            used[first.placeable] = true
        end
    end
    for _, spot in ipairs(spots) do
        assertTrue(used[spot], "every placed spot gets used")
    end
    local count = 0
    for _ in pairs(used) do
        count = count + 1
    end
    assertEquals(3, count)

    -- One removed (being deleted) is out of the running at once.
    spots[1].markedForDeletion = true
    assertEquals(2, #TCYardFarmers.getPlacedSpots(5))
end)

test("a yard with only placed spots has its farmer about; with none it still needs generated ones", function()
    setup()
    addFarmer(2, 5)
    assertEquals(nil, TCYardFarmers.getWanted()[2])
    addSpot(1, 520)
    assertTrue(TCYardFarmers.getWanted()[2] ~= nil)
end)

test("two farmers sharing a yard never take the same placed spot", function()
    setup()
    addFarmer(2, 5)
    addFarmer(3, 5)
    addFarmer(4, 5)
    addSpot(1, 520)
    addSpot(1, 540)

    for day = 1, 15 do
        g_currentMission.environment.currentMonotonicDay = day
        local wanted = TCYardFarmers.getWanted()
        local onSpot, keys = 0, {}
        for _, id in ipairs({ 2, 3, 4 }) do
            if wanted[id] ~= nil then
                assertTrue(not keys[wanted[id].spot.key], "a spot someone's on is taken")
                keys[wanted[id].spot.key] = true
                onSpot = onSpot + 1
            end
        end
        assertEquals(2, onSpot, "two spots, two farmers on them")
    end
end)

test("a farmer on a placed standing spot blocks it, and comes off at once when it goes", function()
    setup()
    addFarmer(2, 5)
    local spot = addSpot(1, 520)
    TCIdleStaff.isSeen = function() return false end
    TCIdleStaff.updateModel = function() end

    local entry = TCYardFarmers.getWanted()[2]
    TCYardFarmers.updatePerson(2, entry, 16, {}, 0, 0, 0)
    assertTrue(TCYardFarmers.figures[2] ~= nil)
    assertEquals(true, world.physics[spot[PlaceableTCStandingSpot.KEY].blockerNode])

    -- Even in plain view, a spot that's been removed takes them off.
    TCIdleStaff.isSeen = function() return true end
    spot.markedForDeletion = true
    TCYardFarmers.updatePerson(2, entry, 16, {}, 0, 0, 0)
    assertEquals(nil, TCYardFarmers.figures[2])
end)

test("a farmer leaving a placed spot frees its blocker; another farmer waits until they've gone", function()
    setup()
    local spot = addSpot(1, 520)
    TCIdleStaff.isSeen = function() return false end
    TCIdleStaff.updateModel = function() end
    local entry = { person = addFarmer(2, 5), spot = TCYardFarmers.getPlacedSpots(5)[1] }

    TCYardFarmers.updatePerson(2, entry, 16, {}, 0, 0, 0)
    local other = { person = addFarmer(3, 5), spot = entry.spot }
    TCYardFarmers.updatePerson(3, other, 16, {}, 0, 0, 0)
    assertEquals(nil, TCYardFarmers.figures[3], "the spot's taken")

    TCYardFarmers.updatePerson(2, nil, 16, {}, 0, 0, 0)
    assertEquals(false, world.physics[spot[PlaceableTCStandingSpot.KEY].blockerNode])
    TCYardFarmers.updatePerson(3, other, 16, {}, 0, 0, 0)
    assertTrue(TCYardFarmers.figures[3] ~= nil)
end)

test("placing one on land no player owns: the host or an admin, on a yard; a farm's own land is vanilla's", function()
    setup()
    local E = TCFarmerYardSpots.PLACEMENT_ERROR
    assertEquals(nil, TCFarmerYardSpots.getPlacementError(true, true))
    assertEquals(E.NO_PERMISSION, TCFarmerYardSpots.getPlacementError(false, true))
    assertEquals(E.NOT_A_YARD, TCFarmerYardSpots.getPlacementError(true, false))
    assertEquals(E.NO_PERMISSION, TCFarmerYardSpots.getPlacementError(false, false), "permission first")

    world.canChange = true
    TheContractorSettings = { getCanLocalPlayerChange = function() return world.canChange end }
    world.yards:applyOverride(8, TheContractorYards.MODE.ON)
    local preview = addSpot(1, 850, { propertyState = PlaceablePropertyState.CONSTRUCTION_PREVIEW })
    local superAnswer = true
    local function superPlace() return true, nil end
    local function superOwned() return superAnswer end
    local function canPlace(x)
        return PlaceableTCStandingSpot.getCanBePlacedAt(preview, superPlace, x, 0, 0, 1)
    end
    local function onOwned(x)
        return PlaceableTCStandingSpot.getIsOnOwnedFarmland(preview, superOwned, x, 0, 0, 0)
    end

    g_time = 0
    assertTrue(canPlace(850))
    assertTrue(onOwned(850), "a yard needn't be the player's land")
    assertEquals(false, canPlace(550), "farmland 5 isn't a yard")
    assertEquals(E.NOT_A_YARD, preview[PlaceableTCStandingSpot.KEY].yardCheck.error)
    assertEquals(false, onOwned(550))

    -- The farm's own land: vanilla says.
    assertTrue(canPlace(350))
    assertTrue(onOwned(350))
    superAnswer = false
    assertEquals(false, onOwned(350))

    -- Not an admin: refused on a yard, a new farmland checked at once.
    world.canChange = false
    assertEquals(false, canPlace(850))
    assertEquals(E.NO_PERMISSION, preview[PlaceableTCStandingSpot.KEY].yardCheck.error)
    -- The same farmland keeps its verdict until it's stale.
    world.canChange = true
    g_time = 100
    assertEquals(false, canPlace(860))
    g_time = 100 + TCFarmerYardSpots.CHECK_CACHE_MS + 1
    assertTrue(canPlace(860))
end)

test("a player buying the land removes its yard spots and seats, and nothing else", function()
    setup()
    local onFive = { addSpot(1, 520), addSeat(2, 540) }
    local onSix = addSpot(1, 620)
    local own = addSpot(1, 350)

    -- A savegame's land loading, and land going back to nobody, leave them.
    TCFarmerYardSpots:onFarmlandOwnerChanged(5, 1, true)
    TCFarmerYardSpots:onFarmlandOwnerChanged(5, FarmlandManager.NO_OWNER_FARM_ID, false)
    assertTrue(not onFive[1].markedForDeletion)

    world.owners[5] = 2
    TCFarmerYardSpots:onFarmlandOwnerChanged(5, 2, false)
    for _, spot in ipairs(onFive) do
        assertTrue(spot.sold, "sold")
        assertTrue(spot.markedForDeletion, "deleted")
    end
    assertTrue(not onSix.markedForDeletion)
    assertTrue(not own.markedForDeletion)
end)
