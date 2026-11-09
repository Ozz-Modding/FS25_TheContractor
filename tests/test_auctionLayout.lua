-- 135: the auction site's layout (TCAuctionLayout): rows of lots with aisles
-- between them inside a field's polygon, the entrance's space kept, the
-- field ranking, the slope, the entrance, and the roles a sale's lots are.

local function setup()
    local world = stubs.install()
    world:load("src/util/TCAuctionCrowd.lua")
    world:load("src/util/TCAuctionLayout.lua")
    return world
end

local function rectPolygon(x1, z1, x2, z2)
    return { { x = x1, z = z1 }, { x = x2, z = z1 }, { x = x2, z = z2 }, { x = x1, z = z2 } }
end

-- An L: a 200 x 60 strip along x with a 60 x 200 leg up from its left end.
local function lPolygon()
    return {
        { x = 0, z = 0 }, { x = 200, z = 0 }, { x = 200, z = 60 }, { x = 60, z = 60 },
        { x = 60, z = 200 }, { x = 0, z = 200 },
    }
end

-- count lots: tractors (3 x 5), trailers (2.6 x 8) and a combine with its
-- header (9 x 14), in turn.
local function makeLots(count)
    local sizes = {
        { width = 3, length = 5, widthOffset = 0.2, lengthOffset = -0.5 },
        { width = 2.6, length = 8 },
        { width = 9, length = 14, lengthOffset = 3 },
    }
    local lots = {}
    for i = 1, count do
        local size = sizes[(i - 1) % #sizes + 1]
        lots[i] = { width = size.width, length = size.length, widthOffset = size.widthOffset,
            lengthOffset = size.lengthOffset }
    end
    return lots
end

local function lotCorners(layout, lots, index)
    local spot = layout.placed[index]
    return TCAuctionLayout.getFootprintCorners(spot.x, spot.z, spot.yaw, lots[index].width, lots[index].length)
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

-- The checks every layout must pass: every placed lot inside the polygon
-- and the rectangle, clear of every aisle, of the entrance's space and of
-- every other lot, facing its aisle.
local function checkLayout(layout, lots, polygon)
    local rect = layout.rect
    for index in pairs(layout.placed) do
        local corners = lotCorners(layout, lots, index)
        for _, corner in ipairs(corners) do
            assertTrue(TCAuctionCrowd.pointInPolygon(corner.x, corner.z, polygon),
                "lot " .. index .. " has a corner outside the field")
            local u, v = TCAuctionLayout.toLocal(rect, corner.x, corner.z)
            assertTrue(math.abs(u) <= rect.halfU + 0.01 and math.abs(v) <= rect.halfV + 0.01,
                "lot " .. index .. " is outside the rectangle")
            assertTrue(u >= layout.lotsFrom - 0.01 and u <= layout.lotsTo + 0.01,
                "lot " .. index .. " is in the entrance's space or the far aisle")
            for _, strip in ipairs(layout.aisleStrips) do
                assertTrue(v <= strip.vFrom + 0.01 or v >= strip.vTo - 0.01,
                    "lot " .. index .. " stands in an aisle")
            end
        end
        for other in pairs(layout.placed) do
            if other ~= index then
                assertTrue(not quadsOverlap(corners, lotCorners(layout, lots, other)),
                    "lots " .. index .. " and " .. other .. " overlap")
            end
        end
        -- Facing an aisle: a few metres ahead of its front is in one.
        local spot = layout.placed[index]
        local ahead = lots[index].length * 0.5 + 1
        local _, v = TCAuctionLayout.toLocal(rect, spot.x + math.sin(spot.yaw) * ahead,
            spot.z + math.cos(spot.yaw) * ahead)
        local inAisle = false
        for _, strip in ipairs(layout.aisleStrips) do
            inAisle = inAisle or (v > strip.vFrom and v < strip.vTo)
        end
        assertTrue(inAisle, "lot " .. index .. " doesn't face an aisle")
    end
end

test("a big rectangular field: 30 lots in rows, inside, clear of the aisles and the entrance", function()
    setup()
    local polygon = rectPolygon(0, 0, 300, 160)
    local lots = makeLots(30)
    local layout = TCAuctionLayout.layOut(polygon, { x = 320, z = 80 }, lots)
    assertTrue(layout ~= nil)
    assertEquals(layout.placedCount, 30)
    assertEquals(#layout.unplaced, 0)
    -- The rows run along the field's long side (x), so the entrance at
    -- +x is at the rectangle's near end.
    assertNear(math.abs(math.cos(layout.rect.angle)), 1, 0.01)
    checkLayout(layout, lots, polygon)
    -- The entrance's space is at the entrance's end.
    local reserveU = (layout.reserve.uFrom + layout.reserve.uTo) * 0.5
    local entranceU = TCAuctionLayout.toLocal(layout.rect, 320, 80)
    assertTrue(reserveU * entranceU > 0)
end)

test("the entrance's space moves to whichever end the entrance is", function()
    setup()
    local polygon = rectPolygon(0, 0, 300, 160)
    local lots = makeLots(12)
    local east = TCAuctionLayout.layOut(polygon, { x = 320, z = 80 }, lots)
    local west = TCAuctionLayout.layOut(polygon, { x = -20, z = 80 }, lots)
    assertEquals(east.nearSign, -west.nearSign)
    checkLayout(east, lots, polygon)
    checkLayout(west, lots, polygon)
end)

test("an L-shaped field keeps every lot inside it", function()
    setup()
    local polygon = lPolygon()
    local lots = makeLots(40)
    local layout = TCAuctionLayout.layOut(polygon, { x = 210, z = 30 }, lots)
    assertTrue(layout ~= nil)
    assertTrue(layout.placedCount > 0)
    assertEquals(layout.placedCount + #layout.unplaced, 40)
    checkLayout(layout, lots, polygon)
end)

test("a narrow strip has room for one row and its aisle, and leaves the rest out", function()
    setup()
    -- 400 x 36: inset 6 leaves about 24 across, one 5-8 m row and a 10 m aisle.
    local polygon = rectPolygon(0, 0, 400, 36)
    local lots = {}
    for i = 1, 200 do
        lots[i] = { width = 3, length = 5 }
    end
    local layout = TCAuctionLayout.layOut(polygon, { x = 410, z = 18 }, lots)
    assertTrue(layout ~= nil)
    assertTrue(#layout.aisleStrips >= 1)
    assertTrue(#layout.unplaced > 0)
    assertEquals(layout.placedCount + #layout.unplaced, 200)
    checkLayout(layout, lots, polygon)
end)

test("a lot too wide for any row is left out, the rest still go in", function()
    setup()
    local polygon = rectPolygon(0, 0, 120, 80)
    local lots = makeLots(6)
    lots[7] = { width = 500, length = 5 }
    local layout = TCAuctionLayout.layOut(polygon, nil, lots)
    assertEquals(layout.placed[7], nil)
    assertEquals(layout.unplaced[#layout.unplaced], 7)
    assertEquals(layout.placedCount, 6)
end)

test("the longest lots go in first, so they share the first row", function()
    setup()
    local polygon = rectPolygon(0, 0, 300, 160)
    local lots = makeLots(9)
    local layout = TCAuctionLayout.layOut(polygon, nil, lots)
    -- Lots 3, 6 and 9 are the combines.
    assertEquals(layout.placed[3].row, 1)
    assertEquals(layout.placed[6].row, 1)
    assertEquals(layout.placed[9].row, 1)
    -- Then the trailers, nearest the entrance after the combines.
    local function fromEntrance(index)
        local u = TCAuctionLayout.toLocal(layout.rect, layout.placed[index].x, layout.placed[index].z)
        return -layout.nearSign * u
    end
    assertTrue(fromEntrance(3) < fromEntrance(2))
    assertTrue(fromEntrance(9) < fromEntrance(2))
    assertTrue(layout.placed[1].row >= layout.placed[2].row)
end)

test("a lot's root is moved by its size's offsets, its footprint stays put", function()
    setup()
    local layout = TCAuctionLayout.layOut(rectPolygon(0, 0, 300, 160), nil,
        { { width = 3, length = 5, widthOffset = 0.5, lengthOffset = 1 } })
    local spot = layout.placed[1]
    local dx, dz = spot.rootX - spot.x, spot.rootZ - spot.z
    -- 1 m back along its heading and 0.5 m to its left.
    local fx, fz = math.sin(spot.yaw), math.cos(spot.yaw)
    assertNear(dx * fx + dz * fz, -1, 0.001)
    assertNear(dx * fz - dz * fx, -0.5, 0.001)
end)

test("the aisles are polylines, the rows' aisles and two cross aisles joining them", function()
    setup()
    local polygon = rectPolygon(0, 0, 160, 160)
    local layout = TCAuctionLayout.layOut(polygon, { x = 180, z = 80 }, makeLots(30))
    assertTrue(#layout.aisleStrips >= 2)
    assertEquals(#layout.aisles, #layout.aisleStrips + 2)
    for _, aisle in ipairs(layout.aisles) do
        assertTrue(#aisle.points >= 2)
        for i = 2, #aisle.points do
            local a, b = aisle.points[i - 1], aisle.points[i]
            assertTrue(math.sqrt((b.x - a.x) ^ 2 + (b.z - a.z) ^ 2) <= TCAuctionLayout.LAYOUT.pointSpacing + 0.01)
        end
        for _, point in ipairs(aisle.points) do
            assertTrue(TCAuctionCrowd.pointInPolygon(point.x, point.z, polygon))
        end
    end
end)

test("one aisle needs no cross aisles", function()
    setup()
    local layout = TCAuctionLayout.layOut(rectPolygon(0, 0, 300, 160), nil, makeLots(6))
    assertEquals(#layout.aisleStrips, 1)
    assertEquals(#layout.aisles, 1)
end)

test("the lot count and the space each needs are inputs", function()
    setup()
    local polygon = rectPolygon(0, 0, 140, 140)
    local small = TCAuctionLayout.layOut(polygon, nil, makeLots(50))
    local wide = TCAuctionLayout.layOut(polygon, nil, makeLots(50), { aisleWidth = 20, lotGap = 6 })
    assertEquals(small.placedCount, 50)
    assertTrue(wide.placedCount < small.placedCount)
end)

test("a polygon too small for a rectangle has no layout", function()
    setup()
    assertEquals(TCAuctionLayout.layOut(rectPolygon(0, 0, 10, 10), nil, makeLots(3)), nil)
end)

-- Ranking -----------------------------------------------------------------------------------

test("fields that can hold the sale come first, then the most lots, then the biggest", function()
    setup()
    local ranked = TCAuctionLayout.rankCandidates({
        { fieldId = 1, areaHa = 9, fitted = 50, slopePercent = 3, entranceDistance = 10 },
        { fieldId = 2, areaHa = 12, fitted = 20, slopePercent = 2, entranceDistance = 10 },
        { fieldId = 3, areaHa = 6, fitted = 40, slopePercent = 2, entranceDistance = 30 },
        { fieldId = 4, areaHa = 20, fitted = 60, slopePercent = 15, entranceDistance = 5 },
        { fieldId = 5, areaHa = 6, fitted = 45, slopePercent = 1, entranceDistance = 20 },
        { fieldId = 6, areaHa = 30, fitted = 80, slopePercent = 1 },
        -- Bigger than field 1 but fits fewer; as many as field 5 but bigger.
        { fieldId = 8, areaHa = 15, fitted = 48, slopePercent = 1, entranceDistance = 20 },
        { fieldId = 7, areaHa = 7, fitted = 45, slopePercent = 1, entranceDistance = 20 },
    }, 30)
    local ids = {}
    for i, candidate in ipairs(ranked) do
        ids[i] = candidate.fieldId
    end
    assertEquals(table.concat(ids, ","), "1,8,7,5,3,6,4,2")
    local P = TCAuctionLayout.PROBLEM
    assertEquals(#ranked[1].problems, 0)
    assertEquals(ranked[6].problems[1], P.NO_ROAD)
    assertEquals(ranked[7].problems[1], P.TOO_STEEP)
    assertEquals(ranked[8].problems[1], P.TOO_SMALL)
end)

test("a road beyond the reach is no road", function()
    setup()
    local problems = TCAuctionLayout.getProblems({ fitted = 40, slopePercent = 1, entranceDistance = 61 }, 30,
        { maxSlopePercent = 8, entranceReach = 60 })
    assertEquals(#problems, 1)
    assertEquals(problems[1], TCAuctionLayout.PROBLEM.NO_ROAD)
end)

test("slope: the steepest and average rise between neighbours, and the whole rise", function()
    setup()
    -- Rising 0.4 m every 8 m along a row (5%), flat across, but for one
    -- corner 2 m up from its row neighbour (25%) and 1.6 m from the other (20%).
    local heights = {
        { 10.0, 10.4, 10.8 },
        { 10.0, 10.4, 12.4 },
    }
    local steepest, average, rise = TCAuctionLayout.measureSlope(heights, 8)
    assertNear(steepest, 25, 0.001)
    assertNear(rise, 2.4, 0.001)
    -- Pairs: 4 along (5% x 3, 25%), 3 across (0, 0, 20%).
    assertNear(average, (5 + 5 + 5 + 25 + 0 + 0 + 20) / 7, 0.001)
    assertEquals(TCAuctionLayout.measureSlope({ { 3 } }, 8), nil)
end)

test("the entrance is the road point nearest the field's edge, inside the reach", function()
    setup()
    local polygon = rectPolygon(0, 0, 100, 100)
    local roads = {
        { x = 50, z = 50 },   -- inside the field: not a road to it
        { x = 130, z = 40 },  -- 30 m off the east edge
        { x = 50, z = -12 },  -- 12 m off the south edge
        { x = 400, z = 400 }, -- far away
    }
    local entrance = TCAuctionLayout.findEntrance(polygon, roads, 60)
    assertEquals(entrance.x, 50)
    assertEquals(entrance.z, -12)
    assertNear(entrance.distance, 12, 0.001)
    assertNear(entrance.edgeX, 50, 0.001)
    assertNear(entrance.edgeZ, 0, 0.001)
    assertEquals(TCAuctionLayout.findEntrance(polygon, { { x = 400, z = 400 } }, 60), nil)
end)

test("the sample grid covers the rectangle edge to edge", function()
    setup()
    local rect = { cx = 50, cz = 20, angle = 0, halfU = 40, halfV = 16 }
    local points = TCAuctionLayout.getSamplePoints(rect, 8)
    assertEquals(#points, 11 * 5)
    assertNear(points[1].x, 10, 0.001)
    assertNear(points[1].z, 4, 0.001)
    assertNear(points[#points].x, 90, 0.001)
    assertNear(points[#points].z, 36, 0.001)
end)

-- Roles and condition ----------------------------------------------------------------------------

local function sequence(values)
    local i = 0
    return function()
        i = i % #values + 1
        return values[i]
    end
end

local ROLE_DEFS = {
    { role = "smallTractor", weight = 4, min = 1, max = 6 },
    { role = "combine", weight = 1, min = 1, max = 2 },
    { role = "mower", weight = 2, min = 1, max = 3 },
    { role = "trailer", weight = 3, min = 0, max = 2 },
}

test("every role gets its minimum, the rest by weight, none past its maximum", function()
    setup()
    local roles, counts = TCAuctionLayout.pickRoles(ROLE_DEFS, 10, math.random)
    assertEquals(#roles, 10)
    for _, def in ipairs(ROLE_DEFS) do
        assertTrue(counts[def.role] >= def.min and counts[def.role] <= def.max, def.role)
    end
    -- Listed in the definitions' order.
    assertEquals(roles[1], "smallTractor")
    assertEquals(roles[#roles], counts.trailer > 0 and "trailer" or "mower")
end)

test("the weights pick: a low roll takes the first role with room", function()
    setup()
    local roles, counts = TCAuctionLayout.pickRoles(ROLE_DEFS, 4, sequence({ 0 }))
    -- The minimums are 3; the fourth is drawn, and a roll of 0 lands on the first.
    assertEquals(#roles, 4)
    assertEquals(counts.smallTractor, 2)
    -- A roll near 1 lands on the last role with room.
    local _, high = TCAuctionLayout.pickRoles(ROLE_DEFS, 4, sequence({ 0.999 }))
    assertEquals(high.trailer, 1)
end)

test("more lots than every maximum allows: as many as there can be", function()
    setup()
    local roles = TCAuctionLayout.pickRoles(ROLE_DEFS, 50, math.random)
    assertEquals(#roles, 6 + 2 + 3 + 2)
end)

test("fewer lots than the minimums: the first roles' minimums", function()
    setup()
    local _, counts = TCAuctionLayout.pickRoles(ROLE_DEFS, 2, math.random)
    assertEquals(counts.smallTractor, 1)
    assertEquals(counts.combine, 1)
    assertEquals(counts.mower, 0)
end)

test("a role the store has nothing for is left out", function()
    setup()
    local roles, counts = TCAuctionLayout.pickRoles(ROLE_DEFS, 8, math.random,
        { smallTractor = true, mower = true, trailer = true })
    assertEquals(counts.combine, nil)
    for _, role in ipairs(roles) do
        assertTrue(role ~= "combine")
    end
end)

test("a lot's condition comes from the preset, its age from its hours", function()
    setup()
    local preset = { hoursMin = 17, hoursMax = 28, damageMin = 0.15, damageMax = 0.45, wearMin = 0.2, wearMax = 0.65 }
    local low = TCAuctionLayout.rollCondition(preset, 800, sequence({ 0 }))
    assertNear(low.hours, 17, 0.001)
    assertNear(low.damage, 0.15, 0.001)
    assertNear(low.wear, 0.2, 0.001)
    assertEquals(low.ageMonths, 1)
    local high = TCAuctionLayout.rollCondition(preset, 10, sequence({ 1 }))
    assertNear(high.hours, 28, 0.001)
    assertNear(high.wear, 0.65, 0.001)
    -- 28 h at 10 h a year: 2.8 years.
    assertEquals(high.ageMonths, 33)
end)

-- A fake catalog, as TheContractorFarmerFleet.buildCatalog makes one.
local function fakeCatalog()
    local function models(...)
        local list = {}
        for _, xml in ipairs({ ... }) do
            table.insert(list, { xmlFilename = xml })
        end
        return list
    end
    return {
        byRole = {
            smallTractor = models("small1.xml", "small2.xml"),
            combine = models("bareCombine.xml", "combine.xml"),
            mower = models("mower.xml"),
            trailer = {},
        },
        attachments = {
            ["combine.xml"] = models("grainHeader.xml"),
            ["bareCombine.xml"] = {},
        },
    }
end

test("a sale's lots from the catalog: a model for each role, a combine with a header that fits", function()
    local world = setup()
    world:load("src/business/FarmerFleet.lua")
    local catalog = fakeCatalog()
    local available = TCAuctionLayout.getAvailableRoles(catalog, ROLE_DEFS)
    assertTrue(available.smallTractor and available.combine and available.mower)
    assertEquals(available.trailer, nil)

    local roles, counts = TCAuctionLayout.pickRoles(ROLE_DEFS, 9, math.random, available)
    assertEquals(#roles, 9)
    assertEquals(counts.trailer, nil)
    local lots = TCAuctionLayout.pickLots(catalog, roles, math.random)
    assertEquals(#lots, 9)
    for i, lot in ipairs(lots) do
        assertEquals(lot.role, roles[i])
        if lot.role == "combine" then
            -- Only combines with something that fits are picked, and it's fitted.
            assertEquals(lot.xmlFilename, "combine.xml")
            assertEquals(lot.attachmentXml, "grainHeader.xml")
        else
            assertEquals(lot.attachmentXml, nil)
        end
    end
end)

test("a role the catalog has nothing for gets no lot", function()
    local world = setup()
    world:load("src/business/FarmerFleet.lua")
    local lots = TCAuctionLayout.pickLots(fakeCatalog(), { "trailer", "mower" }, math.random)
    assertEquals(#lots, 1)
    assertEquals(lots[1].role, "mower")
end)

test("the rows are centred across the field, and the entrance's space is as wide as they are", function()
    setup()
    local polygon = rectPolygon(0, 0, 300, 160)
    local lots = makeLots(12)
    local layout = TCAuctionLayout.layOut(polygon, { x = 320, z = 80 }, lots)
    checkLayout(layout, lots, polygon)
    -- The rows and their aisles, across the rectangle: as far from one side
    -- as the other.
    local vMin, vMax = math.huge, -math.huge
    for index in pairs(layout.placed) do
        for _, corner in ipairs(lotCorners(layout, lots, index)) do
            local _, v = TCAuctionLayout.toLocal(layout.rect, corner.x, corner.z)
            vMin, vMax = math.min(vMin, v), math.max(vMax, v)
        end
    end
    for _, strip in ipairs(layout.aisleStrips) do
        vMin, vMax = math.min(vMin, strip.vFrom), math.max(vMax, strip.vTo)
    end
    assertNear(vMin + vMax, 0, 0.01, "centred")
    assertTrue(vMax - vMin < layout.rect.halfV, "the rows take under half the width")
    -- The reserve spans the rows and their aisles, not the whole rectangle.
    assertNear(layout.reserve.vFrom, vMin, 0.01)
    assertNear(layout.reserve.vTo, vMax, 0.01)
    assertTrue(layout.reserve.vTo - layout.reserve.vFrom < layout.rect.halfV * 2 - 1)
end)

test("no model more than its duplicates limit, and a role held to what its models allow", function()
    local world = setup()
    world:load("src/business/FarmerFleet.lua")
    local catalog = fakeCatalog()
    -- Two small tractor models, one mower, one combine with a header.
    local available = TCAuctionLayout.getAvailableRoles(catalog, ROLE_DEFS, 3)
    assertEquals(available.smallTractor, 6)
    assertEquals(available.mower, 3)

    local defs = {
        { role = "smallTractor", weight = 1, min = 1, max = 25 },
        { role = "mower", weight = 1, min = 1, max = 25 },
    }
    local roles, counts = TCAuctionLayout.pickRoles(defs, 40, math.random, available)
    assertEquals(counts.smallTractor, 6, "held to two models three times")
    assertEquals(counts.mower, 3)
    assertEquals(#roles, 9)

    local lots = TCAuctionLayout.pickLots(catalog, roles, math.random, 3)
    assertEquals(#lots, 9)
    local perModel = {}
    for _, lot in ipairs(lots) do
        perModel[lot.xmlFilename] = (perModel[lot.xmlFilename] or 0) + 1
    end
    assertEquals(perModel["small1.xml"], 3)
    assertEquals(perModel["small2.xml"], 3)
    assertEquals(perModel["mower.xml"], 3)

    -- Asked for more than the models allow: the rest are left out.
    local extra = TCAuctionLayout.pickLots(catalog, { "mower", "mower", "mower", "mower" }, math.random, 3)
    assertEquals(#extra, 3)
end)

-- A role's models at these prices: model1.xml at the first, and so on.
local function pricedModels(...)
    local list = {}
    for i, price in ipairs({ ... }) do
        table.insert(list, { xmlFilename = "model" .. i .. ".xml", price = price })
    end
    return list
end

test("the cheapest share of a role's models by price weigh the boost, the rest 1", function()
    setup()
    -- Five models, listed out of price order: the cheapest 40% are two.
    local weights = TCAuctionLayout.getModelWeights(pricedModels(300, 100, 500, 200, 400), 0.4, 3)
    assertEquals(weights["model2.xml"], 3)
    assertEquals(weights["model4.xml"], 3)
    assertEquals(weights["model1.xml"], 1)
    assertEquals(weights["model5.xml"], 1)
    assertEquals(weights["model3.xml"], 1)

    -- 80% of five: all but the dearest.
    weights = TCAuctionLayout.getModelWeights(pricedModels(300, 100, 500, 200, 400), 0.8, 3)
    assertEquals(weights["model3.xml"], 1)
    assertEquals(weights["model1.xml"], 3)
    assertEquals(weights["model5.xml"], 3)

    -- Two models at 40%: the cheaper one.
    weights = TCAuctionLayout.getModelWeights(pricedModels(900, 400), 0.4, 3)
    assertEquals(weights["model2.xml"], 3)
    assertEquals(weights["model1.xml"], 1)
end)

test("a model with no price, or a role with no band, weighs 1", function()
    setup()
    local models = pricedModels(100, 200)
    table.insert(models, { xmlFilename = "unpriced.xml" })
    local weights = TCAuctionLayout.getModelWeights(models, 0.5, 3)
    assertEquals(weights["model1.xml"], 3)
    assertEquals(weights["model2.xml"], 1)
    assertEquals(weights["unpriced.xml"], 1)

    weights = TCAuctionLayout.getModelWeights(models, nil, 3)
    assertEquals(weights["model1.xml"], 1)
end)

test("a role's models over its cap times their median price are left out, before the bands", function()
    local world = setup()
    world:load("src/business/FarmerFleet.lua")
    -- Median 300k (an odd count: the middle one), cap 1.6: 480k and under.
    local catalog = { byRole = { combine = pricedModels(100000, 300000, 750000, 250000, 480000) }, attachments = {} }
    local def = { role = "combine", weight = 1, min = 1, max = 6, medianPriceCap = 1.6 }
    local kept = {}
    for _, model in ipairs(TCAuctionLayout.getLotModels(catalog, "combine", def)) do
        kept[model.xmlFilename] = true
    end
    assertTrue(kept["model1.xml"] and kept["model2.xml"] and kept["model4.xml"] and kept["model5.xml"])
    assertEquals(kept["model3.xml"], nil)

    -- The role's lot limit counts only the models kept.
    local available = TCAuctionLayout.getAvailableRoles(catalog, { def }, 3)
    assertEquals(available.combine, 12)

    -- And no lot is ever the dropped one.
    local roles = {}
    for _ = 1, 12 do
        table.insert(roles, "combine")
    end
    for _, lot in ipairs(TCAuctionLayout.pickLots(catalog, roles, math.random, 3, { def }, 3)) do
        assertTrue(lot.xmlFilename ~= "model3.xml", "the flagship left out")
    end

    -- An even count: the median's the middle two's average (200k and 400k),
    -- so 1.5 keeps up to 450k. An unpriced model's kept; no cap keeps all.
    local even = { byRole = { trailer = pricedModels(100000, 200000, 400000, 500000) }, attachments = {} }
    table.insert(even.byRole.trailer, { xmlFilename = "unpriced.xml" })
    local trailerDef = { role = "trailer", medianPriceCap = 1.5 }
    assertEquals(#TCAuctionLayout.getLotModels(even, "trailer", trailerDef), 4)
    assertEquals(#TCAuctionLayout.getLotModels(even, "trailer", { role = "trailer" }), 5)
    assertEquals(#TCAuctionLayout.getLotModels(even, "trailer", nil), 5)
end)

test("a sale's lots favour a role's cheap band by its boost", function()
    local world = setup()
    world:load("src/business/FarmerFleet.lua")
    -- One cheap model and one dear: boost 3, so the cheap one is 3 in 4.
    local catalog = { byRole = { smallTractor = pricedModels(50000, 150000) }, attachments = {} }
    local defs = { { role = "smallTractor", weight = 1, min = 1, max = 25, cheapShare = 0.5 } }
    local roles = {}
    for _ = 1, 4000 do
        table.insert(roles, "smallTractor")
    end
    local lots = TCAuctionLayout.pickLots(catalog, roles, math.random, nil, defs, 3)
    local cheap = 0
    for _, lot in ipairs(lots) do
        if lot.xmlFilename == "model1.xml" then
            cheap = cheap + 1
        end
    end
    assertNear(cheap / #lots, 0.75, 0.04)

    -- A role's own boost wins over the default.
    defs[1].cheapBoost = 1
    lots = TCAuctionLayout.pickLots(catalog, roles, math.random, nil, defs, 3)
    cheap = 0
    for _, lot in ipairs(lots) do
        if lot.xmlFilename == "model1.xml" then
            cheap = cheap + 1
        end
    end
    assertNear(cheap / #lots, 0.5, 0.04)
end)

-- The crowd's walks (137) ----------------------------------------------------------------------

-- How far a point is from a convex quad (0 inside it).
local function distanceToQuad(x, z, quad)
    local positive, negative = false, false
    local best = math.huge
    for i = 1, 4 do
        local a, b = quad[i], quad[i % 4 + 1]
        local ex, ez = b.x - a.x, b.z - a.z
        local cross = ex * (z - a.z) - ez * (x - a.x)
        positive = positive or cross > 0
        negative = negative or cross < 0
        local t = math.max(0, math.min(1, ((x - a.x) * ex + (z - a.z) * ez) / (ex * ex + ez * ez)))
        best = math.min(best, math.sqrt((x - a.x - ex * t) ^ 2 + (z - a.z - ez * t) ^ 2))
    end
    if not (positive and negative) then
        return 0
    end
    return best
end

-- Every point a walker can be at: both lanes of every loop, every 0.5 m.
local function lanePoints(loops)
    local points = {}
    for _, loop in ipairs(loops) do
        local path = TCAuctionCrowd.buildPath(loop.points)
        for d = 0, path.length, 0.5 do
            local x, z, dx, dz = TCAuctionCrowd.getPathPoint(path, d)
            for _, direction in ipairs({ 1, -1 }) do
                local lx, lz = TCAuctionCrowd.getLanePosition(x, z, dx, dz, direction)
                table.insert(points, { x = lx, z = lz })
            end
        end
    end
    return points
end

local function nearestLot(layout, lots, x, z)
    local nearest = math.huge
    for index in pairs(layout.placed) do
        nearest = math.min(nearest, distanceToQuad(x, z, lotCorners(layout, lots, index)))
    end
    return nearest
end

test("the crowd walks the aisles: no lane or standing group comes within a metre of a lot", function()
    setup()
    for _, case in ipairs({
        { polygon = rectPolygon(0, 0, 300, 160), lots = 60 },
        { polygon = lPolygon(), lots = 40 },
    }) do
        local lots = makeLots(case.lots)
        local layout = TCAuctionLayout.layOut(case.polygon, { x = 310, z = 80 }, lots)
        assertEquals(#layout.walkways, #layout.aisleStrips, "a walkway per row aisle")
        local loops = TCAuctionCrowd.buildWalkwayLoops(layout.walkways)
        assertEquals(#loops, #layout.walkways)
        local points = lanePoints(loops)
        assertTrue(#points > 100)
        for _, point in ipairs(points) do
            assertTrue(nearestLot(layout, lots, point.x, point.z) >= 1.0,
                string.format("a lane at %.1f, %.1f is in among the lots", point.x, point.z))
            assertTrue(TCAuctionCrowd.pointInPolygon(point.x, point.z, case.polygon), "a lane off the field")
        end
        local spots = TCAuctionCrowd.buildWalkwaySpots(loops, 200)
        assertTrue(#spots > 0)
        for _, spot in ipairs(spots) do
            assertTrue(nearestLot(layout, lots, spot.x, spot.z) >= 1.0, "a group in among the lots")
        end
    end
end)

test("standing groups keep clear of the lanes either side of them", function()
    setup()
    local lots = makeLots(30)
    local layout = TCAuctionLayout.layOut(rectPolygon(0, 0, 300, 160), nil, lots)
    local loops = TCAuctionCrowd.buildWalkwayLoops(layout.walkways)
    local points = lanePoints(loops)
    for _, spot in ipairs(TCAuctionCrowd.buildWalkwaySpots(loops, 200)) do
        for _, point in ipairs(points) do
            assertTrue(math.sqrt((spot.x - point.x) ^ 2 + (spot.z - point.z) ^ 2) >= 0.5,
                "a stander on a walker's lane")
        end
    end
end)

test("an aisle too narrow for both lanes and their clearance gets no loop", function()
    setup()
    local narrow = { { x1 = 0, z1 = 0, x2 = 100, z2 = 0, halfWidth = 1.5 } }
    assertEquals(#TCAuctionCrowd.buildWalkwayLoops(narrow), 0)
    local wide = { { x1 = 0, z1 = 0, x2 = 100, z2 = 0, halfWidth = 5 } }
    local loops = TCAuctionCrowd.buildWalkwayLoops(wide)
    assertEquals(#loops, 1)
    for _, point in ipairs(lanePoints(loops)) do
        assertTrue(math.abs(point.z) <= 5 - TCAuctionCrowd.AISLE_CLEARANCE + 0.01, "inside the aisle")
        assertTrue(point.x >= -0.01 and point.x <= 100.01, "not past its ends")
    end
end)

-- 138: lot numbers ----------------------------------------------------------------------------

test("lots are numbered as they're walked: row by row, each row from the entrance end out", function()
    setup()
    local polygon = rectPolygon(0, 0, 300, 160)
    local lots = makeLots(60)
    for _, entrance in ipairs({ { x = 320, z = 80 }, { x = -20, z = 80 } }) do
        local layout = TCAuctionLayout.layOut(polygon, entrance, lots)
        local order = TCAuctionLayout.getWalkOrder(layout.placed)
        assertEquals(#order, layout.placedCount, "every placed lot gets a number")
        local seen = {}
        local lastRow, lastFromEntrance = 0, -math.huge
        for _, index in ipairs(order) do
            assertTrue(not seen[index], "no lot numbered twice")
            seen[index] = true
            local spot = layout.placed[index]
            -- How far along the rows from the entrance's end.
            local u = TCAuctionLayout.toLocal(layout.rect, spot.x, spot.z)
            local fromEntrance = -layout.nearSign * u
            assertTrue(spot.row >= lastRow, "rows in order")
            if spot.row == lastRow then
                assertTrue(fromEntrance > lastFromEntrance, "along a row, away from the entrance")
            end
            lastRow, lastFromEntrance = spot.row, fromEntrance
        end
        assertTrue(lastRow > 1, "more than one row to walk")
    end
end)
