-- 140: the auction site's dressing (TCAuctionScene): the entrance space's
-- props (car park, food area, toilets, office, bunting, signs, boards) in
-- the space and clear of each other, the drive lane, the near cross aisle
-- and the lots; each row's lot sign with its lots' numbers; the crowd's
-- extra spots and walks.

local function setup()
    local world = stubs.install()
    world:load("src/util/TCAuctionCrowd.lua")
    world:load("src/util/TCAuctionLayout.lua")
    world:load("src/util/TCAuctionScene.lua")
    return world
end

local function rectPolygon(x1, z1, x2, z2)
    return { { x = x1, z = z1 }, { x = x2, z = z1 }, { x = x2, z = z2 }, { x = x1, z = z2 } }
end

-- count lots: tractors (3 x 5), trailers (2.6 x 8) and a combine with its
-- header (9 x 14), in turn (test_auctionLayout's).
local function makeLots(count)
    local sizes = {
        { width = 3, length = 5 },
        { width = 2.6, length = 8 },
        { width = 9, length = 14 },
    }
    local lots = {}
    for i = 1, count do
        local size = sizes[(i - 1) % #sizes + 1]
        lots[i] = { width = size.width, length = size.length }
    end
    return lots
end

-- A sale: the layout, its scene and the scene laid out.
local function makeSale(polygon, entrance, lotCount, seed)
    local lots = makeLots(lotCount)
    local layout = TCAuctionLayout.layOut(polygon, entrance, lots)
    local scene = TCAuctionLayout.getScene(layout, entrance, seed or 1234)
    return { lots = lots, layout = layout, scene = scene, dressed = TCAuctionScene.layOut(scene) }
end

local function footprint(prop)
    return TCAuctionLayout.getFootprintCorners(prop.x, prop.z, prop.yaw, prop.width, prop.length)
end

local function lotCorners(sale, index)
    local spot = sale.layout.placed[index]
    local lot = sale.lots[index]
    return TCAuctionLayout.getFootprintCorners(spot.x, spot.z, spot.yaw, lot.width, lot.length)
end

-- Whether two convex quads overlap (separating axes), shrunk a hair so
-- touching edges don't count.
local function quadsOverlap(a, b)
    for _, quad in ipairs({ a, b }) do
        for i = 1, 4 do
            local p, q = quad[i], quad[i % 4 + 1]
            local nx, nz = q.z - p.z, p.x - q.x
            local aMin, aMax, bMin, bMax = math.huge, -math.huge, math.huge, -math.huge
            for _, c in ipairs(a) do
                local d = c.x * nx + c.z * nz
                aMin, aMax = math.min(aMin, d), math.max(aMax, d)
            end
            for _, c in ipairs(b) do
                local d = c.x * nx + c.z * nz
                bMin, bMax = math.min(bMin, d), math.max(bMax, d)
            end
            if aMax <= bMin + 0.01 or bMax <= aMin + 0.01 then
                return false
            end
        end
    end
    return true
end

local function insideQuad(x, z, quad)
    local positive, negative = false, false
    for i = 1, 4 do
        local a, b = quad[i], quad[i % 4 + 1]
        local cross = (b.x - a.x) * (z - a.z) - (b.z - a.z) * (x - a.x)
        positive = positive or cross > 0.001
        negative = negative or cross < -0.001
    end
    return not (positive and negative)
end

-- A point in the entrance space's own terms: d in from its outer edge, v.
local function toSpace(scene, x, z)
    local u, v = TCAuctionLayout.toLocal({ cx = scene.cx, cz = scene.cz, angle = scene.angle }, x, z)
    local outerU = scene.nearSign > 0 and scene.reserve.uTo or scene.reserve.uFrom
    return (outerU - u) * scene.nearSign, v
end

local function count(props, kind)
    local n = 0
    for _, prop in ipairs(props) do
        if prop.kind == kind then
            n = n + 1
        end
    end
    return n
end

-- Every check a dressed sale must pass.
local function checkScene(sale)
    local scene, dressed = sale.scene, sale.dressed
    local depth = math.abs(scene.reserve.uTo - scene.reserve.uFrom)
    local crossFrom = depth - scene.aisleWidth
    local lane = dressed.lane
    assertTrue(lane ~= nil, "a drive lane")
    for i, prop in ipairs(dressed.props) do
        local corners = footprint(prop)
        local isRowSign = prop.face == TCAuctionScene.FACES.LOTS
        for _, corner in ipairs(corners) do
            local d, v = toSpace(scene, corner.x, corner.z)
            if isRowSign then
                -- At the near cross aisle's edge, by the lots.
                assertTrue(d >= crossFrom - 0.01 and d <= depth + 0.01, "a row sign off the cross aisle's edge")
            else
                assertTrue(d >= -0.01 and d <= crossFrom + 0.01,
                    string.format("a %s out of the entrance space (d %.2f)", prop.kind, d))
                -- The space carries on past the rows' sides, to the
                -- rectangle's.
                assertTrue(v >= -scene.halfV - 0.01 and v <= scene.halfV + 0.01,
                    string.format("a %s off the rectangle's sides", prop.kind))
                assertTrue(v <= lane.vFrom + 0.01 or v >= lane.vTo - 0.01,
                    string.format("a %s in the drive lane", prop.kind))
            end
        end
        for j = i + 1, #dressed.props do
            -- A stack's levels (the bales) sit on each other, not in each other.
            if (prop.level or 0) == (dressed.props[j].level or 0) then
                assertTrue(not quadsOverlap(corners, footprint(dressed.props[j])),
                    string.format("a %s and a %s overlap", prop.kind, dressed.props[j].kind))
            end
        end
        for index in pairs(sale.layout.placed) do
            assertTrue(not quadsOverlap(corners, lotCorners(sale, index)),
                string.format("a %s on lot %d", prop.kind, index))
        end
    end
    -- The gate's sign and board stand in room of their own, a metre clear
    -- of the blocks (toilets, office, food) and the cars.
    local blockKinds = { toilet = true, office = true, foodVan = true, bench = true, bin = true, car = true }
    for _, prop in ipairs(dressed.props) do
        if prop.kind == "gateSign" or (prop.kind == "board" and prop.board == TCAuctionScene.BOARDS.SOLD_AS_SEEN) then
            local room = TCAuctionLayout.getFootprintCorners(prop.x, prop.z, prop.yaw, prop.width + 2, prop.length + 2)
            for _, other in ipairs(dressed.props) do
                if blockKinds[other.kind] then
                    assertTrue(not quadsOverlap(room, footprint(other)),
                        string.format("a %s crowded by a %s", prop.kind, other.kind))
                end
            end
        end
    end
    -- Nobody stands in a prop or on a lot.
    for _, spot in ipairs(dressed.spots) do
        for _, prop in ipairs(dressed.props) do
            assertTrue(not insideQuad(spot.x, spot.z, footprint(prop)),
                string.format("a %s spot inside a %s", spot.category, prop.kind))
        end
        for index in pairs(sale.layout.placed) do
            assertTrue(not insideQuad(spot.x, spot.z, lotCorners(sale, index)),
                string.format("a %s spot on lot %d", spot.category, index))
        end
    end
end

test("a big sale: everything in the entrance space, clear of the lane, the cross aisle, the lots and each other", function()
    setup()
    local sale = makeSale(rectPolygon(0, 0, 400, 220), { x = 420, z = 90 }, 120)
    assertTrue(sale.layout.placedCount >= 100)
    checkScene(sale)
    local props = sale.dressed.props
    assertEquals(count(props, "foodVan"), 1)
    assertEquals(count(props, "office"), 1)
    assertEquals(count(props, "toilet"), 3)
    assertEquals(count(props, "gateSign"), 1)
    assertTrue(count(props, "bench") >= 3)
    assertTrue(count(props, "bin") >= 2)
    assertTrue(count(props, "bunting") >= 4)
    assertTrue(count(props, "car") >= 10)
    -- The gate's bales in stacks: each spot has every level, one bale each.
    local stacks = {}
    for _, prop in ipairs(props) do
        if prop.kind == "bale" then
            local key = string.format("%.1f %.1f", prop.x, prop.z)
            stacks[key] = stacks[key] or {}
            assertTrue(stacks[key][prop.level] == nil, "two bales on one level")
            stacks[key][prop.level] = true
        end
    end
    local stackCount = 0
    for _, levels in pairs(stacks) do
        stackCount = stackCount + 1
        for level = 0, TCAuctionScene.BALE_STACK - 1 do
            assertTrue(levels[level], "a stack missing a level")
        end
    end
    assertEquals(stackCount, 4)
    -- All five chalkboards, each once.
    local boards = {}
    for _, prop in ipairs(props) do
        if prop.kind == "board" then
            assertTrue(boards[prop.board] == nil, "a board twice")
            boards[prop.board] = true
        end
    end
    for _, board in pairs(TCAuctionScene.BOARDS) do
        assertTrue(boards[board], "board " .. board .. " missing")
    end
    -- The signs: the gate, the hours, food, parking, toilets.
    local faces = {}
    for _, prop in ipairs(props) do
        if prop.face ~= nil then
            faces[prop.face] = (faces[prop.face] or 0) + 1
        end
    end
    for _, face in ipairs({ "gate", "hours", "food", "parking", "toilets" }) do
        assertEquals(faces[face], 1, face)
    end
end)

test("the gate is where the entrance is, kept inside the space", function()
    setup()
    for _, entranceZ in ipairs({ 90, 10, 210 }) do
        local sale = makeSale(rectPolygon(0, 0, 400, 220), { x = 420, z = entranceZ }, 80)
        checkScene(sale)
        local scene, lane = sale.scene, sale.dressed.lane
        local _, entranceV = TCAuctionLayout.toLocal({ cx = scene.cx, cz = scene.cz, angle = scene.angle }, 420,
            entranceZ)
        local laneMiddle = (lane.vFrom + lane.vTo) * 0.5
        local low = scene.reserve.vFrom + TCAuctionScene.EDGE + TCAuctionScene.DRIVE_HALF
        local high = scene.reserve.vTo - TCAuctionScene.EDGE - TCAuctionScene.DRIVE_HALF
        assertNear(laneMiddle, math.max(low, math.min(high, entranceV)), 0.01)
    end
end)

test("a small sale still fits, leaving out what doesn't", function()
    setup()
    for _, lotCount in ipairs({ 30, 12 }) do
        local sale = makeSale(rectPolygon(0, 0, 220, 90), { x = -20, z = 45 }, lotCount)
        checkScene(sale)
        assertTrue(count(sale.dressed.props, "gateSign") == 1)
    end
end)

test("a rotated field dresses the same way", function()
    setup()
    local c, s = math.cos(math.rad(30)), math.sin(math.rad(30))
    local polygon = {}
    for _, p in ipairs(rectPolygon(-200, -100, 200, 100)) do
        table.insert(polygon, { x = p.x * c - p.z * s, z = p.x * s + p.z * c })
    end
    local sale = makeSale(polygon, { x = 220 * c, z = 220 * s }, 90)
    checkScene(sale)
    assertTrue(count(sale.dressed.props, "car") > 0)
end)

test("each row's sign shows its lots' numbers, as they're numbered", function()
    setup()
    local sale = makeSale(rectPolygon(0, 0, 400, 220), { x = 420, z = 90 }, 100)
    -- The lots' numbers, as the site gives them (138's walk order).
    local numberOf = {}
    for number, index in ipairs(TCAuctionLayout.getWalkOrder(sale.layout.placed)) do
        numberOf[index] = number
    end
    local rowRanges = {}
    for _, prop in ipairs(sale.dressed.props) do
        if prop.face == TCAuctionScene.FACES.LOTS then
            table.insert(rowRanges, { from = prop.lotFrom, to = prop.lotTo })
        end
    end
    assertEquals(#rowRanges, #sale.scene.rows)
    -- Each row's placed lots are exactly its sign's numbers.
    local next = 1
    for r, row in ipairs(sale.scene.rows) do
        assertEquals(rowRanges[r].from, next)
        local inRow = {}
        for index, spot in pairs(sale.layout.placed) do
            local _, v = TCAuctionLayout.toLocal(sale.layout.rect, spot.x, spot.z)
            if v > row.vFrom and v < row.vTo then
                table.insert(inRow, numberOf[index])
            end
        end
        table.sort(inRow)
        assertEquals(inRow[1], rowRanges[r].from)
        assertEquals(inRow[#inRow], rowRanges[r].to)
        assertEquals(#inRow, rowRanges[r].to - rowRanges[r].from + 1)
        next = rowRanges[r].to + 1
    end
    assertEquals(next - 1, sale.layout.placedCount)
end)

test("the same seed dresses the same; another seed parks other cars", function()
    setup()
    local a = makeSale(rectPolygon(0, 0, 400, 220), { x = 420, z = 90 }, 80, 99)
    local b = makeSale(rectPolygon(0, 0, 400, 220), { x = 420, z = 90 }, 80, 99)
    local c = makeSale(rectPolygon(0, 0, 400, 220), { x = 420, z = 90 }, 80, 100)
    local function cars(sale)
        local list = {}
        for _, prop in ipairs(sale.dressed.props) do
            if prop.kind == "car" then
                table.insert(list, string.format("%.2f,%.2f,%d", prop.x, prop.z, prop.model))
            end
        end
        return table.concat(list, ";")
    end
    assertEquals(cars(a), cars(b))
    assertTrue(cars(a) ~= cars(c))
end)

test("viewers stand at the rows' fronts facing the lots, clear of the walkers", function()
    setup()
    local sale = makeSale(rectPolygon(0, 0, 400, 220), { x = 420, z = 90 }, 100)
    local walks = TCAuctionScene.getWalks(sale.scene, sale.layout.walkways)
    local loops = TCAuctionCrowd.buildWalkwayLoops(walks)
    local lanePoints = {}
    for _, loop in ipairs(loops) do
        local path = TCAuctionCrowd.buildPath(loop.points)
        for d = 0, path.length, 0.5 do
            local x, z, dx, dz = TCAuctionCrowd.getPathPoint(path, d)
            for _, direction in ipairs({ 1, -1 }) do
                local lx, lz = TCAuctionCrowd.getLanePosition(x, z, dx, dz, direction)
                table.insert(lanePoints, { x = lx, z = lz })
            end
        end
    end
    local viewers = 0
    for _, spot in ipairs(sale.dressed.spots) do
        if spot.category == TCAuctionScene.SPOT.LOT then
            viewers = viewers + 1
            -- A step ahead of them is a lot.
            local ax, az = spot.x + math.sin(spot.yaw) * 2, spot.z + math.cos(spot.yaw) * 2
            local onLot = false
            for index in pairs(sale.layout.placed) do
                onLot = onLot or insideQuad(ax, az, lotCorners(sale, index))
            end
            assertTrue(onLot, "a viewer facing away from the lots")
        end
        for _, point in ipairs(lanePoints) do
            assertTrue(math.sqrt((spot.x - point.x) ^ 2 + (spot.z - point.z) ^ 2) >= 0.5,
                "a " .. tostring(spot.category) .. " spot on a walker's lane")
        end
    end
    assertTrue(viewers >= 10)
end)

test("the walks: the aisles stop at the lots' far edge, and the cross aisles are walked without crossing them", function()
    setup()
    local sale = makeSale(rectPolygon(0, 0, 400, 220), { x = 420, z = 90 }, 100)
    local walkways = sale.layout.walkways
    local walks = TCAuctionScene.getWalks(sale.scene, walkways)
    assertEquals(#walks, #walkways + 2)
    local aisleLoops, crossLoops = {}, {}
    for _, walk in ipairs(walks) do
        local loops = TCAuctionCrowd.buildWalkwayLoops({ walk })
        assertEquals(#loops, 1)
        table.insert(walk.isCross and crossLoops or aisleLoops, loops[1])
    end
    assertEquals(#crossLoops, 2)
    local function points(loops)
        local list = {}
        for _, loop in ipairs(loops) do
            local path = TCAuctionCrowd.buildPath(loop.points)
            for d = 0, path.length, 0.5 do
                local x, z, dx, dz = TCAuctionCrowd.getPathPoint(path, d)
                for _, direction in ipairs({ 1, -1 }) do
                    local lx, lz = TCAuctionCrowd.getLanePosition(x, z, dx, dz, direction)
                    table.insert(list, { x = lx, z = lz })
                end
            end
        end
        return list
    end
    local aisle, cross = points(aisleLoops), points(crossLoops)
    -- No aisle lane meets a cross aisle lane.
    for _, p in ipairs(aisle) do
        for _, q in ipairs(cross) do
            assertTrue((p.x - q.x) ^ 2 + (p.z - q.z) ^ 2 >= 0.25, "an aisle lane runs into a cross aisle's")
        end
    end
    -- Neither comes near a lot, nor a prop of the entrance space.
    for _, p in ipairs(cross) do
        for index in pairs(sale.layout.placed) do
            assertTrue(not insideQuad(p.x, p.z, lotCorners(sale, index)), "a cross lane through a lot")
        end
        for _, prop in ipairs(sale.dressed.props) do
            assertTrue(not insideQuad(p.x, p.z, footprint(prop)), "a cross lane through a " .. prop.kind)
        end
    end
end)

test("no scene, no dressing; the walks are the aisles as they were", function()
    setup()
    local walkways = { { x1 = 0, z1 = 0, x2 = 100, z2 = 0, halfWidth = 5 } }
    assertEquals(#TCAuctionScene.layOut(nil).props, 0)
    local walks = TCAuctionScene.getWalks(nil, walkways)
    assertEquals(#walks, 1)
    assertEquals(walks[1].x2, 100)
end)

test("spots fill the gate's first, then the food's, then a group from each place in turn", function()
    setup()
    local spots = {
        { category = "lot", group = 1 }, { category = "lot", group = 1 },
        { category = "lot", group = 2 },
        { category = "food", group = 3 }, { category = "food", group = 3 },
        { category = "gate", group = 4 }, { category = "gate", group = 4 },
        { group = 5 }, { group = 5 },
    }
    local ordered = TCAuctionScene.orderSpots(spots)
    assertEquals(#ordered, #spots)
    local order = {}
    for _, spot in ipairs(ordered) do
        table.insert(order, (spot.category or "aisle") .. spot.group)
    end
    assertEquals(table.concat(order, " "), "gate4 gate4 food3 food3 lot1 lot1 aisle5 aisle5 lot2")
end)

test("car picks follow their weights", function()
    setup()
    local counts = {}
    for i = 0, 999 do
        local model = TCAuctionScene.pickCar(i / 1000)
        counts[model] = (counts[model] or 0) + 1
    end
    assertEquals(TCAuctionScene.pickCar(0), 1)
    assertEquals(TCAuctionScene.pickCar(0.99999), #TCAuctionScene.CAR_MODELS)
    -- A van (weight 1) about half as often as a car (weight 2).
    assertTrue(counts[17] < counts[1])
end)
