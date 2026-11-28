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
--     the ring, for the livestock classes (167), and a second row behind it
--     when the scene asks for more than one row holds (182, getPens). 182:
--     an animal a pen (TCShowPens; 188: other farmers' single animals,
--     never a player's), shown there with its rosettes (layOutPens).
--   The stands: gazebos along the other side (v > 0), a couple of people
--     at each. 171: two of them are stalls (getStallStands: the trade
--     association's and the careers stand), each with a table at its front
--     and a stallholder behind it (layOut's stalls), the visitors stood
--     wider so a player can reach the table.
--   171's farmers' spots (layOut's mingles): the ringside places the
--     spectators didn't take, where farmers at the show stand.
--   The trailer lines: bays across the far end, past the ring, marked out
--     with cones, where entrants park their livestock trailers (167).
--   188's breeders' pens (getAreas' breeders, getBreederPens): a group pen
--     each, sized for its breeder's stock (scene.breeders), their trailer
--     behind it, in strips: along each side past the small pens and the
--     stands, and across the far end past the trailer lines, a lane in
--     front of each strip. As many as there's room for, in the scene's
--     order; the rest have none. The animals in their places in the pen
--     (getBreederAnimalSpots), hurdles round it, straw under it, a bale in
--     a corner, a couple of the crowd at its front.
--   188's ring: the class being judged in a line along it (getRingLine),
--     the judge walking the line (getJudgeSpot).
--   The crowd's walks (getWalkways): a lane down each side of the ring
--     (between it and the pens, and it and the stands) and a cross aisle
--     between the ring and the trailer lines; TCAuctionScene.getWalks adds
--     the near and far cross aisles as it does for any site.
--   The ploughing plots (169, getPlotFrames): 164's plots kept on the scene
--     (scene.plots), each facing across its row, away from the showground,
--     so its near edge is the one the crowd's side, with a peg at each
--     corner and a start peg just outside its near edge, left of the
--     middle (where a player takes the plot).
--   182's straw (layOutStraw): a bed under each row of pens, over the
--     bare ground round them (getPenGround), in tiles, and a straw bale in
--     a corner of each pen (layOutPenBales).
--   182's animals and rosettes in the pens (layOutPens): not in layOut,
--     since they come and go through the day (an animal in its pen while the
--     gates are open, a rosette once it's judged): TCAuctionProps
--     lays them out from ShowLivestock's synced pens as late props. 188: the
--     breeders' animals and rosettes and the class in the ring the same way
--     (ShowLivestock:getDisplay).
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
-- The pens (182): as many as the scene asks for (scene.pens, the show's:
-- one an animal, ShowLivestock's), else `default`; a row holds perRow (or
-- as many as the ring's length takes), and past that a second row stands
-- back to back behind it, its fronts facing out, if there's room.
-- A pen is one penHurdle a side (4 m: room for a cow, the user's call).
TCShowScene.PENS = { size = 4, default = 8, perRow = 12 }
-- 182: the bare ground under the pens (getPenGround) reaches this far past
-- their hurdles (metres), trodden round them.
TCShowScene.PEN_GROUND_MARGIN = 0.75
-- 182: the straw bed under each row of pens (layOutStraw): margin past the
-- hurdles (a little past the bare ground, so its ragged edge runs onto the
-- grass), and the tile's size (genShowPropsI3d.py's STRAW: each tile is
-- scaled a little to fit the bed exactly). Metres.
TCShowScene.STRAW = { margin = 1.0, tile = 2.75 }
-- 182: a straw bale in a corner of each pen (layOutPenBales), the
-- entrance's bale (TCAuctionScene's, its footprint: 1.2 m across its yaw).
-- Metres: in from the hurdles (clear of their feet), and the most it's
-- skewed (radians), so they don't all sit square.
TCShowScene.PEN_BALE = { width = 1.2, length = 0.5, inset = 0.3, skew = 0.05 }
-- 182: the stacks of bales at each end of each row of pens (layOutPenBales):
-- two side by side across the row's end, each 2 or 3 high, this far out
-- from the end hurdle (to the bale's middle, on the straw), this far apart
-- (middle to middle), each bale skewed up to `skew`.
TCShowScene.PEN_END_STACKS = { out = 0.65, apart = 1.35, minLevels = 2, maxLevels = 3, skew = 0.12 }
-- A straw tile's faded sides (TCAuctionProps' setUp shows the model's
-- child numbered by their sum): its own -x, +x, -z, +z.
TCShowScene.STRAW_FADE = { minusX = 1, plusX = 2, minusZ = 4, plusZ = 8 }
-- 188: the breeders' pens (getAreas' breeders), each a group pen of its
-- breeder's stock with their trailer parked behind it, in strips: along
-- each side of the ring past the small pens and the stands, and across
-- the far end past the trailer lines, a crowd's lane in front of each.
-- Metres: lane (in front of a strip), gap (between pens along a strip),
-- trailerGap (a pen's back to its trailer's side), trailerLength and
-- trailerWidth (the room a trailer's given behind its pen), holderOut (the
-- breeder, out from the front) and holderAlong (along it, a share of its
-- length), inset (the animals' places in from the hurdles), visitorsOut
-- (the crowd's spots out from a pen's front), maxStrips (a side's at most).
TCShowScene.BREEDERS = { lane = 6, gap = 2, trailerGap = 1.5, trailerLength = 12, trailerWidth = 3.6,
    holderOut = 1.2, holderAlong = 0.25, inset = 0.5, visitorsOut = 2, maxStrips = 3 }
-- 188: the room an animal's given in a breeder's pen (a square, metres),
-- by type; any other type DEFAULT_ANIMAL_CELL's.
TCShowScene.ANIMAL_CELL = { COW = 3.0, HORSE = 3.2, SHEEP = 1.8, GOAT = 1.8, PIG = 2.0 }
TCShowScene.DEFAULT_ANIMAL_CELL = 2.4
-- 188: the most an animal in a breeder's pen is turned from facing out
-- (radians, either way).
TCShowScene.ANIMAL_TURN = 0.6
-- 188: the class in the ring (getRingLine): a line of animals along the
-- ring, `v` across it (a second line at secondV past perLine), spacing
-- apart, margin in from its ends, all facing -v; the judge walks the line
-- at judgeV and stands back at judgeBackV to place them. Metres.
TCShowScene.RING_LINE = { spacing = 3, margin = 4, v = 2, secondV = 5.5, judgeV = -1.5, judgeBackV = -4 }
TCShowScene.STANDS = { spacing = 7, depth = 3.2, maxCount = 5 }
TCShowScene.TRAILER_LINES = { gap = 8, bayWidth = 5, bayLength = 16, maxBays = 8 }
TCShowScene.LANE_CLEARANCE = 1       -- a lane's edge from the hurdles and stands
TCShowScene.RINGSIDE = { spacing = 2.5, standoff = 1.0, share = 0.6 }

-- The sizes the show's props take on the ground (as TCAuctionScene.SIZES).
TCShowScene.SIZES = {
    hurdle = { width = 0.5, length = 3 },  -- its feet across
    penHurdle = { width = 0.5, length = 4 },  -- 182: a pen's
    stand = { width = 3.2, length = 3.2 },
    cone = { width = 0.4, length = 0.4 },
    plotPeg = { width = 0.4, length = 0.4 },
    plotStartPeg = { width = 0.4, length = 0.4 },
    standTable = { width = 0.9, length = 2 },
    -- 182: an animal in its pen (its footprint for the ground under it).
    penAnimal = { width = 1, length = 2.2 },
}

-- 171: a stall, in from its gazebo's front edge (metres): the table and,
-- behind it, the stallholder. Its visitors stand this much further apart
-- than at another stand, so there's room at the table.
TCShowScene.STALL = { tableIn = 0.5, holderIn = 1.3, visitorSpread = 2.3 }
-- The stalls, in the order they're given stands.
TCShowScene.STALL_ROLES = { "association", "careers" }

-- 182: the rosettes on the pens' front hurdles, once judged (layOutPens). Metres: apart along the hurdle. A placing's
-- colour (TCAuctionProps.ROSETTE_FACES: the model's child shown); a
-- supreme champion's is CHAMPION.
TCShowScene.ROSETTE = { spacing = 0.6 }
TCShowScene.ROSETTE_COLOURS = { "first", "second", "third", "commended" }
TCShowScene.ROSETTE_CHAMPION = "champion"

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

-- 188: a breeder's pen's size in metres: { length (along its front),
-- depth, unitLength (along its strip, room for its trailer too),
-- unitDepth (from its front to its trailer's far side) }.
function TCShowScene.getBreederUnitSize(entry)
    local B = TCShowScene.BREEDERS
    local size = TCShowScene.PENS.size
    local length, depth = (entry.length or 2) * size, (entry.depth or 2) * size
    local unitLength, unitDepth = length, depth
    if entry.trailer then
        unitLength = math.max(length, B.trailerLength)
        unitDepth = depth + B.trailerGap + B.trailerWidth
    end
    return { length = length, depth = depth, unitLength = unitLength, unitDepth = unitDepth }
end

-- 188: the breeders' strips and their pens (pure, part of getAreas). The
-- strips: along each side of the ring (side -1 the pens' side, 1 the
-- stands'), the first just past what's beside the ring there (a lane
-- between, or the ring's own lane with nothing there), each further one a
-- lane further out; and across the far end past the trailer lines (side
-- 0). All as deep as the deepest pen. They're filled in tiers (both sides'
-- first strips, then the far end's first, then the sides' second, ...), a
-- breeder taking the tier's strip with the most room left that takes its
-- pen, in the scene's order; one with room nowhere isn't placed. Returns
-- units (a breeder's index -> { index, strip, side, pen = { dFrom, dTo,
-- vFrom, vTo }, facing = { d, v } (out of its front), front (d or v of its
-- front), alongD (its front runs along d), trailer = { d, v } or nil,
-- holder = { d, v }, size (getBreederUnitSize) }) and the strips used ({
-- side, front, back, from, to, laneD or laneV, ownLane }).
local function placeBreeders(scene, frame, areas, leftOuter, rightOuter, laneRoom)
    local breeders = scene.breeders
    if breeders == nil or #breeders == 0 then
        return {}, {}
    end
    local B = TCShowScene.BREEDERS
    local edge = TCShowScene.EDGE
    local minV, maxV = -frame.halfV + edge, frame.halfV - edge
    local ring = areas.ring
    local depth = 0
    local sizes = {}
    for i, entry in ipairs(breeders) do
        sizes[i] = TCShowScene.getBreederUnitSize(entry)
        depth = math.max(depth, sizes[i].unitDepth)
    end
    local lines = areas.lines
    local sideEnd = lines ~= nil and lines.dTo or frame.depth - 1
    -- A side's strip stops either side of the cross aisle past the ring,
    -- which runs on out to the showground's edges.
    local clearance = TCShowScene.LANE_CLEARANCE
    local crossFrom = areas.crossD - areas.crossHalf - clearance
    local crossTo = areas.crossD + areas.crossHalf + clearance
    local strips = {}
    local function addSide(side, firstFront, ownFirst)
        local front, own = firstFront, ownFirst
        for k = 1, B.maxStrips do
            -- side -1 faces +v (its back further -v); side 1 faces -v.
            local back = side < 0 and front - depth or front + depth
            if back < minV - 0.001 or back > maxV + 0.001 then
                break
            end
            for _, segment in ipairs({ { ring.dFrom, math.min(sideEnd, crossFrom) }, { crossTo, sideEnd } }) do
                if segment[2] > segment[1] then
                    table.insert(strips, { side = side, front = front, back = back, from = segment[1],
                        to = segment[2], used = 0, tier = 2 * k - 1, ownLane = own, order = #strips + 1 })
                end
            end
            front = side < 0 and back - B.lane or back + B.lane
            own = true
        end
    end
    if leftOuter ~= nil then
        addSide(-1, leftOuter - B.lane, true)
    else
        addSide(-1, ring.vFrom - laneRoom, false)
    end
    if rightOuter ~= nil then
        addSide(1, rightOuter + B.lane, true)
    else
        addSide(1, ring.vTo + laneRoom, false)
    end
    if lines ~= nil then
        local front = lines.dTo + B.lane
        for k = 1, B.maxStrips do
            local back = front + depth
            if back > frame.depth + 0.001 then
                break
            end
            table.insert(strips, { side = 0, front = front, back = back, from = minV, to = maxV, used = 0,
                tier = 2 * k, ownLane = true, order = #strips + 1 })
            front = back + B.lane
        end
    end
    table.sort(strips, function(a, b)
        if a.tier ~= b.tier then
            return a.tier < b.tier
        end
        return a.order < b.order
    end)

    local units = {}
    for index, entry in ipairs(breeders) do
        local size = sizes[index]
        local best, bestStart = nil, nil
        local tier = nil
        for _, strip in ipairs(strips) do
            if tier ~= nil and strip.tier ~= tier then
                break
            end
            local start = strip.from + strip.used + (strip.used > 0 and B.gap or 0)
            if start + size.unitLength <= strip.to + 0.001 then
                local left = strip.to - start
                if best == nil or left > best.to - bestStart + 0.001 then
                    best, bestStart = strip, start
                end
                tier = strip.tier
            end
        end
        if best ~= nil then
            best.used = bestStart + size.unitLength - best.from
            best.hasUnits = true
            local unit = { index = index, strip = best, side = best.side, size = size, front = best.front }
            local penFrom = bestStart + (size.unitLength - size.length) * 0.5
            local middle = bestStart + size.unitLength * 0.5
            local holderAlong = penFrom + size.length * B.holderAlong
            local trailerOff = size.depth + B.trailerGap + B.trailerWidth * 0.5
            if best.side ~= 0 then
                local out = -best.side
                unit.alongD = true
                unit.facing = { d = 0, v = out }
                unit.pen = { dFrom = penFrom, dTo = penFrom + size.length,
                    vFrom = out > 0 and best.front - size.depth or best.front,
                    vTo = out > 0 and best.front or best.front + size.depth }
                unit.holder = { d = holderAlong, v = best.front + out * B.holderOut }
                if entry.trailer then
                    unit.trailer = { d = middle, v = best.front - out * trailerOff }
                end
            else
                unit.alongD = false
                unit.facing = { d = -1, v = 0 }
                unit.pen = { dFrom = best.front, dTo = best.front + size.depth, vFrom = penFrom,
                    vTo = penFrom + size.length }
                unit.holder = { d = best.front - B.holderOut, v = holderAlong }
                if entry.trailer then
                    unit.trailer = { d = best.front + trailerOff, v = middle }
                end
            end
            units[index] = unit
        end
    end
    local used = {}
    for _, strip in ipairs(strips) do
        if strip.hasUnits then
            if strip.side ~= 0 then
                strip.laneV = strip.front - strip.side * B.lane * 0.5
            else
                strip.laneD = strip.front - B.lane * 0.5
            end
            table.insert(used, strip)
        end
    end
    return units, used
end

-- Where everything goes (pure), in depth d and across v: {
--   ring = { dFrom, dTo, vFrom, vTo },
--   pens = { dFrom, vFrom, vTo, count, size, back = { vFrom, vTo, count } or
--     nil (182's second row, behind the first) } or nil,
--   stands = { { d, v } },
--   lines = { dFrom, dTo, vFrom, bayWidth, count } or nil,
--   lanes = { { v, halfWidth } } (along d, the ring's sides),
--   crossD, crossHalf (the aisle between the ring and the lines),
--   breeders = { [index] = unit } (188: placeBreeders', a breeder of the
--     scene's with no room left out), breederStrips (the strips used),
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

    -- The pens and the stands sit just past the lane each side of the ring
    -- (182: on a wide showground, against its edges, they were a long walk
    -- from it), the spare width outside them. A narrow one holds them in
    -- from its edges, the lane taking what's left.
    local laneRoom = 2 * aisleHalf + 2 * clearance

    -- The pens: along the -v side.
    local P = TCShowScene.PENS
    local wanted = scene.pens or P.default
    local perRow = math.min(P.perRow, math.floor(R.length / P.size))
    local penCount = math.min(perRow, wanted)
    local backCount = math.min(penCount, wanted - penCount)
    local minRoom = 2 * clearance + 2
    local function rowAt(outer)
        return outer, outer + P.size, ring.vFrom - (outer + P.size)
    end
    local penOuter, penInner, penRoom = rowAt(math.max(-halfV + edge, ring.vFrom - laneRoom - P.size))
    local hasBack = false
    if backCount >= 1 then
        -- 182: a second row behind the first, both out towards the edge if
        -- that's what it takes (the lane narrower), if they fit.
        local outer, inner, room = rowAt(math.max(-halfV + edge + P.size, ring.vFrom - laneRoom - P.size))
        if room >= minRoom then
            penOuter, penInner, penRoom = outer, inner, room
            hasBack = true
        end
    end
    local leftInner = -halfV + edge
    local leftOuter = nil
    if penCount >= 1 and penRoom >= minRoom then
        areas.pens = { dFrom = ring.dFrom, vFrom = penOuter, vTo = penInner, count = penCount, size = P.size }
        leftInner = penInner
        leftOuter = penOuter
        if hasBack then
            areas.pens.back = { vFrom = penOuter - P.size, vTo = penOuter, count = backCount }
            leftOuter = penOuter - P.size
        end
    end

    -- The stands: along the +v side.
    local S = TCShowScene.STANDS
    local standInner = math.min(halfV - edge - S.depth, ring.vTo + laneRoom)
    local rightInner = halfV - edge
    local rightOuter = nil
    if standInner - ring.vTo >= 2 * clearance + 2 then
        local count = math.min(S.maxCount, math.floor(R.length / S.spacing))
        for i = 1, count do
            table.insert(areas.stands, { d = ring.dFrom + (i - 0.5) * S.spacing, v = standInner + S.depth * 0.5 })
        end
        rightInner = standInner
        rightOuter = standInner + S.depth
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

    -- 188: the breeders' pens. A side with nothing beside the ring has its
    -- first strip against the ring's lane, so the lane stops there.
    areas.breeders, areas.breederStrips = placeBreeders(scene, frame, areas, leftOuter, rightOuter, laneRoom)
    for _, strip in ipairs(areas.breederStrips) do
        if not strip.ownLane then
            if strip.side < 0 then
                leftInner = strip.front
            else
                rightInner = strip.front
            end
        end
    end

    -- A lane down each side of the ring, as wide as there's room for.
    for _, side in ipairs({ { leftInner, ring.vFrom }, { ring.vTo, rightInner } }) do
        local from, to = math.min(side[1], side[2]), math.max(side[1], side[2])
        local half = math.min(aisleHalf, (to - from) * 0.5 - clearance)
        if half >= 1 then
            table.insert(areas.lanes, { v = (from + to) * 0.5, halfWidth = half })
        end
    end
    return areas
end

-- 188: the scene's breeders' pens (pure), in the world: a list as long as
-- the scene's breeders, each { index, x, z (the pen's middle), yaw (facing
-- out of its front), placed (false: no room for it, and nothing else set),
-- holder = { x, z, yaw (facing out) }, trailer = { x, z, yaw (along its
-- strip) } or nil, length, depth (the pen's, metres) }. Empty for a scene
-- that isn't the show's.
function TCShowScene.getBreederPens(scene)
    local list = {}
    local areas = TCShowScene.isShowDressing(scene) and TCShowScene.getAreas(scene) or nil
    if areas == nil then
        return list
    end
    local frame = frameOf(scene)
    for index = 1, #(scene.breeders or {}) do
        local unit = areas.breeders[index]
        if unit == nil then
            table.insert(list, { index = index, placed = false })
        else
            local pen = unit.pen
            local x, z = toWorld(scene, frame.uAt((pen.dFrom + pen.dTo) * 0.5), (pen.vFrom + pen.vTo) * 0.5)
            local yaw = yawOf(scene, frame.inSign * unit.facing.d, unit.facing.v)
            local hx, hz = toWorld(scene, frame.uAt(unit.holder.d), unit.holder.v)
            local item = { index = index, placed = true, x = x, z = z, yaw = yaw, holder = { x = hx, z = hz, yaw = yaw },
                length = unit.size.length, depth = unit.size.depth }
            if unit.trailer ~= nil then
                local tx, tz = toWorld(scene, frame.uAt(unit.trailer.d), unit.trailer.v)
                local alongYaw = unit.alongD and yawOf(scene, frame.inSign, 0) or yawOf(scene, 0, 1)
                item.trailer = { x = tx, z = tz, yaw = alongYaw }
            end
            table.insert(list, item)
        end
    end
    return list
end

-- 188: how many of the scene's breeders have a pen (pure).
function TCShowScene.countBreederPens(scene)
    local count = 0
    for _, pen in ipairs(TCShowScene.getBreederPens(scene)) do
        if pen.placed then
            count = count + 1
        end
    end
    return count
end

-- 188: the places for a breeder's animals in their pen (pure): a grid of
-- cells (ANIMAL_CELL's for its type) inside its hurdles, one corner's left
-- for its straw bale, the rest in an order from the scene's seed, so
-- animal id n always has the nth. Returns { { x, z, yaw } } and the bale's
-- corner cell { x, z, yaw (along the front) }, or an empty list.
function TCShowScene.getBreederAnimalSpots(scene, index)
    local areas = TCShowScene.isShowDressing(scene) and TCShowScene.getAreas(scene) or nil
    local unit = areas ~= nil and areas.breeders[index] or nil
    if unit == nil then
        return {}, nil
    end
    local entry = scene.breeders[index]
    local cell = TCShowScene.ANIMAL_CELL[entry.typeName or ""] or TCShowScene.DEFAULT_ANIMAL_CELL
    local B = TCShowScene.BREEDERS
    local frame = frameOf(scene)
    local seed = scene.seed or 0
    local pen = unit.pen
    local dSpan, vSpan = pen.dTo - pen.dFrom - 2 * B.inset, pen.vTo - pen.vFrom - 2 * B.inset
    local cols, rows = math.max(1, math.floor(dSpan / cell)), math.max(1, math.floor(vSpan / cell))
    local stepD, stepV = dSpan / cols, vSpan / rows
    local cells = {}
    for i = 1, cols do
        for j = 1, rows do
            table.insert(cells, { i = i, j = j, d = pen.dFrom + B.inset + (i - 0.5) * stepD,
                v = pen.vFrom + B.inset + (j - 0.5) * stepV })
        end
    end
    -- The bale's corner: one of the four, from the seed.
    local corner = math.floor(TCAuctionScene.hash(seed, 88, index) * 4) % 4
    local baleI = (corner % 2 == 0) and 1 or cols
    local baleJ = (corner < 2) and 1 or rows
    local bale, rest = nil, {}
    local facingYaw = yawOf(scene, frame.inSign * unit.facing.d, unit.facing.v)
    local alongYaw = unit.alongD and yawOf(scene, frame.inSign, 0) or yawOf(scene, 0, 1)
    for _, c in ipairs(cells) do
        if bale == nil and c.i == baleI and c.j == baleJ and #cells > 1 then
            local x, z = toWorld(scene, frame.uAt(c.d), c.v)
            bale = { x = x, z = z, yaw = alongYaw }
        else
            table.insert(rest, c)
        end
    end
    for k, c in ipairs(rest) do
        c.order = TCAuctionScene.hash(seed, 89, index, k)
    end
    table.sort(rest, function(a, b)
        if a.order ~= b.order then
            return a.order < b.order
        end
        return a.i * 100 + a.j < b.i * 100 + b.j
    end)
    local spots = {}
    for k, c in ipairs(rest) do
        local x, z = toWorld(scene, frame.uAt(c.d), c.v)
        local turn = (TCAuctionScene.hash(seed, 90, index, k) - 0.5) * 2 * TCShowScene.ANIMAL_TURN
        table.insert(spots, { x = x, z = z, yaw = facingYaw + turn })
    end
    return spots, bale
end

-- 188: the class in the ring (pure): count animals in a line along the
-- ring's middle (a second line behind past what one holds), from the
-- entrance end, all facing -v. Returns { { x, z, yaw } }.
function TCShowScene.getRingLine(scene, count)
    local spots = {}
    local areas = TCShowScene.isShowDressing(scene) and TCShowScene.getAreas(scene) or nil
    if areas == nil or (count or 0) < 1 then
        return spots
    end
    local frame = frameOf(scene)
    local L = TCShowScene.RING_LINE
    local ring = areas.ring
    local span = ring.dTo - ring.dFrom - 2 * L.margin
    local perLine = math.max(1, math.floor(span / L.spacing) + 1)
    local middle = (ring.dFrom + ring.dTo) * 0.5
    local yaw = yawOf(scene, 0, -1)
    local placed = 0
    for line = 1, 2 do
        local n = math.min(perLine, count - placed)
        if n <= 0 then
            break
        end
        local v = line == 1 and L.v or L.secondV
        for i = 1, n do
            local d = middle + (i - (n + 1) * 0.5) * L.spacing
            local x, z = toWorld(scene, frame.uAt(d), v)
            table.insert(spots, { x = x, z = z, yaw = yaw })
        end
        placed = placed + n
    end
    return spots
end

-- 188: where the judge stands (pure): walking the line (progress 0-1
-- through it: in front of each animal in turn, facing it), or once they're
-- placing them (placed), stood back facing the line's middle. { x, z, yaw }
-- or nil with no ring.
function TCShowScene.getJudgeSpot(scene, count, progress, placed)
    local areas = TCShowScene.isShowDressing(scene) and TCShowScene.getAreas(scene) or nil
    if areas == nil then
        return nil
    end
    local frame = frameOf(scene)
    local L = TCShowScene.RING_LINE
    local ring = areas.ring
    local middle = (ring.dFrom + ring.dTo) * 0.5
    local yaw = yawOf(scene, 0, 1)
    local n = math.max(1, math.min(count or 1, math.floor((ring.dTo - ring.dFrom - 2 * L.margin) / L.spacing) + 1))
    if placed then
        local x, z = toWorld(scene, frame.uAt(middle), L.judgeBackV)
        return { x = x, z = z, yaw = yaw }
    end
    local step = math.min(n, math.floor(math.max(0, progress or 0) * n) + 1)
    local d = middle + (step - (n + 1) * 0.5) * L.spacing
    local x, z = toWorld(scene, frame.uAt(d), L.judgeV)
    return { x = x, z = z, yaw = yaw }
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
    -- 188: the lane in front of each strip of breeders' pens: a side's
    -- from the near aisle to the far end's first strip's lane (or the far
    -- aisle), the far end's across the showground.
    local half = TCShowScene.BREEDERS.lane * 0.5 - TCShowScene.LANE_CLEARANCE
    local farLaneD = nil
    for _, strip in ipairs(areas.breederStrips or {}) do
        if strip.side == 0 and (farLaneD == nil or strip.laneD < farLaneD) then
            farLaneD = strip.laneD
        end
    end
    local drawn = {}
    for _, strip in ipairs(areas.breederStrips or {}) do
        -- A side's strip's two halves (either side of the cross aisle)
        -- share one lane.
        local laneKey = strip.side ~= 0 and string.format("%d:%.3f", strip.side, strip.laneV) or
            string.format("far:%.3f", strip.laneD)
        if strip.ownLane and half >= 1 and not drawn[laneKey] then
            drawn[laneKey] = true
            if strip.side ~= 0 then
                add(frame.uAt(-aisleHalf), strip.laneV, frame.uAt((farLaneD or frame.depth) + trim), strip.laneV, half)
            else
                local reach = frame.halfV - TCShowScene.EDGE
                add(frame.uAt(strip.laneD), -reach, frame.uAt(strip.laneD), reach + trim, half)
            end
        end
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

-- 182: each pen (pure), numbered as ShowLivestock's pens are: the first
-- row from the entrance end, then the second. { number, x, z (its middle),
-- yaw (facing out of its front), frontX, frontZ (its front hurdle's
-- middle), outU (1 when its front faces +v, -1 for the second row's) }.
-- Empty with no pens.
function TCShowScene.getPens(scene)
    local list = {}
    local areas = TCShowScene.isShowDressing(scene) and TCShowScene.getAreas(scene) or nil
    local pens = areas ~= nil and areas.pens or nil
    if pens == nil then
        return list
    end
    local frame = frameOf(scene)
    local rows = { { vFrom = pens.vFrom, vTo = pens.vTo, count = pens.count, front = pens.vTo, out = 1 } }
    if pens.back ~= nil then
        table.insert(rows, { vFrom = pens.back.vFrom, vTo = pens.back.vTo, count = pens.back.count,
            front = pens.back.vFrom, out = -1 })
    end
    for _, row in ipairs(rows) do
        for i = 1, row.count do
            local d = pens.dFrom + (i - 0.5) * pens.size
            local u = frame.uAt(d)
            local x, z = toWorld(scene, u, (row.vFrom + row.vTo) * 0.5)
            local frontX, frontZ = toWorld(scene, u, row.front)
            table.insert(list, { number = #list + 1, x = x, z = z, yaw = yawOf(scene, 0, row.out),
                frontX = frontX, frontZ = frontZ, outU = row.out })
        end
    end
    return list
end

-- 182: the ground under the pens (pure), bare and trodden so no grass
-- grows up through the straw: a rectangle a row, PEN_GROUND_MARGIN past its
-- hurdles all round. Each { { x, z } x 4 } (its corners in turn). Empty with
-- no pens.
function TCShowScene.getPenGround(scene)
    local list = {}
    local areas = TCShowScene.isShowDressing(scene) and TCShowScene.getAreas(scene) or nil
    if areas == nil then
        return list
    end
    local frame = frameOf(scene)
    local margin = TCShowScene.PEN_GROUND_MARGIN
    local function add(dFrom, dTo, vFrom, vTo)
        local corners = {}
        for _, corner in ipairs({ { dFrom, vFrom }, { dTo, vFrom }, { dTo, vTo }, { dFrom, vTo } }) do
            local x, z = toWorld(scene, frame.uAt(corner[1]), corner[2])
            table.insert(corners, { x = x, z = z })
        end
        table.insert(list, corners)
    end
    local pens = areas.pens
    if pens ~= nil then
        local rows = { { vFrom = pens.vFrom, vTo = pens.vTo, count = pens.count } }
        if pens.back ~= nil then
            table.insert(rows, pens.back)
        end
        for _, row in ipairs(rows) do
            add(pens.dFrom - margin, pens.dFrom + row.count * pens.size + margin, row.vFrom - margin, row.vTo + margin)
        end
    end
    -- 188: each breeder's pen.
    for _, unit in ipairs(TCShowScene.listBreederUnits(scene, areas)) do
        local pen = unit.pen
        add(pen.dFrom - margin, pen.dTo + margin, pen.vFrom - margin, pen.vTo + margin)
    end
    return list
end

-- 182: the pens' animals and rosettes (pure), from ShowLivestock's synced
-- pens (pens[number] = { present, subTypeName, age, variation, placing,
-- champion }). In each pen with its animal there: the animal, posed, in its
-- middle facing out of the front (an `animal` prop: subTypeName, age,
-- variation), and once judged its rosettes along its front hurdle on the
-- outside, the champion's first, from the entrance end. A rosette has the
-- hurdle's footprint (so it sits at the hurdle's height on a slope), turned
-- to face out, offsetX along it. Every prop has a `key` naming what it
-- shows, so the props can be swapped one by one as the pens change. A pen
-- past the scene's (no room) is left out.
--
-- 188, extra (optional): { inRing = { [pen number] = true } (a player's
-- animal in the ring, not in its pen), breeders = { [index] = { animals =
-- { { id, subTypeName, age, variation } } (those in their pen now),
-- rosettes = { colour, ... } (on its front, in order) } }, ring = { { look:
-- subTypeName, age, variation } } (the class in the ring, in line order) }.
-- A breeder's animal stands at its id's place in their pen
-- (getBreederAnimalSpots), their rosettes along its front from its start.
function TCShowScene.layOutPens(scene, pens, extra)
    local props = {}
    if pens == nil then
        return props
    end
    extra = extra or {}
    local places = TCShowScene.getPens(scene)
    local frame = frameOf(scene)
    local animalSize = TCShowScene.SIZES.penAnimal
    local footprint = TCShowScene.SIZES.penHurdle
    local spacing = TCShowScene.ROSETTE.spacing
    local inRing = extra.inRing or {}
    TCShowScene.layOutBreederAnimals(scene, extra.breeders, props)
    TCShowScene.layOutRing(scene, extra.ring, props)
    for number, pen in ipairs(pens) do
        local place = places[number]
        if place ~= nil and pen.present and pen.subTypeName ~= nil then
            -- 188: in the ring for its class, its rosettes staying on the pen.
            if not inRing[number] then
                table.insert(props, { kind = "animal", x = place.x, z = place.z, yaw = place.yaw,
                    width = animalSize.width, length = animalSize.length, pen = number,
                    subTypeName = pen.subTypeName, age = pen.age or 0, variation = pen.variation or 1,
                    key = string.format("animal:%d:%s:%d:%d", number, pen.subTypeName, pen.age or 0,
                        pen.variation or 1) })
            end
            local colours = {}
            if pen.champion then
                table.insert(colours, TCShowScene.ROSETTE_CHAMPION)
            end
            local colour = pen.placing ~= nil and TCShowScene.ROSETTE_COLOURS[pen.placing] or nil
            if colour ~= nil then
                table.insert(colours, colour)
            end
            for slot, rosette in ipairs(colours) do
                -- Along d from the entrance end; the model's x is along u
                -- facing +v, against it facing -v.
                local dOffset = (slot - (#colours + 1) * 0.5) * spacing
                table.insert(props, { kind = "rosette", x = place.frontX, z = place.frontZ, yaw = place.yaw,
                    width = footprint.length, length = footprint.width,
                    offsetX = frame.inSign * dOffset * place.outU, rosette = rosette, pen = number,
                    key = string.format("rosette:%d:%d:%s", number, slot, rosette) })
            end
        end
    end
    return props
end

-- 188: the breeders' animals in their pens and their rosettes (pure; see
-- layOutPens' extra.breeders). Added to props.
function TCShowScene.layOutBreederAnimals(scene, breeders, props)
    if breeders == nil then
        return
    end
    local areas = TCShowScene.isShowDressing(scene) and TCShowScene.getAreas(scene) or nil
    if areas == nil then
        return
    end
    local frame = frameOf(scene)
    local animalSize = TCShowScene.SIZES.penAnimal
    local footprint = TCShowScene.SIZES.penHurdle
    local spacing = TCShowScene.ROSETTE.spacing
    local panel = footprint.length
    local cosA, sinA = math.cos(scene.angle), math.sin(scene.angle)
    for index = 1, #(scene.breeders or {}) do
        local unit = areas.breeders[index]
        local shown = breeders[index]
        if unit ~= nil and shown ~= nil then
            local spots = TCShowScene.getBreederAnimalSpots(scene, index)
            for _, animal in ipairs(shown.animals or {}) do
                local spot = animal.id ~= nil and spots[animal.id] or nil
                if spot ~= nil and animal.subTypeName ~= nil then
                    table.insert(props, { kind = "animal", x = spot.x, z = spot.z, yaw = spot.yaw,
                        width = animalSize.width, length = animalSize.length, breeder = index,
                        subTypeName = animal.subTypeName, age = animal.age or 0, variation = animal.variation or 1,
                        key = string.format("breeder:%d:%d:%s:%d:%d", index, animal.id, animal.subTypeName,
                            animal.age or 0, animal.variation or 1) })
                end
            end
            -- The rosettes on the front's hurdles, from its start along it.
            local pen = unit.pen
            local yaw = yawOf(scene, frame.inSign * unit.facing.d, unit.facing.v)
            local fx, fz = math.cos(yaw), -math.sin(yaw)    -- the model's +x in the world
            local length = unit.size.length
            for slot, rosette in ipairs(shown.rosettes or {}) do
                local along = slot * spacing
                if along >= length then
                    break
                end
                local hurdle = math.floor(along / panel)
                local centre = (hurdle + 0.5) * panel
                local d, v
                local ad, av
                if unit.alongD then
                    d, v = pen.dFrom + centre, unit.front
                    ad, av = 1, 0
                else
                    d, v = unit.front, pen.vFrom + centre
                    ad, av = 0, 1
                end
                local x, z = toWorld(scene, frame.uAt(d), v)
                -- Along the front in the world, and so along the model's x.
                local du = frame.inSign * ad
                local wx, wz = du * cosA - av * sinA, du * sinA + av * cosA
                table.insert(props, { kind = "rosette", x = x, z = z, yaw = yaw, width = footprint.length,
                    length = footprint.width, offsetX = (along - centre) * (wx * fx + wz * fz), rosette = rosette,
                    breeder = index, key = string.format("breederRosette:%d:%d:%s", index, slot, rosette) })
            end
        end
    end
end

-- 188: the class in the ring (pure): each animal at its place in the line
-- (getRingLine), in order. Added to props.
function TCShowScene.layOutRing(scene, ring, props)
    if ring == nil or #ring == 0 then
        return
    end
    local animalSize = TCShowScene.SIZES.penAnimal
    for i, spot in ipairs(TCShowScene.getRingLine(scene, #ring)) do
        local animal = ring[i]
        if animal ~= nil and animal.subTypeName ~= nil then
            table.insert(props, { kind = "animal", x = spot.x, z = spot.z, yaw = spot.yaw, width = animalSize.width,
                length = animalSize.length, ring = i, subTypeName = animal.subTypeName, age = animal.age or 0,
                variation = animal.variation or 1, key = string.format("ring:%d:%s:%d:%d", i, animal.subTypeName,
                    animal.age or 0, animal.variation or 1) })
        end
    end
end

-- 182: the straw beds (pure), one under each row of pens, STRAW.margin
-- past its hurdles, laid in tiles (penStraw props, each scaled by scaleX,
-- scaleZ to fit). A tile fades (its ragged edge) only on the bed's outer
-- sides; inside, tiles meet with none, so the bed's one piece. Two rows
-- meet at their shared wall, unfaded. A tile's model +z is towards the
-- entrance (-d), so its +x is +v or -v as the scene runs (place's right
-- of its forward). Added to result.props.
-- One straw bed (pure): the rectangle dFrom..dTo, vFrom..vTo in tiles,
-- each side faded (ragged) where fades says ({ dFrom, dTo, vFrom, vTo },
-- true for faded). Added to result.props.
local function layOutBed(scene, frame, result, dFrom, dTo, vFrom, vTo, fades)
    local S = TCShowScene.STRAW
    local F = TCShowScene.STRAW_FADE
    -- Model +z towards the entrance: -d, which is u's -inSign. Its +x
    -- (place's right: forward (fx, fz) turned to (fz, -fx)) is then +v
    -- when inSign is 1, -v when it's -1.
    local yaw = yawOf(scene, -frame.inSign, 0)
    local vFromBit, vToBit = F.minusX, F.plusX
    if frame.inSign < 0 then
        vFromBit, vToBit = F.plusX, F.minusX
    end
    local nD = math.max(1, math.floor((dTo - dFrom) / S.tile + 0.5))
    local nV = math.max(1, math.floor((vTo - vFrom) / S.tile + 0.5))
    local stepD, stepV = (dTo - dFrom) / nD, (vTo - vFrom) / nV
    for i = 1, nD do
        for j = 1, nV do
            local fade = 0
            if i == 1 and fades.dFrom then
                fade = fade + F.plusZ      -- the entrance end, -d
            end
            if i == nD and fades.dTo then
                fade = fade + F.minusZ
            end
            if j == 1 and fades.vFrom then
                fade = fade + vFromBit
            end
            if j == nV and fades.vTo then
                fade = fade + vToBit
            end
            local x, z = toWorld(scene, frame.uAt(dFrom + (i - 0.5) * stepD), vFrom + (j - 0.5) * stepV)
            table.insert(result.props, { kind = "penStraw", x = x, z = z, yaw = yaw, width = stepV,
                length = stepD, scaleX = stepV / S.tile, scaleZ = stepD / S.tile, fade = fade })
        end
    end
end

function TCShowScene.layOutStraw(scene, result)
    local areas = TCShowScene.getAreas(scene)
    if areas == nil then
        return
    end
    local frame = frameOf(scene)
    local margin = TCShowScene.STRAW.margin
    local pens = areas.pens
    if pens ~= nil then
        local back = pens.back
        local beds = { { count = pens.count, vFrom = back ~= nil and pens.vFrom or pens.vFrom - margin,
            vTo = pens.vTo + margin, fadeVFrom = back == nil, fadeVTo = true } }
        if back ~= nil then
            table.insert(beds, { count = back.count, vFrom = back.vFrom - margin, vTo = back.vTo,
                fadeVFrom = true, fadeVTo = false })
        end
        for _, bed in ipairs(beds) do
            layOutBed(scene, frame, result, pens.dFrom - margin, pens.dFrom + bed.count * pens.size + margin,
                bed.vFrom, bed.vTo, { dFrom = true, dTo = true, vFrom = bed.fadeVFrom, vTo = bed.fadeVTo })
        end
    end
    -- 188: a bed under each breeder's pen, ragged all round.
    for _, unit in ipairs(TCShowScene.listBreederUnits(scene, areas)) do
        local pen = unit.pen
        layOutBed(scene, frame, result, pen.dFrom - margin, pen.dTo + margin, pen.vFrom - margin, pen.vTo + margin,
            { dFrom = true, dTo = true, vFrom = true, vTo = true })
    end
end

-- 188: the placed breeders' units in the scene's order (getAreas').
function TCShowScene.listBreederUnits(scene, areas)
    local list = {}
    for index = 1, #(scene.breeders or {}) do
        local unit = areas ~= nil and areas.breeders ~= nil and areas.breeders[index] or nil
        if unit ~= nil then
            table.insert(list, unit)
        end
    end
    return list
end

-- 182: the pens' bales (pure). One in a corner of each pen, which corner
-- from the scene's seed (TCAuctionScene.hash), along the pen's front or
-- back hurdle, its length along it, clear of the animal in the middle
-- (`bale` props with their pen's number). And at each end of each row, on
-- the straw past its end hurdle, two stacks side by side across it, end on
-- to the row, 2 or 3 high (`bale` props with `level` and `rowEnd`, 1 the
-- entrance end, 2 the far one). Added to result.props.
function TCShowScene.layOutPenBales(scene, result)
    local seed = scene.seed or 0
    local B = TCShowScene.PEN_BALE
    local half = TCShowScene.PENS.size * 0.5
    local offD = half - B.inset - B.width * 0.5
    local offV = half - B.inset - B.length * 0.5
    local frame = frameOf(scene)
    local cosA, sinA = math.cos(scene.angle), math.sin(scene.angle)
    for _, pen in ipairs(TCShowScene.getPens(scene)) do
        local pick = math.floor(TCAuctionScene.hash(seed, 80, pen.number) * 4) % 4
        local sideD = (pick % 2 == 0) and -1 or 1
        local sideV = (pick < 2) and -1 or 1
        -- The pen's middle in u, v; d runs along u by inSign.
        local dx, dz = pen.x - scene.cx, pen.z - scene.cz
        local u, v = dx * cosA + dz * sinA, -dx * sinA + dz * cosA
        local x, z = toWorld(scene, u + frame.inSign * sideD * offD, v + sideV * offV)
        local skew = (TCAuctionScene.hash(seed, 81, pen.number) - 0.5) * 2 * B.skew
        table.insert(result.props, { kind = "bale", x = x, z = z, yaw = yawOf(scene, 0, sideV) + skew,
            width = B.width, length = B.length, pen = pen.number })
    end

    -- 188: a bale in a corner of each breeder's pen, in the cell its
    -- animals leave (getBreederAnimalSpots).
    for index = 1, #(scene.breeders or {}) do
        local _, bale = TCShowScene.getBreederAnimalSpots(scene, index)
        if bale ~= nil then
            local skew = (TCAuctionScene.hash(seed, 87, index) - 0.5) * 2 * B.skew
            table.insert(result.props, { kind = "bale", x = bale.x, z = bale.z, yaw = bale.yaw + skew,
                width = B.width, length = B.length, breeder = index })
        end
    end

    local areas = TCShowScene.getAreas(scene)
    local pens = areas ~= nil and areas.pens or nil
    if pens == nil then
        return
    end
    local E = TCShowScene.PEN_END_STACKS
    local rows = { { count = pens.count, v = (pens.vFrom + pens.vTo) * 0.5 } }
    if pens.back ~= nil then
        table.insert(rows, { count = pens.back.count, v = (pens.back.vFrom + pens.back.vTo) * 0.5 })
    end
    for rowIndex, row in ipairs(rows) do
        local ends = { { d = pens.dFrom - E.out, sign = -1 }, { d = pens.dFrom + row.count * pens.size + E.out, sign = 1 } }
        for endIndex, rowEnd in ipairs(ends) do
            for column = 1, 2 do
                local v = row.v + (column - 1.5) * E.apart
                local key = rowIndex * 100 + endIndex * 10 + column
                local levels = E.minLevels + math.floor(TCAuctionScene.hash(seed, 82, key) *
                    (E.maxLevels - E.minLevels + 1)) % (E.maxLevels - E.minLevels + 1)
                local x, z = toWorld(scene, frame.uAt(rowEnd.d), v)
                for level = 0, levels - 1 do
                    local skew = (TCAuctionScene.hash(seed, 83, key, level) - 0.5) * 2 * E.skew
                    table.insert(result.props, { kind = "bale", x = x, z = z,
                        yaw = yawOf(scene, frame.inSign * rowEnd.sign, 0) + skew, width = B.width,
                        length = B.length, level = level, rowEnd = endIndex })
                end
            end
        end
    end
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
    -- (the run's length over PANEL, rounded down). Each hurdle stands on
    -- its own feet, so there's no post at the joints. skip(i): leave panel
    -- i out (a gateway). kind: the hurdle's (182: the pens' are longer),
    -- `hurdle` by default.
    local function run(d1, v1, d2, v2, skip, kind)
        kind = kind or "hurdle"
        local panel = TCShowScene.SIZES[kind].length
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
                add(kind, startD + stepD * 0.5, startV + stepV * 0.5, yaw)
            end
        end
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
        run(pens.dFrom, pens.vFrom, dTo, pens.vFrom, nil, "penHurdle")
        run(pens.dFrom, pens.vTo, dTo, pens.vTo, nil, "penHurdle")
        for i = 0, pens.count do
            local d = pens.dFrom + i * size
            run(d, pens.vFrom, d, pens.vTo, nil, "penHurdle")
        end
        -- 182: the second row's outer wall (its fronts) and dividers; its
        -- inner wall is the first row's back.
        local back = pens.back
        if back ~= nil then
            run(pens.dFrom, back.vFrom, pens.dFrom + back.count * size, back.vFrom, nil, "penHurdle")
            for i = 0, back.count do
                local d = pens.dFrom + i * size
                run(d, back.vFrom, d, back.vTo, nil, "penHurdle")
            end
        end
    end

    -- 188: each breeder's pen, hurdles all round, and a couple of the
    -- crowd at its front.
    local BR = TCShowScene.BREEDERS
    for _, unit in ipairs(TCShowScene.listBreederUnits(scene, areas)) do
        local pen = unit.pen
        run(pen.dFrom, pen.vFrom, pen.dTo, pen.vFrom, nil, "penHurdle")
        run(pen.dTo, pen.vFrom, pen.dTo, pen.vTo, nil, "penHurdle")
        run(pen.dTo, pen.vTo, pen.dFrom, pen.vTo, nil, "penHurdle")
        run(pen.dFrom, pen.vTo, pen.dFrom, pen.vFrom, nil, "penHurdle")
        local facing = unit.facing
        local lookYaw = yawOf(scene, -frame.inSign * facing.d, -facing.v)
        groupCount = groupCount + 1
        for p = 1, 2 do
            local share = p / 3 + (TCAuctionScene.hash(seed, 91, unit.index, p) - 0.5) * 0.1
            local d, v
            if unit.alongD then
                d = pen.dFrom + share * (pen.dTo - pen.dFrom)
                v = unit.front + facing.v * BR.visitorsOut
            else
                d = unit.front - BR.visitorsOut
                v = pen.vFrom + share * (pen.vTo - pen.vFrom)
            end
            local x, z = toWorld(scene, frame.uAt(d), v)
            table.insert(result.spots, { x = x, z = z, yaw = lookYaw, category = TCShowScene.SPOT.STAND,
                group = groupCount })
        end
    end

    -- 182: the straw under the pens, and a bale in each.
    TCShowScene.layOutStraw(scene, result)
    TCShowScene.layOutPenBales(scene, result)

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
