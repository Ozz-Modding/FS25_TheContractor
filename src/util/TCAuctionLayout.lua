-- Auction site layout (135, spike): the pure half of TheContractorAuctionSite.
-- Everything here works on plain numbers and tables, so it's tested outside
-- the game (tests/test_auctionLayout.lua) and every machine could work the
-- same layout out from the same input.
--
--   layOut: rows of lots with aisles between them, in the largest rectangle
--     inset in the field's polygon (TCAuctionCrowd.findLargestRect, the
--     crowd's), its long side the rows' direction. Each aisle has a row
--     either side facing it, and rows back to back between aisles:
--       row (facing up) | aisle | row (facing down) | gap | row (facing up) ...
--     A lot faces its aisle, its front on the aisle's edge, so the shorter
--     lots in a row line up with the longest. Lots go in longest first, so
--     machines of a size share a row. Space is kept at the end nearest the
--     entrance for the car park and the food area (140's props, TCAuctionScene),
--     and a cross aisle at the far end, so the aisles join up into the
--     crowd's loops (the layout returns every aisle as a polyline, for 134's
--     paths).
--   rankCandidates: the fields that could hold a sale, best first.
--   measureSlope: how steep the ground is, from heights on a grid.
--   findEntrance: the road point nearest the field's edge.
--   pickRoles: which roles a sale's lots are, from each role's weight and
--     count range.
--
-- The lot count and the space each lot needs are inputs, never constants
-- here, so 145's auction sizes can set them.

TCAuctionLayout = {}

-- Metres, unless said.
TCAuctionLayout.LAYOUT = {
    step = 4,             -- grid cell for the rectangle search
    inset = 6,            -- kept clear of the field's edge
    angleStepDeg = 15,    -- angles tried for the rectangle
    aisleWidth = 10,      -- the crowd's walk, and room to drive a lot out
    backGap = 2,          -- between rows back to back
    lotGap = 3,           -- between lots in a row
    entranceSpace = 30,   -- the car park and food area, at the entrance end
    endAisle = 8,         -- the cross aisle at the far end
    pointSpacing = 8,     -- between an aisle polyline's points
}

-- A field that can hold a sale (rankCandidates).
TCAuctionLayout.RULES = {
    maxSlopePercent = 8,  -- the steepest 8 m of ground in the layout
    entranceReach = 60,   -- the furthest a road may be from the field's edge
}

-- Why a field can't hold a sale (rankCandidates' problems).
TCAuctionLayout.PROBLEM = {
    TOO_SMALL = "tooSmall",
    TOO_STEEP = "tooSteep",
    NO_ROAD = "noRoad",
}

-- Geometry -------------------------------------------------------------------------------

local function toWorld(rect, u, v)
    local cosA, sinA = math.cos(rect.angle), math.sin(rect.angle)
    return rect.cx + u * cosA - v * sinA, rect.cz + u * sinA + v * cosA
end

-- A world point in the rectangle's frame: u along its long side, v across.
function TCAuctionLayout.toLocal(rect, x, z)
    local cosA, sinA = math.cos(rect.angle), math.sin(rect.angle)
    local dx, dz = x - rect.cx, z - rect.cz
    return dx * cosA + dz * sinA, -dx * sinA + dz * cosA
end

-- The world direction of the rectangle's (du, dv).
local function directionToWorld(rect, du, dv)
    local cosA, sinA = math.cos(rect.angle), math.sin(rect.angle)
    return du * cosA - dv * sinA, du * sinA + dv * cosA
end

-- A box in the rectangle's frame as four world points, in order.
local function boxCorners(rect, u1, v1, u2, v2)
    local corners = {}
    for i, c in ipairs({ { u1, v1 }, { u2, v1 }, { u2, v2 }, { u1, v2 } }) do
        local x, z = toWorld(rect, c[1], c[2])
        corners[i] = { x = x, z = z }
    end
    return corners
end

-- A straight line in the rectangle's frame as world points at most
-- pointSpacing apart, both ends included.
local function polyline(rect, u1, v1, u2, v2, spacing)
    local length = math.sqrt((u2 - u1) ^ 2 + (v2 - v1) ^ 2)
    local segments = math.max(1, math.ceil(length / spacing))
    local points = {}
    for s = 0, segments do
        local t = s / segments
        local x, z = toWorld(rect, u1 + (u2 - u1) * t, v1 + (v2 - v1) * t)
        table.insert(points, { x = x, z = z })
    end
    return points
end

-- The four corners of a lot's footprint (centre, size, heading yaw as
-- MathUtil.getYRotationFromDirection's: atan2(dirX, dirZ)), as world points.
function TCAuctionLayout.getFootprintCorners(x, z, yaw, width, length)
    local fx, fz = math.sin(yaw), math.cos(yaw)
    -- The right hand, as RepairContracts' bays (u = (vZ, -vX)).
    local rx, rz = fz, -fx
    local hw, hl = width * 0.5, length * 0.5
    local corners = {}
    for i, c in ipairs({ { -hw, -hl }, { hw, -hl }, { hw, hl }, { -hw, hl } }) do
        corners[i] = { x = x + rx * c[1] + fx * c[2], z = z + rz * c[1] + fz * c[2] }
    end
    return corners
end

-- Where a vehicle's root goes for its footprint to be centred on (x, z)
-- facing yaw: its size's widthOffset is along its right hand and
-- lengthOffset along its front (RepairContracts.getSpawnPose's).
function TCAuctionLayout.getRootPosition(x, z, yaw, widthOffset, lengthOffset)
    local fx, fz = math.sin(yaw), math.cos(yaw)
    local rx, rz = fz, -fx
    widthOffset, lengthOffset = widthOffset or 0, lengthOffset or 0
    return x - rx * widthOffset - fx * lengthOffset, z - rz * widthOffset - fz * lengthOffset
end

local function copyLayout(options)
    local layout = {}
    for key, value in pairs(TCAuctionLayout.LAYOUT) do
        layout[key] = value
    end
    for key, value in pairs(options or {}) do
        layout[key] = value
    end
    return layout
end

-- The layout (pure). polygon: the field's { x, z } points; entrance: { x, z }
-- or nil (then the space is kept at the rectangle's -u end); lots: a list of
-- { width, length, widthOffset, lengthOffset } (the ground each lot takes,
-- its attachment included); options: any LAYOUT values to change.
--
-- Returns nil when the polygon holds no rectangle, else {
--   rect = { cx, cz, angle, halfU, halfV },
--   placed = { [lot index] = { x, z (the footprint's centre), rootX, rootZ,
--     yaw, row, slot (its place in the row, 1 nearest the entrance) } },
--     placedCount, unplaced = { lot index, ... },
--   rows = { { corners, facing (1 or -1), lotCount } },
--   aisles = { { points } } (along the rows, then the two cross aisles),
--   aisleStrips = { { vFrom, vTo } } (the rows' aisles, in the rect's frame),
--   walkways = { { x1, z1, x2, z2, halfWidth } } (each row aisle's middle
--     line, end to end, and half its width: the crowd's walks, 137; no lot
--     stands within halfWidth of the line),
--   reserve = { corners, uFrom, uTo, vFrom, vTo } (as wide as the rows,
--     which are centred across the rectangle), nearSign (1: the entrance is at +u),
--   lotsFrom, lotsTo (the u range lots stand in),
-- }.
function TCAuctionLayout.layOut(polygon, entrance, lots, options)
    local layout = copyLayout(options)
    local rect = TCAuctionCrowd.findLargestRect(polygon, layout)
    if rect == nil then
        return nil
    end

    -- Which end the entrance is: the car park's end.
    local nearSign = -1
    if entrance ~= nil then
        local eu = TCAuctionLayout.toLocal(rect, entrance.x, entrance.z)
        nearSign = eu >= 0 and 1 or -1
    end
    local halfU, halfV = rect.halfU, rect.halfV
    -- Lots stand between the reserve and the far cross aisle.
    local nearEdge = nearSign * (halfU - layout.entranceSpace)
    local farEdge = -nearSign * (halfU - layout.endAisle)
    local lotsFrom, lotsTo = math.min(nearEdge, farEdge), math.max(nearEdge, farEdge)

    -- The rows from vStart across; returns the result and how far across
    -- they reach.
    local function build(vStart)
        local result = {
            rect = rect,
            placed = {},
            placedCount = 0,
            unplaced = {},
            rows = {},
            aisles = {},
            aisleStrips = {},
            walkways = {},
            nearSign = nearSign,
            lotsFrom = lotsFrom,
            lotsTo = lotsTo,
        }

        -- Longest first (ties by their order), so a row's lots are much of a size.
        local order = {}
        for i = 1, #lots do
            order[i] = i
        end
        table.sort(order, function(a, b)
            if lots[a].length ~= lots[b].length then
                return lots[a].length > lots[b].length
            end
            return a < b
        end)

        local span = lotsTo - lotsFrom
        -- A lot too wide for a row at all is left out.
        local fits = {}
        for _, index in ipairs(order) do
            if lots[index].width <= span then
                table.insert(fits, index)
            else
                table.insert(result.unplaced, index)
            end
        end
        order = fits
        local next = 1
        local cursor = vStart
        local vEnd = vStart
        local rowIndex = 0

        -- Fills one row of the given depth, from the entrance end outwards,
        -- with lots in order while they fit along it. frontV is the aisle's
        -- edge, facing the way the lots face (1 or -1).
        local function fillRow(frontV, depth, facing)
            rowIndex = rowIndex + 1
            local count = 0
            local used = 0
            while next <= #order do
                local index = order[next]
                local lot = lots[index]
                local need = lot.width + (count > 0 and layout.lotGap or 0)
                if used + need > span + 0.001 then
                    break
                end
                used = used + need
                -- Along u from the entrance end; across v, its front on the aisle.
                local uMiddle = nearEdge - nearSign * (used - lot.width * 0.5)
                local vMiddle = frontV - facing * lot.length * 0.5
                local x, z = toWorld(rect, uMiddle, vMiddle)
                local dx, dz = directionToWorld(rect, 0, facing)
                local yaw = math.atan2(dx, dz)
                local rootX, rootZ = TCAuctionLayout.getRootPosition(x, z, yaw, lot.widthOffset, lot.lengthOffset)
                result.placed[index] = { x = x, z = z, rootX = rootX, rootZ = rootZ, yaw = yaw, row = rowIndex,
                    slot = count + 1 }
                result.placedCount = result.placedCount + 1
                count = count + 1
                next = next + 1
            end
            local backV = frontV - facing * depth
            table.insert(result.rows, {
                corners = boxCorners(rect, lotsFrom, math.min(frontV, backV), lotsTo, math.max(frontV, backV)),
                facing = facing,
                lotCount = count,
                -- 140: across the rectangle, its front's v, and how far from
                -- the entrance end its lots reach.
                vFrom = math.min(frontV, backV),
                vTo = math.max(frontV, backV),
                frontV = frontV,
                used = used,
            })
            return count
        end

        while next <= #order do
            -- A row facing up, then its aisle: both have to fit.
            local depth = lots[order[next]].length
            if cursor + depth + layout.aisleWidth > halfV + 0.001 then
                break
            end
            local aisleFrom = cursor + depth
            local aisleTo = aisleFrom + layout.aisleWidth
            fillRow(aisleFrom, depth, 1)
            vEnd = aisleTo
            table.insert(result.aisleStrips, { vFrom = aisleFrom, vTo = aisleTo })
            local aisleV = (aisleFrom + aisleTo) * 0.5
            local aisleEnd = farEdge - nearSign * layout.endAisle * 0.5
            table.insert(result.aisles, {
                points = polyline(rect, nearEdge, aisleV, aisleEnd, aisleV, layout.pointSpacing),
            })
            local x1, z1 = toWorld(rect, nearEdge, aisleV)
            local x2, z2 = toWorld(rect, aisleEnd, aisleV)
            table.insert(result.walkways, { x1 = x1, z1 = z1, x2 = x2, z2 = z2, halfWidth = layout.aisleWidth * 0.5 })
            cursor = aisleTo
            -- The row facing down into it, if there's room and anything left.
            if next <= #order then
                depth = lots[order[next]].length
                if cursor + depth <= halfV + 0.001 then
                    fillRow(cursor, depth, -1)
                    vEnd = cursor + depth
                    cursor = cursor + depth + layout.backGap
                else
                    break
                end
            end
        end

        for i = next, #order do
            table.insert(result.unplaced, order[i])
        end
        table.sort(result.unplaced)

        -- The cross aisles joining the rows' aisles: along the reserve's edge
        -- and through the far end, over the width the aisles take.
        if #result.aisleStrips > 0 then
            local vFrom = result.aisleStrips[1].vFrom + layout.aisleWidth * 0.5
            local vTo = result.aisleStrips[#result.aisleStrips].vFrom + layout.aisleWidth * 0.5
            if vTo > vFrom then
                local nearU = nearEdge + nearSign * layout.aisleWidth * 0.5
                local farU = farEdge - nearSign * layout.endAisle * 0.5
                table.insert(result.aisles, { points = polyline(rect, nearU, vFrom, nearU, vTo, layout.pointSpacing) })
                table.insert(result.aisles, { points = polyline(rect, farU, vFrom, farU, vTo, layout.pointSpacing) })
            end
        end
        return result, vEnd
    end

    -- Laid out from one side to see how far across the rows reach, then
    -- again centred across the rectangle.
    local _, vEnd = build(-halfV)
    local vStart = -halfV + (halfV - vEnd) * 0.5
    local result
    result, vEnd = build(vStart)

    -- The car park and food area's space: at the entrance end, as wide as the
    -- rows (the whole rectangle with none).
    local reserveFrom = nearSign > 0 and halfU - layout.entranceSpace or -halfU
    local reserveTo = nearSign > 0 and halfU or -halfU + layout.entranceSpace
    local reserveV1, reserveV2 = vStart, vEnd
    if vEnd <= vStart then
        reserveV1, reserveV2 = -halfV, halfV
    end
    result.reserve = { corners = boxCorners(rect, reserveFrom, reserveV1, reserveTo, reserveV2), uFrom = reserveFrom,
        uTo = reserveTo, vFrom = reserveV1, vTo = reserveV2 }
    result.nearEdge, result.farEdge = nearEdge, farEdge
    result.aisleWidth, result.endAisle = layout.aisleWidth, layout.endAisle
    return result
end

-- 140: what every machine needs to dress the site (TCAuctionScene), from
-- layOut's result (pure): the rectangle's frame, the entrance's space, where
-- the gate is along its outer edge, the cross aisles' sizes and each row's
-- place and lots. Lots are numbered row by row (getWalkOrder), so a row's
-- lots are the next lotCount numbers. entrance: { x, z } or nil (the gate in
-- the middle). seed: any whole number, for the props' picks. Returns {
--   seed, cx, cz, angle, halfV (the rectangle's), nearSign, nearEdge,
--   farEdge, aisleWidth, endAisle,
--   reserve = { uFrom, uTo, vFrom, vTo }, gateV,
--   rows = { { vFrom, vTo, frontV, facing, used, lotFrom, lotTo, slots } }
--     (rows with no lots left out; slots: each lot's middle along u, in
--     slot order),
-- }, all in the rectangle's frame (u along the rows, v across).
function TCAuctionLayout.getScene(layout, entrance, seed)
    local rect, reserve = layout.rect, layout.reserve
    local scene = {
        seed = seed or 0,
        cx = rect.cx,
        cz = rect.cz,
        angle = rect.angle,
        halfV = rect.halfV,
        nearSign = layout.nearSign,
        nearEdge = layout.nearEdge,
        farEdge = layout.farEdge,
        aisleWidth = layout.aisleWidth,
        endAisle = layout.endAisle,
        reserve = { uFrom = reserve.uFrom, uTo = reserve.uTo, vFrom = reserve.vFrom, vTo = reserve.vTo },
        rows = {},
    }
    local gateV = (reserve.vFrom + reserve.vTo) * 0.5
    if entrance ~= nil then
        local _, v = TCAuctionLayout.toLocal(rect, entrance.x, entrance.z)
        gateV = math.max(reserve.vFrom, math.min(reserve.vTo, v))
    end
    scene.gateV = gateV
    -- Each row's lots' middles along u, by slot.
    local slots = {}
    for _, spot in pairs(layout.placed) do
        slots[spot.row] = slots[spot.row] or {}
        slots[spot.row][spot.slot] = (TCAuctionLayout.toLocal(rect, spot.x, spot.z))
    end
    local number = 0
    for rowIndex, row in ipairs(layout.rows) do
        if row.lotCount > 0 then
            local rowSlots = {}
            for slot = 1, row.lotCount do
                table.insert(rowSlots, slots[rowIndex] ~= nil and slots[rowIndex][slot] or nil)
            end
            table.insert(scene.rows, { vFrom = row.vFrom, vTo = row.vTo, frontV = row.frontV, facing = row.facing,
                used = row.used, lotFrom = number + 1, lotTo = number + row.lotCount, slots = rowSlots })
            number = number + row.lotCount
        end
    end
    return scene
end

-- The placed lots in the order they're walked (pure), for their numbers
-- (138): row by row, each from the entrance end out. placed: layOut's.
-- Returns the lot indices.
function TCAuctionLayout.getWalkOrder(placed)
    local order = {}
    for index in pairs(placed) do
        table.insert(order, index)
    end
    table.sort(order, function(a, b)
        local pa, pb = placed[a], placed[b]
        if pa.row ~= pb.row then
            return pa.row < pb.row
        end
        if pa.slot ~= pb.slot then
            return pa.slot < pb.slot
        end
        return a < b
    end)
    return order
end

-- Ranking --------------------------------------------------------------------------------

-- Why a candidate can't hold a sale of wantedLots: a list of PROBLEMs.
-- candidate: { fitted, slopePercent, entranceDistance (nil: no road near) }.
function TCAuctionLayout.getProblems(candidate, wantedLots, rules)
    rules = rules or TCAuctionLayout.RULES
    local problems = {}
    if (candidate.fitted or 0) < wantedLots then
        table.insert(problems, TCAuctionLayout.PROBLEM.TOO_SMALL)
    end
    if candidate.slopePercent ~= nil and candidate.slopePercent > rules.maxSlopePercent then
        table.insert(problems, TCAuctionLayout.PROBLEM.TOO_STEEP)
    end
    if candidate.entranceDistance == nil or candidate.entranceDistance > rules.entranceReach then
        table.insert(problems, TCAuctionLayout.PROBLEM.NO_ROAD)
    end
    return problems
end

-- The candidates best first (pure): those that can hold the sale before
-- those that can't, then by how many lots fit (a sale takes as many as its
-- field fits, up to a preferred number), then the biggest by area.
-- Each gets its problems (getProblems). Returns a new list.
function TCAuctionLayout.rankCandidates(candidates, wantedLots, rules)
    local ranked = {}
    for i, candidate in ipairs(candidates) do
        candidate.problems = TCAuctionLayout.getProblems(candidate, wantedLots, rules)
        ranked[i] = candidate
    end
    table.sort(ranked, function(a, b)
        local aOk, bOk = #a.problems == 0, #b.problems == 0
        if aOk ~= bOk then
            return aOk
        end
        if (a.fitted or 0) ~= (b.fitted or 0) then
            return (a.fitted or 0) > (b.fitted or 0)
        end
        if (a.areaHa or 0) ~= (b.areaHa or 0) then
            return (a.areaHa or 0) > (b.areaHa or 0)
        end
        return (a.fieldId or 0) < (b.fieldId or 0)
    end)
    return ranked
end

-- Slope (pure): heights[r][c] sampled every `step` metres (nil where there's
-- no sample). Returns the steepest rise between neighbouring samples and the
-- average, both in percent, and the whole rise (highest less lowest) in
-- metres; nil with fewer than two samples side by side.
function TCAuctionLayout.measureSlope(heights, step)
    local steepest, total, count, lowest, highest = 0, 0, 0, math.huge, -math.huge
    for r, row in pairs(heights) do
        for c, h in pairs(row) do
            lowest, highest = math.min(lowest, h), math.max(highest, h)
            for _, n in ipairs({ { r, c + 1 }, { r + 1, c } }) do
                local other = heights[n[1]] ~= nil and heights[n[1]][n[2]] or nil
                if other ~= nil then
                    local percent = math.abs(other - h) / step * 100
                    steepest = math.max(steepest, percent)
                    total = total + percent
                    count = count + 1
                end
            end
        end
    end
    if count == 0 then
        return nil
    end
    return steepest, total / count, highest - lowest
end

-- The heights grid's sample points over the layout's rectangle (pure):
-- { { x, z, row, col } }, every `step` metres including the edges.
function TCAuctionLayout.getSamplePoints(rect, step)
    local points = {}
    local cols = math.max(1, math.floor(rect.halfU * 2 / step))
    local rows = math.max(1, math.floor(rect.halfV * 2 / step))
    for r = 0, rows do
        for c = 0, cols do
            local u = -rect.halfU + rect.halfU * 2 * c / cols
            local v = -rect.halfV + rect.halfV * 2 * r / rows
            local x, z = toWorld(rect, u, v)
            table.insert(points, { x = x, z = z, row = r + 1, col = c + 1 })
        end
    end
    return points
end

-- Entrance -------------------------------------------------------------------------------

-- The nearest point on segment a-b to p, and the distance.
local function nearestOnSegment(px, pz, ax, az, bx, bz)
    local dx, dz = bx - ax, bz - az
    local lengthSq = dx * dx + dz * dz
    local t = lengthSq > 0 and ((px - ax) * dx + (pz - az) * dz) / lengthSq or 0
    t = math.max(0, math.min(1, t))
    local x, z = ax + dx * t, az + dz * t
    return x, z, math.sqrt((px - x) ^ 2 + (pz - z) ^ 2)
end

-- The road point nearest the field's edge (pure), within reach: { x, z
-- (the road point), edgeX, edgeZ (the nearest point of the field's edge),
-- distance }, or nil. Road points inside the field don't count. roadPoints:
-- { x, z } (FallenTree.sampleRoads').
function TCAuctionLayout.findEntrance(polygon, roadPoints, reach)
    if polygon == nil or #polygon < 3 then
        return nil
    end
    local minX, maxX, minZ, maxZ = math.huge, -math.huge, math.huge, -math.huge
    for _, p in ipairs(polygon) do
        minX, maxX = math.min(minX, p.x), math.max(maxX, p.x)
        minZ, maxZ = math.min(minZ, p.z), math.max(maxZ, p.z)
    end
    local best = nil
    for _, road in ipairs(roadPoints) do
        if road.x >= minX - reach and road.x <= maxX + reach and road.z >= minZ - reach and road.z <= maxZ + reach and
                not TCAuctionCrowd.pointInPolygon(road.x, road.z, polygon) then
            local n = #polygon
            for i = 1, n do
                local a, b = polygon[i], polygon[i % n + 1]
                local x, z, distance = nearestOnSegment(road.x, road.z, a.x, a.z, b.x, b.z)
                if distance <= reach and (best == nil or distance < best.distance) then
                    best = { x = road.x, z = road.z, edgeX = x, edgeZ = z, distance = distance }
                end
            end
        end
    end
    return best
end

-- Lots -----------------------------------------------------------------------------------

-- Which roles a sale's lots are (pure). roleDefs: { { role, weight, min,
-- max } } in the order lots are listed; available: role -> true (or a
-- number: the most lots of it there can be) for the roles the store has
-- models for (nil: all). Every available role gets its min first (in order,
-- as far as lotCount goes), then the rest are drawn by weight among the
-- roles under their max. Fewer than lotCount when every role is at its max. Returns { role, ... } in roleDefs' order, and the
-- counts (role -> n).
function TCAuctionLayout.pickRoles(roleDefs, lotCount, random, available)
    local counts = {}
    local total = 0
    local usable = {}
    for _, def in ipairs(roleDefs) do
        local limit = available ~= nil and available[def.role] or nil
        if available == nil or limit then
            -- A copy with the store's limit on its max.
            local capped = { role = def.role, weight = def.weight, min = def.min, max = def.max or math.huge }
            if type(limit) == "number" then
                capped.max = math.min(capped.max, limit)
            end
            table.insert(usable, capped)
            counts[def.role] = 0
        end
    end
    for _, def in ipairs(usable) do
        local take = math.min(def.min or 0, def.max, lotCount - total)
        counts[def.role] = take
        total = total + take
    end
    while total < lotCount do
        local weightSum = 0
        for _, def in ipairs(usable) do
            if counts[def.role] < (def.max or math.huge) then
                weightSum = weightSum + (def.weight or 0)
            end
        end
        if weightSum <= 0 then
            break
        end
        local roll = random() * weightSum
        local chosen = nil
        for _, def in ipairs(usable) do
            if counts[def.role] < (def.max or math.huge) and (def.weight or 0) > 0 then
                chosen = def
                roll = roll - def.weight
                if roll < 0 then
                    break
                end
            end
        end
        counts[chosen.role] = counts[chosen.role] + 1
        total = total + 1
    end
    local roles = {}
    for _, def in ipairs(usable) do
        for _ = 1, counts[def.role] do
            table.insert(roles, def.role)
        end
    end
    return roles, counts
end

-- A used lot's condition (pure), from a preset { hoursMin, hoursMax,
-- damageMin, damageMax, wearMin, wearMax }: { hours, damage, wear,
-- ageMonths }. The age comes from the hours at hoursPerYear, as Used
-- Equipment Yards works it out, a month at least.
function TCAuctionLayout.rollCondition(preset, hoursPerYear, random)
    local function range(from, to)
        return from + random() * (to - from)
    end
    local hours = range(preset.hoursMin, preset.hoursMax)
    return {
        hours = hours,
        damage = range(preset.damageMin, preset.damageMax),
        wear = range(preset.wearMin, preset.wearMax),
        ageMonths = math.max(1, math.floor(hours / hoursPerYear * 12)),
    }
end

-- The roles the catalog (TheContractorFarmerFleet.buildCatalog's) has models
-- for (getLotModels', within the role's price cap), for pickRoles'
-- available: role -> how many lots of it there can be with at most
-- maxDuplicates of each model (true with no maxDuplicates).
function TCAuctionLayout.getAvailableRoles(catalog, roleDefs, maxDuplicates)
    local available = {}
    for _, def in ipairs(roleDefs) do
        local count = #TCAuctionLayout.getLotModels(catalog, def.role, def)
        if count > 0 then
            available[def.role] = maxDuplicates ~= nil and count * maxDuplicates or true
        end
    end
    return available
end

-- The models a sale's lots of a role can be (pure): getRoleModels', less
-- any priced over medianPriceCap times the role's median price (def:
-- LOT_ROLES' row, or nil: no cap), so a sale has no flagship machines. The
-- median, not the cheapest, as a role's cheapest can be a toy (a small
-- tipping trailer). A model with no price is kept. Never empty while the
-- role has models: the median's under any cap of 1 or more.
function TCAuctionLayout.getLotModels(catalog, role, def)
    local models = TheContractorFarmerFleet.getRoleModels(catalog, role)
    local cap = def ~= nil and def.medianPriceCap or nil
    if cap == nil then
        return models
    end
    local prices = {}
    for _, model in ipairs(models) do
        if model.price ~= nil then
            table.insert(prices, model.price)
        end
    end
    if #prices == 0 then
        return models
    end
    table.sort(prices)
    local middle = (#prices + 1) / 2
    local median = (prices[math.floor(middle)] + prices[math.ceil(middle)]) / 2
    local kept = {}
    for _, model in ipairs(models) do
        if model.price == nil or model.price <= median * cap then
            table.insert(kept, model)
        end
    end
    return kept
end

-- Each model's weight within its role (pure), by price band: the models
-- ranked by price, the cheapest cheapShare of them (0 to 1) weigh boost,
-- the rest 1, so a sale has less of the top end. A model in the band when
-- the middle of its place in the ranking is: with 2 models and a share of
-- 0.4, the cheaper one. A model with no price weighs 1 and isn't ranked.
-- No share (or no boost): all 1. Returns xmlFilename -> weight.
function TCAuctionLayout.getModelWeights(models, cheapShare, boost)
    local weights = {}
    local priced = {}
    for _, model in ipairs(models) do
        weights[model.xmlFilename] = 1
        if model.price ~= nil then
            table.insert(priced, model)
        end
    end
    if cheapShare == nil or boost == nil or #priced == 0 then
        return weights
    end
    table.sort(priced, function(a, b)
        if a.price ~= b.price then
            return a.price < b.price
        end
        return a.xmlFilename < b.xmlFilename
    end)
    for i, model in ipairs(priced) do
        if (i - 0.5) / #priced < cheapShare then
            weights[model.xmlFilename] = boost
        end
    end
    return weights
end

-- A model for each role (pure, from the catalog): { { role, xmlFilename,
-- attachmentXml } }, a machine that takes an attachment (a combine's
-- header, ATTACHMENT_ROLE) with one that fits it when there's one. No model
-- more than maxDuplicates times (nil: no limit), so a sale isn't a row of
-- the same tractor. A role with no model left is left out. roleDefs
-- (optional, LOT_ROLES'): a role's medianPriceCap drops its dearest models
-- first (getLotModels), then its cheapShare and cheapBoost (or
-- defaultBoost) weight the rest by price band (getModelWeights); without
-- them every model's as likely.
function TCAuctionLayout.pickLots(catalog, roles, random, maxDuplicates, roleDefs, defaultBoost)
    local F = TheContractorFarmerFleet
    local lots = {}
    local used = {}
    local defsByRole = {}
    for _, def in ipairs(roleDefs or {}) do
        defsByRole[def.role] = def
    end
    local modelsByRole, weightsByRole = {}, {}
    for _, role in ipairs(roles) do
        if modelsByRole[role] == nil then
            local def = defsByRole[role]
            local share = def ~= nil and def.cheapShare or nil
            local boost = def ~= nil and (def.cheapBoost or defaultBoost) or nil
            modelsByRole[role] = TCAuctionLayout.getLotModels(catalog, role, def)
            weightsByRole[role] = TCAuctionLayout.getModelWeights(modelsByRole[role], share, boost)
        end
        local weights = weightsByRole[role]
        local models = {}
        local weightSum = 0
        for _, candidate in ipairs(modelsByRole[role]) do
            if maxDuplicates == nil or (used[candidate.xmlFilename] or 0) < maxDuplicates then
                table.insert(models, candidate)
                weightSum = weightSum + weights[candidate.xmlFilename]
            end
        end
        local model = nil
        if #models > 0 then
            local roll = random() * weightSum
            for _, candidate in ipairs(models) do
                model = candidate
                roll = roll - weights[candidate.xmlFilename]
                if roll < 0 then
                    break
                end
            end
        end
        if model ~= nil then
            used[model.xmlFilename] = (used[model.xmlFilename] or 0) + 1
            local lot = { role = role, xmlFilename = model.xmlFilename }
            if F.ATTACHMENT_ROLE[role] ~= nil then
                local attachment = F.pickAttachmentModel(catalog, model.xmlFilename, random)
                lot.attachmentXml = attachment ~= nil and attachment.xmlFilename or nil
            end
            table.insert(lots, lot)
        end
    end
    return lots
end
