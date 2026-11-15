-- Seat spots (153): a standing spot with a chair, whose sitter is posed on
-- it. Every chair option names a seat type with a model and all four limb
-- targets; the chosen option picks the type; seats share the standing
-- spots' assignment (and 120's filter); a seat's blocker stays put; whoever
-- is on a seat is loaded sitting rather than stood.

local world

local function setup()
    world = stubs.install()
    dofile("src/business/Worker.lua")
    dofile("src/business/WorkingHours.lua")
    dofile("src/placeables/PlaceableTCParkingSlot.lua")
    dofile("src/placeables/PlaceableTCStandingSpot.lua")
    dofile("src/placeables/PlaceableTCSeatSpot.lua")
    dofile("src/util/TCSeatTypes.lua")
    dofile("src/util/TCIdleStaff.lua")

    -- Nodes are plain tables holding their position.
    entityExists = function() return true end
    getWorldTranslation = function(node) return node.x, 0, node.z end
    localDirectionToWorld = function(node) return 0, 0, 1 end
    world.physics = {}
    addToPhysics = function(node) world.physics[node] = true end
    removeFromPhysics = function(node) world.physics[node] = false end
    MathUtil = {
        getYRotationFromDirection = function(dx, dz) return math.atan2(dx, dz) end,
        vector2Length = function(x, z) return math.sqrt(x * x + z * z) end,
        vector3Length = function(x, y, z) return math.sqrt(x * x + y * y + z * z) end,
    }

    g_currentMission.environment = { currentMonotonicDay = 1, dayTime = 12 * 3600000 }
    g_currentMission.placeableSystem = { placeables = {} }
    g_currentMission.TheContractor.Staff = { workersByFarm = {} }
end

local function addSpot(farmId, x, staffIds)
    local spot = { farmId = farmId }
    spot[PlaceableTCStandingSpot.KEY] = {
        standNode = { x = x, z = 0 },
        blockerNode = { name = "blocker" },
        isBlockerActive = true,
        filter = PlaceableTCStandingSpot.newFilter(staffIds),
    }
    function spot:getOwnerFarmId() return self.farmId end
    table.insert(g_currentMission.placeableSystem.placeables, spot)
    return spot
end

-- A seat spot: a standing spot with a chair of typeKey, its model loaded.
local function addSeat(farmId, x, typeKey, staffIds)
    local seat = addSpot(farmId, x, staffIds)
    seat[PlaceableTCStandingSpot.KEY].keepBlocker = true
    seat[PlaceableTCSeatSpot.KEY] = { typeKey = typeKey, seatType = TCSeatTypes.get(typeKey),
        node = { name = "seat" .. x }, model = { name = "chair" .. x } }
    seat.storeItem = { configurations = { [PlaceableTCSeatSpot.CONFIG] = { { saveId = typeKey } } } }
    seat.configurations = { [PlaceableTCSeatSpot.CONFIG] = 1 }
    return seat
end

local function addWorker(farmId, id)
    local workersByFarm = g_currentMission.TheContractor.Staff.workersByFarm
    workersByFarm[farmId] = workersByFarm[farmId] or {}
    local worker = { id = id, farmId = farmId, name = "Worker " .. id, status = TheContractorWorker.STATUS.IDLE }
    workersByFarm[farmId][id] = worker
    return worker
end

-- The seat spot xml's chair options: { name, saveId } in order.
local function readOptions()
    local file = io.open("xml/seatSpot.xml", "r")
    local content = file:read("*a")
    file:close()
    local options = {}
    for attributes in content:gmatch("<tcSeatTypeConfiguration%s([^>]*)/>") do
        table.insert(options, { name = attributes:match('name="([^"]*)"'), saveId = attributes:match('saveId="([^"]*)"') })
    end
    return options, content:match('<tcSeatTypeConfigurations title="([^"]*)"')
end

local function assertTriple(values, what)
    assertTrue(type(values) == "table" and #values == 3, what .. " has three numbers")
    for _, value in ipairs(values) do
        assertEquals(type(value), "number", what)
    end
end

local function assertPart(part, what)
    assertTrue(part ~= nil, what .. " is given")
    assertTriple(part.pos, what .. " position")
    assertTriple(part.rot, what .. " rotation")
end

test("every chair option names a seat type with a base-game model and all four limb targets", function()
    setup()
    local options, title = readOptions()
    assertEquals(#options, 3, "the three chairs")
    assertTrue(world.texts[title:gsub("^%$l10n_", "")] ~= nil, "the option's title has its text")
    for _, option in ipairs(options) do
        local seatType = TCSeatTypes.get(option.saveId)
        assertTrue(seatType ~= nil, "a type for " .. tostring(option.saveId))
        assertTrue(world.texts[option.name:gsub("^%$l10n_", "")] ~= nil, option.saveId .. "'s name has its text")
        assertEquals(seatType.filename:sub(1, 6), "$data/", option.saveId .. " is loaded from the base game")
        assertPart(seatType.model, option.saveId .. " model")
        assertPart(seatType.seat, option.saveId .. " seat")
        assertPart(seatType.skin, option.saveId .. " skin")
        for _, chain in ipairs(TCSeatTypes.CHAINS) do
            assertPart(seatType.targets[chain], option.saveId .. " " .. chain)
        end
    end
end)

test("the chair is the chosen option's, or the first when none was chosen", function()
    setup()
    local seat = addSeat(1, 0, "woodenChair")
    seat.storeItem.configurations[PlaceableTCSeatSpot.CONFIG] = {
        { saveId = "woodenChair" }, { saveId = "rockingChair" }, { saveId = "lobbyArmchair" } }
    seat.configurations[PlaceableTCSeatSpot.CONFIG] = 3
    assertEquals(PlaceableTCSeatSpot.getTypeKey(seat), "lobbyArmchair")
    seat.configurations = {}
    assertEquals(PlaceableTCSeatSpot.getTypeKey(seat), "woodenChair")
end)

test("seats and standing spots share one assignment, and a sitter's spot carries its seat", function()
    setup()
    addSpot(1, 0)
    addSeat(1, 3, "rockingChair")
    addWorker(1, 1)
    addWorker(1, 2)

    local wanted = TCIdleStaff.getWanted()
    assertTrue(wanted[1] ~= nil and wanted[2] ~= nil, "both placed")
    assertTrue(wanted[1].spot.key ~= wanted[2].spot.key, "on different spots")
    local seated = 0
    for _, entry in pairs(wanted) do
        if entry.spot.seat ~= nil then
            seated = seated + 1
            assertEquals(entry.spot.seat.typeKey, "rockingChair")
            assertTrue(entry.spot.seat.type == TCSeatTypes.TYPES.rockingChair, "the type's own entry")
        end
    end
    assertEquals(seated, 1, "one of them sits")
end)

test("a seat kept for a worker seats only them", function()
    setup()
    addSpot(1, 0)
    addSeat(1, 3, "lobbyArmchair", { 2 })
    addWorker(1, 1)
    addWorker(1, 2)

    local wanted = TCIdleStaff.getWanted()
    assertTrue(wanted[2].spot.seat ~= nil, "the named worker sits")
    assertEquals(wanted[1].spot.seat, nil, "the other stands")
end)

test("a seat's blocker stays in physics with nobody on it; a standing spot's comes out", function()
    setup()
    local spot = addSpot(1, 0)
    local seat = addSeat(1, 3, "woodenChair")
    PlaceableTCStandingSpot.setBlockerActive(spot, false)
    PlaceableTCStandingSpot.setBlockerActive(seat, false)
    assertEquals(world.physics[spot[PlaceableTCStandingSpot.KEY].blockerNode], false, "spot's out")
    assertEquals(world.physics[seat[PlaceableTCStandingSpot.KEY].blockerNode], nil, "seat's never taken out")
    assertTrue(seat[PlaceableTCStandingSpot.KEY].isBlockerActive, "seat's still active")
end)

-- A TCSeatedFigure stand-in recording what it's asked.
local function fakeSeatedFigures(isLoaded)
    local made = {}
    TCSeatedFigure = {
        new = function(node, seatType)
            local figure = { node = node, seatType = seatType, updates = 0, shown = false }
            function figure:load(style, callback) callback(isLoaded) end
            function figure:show() self.shown = true end
            function figure:hide() self.shown = false end
            function figure:update() self.updates = self.updates + 1 end
            function figure:delete() self.deleted = true end
            table.insert(made, figure)
            return figure
        end,
    }
    TCWorkerAppearance = { getPlayerStyle = function() return { xmlFilename = "style.xml" } end }
    return made
end

test("someone on a seat is loaded sitting on its chair, shown and posed, never stood or turned", function()
    setup()
    local made = fakeSeatedFigures(true)
    local seat = addSeat(1, 3, "lobbyArmchair")
    local worker = addWorker(1, 1)
    local spot = { key = "k", placeable = seat, x = 0, y = 0, z = 0, yaw = 0, seat = PlaceableTCSeatSpot.getSeat(seat) }
    local figure = TCIdleStaff.putOnSpot(1, worker, spot)

    TCIdleStaff.updateModel(1, figure, {}, 16, 0, 0, 5)
    assertEquals(#made, 1, "a seated figure")
    assertTrue(made[1].node == seat[PlaceableTCSeatSpot.KEY].node, "on the seat's node")
    assertTrue(made[1].seatType == TCSeatTypes.TYPES.lobbyArmchair, "with the chair's type")
    assertTrue(figure.isReady, "ready once loaded")
    assertTrue(made[1].shown, "shown within range")

    local updates = made[1].updates
    TCIdleStaff.updateModel(1, figure, {}, 16, 0, 0, 5)
    assertEquals(made[1].updates, updates + 1, "posed each frame it's shown")

    TCIdleStaff.updateModel(1, figure, {}, 16, 0, 0, 150)
    assertTrue(not made[1].shown, "hidden out of range")
    assertEquals(made[1].updates, updates + 1, "and not posed")

    TCIdleStaff.takeOffSpot(1)
    assertTrue(made[1].deleted, "freed when they get up")
end)

test("a sitter whose look won't load isn't tried again", function()
    setup()
    local made = fakeSeatedFigures(false)
    local seat = addSeat(1, 3, "woodenChair")
    local worker = addWorker(1, 1)
    local spot = { key = "k", placeable = seat, x = 0, y = 0, z = 0, yaw = 0, seat = PlaceableTCSeatSpot.getSeat(seat) }
    local figure = TCIdleStaff.putOnSpot(1, worker, spot)
    local noStyle = {}
    TCIdleStaff.updateModel(1, figure, noStyle, 16, 0, 0, 5)
    assertTrue(noStyle[1], "marked")
    assertTrue(not figure.isReady, "not ready")
end)
