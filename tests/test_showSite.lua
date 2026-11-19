-- 164: the show site. The pure half (TCShowSite): splitting a polygon and a
-- field's rectangle into the showground and the ploughing ground, laying
-- plots and picking the flattest run, pairing fields next to each other, and
-- ranking (one field before a pair). The engine half (TheContractorShowSite):
-- the candidates on fake fields, a vine refused, dressing (each field
-- snapshotted, the showground side grass and the rest stubble of its crop),
-- putting it back, and both kept through a save. The ground painting itself
-- is the engine's, so it's recorded, not run.

local function setup()
    local world = stubs.install()
    world:load("src/util/TCAuctionCrowd.lua")
    world:load("src/util/TCAuctionLayout.lua")
    world:load("src/util/TCShowSite.lua")
    return world
end

local function rectPolygon(x1, z1, x2, z2)
    return { { x = x1, z = z1 }, { x = x2, z = z1 }, { x = x2, z = z2 }, { x = x1, z = z2 } }
end

-- An L: a 300 x 100 strip along x with a 100 x 300 leg up from its left end.
local function lPolygon()
    return {
        { x = 0, z = 0 }, { x = 300, z = 0 }, { x = 300, z = 100 }, { x = 100, z = 100 },
        { x = 100, z = 300 }, { x = 0, z = 300 },
    }
end

local function insideRect(rect, x, z, slack)
    local u, v = TCShowSite.toLocal(rect, x, z)
    slack = slack or 0.01
    return math.abs(u) <= rect.halfU + slack and math.abs(v) <= rect.halfV + slack
end

-- Splitting -------------------------------------------------------------------------------

test("a polygon cut along a line: the two sides make up the whole, a concave one too", function()
    setup()
    local square = rectPolygon(0, 0, 100, 100)
    local left = TCShowSite.clipPolygon(square, 40, 0, -1, 0)
    local right = TCShowSite.clipPolygon(square, 40, 0, 1, 0)
    assertNear(TCShowSite.getArea(left), 4000, 0.01)
    assertNear(TCShowSite.getArea(right), 6000, 0.01)
    for _, p in ipairs(right) do
        assertTrue(p.x >= 40 - 0.001, "the right side's right of the line")
    end
    local l = lPolygon()
    local total = TCShowSite.getArea(l)
    local a = TCShowSite.clipPolygon(l, 0, 150, 0.6, 0.8)
    local b = TCShowSite.clipPolygon(l, 0, 150, -0.6, -0.8)
    assertNear(TCShowSite.getArea(a) + TCShowSite.getArea(b), total, 0.01)
    assertEquals(#TCShowSite.clipPolygon(square, 200, 0, 1, 0), 0, "all on the other side")
end)

test("one field: the showground at the road's end, a divide, then the ploughing ground", function()
    setup()
    local R = TCShowSite.RULES
    local rect = { cx = 0, cz = 0, angle = 0, halfU = 180, halfV = 80 }
    local split = TCShowSite.splitSingle(rect, { x = 250, z = 0 })
    assertEquals(split.nearSign, 1)
    assertNear(split.showRect.halfU * 2, R.showgroundLength, 0.001)
    assertNear(split.showRect.cx, 180 - R.showgroundLength / 2, 0.001)
    assertNear(split.ploughRect.halfU * 2, 360 - R.showgroundLength - R.divide, 0.001)
    assertNear(split.ploughRect.cx, -180 + split.ploughRect.halfU, 0.001)
    assertNear(split.showRect.halfV, 80, 0.001)
    -- The line's in the divide, its normal towards the showground.
    assertNear(split.line.x, 180 - R.showgroundLength - R.divide / 2, 0.001)
    assertNear(split.line.nx, 1, 0.001)

    -- The road at the other end, or none: the showground's at -u.
    local other = TCShowSite.splitSingle(rect, { x = -250, z = 0 })
    assertEquals(other.nearSign, -1)
    assertNear(other.showRect.cx, -180 + R.showgroundLength / 2, 0.001)
    assertNear(other.line.nx, -1, 0.001)
    assertEquals(TCShowSite.splitSingle(rect, nil).nearSign, -1)
end)

test("one field too short or too narrow for the showground and a plot can't be split", function()
    setup()
    local R = TCShowSite.RULES
    local short = R.showgroundLength + R.divide + R.plotSize - 1
    assertEquals(TCShowSite.splitSingle({ cx = 0, cz = 0, angle = 0, halfU = short / 2, halfV = 80 }, nil), nil)
    assertEquals(TCShowSite.splitSingle({ cx = 0, cz = 0, angle = 0, halfU = 200, halfV = R.showgroundWidth / 2 - 1 },
        nil), nil)
end)

test("the field's polygon either side of the line: the showground's side and the rest", function()
    setup()
    local polygon = rectPolygon(-190, -90, 190, 90)
    local split = TCShowSite.splitSingle({ cx = 0, cz = 0, angle = 0, halfU = 180, halfV = 80 }, { x = 250, z = 0 })
    local show, plough = TCShowSite.splitPolygon(polygon, split.line)
    assertNear(TCShowSite.getArea(show) + TCShowSite.getArea(plough), TCShowSite.getArea(polygon), 0.01)
    for _, p in ipairs(show) do
        assertTrue(p.x >= split.line.x - 0.001)
    end
    -- The showground's rectangle is on its side, the ploughing ground's on the other.
    assertTrue(split.showRect.cx - split.showRect.halfU >= split.line.x)
    assertTrue(split.ploughRect.cx + split.ploughRect.halfU <= split.line.x)
end)

-- Plots ------------------------------------------------------------------------------------

test("plots go in rows along the ploughing ground's long side, square, apart, inside, centred", function()
    setup()
    local R = TCShowSite.RULES
    local region = { cx = 50, cz = 20, angle = math.rad(30), halfU = 120, halfV = 50 }
    local rows = TCShowSite.layPlots(region)
    local step = R.plotSize + R.plotGap
    assertEquals(#rows, math.floor((100 + R.plotGap) / step))
    assertEquals(#rows[1], math.floor((240 + R.plotGap) / step))
    local sumU = 0
    for _, row in ipairs(rows) do
        for i, plot in ipairs(row) do
            assertNear(plot.half, R.plotSize / 2, 0.001)
            for _, corner in ipairs(TCShowSite.getCorners(TCShowSite.plotRect(plot))) do
                assertTrue(insideRect(region, corner.x, corner.z), "a plot's corner outside the ground")
            end
            if i > 1 then
                local u1 = TCShowSite.toLocal(region, row[i - 1].cx, row[i - 1].cz)
                local u2 = TCShowSite.toLocal(region, plot.cx, plot.cz)
                assertNear(u2 - u1, step, 0.001)
            end
            sumU = sumU + TCShowSite.toLocal(region, plot.cx, plot.cz)
        end
    end
    assertNear(sumU, 0, 0.01)

    -- Across a ground longer in v, the rows run across it.
    local tall = TCShowSite.layPlots({ cx = 0, cz = 0, angle = 0, halfU = 30, halfV = 120 })
    assertEquals(#tall, 1)
    assertEquals(#tall[1], math.floor((240 + R.plotGap) / step))
    assertNear(tall[1][1].cx, 0, 0.001)
end)

test("the plots: a run in one row, up to the most there can be, the flattest, then the most central", function()
    setup()
    local R = TCShowSite.RULES
    local function row(n, r)
        local plots = {}
        for s = 1, n do
            table.insert(plots, { row = r or 1, slot = s })
        end
        return plots
    end
    -- Eight in a row: six taken; the steep one at the start is left out.
    local slopes = { 9, 2, 1, 1, 1, 1, 1, 1 }
    local plots, worst = TCShowSite.pickPlots({ row(8) }, nil, function(plot) return slopes[plot.slot] end)
    assertEquals(#plots, R.maxPlots)
    assertEquals(plots[1].slot, 3)
    assertEquals(worst, 1)

    -- All flat: the middle six.
    plots = TCShowSite.pickPlots({ row(8) })
    assertEquals(plots[1].slot, 2)

    -- A row with too few; another row's run is taken.
    plots = TCShowSite.pickPlots({ row(R.minPlots - 1, 1), row(R.minPlots, 2) })
    assertEquals(#plots, R.minPlots)
    assertEquals(plots[1].row, 2)
    assertEquals(#TCShowSite.pickPlots({ row(R.minPlots - 1) }), 0)

    -- Of two rows, the flatter.
    plots = TCShowSite.pickPlots({ row(6, 1), row(6, 2) }, nil, function(plot) return plot.row == 1 and 5 or 2 end)
    assertEquals(plots[1].row, 2)
end)

-- Two fields -------------------------------------------------------------------------------

test("fields next to each other pair up, nearest first; fields far apart don't", function()
    setup()
    local fields = {
        { id = 3, polygon = rectPolygon(0, 0, 100, 100) },
        { id = 1, polygon = rectPolygon(110, 0, 200, 100) },   -- 10 m east of 3
        { id = 2, polygon = rectPolygon(0, 104, 60, 200) },    -- 4 m north of 3, well clear of 1
        { id = 4, polygon = rectPolygon(500, 500, 600, 600) }, -- nowhere near
    }
    local pairs_ = TCShowSite.findPairs(fields, 15)
    assertEquals(#pairs_, 2)
    assertEquals(pairs_[1].a, 2)
    assertEquals(pairs_[1].b, 3)
    assertNear(pairs_[1].gap, 4, 0.001)
    assertEquals(pairs_[2].a, 1)
    assertEquals(pairs_[2].b, 3)
    assertNear(pairs_[2].gap, 10, 0.001)
    assertEquals(#TCShowSite.findPairs(fields, 3), 0)
    -- A corner coming near an edge counts, not just corner to corner.
    assertNear(TCShowSite.getGap(rectPolygon(0, 0, 100, 100), { { x = 50, z = 105 }, { x = 60, z = 200 },
        { x = 40, z = 200 } }), 5, 0.001)
end)

-- Ranking ----------------------------------------------------------------------------------

test("ranking: those that can hold the show first, one field before a pair, then plots, flatness, size", function()
    setup()
    local R = TCShowSite.RULES
    local function candidate(id, mode, overrides)
        local c = { mode = mode, fieldIds = { id }, hasShowground = true, plotCount = R.maxPlots, plotSlope = 2,
            showgroundSlope = 2, entranceDistance = 10, areaHa = 10 }
        for key, value in pairs(overrides or {}) do
            c[key] = value
        end
        return c
    end
    local S, P = TCShowSite.MODE.SINGLE, TCShowSite.MODE.PAIR
    local ranked = TCShowSite.rankCandidates({
        candidate(1, P),
        candidate(2, S, { plotCount = R.minPlots }),
        candidate(3, S, { plotSlope = R.maxPlotSlopePercent + 1 }),
        candidate(4, S, { plotSlope = 1 }),
        candidate(5, S),
        candidate(6, S, { entranceDistance = R.entranceReach + 1 }),
        candidate(7, S, { hasShowground = false, plotCount = 0 }),
    })
    local order = {}
    for _, c in ipairs(ranked) do
        table.insert(order, c.fieldIds[1])
    end
    assertEquals(table.concat(order, ","), "4,5,2,1,6,3,7")
    local P_ = TCShowSite.PROBLEM
    assertEquals(ranked[5].problems[1], P_.NO_ROAD)
    assertEquals(ranked[6].problems[1], P_.TOO_STEEP)
    assertEquals(ranked[7].problems[1], P_.NO_SHOWGROUND)
    assertEquals(ranked[7].problems[2], P_.TOO_FEW_PLOTS)
end)

-- The engine half ------------------------------------------------------------------------------

local function setupGame()
    local world = setup()
    TheContractor = { SaveKey = "TheContractor" }
    FieldGroundType = {}
    world:load("src/util/TCFieldPreparation.lua")
    world:load("src/business/ShowSite.lua")
    TCSiteClearance = { PERMANENT_CROPS = { GRAPE = true } }

    -- The ground's painting, recorded.
    world.painted = {}
    TCFieldPreparation.snapshotField = function(field)
        return { fruitType = field.crop, growthState = 3, weedState = 0, stoneLevel = 0, groundType = "SOWN",
            sprayType = "NONE", sprayLevel = 0, limeLevel = 0, rollerLevel = 0, plowLevel = 0,
            stubbleShredLevel = 0, waterLevel = 0 }
    end
    TCFieldPreparation.makeArea = function(points) return { points = points } end
    TCFieldPreparation.putDownGrass = function(field, area)
        table.insert(world.painted, { what = "grass", fieldId = field:getId(), area = area })
        return true
    end
    TCFieldPreparation.putDownStubble = function(field, crop, area)
        table.insert(world.painted, { what = "stubble", fieldId = field:getId(), crop = crop, area = area })
        return true
    end
    TCFieldPreparation.getStubbleCrop = function(name) return { name = name } end
    TCFieldPreparation.restoreField = function(field, snapshot)
        table.insert(world.painted, { what = "restore", fieldId = field:getId(), crop = snapshot.fruitType })
        return true
    end

    -- Fields: each a polygon, held by a farmer, with a crop.
    world.fields, world.fieldList = {}, {}
    g_fieldManager = {
        getFieldById = function(_, id) return world.fields[id] end,
        getFields = function() return world.fieldList end,
    }
    world.fruits = { WHEAT = { index = 1, name = "WHEAT" }, GRAPE = { index = 2, name = "GRAPE" } }
    g_fruitTypeManager = {
        getFruitTypeByIndex = function(_, index)
            for _, fruit in pairs(world.fruits) do
                if fruit.index == index then
                    return fruit
                end
            end
            return nil
        end,
    }
    function world:addField(id, polygon, crop)
        local field = { id = id, polygon = polygon, crop = crop or "WHEAT", holder = { id = 7 } }
        function field:getId() return self.id end
        function field:getAreaHa() return TCShowSite.getArea(self.polygon) / 10000 end
        function field:getFieldState()
            return { fruitTypeIndex = world.fruits[self.crop] ~= nil and world.fruits[self.crop].index or nil }
        end
        self.fields[id] = field
        table.insert(self.fieldList, field)
        return field
    end
    TCAuctionCrowd.getFieldPolygon = function(field) return field.polygon end
    TheContractorEventDay = { getHolder = function(field) return field.holder end }
    world.refusals = {}
    TheContractorAuctionSite = { getFieldRefusal = function(field) return world.refusals[field:getId()] end }
    world.roads = { { x = 400, z = 50 } }
    TheContractorFallenTree = { sampleRoads = function() return world.roads end }
    world.heights = function() return 10 end
    g_terrainNode = "terrain"
    getTerrainHeightAtWorldPos = function(_, x, _, z) return world.heights(x, z) end
    getTimeSec = function() return 0 end

    local showSite = TheContractorShowSite.new()
    g_currentMission.TheContractor.ShowSite = showSite
    world.showSite = showSite
    return world
end

test("candidates: a big field on its own first, a pair of smaller ones next, a vine or a live job never", function()
    local world = setupGame()
    -- 380 x 110: a showground, a divide and four or more plots in a row.
    world:addField(1, rectPolygon(0, 0, 380, 110))
    -- Two 200 x 110 fields 8 m apart: neither on its own.
    world:addField(2, rectPolygon(0, 300, 200, 410))
    world:addField(3, rectPolygon(208, 300, 408, 410))
    world:addField(4, rectPolygon(0, 600, 380, 710), "GRAPE")
    world:addField(5, rectPolygon(0, 900, 380, 1010))
    world.refusals[5] = "it has a live job"
    world.roads = { { x = 400, z = 50 }, { x = 210, z = 420 }, { x = 400, z = 650 }, { x = 400, z = 950 } }

    local ranked = world.showSite:getCandidates()
    local best = ranked[1]
    assertEquals(#best.problems, 0)
    assertEquals(best.mode, TCShowSite.MODE.SINGLE)
    assertEquals(best.fieldIds[1], 1)
    assertTrue(best.plotCount >= TCShowSite.RULES.minPlots)
    local pairOk = nil
    for _, candidate in ipairs(ranked) do
        assertTrue(candidate.fieldIds[1] ~= 4 and candidate.fieldIds[1] ~= 5, "never a vine or a live job")
        if candidate.mode == TCShowSite.MODE.PAIR and #candidate.problems == 0 then
            pairOk = pairOk or candidate
        end
        if candidate.mode == TCShowSite.MODE.SINGLE and candidate.fieldIds[1] ~= 1 then
            assertTrue(#candidate.problems > 0, "fields 2 and 3 can't on their own")
        end
    end
    assertTrue(pairOk ~= nil, "the pair can")
    local picked = world.showSite:pickBest()
    assertEquals(picked.mode, best.mode)
    assertEquals(picked.fieldIds[1], best.fieldIds[1])
end)

test("steep plots are passed over for flat ones, and a field steep all over can't hold it", function()
    local world = setupGame()
    -- 600 m long: room for the showground and more plots than are wanted.
    world:addField(1, rectPolygon(0, 0, 600, 110))
    world.roads = { { x = 620, z = 50 } }
    -- The far end (x < 150) climbs steeply.
    world.heights = function(x) return x < 150 and (150 - x) * 0.3 or 0 end
    local candidate = world.showSite:planOn(1)
    assertEquals(candidate.plotCount, TCShowSite.RULES.maxPlots)
    for _, plot in ipairs(candidate.plan.plots) do
        assertTrue(plot.cx - plot.half >= 150 - 0.01, "a plot on the slope")
    end
    assertTrue(candidate.plotSlope < 1)

    world.heights = function(x) return x * 0.2 end
    candidate = TCShowSite.rankCandidates({ world.showSite:planOn(1) })[1]
    assertEquals(candidate.problems[1], TCShowSite.PROBLEM.TOO_STEEP)
end)

test("dressing one field: snapshotted, its showground side grass, the rest stubble of its crop; put back after", function()
    local world = setupGame()
    world:addField(1, rectPolygon(0, 0, 380, 110), "WHEAT")
    world.showSite:consolePlan(1)
    local plan = world.showSite.site.plan
    assertEquals(plan.mode, TCShowSite.MODE.SINGLE)

    world.showSite:dress()
    assertTrue(world.showSite.site.dressed)
    assertEquals(world.showSite.site.snapshots[1].fruitType, "WHEAT")
    assertEquals(#world.painted, 2)
    local grass, stubble = world.painted[1], world.painted[2]
    assertEquals(grass.what, "grass")
    assertEquals(stubble.what, "stubble")
    assertEquals(stubble.crop, "WHEAT")
    -- Each side of the line, between them the whole field.
    local line = plan.line
    for _, p in ipairs(grass.area.points) do
        assertTrue((p.x - line.x) * line.nx + (p.z - line.z) * line.nz >= -0.001, "grass past the line")
    end
    assertNear(TCShowSite.getArea(grass.area.points) + TCShowSite.getArea(stubble.area.points), 380 * 110, 0.1)
    -- The road's at the +x end: the showground's there.
    assertTrue(line.nx > 0)
    assertTrue(world.showSite:dress() ~= nil and #world.painted == 2, "not dressed twice")

    world.showSite:restore()
    assertEquals(world.painted[3].what, "restore")
    assertEquals(world.painted[3].crop, "WHEAT")
    assertTrue(not world.showSite.site.dressed)
end)

test("dressing a pair: the showground field all grass, the other all stubble; each put back to its own", function()
    local world = setupGame()
    world:addField(2, rectPolygon(0, 300, 200, 410), "WHEAT")
    world:addField(3, rectPolygon(208, 300, 408, 410), "BARLEY")
    world.roads = { { x = -10, z = 350 } }
    world.showSite:consolePlan(2, 3)
    assertEquals(world.showSite.site.plan.mode, TCShowSite.MODE.PAIR)
    world.showSite:dress()
    assertEquals(world.painted[1].what, "grass")
    assertEquals(world.painted[1].fieldId, 2)
    assertEquals(world.painted[1].area, nil, "the whole field")
    assertEquals(world.painted[2].what, "stubble")
    assertEquals(world.painted[2].fieldId, 3)
    assertEquals(world.painted[2].crop, "BARLEY")
    world.showSite:clear()
    local restored = {}
    for _, painted in ipairs(world.painted) do
        if painted.what == "restore" then
            restored[painted.fieldId] = painted.crop
        end
    end
    assertEquals(restored[2], "WHEAT")
    assertEquals(restored[3], "BARLEY")
    assertEquals(world.showSite.site, nil)

    -- Fields too far apart don't pair.
    world:addField(4, rectPolygon(600, 300, 800, 410))
    local candidate = world.showSite:planOn(2, 4)
    assertEquals(candidate, nil)
end)

test("a dressed site survives a save and is still put back after a load; an undressed plan too", function()
    local world = setupGame()
    world:addField(1, rectPolygon(0, 0, 380, 110), "WHEAT")
    world.showSite:consolePlan(1)
    world.showSite:dress()
    local plan = world.showSite.site.plan

    local xmlFile = {}
    world.showSite:saveToXmlFile(xmlFile)
    local loaded = TheContractorShowSite.new()
    loaded:loadFromXMLFile(xmlFile)
    assertTrue(loaded.site.dressed)
    assertEquals(loaded.site.plan.showFieldId, 1)
    assertEquals(#loaded.site.plan.plots, #plan.plots)
    assertNear(loaded.site.plan.line.x, plan.line.x, 0.001)
    assertNear(loaded.site.plan.showRect.halfU, plan.showRect.halfU, 0.001)
    assertNear(loaded.site.plan.plots[2].cx, plan.plots[2].cx, 0.001)
    assertEquals(loaded.site.snapshots[1].fruitType, "WHEAT")
    loaded:restore()
    assertEquals(world.painted[#world.painted].what, "restore")

    local emptyFile = {}
    TheContractorShowSite.new():saveToXmlFile(emptyFile)
    local none = TheContractorShowSite.new()
    none:loadFromXMLFile(emptyFile)
    assertEquals(none.site, nil)
end)
