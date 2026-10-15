-- Joyrider ruts (072): the car's path (car-like curves, from the edge,
-- comes back after leaving, length by field size), the wheel tracks,
-- clipping to the field, and the painting through vanilla's area functions.

-- A seeded random in 0..1, so a run is repeatable.
local function seeded(seed)
    local state = seed
    return function()
        state = (state * 1103515245 + 12345) % 2147483648
        return state / 2147483648
    end
end

local function rectangle(x1, z1, x2, z2)
    return { { x1, z1 }, { x2, z1 }, { x2, z2 }, { x1, z2 } }
end

-- Distance from (x, z) to the nearest boundary edge.
local function distanceToEdge(x, z, boundary)
    local best = math.huge
    for i = 1, #boundary do
        local ax, az = boundary[i][1], boundary[i][2]
        local bx, bz = boundary[i % #boundary + 1][1], boundary[i % #boundary + 1][2]
        local dx, dz = bx - ax, bz - az
        local t = math.max(0, math.min(1, ((x - ax) * dx + (z - az) * dz) / (dx * dx + dz * dz)))
        local px, pz = ax + dx * t, az + dz * t
        best = math.min(best, math.sqrt((x - px) ^ 2 + (z - pz) ^ 2))
    end
    return best
end

local function load()
    local world = stubs.install()
    world:load("src/util/TCJoyriderRuts.lua")
    return world
end

test("point in polygon, area and centre", function()
    load()
    local square = rectangle(0, 0, 100, 100)
    assertTrue(TCJoyriderRuts.isPointInside(50, 50, square))
    assertTrue(not TCJoyriderRuts.isPointInside(150, 50, square))
    assertTrue(not TCJoyriderRuts.isPointInside(-1, 50, square))

    local area, cx, cz = TCJoyriderRuts.getAreaAndCentre(square)
    assertNear(area, 10000, 0.001)
    assertNear(cx, 50, 0.001)
    assertNear(cz, 50, 0.001)

    -- Clockwise gives the same answer.
    local reversed = { { 0, 0 }, { 0, 100 }, { 100, 100 }, { 100, 0 } }
    area, cx, cz = TCJoyriderRuts.getAreaAndCentre(reversed)
    assertNear(area, 10000, 0.001)
    assertNear(cx, 50, 0.001)
end)

test("the path starts on the field's edge and drives like a car", function()
    load()
    local field = rectangle(0, 0, 200, 150)
    local step = TCJoyriderRuts.STEP
    local maxChange = TCJoyriderRuts.CURVATURE_RATE * step + 1e-9

    for seed = 1, 40 do
        local points = TCJoyriderRuts.generatePath(field, seeded(seed))
        assertTrue(#points > 10, "seed " .. seed .. ": a real path")
        assertTrue(distanceToEdge(points[1].x, points[1].z, field) < 0.01, "seed " .. seed .. ": starts on the edge")

        for i = 2, #points do
            local a, b = points[i - 1], points[i]
            assertTrue(math.abs(b.curvature) <= TCJoyriderRuts.MAX_CURVATURE + 1e-9,
                "seed " .. seed .. ": never tighter than the tightest turn")
            assertTrue(math.abs(b.curvature - a.curvature) <= maxChange,
                "seed " .. seed .. ": steering eases rather than snapping")
            assertNear(math.sqrt((b.x - a.x) ^ 2 + (b.z - a.z) ^ 2), step, 1e-6, "steady steps")
        end
    end
end)

test("the first stretch heads into the field", function()
    load()
    local field = rectangle(0, 0, 200, 150)
    for seed = 1, 40 do
        local points = TCJoyriderRuts.generatePath(field, seeded(seed))
        -- A few metres in, it's in the field (start spread is at most 40 degrees off the middle).
        assertTrue(points[11].inside, "seed " .. seed .. ": 5 m in, inside the field")
    end
end)

test("leaving the field, it comes back in", function()
    load()
    -- A narrow field, so it goes out a lot.
    local field = rectangle(0, 0, 300, 40)
    local excursions = 0
    for seed = 1, 40 do
        local points = TCJoyriderRuts.generatePath(field, seeded(seed))
        local outsideRun = 0
        for i = 2, #points do
            if points[i].inside then
                if outsideRun > 0 then
                    excursions = excursions + 1
                end
                outsideRun = 0
            else
                outsideRun = outsideRun + TCJoyriderRuts.STEP
                -- Out up to 25 m, an 8.3 m radius U-turn (0.6 of full lock), then back to a point 20 m in.
                assertTrue(outsideRun < 100, "seed " .. seed .. ": back in within 100 m of leaving")
            end
        end
        assertTrue(points[#points].inside or outsideRun < 100, "seed " .. seed)
    end
    assertTrue(excursions > 0, "it does leave a narrow field sometimes")
end)

test("the coverage grid", function()
    load()
    -- 290 x 290 m (8.41 ha): 8 * 8.41 ^ 0.25 = 13.62 m cells, 22 x 22. The last
    -- row and column hang over the edge (middles outside), so 21 x 21 count.
    local grid = TCJoyriderRuts.createGrid(rectangle(0, 0, 290, 290), 84100)
    assertNear(grid.cellSize, 8 * math.sqrt(2.9), 1e-6)
    assertEquals(grid.cols, 22)
    assertEquals(grid.rows, 22)
    assertEquals(grid.eligibleCount, 441)
    assertEquals(TCJoyriderRuts.getCoverage(grid), 0)

    TCJoyriderRuts.visitGrid(grid, 1, 1)
    TCJoyriderRuts.visitGrid(grid, 2, 2) -- same cell
    TCJoyriderRuts.visitGrid(grid, 280, 280)
    TCJoyriderRuts.visitGrid(grid, 289, 289) -- an overhanging cell, not counted
    TCJoyriderRuts.visitGrid(grid, -50, 50) -- off the grid
    assertNear(TCJoyriderRuts.getCoverage(grid), 2 / 441, 1e-9)

    -- A small field doesn't go below the minimum cell size.
    local small = TCJoyriderRuts.createGrid(rectangle(0, 0, 30, 30), 900)
    assertEquals(small.cellSize, TCJoyriderRuts.MIN_CELL_SIZE)
    -- Nor does a big one go above the maximum.
    local big = TCJoyriderRuts.createGrid(rectangle(0, 0, 3000, 3000), 9000000)
    assertEquals(big.cellSize, TCJoyriderRuts.MAX_CELL_SIZE)

    -- An L shape: the cells in the missing corner don't count.
    local lShape = { { 0, 0 }, { 100, 0 }, { 100, 50 }, { 50, 50 }, { 50, 100 }, { 0, 100 } }
    local area = TCJoyriderRuts.getAreaAndCentre(lShape)
    local lGrid = TCJoyriderRuts.createGrid(lShape, area)
    assertTrue(lGrid.eligibleCount < lGrid.cols * lGrid.rows, "corner cells left out")
end)

test("it keeps driving until it has covered its target share of the field", function()
    load()
    local fields = {
        rectangle(0, 0, 100, 100),
        rectangle(0, 0, 250, 180),
        rectangle(0, 0, 400, 300),
        rectangle(0, 0, 300, 40),
        { { 0, 0 }, { 200, 0 }, { 200, 80 }, { 80, 80 }, { 80, 200 }, { 0, 200 } },
    }
    for f, boundary in ipairs(fields) do
        for seed = 1, 20 do
            local points, stats = TCJoyriderRuts.generatePath(boundary, seeded(seed))
            local inside = 0
            for _, point in ipairs(points) do
                inside = inside + (point.inside and 1 or 0)
            end
            local insideLength = (inside - 1) * TCJoyriderRuts.STEP
            assertTrue(stats.targetCoverage >= TCJoyriderRuts.COVERAGE_SHARE[1] and
                stats.targetCoverage <= TCJoyriderRuts.COVERAGE_SHARE[2], "target in range")
            assertTrue(stats.coverage >= stats.targetCoverage or insideLength >= TCJoyriderRuts.MAX_LENGTH - 1,
                string.format("field %d seed %d: covered %.2f of %.2f", f, seed, stats.coverage, stats.targetCoverage))
            -- Plus the drive off the field after it.
            assertTrue(insideLength <= TCJoyriderRuts.MAX_LENGTH + 300, "never far past the longest drive")
        end
    end
end)

test("the damage is spread over the field, not one corner", function()
    load()
    -- Each quarter of a 200 x 200 m field gets some of the path, nearly every time.
    local boundary = rectangle(0, 0, 200, 200)
    local missed = 0
    for seed = 1, 40 do
        local points = TCJoyriderRuts.generatePath(boundary, seeded(seed))
        local quarters = {}
        for _, point in ipairs(points) do
            if point.inside then
                quarters[(point.x < 100 and 0 or 1) + (point.z < 100 and 0 or 2)] = true
            end
        end
        for quarter = 0, 3 do
            if not quarters[quarter] then
                missed = missed + 1
            end
        end
    end
    assertTrue(missed <= 4, "at most a handful of the 160 quarters untouched, got " .. missed)
end)

test("a bigger field gets a longer drive", function()
    load()
    local function insideLength(boundary, seed)
        local points = TCJoyriderRuts.generatePath(boundary, seeded(seed))
        local count = 0
        for _, point in ipairs(points) do
            count = count + (point.inside and 1 or 0)
        end
        return count * TCJoyriderRuts.STEP
    end
    local small, big = 0, 0
    for seed = 1, 10 do
        small = small + insideLength(rectangle(0, 0, 100, 100), seed)
        big = big + insideLength(rectangle(0, 0, 400, 300), seed)
    end
    assertTrue(big > small * 2, string.format("12x the area, %.0f m vs %.0f m", big, small))
    assertTrue(small / 10 >= TCJoyriderRuts.MIN_LENGTH)
end)

test("when it's done it drives off the field, by a nearby edge", function()
    load()
    local fields = {
        rectangle(0, 0, 100, 100),
        rectangle(0, 0, 250, 180),
        rectangle(0, 0, 300, 40),
        { { 0, 0 }, { 200, 0 }, { 200, 80 }, { 80, 80 }, { 80, 200 }, { 0, 200 } },
    }
    for f, boundary in ipairs(fields) do
        for seed = 1, 20 do
            local points, stats = TCJoyriderRuts.generatePath(boundary, seeded(seed))
            local label = string.format("field %d seed %d", f, seed)
            assertTrue(stats.exited, label .. ": exited")
            assertTrue(not points[#points].inside, label .. ": ends outside")
            assertTrue(points[#points - 1].inside, label .. ": crossed straight out")
        end
    end
end)

test("the exit point prefers an edge ahead over a slightly nearer one behind", function()
    load()
    local field = rectangle(0, 0, 100, 100)
    -- At (50, 45), heading +z (north): the south edge is 45 m behind, the
    -- north one 55 m ahead.
    local ex, ez = TCJoyriderRuts.getExitPoint(field, 50, 45, 0)
    assertNear(ex, 50, 1e-6)
    assertNear(ez, 100 + TCJoyriderRuts.EXIT_BEYOND, 1e-6, "out past the north edge")

    -- Heading south instead: out the south edge.
    ex, ez = TCJoyriderRuts.getExitPoint(field, 50, 45, math.pi)
    assertNear(ez, -TCJoyriderRuts.EXIT_BEYOND, 1e-6, "out past the south edge")

    -- Right by the east edge, heading north: the east edge is far nearer
    -- than the turn costs, so out east.
    ex, ez = TCJoyriderRuts.getExitPoint(field, 97, 50, 0)
    assertNear(ex, 100 + TCJoyriderRuts.EXIT_BEYOND, 1e-6, "out past the east edge")
    assertNear(ez, 50, 1e-6)
end)

test("two wheel tracks either side of the path", function()
    load()
    local points = {
        { x = 0, z = 0, heading = 0 },        -- heading 0 = +z
        { x = 0, z = 1, heading = math.pi / 2 }, -- +x
    }
    local tracks = TCJoyriderRuts.getWheelTracks(points)
    local half = TCJoyriderRuts.TRACK_WIDTH / 2
    assertNear(math.abs(tracks.left[1][1] - tracks.right[1][1]), 2 * half, 1e-6)
    assertNear(tracks.left[1][2], 0, 1e-6)
    assertNear(math.abs(tracks.left[2][2] - tracks.right[2][2]), 2 * half, 1e-6)
    assertNear(tracks.left[2][1], 0, 1e-6)
end)

test("only pieces inside the field are painted", function()
    load()
    local field = rectangle(0, 0, 10, 10)
    -- A straight track along z = 5 from x = -5 to x = 15.
    local track = {}
    for x = -5, 15, 0.5 do
        table.insert(track, { x, 5 })
    end
    local pieces = TCJoyriderRuts.getTrackPieces(track, field)
    assertEquals(#pieces, 5, "10 m of straight track inside, in 2 m pieces")

    local half = TCJoyriderRuts.RUT_WIDTH / 2
    for _, piece in ipairs(pieces) do
        local sx, sz, wx, wz, hx, hz = piece[1], piece[2], piece[3], piece[4], piece[5], piece[6]
        -- Width corner across the track by the rut width, height corner along it.
        assertNear(math.sqrt((wx - sx) ^ 2 + (wz - sz) ^ 2), 2 * half, 1e-6)
        assertNear(hz, sz, 1e-6)
        assertNear(hx - sx, TCJoyriderRuts.MAX_PIECE_LENGTH + 2 * TCJoyriderRuts.OVERLAP, 1e-6)
        local mx = (sx + hx) / 2
        assertTrue(mx > 0 and mx < 10, "middle inside")
        assertNear(piece[7], math.pi / 2, 1e-6, "heading along +x")
    end
end)

test("a tight bend is painted in shorter pieces that follow the curve, with no gaps", function()
    load()
    local field = rectangle(-50, -50, 50, 50)
    -- A full lap of the tightest donut (5 m radius), a point every 0.5 m.
    local radius = 5
    local track = {}
    local steps = math.floor(2 * math.pi * radius / TCJoyriderRuts.STEP)
    for i = 0, steps do
        local angle = i * TCJoyriderRuts.STEP / radius
        table.insert(track, { radius * math.cos(angle), radius * math.sin(angle) })
    end
    local pieces = TCJoyriderRuts.getTrackPieces(track, field)
    assertTrue(#pieces > 2 * math.pi * radius / TCJoyriderRuts.MAX_PIECE_LENGTH, "shorter than a straight's")
    assertTrue(#pieces < steps, "but still joined")

    local half = TCJoyriderRuts.RUT_WIDTH / 2
    local previousEnd = nil
    for _, piece in ipairs(pieces) do
        local sx, sz, wx, wz, hx, hz = piece[1], piece[2], piece[3], piece[4], piece[5], piece[6]
        -- The centre line's ends, without the overlap.
        local dx, dz = math.sin(piece[7]), math.cos(piece[7])
        local cx, cz = (sx + wx) / 2 + dx * TCJoyriderRuts.OVERLAP, (sz + wz) / 2 + dz * TCJoyriderRuts.OVERLAP
        local ex, ez = hx + (wx - sx) / 2 - dx * TCJoyriderRuts.OVERLAP, hz + (wz - sz) / 2 - dz * TCJoyriderRuts.OVERLAP
        -- Both ends on the circle, the middle no further in than the bend allows.
        assertNear(math.sqrt(cx * cx + cz * cz), radius, 1e-6)
        assertNear(math.sqrt(ex * ex + ez * ez), radius, 1e-6)
        local mx, mz = (cx + ex) / 2, (cz + ez) / 2
        assertTrue(radius - math.sqrt(mx * mx + mz * mz) <= TCJoyriderRuts.MAX_PIECE_BEND + 0.05, "stays on the curve")
        assertTrue(math.sqrt((wx - sx) ^ 2 + (wz - sz) ^ 2) - 2 * half < 1e-6, "rut width")
        if previousEnd ~= nil then
            assertNear(cx, previousEnd[1], 1e-6, "starts where the last one ended")
            assertNear(cz, previousEnd[2], 1e-6)
        end
        previousEnd = { ex, ez }
    end
end)

local function setupPainting(world, boundary)
    world.painted = {}
    world.cleared = 0
    FSDensityMapUtil = {
        convertToDensityMapAngle = function(angle, maxValue)
            return math.floor(angle / math.pi * (maxValue + 1) + 0.5) % (maxValue + 1)
        end,
        updateCultivatorArea = function(sx, sz, wx, wz, hx, hz, createField, limitToField, angle, blocked, setsWeeds,
                                        disableStones)
            table.insert(world.painted, { style = "cultivator", sx = sx, sz = sz, hx = hx, hz = hz, wx = wx, wz = wz,
                createField = createField, limitToField = limitToField, angle = angle, disableStones = disableStones })
        end,
        updateDiscHarrowArea = function(sx, sz, wx, wz, hx, hz, createField, limitToField, angle)
            table.insert(world.painted, { style = "disc", sx = sx, sz = sz, hx = hx, hz = hz, wx = wx, wz = wz,
                createField = createField, limitToField = limitToField, angle = angle })
        end,
        clearDecoArea = function()
            world.cleared = world.cleared + 1
        end,
    }
    g_currentMission.fieldGroundSystem = {
        getGroundAngleMaxValue = function()
            return 7
        end,
    }
    local nodes = {}
    for i, point in ipairs(boundary) do
        nodes[i] = point
    end
    getWorldTranslation = function(node)
        return node[1], 0, node[2]
    end
    return {
        getPolygonPoints = function()
            return nodes
        end,
        getId = function()
            return 12
        end,
    }
end

test("painting a field paints both ruts, inside it only, never creating field ground", function()
    local world = load()
    local boundary = rectangle(0, 0, 150, 100)
    local field = setupPainting(world, boundary)

    local result = TCJoyriderRuts.paintField(field, nil, seeded(3))
    assertTrue(result ~= nil)
    assertEquals(#world.painted, result.pieces)
    assertEquals(world.cleared, result.pieces, "deco cleared along every piece")
    assertTrue(result.pieces > 100)
    assertTrue(result.insideLength <= result.length)

    for _, call in ipairs(world.painted) do
        assertEquals(call.style, "cultivator", "the default look")
        assertEquals(call.createField, false)
        assertEquals(call.limitToField, true)
        assertEquals(call.disableStones, true)
        assertTrue(call.angle >= 0 and call.angle <= 7)
        local mx, mz = (call.wx + call.hx) / 2, (call.wz + call.hz) / 2
        assertTrue(TCJoyriderRuts.isPointInside(mx, mz, boundary), "painted inside the field")
    end
end)

test("the disc look uses the disc harrow", function()
    local world = load()
    local field = setupPainting(world, rectangle(0, 0, 150, 100))
    TCJoyriderRuts.paintField(field, TCJoyriderRuts.STYLE.DISC, seeded(3))
    assertTrue(#world.painted > 0)
    for _, call in ipairs(world.painted) do
        assertEquals(call.style, "disc")
    end
end)

test("a client or a field with no boundary paints nothing", function()
    local world = load()
    local field = setupPainting(world, rectangle(0, 0, 150, 100))
    g_currentMission.getIsServer = function()
        return false
    end
    assertEquals(TCJoyriderRuts.paintField(field, nil, seeded(1)), nil)

    g_currentMission.getIsServer = function()
        return true
    end
    local empty = setupPainting(world, {})
    assertEquals(TCJoyriderRuts.paintField(empty, nil, seeded(1)), nil)
    assertEquals(#world.painted, 0)
end)
