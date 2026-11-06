-- Auction crowd (134, spike): people on a field, walking loops round it and
-- standing about in small talking groups. Driven from the console
-- (tcCompany crowd) on any field; nothing here knows about auctions yet
-- (140 wires it to them).
--
-- Our own people, not the game's pedestrian system. The spike's first part
-- swapped the map's pedestrian system for one of ours and found the
-- engine's limits too tight for a crowd: 64 people and 32 walkers a system,
-- only about 16 shown at once, and extra systems adding a few more who walk
-- through each other (the ticket's Outcome has the runs). So each person
-- here is a vanilla HumanGraphicsComponent we place and animate ourselves,
-- as 065's idle staff (TCIdleStaff), with no limit but the frame rate:
--   - standers on the standing spots, playing vanilla's NPC idle (isNPC);
--   - walkers moved along our loops every frame (by distance, buildPath), animated as
--     vanilla animates a remote player (PlayerGraphicsState:updateRemote:
--     absSpeed, isWalking, isGrounded), the idea from FS25_PlaceableNPCSystem
--     by Arrow-kb (its NPCGraphicsComponent drives HumanGraphicsComponent's
--     animation from its own movement).
-- The map's own pedestrians are left alone.
--
-- Walkers keep to lanes: each loop has a lane each way, offset to either
-- side of the loop, and a lane's walkers share one speed, spaced evenly
-- round it, so nobody walks through anybody else. Where a walker is comes
-- from the time since the crowd went up (walkerDistance), not from
-- integrating each frame, so it's the same wherever the camera's been.
--
-- Their looks are copied from the base maps' pedestrian XMLs
-- (SOURCE_XMLS), taken in turn, so no style name of vanilla's is written
-- into our code.
--
-- The layout (pure, tested in tests/test_auctionCrowd.lua): the largest
-- rectangle inset in the field's polygon (findLargestRect, tried at several
-- angles), concentric rounded-rectangle loops inside it (buildLoops), and
-- small talking groups facing each other in the lanes between the loops
-- (buildStandingSpots). planCrowd shares the people out between the spots
-- and the lanes.
--
-- Models are loaded within LOAD_DISTANCE of the camera, freed beyond
-- UNLOAD_DISTANCE and shown within CLIP_DISTANCE, as the idle staff's are.
-- Local and visual only: nothing is saved or synced, and nothing happens on
-- a dedicated server.

TCAuctionCrowd = {}

-- The base maps' pedestrian XMLs, whose people's looks we copy.
TCAuctionCrowd.SOURCE_XMLS = {
    "$data/maps/mapEU/config/pedestrianSystem.xml",
    "$data/maps/mapUS/config/pedestrianSystem.xml",
    "$data/maps/mapAS/config/pedestrianSystem.xml",
}

TCAuctionCrowd.DEFAULT_PEOPLE = 60
TCAuctionCrowd.MAX_PEOPLE = 300
-- The share of the people that stand, as far as the spots go.
TCAuctionCrowd.STANDING_SHARE = 0.4
-- Walking speed range (m/s): a stroll. Each lane gets one speed.
TCAuctionCrowd.WALK_SPEED_MIN = 1.0
TCAuctionCrowd.WALK_SPEED_MAX = 1.4
-- How far either side of the loop a lane runs (metres).
TCAuctionCrowd.LANE_OFFSET = 0.8
-- Metres from the camera: shown within CLIP, model loaded within LOAD,
-- freed beyond UNLOAD (TCIdleStaff's).
TCAuctionCrowd.CLIP_DISTANCE = 100
TCAuctionCrowd.LOAD_DISTANCE = 150
TCAuctionCrowd.UNLOAD_DISTANCE = 200
-- Models started loading a frame at most: starting dozens at once stalled
-- a frame for about 90 ms.
TCAuctionCrowd.MAX_LOADS_PER_FRAME = 2

-- Layout (metres unless said).
TCAuctionCrowd.LAYOUT = {
    step = 4,            -- grid cell for the rectangle search
    inset = 8,           -- kept clear of the field's edge
    angleStepDeg = 15,   -- angles tried for the rectangle
    edgeMargin = 4,      -- the outer loop's distance in from the rectangle
    laneGap = 14,        -- between one loop and the next
    maxLoops = 4,
    minHalf = 4,         -- a loop narrower than twice this isn't made
    cornerRadius = 6,
    pointSpacing = 8,    -- between edit points along a straight
    arcSteps = 4,        -- edit points per rounded corner
    clusterSpacing = 18, -- between standing groups along a lane
    clusterRadius = 1.2, -- how far each person stands from the group's middle
}
-- People per standing group, taken in turn.
TCAuctionCrowd.CLUSTER_SIZES = { 3, 4, 2, 5, 3 }

-- Live state (this machine only): { fieldId, loops (buildPath's paths),
-- figures, elapsedMs, people, walkers, standers, lanes, stats }.
TCAuctionCrowd.active = nil

-- Geometry (pure) ---------------------------------------------------------------------

local function toLocal(x, z, cosA, sinA)
    return x * cosA + z * sinA, -x * sinA + z * cosA
end

local function toWorld(u, v, cosA, sinA)
    return u * cosA - v * sinA, u * sinA + v * cosA
end

-- polygon: list of { x, z }.
function TCAuctionCrowd.pointInPolygon(x, z, polygon)
    local inside = false
    local n = #polygon
    local j = n
    for i = 1, n do
        local xi, zi = polygon[i].x, polygon[i].z
        local xj, zj = polygon[j].x, polygon[j].z
        if (zi > z) ~= (zj > z) and x < (xj - xi) * (z - zi) / (zj - zi) + xi then
            inside = not inside
        end
        j = i
    end
    return inside
end

-- The largest-area rectangle of true cells in grid[row][col] (rows x cols):
-- returns rowFrom, rowTo, colFrom, colTo, or nil.
function TCAuctionCrowd.largestRectangle(grid, rows, cols)
    local heights = {}
    for c = 1, cols do
        heights[c] = 0
    end
    local best, bestRect = 0, nil
    for r = 1, rows do
        for c = 1, cols do
            heights[c] = grid[r][c] and heights[c] + 1 or 0
        end
        -- Largest rectangle under the histogram (a stack of rising heights).
        local stack = {}
        for c = 1, cols + 1 do
            local h = c <= cols and heights[c] or 0
            local start = c
            while #stack > 0 and stack[#stack].h >= h do
                local top = table.remove(stack)
                local area = top.h * (c - top.start)
                if area > best then
                    best = area
                    bestRect = { r - top.h + 1, r, top.start, c - 1 }
                end
                start = top.start
            end
            if h > 0 then
                table.insert(stack, { h = h, start = start })
            end
        end
    end
    if bestRect == nil then
        return nil
    end
    return bestRect[1], bestRect[2], bestRect[3], bestRect[4]
end

-- The cells inside the polygon at one angle, eroded by the inset, and the
-- largest rectangle of them: { cx, cz, angle, halfU, halfV, area } or nil.
local function rectAtAngle(polygon, angle, layout)
    local cosA, sinA = math.cos(angle), math.sin(angle)
    local pts = {}
    local uMin, uMax, vMin, vMax = math.huge, -math.huge, math.huge, -math.huge
    for i, p in ipairs(polygon) do
        local u, v = toLocal(p.x, p.z, cosA, sinA)
        pts[i] = { u = u, v = v }
        uMin, uMax = math.min(uMin, u), math.max(uMax, u)
        vMin, vMax = math.min(vMin, v), math.max(vMax, v)
    end
    local step = layout.step
    local cols = math.floor((uMax - uMin) / step)
    local rows = math.floor((vMax - vMin) / step)
    if cols < 1 or rows < 1 then
        return nil
    end

    -- Inside, row by row from where the edges cross the row's line.
    local inside = {}
    local n = #pts
    for r = 1, rows do
        local v = vMin + (r - 0.5) * step
        local crossings = {}
        local j = n
        for i = 1, n do
            local a, b = pts[i], pts[j]
            if (a.v > v) ~= (b.v > v) then
                table.insert(crossings, a.u + (v - a.v) * (b.u - a.u) / (b.v - a.v))
            end
            j = i
        end
        table.sort(crossings)
        local row = {}
        for c = 1, cols do
            local u = uMin + (c - 0.5) * step
            local isIn = false
            for k = 1, #crossings - 1, 2 do
                if u >= crossings[k] and u <= crossings[k + 1] then
                    isIn = true
                    break
                end
            end
            row[c] = isIn
        end
        inside[r] = row
    end

    -- Erode by the inset (a square of cells), across then down.
    local k = math.ceil(layout.inset / step)
    local across = {}
    for r = 1, rows do
        local row = {}
        for c = 1, cols do
            local ok = true
            for d = -k, k do
                local cc = c + d
                if cc < 1 or cc > cols or not inside[r][cc] then
                    ok = false
                    break
                end
            end
            row[c] = ok
        end
        across[r] = row
    end
    local grid = {}
    for r = 1, rows do
        local row = {}
        for c = 1, cols do
            local ok = true
            for d = -k, k do
                local rr = r + d
                if rr < 1 or rr > rows or not across[rr][c] then
                    ok = false
                    break
                end
            end
            row[c] = ok
        end
        grid[r] = row
    end

    local r1, r2, c1, c2 = TCAuctionCrowd.largestRectangle(grid, rows, cols)
    if r1 == nil then
        return nil
    end
    -- Between the outer cells' middles, so every edge is in the eroded area.
    local u1, u2 = uMin + (c1 - 0.5) * step, uMin + (c2 - 0.5) * step
    local v1, v2 = vMin + (r1 - 0.5) * step, vMin + (r2 - 0.5) * step
    local cu, cv = (u1 + u2) / 2, (v1 + v2) / 2
    local cx, cz = toWorld(cu, cv, cosA, sinA)
    local halfU, halfV = (u2 - u1) / 2, (v2 - v1) / 2
    return { cx = cx, cz = cz, angle = angle, halfU = halfU, halfV = halfV, area = 4 * halfU * halfV }
end

-- The largest rectangle inset in the polygon, tried every angleStepDeg, with
-- u its long side: { cx, cz, angle, halfU, halfV, area }, or nil.
function TCAuctionCrowd.findLargestRect(polygon, layout)
    layout = layout or TCAuctionCrowd.LAYOUT
    if polygon == nil or #polygon < 3 then
        return nil
    end
    local best = nil
    local deg = 0
    while deg < 180 do
        local rect = rectAtAngle(polygon, math.rad(deg), layout)
        if rect ~= nil and rect.area > 0 and (best == nil or rect.area > best.area) then
            best = rect
        end
        deg = deg + layout.angleStepDeg
    end
    if best ~= nil and best.halfV > best.halfU then
        best.angle = best.angle + math.pi / 2
        best.halfU, best.halfV = best.halfV, best.halfU
    end
    return best
end

-- One rounded rectangle around the rectangle's middle, as world points
-- { x, z } in order (counter-clockwise in the rectangle's frame), not
-- repeating the first at the end.
local function roundedRect(rect, hu, hv, layout)
    local cosA, sinA = math.cos(rect.angle), math.sin(rect.angle)
    local r = math.min(layout.cornerRadius, hu * 0.5, hv * 0.5)
    local corners = {
        { u = hu - r, v = hv - r, from = 0 },
        { u = -(hu - r), v = hv - r, from = 90 },
        { u = -(hu - r), v = -(hv - r), from = 180 },
        { u = hu - r, v = -(hv - r), from = 270 },
    }
    local localPts = {}
    for i, corner in ipairs(corners) do
        for s = 0, layout.arcSteps do
            local a = math.rad(corner.from + 90 * s / layout.arcSteps)
            table.insert(localPts, { u = corner.u + r * math.cos(a), v = corner.v + r * math.sin(a) })
        end
        -- The straight to the next corner's arc.
        local nextCorner = corners[i % 4 + 1]
        local last = localPts[#localPts]
        local nextA = math.rad(nextCorner.from)
        local tu, tv = nextCorner.u + r * math.cos(nextA), nextCorner.v + r * math.sin(nextA)
        local length = math.sqrt((tu - last.u) ^ 2 + (tv - last.v) ^ 2)
        local segments = math.max(1, math.ceil(length / layout.pointSpacing))
        for s = 1, segments - 1 do
            local t = s / segments
            table.insert(localPts, { u = last.u + (tu - last.u) * t, v = last.v + (tv - last.v) * t })
        end
    end
    local points = {}
    for i, p in ipairs(localPts) do
        local x, z = toWorld(p.u, p.v, cosA, sinA)
        points[i] = { x = rect.cx + x, z = rect.cz + z }
    end
    return points
end

-- Concentric walking loops inside the rectangle, outermost first: a list of
-- { points = { { x, z }... }, halfU, halfV }.
function TCAuctionCrowd.buildLoops(rect, layout)
    layout = layout or TCAuctionCrowd.LAYOUT
    local loops = {}
    if rect == nil then
        return loops
    end
    for k = 1, layout.maxLoops do
        local d = layout.edgeMargin + (k - 1) * layout.laneGap
        local hu, hv = rect.halfU - d, rect.halfV - d
        if hu < layout.minHalf or hv < layout.minHalf then
            break
        end
        table.insert(loops, { points = roundedRect(rect, hu, hv, layout), halfU = hu, halfV = hv })
    end
    return loops
end

-- An auction's walks (137): one long loop down each aisle between the rows
-- of lots (135's walkways: a middle line and half the aisle's width), up
-- one side of the aisle and back down the other, so walkers never leave
-- it and never meet a lot. Its outer lane keeps AISLE_CLEARANCE from the
-- aisle's edge, where the lots' fronts are. Returns buildLoops' shape, a
-- walkway too narrow or short for a loop left out.
TCAuctionCrowd.AISLE_CLEARANCE = 1.2

function TCAuctionCrowd.buildWalkwayLoops(walkways, layout)
    layout = layout or TCAuctionCrowd.LAYOUT
    local loops = {}
    for _, walkway in ipairs(walkways or {}) do
        local dx, dz = walkway.x2 - walkway.x1, walkway.z2 - walkway.z1
        local length = math.sqrt(dx * dx + dz * dz)
        local hv = walkway.halfWidth - TCAuctionCrowd.LANE_OFFSET - TCAuctionCrowd.AISLE_CLEARANCE
        -- The lanes swing LANE_OFFSET out round the ends too.
        local hu = length * 0.5 - TCAuctionCrowd.LANE_OFFSET
        if hv > 0.25 and hu > hv then
            -- u along the walkway: toWorld's u axis is (cos, sin).
            local rect = { cx = (walkway.x1 + walkway.x2) * 0.5, cz = (walkway.z1 + walkway.z2) * 0.5,
                angle = math.atan2(dz, dx), halfU = hu, halfV = hv }
            table.insert(loops, { points = roundedRect(rect, hu, hv, layout), halfU = hu, halfV = hv, rect = rect })
        end
    end
    return loops
end

-- The standing groups on an auction's walks: down the middle of each
-- aisle's loop, between its two sides' lanes, spaced clusterSpacing apart.
-- Up to maxCount spots, as buildStandingSpots.
function TCAuctionCrowd.buildWalkwaySpots(loops, maxCount, layout)
    layout = layout or TCAuctionCrowd.LAYOUT
    local spots = {}
    local groupIndex = 0
    for _, loop in ipairs(loops) do
        local rect = loop.rect
        local reach = math.max(0, loop.halfU - loop.halfV - layout.clusterRadius * 2)
        local count = math.floor(2 * reach / layout.clusterSpacing) + 1
        local cosA, sinA = math.cos(rect.angle), math.sin(rect.angle)
        for i = 0, count - 1 do
            groupIndex = groupIndex + 1
            local u = count == 1 and 0 or -reach + 2 * reach * i / (count - 1)
            local mx, mz = toWorld(u, 0, cosA, sinA)
            mx, mz = rect.cx + mx, rect.cz + mz
            local size = TCAuctionCrowd.CLUSTER_SIZES[(groupIndex - 1) % #TCAuctionCrowd.CLUSTER_SIZES + 1]
            for p = 1, size do
                if #spots >= maxCount then
                    return spots
                end
                local a = 2 * math.pi * (p - 1) / size + groupIndex
                local x = mx + layout.clusterRadius * math.cos(a)
                local z = mz + layout.clusterRadius * math.sin(a)
                table.insert(spots, { x = x, z = z, yaw = math.atan2(mx - x, mz - z) })
            end
        end
    end
    return spots
end

-- Where the standing people go: small groups facing their middle, in the
-- lanes between loops (along the long sides), or down the middle of a
-- single loop. Up to maxCount spots: a list of { x, z, yaw }, yaw so the
-- spot faces its group's middle (MathUtil.getYRotationFromDirection's
-- convention: atan2(dx, dz)).
function TCAuctionCrowd.buildStandingSpots(rect, loops, maxCount, layout)
    layout = layout or TCAuctionCrowd.LAYOUT
    local spots = {}
    if rect == nil or #loops == 0 or maxCount <= 0 then
        return spots
    end
    local lines = {}
    local reach
    if #loops >= 2 then
        local v = rect.halfV - layout.edgeMargin - layout.laneGap / 2
        reach = rect.halfU - layout.edgeMargin - layout.laneGap / 2 - layout.cornerRadius
        lines = { v, -v }
    else
        local loop = loops[1]
        reach = loop.halfU - layout.cornerRadius - layout.clusterRadius * 2
        lines = { 0 }
    end
    if reach < 0 then
        reach = 0
    end

    local centres = {}
    local count = math.floor(2 * reach / layout.clusterSpacing) + 1
    for _, v in ipairs(lines) do
        for i = 0, count - 1 do
            local u = count == 1 and 0 or -reach + 2 * reach * i / (count - 1)
            table.insert(centres, { u = u, v = v })
        end
    end

    local cosA, sinA = math.cos(rect.angle), math.sin(rect.angle)
    for i, centre in ipairs(centres) do
        local size = TCAuctionCrowd.CLUSTER_SIZES[(i - 1) % #TCAuctionCrowd.CLUSTER_SIZES + 1]
        local mx, mz = toWorld(centre.u, centre.v, cosA, sinA)
        mx, mz = rect.cx + mx, rect.cz + mz
        for p = 1, size do
            if #spots >= maxCount then
                return spots
            end
            local a = 2 * math.pi * (p - 1) / size + i
            local x = mx + layout.clusterRadius * math.cos(a)
            local z = mz + layout.clusterRadius * math.sin(a)
            table.insert(spots, { x = x, z = z, yaw = math.atan2(mx - x, mz - z) })
        end
    end
    return spots
end

-- Who goes where (pure). loopLengths: each loop's length in metres;
-- spotCount: the standing spots there are. Standers take STANDING_SHARE of
-- the people, as far as the spots go; everyone else walks. Each loop has a
-- lane each way, and the walkers are shared out between the lanes by
-- length (largest remainders, so the counts add up). A lane's walkers all
-- go at the lane's speed, spaced evenly round it, so they never catch each
-- other up. Speeds and starting points come from the lane's number (a
-- golden-ratio sequence), not math.random, so a crowd is the same each time.
-- Returns { standers = n, lanes = n, walkers = { { loop, direction (1 or
-- -1), offset (metres along the loop), speed } } }.
local GOLDEN = 0.6180339887498949

function TCAuctionCrowd.planCrowd(loopLengths, spotCount, people)
    local standers = math.min(spotCount, math.floor(people * TCAuctionCrowd.STANDING_SHARE))
    local walkerCount = people - standers
    local plan = { standers = standers, lanes = 0, walkers = {} }
    if #loopLengths == 0 then
        plan.standers = math.min(spotCount, people)
        return plan
    end

    local lanes = {}
    local total = 0
    for loop, length in ipairs(loopLengths) do
        for _, direction in ipairs({ 1, -1 }) do
            table.insert(lanes, { loop = loop, direction = direction, length = length })
            total = total + length
        end
    end
    plan.lanes = #lanes

    -- Largest remainders.
    local assigned = 0
    for _, lane in ipairs(lanes) do
        local exact = total > 0 and walkerCount * lane.length / total or 0
        lane.count = math.floor(exact)
        lane.remainder = exact - lane.count
        assigned = assigned + lane.count
    end
    local order = {}
    for i = 1, #lanes do
        order[i] = i
    end
    table.sort(order, function(a, b)
        if lanes[a].remainder ~= lanes[b].remainder then
            return lanes[a].remainder > lanes[b].remainder
        end
        return a < b
    end)
    for k = 1, walkerCount - assigned do
        local lane = lanes[order[(k - 1) % #lanes + 1]]
        lane.count = lane.count + 1
    end

    local speedMin, speedMax = TCAuctionCrowd.WALK_SPEED_MIN, TCAuctionCrowd.WALK_SPEED_MAX
    for index, lane in ipairs(lanes) do
        local fraction = (index * GOLDEN) % 1
        local speed = speedMin + (speedMax - speedMin) * fraction
        local spacing = lane.count > 0 and lane.length / lane.count or 0
        local phase = ((index * GOLDEN * 7) % 1) * spacing
        for j = 1, lane.count do
            table.insert(plan.walkers, {
                loop = lane.loop,
                direction = lane.direction,
                offset = (phase + (j - 1) * spacing) % lane.length,
                speed = speed,
            })
        end
    end
    return plan
end

-- How far round its loop a walker is after elapsedSec, in [0, length).
function TCAuctionCrowd.walkerDistance(walker, elapsedSec, length)
    if length <= 0 then
        return 0
    end
    local distance = (walker.offset + walker.direction * walker.speed * elapsedSec) % length
    if distance < 0 then
        distance = distance + length
    end
    return distance
end

-- A walker's place and heading from the loop's point and direction
-- there: moved LANE_OFFSET to its right (so the two lanes of a loop pass
-- on either side), and facing the way it walks. Returns x, z, yaw.
function TCAuctionCrowd.getLanePosition(x, z, dirX, dirZ, direction)
    local length = math.sqrt(dirX * dirX + dirZ * dirZ)
    if length < 0.0001 then
        return x, z, 0
    end
    dirX, dirZ = direction * dirX / length, direction * dirZ / length
    -- Facing (dirX, dirZ), the right hand is (dirZ, -dirX).
    local offset = TCAuctionCrowd.LANE_OFFSET
    return x + dirZ * offset, z - dirX * offset, math.atan2(dirX, dirZ)
end

-- A loop as a closed path walked by distance (pure): its points and the
-- distance round it at each, { points, distances, length }. Walkers follow
-- the loop's own points rather than an engine spline: a cubic spline
-- through unevenly spaced points (short arc steps beside long straights)
-- swings out at tight corners and isn't parameterised by distance, so
-- walkers on a small loop slid back and forth.
function TCAuctionCrowd.buildPath(points)
    local distances = { 0 }
    local length = 0
    local count = #points
    for i = 1, count do
        local a, b = points[i], points[i % count + 1]
        length = length + math.sqrt((b.x - a.x) ^ 2 + (b.z - a.z) ^ 2)
        distances[i + 1] = length
    end
    return { points = points, distances = distances, length = length }
end

local function pathPosition(path, distance)
    local length = path.length
    distance = distance % length
    if distance < 0 then
        distance = distance + length
    end
    local distances = path.distances
    -- The segment it's on: distances[low] <= distance < distances[low + 1].
    local low, high = 1, #path.points
    while low < high do
        local mid = math.floor((low + high + 1) / 2)
        if distances[mid] <= distance then
            low = mid
        else
            high = mid - 1
        end
    end
    local points = path.points
    local a, b = points[low], points[low % #points + 1]
    local span = distances[low + 1] - distances[low]
    local t = span > 0 and (distance - distances[low]) / span or 0
    return a.x + (b.x - a.x) * t, a.z + (b.z - a.z) * t
end

-- How far ahead and behind the heading is taken from (metres), so a walker
-- turns smoothly round a corner instead of in steps at each point.
TCAuctionCrowd.HEADING_REACH = 1.0

-- The point distance metres round the path (any distance, wrapped) and the
-- path's direction there (not normalised). Returns x, z, dirX, dirZ.
function TCAuctionCrowd.getPathPoint(path, distance)
    if path.length <= 0 then
        local p = path.points[1]
        return p.x, p.z, 0, 1
    end
    local x, z = pathPosition(path, distance)
    local reach = TCAuctionCrowd.HEADING_REACH
    local ax, az = pathPosition(path, distance + reach)
    local bx, bz = pathPosition(path, distance - reach)
    return x, z, ax - bx, az - bz
end


-- The looks for count people, taken from the templates in turn.
function TCAuctionCrowd.pickTemplates(templates, count)
    local result = {}
    if #templates == 0 then
        return result
    end
    for i = 1, count do
        result[i] = templates[(i - 1) % #templates + 1]
    end
    return result
end

-- Engine side --------------------------------------------------------------------------

function TCAuctionCrowd.getFieldPolygon(field)
    local polygon = {}
    if field == nil or field.getPolygonPoints == nil then
        return polygon
    end
    for _, node in ipairs(field:getPolygonPoints() or {}) do
        local x, _, z = getWorldTranslation(node)
        table.insert(polygon, { x = x, z = z })
    end
    return polygon
end

-- Every person in the base maps' pedestrian XMLs: { variation, style,
-- walk = { animationName, blendWithAnimationName, distance, speedScaleMin,
-- speedScaleMax, triggers }, idle, staticIdles }.
function TCAuctionCrowd.readTemplates()
    local templates = {}
    for _, source in ipairs(TCAuctionCrowd.SOURCE_XMLS) do
        local filename = Utils.getFilename(source, nil)
        if fileExists(filename) then
            local xmlFile = XMLFile.load("tcCrowdSource", filename, PedestrianSystem.xmlSchema)
            if xmlFile ~= nil then
                for _, key in xmlFile:iterator("pedestrianSystem.pedestrians.pedestrian") do
                    local style = PlayerStyle.new()
                    if style:loadFromXMLFile(xmlFile, key .. ".style") then
                        local template = {
                            variation = xmlFile:getValue(key .. "#variation", "male"),
                            style = style,
                            idle = xmlFile:getValue(key .. ".idleAnimation#animationName"),
                            staticIdles = {},
                            walk = {
                                animationName = xmlFile:getValue(key .. ".walkAnimation#animationName"),
                                blendWithAnimationName = xmlFile:getValue(key ..
                                    ".walkAnimation#blendWithAnimationName"),
                                distance = xmlFile:getValue(key .. ".walkAnimation#distance"),
                                speedScaleMin = xmlFile:getValue(key .. ".walkAnimation#speedScaleMin"),
                                speedScaleMax = xmlFile:getValue(key .. ".walkAnimation#speedScaleMax"),
                                triggers = {},
                            },
                        }
                        for _, idleKey in xmlFile:iterator(key .. ".staticIdleAnimation") do
                            table.insert(template.staticIdles, xmlFile:getValue(idleKey .. "#animationName"))
                        end
                        for _, triggerKey in xmlFile:iterator(key .. ".walkAnimation.stepSoundTrigger") do
                            table.insert(template.walk.triggers, xmlFile:getValue(triggerKey .. "#time"))
                        end
                        if template.walk.animationName ~= nil then
                            table.insert(templates, template)
                        end
                    end
                end
                xmlFile:delete()
            end
        else
            TCLog.info("TheContractor: crowd source %s not found", filename)
        end
    end
    return templates
end

local function groundY(x, z)
    return getTerrainHeightAtWorldPos(g_terrainNode, x, 0, z)
end

-- Whether this machine shows a crowd at all, or why not.
function TCAuctionCrowd.getUnavailableReason()
    if g_dedicatedServer ~= nil then
        return "There's no crowd on a dedicated server: nobody's there to see it."
    end
    if g_currentMission == nil or not g_currentMission:getIsClient() then
        return "This machine has no client to show a crowd."
    end
    return nil
end

-- Puts a crowd of people on the field (the spike's loops, over the whole
-- field). Returns the text to print.
function TCAuctionCrowd.start(fieldId, people, laneGap)
    local reason = TCAuctionCrowd.getUnavailableReason()
    if reason ~= nil then
        return reason
    end
    local field = g_fieldManager:getFieldById(fieldId)
    if field == nil then
        return string.format("No field %d.", fieldId)
    end

    local layout = {}
    for key, value in pairs(TCAuctionCrowd.LAYOUT) do
        layout[key] = value
    end
    layout.laneGap = laneGap or layout.laneGap
    local rect = TCAuctionCrowd.findLargestRect(TCAuctionCrowd.getFieldPolygon(field), layout)
    local loops = TCAuctionCrowd.buildLoops(rect, layout)
    if #loops == 0 then
        return string.format("Field %d has no room for a loop.", fieldId)
    end
    local spots = TCAuctionCrowd.buildStandingSpots(rect, loops, math.floor(people * TCAuctionCrowd.STANDING_SHARE),
        layout)
    local text = TCAuctionCrowd.putUp(fieldId, loops, spots, people)
    if TCAuctionCrowd.active ~= nil then
        text = text .. "\n" .. string.format("Area used: %.0f x %.0f m at %.0f degrees, %.0f m between loops",
            rect.halfU * 2, rect.halfV * 2, math.deg(rect.angle), layout.laneGap)
    end
    return text
end

-- 137: puts a crowd on an auction's walks (135's walkways, buildWalkwayLoops),
-- never among its lots. Returns the text to print.
function TCAuctionCrowd.startOnWalkways(fieldId, walkways, people)
    local reason = TCAuctionCrowd.getUnavailableReason()
    if reason ~= nil then
        return reason
    end
    local loops = TCAuctionCrowd.buildWalkwayLoops(walkways)
    if #loops == 0 then
        return "The auction has no aisles wide enough to walk."
    end
    local spots = TCAuctionCrowd.buildWalkwaySpots(loops, math.floor(people * TCAuctionCrowd.STANDING_SHARE))
    return TCAuctionCrowd.putUp(fieldId, loops, spots, people)
end

-- Puts the people on the loops and spots, replacing any crowd. Returns the
-- text to print.
function TCAuctionCrowd.putUp(fieldId, loops, spots, people)
    local templates = TCAuctionCrowd.readTemplates()
    if #templates == 0 then
        return "None of the base maps' pedestrian XMLs could be read."
    end

    TCAuctionCrowd.stop()
    local paths = {}
    local lengths = {}
    for i, loop in ipairs(loops) do
        paths[i] = TCAuctionCrowd.buildPath(loop.points)
        lengths[i] = paths[i].length
    end
    local plan = TCAuctionCrowd.planCrowd(lengths, #spots, people)
    local looks = TCAuctionCrowd.pickTemplates(templates, plan.standers + #plan.walkers)

    local figures = {}
    for i = 1, plan.standers do
        local spot = spots[i]
        table.insert(figures, { kind = "stand", template = looks[i], x = spot.x, y = groundY(spot.x, spot.z),
            z = spot.z, yaw = spot.yaw })
    end
    for k, walker in ipairs(plan.walkers) do
        table.insert(figures, { kind = "walk", template = looks[plan.standers + k], walker = walker,
            x = 0, y = 0, z = 0, yaw = 0 })
    end

    TCAuctionCrowd.active = {
        fieldId = fieldId,
        loops = paths,
        figures = figures,
        elapsedMs = 0,
        people = #figures,
        standers = plan.standers,
        walkers = #plan.walkers,
        lanes = plan.lanes,
        stats = { loaded = 0, shown = 0, updateMs = 0 },
    }
    TCLog.info("TheContractor: crowd on field %d, %d standing, %d walking in %d lanes", fieldId, plan.standers,
        #plan.walkers, plan.lanes)

    local lines = { string.format("Crowd on field %d: %d people (%d standing, %d walking in %d lanes on %d loops)",
        fieldId, #figures, plan.standers, #plan.walkers, plan.lanes, #paths) }
    for i, path in ipairs(paths) do
        table.insert(lines, string.format("  loop %d: %.0f m", i, path.length))
    end
    table.insert(lines, string.format("  %d standing spots", #spots))
    table.insert(lines, "Models load as you come within 150 m. 'tcCompany crowd' shows how many are loaded and shown, and what the crowd costs a frame.")
    return table.concat(lines, "\n")
end

local function freeModel(figure)
    if figure.graphics ~= nil then
        figure.graphics:delete()
        figure.graphics = nil
    end
    figure.isReady = false
    figure.isVisible = false
end

local function setVisible(figure, isVisible)
    if figure.isVisible ~= isVisible then
        figure.isVisible = isVisible
        if isVisible then
            figure.graphics:show()
        else
            figure.graphics:hide()
        end
    end
end

-- Starts loading a figure's model: a vanilla character in its look,
-- standing (vanilla's NPC idle) or walking (as a remote player's walk:
-- PlayerGraphicsState:updateRemote's speed, walking and grounded).
local function loadModel(figure)
    local graphics = HumanGraphicsComponent.new()
    local state = graphics.defaultState
    if figure.kind == "walk" then
        state.isNPC = false
        state.isIdling = false
        state.isWalking = true
        state.absSpeed = figure.walker.speed
        state.movementDirX = 0
        state.movementDirZ = 1
        state.isGrounded = true
        state.isCloseToGround = true
    else
        state.isNPC = true
    end
    graphics:setSoundsEnabled(false)
    graphics:initialize()
    figure.graphics = graphics
    figure.isReady = false
    figure.isVisible = false

    local style = PlayerStyle.new()
    style:copyFrom(figure.template.style)
    graphics:setStyleAsync(style, function(_, loadingState)
        if figure.graphics ~= graphics then
            return
        end
        if loadingState == HumanModelLoadingState.OK then
            -- Loading shows the model at the origin: hidden until the next
            -- update places it.
            graphics:hide()
            graphics:defaultAllParameters()
            figure.isReady = true
        else
            figure.noModel = true
        end
    end, nil, nil, true)
end

-- Where a walker is now, into figure.x/y/z/yaw.
local function placeWalker(figure, loops, elapsedSec)
    local walker = figure.walker
    local path = loops[walker.loop]
    local distance = TCAuctionCrowd.walkerDistance(walker, elapsedSec, path.length)
    local x, z, dx, dz = TCAuctionCrowd.getPathPoint(path, distance)
    local lx, lz, yaw = TCAuctionCrowd.getLanePosition(x, z, dx, dz, walker.direction)
    figure.x, figure.z, figure.yaw = lx, lz, yaw
    figure.y = groundY(lx, lz)
end

-- Every frame on a machine with a client.
function TCAuctionCrowd.update(dt)
    local active = TCAuctionCrowd.active
    if active == nil then
        return
    end
    local camera = g_cameraManager ~= nil and g_cameraManager:getActiveCamera() or nil
    if camera == nil or camera == 0 then
        return
    end
    local started = getTimeSec()
    local cx, cy, cz = getWorldTranslation(camera)
    active.elapsedMs = active.elapsedMs + dt
    local elapsedSec = active.elapsedMs / 1000

    local loaded, shown, loadsStarted = 0, 0, 0
    for _, figure in ipairs(active.figures) do
        local isWalker = figure.kind == "walk"
        if isWalker then
            -- A walker's distance is checked from where it is now; placing
            -- it is cheap next to animating it.
            placeWalker(figure, active.loops, elapsedSec)
        end
        local distance = MathUtil.vector3Length(figure.x - cx, figure.y - cy, figure.z - cz)
        if figure.graphics == nil then
            if distance <= TCAuctionCrowd.LOAD_DISTANCE and not figure.noModel and
                loadsStarted < TCAuctionCrowd.MAX_LOADS_PER_FRAME then
                loadModel(figure)
                loadsStarted = loadsStarted + 1
            end
        elseif distance > TCAuctionCrowd.UNLOAD_DISTANCE then
            freeModel(figure)
        end

        if figure.graphics ~= nil then
            loaded = loaded + 1
        end
        if figure.isReady then
            if distance > TCAuctionCrowd.CLIP_DISTANCE then
                setVisible(figure, false)
            else
                setVisible(figure, true)
                shown = shown + 1
                figure.graphics:setModelPosition(figure.x, figure.y, figure.z)
                figure.graphics:setModelYaw(figure.yaw)
                figure.graphics:defaultAllParameters()
                figure.graphics:update(dt)
            end
        end
    end

    local stats = active.stats
    stats.loaded, stats.shown = loaded, shown
    local ms = (getTimeSec() - started) * 1000
    stats.updateMs = stats.updateMs * 0.95 + ms * 0.05
    stats.peakMs = math.max(stats.peakMs or 0, ms)
end

-- Takes the crowd away.
function TCAuctionCrowd.stop()
    local active = TCAuctionCrowd.active
    if active == nil then
        return false
    end
    for _, figure in ipairs(active.figures) do
        freeModel(figure)
    end
    TCAuctionCrowd.active = nil
    return true
end

function TCAuctionCrowd.describe()
    local active = TCAuctionCrowd.active
    if active == nil then
        return "No crowd up."
    end
    local stats = active.stats
    return string.format(
        "Crowd on field %d: %d people (%d standing, %d walking in %d lanes). Models loaded: %d, shown now: %d. The crowd's own update takes %.2f ms a frame on average (peak %.2f ms); the models' drawing and animation cost shows in the game's frame rate.",
        active.fieldId, active.people, active.standers, active.walkers, active.lanes, stats.loaded, stats.shown,
        stats.updateMs, stats.peakMs or 0)
end

-- deleteMap: the crowd goes with the map.
function TCAuctionCrowd.reset()
    TCAuctionCrowd.stop()
end

function TCAuctionCrowd.registerConsoleCommands()
    TCConsole.register("company", "crowd", {
        args = "[fieldId|off] [people] [laneGap]",
        description = "Put an auction crowd on a field: people walking loops and standing in groups (this machine only)",
        serverOnly = false,
        run = function(_, args)
            if args[1] == nil then
                return TCAuctionCrowd.describe()
            end
            if string.lower(args[1]) == "off" then
                return TCAuctionCrowd.stop() and "Crowd removed." or "There's no crowd up."
            end
            local fieldId = tonumber(args[1])
            local people = tonumber(args[2] or TCAuctionCrowd.DEFAULT_PEOPLE)
            local laneGap = args[3] ~= nil and tonumber(args[3]) or nil
            if fieldId == nil or people == nil or people < 1 or (args[3] ~= nil and (laneGap == nil or laneGap < 3)) then
                return false
            end
            people = math.min(math.floor(people), TCAuctionCrowd.MAX_PEOPLE)
            -- 137: on an auction site's field, its aisles (laneGap doesn't apply).
            local site = g_currentMission.TheContractor ~= nil and g_currentMission.TheContractor.AuctionSite or nil
            if site ~= nil and site.fieldId == fieldId and #site:getWalkways() > 0 then
                return TCAuctionCrowd.startOnWalkways(fieldId, site:getWalkways(), people)
            end
            return TCAuctionCrowd.start(fieldId, people, laneGap)
        end,
    })
end
