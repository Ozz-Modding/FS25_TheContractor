-- 168: the ploughing match's scoring from sampled data (TCPloughScore): the
-- plot's geometry, the ground's coverage, ragged ends and work outside,
-- splitting the path into runs (reverses and stops counted), each run's
-- straightness, the furrow angle's consistency, and the total ranking a
-- careful, a sloppy and a patchy plot the right way round.

local function setup()
    local world = stubs.install()
    world:load("src/util/TCPloughScore.lua")
    return world
end

-- A plot from (0, 0) facing +z: u is z, v is -x.
local function makePlot(size)
    return TCPloughScore.newPlot(0, 0, 0, 1, size or 40)
end

-- Fills a grid: before 0, ploughed by isPloughed(u, v).
local function fillGrid(grid, isPloughed)
    for _, cell in ipairs(grid.cells) do
        cell.before = 0
        cell.ploughed = isPloughed(cell.u, cell.v) and 1 or 0
    end
    return grid
end

-- A run along the plot's u at across-position v, with sideways wobble
-- wobble(u) (metres) and heading off the line by heading(u) (degrees),
-- one sample a metre at 8 km/h, starting at time t0.
local function runSamples(plot, v, t0, wobble, heading, reverse)
    local samples = {}
    for i = 0, plot.size - 1 do
        local u = reverse and plot.size - 1 - i or i
        local offset = wobble ~= nil and wobble(u) or 0
        local x, z = TCPloughScore.toWorld(plot, u + 0.5, v + offset)
        local deg = heading ~= nil and heading(u) or 0
        local dirSign = reverse and -1 or 1
        local hx = math.sin(math.rad(deg)) * dirSign
        local hz = math.cos(math.rad(deg)) * dirSign
        table.insert(samples, { t = t0 + i * 0.45, x = x, z = z, hx = hx, hz = hz, speed = 8, dir = 1, lowered = true })
    end
    return samples
end

-- The plough raised and turning outside the plot.
local function turnSamples(t0)
    return { { t = t0, x = 0, z = -5, hx = 1, hz = 0, speed = 5, dir = 1, lowered = false } }
end

local function append(into, list)
    for _, s in ipairs(list) do
        table.insert(into, s)
    end
end

-- A whole plot's path: runs every `width` metres, back and forth.
local function plotPath(plot, width, wobble, heading)
    local samples, t = {}, 0
    local v = -plot.size * 0.5 + width * 0.5
    local reverse = false
    while v < plot.size * 0.5 do
        append(samples, runSamples(plot, v, t, wobble, heading, reverse))
        t = t + plot.size * 0.45
        append(samples, turnSamples(t))
        t = t + 20
        v = v + width
        reverse = not reverse
    end
    return samples
end

local function scoreOf(plot, grid, samples, minutes, angles)
    local runs, reverses, stops = TCPloughScore.splitRuns(samples, plot)
    local alongU = TCPloughScore.getWorkAxis(runs, plot)
    return TCPloughScore.score({
        ground = TCPloughScore.measureGround(grid, plot, alongU),
        runs = runs,
        angles = angles,
        reverses = reverses,
        stops = stops,
        minutes = minutes or 150,
    })
end

-- Geometry ----------------------------------------------------------------------------------------

test("a plot is laid from the middle of its near edge, facing in", function()
    setup()
    local plot = TCPloughScore.newPlot(100, 200, 3, 4, 40)
    assertNear(plot.dirX, 0.6, 0.0001)
    local u, v = TCPloughScore.toLocal(plot, 100 + 0.6 * 10, 200 + 0.8 * 10)
    assertNear(u, 10, 0.0001)
    assertNear(v, 0, 0.0001)
    local x, z = TCPloughScore.toWorld(plot, 25, -7)
    u, v = TCPloughScore.toLocal(plot, x, z)
    assertNear(u, 25, 0.0001)
    assertNear(v, -7, 0.0001)
    assertTrue(TCPloughScore.isInside(plot, 1, 19.9))
    assertTrue(not TCPloughScore.isInside(plot, -0.5, 0))
    assertTrue(TCPloughScore.isInside(plot, -0.5, 0, 1))
    assertEquals(#TCPloughScore.getCorners(plot), 4)
end)

test("the grid covers the plot and its margin, cells inside marked", function()
    setup()
    local plot = makePlot(40)
    local grid = TCPloughScore.makeGrid(plot)
    assertEquals(grid.count, 48)
    assertEquals(#grid.cells, 48 * 48)
    local inside = 0
    for _, cell in ipairs(grid.cells) do
        if cell.inside then
            inside = inside + 1
        end
    end
    assertEquals(inside, 40 * 40)
end)

-- The ground ---------------------------------------------------------------------------------------

test("coverage counts only ground ploughed since the start", function()
    setup()
    local plot = makePlot(40)
    local grid = TCPloughScore.makeGrid(plot)
    for _, cell in ipairs(grid.cells) do
        -- The left half was ploughed already; now all of it is.
        cell.before = (cell.inside and cell.v < 0) and 1 or 0
        cell.ploughed = cell.inside and 1 or 0
    end
    local ground = TCPloughScore.measureGround(grid, plot, true)
    assertNear(ground.coverage, 1, 0.0001)
    assertNear(ground.alreadyPloughed, 0.5, 0.0001)
    assertNear(ground.ploughedArea, 800, 0.0001)
end)

test("a missed strip lowers coverage; ragged ends are the end bands left", function()
    setup()
    local plot = makePlot(40)
    -- Everything but a 4 m strip down the middle and the last 2 m at the far end.
    local grid = fillGrid(TCPloughScore.makeGrid(plot), function(u, v)
        return TCPloughScore.isInside(plot, u, v) and math.abs(v) > 2 and u < 38
    end)
    local ground = TCPloughScore.measureGround(grid, plot, true)
    assertNear(ground.coverage, 36 * 38 / 1600, 0.0001)
    -- End bands: u in 0..3 and 37..40 (6 rows of 40); unploughed: the strip
    -- in all six (4 x 6), plus the last two rows outside it (2 x 36).
    assertNear(ground.raggedEnds, (24 + 72) / 240, 0.0001)
    assertNear(ground.outsideArea, 0, 0.0001)
end)

test("the ends follow the work: runs across the plot make its sides the ends", function()
    setup()
    local plot = makePlot(40)
    -- Unploughed: the first metre at u = 0.
    local grid = fillGrid(TCPloughScore.makeGrid(plot), function(u, v)
        return TCPloughScore.isInside(plot, u, v) and u > 1
    end)
    assertTrue(TCPloughScore.measureGround(grid, plot, true).raggedEnds > 0)
    assertNear(TCPloughScore.measureGround(grid, plot, false).raggedEnds, 1 / 40, 0.0001)
end)

test("ploughing into the margin is measured in square metres", function()
    setup()
    local plot = makePlot(40)
    local grid = fillGrid(TCPloughScore.makeGrid(plot), function(u, v)
        return TCPloughScore.isInside(plot, u, v, 2) and u < 40
    end)
    local ground = TCPloughScore.measureGround(grid, plot, true)
    assertNear(ground.coverage, 1, 0.0001)
    -- 2 m either side for u in -2..40 (42 x 4) plus 2 m before the near edge (2 x 40).
    assertNear(ground.outsideArea, 42 * 4 + 80, 0.0001)
end)

-- The path ------------------------------------------------------------------------------------------

test("a straight run has no drift; a wobbly one drifts and its heading wanders", function()
    setup()
    local plot = makePlot(40)
    local straight = TCPloughScore.measureRun(runSamples(plot, 0, 0))
    assertNear(straight.length, 39, 0.0001)
    assertNear(straight.lateralRms, 0, 0.0001)
    assertNear(straight.headingRms, 0, 0.0001)
    local wobbly = TCPloughScore.measureRun(runSamples(plot, 0, 0,
        function(u) return math.sin(u / 6) * 0.8 end,
        function(u) return math.cos(u / 6) * 6 end))
    assertTrue(wobbly.lateralRms > 0.3)
    assertTrue(wobbly.lateralMax > wobbly.lateralRms)
    assertTrue(wobbly.headingRms > 2)
    assertTrue(TCPloughScore.scoreRun(straight) > TCPloughScore.scoreRun(wobbly))
end)

test("a run going the other way is just as straight (the axis has no direction)", function()
    setup()
    local plot = makePlot(40)
    local back = TCPloughScore.measureRun(runSamples(plot, 0, 0, nil, nil, true))
    assertNear(back.headingRms, 0, 0.0001)
    assertNear(TCPloughScore.scoreRun(back), 1, 0.0001)
end)

test("the path splits into runs at the turns; short touch-ups aren't judged", function()
    setup()
    local plot = makePlot(40)
    local samples = {}
    append(samples, runSamples(plot, -10, 0))
    append(samples, turnSamples(20))
    append(samples, runSamples(plot, -8, 30, nil, nil, true))
    append(samples, turnSamples(50))
    -- A 5 m touch-up.
    local short = runSamples(plot, 5, 60)
    for i = 1, 5 do
        table.insert(samples, short[i])
    end
    local runs, reverses, stops = TCPloughScore.splitRuns(samples, plot)
    assertEquals(#runs, 2)
    assertEquals(reverses, 0)
    assertEquals(stops, 0)
    assertTrue(TCPloughScore.getWorkAxis(runs, plot))
end)

test("reversing with the plough down counts once a time; raised it doesn't", function()
    setup()
    local plot = makePlot(40)
    local samples = runSamples(plot, 0, 0)
    for i = 1, 3 do
        table.insert(samples, { t = 20 + i, x = 0, z = 30 - i, hx = 0, hz = 1, speed = 3, dir = -1, lowered = true })
    end
    table.insert(samples, { t = 24, x = 0, z = 26, hx = 0, hz = 1, speed = 3, dir = 1, lowered = true })
    table.insert(samples, { t = 25, x = 0, z = 25, hx = 0, hz = 1, speed = 3, dir = -1, lowered = true })
    table.insert(samples, { t = 26, x = 0, z = 24, hx = 0, hz = 1, speed = 3, dir = -1, lowered = false })
    local _, reverses = TCPloughScore.splitRuns(samples, plot)
    assertEquals(reverses, 2)
end)

test("a stop mid-run counts; standing at the run's start or end doesn't", function()
    setup()
    local plot = makePlot(40)
    local run = runSamples(plot, 0, 0)
    local function still(sample)
        sample.speed = 0
    end
    -- At the start (samples 1-10) and the end (the last 5), and 5 s mid-run.
    for i = 1, 10 do
        still(run[i])
    end
    for i = #run - 4, #run do
        still(run[i])
    end
    for i = 20, 32 do
        still(run[i])
    end
    assertEquals(TCPloughScore.countStops(run), 1)
    -- Too short a pause isn't a stop.
    local brief = runSamples(plot, 0, 0)
    for i = 20, 23 do
        still(brief[i])
    end
    assertEquals(TCPloughScore.countStops(brief), 0)
end)

-- The furrow angle ----------------------------------------------------------------------------------

test("the furrow angle's consistency is the best two neighbouring values, wrapping", function()
    setup()
    assertNear(TCPloughScore.measureAngles({ 50, 40, 5, 5, 0, 0, 0, 0 }).share, 0.9, 0.0001)
    assertNear(TCPloughScore.measureAngles({ 45, 5, 5, 0, 0, 0, 0, 45 }).share, 0.9, 0.0001)
    assertEquals(TCPloughScore.measureAngles({ 0, 0, 0 }), nil)
end)

-- The score -----------------------------------------------------------------------------------------

test("a careful plot scores full marks", function()
    setup()
    local plot = makePlot(40)
    local grid = fillGrid(TCPloughScore.makeGrid(plot), function(u, v)
        return TCPloughScore.isInside(plot, u, v)
    end)
    local result = scoreOf(plot, grid, plotPath(plot, 1.6), 150, { share = 1 })
    assertNear(result.total, 100, 0.0001)
    assertEquals(result.minutesOver, 0)
end)

test("careful beats sloppy beats patchy", function()
    setup()
    local plot = makePlot(40)
    local full = function(u, v)
        return TCPloughScore.isInside(plot, u, v)
    end
    local careful = scoreOf(plot, fillGrid(TCPloughScore.makeGrid(plot), full), plotPath(plot, 1.6), 150)
    -- Sloppy: every run wobbles, a little ploughed over the ends.
    local sloppy = scoreOf(plot, fillGrid(TCPloughScore.makeGrid(plot), function(u, v)
        return TCPloughScore.isInside(plot, u, v, 1)
    end), plotPath(plot, 1.6, function(u) return math.sin(u / 5) * 0.6 end,
        function(u) return math.cos(u / 5) * 5 end), 150)
    -- Patchy: straight, but strips left every 8 m and the far end short.
    local patchy = scoreOf(plot, fillGrid(TCPloughScore.makeGrid(plot), function(u, v)
        return full(u, v) and (math.floor(v + 20) % 8) ~= 0 and u < 36
    end), plotPath(plot, 1.6), 150)
    assertTrue(careful.total > sloppy.total)
    assertTrue(sloppy.total > patchy.total)
    assertTrue(careful.parts.straightness.marks > sloppy.parts.straightness.marks)
    assertTrue(sloppy.parts.outside.marks < careful.parts.outside.marks)
    assertTrue(patchy.parts.coverage.marks < sloppy.parts.coverage.marks)
end)

test("speed earns nothing; each game minute over the limit costs", function()
    setup()
    local plot = makePlot(40)
    local grid = fillGrid(TCPloughScore.makeGrid(plot), function(u, v)
        return TCPloughScore.isInside(plot, u, v)
    end)
    local path = plotPath(plot, 1.6)
    local quick = scoreOf(plot, grid, path, 30)
    local steady = scoreOf(plot, grid, path, 179.5)
    assertNear(steady.total, quick.total, 0.0001)
    local late = scoreOf(plot, grid, path, 190)
    assertEquals(late.minutesOver, 10)
    assertNear(late.total, steady.total - 10 * TCPloughScore.RULES.minutePenalty, 0.0001)
end)

test("the furrow angle is left out of the total when it can't be read", function()
    setup()
    local plot = makePlot(40)
    local grid = fillGrid(TCPloughScore.makeGrid(plot), function(u, v)
        return TCPloughScore.isInside(plot, u, v)
    end)
    local result = scoreOf(plot, grid, plotPath(plot, 1.6), 150, nil)
    assertEquals(result.parts.furrowAngle, nil)
    assertNear(result.total, 100, 0.0001)
end)

test("nothing ploughed and no runs scores nothing", function()
    setup()
    local plot = makePlot(40)
    local grid = fillGrid(TCPloughScore.makeGrid(plot), function() return false end)
    local result = scoreOf(plot, grid, {}, 0)
    assertNear(result.total, 0, 0.0001)
end)

-- Sizing ------------------------------------------------------------------------------------------

test("the estimate grows with the plot, and sizeForMinutes inverts it", function()
    setup()
    -- 40 m at 1.6 m: 25 runs of 18 s and 24 turns of 20 s.
    assertNear(TCPloughScore.estimateMinutes(40, 1.6), (25 * 18 + 24 * 20) / 60, 0.0001)
    local size = TCPloughScore.sizeForMinutes(20, 1.6)
    assertTrue(TCPloughScore.estimateMinutes(size, 1.6) <= 20)
    assertTrue(TCPloughScore.estimateMinutes(size + 1, 1.6) > 20)
end)
