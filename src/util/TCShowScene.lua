-- The agricultural show's showground (165): the pure half of its dressing.
-- The showground is 164's rectangle, laid out as an open site (163's
-- AuctionSite:startOpen, TCAuctionLayout.layOutOpenRect): the entrance
-- space at the road end gets the shared dressing (TCAuctionScene: the car
-- park, food, toilets, bunting, bales) and the show's gate sign. This is
-- the rest, the arena, worked out from the same synced scene (no
-- math.random: picks come from the scene's seed through
-- TCAuctionScene.hash), so every machine lays out the same:
--
--   The ring: a rectangle of hurdles in the middle across, RING.start in
--     from the near cross aisle, with a gap in its near side to lead
--     stock in. Ringside spectators along its long sides.
--   The pens: a row of hurdle pens along one long side (v < 0), as long as
--     the ring, for the livestock classes (167).
--   The stands: gazebos along the other side (v > 0), for 171's trade
--     stands, a couple of people at each.
--   The trailer lines: bays across the far end, past the ring, marked out
--     with cones, where entrants park their livestock trailers (167).
--   The crowd's walks (getWalkways): a lane down each side of the ring
--     (between it and the pens, and it and the stands) and a cross aisle
--     between the ring and the trailer lines; TCAuctionScene.getWalks adds
--     the near and far cross aisles as it does for any site.
--
-- In the scene's frame: u along the showground (nearSign towards the
-- entrance), v across. "Depth" d is measured in from the arena's near
-- edge (the entrance space's inner edge, scene.nearEdge) towards the far
-- end. A prop is TCAuctionScene's { kind, x, z, yaw, width, length }.
-- Tested in tests/test_showScene.lua; TCAuctionProps loads the models.

TCShowScene = {}

-- The show's dressing (a scene's dressing: the show's KIND).
TCShowScene.DRESSING = "show"

-- Metres.
TCShowScene.EDGE = 1.5               -- kept clear of the showground's sides
TCShowScene.PANEL = 3                -- one hurdle (the model's panel length)
TCShowScene.RING = { start = 13, length = 36, width = 24, gatePanels = 1 }
TCShowScene.PENS = { size = 3, maxCount = 8 }
TCShowScene.STANDS = { spacing = 7, depth = 3.2, maxCount = 5 }
TCShowScene.TRAILER_LINES = { gap = 8, bayWidth = 5, bayLength = 16, maxBays = 8 }
TCShowScene.LANE_CLEARANCE = 1       -- a lane's edge from the hurdles and stands
TCShowScene.RINGSIDE = { spacing = 2.5, standoff = 1.0, share = 0.6 }

-- The sizes the show's props take on the ground (as TCAuctionScene.SIZES).
TCShowScene.SIZES = {
    hurdle = { width = 0.15, length = 3 },
    hurdlePost = { width = 0.15, length = 0.15 },
    stand = { width = 3.2, length = 3.2 },
    cone = { width = 0.4, length = 0.4 },
}

-- Standing spot categories (as TCAuctionScene.SPOT).
TCShowScene.SPOT = {
    RING = "ring",
    STAND = "stand",
}

function TCShowScene.isShowDressing(scene)
    return scene ~= nil and scene.dressing == TCShowScene.DRESSING
end

-- Geometry ---------------------------------------------------------------------------------

local function toWorld(scene, u, v)
    local cosA, sinA = math.cos(scene.angle), math.sin(scene.angle)
    return scene.cx + u * cosA - v * sinA, scene.cz + u * sinA + v * cosA
end

local function yawOf(scene, du, dv)
    local cosA, sinA = math.cos(scene.angle), math.sin(scene.angle)
    return math.atan2(du * cosA - dv * sinA, du * sinA + dv * cosA)
end

-- The arena's frame: u at depth d, the way in along u, its depth and half
-- width.
local function frameOf(scene)
    local inSign = -scene.nearSign
    return {
        inSign = inSign,
        depth = math.abs(scene.farEdge - scene.nearEdge),
        halfV = scene.halfV,
        uAt = function(d)
            return scene.nearEdge + inSign * d
        end,
    }
end

-- Where everything goes (pure), in depth d and across v: {
--   ring = { dFrom, dTo, vFrom, vTo },
--   pens = { dFrom, vFrom, vTo, count, size } or nil,
--   stands = { { d, v } },
--   lines = { dFrom, dTo, vFrom, bayWidth, count } or nil,
--   lanes = { { v, halfWidth } } (along d, the ring's sides),
--   crossD, crossHalf (the aisle between the ring and the lines),
-- }, or nil when the arena's too small for the ring.
function TCShowScene.getAreas(scene)
    if scene == nil or scene.nearEdge == nil or scene.farEdge == nil or scene.halfV == nil then
        return nil
    end
    local frame = frameOf(scene)
    local R = TCShowScene.RING
    local edge = TCShowScene.EDGE
    local halfV = frame.halfV
    if frame.depth < R.start + R.length + 2 or halfV - edge < R.width * 0.5 + 2 then
        return nil
    end
    local areas = {
        ring = { dFrom = R.start, dTo = R.start + R.length, vFrom = -R.width * 0.5, vTo = R.width * 0.5 },
        stands = {},
        lanes = {},
    }
    local ring = areas.ring
    local aisleHalf = (scene.aisleWidth or 10) * 0.5
    local clearance = TCShowScene.LANE_CLEARANCE

    -- The pens: along the -v side, out to the edge.
    local P = TCShowScene.PENS
    local penCount = math.min(P.maxCount, math.floor(R.length / P.size))
    local penInner = -halfV + edge + P.size
    local penRoom = ring.vFrom - penInner
    local leftInner = -halfV + edge
    if penCount >= 1 and penRoom >= 2 * clearance + 2 then
        areas.pens = { dFrom = ring.dFrom, vFrom = -halfV + edge, vTo = penInner, count = penCount, size = P.size }
        leftInner = penInner
    end

    -- The stands: along the +v side.
    local S = TCShowScene.STANDS
    local standInner = halfV - edge - S.depth
    local rightInner = halfV - edge
    if standInner - ring.vTo >= 2 * clearance + 2 then
        local count = math.min(S.maxCount, math.floor(R.length / S.spacing))
        for i = 1, count do
            table.insert(areas.stands, { d = ring.dFrom + (i - 0.5) * S.spacing, v = halfV - edge - S.depth * 0.5 })
        end
        rightInner = standInner
    end

    -- A lane down each side of the ring, as wide as there's room for.
    for _, side in ipairs({ { leftInner, ring.vFrom }, { ring.vTo, rightInner } }) do
        local from, to = math.min(side[1], side[2]), math.max(side[1], side[2])
        local half = math.min(aisleHalf, (to - from) * 0.5 - clearance)
        if half >= 1 then
            table.insert(areas.lanes, { v = (from + to) * 0.5, halfWidth = half })
        end
    end

    -- The trailer lines past the ring, with a cross aisle between.
    local L = TCShowScene.TRAILER_LINES
    local linesFrom = ring.dTo + L.gap
    areas.crossD = ring.dTo + L.gap * 0.5
    areas.crossHalf = math.min(aisleHalf, L.gap * 0.5 - clearance)
    local bays = math.min(L.maxBays, math.floor((2 * (halfV - edge)) / L.bayWidth))
    if linesFrom + L.bayLength <= frame.depth and bays >= 1 then
        areas.lines = { dFrom = linesFrom, dTo = linesFrom + L.bayLength, vFrom = -bays * L.bayWidth * 0.5,
            bayWidth = L.bayWidth, count = bays }
    end
    return areas
end

-- The trailer line bay (1 to count, across v) a world point is in, or nil
-- outside the lines (166: a trailer's root node).
function TCShowScene.findBay(scene, x, z)
    local areas = TCShowScene.getAreas(scene)
    local lines = areas ~= nil and areas.lines or nil
    if lines == nil then
        return nil
    end
    local cosA, sinA = math.cos(scene.angle), math.sin(scene.angle)
    local dx, dz = x - scene.cx, z - scene.cz
    local u, v = dx * cosA + dz * sinA, -dx * sinA + dz * cosA
    local d = (u - scene.nearEdge) * frameOf(scene).inSign
    if d < lines.dFrom or d > lines.dTo then
        return nil
    end
    local bay = math.floor((v - lines.vFrom) / lines.bayWidth) + 1
    if bay < 1 or bay > lines.count then
        return nil
    end
    return bay
end

-- The crowd's walks on the showground (pure): the lanes beside the ring,
-- from the near cross aisle to the aisle past the ring, and that aisle
-- across. Returns walkways { x1, z1, x2, z2, halfWidth } (TCAuctionScene.
-- getWalks trims each one's far end by half the end aisle, so they're
-- drawn that much longer).
function TCShowScene.getWalkways(scene)
    local walkways = {}
    local areas = TCShowScene.getAreas(scene)
    if areas == nil then
        return walkways
    end
    local frame = frameOf(scene)
    local trim = (scene.endAisle or 0) * 0.5
    local aisleHalf = (scene.aisleWidth or 10) * 0.5
    local function add(u1, v1, u2, v2, halfWidth)
        local x1, z1 = toWorld(scene, u1, v1)
        local x2, z2 = toWorld(scene, u2, v2)
        table.insert(walkways, { x1 = x1, z1 = z1, x2 = x2, z2 = z2, halfWidth = halfWidth })
    end
    for _, lane in ipairs(areas.lanes) do
        add(frame.uAt(-aisleHalf), lane.v, frame.uAt(areas.crossD + trim), lane.v, lane.halfWidth)
    end
    if areas.crossHalf >= 1 then
        local reach = frame.halfV - TCShowScene.EDGE
        add(frame.uAt(areas.crossD), -reach, frame.uAt(areas.crossD), reach + trim, areas.crossHalf)
    end
    return walkways
end

-- Lays the arena out (pure). Returns { props, spots, sounds }, empty for a
-- scene that isn't the show's.
function TCShowScene.layOut(scene)
    local result = { props = {}, spots = {}, sounds = {} }
    if not TCShowScene.isShowDressing(scene) then
        return result
    end
    local areas = TCShowScene.getAreas(scene)
    if areas == nil then
        return result
    end
    local frame = frameOf(scene)
    local seed = scene.seed or 0
    local panel = TCShowScene.PANEL
    local groupCount = 1000

    local function add(kind, d, v, yaw, extra)
        local size = TCShowScene.SIZES[kind]
        local x, z = toWorld(scene, frame.uAt(d), v)
        local prop = { kind = kind, x = x, z = z, yaw = yaw, width = size.width, length = size.length }
        for key, value in pairs(extra or {}) do
            prop[key] = value
        end
        table.insert(result.props, prop)
        return prop
    end

    -- A run of hurdles from (d1, v1) to (d2, v2), a whole number of panels
    -- (the run's length over PANEL, rounded down), with a post at each
    -- joint and both ends. skip(i): leave panel i out (a gateway).
    local function run(d1, v1, d2, v2, skip)
        local dd, dv = d2 - d1, v2 - v1
        local length = math.sqrt(dd * dd + dv * dv)
        local count = math.floor(length / panel + 0.001)
        if count < 1 then
            return
        end
        local stepD, stepV = dd / length * panel, dv / length * panel
        local yaw = yawOf(scene, frame.inSign * dd, dv)
        for i = 1, count do
            local startD, startV = d1 + stepD * (i - 1), v1 + stepV * (i - 1)
            if skip == nil or not skip(i, count) then
                add("hurdle", startD + stepD * 0.5, startV + stepV * 0.5, yaw)
            end
            add("hurdlePost", startD, startV, yaw)
        end
        add("hurdlePost", d1 + stepD * count, v1 + stepV * count, yaw)
    end

    -- The ring, its near side with a gateway in the middle.
    local ring = areas.ring
    local gatePanels = TCShowScene.RING.gatePanels
    run(ring.dFrom, ring.vFrom, ring.dFrom, ring.vTo, function(i, count)
        local first = math.floor((count - gatePanels) / 2) + 1
        return i >= first and i < first + gatePanels
    end)
    run(ring.dFrom, ring.vTo, ring.dTo, ring.vTo)
    run(ring.dTo, ring.vTo, ring.dTo, ring.vFrom)
    run(ring.dTo, ring.vFrom, ring.dFrom, ring.vFrom)

    -- The pens: back and front walls the row's length (a pen's front is
    -- one hurdle, its gate), and a divider across between each pen and at
    -- both ends.
    local pens = areas.pens
    if pens ~= nil then
        local size = pens.size
        local dTo = pens.dFrom + pens.count * size
        run(pens.dFrom, pens.vFrom, dTo, pens.vFrom)
        run(pens.dFrom, pens.vTo, dTo, pens.vTo)
        for i = 0, pens.count do
            local d = pens.dFrom + i * size
            run(d, pens.vFrom, d, pens.vTo)
        end
    end

    -- The stands, facing the lane, a couple of people at each.
    for i, stand in ipairs(areas.stands) do
        add("stand", stand.d, stand.v, yawOf(scene, 0, -1))
        groupCount = groupCount + 1
        local front = stand.v - TCShowScene.STANDS.depth * 0.5 - 1.2
        for p = 1, 2 do
            local offset = (p - 1.5) * 1.4 + (TCAuctionScene.hash(seed, 50, i, p) - 0.5) * 0.4
            local x, z = toWorld(scene, frame.uAt(stand.d + offset), front)
            table.insert(result.spots, { x = x, z = z, yaw = yawOf(scene, 0, 1), category = TCShowScene.SPOT.STAND,
                group = groupCount })
        end
    end

    -- The trailer lines: a cone at each end of every line between bays.
    local lines = areas.lines
    if lines ~= nil then
        for i = 0, lines.count do
            local v = lines.vFrom + i * lines.bayWidth
            add("cone", lines.dFrom, v, 0)
            add("cone", lines.dTo, v, 0)
        end
    end

    -- Ringside: people along the ring's long sides, facing in.
    local R = TCShowScene.RINGSIDE
    for sideIndex, side in ipairs({ { v = ring.vFrom - R.standoff, face = 1 }, { v = ring.vTo + R.standoff, face = -1 } }) do
        local count = math.floor((ring.dTo - ring.dFrom) / R.spacing)
        for k = 1, count do
            if TCAuctionScene.hash(seed, 60 + sideIndex, k) < R.share then
                groupCount = groupCount + 1
                local x, z = toWorld(scene, frame.uAt(ring.dFrom + (k - 0.5) * R.spacing), side.v)
                table.insert(result.spots, { x = x, z = z, yaw = yawOf(scene, 0, side.face),
                    category = TCShowScene.SPOT.RING, group = groupCount })
            end
        end
    end

    -- The murmur, from the ring.
    local mx, mz = toWorld(scene, frame.uAt((ring.dFrom + ring.dTo) * 0.5), 0)
    table.insert(result.sounds, { x = mx, z = mz })
    return result
end
