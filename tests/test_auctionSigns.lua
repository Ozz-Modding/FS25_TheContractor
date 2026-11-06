-- 136: where an auction's roadside signs go (TCAuctionSigns): junctions
-- found from fake road splines, the busiest first, one sign each on the
-- driver's verge of a road into it, spread over the map; and the engine
-- half (TheContractorAuctionSigns): the month on the board, sync, save and
-- the console. Directions: x east, z south (a heading's right is (-hz, hx)).

local function setup()
    local world = stubs.install()
    world:load("src/util/TCAuctionSigns.lua")
    return world
end

-- A straight spline from (x1, z1) to (x2, z2), a point every 8 m.
local function line(x1, z1, x2, z2)
    local length = math.sqrt((x2 - x1) ^ 2 + (z2 - z1) ^ 2)
    local count = math.max(1, math.floor(length / 8))
    local points = {}
    for i = 0, count do
        local t = i / count
        table.insert(points, { x = x1 + (x2 - x1) * t, z = z1 + (z2 - z1) * t, y = 0 })
    end
    return points
end

local function allClear()
    return true
end

-- A road along x with a lane leaving it south (+z) at x = cx.
local function tJunction(cx, cz)
    cx, cz = cx or 0, cz or 0
    return { line(cx - 400, cz, cx + 400, cz), line(cx, cz, cx, cz + 300) }
end

local function addAll(roads, more)
    for _, road in ipairs(more) do
        table.insert(roads, road)
    end
    return roads
end

-- A village: a 3 x 3 grid of streets 60 m apart round (cx, cz), plus roads
-- out of it.
local function village(cx, cz)
    local roads = {}
    for i = -1, 1 do
        table.insert(roads, line(cx - 300, cz + i * 60, cx + 300, cz + i * 60))
        table.insert(roads, line(cx + i * 60, cz - 300, cx + i * 60, cz + 300))
    end
    return roads
end

local function distance(ax, az, bx, bz)
    return math.sqrt((ax - bx) ^ 2 + (az - bz) ^ 2)
end

-- A sign stands on the driver's (right) verge of the road it's on, facing a
-- driver heading to its junction. (The junction's middle is its joined
-- points' average, a little off a road's line, hence the leeway.)
local function assertFacesDriver(sign)
    local hx, hz = sign.junctionX - sign.roadX, sign.junctionZ - sign.roadZ
    local length = math.sqrt(hx * hx + hz * hz)
    hx, hz = hx / length, hz / length
    local rx, rz = TCAuctionSigns.rightOf(hx, hz)
    assertEquals("right", sign.side)
    assertNear(sign.roadX + rx * sign.offset, sign.x, 0.5)
    assertNear(sign.roadZ + rz * sign.offset, sign.z, 0.5)
    assertNear(math.atan2(-hx, -hz), sign.yaw, 0.1)
end

test("a T junction gets a sign back along a road into it, on the driver's verge, facing them", function()
    setup()
    local result = TCAuctionSigns.pick(tJunction(), allClear)
    assertEquals(1, result.junctionCount)
    assertEquals(1, #result.signs)
    local sign = result.signs[1]
    assertNear(0, sign.junctionX, 1)
    assertNear(0, sign.junctionZ, 1)
    local back = distance(sign.roadX, sign.roadZ, sign.junctionX, sign.junctionZ)
    assertTrue(back >= TCAuctionSigns.RULES.approachDistance - 1, "far enough back")
    assertTrue(back <= TCAuctionSigns.RULES.approachDistance + 9, "not too far back")
    assertNear(TCAuctionSigns.RULES.vergeOffsets[1], sign.offset, 0.001)
    assertFacesDriver(sign)
end)

test("a crossing of two splines is a junction", function()
    setup()
    local result = TCAuctionSigns.pick({ line(-300, 0, 300, 0), line(0, -300, 0, 300) }, allClear)
    assertEquals(1, result.junctionCount)
    assertEquals(1, #result.signs)
    assertFacesDriver(result.signs[1])
end)

test("a road split into two splines end to end is no junction", function()
    setup()
    local result = TCAuctionSigns.pick({ line(-300, 0, 0, 0), line(0, 0, 300, 0) }, allClear)
    assertEquals(0, result.junctionCount)
    assertEquals(0, #result.signs)
end)

test("a lane drawn as two splines, one each way, is one road into the junction", function()
    setup()
    local roads = { line(-400, 0, 400, 0), line(1.5, 0, 1.5, 300), line(-1.5, 300, -1.5, 0) }
    local result = TCAuctionSigns.pick(roads, allClear)
    assertEquals(1, result.junctionCount)
end)

test("the busiest junction comes first: a village's before a lone one in the country", function()
    setup()
    TCAuctionSigns.RULES.maxSigns = 1
    local roads = addAll(tJunction(-3000, 0), village(3000, 0))
    local result = TCAuctionSigns.pick(roads, allClear)
    assertTrue(result.junctionCount > 1, "the village's junctions and the lone one")
    assertEquals(1, #result.signs)
    assertTrue(result.signs[1].junctionX > 2000, "the sign is in the village")
end)

test("signs are spread over the map: a junction near one already signed is left", function()
    setup()
    -- Two T junctions 200 m apart on one road, nearer than minSpacing.
    local roads = { line(-600, 0, 600, 0), line(-100, 0, -100, 300), line(100, 0, 100, 300) }
    local result = TCAuctionSigns.pick(roads, allClear)
    assertEquals(2, result.junctionCount)
    assertEquals(1, #result.signs)
    assertEquals(1, result.rejected[TCAuctionSigns.REJECT.TOO_CLOSE])

    TCAuctionSigns.RULES.minSpacing = 100
    result = TCAuctionSigns.pick(roads, allClear)
    assertEquals(2, #result.signs)
end)

test("at most maxSigns go up, each at least minSpacing from the rest", function()
    setup()
    local roads = {}
    for i = 0, 5 do
        addAll(roads, tJunction(i * 1000, 0))
    end
    TCAuctionSigns.RULES.maxSigns = 4
    local result = TCAuctionSigns.pick(roads, allClear)
    assertEquals(6, result.junctionCount)
    assertEquals(4, #result.signs)
    for i = 1, #result.signs do
        for j = i + 1, #result.signs do
            local a, b = result.signs[i], result.signs[j]
            assertTrue(distance(a.x, a.z, b.x, b.z) >= TCAuctionSigns.RULES.minSpacing,
                "signs " .. i .. " and " .. j .. " apart")
        end
    end
end)

test("a blocked verge moves the sign in, then across the road, then to another road in", function()
    setup()
    local outer = TCAuctionSigns.RULES.vergeOffsets[1]
    local blockedRoad
    local result = TCAuctionSigns.pick(tJunction(), function(candidate)
        -- The first road tried is blocked on the driver's side, and its
        -- outer spot across the road.
        blockedRoad = blockedRoad or { candidate.roadX, candidate.roadZ }
        if candidate.roadX == blockedRoad[1] and candidate.roadZ == blockedRoad[2] then
            if candidate.side == "right" then
                return false, "hedge"
            end
            if candidate.offset == outer then
                return false, "gate"
            end
        end
        return true
    end)
    local sign = result.signs[1]
    assertEquals("left", sign.side)
    assertNear(TCAuctionSigns.RULES.vergeOffsets[2], sign.offset, 0.001)
    assertEquals(#TCAuctionSigns.RULES.vergeOffsets, result.rejected.hedge)
    assertEquals(1, result.rejected.gate)

    -- Every spot on the first road blocked: the next road in gets it.
    blockedRoad = nil
    result = TCAuctionSigns.pick(tJunction(), function(candidate)
        blockedRoad = blockedRoad or { candidate.roadX, candidate.roadZ }
        if candidate.roadX == blockedRoad[1] and candidate.roadZ == blockedRoad[2] then
            return false, "hedge"
        end
        return true
    end)
    assertEquals(1, #result.signs)
    assertTrue(result.signs[1].roadX ~= blockedRoad[1] or result.signs[1].roadZ ~= blockedRoad[2],
        "on another road in")
    assertFacesDriver(result.signs[1])
    assertEquals(2 * #TCAuctionSigns.RULES.vergeOffsets, result.rejected.hedge)
end)

test("a spot on another road is passed over", function()
    setup()
    -- Every road into the junction has another, not joined to it, 6 m to
    -- the driver's right of the sign's road point: those spots are on it.
    TCAuctionSigns.RULES.joinDistance = 4
    local roads = { line(-400, 0, 400, 0), line(0, 0, 0, 300),
        line(-300, 6, -10, 6), line(10, -6, 300, -6), line(-6, 10, -6, 300) }
    local result = TCAuctionSigns.pick(roads, allClear)
    assertEquals(1, #result.signs)
    assertEquals("left", result.signs[1].side)
    assertTrue((result.rejected[TCAuctionSigns.REJECT.ON_ROAD] or 0) >= #TCAuctionSigns.RULES.vergeOffsets,
        "the driver's side counted as on a road")
end)

-- The engine half (TheContractorAuctionSigns) -------------------------------------------------

-- A fake engine for the sign's model: nodes are tables, the model's tree as
-- the i3d has it (auctionSign > visuals > posts, board, face, date > month1
-- to month12; and col).
local function installModelEngine(world)
    world.loaded, world.released = {}, {}
    local function node(name, children)
        return { name = name, children = children or {}, visible = true }
    end
    g_i3DManager = {
        loadSharedI3DFile = function(_, filename)
            local months = {}
            for month = 1, 12 do
                table.insert(months, node("month" .. month))
            end
            local sign = node("auctionSign", {
                node("visuals", { node("posts"), node("board"), node("face"), node("date", months) }), node("col") })
            table.insert(world.loaded, sign)
            return node("root", { sign }), #world.loaded
        end,
        releaseSharedI3DFile = function(_, id) table.insert(world.released, id) end,
    }
    getChildAt = function(n, i) return n.children[i + 1] end
    getNumOfChildren = function(n) return #n.children end
    world.sceneRoot = node("scene")
    getRootNode = function() return world.sceneRoot end
    link = function(parent, n) n.parent = parent end
    delete = function(n) n.deleted = true end
    entityExists = function(n) return n ~= nil and not n.deleted end
    setTranslation = function(n, x, y, z) n.translation = { x, y, z } end
    setRotation = function(n, x, y, z) n.rotation = { x, y, z } end
    setVisibility = function(n, visible) n.visible = visible end
    world.terrainHeight = 10
    g_terrainNode = "terrain"
    getTerrainHeightAtWorldPos = function() return world.terrainHeight end
end

local function setupGame()
    local world = setup()
    TheContractor = { SaveKey = "TheContractor", dir = "" }
    Event = { new = function(mt) return setmetatable({}, mt) end }
    InitEventClass = function() end
    world.events = {}
    g_server = { broadcastEvent = function(_, event) table.insert(world.events, event) end }
    getTimeSec = function() return 0 end
    installModelEngine(world)
    world:load("src/business/AuctionSigns.lua")
    world:load("src/events/TCAuctionSignsEvent.lua")
    local signs = TheContractorAuctionSigns.new()
    g_currentMission.TheContractor.AuctionSigns = signs
    world.signs = signs
    return world
end

local SIGNS = {
    { x = 10, z = 20, yaw = 1.5 },
    { x = -40, z = 5, yaw = -1.57 },
}

local function sameSpots(expected, actual)
    assertEquals(#expected, #actual)
    for i, sign in ipairs(expected) do
        assertNear(sign.x, actual[i].x, 0.001)
        assertNear(sign.z, actual[i].z, 0.001)
        assertNear(sign.yaw, actual[i].yaw, 0.001)
    end
end

-- The visible children's names under a node.
local function shown(n)
    local names = {}
    for _, child in ipairs(n.children) do
        if child.visible then
            table.insert(names, child.name)
        end
    end
    return table.concat(names, ",")
end

test("signs going up are sent to every client, and the event carries the month and every spot", function()
    local world = setupGame()
    world.signs.month, world.signs.signs = 12, SIGNS
    world.signs:sync()
    assertEquals(1, #world.events)
    local stream = world:newStream()
    world.events[1]:writeStream(stream)
    local month, signs = TCAuctionSignsEvent.readSigns(stream)
    assertEquals(12, month)
    sameSpots(SIGNS, signs)
end)

test("a player joining afterwards gets the signs in the initial client state", function()
    local world = setupGame()
    world.signs:applySync(9, SIGNS)
    local stream = world:newStream()
    world.signs:writeInitialClientState(stream)
    local client = TheContractorAuctionSigns.new()
    client:readInitialClientState(stream)
    assertEquals(9, client.month)
    sameSpots(SIGNS, client.signs)
    assertTrue(client.isDirty, "the client builds them on its next update")
end)

test("each sign is a model on the ground at its spot, showing only its month", function()
    local world = setupGame()
    world.signs:applySync(7, SIGNS)
    world.signs:update(16)
    assertEquals(2, #world.signs.models)
    local model = world.loaded[1]
    assertEquals(world.sceneRoot, model.parent)
    assertEquals(10, model.translation[1])
    assertEquals(world.terrainHeight, model.translation[2])
    assertEquals(1.5, model.rotation[2])
    assertEquals("month7", shown(model.children[1].children[4]))
    assertEquals("month7", shown(world.loaded[2].children[1].children[4]))
end)

test("on a slope a sign stands at the lowest ground under its posts, so no post hangs in the air", function()
    local world = setupGame()
    -- Ground rising along world z; a sign turned a quarter has its board
    -- across z, so one post is downhill of the other.
    getTerrainHeightAtWorldPos = function(_, x, _, z) return 10 + z end
    world.signs:applySync(7, { { x = 0, z = 0, yaw = math.pi / 2 } })
    world.signs:update(16)
    assertNear(10 - 0.645, world.loaded[1].translation[2], 0.001)

    -- Turned the other way round, it's the other post that's downhill.
    world.signs:applySync(7, { { x = 0, z = 0, yaw = -math.pi / 2 } })
    world.signs:update(16)
    assertNear(10 - 0.645, world.loaded[2].translation[2], 0.001)
end)

test("taking the signs down deletes the models and frees the shared file", function()
    local world = setupGame()
    world.signs.month, world.signs.signs = 7, SIGNS
    world.signs:sync()
    world.signs:update(16)
    world.signs:clear()
    world.signs:update(16)
    assertEquals(0, #world.signs.models)
    assertTrue(world.loaded[1].deleted and world.loaded[2].deleted, "models deleted")
    assertEquals(2, #world.released)
    assertEquals(0, world.events[#world.events].month)
    assertEquals(0, #world.events[#world.events].signs)
end)

test("the signs and their month survive a save, and nothing's saved without any", function()
    local world = setupGame()
    local xmlFile = {}
    world.signs:saveToXmlFile(xmlFile)
    assertEquals(nil, next(xmlFile))

    world.signs:applySync(7, SIGNS)
    world.signs:saveToXmlFile(xmlFile)
    local loaded = TheContractorAuctionSigns.new()
    loaded:loadFromXMLFile(xmlFile)
    assertEquals(7, loaded.month)
    sameSpots(SIGNS, loaded.signs)
    assertTrue(loaded.isDirty, "built on the first update")
end)

-- A T junction's roads as engine splines, and a field south of the main
-- road west of the lane (x -400 to -1, z 1 to 300).
local function installRoadsAndField(world)
    local splines = { { -400, 0, 400, 0 }, { 0, 0, 0, 300 } }
    local set = {}
    for _, spline in ipairs(splines) do
        set[spline] = true
    end
    g_currentMission.aiSystem = { getRoadSplines = function() return set end }
    getSplineLength = function(s) return math.sqrt((s[3] - s[1]) ^ 2 + (s[4] - s[2]) ^ 2) end
    getSplinePosition = function(s, t) return s[1] + (s[3] - s[1]) * t, 10, s[2] + (s[4] - s[2]) * t end
    FSDensityMapUtil = {
        getIsFieldAtWorldPos = function(x, z) return x >= -400 and x <= -1 and z >= 1 and z <= 300 end,
    }
    world.overlaps = 0
    overlapBox = function() world.overlaps = world.overlaps + 1 end
end

test("tcCompany auctionSigns <month>: signs at the junctions for that month, none on a field", function()
    local world = setupGame()
    installRoadsAndField(world)
    local registered = {}
    TCConsole = { register = function(group, name, def) registered[name] = def end }
    TheContractorAuctionSigns.registerConsoleCommands()
    local command = registered.auctionSigns

    for _, bad in ipairs({ { "x" }, { "13" }, { "0" }, { "7.5" }, { "july", "2" }, { "clear", "2" } }) do
        assertEquals(false, command.run(1, bad))
    end
    assertEquals(0, #world.signs.signs)

    command.run(1, { "Jul" })
    assertEquals(7, world.signs.month)
    assertEquals(1, #world.signs.signs)
    assertTrue(world.overlaps > 0, "each spot checked for room")
    for _, sign in ipairs(world.signs.signs) do
        assertTrue(not FSDensityMapUtil.getIsFieldAtWorldPos(sign.x, sign.z), "no sign on the field")
    end
    assertEquals(1, #world.events)

    command.run(1, { "9" })
    assertEquals(9, world.signs.month)
    command.run(1, { "september" })
    assertEquals(9, world.signs.month)

    command.run(1, { "clear" })
    assertEquals(0, #world.signs.signs)
    assertEquals(0, world.signs.month)
end)
