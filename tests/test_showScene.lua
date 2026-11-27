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
    assertEquals(areas.pens.count, TCShowScene.PENS.default)
    assertEquals(#areas.stands, TCShowScene.STANDS.maxCount)
    assertEquals(areas.lines.count, TCShowScene.TRAILER_LINES.maxBays)
    assertEquals(#areas.lanes, 2)

    local dressed = TCShowScene.layOut(scene)
    local hurdles = byKind(dressed.props, "hurdle")
    -- The ring: 12 + 12 panels along its sides, 8 + 8 across, one left
    -- out for the gateway. The pens: two walls of 8, and 9 across.
    local ringPanels = 2 * (TCShowScene.RING.length + TCShowScene.RING.width) / TCShowScene.PANEL - 1
    assertEquals(#hurdles, ringPanels)
    -- 182: the pens' own, longer hurdles.
    assertEquals(#byKind(dressed.props, "penHurdle"), 2 * 8 + 9)
    assertEquals(#byKind(dressed.props, "stand"), 5)
    assertEquals(#byKind(dressed.props, "cone"), 2 * (8 + 1))
    for _, prop in ipairs(dressed.props) do
        local u, v = toLocal(rect, prop.x, prop.z)
        assertTrue(math.abs(u) <= rect.halfU and math.abs(v) <= rect.halfV, prop.kind .. " in the showground")
        assertTrue(u < scene.nearEdge + 0.01, prop.kind .. " past the entrance space")
    end
    assertTrue(#dressed.sounds == 1, "the ring's murmur")
end)

test("on a wide showground the pens and stands sit just past the lanes, not out at its edges", function()
    setup()
    local scene = makeScene(60, 60)
    local areas = TCShowScene.getAreas(scene)
    local laneRoom = scene.aisleWidth + 2 * TCShowScene.LANE_CLEARANCE
    assertNear(areas.pens.vTo, areas.ring.vFrom - laneRoom, 0.001, "the pens' inner wall")
    assertTrue(areas.pens.vFrom > -scene.halfV + TCShowScene.EDGE + 10, "well in from the edge")
    for _, stand in ipairs(areas.stands) do
        assertNear(stand.v - TCShowScene.STANDS.depth * 0.5, areas.ring.vTo + laneRoom, 0.001, "a stand's front")
    end
    for _, lane in ipairs(areas.lanes) do
        assertNear(lane.halfWidth, scene.aisleWidth * 0.5, 0.001, "a full lane")
    end
end)

test("the crowd's lanes keep clear of every hurdle and stand, with one row of pens or two", function()
    setup()
    for _, pens in ipairs({ false, 20 }) do
        local scene = makeScene()
        scene.pens = pens or nil
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

-- 182: the pens' animals and rosettes, from ShowLivestock's pens.
local function present(subTypeName, extra)
    local pen = { present = true, subTypeName = subTypeName, age = 20, variation = 2 }
    for key, value in pairs(extra or {}) do
        pen[key] = value
    end
    return pen
end

-- A rosette's spot on its hurdle, in the rectangle's frame (its model moved
-- offsetX along its own x).
local function rosetteLocal(rect, prop)
    local fx, fz = math.sin(prop.yaw), math.cos(prop.yaw)
    return toLocal(rect, prop.x + fz * prop.offsetX, prop.z - fx * prop.offsetX)
end

test("pens: as many as the scene asks, a second row behind the first when one row won't do", function()
    setup()
    local scene, rect = makeScene()
    scene.pens = 5
    local areas = TCShowScene.getAreas(scene)
    assertEquals(areas.pens.count, 5)
    assertEquals(areas.pens.back, nil)
    assertEquals(#TCShowScene.getPens(scene), 5)

    scene.pens = 20
    areas = TCShowScene.getAreas(scene)
    local perRow = math.min(TCShowScene.PENS.perRow, math.floor(TCShowScene.RING.length / TCShowScene.PENS.size))
    assertEquals(areas.pens.count, perRow)
    local backCount = math.min(perRow, 20 - perRow)
    assertEquals(areas.pens.back.count, backCount, "two rows at most")
    assertNear(areas.pens.back.vTo, areas.pens.vFrom, 0.001, "back to back")
    local pens = TCShowScene.getPens(scene)
    assertEquals(#pens, perRow + backCount)
    -- The first row faces the lane (+v), the second away from it, each
    -- pen's front hurdle its outer side.
    local _, firstV = toLocal(rect, pens[1].x, pens[1].z)
    local _, frontV = toLocal(rect, pens[1].frontX, pens[1].frontZ)
    assertNear(frontV, areas.pens.vTo, 0.001)
    assertTrue(math.cos(pens[1].yaw) > 0.99, "facing +v")
    local _, backV = toLocal(rect, pens[perRow + 1].frontX, pens[perRow + 1].frontZ)
    assertNear(backV, areas.pens.back.vFrom, 0.001)
    assertTrue(math.cos(pens[perRow + 1].yaw) < -0.99, "facing -v")
    assertTrue(firstV > backV)
    -- The hurdles: the second row's outer wall and its dividers more.
    local hurdles = #byKind(TCShowScene.layOut(scene).props, "penHurdle")
    scene.pens = perRow
    local oneRow = #byKind(TCShowScene.layOut(scene).props, "penHurdle")
    assertEquals(hurdles - oneRow, backCount + (backCount + 1))

    -- No room behind: one row only.
    local narrow = makeScene(60, 22)
    narrow.pens = 20
    assertEquals(TCShowScene.getAreas(narrow).pens.back, nil)
    assertTrue(#TCShowScene.getPens(narrow) <= perRow)
end)

test("pens: the ground under each row of pens is bared, a margin past its hurdles", function()
    setup()
    local scene, rect = makeScene()
    scene.pens = 4
    local areas = TCShowScene.getAreas(scene)
    local ground = TCShowScene.getPenGround(scene)
    assertEquals(#ground, 1, "one row")
    local margin = TCShowScene.PEN_GROUND_MARGIN
    local function bounds(corners)
        local uMin, uMax, vMin, vMax = math.huge, -math.huge, math.huge, -math.huge
        for _, corner in ipairs(corners) do
            local u, v = toLocal(rect, corner.x, corner.z)
            uMin, uMax, vMin, vMax = math.min(uMin, u), math.max(uMax, u), math.min(vMin, v), math.max(vMax, v)
        end
        return uMin, uMax, vMin, vMax
    end
    local uMin, uMax, vMin, vMax = bounds(ground[1])
    assertNear(uMax - uMin, 4 * TCShowScene.PENS.size + 2 * margin, 0.001, "the row's pens and the margin")
    assertNear(vMin, areas.pens.vFrom - margin, 0.001)
    assertNear(vMax, areas.pens.vTo + margin, 0.001)
    -- Every pen's middle on it.
    for _, pen in ipairs(TCShowScene.getPens(scene)) do
        local u, v = toLocal(rect, pen.x, pen.z)
        assertTrue(u > uMin and u < uMax and v > vMin and v < vMax)
    end

    -- Two rows: a rectangle each, the second as long as its own pens.
    local perRow = math.min(TCShowScene.PENS.perRow, math.floor(TCShowScene.RING.length / TCShowScene.PENS.size))
    scene.pens = perRow + 2
    areas = TCShowScene.getAreas(scene)
    ground = TCShowScene.getPenGround(scene)
    assertEquals(#ground, 2)
    uMin, uMax, vMin, vMax = bounds(ground[2])
    assertNear(uMax - uMin, 2 * TCShowScene.PENS.size + 2 * margin, 0.001)
    assertNear(vMin, areas.pens.back.vFrom - margin, 0.001)

    assertEquals(#TCShowScene.getPenGround(makeScene(40, 30)), 0, "no arena")
    assertEquals(#TCShowScene.getPenGround(makeScene(nil, nil, "auction")), 0, "not the show's")
end)

-- 182: a straw tile's side's middle (bit: TCShowScene.STRAW_FADE's), in the
-- rectangle's frame, as TCAuctionProps places the model: +z its forward
-- (sin yaw, cos yaw), +x its right (cos yaw, -sin yaw).
local function strawSide(rect, tile, bit)
    local F = TCShowScene.STRAW_FADE
    local fx, fz = math.sin(tile.yaw), math.cos(tile.yaw)
    local rx, rz = fz, -fx
    local dx, dz
    if bit == F.plusX then
        dx, dz = rx * tile.width * 0.5, rz * tile.width * 0.5
    elseif bit == F.minusX then
        dx, dz = -rx * tile.width * 0.5, -rz * tile.width * 0.5
    elseif bit == F.plusZ then
        dx, dz = fx * tile.length * 0.5, fz * tile.length * 0.5
    else
        dx, dz = -fx * tile.length * 0.5, -fz * tile.length * 0.5
    end
    return toLocal(rect, tile.x + dx, tile.z + dz)
end

-- Checks a scene's straw: the tiles fill each bed exactly, and a tile's side
-- is faded exactly when it's on its bed's outer edge (never the two rows'
-- shared wall).
local function checkStraw(scene, rect)
    local areas = TCShowScene.getAreas(scene)
    local pens = areas.pens
    local margin = TCShowScene.STRAW.margin
    local tiles = byKind(TCShowScene.layOut(scene).props, "penStraw")
    assertTrue(#tiles > 0)
    local function dOf(u)
        return (u - scene.nearEdge) * -scene.nearSign
    end
    local beds = { { count = pens.count, vFrom = pens.back ~= nil and pens.vFrom or pens.vFrom - margin,
        vTo = pens.vTo + margin, edges = { vFrom = pens.back == nil, vTo = true } } }
    if pens.back ~= nil then
        table.insert(beds, { count = pens.back.count, vFrom = pens.back.vFrom - margin, vTo = pens.back.vTo,
            edges = { vFrom = true, vTo = false } })
    end
    local area = 0
    for _, bed in ipairs(beds) do
        bed.dFrom, bed.dTo = pens.dFrom - margin, pens.dFrom + bed.count * pens.size + margin
        area = area + (bed.dTo - bed.dFrom) * (bed.vTo - bed.vFrom)
    end
    local tileArea = 0
    for _, tile in ipairs(tiles) do
        tileArea = tileArea + tile.width * tile.length
        assertNear(tile.width, tile.scaleX * TCShowScene.STRAW.tile, 0.001, "scaled to fit")
        assertNear(tile.length, tile.scaleZ * TCShowScene.STRAW.tile, 0.001)
        assertTrue(tile.scaleX > 0.75 and tile.scaleX < 1.35 and tile.scaleZ > 0.75 and tile.scaleZ < 1.35,
            "never stretched far")
        local cu, cv = toLocal(rect, tile.x, tile.z)
        local bed = nil
        for _, candidate in ipairs(beds) do
            local d = dOf(cu)
            if d > candidate.dFrom and d < candidate.dTo and cv > candidate.vFrom and cv < candidate.vTo then
                bed = candidate
            end
        end
        assertTrue(bed ~= nil, "in a bed")
        for _, bit in pairs(TCShowScene.STRAW_FADE) do
            local u, v = strawSide(rect, tile, bit)
            local d = dOf(u)
            local outer = math.abs(d - bed.dFrom) < 0.001 or math.abs(d - bed.dTo) < 0.001 or
                (bed.edges.vFrom and math.abs(v - bed.vFrom) < 0.001) or (bed.edges.vTo and math.abs(v - bed.vTo) < 0.001)
            local faded = math.floor(tile.fade / bit) % 2 == 1
            assertEquals(faded, outer, "faded only on the bed's outer edge")
        end
    end
    assertNear(tileArea, area, 0.01, "the beds filled, no overlap")
    return tiles
end

test("straw: a bed under the pens in tiles, ragged only round its outside, whichever way the showground runs", function()
    setup()
    local scene, rect = makeScene()
    scene.pens = 4
    checkStraw(scene, rect)
    -- Its edge past the bare ground's, so the ragged edge runs onto grass.
    assertTrue(TCShowScene.STRAW.margin > TCShowScene.PEN_GROUND_MARGIN)
    -- Two rows: two beds meeting at the shared wall, unfaded there.
    local perRow = math.min(TCShowScene.PENS.perRow, math.floor(TCShowScene.RING.length / TCShowScene.PENS.size))
    scene.pens = perRow + 3
    checkStraw(scene, rect)
    -- Turned, and with the entrance at the other end (the arena run the
    -- other way along u).
    local turned, turnedRect = makeScene(nil, nil, nil, nil, 0.7)
    turned.pens = 5
    checkStraw(turned, turnedRect)
    local flipped = { cx = 100, cz = 50, angle = 0, halfU = 60, halfV = 30 }
    local layout = TCAuctionLayout.layOutOpenRect(flipped, { x = 100 - 70, z = 50 })
    local other = TCAuctionLayout.getScene(layout, { x = 100 - 70, z = 50 }, 99)
    other.dressing = "show"
    other.pens = 6
    assertTrue(other.nearSign ~= scene.nearSign, "the other way round")
    checkStraw(other, flipped)

    assertEquals(#byKind(TCShowScene.layOut(makeScene(40, 30)).props, "penStraw"), 0, "no arena")
end)

test("pens: an animal in each pen it's there for, facing out, its rosettes along the front hurdle", function()
    setup()
    local scene, rect = makeScene()
    scene.pens = 4
    local pens = {
        present("COW_HOLSTEIN", { placing = 1, champion = true }),
        { subTypeName = "COW_ANGUS", age = 20 },                   -- not there yet
        present("SHEEP_LANDRACE", { placing = 4 }),
        {},                                                        -- empty
        present("COW_ANGUS"),                                      -- past the scene's pens
    }
    local props = TCShowScene.layOutPens(scene, pens)
    local animals, rosettes = byKind(props, "animal"), byKind(props, "rosette")
    assertEquals(#animals, 2)
    assertEquals(animals[1].pen, 1)
    assertEquals(animals[1].subTypeName, "COW_HOLSTEIN")
    assertEquals(animals[1].age, 20)
    assertEquals(animals[1].variation, 2)
    assertEquals(animals[2].pen, 3)
    local places = TCShowScene.getPens(scene)
    assertNear(animals[1].x, places[1].x, 0.001)
    assertNear(animals[1].yaw, places[1].yaw, 0.001)

    assertEquals(#rosettes, 3)
    assertEquals(rosettes[1].rosette, TCShowScene.ROSETTE_CHAMPION, "the champion's first")
    assertEquals(rosettes[2].rosette, "first")
    assertEquals(rosettes[3].rosette, "commended")
    assertEquals(rosettes[3].pen, 3)
    local hurdle = TCShowScene.SIZES.penHurdle
    local lastD = nil
    for i = 1, 2 do
        local prop = rosettes[i]
        assertNear(prop.x, places[1].frontX, 0.001, "on the pen's front hurdle's footprint")
        assertEquals(prop.width, hurdle.length)
        assertEquals(prop.length, hurdle.width)
        local u = rosetteLocal(rect, prop)
        local d = scene.nearEdge - u
        if lastD ~= nil then
            assertNear(d - lastD, TCShowScene.ROSETTE.spacing, 0.001, "spaced, from the entrance end")
        end
        lastD = d
    end
    -- Every prop names what it shows, each name once.
    local keys = {}
    for _, prop in ipairs(props) do
        assertTrue(prop.key ~= nil and not keys[prop.key])
        keys[prop.key] = true
    end
    assertEquals(#TCShowScene.layOutPens(makeScene(40, 30), pens), 0, "no arena")
    assertEquals(#TCShowScene.layOutPens(makeScene(nil, nil, "auction"), pens), 0, "not the show's")
end)

test("pens: a second-row pen's rosettes hang on its outer front, in the same order from the entrance end", function()
    setup()
    local scene, rect = makeScene()
    local perRow = math.min(TCShowScene.PENS.perRow, math.floor(TCShowScene.RING.length / TCShowScene.PENS.size))
    scene.pens = perRow + 1
    local pens = {}
    for i = 1, perRow do
        pens[i] = {}
    end
    pens[perRow + 1] = present("COW_HOLSTEIN", { placing = 2, champion = true })
    local rosettes = byKind(TCShowScene.layOutPens(scene, pens), "rosette")
    assertEquals(#rosettes, 2)
    local d1 = scene.nearEdge - rosetteLocal(rect, rosettes[1])
    local d2 = scene.nearEdge - rosetteLocal(rect, rosettes[2])
    assertNear(d2 - d1, TCShowScene.ROSETTE.spacing, 0.001)
    local _, v = toLocal(rect, rosettes[1].x, rosettes[1].z)
    assertNear(v, TCShowScene.getAreas(scene).pens.back.vFrom, 0.001)
end)
