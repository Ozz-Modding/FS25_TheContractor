-- 165: the show's showground (TCShowScene), laid out from the synced scene
-- of 164's showground rectangle: the ring (with its gateway), the pens, the
-- stands and the trailer lines inside the arena and clear of each other;
-- the crowd's lanes clear of every hurdle and stand; the shared entrance
-- dressing with the show's own gate sign; the same on every machine; and
-- nothing of it for another kind's day.

local function setup()
    local world = stubs.install()
    world:load("src/util/TCAuctionCrowd.lua")
    world:load("src/util/TCAuctionLayout.lua")
    world:load("src/util/TCAuctionScene.lua")
    world:load("src/util/TCShowScene.lua")
    return world
end

-- 164's showground: 120 x 60 m by default, its entrance at the +u end.
local function makeScene(halfU, halfV, dressing, seed, angle)
    local rect = { cx = 100, cz = 50, angle = angle or 0, halfU = halfU or 60, halfV = halfV or 30 }
    local cosA, sinA = math.cos(rect.angle), math.sin(rect.angle)
    local entrance = { x = rect.cx + cosA * (rect.halfU + 10), z = rect.cz + sinA * (rect.halfU + 10) }
    local layout = TCAuctionLayout.layOutOpenRect(rect, entrance)
    local scene = TCAuctionLayout.getScene(layout, entrance, seed or 99)
    scene.dressing = dressing or "show"
    return scene, rect
end

-- A world point in the rectangle's frame.
local function toLocal(rect, x, z)
    local cosA, sinA = math.cos(rect.angle), math.sin(rect.angle)
    local dx, dz = x - rect.cx, z - rect.cz
    return dx * cosA + dz * sinA, -dx * sinA + dz * cosA
end

local function byKind(props, kind)
    local found = {}
    for _, prop in ipairs(props) do
        if prop.kind == kind then
            table.insert(found, prop)
        end
    end
    return found
end

-- The distance from a point to a walkway's middle line.
local function distanceToWalkway(walkway, x, z)
    local dx, dz = walkway.x2 - walkway.x1, walkway.z2 - walkway.z1
    local lengthSq = dx * dx + dz * dz
    local t = math.max(0, math.min(1, ((x - walkway.x1) * dx + (z - walkway.z1) * dz) / lengthSq))
    local px, pz = walkway.x1 + dx * t, walkway.z1 + dz * t
    return math.sqrt((x - px) ^ 2 + (z - pz) ^ 2)
end

test("the arena: a ring with a gateway, a row of pens, stands and trailer lines, inside the showground", function()
    setup()
    local scene, rect = makeScene()
    local areas = TCShowScene.getAreas(scene)
    assertTrue(areas ~= nil)
    assertEquals(areas.pens.count, TCShowScene.PENS.maxCount)
    assertEquals(#areas.stands, TCShowScene.STANDS.maxCount)
    assertEquals(areas.lines.count, TCShowScene.TRAILER_LINES.maxBays)
    assertEquals(#areas.lanes, 2)

    local dressed = TCShowScene.layOut(scene)
    local hurdles = byKind(dressed.props, "hurdle")
    -- The ring: 12 + 12 panels along its sides, 8 + 8 across, one left
    -- out for the gateway. The pens: two walls of 8, and 9 across.
    local ringPanels = 2 * (TCShowScene.RING.length + TCShowScene.RING.width) / TCShowScene.PANEL - 1
    assertEquals(#hurdles, ringPanels + 2 * 8 + 9)
    assertEquals(#byKind(dressed.props, "stand"), 5)
    assertEquals(#byKind(dressed.props, "cone"), 2 * (8 + 1))
    for _, prop in ipairs(dressed.props) do
        local u, v = toLocal(rect, prop.x, prop.z)
        assertTrue(math.abs(u) <= rect.halfU and math.abs(v) <= rect.halfV, prop.kind .. " in the showground")
        assertTrue(u < scene.nearEdge + 0.01, prop.kind .. " past the entrance space")
    end
    assertTrue(#dressed.sounds == 1, "the ring's murmur")
end)

test("the crowd's lanes keep clear of every hurdle, post and stand", function()
    setup()
    local scene = makeScene()
    local walkways = TCShowScene.getWalkways(scene)
    assertEquals(#walkways, 3, "a lane each side of the ring and the aisle past it")
    local dressed = TCShowScene.layOut(scene)
    for _, prop in ipairs(dressed.props) do
        if prop.kind ~= "cone" then
            local points = TCAuctionLayout.getFootprintCorners(prop.x, prop.z, prop.yaw, prop.width, prop.length)
            table.insert(points, { x = prop.x, z = prop.z })
            for i, walkway in ipairs(walkways) do
                for _, point in ipairs(points) do
                    assertTrue(distanceToWalkway(walkway, point.x, point.z) >= walkway.halfWidth - 0.01,
                        prop.kind .. " clear of walkway " .. i)
                end
            end
        end
    end
end)

test("ringside spectators face the ring, and the stands have people at them", function()
    setup()
    local scene, rect = makeScene()
    local dressed = TCShowScene.layOut(scene)
    local ring, stand = 0, 0
    for _, spot in ipairs(dressed.spots) do
        if spot.category == TCShowScene.SPOT.RING then
            ring = ring + 1
            local _, v = toLocal(rect, spot.x, spot.z)
            -- Facing along v, towards the middle.
            local facingV = math.cos(spot.yaw)
            assertTrue(facingV * v < 0, "facing in")
        elseif spot.category == TCShowScene.SPOT.STAND then
            stand = stand + 1
        end
    end
    assertTrue(ring > 0)
    assertEquals(stand, 10)
end)

test("the scene's dressing: the show's gate sign and arena, nothing of the auction's", function()
    setup()
    local scene = makeScene()
    local dressed = TCAuctionScene.layOut(scene)
    assertEquals(#byKind(dressed.props, "showGateSign"), 1)
    assertEquals(#byKind(dressed.props, "gateSign"), 0)
    assertEquals(#byKind(dressed.props, "office"), 0)
    assertTrue(#byKind(dressed.props, "hurdle") > 0)
    assertTrue(#byKind(dressed.props, "car") > 0, "the shared car park")

    local other = TCAuctionScene.layOut(makeScene(nil, nil, "openDay"))
    assertEquals(#byKind(other.props, "hurdle"), 0, "another kind's day has no arena")
    assertEquals(#byKind(other.props, "showGateSign"), 0)
    assertEquals(#TCShowScene.getWalkways(makeScene(nil, nil, "openDay")), 3,
        "the walks are the scene's frame's (only the show asks for them)")
end)

test("every machine lays out the same, at any angle", function()
    setup()
    local a = TCShowScene.layOut(makeScene(nil, nil, nil, 7, 0.7))
    local b = TCShowScene.layOut(makeScene(nil, nil, nil, 7, 0.7))
    assertEquals(#a.props, #b.props)
    assertEquals(#a.spots, #b.spots)
    for i, prop in ipairs(a.props) do
        assertNear(prop.x, b.props[i].x, 0.0001)
        assertNear(prop.yaw, b.props[i].yaw, 0.0001)
    end
end)

test("a showground too small for the ring has no arena; a short one no trailer lines", function()
    setup()
    assertEquals(TCShowScene.getAreas(makeScene(40, 30)), nil)
    assertEquals(#TCShowScene.layOut(makeScene(40, 30)).props, 0)
    assertEquals(#TCShowScene.getWalkways(makeScene(40, 30)), 0)
    local short = TCShowScene.getAreas(makeScene(48, 30))
    assertTrue(short ~= nil)
    assertEquals(short.lines, nil)
end)
