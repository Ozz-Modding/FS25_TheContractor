-- 134: the auction crowd (TCAuctionCrowd): the largest rectangle
-- inset in a field's polygon, the walking loops inside it, the standing
-- groups between them, and the people taken from the base maps' looks.

local function setup()
    local world = stubs.install()
    world:load("src/util/TCAuctionCrowd.lua")
    world:load("src/util/TCAuctionScene.lua")
    return world
end

local function rectPolygon(x1, z1, x2, z2)
    return { { x = x1, z = z1 }, { x = x2, z = z1 }, { x = x2, z = z2 }, { x = x1, z = z2 } }
end

-- Every point at least `margin` inside an axis-aligned box.
local function allInsideBox(points, x1, z1, x2, z2, margin)
    for _, p in ipairs(points) do
        if p.x < x1 + margin or p.x > x2 - margin or p.z < z1 + margin or p.z > z2 - margin then
            return false
        end
    end
    return true
end

test("the largest rectangle on a grid", function()
    setup()
    local rows = {
        "..........",
        ".####.....",
        ".####.###.",
        ".#######..",
        "..........",
    }
    local grid = {}
    for r, line in ipairs(rows) do
        grid[r] = {}
        for c = 1, #line do
            grid[r][c] = line:sub(c, c) == "#"
        end
    end
    local r1, r2, c1, c2 = TCAuctionCrowd.largestRectangle(grid, #rows, 10)
    -- The 3 x 4 block on the left (12) beats the bottom row's 7 and the
    -- right-hand 2 x 2.
    assertEquals(r1, 2)
    assertEquals(r2, 4)
    assertEquals(c1, 2)
    assertEquals(c2, 5)
end)

test("an empty grid has no rectangle", function()
    setup()
    local grid = { { false, false }, { false, false } }
    assertEquals(TCAuctionCrowd.largestRectangle(grid, 2, 2), nil)
end)

test("a rectangular field: nearly all of it, inset, long side first", function()
    setup()
    local layout = TCAuctionCrowd.LAYOUT
    local rect = TCAuctionCrowd.findLargestRect(rectPolygon(0, 0, 100, 200))
    assertTrue(rect ~= nil)
    assertTrue(rect.halfU >= rect.halfV, "u is the long side")
    -- Inset by about the inset each side, give or take a grid cell.
    assertNear(rect.halfU * 2, 200 - 2 * layout.inset, layout.step * 2 + 1)
    assertNear(rect.halfV * 2, 100 - 2 * layout.inset, layout.step * 2 + 1)
    assertNear(rect.cx, 50, layout.step)
    assertNear(rect.cz, 100, layout.step)
end)

test("an L-shaped field: the rectangle is in its bigger arm", function()
    setup()
    -- A 200 x 60 arm along x, and a 60 x 120 arm going up from its left end.
    local polygon = {
        { x = 0, z = 0 }, { x = 200, z = 0 }, { x = 200, z = 60 },
        { x = 60, z = 60 }, { x = 60, z = 180 }, { x = 0, z = 180 },
    }
    local rect = TCAuctionCrowd.findLargestRect(polygon)
    assertTrue(rect ~= nil)
    assertTrue(rect.cz < 60, "in the long arm")
    assertTrue(rect.halfU * 2 > 150, "along it")
    for _, loop in ipairs(TCAuctionCrowd.buildLoops(rect)) do
        for _, p in ipairs(loop.points) do
            assertTrue(TCAuctionCrowd.pointInPolygon(p.x, p.z, polygon), "loop point inside the field")
        end
    end
end)

test("a rotated field: the rectangle turns with it", function()
    setup()
    local angle = math.rad(30)
    local function rot(u, v)
        return { x = u * math.cos(angle) - v * math.sin(angle), z = u * math.sin(angle) + v * math.cos(angle) }
    end
    local polygon = { rot(0, 0), rot(200, 0), rot(200, 80), rot(0, 80) }
    local rect = TCAuctionCrowd.findLargestRect(polygon)
    assertTrue(rect ~= nil)
    -- At 30 degrees (a tried angle) it should fit nearly as well as unrotated.
    assertTrue(rect.halfU * 2 > 170, "long side kept")
    assertTrue(rect.halfV * 2 > 50, "short side kept")
    local dirAngle = math.deg(rect.angle) % 180
    assertNear(dirAngle, 30, 0.01)
end)

test("loops: concentric, inside the rectangle, as many as fit", function()
    setup()
    local layout = TCAuctionCrowd.LAYOUT
    local polygon = rectPolygon(0, 0, 100, 200)
    local rect = TCAuctionCrowd.findLargestRect(polygon)
    local loops = TCAuctionCrowd.buildLoops(rect)
    -- halfV about 42: loops at 4, 18 and 32 in, the next (46) doesn't fit.
    assertEquals(#loops, 3)
    for k, loop in ipairs(loops) do
        assertTrue(#loop.points >= 8)
        assertTrue(allInsideBox(loop.points, 0, 0, 100, 200, layout.inset), "loop " .. k .. " inside the inset")
        if k > 1 then
            assertNear(loops[k - 1].halfV - loop.halfV, layout.laneGap, 0.001)
        end
    end
end)

test("loops: edit points are spaced no wider than asked, with no repeats", function()
    setup()
    local layout = TCAuctionCrowd.LAYOUT
    local rect = { cx = 0, cz = 0, angle = 0, halfU = 60, halfV = 30 }
    local loop = TCAuctionCrowd.buildLoops(rect)[1]
    local points = loop.points
    for i = 1, #points do
        local a, b = points[i], points[i % #points + 1]
        local d = math.sqrt((a.x - b.x) ^ 2 + (a.z - b.z) ^ 2)
        assertTrue(d > 0.01, "no repeated point at " .. i)
        assertTrue(d <= layout.pointSpacing + 0.001, "gap at " .. i)
    end
end)

test("a field too small for a loop gets none", function()
    setup()
    local rect = TCAuctionCrowd.findLargestRect(rectPolygon(0, 0, 20, 20))
    assertEquals(#TCAuctionCrowd.buildLoops(rect), 0)
end)

test("standing groups sit in the lane between loops, facing their middle", function()
    setup()
    local layout = TCAuctionCrowd.LAYOUT
    local rect = { cx = 0, cz = 0, angle = 0, halfU = 90, halfV = 40 }
    local loops = TCAuctionCrowd.buildLoops(rect)
    assertTrue(#loops >= 2)
    local spots = TCAuctionCrowd.buildStandingSpots(rect, loops, 1000)
    assertTrue(#spots > 0)
    local laneV = rect.halfV - layout.edgeMargin - layout.laneGap / 2
    for _, spot in ipairs(spots) do
        -- Within a group's radius of one of the two lanes.
        assertNear(math.abs(spot.z), laneV, layout.clusterRadius + 0.001)
        assertTrue(math.abs(spot.x) <= rect.halfU, "within the rectangle")
        -- Facing inwards: one step along the yaw gets nearer the lane's line
        -- or along it (the group's middle is on the line).
        local fx, fz = math.sin(spot.yaw), math.cos(spot.yaw)
        local middleZ = spot.z > 0 and laneV or -laneV
        local before = math.abs(spot.z - middleZ)
        local after = math.abs(spot.z + fz * 0.1 - middleZ)
        assertTrue(after <= before + 0.0001, "faces its group")
        assertNear(fx * fx + fz * fz, 1, 0.0001)
    end
end)

test("standing spots stop at the number asked for", function()
    setup()
    local rect = { cx = 0, cz = 0, angle = 0, halfU = 90, halfV = 40 }
    local loops = TCAuctionCrowd.buildLoops(rect)
    assertEquals(#TCAuctionCrowd.buildStandingSpots(rect, loops, 7), 7)
    assertEquals(#TCAuctionCrowd.buildStandingSpots(rect, loops, 0), 0)
end)

test("one loop: the groups stand down its middle", function()
    setup()
    local rect = { cx = 10, cz = 20, angle = 0, halfU = 40, halfV = 10 }
    local loops = TCAuctionCrowd.buildLoops(rect)
    assertEquals(#loops, 1)
    local spots = TCAuctionCrowd.buildStandingSpots(rect, loops, 1000)
    assertTrue(#spots > 0)
    for _, spot in ipairs(spots) do
        assertNear(spot.z, 20, TCAuctionCrowd.LAYOUT.clusterRadius + 0.001)
    end
end)

test("people are taken from the looks in turn", function()
    setup()
    local templates = { { id = "a" }, { id = "b" }, { id = "c" } }
    local picked = TCAuctionCrowd.pickTemplates(templates, 7)
    assertEquals(#picked, 7)
    local ids = {}
    for i, t in ipairs(picked) do
        ids[i] = t.id
    end
    assertEquals(table.concat(ids), "abcabca")
    assertEquals(#TCAuctionCrowd.pickTemplates({}, 5), 0)
end)

test("point in polygon", function()
    setup()
    local square = rectPolygon(0, 0, 10, 10)
    assertTrue(TCAuctionCrowd.pointInPolygon(5, 5, square))
    assertTrue(not TCAuctionCrowd.pointInPolygon(15, 5, square))
    assertTrue(not TCAuctionCrowd.pointInPolygon(-1, -1, square))
end)


test("the crowd plan: standers as far as the spots go, everyone else walks", function()
    setup()
    local plan = TCAuctionCrowd.planCrowd({ 200, 100 }, 10, 60)
    -- 40% of 60 is 24, but there are only 10 spots.
    assertEquals(plan.standers, 10)
    assertEquals(#plan.walkers, 50)
    assertEquals(plan.lanes, 4)
    local few = TCAuctionCrowd.planCrowd({ 200 }, 50, 10)
    assertEquals(few.standers, 4)
    assertEquals(#few.walkers, 6)
end)

test("the crowd plan: walkers shared between the lanes by length, both ways round", function()
    setup()
    local plan = TCAuctionCrowd.planCrowd({ 300, 100 }, 0, 41)
    local perLane = {}
    for _, w in ipairs(plan.walkers) do
        local key = w.loop .. ":" .. w.direction
        perLane[key] = (perLane[key] or 0) + 1
    end
    -- 41 over lanes of 300, 300, 100, 100: about 15.4, 15.4, 5.1, 5.1.
    assertEquals(perLane["1:1"] + perLane["1:-1"] + perLane["2:1"] + perLane["2:-1"], 41)
    assertTrue(perLane["1:1"] >= 15 and perLane["1:1"] <= 16)
    assertTrue(perLane["2:-1"] >= 5 and perLane["2:-1"] <= 6)
end)

test("the crowd plan: a lane's walkers share a speed and are spaced evenly", function()
    setup()
    local plan = TCAuctionCrowd.planCrowd({ 120 }, 0, 8)
    local lane = {}
    for _, w in ipairs(plan.walkers) do
        if w.direction == 1 then
            table.insert(lane, w)
        end
    end
    assertEquals(#lane, 4)
    table.sort(lane, function(a, b)
        return a.offset < b.offset
    end)
    for i, w in ipairs(lane) do
        assertNear(w.speed, lane[1].speed, 0.0001)
        assertTrue(w.speed >= TCAuctionCrowd.WALK_SPEED_MIN and w.speed <= TCAuctionCrowd.WALK_SPEED_MAX)
        if i > 1 then
            assertNear(w.offset - lane[i - 1].offset, 30, 0.0001)
        end
    end
end)

test("the crowd plan is the same each time", function()
    setup()
    local a = TCAuctionCrowd.planCrowd({ 150, 90 }, 12, 50)
    local b = TCAuctionCrowd.planCrowd({ 150, 90 }, 12, 50)
    assertEquals(#a.walkers, #b.walkers)
    for i = 1, #a.walkers do
        assertEquals(a.walkers[i].offset, b.walkers[i].offset)
        assertEquals(a.walkers[i].speed, b.walkers[i].speed)
    end
end)

test("a walker goes round its loop and wraps, either way", function()
    setup()
    local forward = { offset = 90, speed = 2, direction = 1 }
    assertNear(TCAuctionCrowd.walkerDistance(forward, 0, 100), 90, 0.0001)
    assertNear(TCAuctionCrowd.walkerDistance(forward, 10, 100), 10, 0.0001)
    local back = { offset = 5, speed = 2, direction = -1 }
    assertNear(TCAuctionCrowd.walkerDistance(back, 5, 100), 95, 0.0001)
    assertEquals(TCAuctionCrowd.walkerDistance(back, 5, 0), 0)
end)

test("the two lanes of a loop pass on either side, each facing its way", function()
    setup()
    local offset = TCAuctionCrowd.LANE_OFFSET
    -- The loop runs along +z here.
    local x1, z1, yaw1 = TCAuctionCrowd.getLanePosition(0, 0, 0, 2, 1)
    local x2, z2, yaw2 = TCAuctionCrowd.getLanePosition(0, 0, 0, 2, -1)
    assertNear(math.abs(x1 - x2), 2 * offset, 0.0001)
    assertNear(z1, 0, 0.0001)
    assertNear(z2, 0, 0.0001)
    assertNear(math.abs(yaw1 - yaw2), math.pi, 0.0001)
    -- Facing along the yaw: sin/cos of it is the walking direction.
    assertNear(math.cos(yaw1), 1, 0.0001)
    assertNear(math.cos(yaw2), -1, 0.0001)
end)

test("a path's length is the distance round its points, back to the first", function()
    setup()
    local path = TCAuctionCrowd.buildPath(rectPolygon(0, 0, 10, 4))
    assertNear(path.length, 28, 0.0001)
    assertNear(path.distances[2], 10, 0.0001)
    assertNear(path.distances[5], 28, 0.0001)
end)

test("a point along a path, wrapped either way, with its direction", function()
    setup()
    local path = TCAuctionCrowd.buildPath(rectPolygon(0, 0, 10, 4))
    local x, z, dx, dz = TCAuctionCrowd.getPathPoint(path, 5)
    assertNear(x, 5, 0.0001)
    assertNear(z, 0, 0.0001)
    assertTrue(dx > 0 and math.abs(dz) < 0.0001, "along the first side")
    x, z = TCAuctionCrowd.getPathPoint(path, 12)
    assertNear(x, 10, 0.0001)
    assertNear(z, 2, 0.0001)
    x, z = TCAuctionCrowd.getPathPoint(path, 28 + 5)
    assertNear(x, 5, 0.0001)
    x, z = TCAuctionCrowd.getPathPoint(path, -2)
    assertNear(x, 0, 0.0001)
    assertNear(z, 2, 0.0001)
end)

-- The glitch in game: on a small inner loop (tight corners), walkers slid
-- back and then on. Walking a loop by distance, both lanes keep moving the
-- way they face at an even pace, corners included.
test("walkers never step backwards or jump, even round a small loop's corners", function()
    setup()
    local layout = {}
    for key, value in pairs(TCAuctionCrowd.LAYOUT) do
        layout[key] = value
    end
    layout.laneGap = 6
    local rect = TCAuctionCrowd.findLargestRect(rectPolygon(0, 0, 120, 56), layout)
    local loops = TCAuctionCrowd.buildLoops(rect, layout)
    assertTrue(#loops >= 2, "an inner loop")
    local step = 0.05
    for _, loop in ipairs(loops) do
        local path = TCAuctionCrowd.buildPath(loop.points)
        for _, direction in ipairs({ 1, -1 }) do
            local walker = { offset = 0, speed = 1, direction = direction }
            local lastX, lastZ
            for k = 0, math.floor(path.length / step) + 20 do
                local d = TCAuctionCrowd.walkerDistance(walker, k * step, path.length)
                local px, pz, dx, dz = TCAuctionCrowd.getPathPoint(path, d)
                local x, z, yaw = TCAuctionCrowd.getLanePosition(px, pz, dx, dz, direction)
                if lastX ~= nil then
                    local mx, mz = x - lastX, z - lastZ
                    local moved = math.sqrt(mx * mx + mz * mz)
                    assertTrue(moved < step * 2, "no jump")
                    -- Forward is (sin yaw, cos yaw).
                    assertTrue(mx * math.sin(yaw) + mz * math.cos(yaw) > 0, "never backwards")
                end
                lastX, lastZ = x, z
            end
        end
    end
end)

-- 140: the crowd's hours and size ----------------------------------------------------------

-- How many of the figures are there at an hour.
local function presentAt(ranks, hour)
    local share = TCAuctionCrowd.getShare(hour)
    local count = 0
    for _, rank in ipairs(ranks) do
        if rank < share then
            count = count + 1
        end
    end
    return count
end

test("the crowd's hours: nobody before 08:00, busiest late morning and round the closes, a handful by the gate after", function()
    setup()
    local categories = {}
    for i = 1, 6 do
        categories[i] = TCAuctionScene.SPOT.GATE
    end
    local ranks = TCAuctionCrowd.rankFigures(categories, 100)
    assertEquals(presentAt(ranks, 0), 0)
    assertEquals(presentAt(ranks, 7.5), 0)
    local arriving = presentAt(ranks, 8)
    assertTrue(arriving > 0 and arriving < 30, "a few at 08:00")
    assertTrue(presentAt(ranks, 9.5) > arriving, "more through the morning")
    assertEquals(presentAt(ranks, 11.5), 100)
    local afternoon = presentAt(ranks, 14)
    assertTrue(afternoon < 90 and afternoon > 40, "quieter after lunch")
    assertTrue(presentAt(ranks, 17.5) > 90, "busy round the closes")
    -- After the last close, only the gate's.
    for _, hour in ipairs({ 20, 22, 23.9 }) do
        assertEquals(presentAt(ranks, hour), 6)
    end
    -- The gate's are there whenever anyone is.
    local share = TCAuctionCrowd.getShare(8)
    for i = 1, 6 do
        assertTrue(ranks[i] < share)
    end
end)

test("the crowd thins evenly: the ones who go first aren't all one end of the list", function()
    setup()
    local ranks = TCAuctionCrowd.rankFigures({}, 100)
    local share = TCAuctionCrowd.getShare(14)
    local firstHalf, secondHalf = 0, 0
    for i, rank in ipairs(ranks) do
        if rank < share then
            if i <= 50 then
                firstHalf = firstHalf + 1
            else
                secondHalf = secondHalf + 1
            end
        end
    end
    assertTrue(math.abs(firstHalf - secondHalf) <= 6)
end)

test("the food area's busy from breakfast till the evening thins out", function()
    setup()
    local categories = {}
    for i = 1, 3 do
        categories[i] = TCAuctionScene.SPOT.GATE
    end
    for i = 4, 16 do
        categories[i] = TCAuctionScene.SPOT.FOOD
    end
    local ranks = TCAuctionCrowd.rankFigures(categories, 100)
    local function foodAt(hour)
        local share, count = TCAuctionCrowd.getShare(hour), 0
        for i = 4, 16 do
            if ranks[i] < share then
                count = count + 1
            end
        end
        return count
    end
    assertTrue(foodAt(8) > 0, "some at breakfast")
    for _, hour in ipairs({ 8.5, 11.5, 14, 17.5 }) do
        assertEquals(foodAt(hour), 13)
    end
    assertEquals(foodAt(20), 0)
    -- The gate's still go last.
    for i = 1, 3 do
        for j = 4, 16 do
            assertTrue(ranks[i] < ranks[j])
        end
    end
end)

test("the share moves smoothly between the hours given", function()
    setup()
    assertNear(TCAuctionCrowd.getShare(11.5), 1, 0.0001)
    assertNear(TCAuctionCrowd.getShare(12), 0.95, 0.0001)
    assertNear(TCAuctionCrowd.getShare(30), TCAuctionCrowd.GATE_SHARE, 0.0001)
end)

test("an auction's crowd grows with its lots, within the frame-rate range", function()
    setup()
    assertEquals(TCAuctionCrowd.getAuctionPeople(0), TCAuctionCrowd.AUCTION_MIN)
    assertEquals(TCAuctionCrowd.getAuctionPeople(120), 100)
    assertEquals(TCAuctionCrowd.getAuctionPeople(1000), TCAuctionCrowd.AUCTION_MAX)
    assertTrue(TCAuctionCrowd.getAuctionPeople(60) < TCAuctionCrowd.getAuctionPeople(100))
end)

test("the crowd plan takes a standing share when given one", function()
    setup()
    local plan = TCAuctionCrowd.planCrowd({ 100 }, 200, 100, 0.5)
    assertEquals(plan.standers, 50)
    assertEquals(#plan.walkers, 50)
end)
