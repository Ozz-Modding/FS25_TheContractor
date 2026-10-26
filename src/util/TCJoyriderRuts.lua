-- Joyrider ruts (072): a car's two wheel tracks torn into a grass field.
-- The path is a simple car-steering model, not a spline: the car moves
-- STEP metres at a time and its curvature eases toward a target that
-- changes every so often (straight, an arc, a donut of a few laps, or a
-- run across to a part of the field it hasn't been to yet). Easing the
-- turns in and out at a limited rate is what makes it read as a car. It
-- comes in from a point on the field's edge, can drive out of the field
-- and turns back in a little way after it does.
--
-- It stops on coverage, not distance: the field is split into a coarse
-- grid (squares of 8-25 m, see MIN_CELL_SIZE) and the car keeps
-- going until it's driven through a target share of them. The "cross"
-- manoeuvre heads for a cell it hasn't visited, so the damage spreads over
-- the field rather than circling one corner. When it has covered enough
-- it drives off the field by a nearby edge, rather than stopping dead.
--
-- generatePath is pure (boundary in, points out), so the tests can check it
-- without the engine. paintField does the painting, on the server only:
-- each wheel strip is a run of parallelograms (up to MAX_PIECE_LENGTH,
-- shorter on a bend) through vanilla's own
-- cultivator or disc harrow area functions, skipping any piece whose
-- middle isn't inside this field (the cultivator's own field filter would
-- happily paint a neighbouring field). Ground changes are synced to
-- clients and saved by the engine, so there's no state here.
--
-- The ruts are never painted PLOWED: plow progress counts PLOWED ground
-- (TCJobProgress), so plowed ruts would read as work already done.
--
-- 075 borrows it for fly-tipping's evidence: planDumpSite picks a spot a few
-- metres in from the field's edge (by its gate where it can) and a straight
-- run in to it from outside, and paintDumpSite paints that run's ruts and a
-- churned-up patch where the pile goes, so a player can park at the edge,
-- follow the tracks in and find it.
--
-- 101's field breakdowns use the same plan with their own depth (a broken
-- machine stands within 10 m of the edge, see planDumpSite's depthRange),
-- and paintMachineSite paints its run in and a patch the machine's size,
-- so it isn't left standing in the middle of a crop.

TCJoyriderRuts = {}

-- Metres per step along the path.
TCJoyriderRuts.STEP = 0.5
-- Centre to centre of the two wheels, and each rut's width. The ground map
-- is about 0.5 m a pixel, so ruts much narrower than 1 m look thin.
TCJoyriderRuts.TRACK_WIDTH = 1.8
TCJoyriderRuts.RUT_WIDTH = 0.9
-- Each painted piece reaches this far past both its ends, so the outside
-- of a curve has no gaps between pieces.
TCJoyriderRuts.OVERLAP = 0.15
-- Steps along a track are joined into one painted piece while it stays
-- this short and no step strays more than MAX_PIECE_BEND metres from its
-- centre line, so a straight run is a few long pieces rather than many.
TCJoyriderRuts.MAX_PIECE_LENGTH = 2
TCJoyriderRuts.MAX_PIECE_BEND = 0.08

-- Tightest turn (a 5 m radius donut), and how fast the steering can move:
-- curvature change per metre driven (full lock from straight in ~10 m).
TCJoyriderRuts.MAX_CURVATURE = 1 / 5
TCJoyriderRuts.CURVATURE_RATE = 0.02

-- Manoeuvres, picked by weight. curvature is a range of 1/radius (the
-- sign is random), length a range in metres; a donut's length is laps
-- of its own circle instead. "cross" has neither: it drives to an
-- unvisited cell (see CROSS_*).
TCJoyriderRuts.MANOEUVRES = {
    { key = "straight", weight = 3, curvature = { 0, 0.01 }, length = { 10, 30 } },
    { key = "arc", weight = 4.5, curvature = { 0.03, 0.08 }, length = { 10, 40 } },
    { key = "donut", weight = 2.5, curvature = { 0.15, 0.2 }, laps = { 1, 3 } },
    { key = "cross", weight = 3 },
}

-- Steering toward a point (crossing, or coming back into the field):
-- curvature is the heading error over STEER_DISTANCE metres, capped at
-- this share of full lock.
TCJoyriderRuts.STEER_DISTANCE = 10
TCJoyriderRuts.STEER_CURVATURE_SHARE = 0.6

-- Crossing: the target is the one in the emptiest patch out of the
-- CROSS_NEAREST nearest unvisited cells (all the way over the field every
-- time would be a zig-zag). It's reached within half a cell, or given up
-- on after twice the straight-line distance plus CROSS_SLACK metres.
TCJoyriderRuts.CROSS_NEAREST = 5
TCJoyriderRuts.CROSS_SLACK = 30

-- Once outside the field, drive on this far (a random distance in the
-- range) before turning back. It heads for a point RETURN_DEPTH in from
-- where it left, toward the middle (the middle itself when that's nearer) -
-- aiming at the middle of a long, narrow field would bring it back at a
-- shallow angle a long way off.
TCJoyriderRuts.OUTSIDE_DISTANCE = { 5, 25 }
TCJoyriderRuts.RETURN_DEPTH = 20

-- Heading at the start: toward the middle, give or take this much.
TCJoyriderRuts.START_ANGLE_SPREAD = math.rad(40)

-- Leaving, once it's done: it drives off the field rather than stopping
-- dead in the middle. It makes for the nearest edge, counting each radian
-- it would have to turn as EXIT_TURN_PENALTY metres further (so an edge
-- ahead beats a slightly nearer one behind), aiming EXIT_BEYOND metres
-- past it. The path ends at the first point outside.
TCJoyriderRuts.EXIT_TURN_PENALTY = 15
TCJoyriderRuts.EXIT_BEYOND = 10

-- Coverage: the grid's cells are MIN_CELL_SIZE across on a field of
-- CELL_SIZE_AREA or less, growing with the field's area to the power
-- CELL_SIZE_GROWTH up to MAX_CELL_SIZE, and the car stops once it's
-- been through COVERAGE_SHARE of those whose middle is in the field. A cell
-- counts once any of the path crosses it, so this is "share of the field
-- that has ruts within a cell's width", not the share torn up - small cells
-- are what make the damage dense. Cells growing slower than the field
-- (a fixed number of cells would grow them with its square root) keep a
-- big field's damage nearer a small one's: measured on rectangles, about
-- 14% of 1 ha is torn up, 12% of 3 ha, 9% of 10 ha and 6.5% of 20 ha. A
-- field bigger than that hits MAX_LENGTH before its target, and that's
-- fine: it's still well torn up. Distance driven inside
-- the field is at least MIN_LENGTH and at most MAX_LENGTH, and the whole
-- path at most MAX_STEPS_FACTOR times MAX_LENGTH - a guard against a car
-- that keeps finding the way out.
TCJoyriderRuts.CELL_SIZE_AREA = 10000
TCJoyriderRuts.CELL_SIZE_GROWTH = 0.25
TCJoyriderRuts.MIN_CELL_SIZE = 8
TCJoyriderRuts.MAX_CELL_SIZE = 25
TCJoyriderRuts.COVERAGE_SHARE = { 0.48, 0.68 }
TCJoyriderRuts.MIN_LENGTH = 60
TCJoyriderRuts.MAX_LENGTH = 10000
TCJoyriderRuts.MAX_STEPS_FACTOR = 1.5

-- Looks: which vanilla tool's ground the ruts get.
TCJoyriderRuts.STYLE = {
    CULTIVATOR = "cultivator",
    DISC = "disc",
}
TCJoyriderRuts.DEFAULT_STYLE = TCJoyriderRuts.STYLE.CULTIVATOR

-- Geometry ------------------------------------------------------------------

-- Ray cast: whether (x, z) is inside the polygon { {x, z}, ... } (closed
-- implicitly, last point back to the first).
function TCJoyriderRuts.isPointInside(x, z, boundary)
    local inside = false
    local count = #boundary
    local j = count
    for i = 1, count do
        local xi, zi = boundary[i][1], boundary[i][2]
        local xj, zj = boundary[j][1], boundary[j][2]
        if (zi > z) ~= (zj > z) and x < (xj - xi) * (z - zi) / (zj - zi) + xi then
            inside = not inside
        end
        j = i
    end
    return inside
end

-- Shoelace area and centroid of the polygon (falls back to the average
-- point for a degenerate one).
function TCJoyriderRuts.getAreaAndCentre(boundary)
    local area, cx, cz = 0, 0, 0
    local count = #boundary
    for i = 1, count do
        local x1, z1 = boundary[i][1], boundary[i][2]
        local x2, z2 = boundary[i % count + 1][1], boundary[i % count + 1][2]
        local cross = x1 * z2 - x2 * z1
        area = area + cross
        cx = cx + (x1 + x2) * cross
        cz = cz + (z1 + z2) * cross
    end
    area = area / 2
    if math.abs(area) < 0.0001 then
        local sx, sz = 0, 0
        for _, point in ipairs(boundary) do
            sx, sz = sx + point[1], sz + point[2]
        end
        return 0, sx / math.max(count, 1), sz / math.max(count, 1)
    end
    return math.abs(area), cx / (6 * area), cz / (6 * area)
end

-- A random point on the boundary, by distance along it.
local function getRandomEdgePoint(boundary, random)
    local count = #boundary
    local lengths, total = {}, 0
    for i = 1, count do
        local x1, z1 = boundary[i][1], boundary[i][2]
        local x2, z2 = boundary[i % count + 1][1], boundary[i % count + 1][2]
        local length = math.sqrt((x2 - x1) ^ 2 + (z2 - z1) ^ 2)
        lengths[i] = length
        total = total + length
    end

    local target = random() * total
    for i = 1, count do
        if target <= lengths[i] or i == count then
            local t = lengths[i] > 0 and math.min(1, target / lengths[i]) or 0
            local x1, z1 = boundary[i][1], boundary[i][2]
            local x2, z2 = boundary[i % count + 1][1], boundary[i % count + 1][2]
            return x1 + (x2 - x1) * t, z1 + (z2 - z1) * t
        end
        target = target - lengths[i]
    end
    return boundary[1][1], boundary[1][2]
end

local function randomIn(range, random)
    return range[1] + (range[2] - range[1]) * random()
end

local function wrapAngle(angle)
    while angle > math.pi do
        angle = angle - 2 * math.pi
    end
    while angle < -math.pi do
        angle = angle + 2 * math.pi
    end
    return angle
end

-- Heading is vanilla's y rotation: direction (sin h, cos h).
local function headingTo(x, z, tx, tz)
    return math.atan2(tx - x, tz - z)
end

local function pickManoeuvre(random)
    local total = 0
    for _, manoeuvre in ipairs(TCJoyriderRuts.MANOEUVRES) do
        total = total + manoeuvre.weight
    end
    local roll = random() * total
    for _, manoeuvre in ipairs(TCJoyriderRuts.MANOEUVRES) do
        roll = roll - manoeuvre.weight
        if roll <= 0 then
            return manoeuvre
        end
    end
    return TCJoyriderRuts.MANOEUVRES[#TCJoyriderRuts.MANOEUVRES]
end

-- Target curvature and how long to hold it, for a curvature manoeuvre.
local function rollCurve(manoeuvre, random)
    local sign = random() < 0.5 and -1 or 1
    local curvature = math.min(TCJoyriderRuts.MAX_CURVATURE, randomIn(manoeuvre.curvature, random))
    local length
    if manoeuvre.laps ~= nil then
        length = randomIn(manoeuvre.laps, random) * 2 * math.pi / math.max(curvature, 0.001)
    else
        length = randomIn(manoeuvre.length, random)
    end
    return sign * curvature, length
end

-- Curvature that turns the car toward (tx, tz).
local function steerToward(x, z, heading, tx, tz)
    local offset = wrapAngle(headingTo(x, z, tx, tz) - heading)
    local limit = TCJoyriderRuts.MAX_CURVATURE * TCJoyriderRuts.STEER_CURVATURE_SHARE
    -- Positive curvature turns toward a growing heading.
    return math.max(-limit, math.min(limit, offset / TCJoyriderRuts.STEER_DISTANCE))
end

-- The coverage grid over the boundary: { cellSize, minX, minZ, cols, rows,
-- cells = { { x, z, eligible, visited }, ... }, eligibleCount, visitedCount }.
-- A cell is eligible (counts toward coverage) when its middle is inside.
function TCJoyriderRuts.createGrid(boundary, areaSqm)
    local minX, minZ, maxX, maxZ = math.huge, math.huge, -math.huge, -math.huge
    for _, point in ipairs(boundary) do
        minX, maxX = math.min(minX, point[1]), math.max(maxX, point[1])
        minZ, maxZ = math.min(minZ, point[2]), math.max(maxZ, point[2])
    end
    local growth = math.max(1, areaSqm / TCJoyriderRuts.CELL_SIZE_AREA) ^ TCJoyriderRuts.CELL_SIZE_GROWTH
    local cellSize = math.min(TCJoyriderRuts.MAX_CELL_SIZE, TCJoyriderRuts.MIN_CELL_SIZE * growth)
    local cols = math.max(1, math.ceil((maxX - minX) / cellSize))
    local rows = math.max(1, math.ceil((maxZ - minZ) / cellSize))

    local grid = { cellSize = cellSize, minX = minX, minZ = minZ, cols = cols, rows = rows, cells = {},
        eligibleCount = 0, visitedCount = 0 }
    for row = 0, rows - 1 do
        for col = 0, cols - 1 do
            local x, z = minX + (col + 0.5) * cellSize, minZ + (row + 0.5) * cellSize
            local eligible = TCJoyriderRuts.isPointInside(x, z, boundary)
            grid.cells[row * cols + col + 1] = { x = x, z = z, eligible = eligible, visited = false }
            if eligible then
                grid.eligibleCount = grid.eligibleCount + 1
            end
        end
    end
    return grid
end

-- Marks the cell under (x, z) visited.
function TCJoyriderRuts.visitGrid(grid, x, z)
    local col = math.floor((x - grid.minX) / grid.cellSize)
    local row = math.floor((z - grid.minZ) / grid.cellSize)
    if col < 0 or row < 0 or col >= grid.cols or row >= grid.rows then
        return
    end
    local cell = grid.cells[row * grid.cols + col + 1]
    if not cell.visited then
        cell.visited = true
        if cell.eligible then
            grid.visitedCount = grid.visitedCount + 1
        end
    end
end

-- Share of eligible cells visited (1 for a field too small or thin to
-- have any).
function TCJoyriderRuts.getCoverage(grid)
    if grid.eligibleCount == 0 then
        return 1
    end
    return grid.visitedCount / grid.eligibleCount
end

-- An unvisited eligible cell to drive to, or nil.
local function pickCrossTarget(grid, x, z, random)
    local candidates = {}
    for _, cell in ipairs(grid.cells) do
        if cell.eligible and not cell.visited then
            table.insert(candidates, { cell = cell, distance = (cell.x - x) ^ 2 + (cell.z - z) ^ 2 })
        end
    end
    if #candidates == 0 then
        return nil
    end
    table.sort(candidates, function(a, b)
        return a.distance < b.distance
    end)

    -- Of the nearest few, the one in the emptiest patch (most unvisited
    -- neighbours), ties at random - so it heads into open ground rather
    -- than filling in a gap beside its own tracks.
    local best, bestScore = nil, -1
    for i = 1, math.min(#candidates, TCJoyriderRuts.CROSS_NEAREST) do
        local cell = candidates[i].cell
        local score = random() * 0.5
        local col = math.floor((cell.x - grid.minX) / grid.cellSize)
        local row = math.floor((cell.z - grid.minZ) / grid.cellSize)
        for dr = -1, 1 do
            for dc = -1, 1 do
                local r, c = row + dr, col + dc
                if (dr ~= 0 or dc ~= 0) and r >= 0 and c >= 0 and r < grid.rows and c < grid.cols then
                    local neighbour = grid.cells[r * grid.cols + c + 1]
                    if neighbour.eligible and not neighbour.visited then
                        score = score + 1
                    end
                end
            end
        end
        if score > bestScore then
            best, bestScore = cell, score
        end
    end
    return best
end

-- Where to drive off the field from (x, z) heading `heading`: a point
-- EXIT_BEYOND past the best edge point (see EXIT_TURN_PENALTY).
function TCJoyriderRuts.getExitPoint(boundary, x, z, heading)
    local bestX, bestZ, bestScore = nil, nil, math.huge
    local count = #boundary
    for i = 1, count do
        local ax, az = boundary[i][1], boundary[i][2]
        local bx, bz = boundary[i % count + 1][1], boundary[i % count + 1][2]
        local dx, dz = bx - ax, bz - az
        local lengthSq = dx * dx + dz * dz
        local t = lengthSq > 0 and math.max(0, math.min(1, ((x - ax) * dx + (z - az) * dz) / lengthSq)) or 0
        local px, pz = ax + dx * t, az + dz * t
        local distance = math.sqrt((px - x) ^ 2 + (pz - z) ^ 2)
        local turn = math.abs(wrapAngle(headingTo(x, z, px, pz) - heading))
        local score = distance + turn * TCJoyriderRuts.EXIT_TURN_PENALTY
        if score < bestScore then
            bestX, bestZ, bestScore = px, pz, score
        end
    end

    local outX, outZ = bestX - x, bestZ - z
    local length = math.sqrt(outX * outX + outZ * outZ)
    if length < 0.001 then
        outX, outZ, length = math.sin(heading), math.cos(heading), 1
    end
    return bestX + outX / length * TCJoyriderRuts.EXIT_BEYOND, bestZ + outZ / length * TCJoyriderRuts.EXIT_BEYOND
end

-- The car's path across the field: { { x, z, heading, curvature, inside }, ... }
-- one point every STEP metres, and { coverage, targetCoverage, cellSize,
-- exited }. Once it's covered enough it drives off the field, so the last
-- point is outside (exited) unless the step guard ran out first.
-- boundary is { {x, z}, ... }; random a function like math.random() (0..1),
-- for the tests.
function TCJoyriderRuts.generatePath(boundary, random)
    random = random or math.random
    if boundary == nil or #boundary < 3 then
        return {}, { coverage = 0, targetCoverage = 0, cellSize = 0, exited = false }
    end

    local areaSqm, cx, cz = TCJoyriderRuts.getAreaAndCentre(boundary)
    local step = TCJoyriderRuts.STEP
    local grid = TCJoyriderRuts.createGrid(boundary, areaSqm)
    local targetCoverage = randomIn(TCJoyriderRuts.COVERAGE_SHARE, random)
    local maxSteps = math.ceil(TCJoyriderRuts.MAX_LENGTH / step * TCJoyriderRuts.MAX_STEPS_FACTOR)

    local x, z = getRandomEdgePoint(boundary, random)
    local heading = headingTo(x, z, cx, cz) + (random() * 2 - 1) * TCJoyriderRuts.START_ANGLE_SPREAD
    local curvature = 0
    local driven = 0
    local maxChange = TCJoyriderRuts.CURVATURE_RATE * step

    -- The manoeuvre under way: a curve (targetCurvature for targetLeft
    -- metres) or a cross (to crossTarget, given up after targetLeft metres).
    local targetCurvature, targetLeft, crossTarget = 0, 0, nil
    local function nextManoeuvre()
        local manoeuvre = pickManoeuvre(random)
        crossTarget = nil
        if manoeuvre.key == "cross" then
            crossTarget = pickCrossTarget(grid, x, z, random)
            if crossTarget ~= nil then
                local distance = math.sqrt((crossTarget.x - x) ^ 2 + (crossTarget.z - z) ^ 2)
                targetLeft = 2 * distance + TCJoyriderRuts.CROSS_SLACK
                return
            end
            -- Nowhere left to go: just drive on.
            manoeuvre = TCJoyriderRuts.MANOEUVRES[1]
        end
        targetCurvature, targetLeft = rollCurve(manoeuvre, random)
    end

    local outsideFor, outsideLimit = nil, nil
    local returnX, returnZ = cx, cz

    local points = {}
    local function addPoint()
        local inside = TCJoyriderRuts.isPointInside(x, z, boundary)
        table.insert(points, { x = x, z = z, heading = heading, curvature = curvature, inside = inside })
        if inside then
            TCJoyriderRuts.visitGrid(grid, x, z)
        end
        return inside
    end
    addPoint()
    nextManoeuvre()

    local exitX, exitZ = nil, nil
    local exited = false
    for _ = 1, maxSteps do
        if exitX == nil and (driven >= TCJoyriderRuts.MAX_LENGTH or
            (driven >= TCJoyriderRuts.MIN_LENGTH and TCJoyriderRuts.getCoverage(grid) >= targetCoverage)) then
            exitX, exitZ = TCJoyriderRuts.getExitPoint(boundary, x, z, heading)
        end
        if exitX ~= nil and not points[#points].inside then
            exited = true
            break
        end

        local wanted = targetCurvature
        if exitX ~= nil then
            wanted = steerToward(x, z, heading, exitX, exitZ)
        elseif outsideFor ~= nil and outsideFor >= outsideLimit then
            -- Out long enough: turn back in.
            wanted = steerToward(x, z, heading, returnX, returnZ)
        elseif crossTarget ~= nil then
            wanted = steerToward(x, z, heading, crossTarget.x, crossTarget.z)
        end
        curvature = curvature + math.max(-maxChange, math.min(maxChange, wanted - curvature))

        heading = wrapAngle(heading + curvature * step)
        x = x + math.sin(heading) * step
        z = z + math.cos(heading) * step

        if addPoint() then
            driven = driven + step
            outsideFor, outsideLimit = nil, nil
        else
            if outsideFor == nil then
                outsideFor, outsideLimit = 0, randomIn(TCJoyriderRuts.OUTSIDE_DISTANCE, random)
                local lastX, lastZ = points[#points - 1].x, points[#points - 1].z
                local toCentre = math.sqrt((cx - lastX) ^ 2 + (cz - lastZ) ^ 2)
                local depth = math.min(TCJoyriderRuts.RETURN_DEPTH, toCentre)
                if toCentre > 0.001 then
                    returnX = lastX + (cx - lastX) / toCentre * depth
                    returnZ = lastZ + (cz - lastZ) / toCentre * depth
                else
                    returnX, returnZ = cx, cz
                end
            end
            outsideFor = outsideFor + step
        end

        targetLeft = targetLeft - step
        local arrived = crossTarget ~= nil and
            (crossTarget.x - x) ^ 2 + (crossTarget.z - z) ^ 2 <= (grid.cellSize / 2) ^ 2
        if targetLeft <= 0 or arrived then
            nextManoeuvre()
        end
    end

    return points, { coverage = TCJoyriderRuts.getCoverage(grid), targetCoverage = targetCoverage,
        cellSize = grid.cellSize, exited = exited }
end

-- The two wheel tracks: { left = { {x, z}, ... }, right = { ... } }, each
-- TRACK_WIDTH / 2 either side of the path, square to its heading.
function TCJoyriderRuts.getWheelTracks(points)
    local half = TCJoyriderRuts.TRACK_WIDTH / 2
    local left, right = {}, {}
    for i, point in ipairs(points) do
        -- (cos h, -sin h) is square to the direction (sin h, cos h).
        local nx, nz = math.cos(point.heading), -math.sin(point.heading)
        left[i] = { point.x - nx * half, point.z - nz * half }
        right[i] = { point.x + nx * half, point.z + nz * half }
    end
    return { left = left, right = right }
end

-- The pieces to paint along one track: { { sx, sz, wx, wz, hx, hz, heading }, ... },
-- vanilla's start/width/height corner points (POINT_POINT_POINT). Only
-- steps whose middle is inside the boundary are painted, joined into
-- longer pieces where the track runs straight enough (MAX_PIECE_LENGTH,
-- MAX_PIECE_BEND).
function TCJoyriderRuts.getTrackPieces(track, boundary)
    local half = TCJoyriderRuts.RUT_WIDTH / 2
    local overlap = TCJoyriderRuts.OVERLAP
    local pieces = {}

    local function isStepInside(i)
        local ax, az, bx, bz = track[i][1], track[i][2], track[i + 1][1], track[i + 1][2]
        return (bx - ax) ^ 2 + (bz - az) ^ 2 > 0.000001
            and TCJoyriderRuts.isPointInside((ax + bx) / 2, (az + bz) / 2, boundary)
    end
    -- Whether track[first..last] fits one piece: short enough, and every
    -- point in between close to the line from first to last.
    local function fits(first, last)
        local ax, az, bx, bz = track[first][1], track[first][2], track[last][1], track[last][2]
        local length = math.sqrt((bx - ax) ^ 2 + (bz - az) ^ 2)
        if length > TCJoyriderRuts.MAX_PIECE_LENGTH then
            return false
        end
        for i = first + 1, last - 1 do
            local px, pz = track[i][1] - ax, track[i][2] - az
            if math.abs(px * (bz - az) - pz * (bx - ax)) > TCJoyriderRuts.MAX_PIECE_BEND * length then
                return false
            end
        end
        return true
    end

    local i = 1
    while i < #track do
        if isStepInside(i) then
            local last = i + 1
            while last < #track and isStepInside(last) and fits(i, last + 1) do
                last = last + 1
            end
            local ax, az, bx, bz = track[i][1], track[i][2], track[last][1], track[last][2]
            local dx, dz = bx - ax, bz - az
            local length = math.sqrt(dx * dx + dz * dz)
            dx, dz = dx / length, dz / length
            local nx, nz = dz, -dx
            local sx, sz = ax - dx * overlap - nx * half, az - dz * overlap - nz * half
            table.insert(pieces, {
                sx, sz,
                sx + nx * 2 * half, sz + nz * 2 * half,
                bx + dx * overlap - nx * half, bz + dz * overlap - nz * half,
                math.atan2(dx, dz),
            })
            i = last
        else
            i = i + 1
        end
    end
    return pieces
end

-- Fly-tipping dump site (075) ---------------------------------------------------

-- How far in from the field's edge the pile goes (metres, a random distance
-- in the range), measured to the nearest edge, not just the one it came in
-- over - a spot by a corner is tried again elsewhere.
TCJoyriderRuts.DUMP_DEPTH = { 4, 7 }
-- The van's run starts this far outside the edge, give or take
-- DUMP_ANGLE_SPREAD off square to it.
TCJoyriderRuts.DUMP_APPROACH = 8
TCJoyriderRuts.DUMP_ANGLE_SPREAD = math.rad(20)
-- The churned-up patch under the pile, a square this wide.
TCJoyriderRuts.DUMP_PATCH_SIZE = 5
-- Random edge points tried after the one by the gate.
TCJoyriderRuts.DUMP_TRIES = 30

-- Distance from (x, z) to the nearest point of the boundary.
function TCJoyriderRuts.getDistanceToBoundary(x, z, boundary)
    local best = math.huge
    local count = #boundary
    for i = 1, count do
        local ax, az = boundary[i][1], boundary[i][2]
        local bx, bz = boundary[i % count + 1][1], boundary[i % count + 1][2]
        local dx, dz = bx - ax, bz - az
        local lengthSq = dx * dx + dz * dz
        local t = lengthSq > 0 and math.max(0, math.min(1, ((x - ax) * dx + (z - az) * dz) / lengthSq)) or 0
        local px, pz = ax + dx * t, az + dz * t
        best = math.min(best, math.sqrt((px - x) ^ 2 + (pz - z) ^ 2))
    end
    return best
end

-- The boundary point nearest (x, z), and the inward direction square to
-- that edge there.
local function getNearestEdge(boundary, x, z)
    local bestX, bestZ, bestNX, bestNZ, bestDistance = nil, nil, nil, nil, math.huge
    local count = #boundary
    for i = 1, count do
        local ax, az = boundary[i][1], boundary[i][2]
        local bx, bz = boundary[i % count + 1][1], boundary[i % count + 1][2]
        local dx, dz = bx - ax, bz - az
        local lengthSq = dx * dx + dz * dz
        if lengthSq > 0.000001 then
            local t = math.max(0, math.min(1, ((x - ax) * dx + (z - az) * dz) / lengthSq))
            local px, pz = ax + dx * t, az + dz * t
            local distance = (px - x) ^ 2 + (pz - z) ^ 2
            if distance < bestDistance then
                local length = math.sqrt(lengthSq)
                bestX, bestZ, bestNX, bestNZ, bestDistance = px, pz, dz / length, -dx / length, distance
            end
        end
    end
    if bestX == nil then
        return nil
    end
    -- Whichever side of the edge is the field's.
    if not TCJoyriderRuts.isPointInside(bestX + bestNX * 0.5, bestZ + bestNZ * 0.5, boundary) then
        bestNX, bestNZ = -bestNX, -bestNZ
    end
    return bestX, bestZ, bestNX, bestNZ
end

-- A dump spot depthRange in from the edge nearest (edgeX, edgeZ), or nil if
-- it isn't that far from every edge (a corner, a thin strip).
local function tryDumpSpot(boundary, edgeX, edgeZ, depthRange, random)
    local x, z, nx, nz = getNearestEdge(boundary, edgeX, edgeZ)
    if x == nil then
        return nil
    end
    local depth = randomIn(depthRange, random)
    local dumpX, dumpZ = x + nx * depth, z + nz * depth
    if not TCJoyriderRuts.isPointInside(dumpX, dumpZ, boundary) or
        TCJoyriderRuts.getDistanceToBoundary(dumpX, dumpZ, boundary) < depthRange[1] - 0.01 then
        return nil
    end

    -- The van comes in from outside, a little off square to the edge.
    local inward = math.atan2(nx, nz) + (random() * 2 - 1) * TCJoyriderRuts.DUMP_ANGLE_SPREAD
    local length = depth + TCJoyriderRuts.DUMP_APPROACH
    local startX, startZ = dumpX - math.sin(inward) * length, dumpZ - math.cos(inward) * length
    local points = {}
    local steps = math.max(1, math.ceil(length / TCJoyriderRuts.STEP))
    for i = 0, steps do
        local t = i / steps
        local px, pz = startX + (dumpX - startX) * t, startZ + (dumpZ - startZ) * t
        table.insert(points, { x = px, z = pz, heading = inward, curvature = 0,
            inside = TCJoyriderRuts.isPointInside(px, pz, boundary) })
    end
    return { x = dumpX, z = dumpZ, heading = inward, depth = depth, edgeX = x, edgeZ = z, points = points }
end

-- Where a fly-tipper dumps on this field: { x, z, heading, depth, edgeX,
-- edgeZ, points } - the spot, the van's heading coming in, how far in it
-- is from the edge it came over, where it crossed that edge, and its path
-- from outside to the spot (generatePath's point shape). By the gate
-- (gateX, gateZ, may be nil) if that works, else a random stretch of edge.
-- depthRange ({ min, max } metres in, at least min from every edge)
-- defaults to DUMP_DEPTH. nil if nowhere on the field will do. random is
-- for the tests.
function TCJoyriderRuts.planDumpSite(boundary, gateX, gateZ, random, depthRange)
    random = random or math.random
    depthRange = depthRange or TCJoyriderRuts.DUMP_DEPTH
    if boundary == nil or #boundary < 3 then
        return nil
    end
    if gateX ~= nil then
        local site = tryDumpSpot(boundary, gateX, gateZ, depthRange, random)
        if site ~= nil then
            return site
        end
    end
    for _ = 1, TCJoyriderRuts.DUMP_TRIES do
        local edgeX, edgeZ = getRandomEdgePoint(boundary, random)
        local site = tryDumpSpot(boundary, edgeX, edgeZ, depthRange, random)
        if site ~= nil then
            return site
        end
    end
    return nil
end

-- A rectangle width across and length along heading, centred on (x, z), as
-- one paint piece (see getTrackPieces).
function TCJoyriderRuts.getPatchPiece(x, z, heading, width, length)
    local dx, dz = math.sin(heading), math.cos(heading)
    local nx, nz = dz, -dx
    local sx, sz = x - dx * length / 2 - nx * width / 2, z - dz * length / 2 - nz * width / 2
    return { sx, sz, sx + nx * width, sz + nz * width, sx + dx * length, sz + dz * length, heading }
end

-- The churned-up square under the pile, square to the van's heading.
function TCJoyriderRuts.getDumpPatchPiece(site)
    local size = TCJoyriderRuts.DUMP_PATCH_SIZE
    return TCJoyriderRuts.getPatchPiece(site.x, site.z, site.heading, size, size)
end

-- 101: the run in to a spot already chosen (x, z, facing heading), in
-- generatePath's point shape: straight back from the spot until it leaves
-- the field (or MACHINE_RUN_MAX metres), then DUMP_APPROACH more outside.
TCJoyriderRuts.MACHINE_RUN_MAX = 60

function TCJoyriderRuts.getRunInPoints(boundary, x, z, heading)
    local dx, dz = math.sin(heading), math.cos(heading)
    local step = TCJoyriderRuts.STEP
    local reversed = {}
    local distance, outsideFor = 0, nil
    while distance <= TCJoyriderRuts.MACHINE_RUN_MAX do
        local px, pz = x - dx * distance, z - dz * distance
        local inside = TCJoyriderRuts.isPointInside(px, pz, boundary)
        table.insert(reversed, { x = px, z = pz, heading = heading, curvature = 0, inside = inside })
        if not inside then
            outsideFor = outsideFor or distance
        end
        if outsideFor ~= nil and distance - outsideFor >= TCJoyriderRuts.DUMP_APPROACH then
            break
        end
        distance = distance + step
    end
    local points = {}
    for i = #reversed, 1, -1 do
        table.insert(points, reversed[i])
    end
    return points
end

-- Painting (server) -----------------------------------------------------------

-- The field's boundary as { {x, z}, ... }, from its polygon nodes.
function TCJoyriderRuts.getFieldBoundary(field)
    local boundary = {}
    for _, node in ipairs(field:getPolygonPoints() or {}) do
        local x, _, z = getWorldTranslation(node)
        table.insert(boundary, { x, z })
    end
    return boundary
end

local function paintPiece(piece, style, maxAngle)
    local sx, sz, wx, wz, hx, hz, heading = piece[1], piece[2], piece[3], piece[4], piece[5], piece[6], piece[7]
    local angle = FSDensityMapUtil.convertToDensityMapAngle(heading, maxAngle)
    if style == TCJoyriderRuts.STYLE.DISC then
        FSDensityMapUtil.updateDiscHarrowArea(sx, sz, wx, wz, hx, hz, false, true, angle, nil)
    else
        FSDensityMapUtil.updateCultivatorArea(sx, sz, wx, wz, hx, hz, false, true, angle, nil, false, true)
    end
    FSDensityMapUtil.clearDecoArea(sx, sz, wx, wz, hx, hz)
end

-- A run in's two ruts (inside the field only) and then the patch at its
-- end. Returns the number of rut pieces.
local function paintRunIn(boundary, points, patch)
    local style = TCJoyriderRuts.DEFAULT_STYLE
    local maxAngle = g_currentMission.fieldGroundSystem:getGroundAngleMaxValue()
    local tracks = TCJoyriderRuts.getWheelTracks(points)
    local pieceCount = 0
    for _, track in ipairs({ tracks.left, tracks.right }) do
        for _, piece in ipairs(TCJoyriderRuts.getTrackPieces(track, boundary)) do
            paintPiece(piece, style, maxAngle)
            pieceCount = pieceCount + 1
        end
    end
    paintPiece(patch, style, maxAngle)
    return pieceCount
end

-- 075: plans a fly-tipping dump site on the field (planDumpSite) and paints
-- the van's ruts in from the edge and the churned patch under the pile.
-- Returns the site, or nil if it can't (not the server, no boundary,
-- nowhere suitable).
function TCJoyriderRuts.paintDumpSite(field, random)
    if not g_currentMission:getIsServer() or field == nil then
        return nil
    end
    local boundary = TCJoyriderRuts.getFieldBoundary(field)
    local gateX, gateZ = nil, nil
    if field.getTeleportPosition ~= nil then
        gateX, gateZ = field:getTeleportPosition()
    end
    local site = TCJoyriderRuts.planDumpSite(boundary, gateX, gateZ, random)
    if site == nil then
        return nil
    end

    local pieceCount = paintRunIn(boundary, site.points, TCJoyriderRuts.getDumpPatchPiece(site))

    TCLog.info("TheContractor: fly-tipping site on field %s: %.1f m in from the edge at (%.0f, %.0f), %d rut pieces",
        tostring(field:getId()), site.depth, site.edgeX, site.edgeZ, pieceCount)
    return site
end

-- 101: a broken-down machine's spot on the field (its centre x, z, facing
-- heading, its width and length): the ruts it made coming in from the edge,
-- and the crop cleared from a patch MACHINE_PATCH_MARGIN bigger than it all
-- round. Returns the number of rut pieces, or nil if it can't (not the
-- server, no boundary).
TCJoyriderRuts.MACHINE_PATCH_MARGIN = 2

function TCJoyriderRuts.paintMachineSite(field, x, z, heading, width, length)
    if not g_currentMission:getIsServer() or field == nil then
        return nil
    end
    local boundary = TCJoyriderRuts.getFieldBoundary(field)
    if #boundary < 3 then
        return nil
    end
    local margin = TCJoyriderRuts.MACHINE_PATCH_MARGIN * 2
    local patch = TCJoyriderRuts.getPatchPiece(x, z, heading, width + margin, length + margin)
    local pieceCount = paintRunIn(boundary, TCJoyriderRuts.getRunInPoints(boundary, x, z, heading), patch)

    TCLog.info("TheContractor: breakdown spot on field %s at (%.0f, %.0f), %.1f m from the edge, %d rut pieces",
        tostring(field:getId()), x, z, TCJoyriderRuts.getDistanceToBoundary(x, z, boundary), pieceCount)
    return pieceCount
end

-- Tears up the field. Returns { length, insideLength, pieces, coverage,
-- targetCoverage, cellSize } (logged), or nil if it can't (not the
-- server, no boundary).
function TCJoyriderRuts.paintField(field, style, random)
    if not g_currentMission:getIsServer() or field == nil then
        return nil
    end
    local boundary = TCJoyriderRuts.getFieldBoundary(field)
    if #boundary < 3 then
        TCLog.warning("TheContractor: field %s has no boundary, can't add joyrider ruts", tostring(field:getId()))
        return nil
    end

    style = style or TCJoyriderRuts.DEFAULT_STYLE
    local points, stats = TCJoyriderRuts.generatePath(boundary, random)
    local tracks = TCJoyriderRuts.getWheelTracks(points)
    local maxAngle = g_currentMission.fieldGroundSystem:getGroundAngleMaxValue()

    local pieceCount = 0
    for _, track in ipairs({ tracks.left, tracks.right }) do
        for _, piece in ipairs(TCJoyriderRuts.getTrackPieces(track, boundary)) do
            paintPiece(piece, style, maxAngle)
            pieceCount = pieceCount + 1
        end
    end

    local insideCount = 0
    for _, point in ipairs(points) do
        if point.inside then
            insideCount = insideCount + 1
        end
    end
    local result = {
        length = math.max(0, #points - 1) * TCJoyriderRuts.STEP,
        insideLength = insideCount * TCJoyriderRuts.STEP,
        pieces = pieceCount,
        coverage = stats.coverage,
        targetCoverage = stats.targetCoverage,
        cellSize = stats.cellSize,
    }
    TCLog.info("TheContractor: joyrider ruts on field %s (%s): %.0f m driven, %.0f m inside, %d pieces, "
        .. "ruts in %d%% of its %.0f m squares (target %d%%)", tostring(field:getId()), style, result.length,
        result.insideLength, pieceCount, math.floor(result.coverage * 100 + 0.5), result.cellSize,
        math.floor(result.targetCoverage * 100 + 0.5))
    return result
end
