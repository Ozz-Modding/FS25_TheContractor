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
--   The stands: gazebos along the other side (v > 0), a couple of people
--     at each. 171: two of them are stalls (getStallStands: the trade
--     association's and the careers stand), each with a table at its front
--     and a stallholder behind it (layOut's stalls), the visitors stood
--     wider so a player can reach the table.
--   171's farmers' spots (layOut's mingles): the ringside places the
--     spectators didn't take, where farmers at the show stand.
--   The trailer lines: bays across the far end, past the ring, marked out
--     with cones, where entrants park their livestock trailers (167). 173:
--     the breeder's trailers take the bays at the stands' end
--     (getBreederBays), the breeder the last stand that isn't a stall
--     (getBreederStand).
--   The crowd's walks (getWalkways): a lane down each side of the ring
--     (between it and the pens, and it and the stands) and a cross aisle
--     between the ring and the trailer lines; TCAuctionScene.getWalks adds
--     the near and far cross aisles as it does for any site.
--   The ploughing plots (169, getPlotFrames): 164's plots kept on the scene
--     (scene.plots), each facing across its row, away from the showground,
--     so its near edge is the one the crowd's side, with a peg at each
--     corner and a start peg just outside its near edge, left of the
--     middle (where a player takes the plot).
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
    plotPeg = { width = 0.4, length = 0.4 },
    plotStartPeg = { width = 0.4, length = 0.4 },
    standTable = { width = 0.9, length = 2 },
}

-- 171: a stall, in from its gazebo's front edge (metres): the table and,
-- behind it, the stallholder. Its visitors stand this much further apart
-- than at another stand, so there's room at the table.
TCShowScene.STALL = { tableIn = 0.5, holderIn = 1.3, visitorSpread = 2.3 }
-- The stalls, in the order they're given stands.
TCShowScene.STALL_ROLES = { "association", "careers" }

-- 169: in a plot's own frame (u in from its near edge, v to its right),
-- metres: its start peg (outside the near edge, left of the middle).
TCShowScene.PLOT = { startPegU = -1.5, startPegV = -4 }

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

-- The ploughing plots (169) ------------------------------------------------------------------

-- A point in a plot's frame (u in from its near edge, v to its right) in
-- the world (TCPloughScore.toWorld's frame).
function TCShowScene.plotToWorld(frame, u, v)
    return frame.x + u * frame.dirX + v * frame.dirZ, frame.z + u * frame.dirZ - v * frame.dirX
end

-- Each of the scene's plots as a frame (pure), numbered in the scene's
-- order: { number, x, z (its near edge's middle), dirX, dirZ (facing in),
-- size, cx, cz (its middle) }. Every plot faces the same way: across their
-- row, away from the showground's middle (the scene's). Empty for a scene
-- with none.
function TCShowScene.getPlotFrames(scene)
    local plots = scene ~= nil and scene.plots or nil
    local frames = {}
    if plots == nil or #plots == 0 then
        return frames
    end
    local first, last = plots[1], plots[#plots]
    local ax, az = last.cx - first.cx, last.cz - first.cz
    local length = math.sqrt(ax * ax + az * az)
    if length < 0.001 then
        ax, az = math.cos(first.angle or 0), math.sin(first.angle or 0)
    else
        ax, az = ax / length, az / length
    end
    -- Across the row, away from the showground.
    local fx, fz = -az, ax
    local mx, mz = 0, 0
    for _, plot in ipairs(plots) do
        mx, mz = mx + plot.cx, mz + plot.cz
    end
    mx, mz = mx / #plots, mz / #plots
    if (mx - (scene.cx or 0)) * fx + (mz - (scene.cz or 0)) * fz < 0 then
        fx, fz = -fx, -fz
    end
    for i, plot in ipairs(plots) do
        local half = plot.half or 0
        table.insert(frames, {
            number = i,
            x = plot.cx - fx * half,
            z = plot.cz - fz * half,
            dirX = fx,
            dirZ = fz,
            size = 2 * half,
            cx = plot.cx,
            cz = plot.cz,
        })
    end
    return frames
end

-- A plot's start peg in the world (pure).
function TCShowScene.getStartPeg(frame)
    return TCShowScene.plotToWorld(frame, TCShowScene.PLOT.startPegU, TCShowScene.PLOT.startPegV)
end

-- The plots' pegs (pure): one at each corner, and the start peg, facing
-- in. Added to result.props.
function TCShowScene.layOutPlots(scene, result)
    for _, frame in ipairs(TCShowScene.getPlotFrames(scene)) do
        local yaw = math.atan2(frame.dirX, frame.dirZ)
        local half = frame.size * 0.5
        for _, corner in ipairs({ { 0, -half }, { frame.size, -half }, { frame.size, half }, { 0, half } }) do
            local x, z = TCShowScene.plotToWorld(frame, corner[1], corner[2])
            local size = TCShowScene.SIZES.plotPeg
            table.insert(result.props, { kind = "plotPeg", x = x, z = z, yaw = yaw, width = size.width,
                length = size.length, plot = frame.number })
        end
        local x, z = TCShowScene.getStartPeg(frame)
        local size = TCShowScene.SIZES.plotStartPeg
        table.insert(result.props, { kind = "plotStartPeg", x = x, z = z, yaw = yaw, width = size.width,
            length = size.length, plot = frame.number })
    end
end

-- 171: which of count stands (by their index along the row) are stalls
-- (pure): role -> index. The second and fourth of four or more, so they're
-- spread down the row, else the first ones; a role with no stand left is
-- missing.
function TCShowScene.getStallStands(count)
    local indices = count >= 4 and { 2, 4 } or { 1, 2 }
    local stalls = {}
    for i, role in ipairs(TCShowScene.STALL_ROLES) do
        local index = indices[i]
        if index ~= nil and index <= count then
            stalls[role] = index
        end
    end
    return stalls
end

-- 173: the breeder's stand (pure): the last stand along the row that isn't
-- a stall, where the breeder stands at its front as a stallholder does
-- (with no table): { x, z, yaw, d, index }, or nil with no stand left.
function TCShowScene.getBreederStand(scene)
    if not TCShowScene.isShowDressing(scene) then
        return nil
    end
    local areas = TCShowScene.getAreas(scene)
    if areas == nil or #areas.stands == 0 then
        return nil
    end
    local taken = {}
    for _, index in pairs(TCShowScene.getStallStands(#areas.stands)) do
        taken[index] = true
    end
    for index = #areas.stands, 1, -1 do
        if not taken[index] then
            local stand = areas.stands[index]
            local frame = frameOf(scene)
            local frontEdge = stand.v - TCShowScene.STANDS.depth * 0.5
            local x, z = toWorld(scene, frame.uAt(stand.d), frontEdge + TCShowScene.STALL.holderIn)
            return { x = x, z = z, yaw = yawOf(scene, 0, -1), d = stand.d, index = index }
        end
    end
    return nil
end

-- 173: where the breeder's trailers park (pure): the trailer line bays from
-- the stands' end of the lines, one a trailer, always leaving one for the
-- entrants. { { x, z, yaw (facing the far end, its ramp to the ring), bay } },
-- as many as there's room for up to count.
function TCShowScene.getBreederBays(scene, count)
    local bays = {}
    local areas = TCShowScene.isShowDressing(scene) and TCShowScene.getAreas(scene) or nil
    local lines = areas ~= nil and areas.lines or nil
    if lines == nil then
        return bays
    end
    local frame = frameOf(scene)
    local d = (lines.dFrom + lines.dTo) * 0.5
    for k = 1, math.min(count or 0, lines.count - 1) do
        local bay = lines.count - k + 1
        local x, z = toWorld(scene, frame.uAt(d), lines.vFrom + (bay - 0.5) * lines.bayWidth)
        table.insert(bays, { x = x, z = z, yaw = yawOf(scene, frame.inSign, 0), bay = bay })
    end
    return bays
end

-- Lays the arena out (pure). Returns { props, spots, sounds, stalls,
-- mingles }, empty for a scene that isn't the show's. 171: stalls { role,
-- x, z, yaw (the stallholder, facing the lane) }, mingles { x, z, yaw }
-- (farmers' spots, kept off the crowd's).
function TCShowScene.layOut(scene)
    local result = { props = {}, spots = {}, sounds = {}, stalls = {}, mingles = {} }
    if not TCShowScene.isShowDressing(scene) then
        return result
    end
    -- 169: the plots are on the ploughing ground, whatever the arena's room.
    TCShowScene.layOutPlots(scene, result)
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

    -- The stands, facing the lane, a couple of people at each. 171: a
    -- stall has a table at its front and a stallholder behind it.
    local stallIndices = {}
    for role, index in pairs(TCShowScene.getStallStands(#areas.stands)) do
        stallIndices[index] = role
    end
    local S = TCShowScene.STALL
    for i, stand in ipairs(areas.stands) do
        local facing = yawOf(scene, 0, -1)
        add("stand", stand.d, stand.v, facing)
        local frontEdge = stand.v - TCShowScene.STANDS.depth * 0.5
        local role = stallIndices[i]
        if role ~= nil then
            add("standTable", stand.d, frontEdge + S.tableIn, facing, { stall = role })
            local x, z = toWorld(scene, frame.uAt(stand.d), frontEdge + S.holderIn)
            table.insert(result.stalls, { role = role, x = x, z = z, yaw = facing })
        end
        groupCount = groupCount + 1
        local front = frontEdge - 1.2
        local spread = role ~= nil and S.visitorSpread or 1.4
        for p = 1, 2 do
            local offset = (p - 1.5) * spread + (TCAuctionScene.hash(seed, 50, i, p) - 0.5) * 0.4
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
            local x, z = toWorld(scene, frame.uAt(ring.dFrom + (k - 0.5) * R.spacing), side.v)
            if TCAuctionScene.hash(seed, 60 + sideIndex, k) < R.share then
                groupCount = groupCount + 1
                table.insert(result.spots, { x = x, z = z, yaw = yawOf(scene, 0, side.face),
                    category = TCShowScene.SPOT.RING, group = groupCount })
            else
                -- 171: a place the spectators left, for a farmer.
                table.insert(result.mingles, { x = x, z = z, yaw = yawOf(scene, 0, side.face) })
            end
        end
    end

    -- The murmur, from the ring.
    local mx, mz = toWorld(scene, frame.uAt((ring.dFrom + ring.dTo) * 0.5), 0)
    table.insert(result.sounds, { x = mx, z = mz })
    return result
end
