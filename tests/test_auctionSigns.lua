-- 136: where an auction's roadside signs go (TCAuctionSigns): junctions
-- found from fake road splines, the busiest first, one sign each on the
-- driver's verge of a road into it, spread over the map; and the engine
-- half (TheContractorAuctionSigns): the models, sync, save and the
-- console. Directions: x east, z south (a heading's right is (-hz, hx)).

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

-- A sign stands on the driver's (right) verge of the road it's on, side on
-- to it and facing the road. (The junction's middle is its joined
-- points' average, a little off a road's line, hence the leeway.)
local function assertFacesDriver(sign)
    local hx, hz = sign.junctionX - sign.roadX, sign.junctionZ - sign.roadZ
    local length = math.sqrt(hx * hx + hz * hz)
    hx, hz = hx / length, hz / length
    local rx, rz = TCAuctionSigns.rightOf(hx, hz)
    assertEquals("right", sign.side)
    assertNear(sign.roadX + rx * sign.offset, sign.x, 0.5)
    assertNear(sign.roadZ + rz * sign.offset, sign.z, 0.5)
    -- The board's front (+Z at its yaw) points back at the road.
    assertNear(-rx, math.sin(sign.yaw), 0.1)
    assertNear(-rz, math.cos(sign.yaw), 0.1)
end

test("a T junction gets a sign back along a road into it, on the driver's verge, facing the road", function()
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
    -- Each spot is tried with every design.
    local designs = #TCAuctionSigns.RULES.designs
    assertEquals(#TCAuctionSigns.RULES.vergeOffsets * designs, result.rejected.hedge)
    assertEquals(designs, result.rejected.gate)

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
    assertEquals(2 * #TCAuctionSigns.RULES.vergeOffsets * designs, result.rejected.hedge)
end)

test("signs take turns at the designs, and a verge too short for one gets the other", function()
    setup()
    local roads = {}
    for i = 0, 3 do
        addAll(roads, tJunction(i * 1000, 0))
    end
    local result = TCAuctionSigns.pick(roads, allClear)
    assertEquals(4, #result.signs)
    for i, sign in ipairs(result.signs) do
        assertEquals(TCAuctionSigns.RULES.designs[(i - 1) % 2 + 1], sign.design)
    end

    -- Design 1 never fits: every sign is design 2, on the outer verge
    -- (the narrower board isn't moved in for want of the wider one).
    result = TCAuctionSigns.pick(roads, function(candidate)
        if candidate.design == 1 then
            return false, "tooWide"
        end
        return true
    end)
    assertEquals(4, #result.signs)
    for _, sign in ipairs(result.signs) do
        assertEquals(2, sign.design)
        assertNear(TCAuctionSigns.RULES.vergeOffsets[1], sign.offset, 0.001)
    end
    assertEquals(4, result.rejected.tooWide)
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

-- A ring road of radius r round (cx, cz), a point every 8 m or so, closed.
local function ring(cx, cz, r)
    local count = math.max(6, math.floor(2 * math.pi * r / 8))
    local points = {}
    for i = 0, count do
        local a = 2 * math.pi * i / count
        table.insert(points, { x = cx + r * math.cos(a), z = cz + r * math.sin(a), y = 0 })
    end
    return points
end

-- A roundabout at (0, 0): a ring of radius 15 and four roads out of it.
local function roundabout()
    return { ring(0, 0, 15), line(15, 0, 400, 0), line(-15, 0, -400, 0), line(0, 15, 0, 400), line(0, -15, 0, -400) }
end

test("a spot with road all round it (a roundabout's island) is enclosed; a verge isn't", function()
    setup()
    local network = TCAuctionSigns.buildNetwork(roundabout())
    assertTrue(TCAuctionSigns.isEnclosed(network, 0, 0), "the island")
    assertTrue(TCAuctionSigns.isEnclosed(network, 4, -5), "off the island's middle")
    -- On the verge of a road into it, a junction sign's distance back.
    assertTrue(not TCAuctionSigns.isEnclosed(network, 50, 5), "a verge before the roundabout")
    assertTrue(not TCAuctionSigns.isEnclosed(network, 200, 5), "a verge out in the country")
end)

test("a verge with another street close behind it isn't enclosed (a village's blocks)", function()
    setup()
    -- Two streets 20 m apart, crossed by others 60 m on.
    local network = TCAuctionSigns.buildNetwork({ line(-400, 0, 400, 0), line(-400, 20, 400, 20),
        line(-60, -100, -60, 100), line(60, -100, 60, 100) })
    assertTrue(not TCAuctionSigns.isEnclosed(network, 0, 5), "a verge between the streets")
    assertTrue(not TCAuctionSigns.isEnclosed(network, 0, 15), "the other street's verge")
end)

test("no sign goes up inside a roundabout", function()
    setup()
    local result = TCAuctionSigns.pick(roundabout(), allClear)
    assertTrue(#result.signs >= 1)
    for _, sign in ipairs(result.signs) do
        assertTrue(distance(sign.x, sign.z, 0, 0) > 15, "a sign inside the ring")
        assertTrue(not TCAuctionSigns.isEnclosed(TCAuctionSigns.buildNetwork(roundabout()), sign.x, sign.z))
    end
end)

test("no sign on a roundabout's ring: only on the roads into it", function()
    setup()
    local result = TCAuctionSigns.pick(roundabout(), allClear)
    assertTrue(#result.signs >= 1)
    for _, sign in ipairs(result.signs) do
        -- Its road point is on an approach, out past the ring.
        assertTrue(distance(sign.roadX, sign.roadZ, 0, 0) > 20, "a sign by the ring")
    end
end)

test("no sign on a dead end: a spur that stops short", function()
    setup()
    -- A road along x, and a 60 m spur north (a drive, a yard). Only the
    -- spur's verges are free, so without the rule the sign goes there.
    local roads = { line(-400, 0, 400, 0), line(0, 0, 0, -60) }
    local function onlySpur(candidate)
        return math.abs(candidate.x) < 10
    end
    local result = TCAuctionSigns.pick(roads, onlySpur)
    assertEquals(0, #result.signs)
    -- A long enough road north takes one.
    result = TCAuctionSigns.pick({ line(-400, 0, 400, 0), line(0, 0, 0, -300) }, onlySpur)
    assertEquals(1, #result.signs)
end)

test("a map's exclusion keeps a sign out of its circle: the sign goes to the next spot that works", function()
    setup()
    local first = TCAuctionSigns.pick(tJunction(), allClear).signs[1]
    local zone = { x = first.x, z = first.z, radius = 10 }
    local result = TCAuctionSigns.pick(tJunction(), allClear, { zone })
    assertEquals(1, #result.signs)
    local sign = result.signs[1]
    assertTrue(distance(sign.x, sign.z, zone.x, zone.z) >= zone.radius, "a sign inside the exclusion")
    assertTrue((result.rejected[TCAuctionSigns.REJECT.EXCLUDED] or 0) > 0)
end)

test("a map's exclusions are found by its mod name; any other map has none", function()
    setup()
    local zone = { x = 1, z = 2, radius = 10 }
    TCAuctionSigns.MAP_EXCLUSIONS.FS25_TestMap = { zone }
    assertEquals(zone, TCAuctionSigns.getExclusions("FS25_TestMap.SampleModMap")[1])
    assertEquals(0, #TCAuctionSigns.getExclusions("MapUS"))
    assertEquals(0, #TCAuctionSigns.getExclusions("FS25_OtherMap.SampleModMap"))
    assertEquals(0, #TCAuctionSigns.getExclusions(nil))
end)

test("another road crossing the sign's keeps further off than the road it stands by", function()
    setup()
    -- A T junction, and a road running south from 10 m off the main road
    -- at x = -38, not joined to it: the west road's south verge is 6 m
    -- from it.
    local roads = { line(-400, 0, 400, 0), line(0, 0, 0, 300), line(-38, 10, -38, 300) }
    local function westOnly(candidate)
        return candidate.x < -20 and candidate.x > -60
    end
    local result = TCAuctionSigns.pick(roads, westOnly)
    assertEquals(1, #result.signs)
    assertTrue(result.signs[1].z < 0, "the north verge, away from the crossing road")
end)

-- The engine half (TheContractorAuctionSigns) -------------------------------------------------

-- A fake engine for the sign's model: nodes are tables, the model's tree as
-- the i3d has it (auctionSign > visuals > posts, board, face; and col).
local function installModelEngine(world)
    world.loaded, world.released = {}, {}
    local function node(name, children)
        return { name = name, children = children or {}, visible = true }
    end
    g_i3DManager = {
        loadSharedI3DFile = function(_, filename)
            local sign = node("auctionSign", {
                node("visuals", { node("posts"), node("board"), node("face") }), node("col") })
            sign.filename = filename
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
    { x = 10, z = 20, yaw = 1.5, design = 2 },
    { x = -40, z = 5, yaw = -1.57, design = 1 },
}

local function sameSpots(expected, actual)
    assertEquals(#expected, #actual)
    for i, sign in ipairs(expected) do
        assertNear(sign.x, actual[i].x, 0.001)
        assertNear(sign.z, actual[i].z, 0.001)
        assertNear(sign.yaw, actual[i].yaw, 0.001)
        assertEquals(sign.design, actual[i].design)
    end
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

test("each sign is its design's model on the ground at its spot", function()
    local world = setupGame()
    world.signs:applySync(7, SIGNS)
    world.signs:update(16)
    assertEquals(2, #world.signs.models)
    local model = world.loaded[1]
    assertEquals(world.sceneRoot, model.parent)
    assertEquals(10, model.translation[1])
    assertEquals(world.terrainHeight, model.translation[2])
    assertEquals(1.5, model.rotation[2])
    assertEquals(TheContractorAuctionSigns.DESIGNS[2].filename, model.filename)
    assertEquals(TheContractorAuctionSigns.DESIGNS[1].filename, world.loaded[2].filename)
end)

test("on a slope a sign stands at the lowest ground under its posts, so no post hangs in the air", function()
    local world = setupGame()
    -- Ground rising along world z; a sign turned a quarter has its board
    -- across z, so one post is downhill of the other.
    getTerrainHeightAtWorldPos = function(_, x, _, z) return 10 + z end
    local function outerEdge(design)
        return TheContractorAuctionSigns.DESIGNS[design].postX + TheContractorAuctionSigns.POST_SIZE / 2
    end
    world.signs:applySync(7, { { x = 0, z = 0, yaw = math.pi / 2, design = 1 } })
    world.signs:update(16)
    assertNear(10 - outerEdge(1), world.loaded[1].translation[2], 0.001)

    -- Turned the other way round, it's the other post that's downhill; the
    -- narrower design's posts are closer in.
    world.signs:applySync(7, { { x = 0, z = 0, yaw = -math.pi / 2, design = 2 } })
    world.signs:update(16)
    assertNear(10 - outerEdge(2), world.loaded[2].translation[2], 0.001)
    assertTrue(outerEdge(2) < outerEdge(1), "design 2 is the narrower")
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

test("a sign saved before there were designs, or with one that's gone, loads as the default", function()
    setupGame()
    local xmlFile = {}
    setXMLInt(xmlFile, "TheContractor.auctionSigns#month", 5)
    setXMLFloat(xmlFile, "TheContractor.auctionSigns.sign(0)#x", 1)
    setXMLFloat(xmlFile, "TheContractor.auctionSigns.sign(0)#z", 2)
    setXMLFloat(xmlFile, "TheContractor.auctionSigns.sign(1)#x", 3)
    setXMLFloat(xmlFile, "TheContractor.auctionSigns.sign(1)#z", 4)
    setXMLInt(xmlFile, "TheContractor.auctionSigns.sign(1)#design", 9)
    local loaded = TheContractorAuctionSigns.new()
    loaded:loadFromXMLFile(xmlFile)
    assertEquals(2, #loaded.signs)
    assertEquals(TheContractorAuctionSigns.DEFAULT_DESIGN, loaded.signs[1].design)
    assertEquals(TheContractorAuctionSigns.DEFAULT_DESIGN, loaded.signs[2].design)
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

-- The T junction's spots checked as the game checks them: north of the main
-- road (z < 0) has a mesh on the ground (a road or island the splines don't
-- run along).
local function pickWithGround(world)
    installRoadsAndField(world)
    RaycastUtil = {
        raycastClosest = function(x, y, z)
            if z < 0 then
                return 99, x, y - 2.9, z
            end
            return g_terrainNode, x, y - 3, z
        end,
    }
    return TCAuctionSigns.pick(TheContractorAuctionSigns.sampleRoads(), TheContractorAuctionSigns.isSpotClear)
end

test("a spot on something other than the ground is passed over: a road's or an island's mesh", function()
    local world = setupGame()
    local result = pickWithGround(world)
    assertEquals(1, #result.signs)
    assertTrue(result.signs[1].z > 0, "the sign south of the road, off the mesh")
    assertTrue((result.rejected[TheContractorAuctionSigns.REJECT.ON_OBJECT] or 0) > 0)
end)

test("tcDebug auctionSigns up: signs at the junctions, noted with this month, none on a field", function()
    local world = setupGame()
    installRoadsAndField(world)
    world:load("src/util/TCCalendar.lua")
    g_currentMission.environment = { currentPeriod = 5 }
    local registered = {}
    TCConsole = { register = function(group, name, def) registered[name] = def end }
    TheContractorAuctionSigns.registerConsoleCommands()
    local command = registered.auctionSigns

    for _, bad in ipairs({ { "x" }, { "7" }, { "july" }, { "up", "2" }, { "clear", "2" } }) do
        assertEquals(false, command.run(1, bad))
    end
    assertEquals(0, #world.signs.signs)

    command.run(1, { "Up" })
    assertEquals(TCCalendar.getMonth(5), world.signs.month)
    assertEquals(1, #world.signs.signs)
    assertTrue(world.overlaps > 0, "each spot checked for room")
    for _, sign in ipairs(world.signs.signs) do
        assertTrue(not FSDensityMapUtil.getIsFieldAtWorldPos(sign.x, sign.z), "no sign on the field")
    end
    assertEquals(1, #world.events)

    command.run(1, { "clear" })
    assertEquals(0, #world.signs.signs)
    assertEquals(0, world.signs.month)
end)

test("a spot's clear space is as wide as its design's board", function()
    local world = setupGame()
    installRoadsAndField(world)
    local widths = {}
    overlapBox = function(_, _, _, _, _, _, halfWidth) table.insert(widths, halfWidth) end
    -- East of the lane, off the field.
    for design = 1, 2 do
        TheContractorAuctionSigns.isSpotClear({ x = 100, z = 5, yaw = 0, roadX = 100, roadZ = 0, design = design })
    end
    local margin = TheContractorAuctionSigns.CLEARANCE.margin
    assertNear(TheContractorAuctionSigns.DESIGNS[1].width / 2 + margin, widths[1], 0.001)
    assertNear(TheContractorAuctionSigns.DESIGNS[2].width / 2 + margin, widths[2], 0.001)
end)

-- 163: whose signs they are --------------------------------------------------------------------

test("163: the signs carry the kind of day they're for, to clients, a joining one and the save", function()
    local world = setupGame()
    world.signs.month, world.signs.signs, world.signs.face = 6, SIGNS, "openDay"
    world.signs:sync()
    local stream = world:newStream()
    world.events[#world.events]:writeStream(stream)
    local client = TheContractorAuctionSigns.new()
    g_currentMission.TheContractor.AuctionSigns = client
    TCAuctionSignsEvent.emptyNew():readStream(stream, { getIsServer = function() return true end })
    assertEquals(client.face, "openDay")
    sameSpots(SIGNS, client.signs)

    local initial = world:newStream()
    world.signs:writeInitialClientState(initial)
    local joining = TheContractorAuctionSigns.new()
    joining:readInitialClientState(initial)
    assertEquals(joining.face, "openDay")

    local xmlFile = {}
    world.signs:saveToXmlFile(xmlFile)
    local loaded = TheContractorAuctionSigns.new()
    loaded:loadFromXMLFile(xmlFile)
    assertEquals(loaded.face, "openDay")

    -- Taken down: nobody's.
    world.signs:clear()
    assertEquals(world.signs.face, nil)
end)

test("163: signs saved before faces, or put up with none named, are the auction's", function()
    local world = setupGame()
    world.signs:applySync(7, SIGNS)
    assertEquals(world.signs.face, TheContractorAuctionSigns.DEFAULT_FACE)
    local xmlFile = {}
    setXMLInt(xmlFile, "TheContractor.auctionSigns#month", 5)
    setXMLFloat(xmlFile, "TheContractor.auctionSigns.sign(0)#x", 1)
    setXMLFloat(xmlFile, "TheContractor.auctionSigns.sign(0)#z", 2)
    local loaded = TheContractorAuctionSigns.new()
    loaded:loadFromXMLFile(xmlFile)
    assertEquals(loaded.face, TheContractorAuctionSigns.DEFAULT_FACE)
end)

test("163: a kind's face is its own boards; a kind with none yet shows the auction's", function()
    local world = setupGame()
    TheContractorAuctionSigns.FACES.testDay = { [1] = "i3d/testDay1.i3d", [2] = "i3d/testDay2.i3d" }
    world.signs:applySync(7, SIGNS, "testDay")
    world.signs:update(16)
    assertEquals(world.loaded[1].filename, "i3d/testDay2.i3d")
    assertEquals(world.loaded[2].filename, "i3d/testDay1.i3d")
    world.signs:applySync(7, SIGNS, "openDay")
    world.signs:update(16)
    assertEquals(world.loaded[3].filename, TheContractorAuctionSigns.DESIGNS[2].filename)
    TheContractorAuctionSigns.FACES.testDay = nil
end)
