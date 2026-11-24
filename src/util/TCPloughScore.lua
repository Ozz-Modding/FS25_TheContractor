-- Ploughing match scoring (168, spike): the pure half of TCPloughTrial.
-- Real matches are judged on the opening split, straight and even work,
-- neat ends and finishing in time, never on speed. Everything here works on
-- plain numbers and tables sampled in game (the plot's ground, cell by cell,
-- and the plough's path), so it's tested outside the game
-- (tests/test_ploughScore.lua).
--
--   The plot: a square SIZE a side, laid from a point in the middle of its
--     near edge along a direction (where the ploughman stands, facing in).
--     Plot-local coordinates: u along that direction (0 at the near edge,
--     size at the far one), v across (-size/2..size/2).
--   The ground (measureGround): a grid of cells over the plot and a MARGIN
--     round it. Each cell holds the share of it that was ploughed when the
--     trial started (before) and now (ploughed). Only ground ploughed since
--     the start counts, so a plot that was partly ploughed already is
--     scored on what was left.
--       coverage: the share of the plot's unploughed ground now ploughed.
--       ragged ends: the share of the end bands (END_BAND deep, at the two
--         ends of the runs) still unploughed.
--       outside: square metres newly ploughed in the margin.
--   The path (splitRuns, measureRun): the plough's position and heading,
--     sampled while the trial runs. A run is the plough lowered, going
--     forward, inside the plot; runs shorter than MIN_RUN_LENGTH are
--     touch-ups and aren't judged. Each run's straightness is how far it
--     drifts sideways from its own best-fit line (RMS, metres) and how much
--     the heading wanders off that line (RMS, degrees). The first judged run
--     is the opening split, scored on its own.
--       reverses: reversing with the plough down (each time it starts).
--       stops: standing still with the plough down mid-run, at least
--         STOP_SECONDS (not at a run's start or end).
--   The furrow angle (measureAngles): the ground's own direction per pixel
--     (FieldDensityMap.GROUND_ANGLE), as a histogram of the plot's ploughed
--     pixels by angle value. Its consistency is the share in the best two
--     neighbouring values (a straight run along a bin's edge splits two).
--   The score (score): each part 0..1 from a linear range (full marks at
--     one end, none at the other), times its weight; the total is out of
--     100 over the parts that could be measured, less MINUTE_PENALTY per
--     game minute over the time limit (3 game hours, the user's call: the
--     player sets the time scale so that's about 15 real minutes). Speed
--     never earns marks.

TCPloughScore = {}

TCPloughScore.RULES = {
    plotSize = 35,            -- m a side (164's TCShowSite.RULES.plotSize)
    timeLimitMinutes = 180,   -- game minutes (the clock), the user's call
    cellSize = 1,             -- m, the ground's sampling grid
    margin = 4,               -- m round the plot sampled for ploughing outside it
    endBand = 3,              -- m deep at each end of the runs
    minRunLength = 10,        -- m: shorter runs aren't judged
    stopSpeed = 0.5,          -- km/h: slower than this is standing still
    stopSeconds = 3,          -- a stop shorter than this isn't counted
    minutePenalty = 0.2,      -- marks off the total per game minute over the limit
    -- Each part's weight (out of 100 when every part is measured).
    weights = {
        coverage = 35,
        straightness = 20,
        split = 10,
        furrowAngle = 5,
        ends = 10,
        outside = 5,
        tidiness = 15,
    },
    -- { full marks at, no marks at }.
    ranges = {
        coverage = { 0.99, 0.80 },
        lateralRms = { 0.15, 1.0 },      -- m
        headingRms = { 1.5, 8 },         -- degrees
        angleShare = { 0.95, 0.6 },
        raggedEnds = { 0.05, 0.4 },      -- share unploughed
        outsideArea = { 5, 60 },         -- m2
    },
    lateralShare = 0.7,       -- of a run's straightness; the heading the rest
    reverseCost = 0.2,        -- of the tidiness part, per reverse
    stopCost = 0.1,           -- per stop
    -- The time estimate (estimateMinutes).
    estimateSpeedKmh = 8,
    estimateTurnSeconds = 20,
}

TCPloughScore.PARTS = { "coverage", "straightness", "split", "furrowAngle", "ends", "outside", "tidiness" }

-- 0..1: full at `full`, none at `zero`, linear between (either way round).
function TCPloughScore.linear(value, full, zero)
    if full == zero then
        return value == full and 1 or 0
    end
    local t = (value - zero) / (full - zero)
    return math.max(0, math.min(1, t))
end

-- The plot ---------------------------------------------------------------------------------

-- A plot from the middle of its near edge (x, z), facing in (dirX, dirZ).
function TCPloughScore.newPlot(x, z, dirX, dirZ, size)
    local length = math.sqrt(dirX * dirX + dirZ * dirZ)
    if length < 0.0001 then
        dirX, dirZ, length = 0, 1, 1
    end
    return { x = x, z = z, dirX = dirX / length, dirZ = dirZ / length, size = size }
end

-- World to plot-local: u along the facing, v across (to its right).
function TCPloughScore.toLocal(plot, x, z)
    local dx, dz = x - plot.x, z - plot.z
    return dx * plot.dirX + dz * plot.dirZ, dx * plot.dirZ - dz * plot.dirX
end

function TCPloughScore.toWorld(plot, u, v)
    return plot.x + u * plot.dirX + v * plot.dirZ, plot.z + u * plot.dirZ - v * plot.dirX
end

-- Inside the plot, grown by `grow` metres all round.
function TCPloughScore.isInside(plot, u, v, grow)
    grow = grow or 0
    local half = plot.size * 0.5
    return u >= -grow and u <= plot.size + grow and v >= -half - grow and v <= half + grow
end

-- The plot's corners in world coordinates, grown by `grow`.
function TCPloughScore.getCorners(plot, grow)
    grow = grow or 0
    local half = plot.size * 0.5 + grow
    local corners = {}
    for _, uv in ipairs({ { -grow, -half }, { plot.size + grow, -half }, { plot.size + grow, half }, { -grow, half } }) do
        local x, z = TCPloughScore.toWorld(plot, uv[1], uv[2])
        table.insert(corners, { x = x, z = z })
    end
    return corners
end

-- The ground's grid: cells cellSize square over the plot and its margin.
-- Each cell { u, v, inside } (its centre); the engine fills before/ploughed.
function TCPloughScore.makeGrid(plot, rules)
    rules = rules or TCPloughScore.RULES
    local cellSize, margin = rules.cellSize, rules.margin
    local count = math.ceil((plot.size + 2 * margin) / cellSize)
    local cells = {}
    for row = 1, count do
        local u = -margin + (row - 0.5) * cellSize
        for col = 1, count do
            local v = -plot.size * 0.5 - margin + (col - 0.5) * cellSize
            table.insert(cells, { u = u, v = v, inside = TCPloughScore.isInside(plot, u, v) })
        end
    end
    return { cellSize = cellSize, count = count, cells = cells }
end

-- The ground ---------------------------------------------------------------------------------

-- What a cell's ploughing since the start comes to: (new, open), each a
-- share of the cell. open is what could still be ploughed at the start.
local function cellWork(cell)
    local before = math.max(0, math.min(1, cell.before or 0))
    local now = math.max(0, math.min(1, cell.ploughed or 0))
    return math.max(0, now - before), 1 - before
end

-- Coverage, ragged ends and outside work from a filled grid. workAlongU:
-- the runs go along the plot's u (so its ends are at u = 0 and u = size).
function TCPloughScore.measureGround(grid, plot, workAlongU, rules)
    rules = rules or TCPloughScore.RULES
    local cellArea = grid.cellSize * grid.cellSize
    local half = plot.size * 0.5
    local done, open = 0, 0
    local endDone, endOpen = 0, 0
    local outside = 0
    local before, insideCells = 0, 0
    for _, cell in ipairs(grid.cells) do
        local new, cellOpen = cellWork(cell)
        if cell.inside then
            insideCells = insideCells + 1
            before = before + (1 - cellOpen)
            done = done + new
            open = open + cellOpen
            local depth
            if workAlongU then
                depth = math.min(cell.u, plot.size - cell.u)
            else
                depth = math.min(cell.v + half, half - cell.v)
            end
            if depth <= rules.endBand then
                endDone = endDone + new
                endOpen = endOpen + cellOpen
            end
        else
            outside = outside + new * cellArea
        end
    end
    return {
        coverage = open > 0 and done / open or 0,
        raggedEnds = endOpen > 0 and 1 - endDone / endOpen or 0,
        outsideArea = outside,
        ploughedArea = done * cellArea,
        alreadyPloughed = insideCells > 0 and before / insideCells or 0,
    }
end

-- The path -----------------------------------------------------------------------------------

-- A sample: { t (s), x, z, hx, hz (the plough's heading), speed (km/h),
-- dir (1 forward, -1 back, 0 still), lowered }.

-- Splits the samples into runs (lists of samples, in order) and counts the
-- reverses and stops. Runs shorter than minRunLength are dropped.
function TCPloughScore.splitRuns(samples, plot, rules)
    rules = rules or TCPloughScore.RULES
    local runs, current = {}, nil
    local reverses, stops = 0, 0
    local wasReversing = false

    local function closeRun()
        if current == nil then
            return
        end
        local measured = TCPloughScore.measureRun(current)
        if measured.length >= rules.minRunLength then
            measured.samples = current
            table.insert(runs, measured)
            stops = stops + TCPloughScore.countStops(current, rules)
        end
        current = nil
    end

    for _, sample in ipairs(samples) do
        local u, v = TCPloughScore.toLocal(plot, sample.x, sample.z)
        local reversing = sample.lowered and sample.dir == -1 and sample.speed > rules.stopSpeed
        if reversing and not wasReversing then
            reverses = reverses + 1
        end
        wasReversing = reversing
        local working = sample.lowered and sample.dir ~= -1 and TCPloughScore.isInside(plot, u, v)
        if working then
            current = current or {}
            table.insert(current, sample)
        else
            closeRun()
        end
    end
    closeRun()
    return runs, reverses, stops
end

-- Stops within a run: stretches below stopSpeed lasting stopSeconds or more,
-- that neither start the run nor end it.
function TCPloughScore.countStops(run, rules)
    rules = rules or TCPloughScore.RULES
    local stops = 0
    local i = 1
    while i <= #run do
        if run[i].speed < rules.stopSpeed then
            local j = i
            while j < #run and run[j + 1].speed < rules.stopSpeed do
                j = j + 1
            end
            if i > 1 and j < #run and run[j].t - run[i].t >= rules.stopSeconds then
                stops = stops + 1
            end
            i = j + 1
        else
            i = i + 1
        end
    end
    return stops
end

-- A run's straightness: its best-fit line (the principal axis of its
-- points), its length along it, the sideways drift from it (RMS and max, m)
-- and the heading's wander off it (RMS, degrees, moving samples only).
function TCPloughScore.measureRun(run, rules)
    rules = rules or TCPloughScore.RULES
    local n = #run
    local result = { count = n, length = 0, lateralRms = 0, lateralMax = 0, headingRms = 0, axisX = 1, axisZ = 0 }
    if n < 2 then
        return result
    end
    local mx, mz = 0, 0
    for _, s in ipairs(run) do
        mx, mz = mx + s.x, mz + s.z
    end
    mx, mz = mx / n, mz / n
    local sxx, szz, sxz = 0, 0, 0
    for _, s in ipairs(run) do
        local dx, dz = s.x - mx, s.z - mz
        sxx, szz, sxz = sxx + dx * dx, szz + dz * dz, sxz + dx * dz
    end
    local angle = 0.5 * math.atan2(2 * sxz, sxx - szz)
    local ax, az = math.cos(angle), math.sin(angle)
    local minAlong, maxAlong = math.huge, -math.huge
    local sumSq, maxLateral = 0, 0
    for _, s in ipairs(run) do
        local dx, dz = s.x - mx, s.z - mz
        local along = dx * ax + dz * az
        local lateral = -dx * az + dz * ax
        minAlong, maxAlong = math.min(minAlong, along), math.max(maxAlong, along)
        sumSq = sumSq + lateral * lateral
        maxLateral = math.max(maxLateral, math.abs(lateral))
    end
    local headingSq, moving = 0, 0
    for _, s in ipairs(run) do
        local hl = math.sqrt((s.hx or 0) ^ 2 + (s.hz or 0) ^ 2)
        if s.speed >= rules.stopSpeed and hl > 0.0001 then
            -- The angle between the heading and the axis, folded to 0..90
            -- (the axis has no direction).
            local cosA = math.abs((s.hx * ax + s.hz * az) / hl)
            local deg = math.deg(math.acos(math.min(1, cosA)))
            headingSq = headingSq + deg * deg
            moving = moving + 1
        end
    end
    result.length = maxAlong - minAlong
    result.lateralRms = math.sqrt(sumSq / n)
    result.lateralMax = maxLateral
    result.headingRms = moving > 0 and math.sqrt(headingSq / moving) or 0
    result.axisX, result.axisZ = ax, az
    return result
end

-- Whether the runs go along the plot's u (true) or across it, by length.
function TCPloughScore.getWorkAxis(runs, plot)
    local along, across = 0, 0
    for _, run in ipairs(runs) do
        local cosU = math.abs(run.axisX * plot.dirX + run.axisZ * plot.dirZ)
        along = along + run.length * cosU
        across = across + run.length * math.sqrt(math.max(0, 1 - cosU * cosU))
    end
    return along >= across
end

-- A run's straightness, 0..1.
function TCPloughScore.scoreRun(run, rules)
    rules = rules or TCPloughScore.RULES
    local r = rules.ranges
    local lateral = TCPloughScore.linear(run.lateralRms, r.lateralRms[1], r.lateralRms[2])
    local heading = TCPloughScore.linear(run.headingRms, r.headingRms[1], r.headingRms[2])
    return rules.lateralShare * lateral + (1 - rules.lateralShare) * heading
end

-- The furrow angle -----------------------------------------------------------------------------

-- histogram[value + 1] = ploughed pixels at that angle value (0..max). The
-- share in the best two neighbouring values (the values wrap: 0 is next to
-- max), and the total; nil if nothing's ploughed.
function TCPloughScore.measureAngles(histogram)
    local total, best = 0, 0
    local n = #histogram
    for i = 1, n do
        total = total + histogram[i]
    end
    if total <= 0 then
        return nil
    end
    for i = 1, n do
        local pair = histogram[i] + (n > 1 and histogram[i % n + 1] or 0)
        best = math.max(best, pair)
    end
    return { share = best / total, total = total }
end

-- The score ------------------------------------------------------------------------------------

-- measures: { ground = measureGround's, runs = scored runs in order (the
-- first is the split), angles = measureAngles' or nil, reverses, stops,
-- minutes }. Returns { total, parts = { [name] = { value, marks, max } },
-- minutesOver, timePenalty }. A part that couldn't be measured (no runs, no
-- ploughed ground) gets no marks out of its weight; the furrow angle, when
-- the map has none, is left out of the total entirely.
function TCPloughScore.score(measures, rules)
    rules = rules or TCPloughScore.RULES
    local w, r = rules.weights, rules.ranges
    local parts = {}
    local function put(name, value, fraction)
        parts[name] = { value = value, marks = fraction * w[name], max = w[name] }
    end

    local ground = measures.ground
    put("coverage", ground.coverage, TCPloughScore.linear(ground.coverage, r.coverage[1], r.coverage[2]))
    put("ends", ground.raggedEnds,
        ground.coverage > 0 and TCPloughScore.linear(ground.raggedEnds, r.raggedEnds[1], r.raggedEnds[2]) or 0)
    -- Neat ends and keeping inside the plot are only worth anything once
    -- there's ploughing in it.
    put("outside", ground.outsideArea,
        ground.coverage > 0 and TCPloughScore.linear(ground.outsideArea, r.outsideArea[1], r.outsideArea[2]) or 0)

    local runs = measures.runs or {}
    local split = runs[1]
    put("split", split ~= nil and split.lateralRms or nil, split ~= nil and TCPloughScore.scoreRun(split, rules) or 0)
    local weighted, length = 0, 0
    for i = 2, #runs do
        weighted = weighted + TCPloughScore.scoreRun(runs[i], rules) * runs[i].length
        length = length + runs[i].length
    end
    put("straightness", length > 0 and #runs - 1 or nil, length > 0 and weighted / length or 0)

    if measures.angles ~= nil then
        put("furrowAngle", measures.angles.share,
            TCPloughScore.linear(measures.angles.share, r.angleShare[1], r.angleShare[2]))
    end

    local reverses, stops = measures.reverses or 0, measures.stops or 0
    local tidiness = #runs > 0 and math.max(0, 1 - reverses * rules.reverseCost - stops * rules.stopCost) or 0
    put("tidiness", reverses + stops, tidiness)

    local marks, max = 0, 0
    for _, name in ipairs(TCPloughScore.PARTS) do
        if parts[name] ~= nil then
            marks, max = marks + parts[name].marks, max + parts[name].max
        end
    end
    -- measures.minutes: game minutes.
    local minutesOver = math.max(0, math.ceil((measures.minutes or 0) - rules.timeLimitMinutes))
    local timePenalty = minutesOver * rules.minutePenalty
    local total = max > 0 and marks / max * 100 or 0
    total = math.max(0, math.min(100, total - timePenalty))
    return { total = total, parts = parts, minutesOver = minutesOver, timePenalty = timePenalty }
end

-- Sizing ---------------------------------------------------------------------------------------

-- Minutes to plough a square plot of `size` with a plough `width` wide, at
-- a steady speed with a turn at each end: the runs across it, each the
-- plot's length, and a turn between each.
function TCPloughScore.estimateMinutes(size, width, rules)
    rules = rules or TCPloughScore.RULES
    if width <= 0 then
        return nil
    end
    local runs = math.ceil(size / width)
    local runSeconds = size / (rules.estimateSpeedKmh / 3.6)
    return (runs * runSeconds + (runs - 1) * rules.estimateTurnSeconds) / 60
end

-- The plot size that takes `minutes` at that width (to the metre).
function TCPloughScore.sizeForMinutes(minutes, width, rules)
    rules = rules or TCPloughScore.RULES
    local size = 1
    while size < 500 and TCPloughScore.estimateMinutes(size + 1, width, rules) <= minutes do
        size = size + 1
    end
    return size
end
