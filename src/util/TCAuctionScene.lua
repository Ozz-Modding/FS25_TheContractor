-- Auction site dressing (140): the pure half. Where the props go on a sale
-- day (the car park, the food area, the toilets, the sale office, bunting,
-- signs and chalkboards), the crowd's extra standing spots (by the lots,
-- round the food, a handful by the gate) and its extra walks (the cross
-- aisles), all from the site's synced scene (TCAuctionLayout.getScene), so
-- every machine works out the same. Tested in tests/test_auctionScene.lua.
-- TCAuctionProps loads the models; TCAuctionCrowd puts the people out.
--
-- The entrance space (135's, entranceSpace deep, as wide as the rows) is
-- worked in depth d from its outer edge (the field's edge, by the road) in
-- towards the lots, and across it by v (the rectangle's). Its inner
-- aisleWidth is the near cross aisle, walked by the crowd and kept clear
-- but for each row's lot sign at its edge. The rows rarely take the whole
-- rectangle's width, so the car park and the bunting carry on past the
-- rows' sides, as far as the rectangle goes, in the same depth. Across:
--   - the drive lane: DRIVE_HALF either side of the gate (the entrance's
--     v), clear all the way in, for buyers driving their lots out;
--   - a LANE_MARGIN strip down each side of it, for a strand of bunting,
--     straw bales by the gate and the blocks' signs;
--   - either side of that, blocks packed out from the lane (packBlocks): the
--     sale office by the gate, the food area (the food van, picnic benches,
--     bins, the menu board), the toilets, then the car park filling what's
--     left of both sides. A block that fits nowhere is left out;
--   - bunting along the outer edge either side of the gate, and a strand
--     down each side of the lane's mouth; straw bales flanking the gate.
-- A prop is { kind, x, z, yaw, width, length } (its footprint centred on
-- x, z: width across its own x, length along its facing, yaw as
-- MathUtil.getYRotationFromDirection's, atan2(dirX, dirZ)), plus model
-- (a car's, from CAR_MODELS, by number), colour (a car's, a fraction to
-- pick from its colours), face (a sign's: FACES), lotFrom/lotTo (a row
-- sign's) or board (a chalkboard's: BOARDS).
--
-- Picks (which bays have cars, which car, which way round) come from the
-- scene's seed through hash, never math.random, so every machine agrees.
--
-- 163: a scene dressed for another kind of day than the auction (its
-- dressing, a kind's KIND; nil is the auction) has the shared dressing
-- only: the car park, the food area, the toilets, bunting and bales, and
-- their signs. Everything that says "auction" (the gate's sign, the sale
-- office and its closing hours, the boards about bidding and lots, the
-- rows' lot signs) is the auction's alone.

TCAuctionScene = {}

-- Metres.
TCAuctionScene.DRIVE_HALF = 4        -- the drive lane, either side of the gate
TCAuctionScene.EDGE = 0.5            -- props kept this far from the space's edges
TCAuctionScene.LANE_MARGIN = 1.0     -- a strip along the lane for bunting, bales and signs
TCAuctionScene.BLOCK_GAP = 1.0       -- between blocks
-- How far out from the lane the gate's own things reach along each side
-- (the gate sign on the first, the sold-as-seen board on the second):
-- the blocks are packed from there, a BLOCK_GAP on.
TCAuctionScene.GATE_ROOM = { 4.0, 2.7 }
-- The straw bales by the gate, stacked this many high.
TCAuctionScene.BALE_STACK = 3
TCAuctionScene.BUNTING_SPAN = 8      -- one bunting model's length, pole to pole
TCAuctionScene.BAY_WIDTH = 2.8       -- a parking bay, across
TCAuctionScene.BAY_DEPTH = 5.4       -- a parking bay, deep
TCAuctionScene.CAR_AISLE = 6         -- between the car park's two rows
TCAuctionScene.CAR_SHARE = 0.75      -- of the bays that have a car
TCAuctionScene.CAR_MAX = 50          -- cars at most, filled out from the lane
TCAuctionScene.ROW_SIGN_INSET = 0.7  -- a row's lot sign, out from the lots' edge
TCAuctionScene.VIEW_STANDOFF = 0.6   -- a viewer from the lots' fronts
TCAuctionScene.VIEW_SHARE = 0.4      -- of the lots that have someone looking at them

-- The sizes props take on the ground (width across, length along the way
-- they face). A car's is its model's (CAR_MODELS).
TCAuctionScene.SIZES = {
    foodVan = { width = 5.4, length = 6 },
    bench = { width = 1.8, length = 1.6 },
    bin = { width = 0.7, length = 0.7 },
    toilet = { width = 1.2, length = 1.2 },
    office = { width = 3.2, length = 3.2 },
    bunting = { width = 8, length = 0.3 },
    bale = { width = 1.2, length = 0.5 },
    sign = { width = 1.6, length = 0.3 },
    gateSign = { width = 3.0, length = 0.3 },
    board = { width = 1.4, length = 0.7 },
}

-- The site signs' faces (genAuctionSiteSignI3d.py's), by what they say.
TCAuctionScene.FACES = {
    GATE = "gate",          -- MACHINERY AUCTION (the gate sign)
    HOURS = "hours",        -- BIDDING CLOSES 17:00-18:00
    FOOD = "food",
    PARKING = "parking",
    TOILETS = "toilets",
    LOTS = "lots",          -- LOTS <from>-<to>
}

-- The chalkboards (i3d/auctionBoard.i3d's variants), by what they say.
TCAuctionScene.BOARDS = {
    FOOD_MENU = 1,          -- the food area's menu
    SOLD_AS_SEEN = 2,       -- sold as seen, free delivery: by the gate
    STOP_FAFFING = 3,       -- Stop Faffing, Start Bidding: into the lots
    KEEP_CLOSE = 4,         -- children and dogs close: into the lots
    CAREFUL_OWNER = 5,      -- one careful owner: by the car park
}

-- The parked cars: vanilla's traffic cars (their own XMLs give the model
-- file, paint colours and paint nodes, TCAuctionProps). width and length
-- are the car's footprint, padded; forward is how far its middle is ahead
-- of its root (the rear axle: half the wheelbase); weight how often it's
-- picked (vans less).
TCAuctionScene.CAR_MODELS = {
    { xml = "$data/trafficVehicles/vehicle01/vehicle01.xml", width = 1.9, length = 4.6, forward = 1.38, weight = 2 },
    { xml = "$data/trafficVehicles/vehicle02/vehicle02.xml", width = 2.1, length = 4.6, forward = 1.38, weight = 2 },
    { xml = "$data/trafficVehicles/vehicle03/vehicle03.xml", width = 2.2, length = 5.0, forward = 1.55, weight = 2 },
    { xml = "$data/trafficVehicles/vehicle04/vehicle04.xml", width = 1.9, length = 4.6, forward = 1.38, weight = 2 },
    { xml = "$data/trafficVehicles/vehicle05/vehicle05.xml", width = 1.9, length = 4.6, forward = 1.38, weight = 2 },
    { xml = "$data/trafficVehicles/vehicle06/vehicle06.xml", width = 1.9, length = 4.6, forward = 1.38, weight = 2 },
    { xml = "$data/trafficVehicles/vehicle07/vehicle07.xml", width = 1.9, length = 4.6, forward = 1.38, weight = 2 },
    { xml = "$data/trafficVehicles/vehicle08/vehicle08.xml", width = 1.9, length = 4.6, forward = 1.38, weight = 2 },
    { xml = "$data/trafficVehicles/vehicle09/vehicle09.xml", width = 1.9, length = 4.6, forward = 1.38, weight = 2 },
    { xml = "$data/trafficVehicles/vehicle10/vehicle10.xml", width = 2.2, length = 5.3, forward = 1.7, weight = 2 },
    { xml = "$data/trafficVehicles/vehicle11/vehicle11.xml", width = 1.9, length = 4.6, forward = 1.38, weight = 2 },
    { xml = "$data/trafficVehicles/vehicle12/vehicle12.xml", width = 1.9, length = 4.6, forward = 1.38, weight = 2 },
    { xml = "$data/trafficVehicles/vehicle13/vehicle13.xml", width = 1.9, length = 4.3, forward = 1.23, weight = 2 },
    { xml = "$data/trafficVehicles/vehicle14/vehicle14.xml", width = 2.0, length = 4.6, forward = 1.38, weight = 2 },
    { xml = "$data/trafficVehicles/vehicle16/vehicle16.xml", width = 1.8, length = 4.3, forward = 1.25, weight = 2 },
    { xml = "$data/trafficVehicles/vehicle17/vehicle17.xml", width = 1.7, length = 3.6, forward = 0.93, weight = 1 },
    { xml = "$data/trafficVehicles/vehicle18/vehicle18.xml", width = 2.3, length = 5.3, forward = 1.68, weight = 1 },
    { xml = "$data/trafficVehicles/vehicle19/vehicle19.xml", width = 2.3, length = 5.3, forward = 1.68, weight = 1 },
    { xml = "$data/trafficVehicles/vehicle20/vehicle20.xml", width = 2.3, length = 4.7, forward = 1.38, weight = 1 },
    { xml = "$data/trafficVehicles/vehicle21/vehicle21.xml", width = 2.3, length = 4.7, forward = 1.4, weight = 1 },
}

-- Standing spot categories (TCAuctionCrowd's hours treat the gate's apart:
-- they stay into the evening).
TCAuctionScene.SPOT = {
    GATE = "gate",
    FOOD = "food",
    LOT = "lot",
}

-- Picks ------------------------------------------------------------------------------------

-- A fraction in [0, 1) from the seed and up to three whole numbers
-- (integer arithmetic, so every machine gets the same).
function TCAuctionScene.hash(seed, a, b, c)
    local h = (seed or 0) % 2147483647
    for _, n in ipairs({ a or 0, b or 0, c or 0 }) do
        h = (h * 31 + n * 7919 + 104729) % 2147483647
        h = (h * 48271) % 2147483647
    end
    return h / 2147483647
end

-- A car model's number, weighted, from a fraction.
function TCAuctionScene.pickCar(fraction)
    local total = 0
    for _, model in ipairs(TCAuctionScene.CAR_MODELS) do
        total = total + model.weight
    end
    local target = fraction * total
    for index, model in ipairs(TCAuctionScene.CAR_MODELS) do
        target = target - model.weight
        if target < 0 then
            return index
        end
    end
    return #TCAuctionScene.CAR_MODELS
end

-- Geometry ---------------------------------------------------------------------------------

local function toWorld(scene, u, v)
    local cosA, sinA = math.cos(scene.angle), math.sin(scene.angle)
    return scene.cx + u * cosA - v * sinA, scene.cz + u * sinA + v * cosA
end

-- The yaw facing the rectangle's (du, dv).
local function yawOf(scene, du, dv)
    local cosA, sinA = math.cos(scene.angle), math.sin(scene.angle)
    return math.atan2(du * cosA - dv * sinA, du * sinA + dv * cosA)
end

-- The entrance space's frame: u at depth d in from its outer edge, and
-- which way along u is in (towards the lots).
local function frameOf(scene)
    local reserve = scene.reserve
    local outerU = scene.nearSign > 0 and reserve.uTo or reserve.uFrom
    local inSign = -scene.nearSign
    return {
        outerU = outerU,
        inSign = inSign,
        depth = math.abs(reserve.uTo - reserve.uFrom),
        uAt = function(d)
            return outerU + inSign * d
        end,
    }
end

-- Building the scene -----------------------------------------------------------------------

-- A side of the drive lane: from the lane's edge (laneV) out to the space's
-- edge (endV), in direction sign (1 or -1 along v).
local function makeSide(laneV, endV, sign)
    return { laneV = laneV, endV = endV, sign = sign, used = TCAuctionScene.LANE_MARGIN,
        width = math.abs(endV - laneV) }
end

-- The blocks that go beside the lane, in the order they're placed, and
-- how wide each is along the side.
TCAuctionScene.BLOCKS = {
    { key = "office", width = 6, auctionOnly = true },
    { key = "food", width = 17 },
    { key = "toilets", width = 6 },
}

-- Whether a scene's dressed as the auction (163).
function TCAuctionScene.isAuctionDressing(scene)
    return scene.dressing == nil or scene.dressing == "auction"
end

-- Which side each block goes (pure): the office on the side with more room
-- (nearest the gate), then each block on whichever side has the most room
-- left that it fits, packed out from the lane. Returns { [key] = { side,
-- from (along the side, from the lane's edge) } }.
function TCAuctionScene.packBlocks(sides, blocks)
    local placed = {}
    for _, block in ipairs(blocks) do
        local best = nil
        for _, side in ipairs(sides) do
            local gap = side.used > TCAuctionScene.LANE_MARGIN and TCAuctionScene.BLOCK_GAP or 0
            local room = side.width - side.used - gap
            if room >= block.width and (best == nil or room > best.room) then
                best = { side = side, room = room }
            end
        end
        if best ~= nil then
            local side = best.side
            local from = side.used + (side.used > TCAuctionScene.LANE_MARGIN and TCAuctionScene.BLOCK_GAP or 0)
            placed[block.key] = { side = side, from = from }
            side.used = from + block.width
        end
    end
    return placed
end

-- Lays the scene out. scene: TCAuctionLayout.getScene's. Returns {
--   props = { prop, ... },
--   spots = { { x, z, yaw, category, group } },
--   sounds = { { x, z } },
--   lane = { vFrom, vTo }, usableDepth,
-- }.
function TCAuctionScene.layOut(scene)
    local result = { props = {}, spots = {}, sounds = {} }
    if scene == nil or scene.reserve == nil then
        return result
    end
    local isAuction = TCAuctionScene.isAuctionDressing(scene)
    local frame = frameOf(scene)
    local reserve = scene.reserve
    local seed = scene.seed or 0
    local edge = TCAuctionScene.EDGE
    -- Clear of the near cross aisle.
    local usable = frame.depth - (scene.aisleWidth or 10) - edge
    result.usableDepth = usable
    if usable < 4 or reserve.vTo - reserve.vFrom < 2 * TCAuctionScene.DRIVE_HALF + 4 then
        return result
    end

    -- The gate and the drive lane, kept inside the space.
    local half = TCAuctionScene.DRIVE_HALF
    local gateV = math.max(reserve.vFrom + edge + half, math.min(reserve.vTo - edge - half, scene.gateV or 0))
    local laneFrom, laneTo = gateV - half, gateV + half
    result.lane = { vFrom = laneFrom, vTo = laneTo }

    local outwardYaw = yawOf(scene, -frame.inSign, 0)
    local inwardYaw = yawOf(scene, frame.inSign, 0)
    local groupCount = 0

    local function add(kind, d, v, yaw, extra)
        local size = TCAuctionScene.SIZES[kind]
        local x, z = toWorld(scene, frame.uAt(d), v)
        local prop = { kind = kind, x = x, z = z, yaw = yaw, width = size and size.width or 1,
            length = size and size.length or 1 }
        for key, value in pairs(extra or {}) do
            prop[key] = value
        end
        table.insert(result.props, prop)
        return prop
    end

    local function addSpot(d, v, yaw, category, group)
        local x, z = toWorld(scene, frame.uAt(d), v)
        table.insert(result.spots, { x = x, z = z, yaw = yaw, category = category, group = group })
    end

    -- A group of people facing their middle.
    local function addGroup(d, v, size, radius, category)
        groupCount = groupCount + 1
        local mx, mz = toWorld(scene, frame.uAt(d), v)
        for p = 1, size do
            local a = 2 * math.pi * (p - 1) / size + groupCount
            local x = mx + radius * math.cos(a)
            local z = mz + radius * math.sin(a)
            table.insert(result.spots, { x = x, z = z, yaw = math.atan2(mx - x, mz - z), category = category,
                group = groupCount })
        end
    end

    -- Out to the rectangle's sides (the reserve's, for a scene without them).
    local halfV = scene.halfV or math.max(-reserve.vFrom, reserve.vTo)
    local sides = {
        makeSide(laneFrom, math.min(reserve.vFrom, -halfV) + edge, -1),
        makeSide(laneTo, math.max(reserve.vTo, halfV) - edge, 1),
    }
    -- The roomier side first, so the office (the first block) is on it.
    if sides[2].width > sides[1].width then
        sides[1], sides[2] = sides[2], sides[1]
    end
    -- The gate's sign and board keep their room: the blocks start past them.
    for i, side in ipairs(sides) do
        side.used = TCAuctionScene.GATE_ROOM[i]
    end
    local wantedBlocks = {}
    for _, block in ipairs(TCAuctionScene.BLOCKS) do
        if isAuction or not block.auctionOnly then
            table.insert(wantedBlocks, block)
        end
    end
    local blocks = TCAuctionScene.packBlocks(sides, wantedBlocks)

    -- A point a along a side from its lane edge.
    local function sideV(side, a)
        return side.laneV + side.sign * a
    end
    -- Facing the lane from a side.
    local function towardLane(side)
        return yawOf(scene, 0, -side.sign)
    end

    -- The gate: its sign beside the lane on the first side, facing the road;
    -- the sold-as-seen board on the other; two stacks of bales each side,
    -- end on to the lane.
    if isAuction then
        add("gateSign", 1.2, sideV(sides[1], 2.5), outwardYaw, { face = TCAuctionScene.FACES.GATE })
        add("board", 2.8, sideV(sides[2], 2.0), outwardYaw, { board = TCAuctionScene.BOARDS.SOLD_AS_SEEN })
    end
    for _, side in ipairs(sides) do
        for k, d in ipairs({ 1.3, 2.7 }) do
            -- Stacked BALE_STACK high, each a little askew.
            for level = 0, TCAuctionScene.BALE_STACK - 1 do
                local skew = (TCAuctionScene.hash(seed, 11, side.sign * 10 + k, level) - 0.5) * 0.12
                add("bale", d, sideV(side, 0.45), yawOf(scene, 0, side.sign) + skew, { level = level })
            end
        end
    end

    -- Bunting: along the outer edge either side of the lane, and a strand
    -- down each side of the lane's mouth.
    local span = TCAuctionScene.BUNTING_SPAN
    for _, side in ipairs(sides) do
        local count = math.floor((side.width - 0.5) / span)
        for i = 1, count do
            local a = 0.5 + (i - 0.5) * span
            add("bunting", 0.3, sideV(side, a), outwardYaw)
        end
        if usable >= span + 5 then
            add("bunting", 4 + span * 0.5, sideV(side, 0.3), yawOf(scene, 0, side.sign))
        end
    end

    -- Boards into the lots, at the lane's inner end, facing the way in.
    if isAuction then
        add("board", usable - 0.6, sideV(sides[1], 1.2), outwardYaw, { board = TCAuctionScene.BOARDS.STOP_FAFFING })
        add("board", usable - 0.6, sideV(sides[2], 1.2), outwardYaw, { board = TCAuctionScene.BOARDS.KEEP_CLOSE })
    end

    -- The sale office by the gate: a gazebo, the closing hours facing the
    -- lane, and the gate's handful of people in front of it.
    local office = blocks.office
    if office ~= nil then
        local side, a0 = office.side, office.from
        add("office", 3.2, sideV(side, a0 + 3), inwardYaw)
        add("sign", 6.0, sideV(side, a0 + 0.8), towardLane(side), { face = TCAuctionScene.FACES.HOURS })
        addGroup(math.min(usable - 2, 8.5), sideV(side, a0 + 3), 3, 1.0, TCAuctionScene.SPOT.GATE)
    end

    -- The food area: the food van facing in, a queue at its counter, picnic
    -- benches in front, bins, its menu and its sign.
    local food = blocks.food
    if food ~= nil then
        local side, a0 = food.side, food.from
        local vanA = a0 + 9
        add("foodVan", 4.0, sideV(side, vanA), inwardYaw)
        -- Its sign beside the lane, facing the lots, for the people there.
        add("sign", 4.0, sideV(side, a0 + 1.2), inwardYaw, { face = TCAuctionScene.FACES.FOOD })
        add("board", 7.6, sideV(side, vanA + 3.2), inwardYaw, { board = TCAuctionScene.BOARDS.FOOD_MENU })
        for k = 0, 2 do
            addSpot(7.8 + k * 0.9, sideV(side, vanA), outwardYaw, TCAuctionScene.SPOT.FOOD)
        end
        add("bin", 8.0, sideV(side, a0 + 1.6), inwardYaw)
        add("bin", 8.5, sideV(side, a0 + 16.0), inwardYaw)
        -- The benches, as deep as there's room for, turned a little each.
        local benches = { { 3.5, 11 }, { 8.5, 13.6 }, { 13.5, 11.2 }, { 4.5, 16.2 }, { 14, 16.0 } }
        for i, bench in ipairs(benches) do
            local a, d = bench[1], bench[2]
            if d + 1.5 <= usable then
                local turn = (TCAuctionScene.hash(seed, 7, i) - 0.5) * 0.5
                local yaw = yawOf(scene, 0, side.sign) + turn
                add("bench", d, sideV(side, a0 + a), yaw)
                -- Two standing at its ends, facing each other.
                groupCount = groupCount + 1
                local cx, cz = toWorld(scene, frame.uAt(d), sideV(side, a0 + a))
                local dirX, dirZ = math.sin(yaw), math.cos(yaw)
                -- A bench's ends are across it (its width, its own x).
                local acrossX, acrossZ = dirZ, -dirX
                for _, s in ipairs({ -1.4, 1.4 }) do
                    local x, z = cx + acrossX * s, cz + acrossZ * s
                    table.insert(result.spots, { x = x, z = z, yaw = math.atan2(cx - x, cz - z),
                        category = TCAuctionScene.SPOT.FOOD, group = groupCount })
                end
            end
        end
        local sx, sz = toWorld(scene, frame.uAt(math.min(usable, 12)), sideV(side, a0 + 8))
        table.insert(result.sounds, { x = sx, z = sz })
    end

    -- The toilets in a row facing in, and their sign.
    local toilets = blocks.toilets
    if toilets ~= nil then
        local side, a0 = toilets.side, toilets.from
        for i = 0, 2 do
            add("toilet", 1.4, sideV(side, a0 + 1.8 + i * 1.5), inwardYaw)
        end
        add("sign", 4.6, sideV(side, a0 + 0.8), towardLane(side), { face = TCAuctionScene.FACES.TOILETS })
    end

    -- The car park: what's left of each side, a row of bays at the outer
    -- edge and, with room, another facing it across an aisle.
    local bay, bayDepth = TCAuctionScene.BAY_WIDTH, TCAuctionScene.BAY_DEPTH
    local rowsAt = { 1 + bayDepth * 0.5 }
    if usable >= 1 + bayDepth * 2 + TCAuctionScene.CAR_AISLE then
        table.insert(rowsAt, 1 + bayDepth * 1.5 + TCAuctionScene.CAR_AISLE)
    end
    local carCount = 0
    local parkingSigned = false
    local perSide = math.ceil(TCAuctionScene.CAR_MAX / #sides)
    for sideIndex, side in ipairs(sides) do
        local sideCars = 0
        local from = side.used + (side.used > TCAuctionScene.LANE_MARGIN and TCAuctionScene.BLOCK_GAP or 0)
        local bays = math.floor((side.width - from) / bay)
        if bays >= 2 then
            if not parkingSigned then
                parkingSigned = true
                add("sign", rowsAt[1] + bayDepth * 0.5 + 1.2, sideV(side, from + 0.8), towardLane(side),
                    { face = TCAuctionScene.FACES.PARKING })
                if #rowsAt > 1 and isAuction then
                    add("board", rowsAt[1] + bayDepth * 0.5 + 1.2, sideV(side, from + 2.6), towardLane(side),
                        { board = TCAuctionScene.BOARDS.CAREFUL_OWNER })
                end
            end
            -- Out from the lane, both rows at once, until the side's had its share.
            for b = 1, bays do
                for rowIndex, d in ipairs(rowsAt) do
                    -- The first bays by the signs stay empty.
                    local a = from + (b - 0.5) * bay
                    local blocked = rowIndex == 1 and b <= 2
                    if not blocked and sideCars < perSide and
                            TCAuctionScene.hash(seed, sideIndex * 100 + rowIndex, b) < TCAuctionScene.CAR_SHARE then
                        local model = TCAuctionScene.pickCar(TCAuctionScene.hash(seed, sideIndex * 100 + rowIndex, b, 1))
                        local car = TCAuctionScene.CAR_MODELS[model]
                        -- Nose in or out, a touch askew.
                        local noseIn = TCAuctionScene.hash(seed, sideIndex * 100 + rowIndex, b, 2) < 0.5
                        local skew = (TCAuctionScene.hash(seed, sideIndex * 100 + rowIndex, b, 3) - 0.5) * 0.12
                        -- The first row backs onto the edge, the second onto the
                        -- lanes behind: "in" is away from each row's back.
                        local facingIn = (rowIndex == 1) == noseIn
                        local prop = add("car", d, sideV(side, a), (facingIn and inwardYaw or outwardYaw) + skew,
                            { model = model, colour = TCAuctionScene.hash(seed, sideIndex * 100 + rowIndex, b, 4) })
                        prop.width, prop.length = car.width, car.length
                        carCount = carCount + 1
                        sideCars = sideCars + 1
                    end
                end
            end
        end
    end
    result.carCount = carCount

    -- Each row's lot sign at its end on the near cross aisle, facing the
    -- entrance.
    for _, row in ipairs(scene.rows or {}) do
        local u = scene.nearEdge + scene.nearSign * TCAuctionScene.ROW_SIGN_INSET
        local v = (row.vFrom + row.vTo) * 0.5
        local x, z = toWorld(scene, u, v)
        table.insert(result.props, { kind = "sign", x = x, z = z, yaw = outwardYaw,
            width = TCAuctionScene.SIZES.sign.width, length = TCAuctionScene.SIZES.sign.length,
            face = TCAuctionScene.FACES.LOTS, lotFrom = row.lotFrom, lotTo = row.lotTo })
    end

    -- People looking at the lots: VIEW_SHARE of them have one or two in
    -- front, facing the lot.
    for rowIndex, row in ipairs(scene.rows or {}) do
        local facing = row.facing
        local v = row.frontV + facing * TCAuctionScene.VIEW_STANDOFF
        local yaw = yawOf(scene, 0, -facing)
        for slot, u in ipairs(row.slots or {}) do
            local roll = TCAuctionScene.hash(seed, 300 + rowIndex, slot)
            if roll < TCAuctionScene.VIEW_SHARE then
                groupCount = groupCount + 1
                local count = roll < TCAuctionScene.VIEW_SHARE * 0.4 and 2 or 1
                for p = 1, count do
                    local x, z = toWorld(scene, u + (p - 1.5) * 0.8 * (count - 1), v)
                    table.insert(result.spots, { x = x, z = z, yaw = yaw, category = TCAuctionScene.SPOT.LOT,
                        group = groupCount })
                end
            end
        end
    end

    -- The murmur: the food area's, and the middle of the lots.
    local midU = (scene.nearEdge + scene.farEdge) * 0.5
    local mx, mz = toWorld(scene, midU, (reserve.vFrom + reserve.vTo) * 0.5)
    table.insert(result.sounds, { x = mx, z = mz })
    return result
end

-- The crowd's walks (pure): the row aisles (135's walkways), each cut back
-- at its far end so it stops at the lots' far edge, and the two cross
-- aisles, near (in the entrance space) and far, as walkways of their own.
-- So people move between the rows, and no lane crosses another. Returns
-- walkways { x1, z1, x2, z2, halfWidth }.
function TCAuctionScene.getWalks(scene, walkways)
    local walks = {}
    if scene == nil or scene.reserve == nil then
        for _, walkway in ipairs(walkways or {}) do
            table.insert(walks, walkway)
        end
        return walks
    end
    local trim = (scene.endAisle or 0) * 0.5
    for _, walkway in ipairs(walkways or {}) do
        local dx, dz = walkway.x2 - walkway.x1, walkway.z2 - walkway.z1
        local length = math.sqrt(dx * dx + dz * dz)
        if length > trim + 1 then
            local keep = (length - trim) / length
            table.insert(walks, { x1 = walkway.x1, z1 = walkway.z1, x2 = walkway.x1 + dx * keep,
                z2 = walkway.z1 + dz * keep, halfWidth = walkway.halfWidth })
        end
    end
    local reserve = scene.reserve
    local function cross(u, halfWidth)
        local x1, z1 = toWorld(scene, u, reserve.vFrom)
        local x2, z2 = toWorld(scene, u, reserve.vTo)
        table.insert(walks, { x1 = x1, z1 = z1, x2 = x2, z2 = z2, halfWidth = halfWidth, isCross = true })
    end
    local aisleHalf = (scene.aisleWidth or 10) * 0.5
    cross(scene.nearEdge + scene.nearSign * aisleHalf, aisleHalf)
    if (scene.endAisle or 0) > 0 then
        cross(scene.farEdge - scene.nearSign * scene.endAisle * 0.5, scene.endAisle * 0.5)
    end
    return walks
end

-- The spots in the order the crowd fills them (pure): the gate's first
-- (they're there all day), then the food's (so even a small crowd has
-- people round it), then the rest a group at a time, taking the
-- categories in turn so a small crowd still spreads out. spots: layOut's
-- plus the aisles' groups (category nil). Returns a new list.
function TCAuctionScene.orderSpots(spots)
    local byCategory, categories = {}, {}
    local ordered, food = {}, {}
    for _, spot in ipairs(spots) do
        if spot.category == TCAuctionScene.SPOT.GATE then
            table.insert(ordered, spot)
        elseif spot.category == TCAuctionScene.SPOT.FOOD then
            table.insert(food, spot)
        else
            local key = spot.category or "aisle"
            if byCategory[key] == nil then
                byCategory[key] = {}
                table.insert(categories, key)
            end
            local groups = byCategory[key]
            local last = groups[#groups]
            if last == nil or spot.group == nil or last.group ~= spot.group then
                last = { group = spot.group, spots = {} }
                table.insert(groups, last)
            end
            table.insert(last.spots, spot)
        end
    end
    for _, spot in ipairs(food) do
        table.insert(ordered, spot)
    end
    local index = 1
    local any = true
    while any do
        any = false
        for _, key in ipairs(categories) do
            local group = byCategory[key][index]
            if group ~= nil then
                any = true
                for _, spot in ipairs(group.spots) do
                    table.insert(ordered, spot)
                end
            end
        end
        index = index + 1
    end
    return ordered
end
