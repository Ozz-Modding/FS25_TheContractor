-- Show site (164, spike): the pure half of TheContractorShowSite. The
-- agricultural show (165) is one combined day: a showground on grass (the
-- pens, trailer lines, ring, stands and crowd) and a ploughing match on
-- stubble next to it, in 4 to 6 square plots side by side. Everything here
-- works on plain numbers and tables, so it's tested outside the game
-- (tests/test_showSite.lua).
--
--   One field first (the user's call): the field's largest rectangle (135's
--     search) split across its long side. The showground takes the end
--     nearest the road (the entrance), SHOWGROUND_LENGTH along and at least
--     SHOWGROUND_WIDTH across; a DIVIDE strip; the ploughing ground the rest
--     (splitSingle). 188: the showground's longer, up to
--     MAX_SHOWGROUND_LENGTH, when the ploughing ground still has as many
--     plots, so the breeders' pens have room past the trailer lines. The line across the field between them (perpendicular
--     to the long side, through the divide) is where the ground's dressed
--     one way or the other (clipPolygon).
--   Two fields next to each other when no one field will do (findPairs:
--     their edges within PAIR_MAX_GAP): one field's rectangle is the
--     showground, the other's the ploughing ground.
--   The plots (layPlots, pickPlots): squares PLOT_SIZE a side, PLOT_GAP
--     apart (a headland strip between neighbours), in rows along the
--     ploughing ground's long side. The plots are a run of up to MAX_PLOTS
--     side by side in one row (never fewer than MIN_PLOTS), the run whose
--     steepest plot is flattest.
--   Ranking (rankCandidates): those that can hold the show first, one field
--     before a pair, then the most plots, the flattest plots, the biggest.
--
-- The plot size is 168's: about 15 real minutes' ploughing for a 3-4
-- furrow plough. The count (4 to 6) is still 164's guess.

TCShowSite = {}

TCShowSite.RULES = {
    plotSize = 35,               -- a plot's side (m), 168's
    plotGap = 6,                 -- between neighbouring plots
    minPlots = 4,
    maxPlots = 6,
    showgroundLength = 120,      -- along the field, from the entrance end, at least
    -- 188: up to this long, in steps, while the ploughing ground still has
    -- as many plots (splitSingle), so the breeders' pens have room.
    maxShowgroundLength = 160,
    showgroundStep = 10,
    showgroundWidth = 60,        -- across it, at least
    -- 188: a showground this long or this wide has room for breeders'
    -- pens (TCShowScene's), and ranks first (rankCandidates).
    roomyLength = 140,
    roomyWidth = 100,
    divide = 10,                 -- between the showground and the plots
    maxPlotSlopePercent = 6,     -- the steepest 8 m in a plot
    maxShowgroundSlopePercent = 8,
    pairMaxGap = 15,             -- two fields' edges at most this far apart
    entranceReach = 60,          -- a road at most this far from the showground's field
}

-- The largest rectangle's search (TCAuctionCrowd.findLargestRect).
TCShowSite.RECT_LAYOUT = { step = 4, inset = 6, angleStepDeg = 15 }

TCShowSite.MODE = { SINGLE = "single", PAIR = "pair" }

TCShowSite.PROBLEM = {
    NO_SHOWGROUND = "noShowground",
    TOO_FEW_PLOTS = "tooFewPlots",
    TOO_STEEP = "tooSteep",
    NO_ROAD = "noRoad",
}

-- Geometry ---------------------------------------------------------------------------------

-- A rectangle is { cx, cz, angle, halfU, halfV }: u along its long side
-- (angle's direction), v across.
function TCShowSite.toWorld(rect, u, v)
    local cosA, sinA = math.cos(rect.angle), math.sin(rect.angle)
    return rect.cx + u * cosA - v * sinA, rect.cz + u * sinA + v * cosA
end

function TCShowSite.toLocal(rect, x, z)
    local cosA, sinA = math.cos(rect.angle), math.sin(rect.angle)
    local dx, dz = x - rect.cx, z - rect.cz
    return dx * cosA + dz * sinA, -dx * sinA + dz * cosA
end

-- The part of a rectangle between uFrom..uTo and vFrom..vTo, as a rectangle
-- of its own (the same angle).
function TCShowSite.subRect(rect, uFrom, uTo, vFrom, vTo)
    local cx, cz = TCShowSite.toWorld(rect, (uFrom + uTo) * 0.5, (vFrom + vTo) * 0.5)
    return { cx = cx, cz = cz, angle = rect.angle, halfU = (uTo - uFrom) * 0.5, halfV = (vTo - vFrom) * 0.5 }
end

-- A rectangle's corners, in order.
function TCShowSite.getCorners(rect)
    local corners = {}
    for i, c in ipairs({ { -1, -1 }, { 1, -1 }, { 1, 1 }, { -1, 1 } }) do
        local x, z = TCShowSite.toWorld(rect, c[1] * rect.halfU, c[2] * rect.halfV)
        corners[i] = { x = x, z = z }
    end
    return corners
end

-- The part of a polygon on one side of a line (Sutherland-Hodgman): the
-- points whose offset from (px, pz) along (nx, nz) isn't negative. A
-- concave polygon may come back with an edge along the line joining two
-- pieces; as a filled area it's still right.
function TCShowSite.clipPolygon(polygon, px, pz, nx, nz)
    local result = {}
    local count = #polygon
    if count == 0 then
        return result
    end
    local function side(p)
        return (p.x - px) * nx + (p.z - pz) * nz
    end
    local previous = polygon[count]
    local previousSide = side(previous)
    for i = 1, count do
        local current = polygon[i]
        local currentSide = side(current)
        if (currentSide >= 0) ~= (previousSide >= 0) then
            local t = previousSide / (previousSide - currentSide)
            table.insert(result, { x = previous.x + (current.x - previous.x) * t,
                z = previous.z + (current.z - previous.z) * t })
        end
        if currentSide >= 0 then
            table.insert(result, { x = current.x, z = current.z })
        end
        previous, previousSide = current, currentSide
    end
    return result
end

-- A polygon's area (m2).
function TCShowSite.getArea(polygon)
    local sum = 0
    for i = 1, #polygon do
        local a, b = polygon[i], polygon[i % #polygon + 1]
        sum = sum + a.x * b.z - b.x * a.z
    end
    return math.abs(sum) * 0.5
end

-- One field ---------------------------------------------------------------------------------

-- A field's rectangle split into the showground (at the entrance's end; the
-- rectangle's -u end without one) and the ploughing ground, or nil when it
-- isn't long or wide enough for the showground and one plot. Returns {
--   showRect, ploughRect (rectangles),
--   line = { x, z, nx, nz } (a point on the dividing line across the field,
--     and its normal, towards the showground),
--   nearSign (1: the showground's at the rectangle's +u end),
-- }.
-- 188: the most plots a ploughing ground's rows can run (pure, by
-- layPlots' rows; the flattest run's for pickPlots).
function TCShowSite.countPlots(region, rules)
    rules = rules or TCShowSite.RULES
    local best = 0
    for _, row in ipairs(TCShowSite.layPlots(region, rules)) do
        best = math.max(best, math.min(rules.maxPlots, #row))
    end
    return best
end

-- 188: whether a showground has room for breeders' pens (pure).
function TCShowSite.isRoomy(rect, rules)
    rules = rules or TCShowSite.RULES
    return rect ~= nil and (2 * rect.halfU >= rules.roomyLength - 0.001 or 2 * rect.halfV >= rules.roomyWidth - 0.001)
end

function TCShowSite.splitSingle(rect, entrance, rules)
    rules = rules or TCShowSite.RULES
    local length = 2 * rect.halfU
    if length < rules.showgroundLength + rules.divide + rules.plotSize or 2 * rect.halfV < rules.showgroundWidth then
        return nil
    end
    -- 188: as long as it can be (to maxShowgroundLength) while the
    -- ploughing ground keeps the plots it has at the shortest.
    local showLength = rules.showgroundLength
    local fewest = TCShowSite.countPlots(TCShowSite.splitAt(rect, entrance, rules, showLength).ploughRect, rules)
    local step = rules.showgroundStep or 10
    local try = rules.maxShowgroundLength or showLength
    while try > showLength + 0.001 do
        if length >= try + rules.divide + rules.plotSize and
                TCShowSite.countPlots(TCShowSite.splitAt(rect, entrance, rules, try).ploughRect, rules) >= fewest then
            showLength = try
            break
        end
        try = try - step
    end
    return TCShowSite.splitAt(rect, entrance, rules, showLength)
end

-- The split with a showground showLength long (splitSingle's).
function TCShowSite.splitAt(rect, entrance, rules, showLength)
    local nearSign = -1
    if entrance ~= nil then
        local eu = TCShowSite.toLocal(rect, entrance.x, entrance.z)
        nearSign = eu >= 0 and 1 or -1
    end
    local halfU, halfV = rect.halfU, rect.halfV
    local showInner = halfU - showLength
    local ploughInner = showInner - rules.divide
    local showRect, ploughRect
    if nearSign > 0 then
        showRect = TCShowSite.subRect(rect, showInner, halfU, -halfV, halfV)
        ploughRect = TCShowSite.subRect(rect, -halfU, ploughInner, -halfV, halfV)
    else
        showRect = TCShowSite.subRect(rect, -halfU, -showInner, -halfV, halfV)
        ploughRect = TCShowSite.subRect(rect, -ploughInner, halfU, -halfV, halfV)
    end
    local lineU = nearSign * (showInner - rules.divide * 0.5)
    local x, z = TCShowSite.toWorld(rect, lineU, 0)
    local cosA, sinA = math.cos(rect.angle), math.sin(rect.angle)
    return {
        showRect = showRect,
        ploughRect = ploughRect,
        line = { x = x, z = z, nx = nearSign * cosA, nz = nearSign * sinA },
        nearSign = nearSign,
    }
end

-- The field's polygon either side of the dividing line: the showground's
-- and the ploughing ground's.
function TCShowSite.splitPolygon(polygon, line)
    return TCShowSite.clipPolygon(polygon, line.x, line.z, line.nx, line.nz),
        TCShowSite.clipPolygon(polygon, line.x, line.z, -line.nx, -line.nz)
end

-- Whether a whole rectangle will do for the showground (two fields).
function TCShowSite.isShowground(rect, rules)
    rules = rules or TCShowSite.RULES
    return rect ~= nil and 2 * rect.halfU >= rules.showgroundLength and 2 * rect.halfV >= rules.showgroundWidth
end

-- The plots --------------------------------------------------------------------------------

-- Every place a plot could go in the ploughing ground: rows along its long
-- side, centred both ways. Returns rows of { cx, cz, angle, half, row, slot }.
function TCShowSite.layPlots(region, rules)
    rules = rules or TCShowSite.RULES
    local size, gap = rules.plotSize, rules.plotGap
    local step = size + gap
    local alongU = region.halfU >= region.halfV
    local long = alongU and region.halfU or region.halfV
    local short = alongU and region.halfV or region.halfU
    local perRow = math.floor((2 * long + gap) / step)
    local rowCount = math.floor((2 * short + gap) / step)
    local rows = {}
    if perRow < 1 or rowCount < 1 then
        return rows
    end
    local alongStart = -(perRow * step - gap) * 0.5 + size * 0.5
    local acrossStart = -(rowCount * step - gap) * 0.5 + size * 0.5
    for r = 1, rowCount do
        local row = {}
        local across = acrossStart + (r - 1) * step
        for s = 1, perRow do
            local along = alongStart + (s - 1) * step
            local u, v = along, across
            if not alongU then
                u, v = across, along
            end
            local cx, cz = TCShowSite.toWorld(region, u, v)
            table.insert(row, { cx = cx, cz = cz, angle = region.angle, half = size * 0.5, row = r, slot = s })
        end
        table.insert(rows, row)
    end
    return rows
end

-- A plot as a rectangle.
function TCShowSite.plotRect(plot)
    return { cx = plot.cx, cz = plot.cz, angle = plot.angle, halfU = plot.half, halfV = plot.half }
end

-- The plots for the match (pure): in one row, a run of as many as fit up to
-- maxPlots (none with fewer than minPlots), the run whose steepest plot is
-- flattest; a tie goes to the run nearest its row's middle, then the first.
-- getSlope(plot): the plot's steepest (percent), nil for flat. Returns the
-- plots and the run's steepest.
function TCShowSite.pickPlots(rows, rules, getSlope)
    rules = rules or TCShowSite.RULES
    local best, bestWorst, bestOffset = nil, nil, nil
    for _, row in ipairs(rows) do
        local count = math.min(rules.maxPlots, #row)
        if count >= rules.minPlots then
            for first = 1, #row - count + 1 do
                local worst = 0
                for i = first, first + count - 1 do
                    worst = math.max(worst, getSlope ~= nil and getSlope(row[i]) or 0)
                end
                local offset = math.abs((first + (count - 1) * 0.5) - (#row + 1) * 0.5)
                local better = best == nil or worst < bestWorst - 0.001 or
                    (math.abs(worst - bestWorst) <= 0.001 and (count > #best or
                        (count == #best and offset < bestOffset - 0.001)))
                if better then
                    best = {}
                    for i = first, first + count - 1 do
                        table.insert(best, row[i])
                    end
                    bestWorst, bestOffset = worst, offset
                end
            end
        end
    end
    return best or {}, bestWorst
end

-- Two fields --------------------------------------------------------------------------------

local function pointSegmentDistance(px, pz, ax, az, bx, bz)
    local dx, dz = bx - ax, bz - az
    local lengthSq = dx * dx + dz * dz
    local t = 0
    if lengthSq > 0 then
        t = math.max(0, math.min(1, ((px - ax) * dx + (pz - az) * dz) / lengthSq))
    end
    local x, z = ax + dx * t, az + dz * t
    return math.sqrt((px - x) ^ 2 + (pz - z) ^ 2)
end

local function pointsToEdges(a, b)
    local best = math.huge
    for _, p in ipairs(a) do
        for i = 1, #b do
            local q, r = b[i], b[i % #b + 1]
            best = math.min(best, pointSegmentDistance(p.x, p.z, q.x, q.z, r.x, r.z))
        end
    end
    return best
end

-- The gap between two fields' edges (m): the nearest any corner of either
-- comes to the other's edge.
function TCShowSite.getGap(a, b)
    return math.min(pointsToEdges(a, b), pointsToEdges(b, a))
end

local function getBounds(polygon)
    local bounds = { minX = math.huge, maxX = -math.huge, minZ = math.huge, maxZ = -math.huge }
    for _, p in ipairs(polygon) do
        bounds.minX, bounds.maxX = math.min(bounds.minX, p.x), math.max(bounds.maxX, p.x)
        bounds.minZ, bounds.maxZ = math.min(bounds.minZ, p.z), math.max(bounds.maxZ, p.z)
    end
    return bounds
end

-- Every pair of fields next to each other (pure): fields { { id, polygon } };
-- returns { { a, b (ids, a < b), gap } }, nearest first.
function TCShowSite.findPairs(fields, maxGap)
    maxGap = maxGap or TCShowSite.RULES.pairMaxGap
    local bounds = {}
    for i, field in ipairs(fields) do
        bounds[i] = getBounds(field.polygon)
    end
    local pairs_ = {}
    for i = 1, #fields do
        for j = i + 1, #fields do
            local a, b = bounds[i], bounds[j]
            if a.minX - maxGap <= b.maxX and b.minX - maxGap <= a.maxX and a.minZ - maxGap <= b.maxZ and
                    b.minZ - maxGap <= a.maxZ then
                local gap = TCShowSite.getGap(fields[i].polygon, fields[j].polygon)
                if gap <= maxGap then
                    local idA, idB = fields[i].id, fields[j].id
                    table.insert(pairs_, { a = math.min(idA, idB), b = math.max(idA, idB), gap = gap })
                end
            end
        end
    end
    table.sort(pairs_, function(x, y)
        if math.abs(x.gap - y.gap) > 0.001 then
            return x.gap < y.gap
        end
        if x.a ~= y.a then
            return x.a < y.a
        end
        return x.b < y.b
    end)
    return pairs_
end

-- Ranking ----------------------------------------------------------------------------------

-- Why a candidate can't hold the show: a list of PROBLEMs. candidate: {
-- hasShowground, plotCount, plotSlope, showgroundSlope, entranceDistance
-- (nil: no road near) }.
function TCShowSite.getProblems(candidate, rules)
    rules = rules or TCShowSite.RULES
    local P = TCShowSite.PROBLEM
    local problems = {}
    if not candidate.hasShowground then
        table.insert(problems, P.NO_SHOWGROUND)
    end
    if (candidate.plotCount or 0) < rules.minPlots then
        table.insert(problems, P.TOO_FEW_PLOTS)
    end
    if (candidate.plotSlope ~= nil and candidate.plotSlope > rules.maxPlotSlopePercent) or
            (candidate.showgroundSlope ~= nil and candidate.showgroundSlope > rules.maxShowgroundSlopePercent) then
        table.insert(problems, P.TOO_STEEP)
    end
    if candidate.entranceDistance == nil or candidate.entranceDistance > rules.entranceReach then
        table.insert(problems, P.NO_ROAD)
    end
    return problems
end

-- The candidates best first (pure): those that can hold the show first,
-- one field before a pair, then (188) a roomy showground (candidate.roomy:
-- isRoomy's, room for breeders' pens), then the most plots, the flattest
-- plots, the biggest. Each gets its problems. Returns a new list.
function TCShowSite.rankCandidates(candidates, rules)
    local ranked = {}
    for i, candidate in ipairs(candidates) do
        candidate.problems = TCShowSite.getProblems(candidate, rules)
        ranked[i] = candidate
    end
    table.sort(ranked, function(a, b)
        local aOk, bOk = #a.problems == 0, #b.problems == 0
        if aOk ~= bOk then
            return aOk
        end
        local aSingle, bSingle = a.mode == TCShowSite.MODE.SINGLE, b.mode == TCShowSite.MODE.SINGLE
        if aSingle ~= bSingle then
            return aSingle
        end
        -- 188: a showground with room for breeders' pens.
        if (a.roomy == true) ~= (b.roomy == true) then
            return a.roomy == true
        end
        if (a.plotCount or 0) ~= (b.plotCount or 0) then
            return (a.plotCount or 0) > (b.plotCount or 0)
        end
        local aSlope, bSlope = a.plotSlope or math.huge, b.plotSlope or math.huge
        if math.abs(aSlope - bSlope) > 0.001 then
            return aSlope < bSlope
        end
        if math.abs((a.areaHa or 0) - (b.areaHa or 0)) > 0.0001 then
            return (a.areaHa or 0) > (b.areaHa or 0)
        end
        return (a.fieldIds[1] or 0) < (b.fieldIds[1] or 0)
    end)
    return ranked
end
