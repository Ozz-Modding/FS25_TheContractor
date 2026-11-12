-- Auction roadside signs (136, spike): where an auction's signs go up, at
-- the map's busiest road junctions, giving the sale's date (no directions).
-- Pure: road points in, spots out, so it's tested outside the game
-- (tests/test_auctionSigns.lua). The server feeds it the AI road splines,
-- sampled (TheContractorAuctionSigns.sampleRoads), plus a check of its own
-- for whether a spot's clear.
--
--   The road network (buildNetwork): each spline a chain of points. A
--     spline's end within joinDistance of another spline's point is joined
--     to it, and two splines whose segments cross are joined where they
--     cross. Joined points are one place (a cluster).
--   Junctions: a cluster with three roads or more leaving it (arms). Arms
--     within armMergeDegrees of each other are one road (a map that draws
--     each lane as its own spline).
--   The best: the junctions with the most road within busyRadius of them
--     (in a village or a town, where the most people pass), then the most
--     arms.
--   A junction's sign stands approachDistance back along one of its arms
--     (the first whose verge has room), side on to the road and facing it,
--     so a driver coming in reads it as they pass and it takes little of
--     the verge's depth.
--   The verge: offset from the road's middle by each of vergeOffsets in
--     turn, the driver's side (DRIVE_SIDE) first, then the other. A spot
--     nearer than minRoadClearance to any road's middle is on a road, and
--     one with road all round it (isEnclosed: a roundabout's island) is
--     passed over too; the caller's
--     isClear says whether anything's in the way there.
--   The design: each spot is tried with each of the board's designs
--     (designs, the caller's ids; they're different widths), the one
--     after the last sign's first, so a map gets a mix, then the rest in
--     turn: a verge with room only for the narrower board gets that one.
--   Which: the best junctions first, one sign each, each junction at least
--     minSpacing from the signs already up (spread over the map), at most
--     maxSigns.
--
-- Directions are flat (x, z). A heading's left is (hz, -hx): a vehicle's +x
-- is its left in FS, and MathUtil.getYRotationFromDirection is atan2(dx,
-- dz).

TCAuctionSigns = {}

-- Metres, unless said.
TCAuctionSigns.RULES = {
    sampleStep = 8,           -- between a spline's points
    joinDistance = 8,         -- a spline's end this near another's point joins it
    armMergeDegrees = 25,     -- a junction's arms this close in direction are one road
    busyRadius = 250,         -- a junction's road counted within this
    busyCell = 50,            -- the grid the road's counted in
    approachDistance = 35,    -- a junction's sign this far back along the road a driver comes in on
    minApproach = 25,         -- an approach shorter than this (another junction, a roundabout's ring) gets none
    minThrough = 150,         -- the sign's road carries on at least this far past it (no dead ends)
    vergeOffsets = { 5, 4.25, 3.5 }, -- from the road's middle, tried in turn
    minRoadClearance = 3,     -- from any road's middle
    crossRoadClearance = 8,   -- from the middle of a road across the sign's own (a ring, a side road)
    crossRoadDegrees = 30,    -- a road this far off the sign's own direction is across it
    enclosedRadius = 30,      -- isEnclosed's rays: this long,
    enclosedRays = 16,        -- this many round the spot
    minSpacing = 400,         -- between signs
    maxSigns = 15,
    designs = { 1, 2 },       -- the boards a spot's tried with (TheContractorAuctionSigns.DESIGNS)
}

-- Vehicles drive on the right in FS: a sign goes on the driver's side first.
TCAuctionSigns.DRIVE_SIDE = "right"

-- Why a spot was passed over (the pick's rejected counts; the caller's
-- isClear adds its own reasons).
TCAuctionSigns.REJECT = {
    ON_ROAD = "onRoad",
    CROSS_ROAD = "crossRoad",
    DEAD_END = "deadEnd",
    ENCLOSED = "enclosed",
    TOO_CLOSE = "tooClose",
}

-- Vectors ----------------------------------------------------------------------------------

local function normalise(x, z)
    local length = math.sqrt(x * x + z * z)
    if length < 0.0001 then
        return 0, 0
    end
    return x / length, z / length
end

function TCAuctionSigns.leftOf(hx, hz)
    return hz, -hx
end

function TCAuctionSigns.rightOf(hx, hz)
    return -hz, hx
end

-- A board facing (fx, fz) (its front's normal): the model's yaw, its front
-- being +Z.
function TCAuctionSigns.getYaw(fx, fz)
    return math.atan2(fx, fz)
end

-- The road network ---------------------------------------------------------------------------

-- A grid of the nodes, for finding near ones.
local function cellKey(x, z, size)
    return math.floor(x / size) .. ":" .. math.floor(z / size)
end

local function buildGrid(nodes, size)
    local grid = {}
    for index, node in ipairs(nodes) do
        local key = cellKey(node.x, node.z, size)
        grid[key] = grid[key] or {}
        table.insert(grid[key], index)
    end
    return grid
end

-- Every node index within distance of (x, z), from the grid.
local function nearNodes(grid, size, nodes, x, z, distance)
    local found = {}
    local cx, cz = math.floor(x / size), math.floor(z / size)
    local reach = math.ceil(distance / size)
    for i = cx - reach, cx + reach do
        for j = cz - reach, cz + reach do
            for _, index in ipairs(grid[i .. ":" .. j] or {}) do
                local node = nodes[index]
                if (node.x - x) ^ 2 + (node.z - z) ^ 2 <= distance * distance then
                    table.insert(found, index)
                end
            end
        end
    end
    return found
end

local function segmentsCross(ax, az, bx, bz, cx, cz, dx, dz)
    local rx, rz = bx - ax, bz - az
    local sx, sz = dx - cx, dz - cz
    local denominator = rx * sz - rz * sx
    if math.abs(denominator) < 0.000001 then
        return false
    end
    local t = ((cx - ax) * sz - (cz - az) * sx) / denominator
    local u = ((cx - ax) * rz - (cz - az) * rx) / denominator
    return t >= 0 and t <= 1 and u >= 0 and u <= 1
end

local function find(parent, i)
    while parent[i] ~= i do
        parent[i] = parent[parent[i]]
        i = parent[i]
    end
    return i
end

local function addEdge(nodes, a, b, isJoin)
    local length = math.sqrt((nodes[a].x - nodes[b].x) ^ 2 + (nodes[a].z - nodes[b].z) ^ 2)
    table.insert(nodes[a].edges, { to = b, length = length, isJoin = isJoin })
    table.insert(nodes[b].edges, { to = a, length = length, isJoin = isJoin })
end

-- splines: { { { x, z, y? }, ... }, ... }, each a spline's points in order.
-- Returns the network: nodes ({ x, z, y, spline, index, isEnd, edges,
-- cluster }), clusters (cluster id -> { nodes, x, z }), grid and its cell
-- size.
function TCAuctionSigns.buildNetwork(splines)
    local R = TCAuctionSigns.RULES
    local nodes = {}
    for splineIndex, points in ipairs(splines) do
        local first = #nodes + 1
        for i, point in ipairs(points) do
            table.insert(nodes, {
                x = point.x, z = point.z, y = point.y, spline = splineIndex, index = i,
                isEnd = i == 1 or i == #points, edges = {},
            })
            if i > 1 then
                addEdge(nodes, first + i - 2, first + i - 1, false)
            end
        end
    end

    local size = math.max(R.joinDistance, R.sampleStep) * 2
    local grid = buildGrid(nodes, size)
    local parent = {}
    for i = 1, #nodes do
        parent[i] = i
    end
    local joined = {}
    local function join(a, b)
        local key = math.min(a, b) .. ":" .. math.max(a, b)
        if a == b or joined[key] then
            return
        end
        joined[key] = true
        addEdge(nodes, a, b, true)
        parent[find(parent, a)] = find(parent, b)
    end

    -- A spline's end near another spline's point: joined to its nearest one
    -- on each other spline.
    for index, node in ipairs(nodes) do
        if node.isEnd then
            local nearest = {}
            for _, other in ipairs(nearNodes(grid, size, nodes, node.x, node.z, R.joinDistance)) do
                local otherNode = nodes[other]
                if otherNode.spline ~= node.spline then
                    local distance = (otherNode.x - node.x) ^ 2 + (otherNode.z - node.z) ^ 2
                    local best = nearest[otherNode.spline]
                    if best == nil or distance < best.distance then
                        nearest[otherNode.spline] = { index = other, distance = distance }
                    end
                end
            end
            for _, best in pairs(nearest) do
                join(index, best.index)
            end
        end
    end

    -- Splines crossing: the segments' nearer ends joined.
    for index, node in ipairs(nodes) do
        local nextIndex = index + 1
        local nextNode = nodes[nextIndex]
        if nextNode ~= nil and nextNode.spline == node.spline then
            local mx, mz = (node.x + nextNode.x) * 0.5, (node.z + nextNode.z) * 0.5
            for _, other in ipairs(nearNodes(grid, size, nodes, mx, mz, R.sampleStep * 1.5)) do
                local otherNode, otherNext = nodes[other], nodes[other + 1]
                if otherNode.spline ~= node.spline and otherNext ~= nil and otherNext.spline == otherNode.spline and
                        segmentsCross(node.x, node.z, nextNode.x, nextNode.z, otherNode.x, otherNode.z, otherNext.x,
                            otherNext.z) then
                    local a = index
                    if (nextNode.x - otherNode.x) ^ 2 + (nextNode.z - otherNode.z) ^ 2 <
                            (node.x - otherNode.x) ^ 2 + (node.z - otherNode.z) ^ 2 then
                        a = nextIndex
                    end
                    local b = other
                    if (otherNext.x - nodes[a].x) ^ 2 + (otherNext.z - nodes[a].z) ^ 2 <
                            (otherNode.x - nodes[a].x) ^ 2 + (otherNode.z - nodes[a].z) ^ 2 then
                        b = other + 1
                    end
                    join(a, b)
                end
            end
        end
    end

    local clusters = {}
    for index, node in ipairs(nodes) do
        local root = find(parent, index)
        node.cluster = root
        local cluster = clusters[root]
        if cluster == nil then
            cluster = { id = root, nodes = {} }
            clusters[root] = cluster
        end
        table.insert(cluster.nodes, index)
    end
    for _, cluster in pairs(clusters) do
        local sx, sz = 0, 0
        for _, index in ipairs(cluster.nodes) do
            sx, sz = sx + nodes[index].x, sz + nodes[index].z
        end
        cluster.x, cluster.z = sx / #cluster.nodes, sz / #cluster.nodes
    end
    return { nodes = nodes, clusters = clusters, grid = grid, cellSize = size }
end

-- A cluster's arms: the roads leaving it, as { from, node, dirX, dirZ }
-- (from a node in the cluster to its neighbour outside it), those within
-- armMergeDegrees of each other merged (the first kept, with every node it
-- stands for in merged).
function TCAuctionSigns.getArms(network, cluster)
    local nodes = network.nodes
    local arms = {}
    local cosMerge = math.cos(math.rad(TCAuctionSigns.RULES.armMergeDegrees))
    for _, index in ipairs(cluster.nodes) do
        for _, edge in ipairs(nodes[index].edges) do
            local to = nodes[edge.to]
            if to.cluster ~= cluster.id then
                local dirX, dirZ = normalise(to.x - cluster.x, to.z - cluster.z)
                local merged = false
                for _, arm in ipairs(arms) do
                    if arm.dirX * dirX + arm.dirZ * dirZ >= cosMerge then
                        table.insert(arm.merged, edge.to)
                        merged = true
                        break
                    end
                end
                if not merged then
                    table.insert(arms, { from = index, node = edge.to, dirX = dirX, dirZ = dirZ, merged = { edge.to } })
                end
            end
        end
    end
    return arms
end

-- Whether a point is nearer than minRoadClearance to any road's middle.
local function isOnRoad(network, x, z)
    local R = TCAuctionSigns.RULES
    local nodes = network.nodes
    -- Nodes are sampleStep apart, so the nearest segment is checked too.
    for _, index in ipairs(nearNodes(network.grid, network.cellSize, nodes, x, z, R.minRoadClearance + R.sampleStep)) do
        local a = nodes[index]
        for _, edge in ipairs(a.edges) do
            local b = nodes[edge.to]
            local abx, abz = b.x - a.x, b.z - a.z
            local lengthSq = abx * abx + abz * abz
            local t = lengthSq > 0 and math.max(0, math.min(1, ((x - a.x) * abx + (z - a.z) * abz) / lengthSq)) or 0
            local px, pz = a.x + abx * t, a.z + abz * t
            if (x - px) ^ 2 + (z - pz) ^ 2 < R.minRoadClearance ^ 2 then
                return true
            end
        end
    end
    return false
end

local function distanceBetween(a, b)
    return math.sqrt((a.x - b.x) ^ 2 + (a.z - b.z) ^ 2)
end

-- Walks back along an arm from its junction for approachDistance: the node
-- it stops at, how far that is, and the node before it (towards the
-- junction). Stops a node short of another junction, or at the road's end.
local function walkApproach(network, arm, junctionIds)
    local nodes = network.nodes
    local R = TCAuctionSigns.RULES
    local path = { arm.from, arm.node }
    local walked = { 0, distanceBetween(nodes[arm.from], nodes[arm.node]) }
    local startCluster = nodes[arm.from].cluster
    while walked[#path] < R.approachDistance do
        local current, previous = path[#path], path[#path - 1]
        if junctionIds[nodes[current].cluster] and nodes[current].cluster ~= startCluster then
            -- Another junction: the sign goes a node short of it.
            table.remove(path)
            table.remove(walked)
            break
        end
        local nextIndex = nil
        for _, edge in ipairs(nodes[current].edges) do
            local to = nodes[edge.to]
            if edge.to ~= previous and to.cluster ~= startCluster and to.cluster ~= nodes[previous].cluster then
                nextIndex = edge.to
                break
            end
        end
        if nextIndex == nil then
            break
        end
        table.insert(path, nextIndex)
        table.insert(walked, walked[#walked] + distanceBetween(nodes[current], nodes[nextIndex]))
    end
    if #path < 2 then
        return nil, 0, nil
    end
    return path[#path], walked[#path], path[#path - 1]
end

-- How much road is near each junction: the network's points counted in a
-- coarse grid, summed over the cells within busyRadius, as metres.
local function setBusyMetres(network, junctions)
    local R = TCAuctionSigns.RULES
    local size = R.busyCell
    local counts = {}
    for _, node in ipairs(network.nodes) do
        local key = cellKey(node.x, node.z, size)
        counts[key] = (counts[key] or 0) + 1
    end
    local reach = math.ceil(R.busyRadius / size)
    for _, junction in ipairs(junctions) do
        local x, z = junction.cluster.x, junction.cluster.z
        local cx, cz = math.floor(x / size), math.floor(z / size)
        local count = 0
        for i = cx - reach, cx + reach do
            for j = cz - reach, cz + reach do
                local mx, mz = (i + 0.5) * size, (j + 0.5) * size
                if (mx - x) ^ 2 + (mz - z) ^ 2 <= R.busyRadius * R.busyRadius then
                    count = count + (counts[i .. ":" .. j] or 0)
                end
            end
        end
        junction.busyMetres = count * R.sampleStep
    end
end

-- Every junction, the best first (see the header), as { cluster, arms,
-- busyMetres }, plus the junctions' cluster ids (id -> true).
function TCAuctionSigns.findJunctions(network)
    local junctions, junctionIds = {}, {}
    for id, cluster in pairs(network.clusters) do
        local arms = TCAuctionSigns.getArms(network, cluster)
        if #arms >= 3 then
            junctionIds[id] = true
            table.insert(junctions, { cluster = cluster, arms = arms })
        end
    end
    setBusyMetres(network, junctions)
    table.sort(junctions, function(a, b)
        if a.busyMetres ~= b.busyMetres then
            return a.busyMetres > b.busyMetres
        end
        if #a.arms ~= #b.arms then
            return #a.arms > #b.arms
        end
        return a.cluster.id < b.cluster.id
    end)
    return junctions, junctionIds
end

-- Picking -----------------------------------------------------------------------------------

local function isSpaced(x, z, picked)
    local spacing = TCAuctionSigns.RULES.minSpacing
    for _, sign in ipairs(picked) do
        if (sign.x - x) ^ 2 + (sign.z - z) ^ 2 < spacing * spacing then
            return false
        end
    end
    return true
end

local function countReject(rejected, reason)
    reason = reason or "blocked"
    rejected[reason] = (rejected[reason] or 0) + 1
end

-- Whether a spot has road all round it (pure): a roundabout's island. A
-- ray every enclosedRays round the spot, enclosedRadius long: enclosed
-- when every one crosses a road. On a verge the rays along the road cross
-- nothing, whatever's behind it (another street, a village's next block).
-- (AI splines run round an island but never over it, so isOnRoad misses
-- it.)
function TCAuctionSigns.isEnclosed(network, x, z)
    local R = TCAuctionSigns.RULES
    local nodes = network.nodes
    local radius = R.enclosedRadius
    local near = nearNodes(network.grid, network.cellSize, nodes, x, z, radius + R.sampleStep)
    for i = 0, R.enclosedRays - 1 do
        local angle = 2 * math.pi * i / R.enclosedRays
        local ex, ez = x + math.cos(angle) * radius, z + math.sin(angle) * radius
        local hit = false
        for _, index in ipairs(near) do
            local a = nodes[index]
            for _, edge in ipairs(a.edges) do
                local b = nodes[edge.to]
                if segmentsCross(x, z, ex, ez, a.x, a.z, b.x, b.z) then
                    hit = true
                    break
                end
            end
            if hit then
                break
            end
        end
        if not hit then
            return false
        end
    end
    return true
end

-- Whether a road across the sign's own (heading hx, hz) passes nearer than
-- crossRoadClearance to (x, z) (pure). A road's middle line can be well
-- inside its tarmac (a roundabout's wide ring), so one crossing the sign's
-- road keeps further off than minRoadClearance; one alongside (the other
-- lane's spline) is isOnRoad's.
function TCAuctionSigns.isNearCrossRoad(network, x, z, hx, hz)
    local R = TCAuctionSigns.RULES
    local nodes = network.nodes
    local cosAcross = math.cos(math.rad(R.crossRoadDegrees))
    local clearance = R.crossRoadClearance
    for _, index in ipairs(nearNodes(network.grid, network.cellSize, nodes, x, z, clearance + R.sampleStep)) do
        local a = nodes[index]
        for _, edge in ipairs(a.edges) do
            local b = nodes[edge.to]
            local abx, abz = b.x - a.x, b.z - a.z
            local lengthSq = abx * abx + abz * abz
            if lengthSq > 0.0001 then
                local length = math.sqrt(lengthSq)
                if math.abs((abx * hx + abz * hz) / length) < cosAcross then
                    local t = math.max(0, math.min(1, ((x - a.x) * abx + (z - a.z) * abz) / lengthSq))
                    local px, pz = a.x + abx * t, a.z + abz * t
                    if (x - px) ^ 2 + (z - pz) ^ 2 < clearance * clearance then
                        return true
                    end
                end
            end
        end
    end
    return false
end

-- Whether the road carries on minThrough past node at (pure), away from
-- the node before it (back towards the junction) and the junction itself:
-- a drive or a yard's spur that stops short is a dead end.
function TCAuctionSigns.leadsOn(network, at, back, startCluster)
    local R = TCAuctionSigns.RULES
    local nodes = network.nodes
    local best = { [at] = 0, [back] = math.huge }
    local stack = { at }
    while #stack > 0 do
        local index = table.remove(stack)
        local walked = best[index]
        if walked >= R.minThrough then
            return true
        end
        for _, edge in ipairs(nodes[index].edges) do
            local to = edge.to
            if nodes[to].cluster ~= startCluster then
                local further = walked + distanceBetween(nodes[index], nodes[to])
                if best[to] == nil or further < best[to] then
                    best[to] = further
                    table.insert(stack, to)
                end
            end
        end
    end
    return false
end

-- The designs in the order a sign tries them: the one after the last
-- sign's (the first if there's none yet), then on round.
local function getDesignOrder(signs)
    local designs = TCAuctionSigns.RULES.designs
    local first = 1
    local last = signs[#signs]
    if last ~= nil then
        for i, design in ipairs(designs) do
            if design == last.design then
                first = i % #designs + 1
            end
        end
    end
    local order = {}
    for i = 0, #designs - 1 do
        table.insert(order, designs[(first - 1 + i) % #designs + 1])
    end
    return order
end

-- The first verge spot that works for a sign by road point (roadX, roadZ):
-- sides in order, each at every verge offset, each with every design in
-- designOrder. base: the sign's other values; each spot's x, z, side,
-- offset, yaw (facing the road) and design are added.
local function placeOnVerge(network, roadX, roadZ, sides, base, isClear, rejected, hx, hz, designOrder)
    for _, side in ipairs(sides) do
        for _, offset in ipairs(TCAuctionSigns.RULES.vergeOffsets) do
            local x = roadX + side.x * offset
            local z = roadZ + side.z * offset
            if isOnRoad(network, x, z) then
                countReject(rejected, TCAuctionSigns.REJECT.ON_ROAD)
            elseif TCAuctionSigns.isNearCrossRoad(network, x, z, hx, hz) then
                countReject(rejected, TCAuctionSigns.REJECT.CROSS_ROAD)
            elseif TCAuctionSigns.isEnclosed(network, x, z) then
                countReject(rejected, TCAuctionSigns.REJECT.ENCLOSED)
            else
                for _, design in ipairs(designOrder) do
                    local candidate = {}
                    for key, value in pairs(base) do
                        candidate[key] = value
                    end
                    candidate.x, candidate.z, candidate.side, candidate.offset = x, z, side.name, offset
                    candidate.yaw = TCAuctionSigns.getYaw(-side.x, -side.z)
                    candidate.design = design
                    local clear, reason = isClear(candidate)
                    if clear then
                        return candidate
                    end
                    countReject(rejected, reason)
                end
            end
        end
    end
    return nil
end

-- The driver's side, then the other, for someone heading (hx, hz).
local function getSides(hx, hz)
    local rx, rz = TCAuctionSigns.rightOf(hx, hz)
    local right = { name = "right", x = rx, z = rz }
    local left = { name = "left", x = -rx, z = -rz }
    if TCAuctionSigns.DRIVE_SIDE == "right" then
        return { right, left }
    end
    return { left, right }
end

-- The signs for the map. splines: as buildNetwork's. isClear(candidate):
-- true, or false and a reason, for a spot (the caller's checks: anything in
-- the way, steep, a field, water). Returns { signs, junctionCount, rejected
-- (reason -> count) }, each sign { x, z, yaw, design, side, offset, roadX,
-- roadZ, roadY, junctionX, junctionZ, busyMetres }.
function TCAuctionSigns.pick(splines, isClear)
    local R = TCAuctionSigns.RULES
    local result = { signs = {}, junctionCount = 0, rejected = {} }
    local network = TCAuctionSigns.buildNetwork(splines)
    local junctions, junctionIds = TCAuctionSigns.findJunctions(network)
    result.junctionCount = #junctions
    local signs, rejected = result.signs, result.rejected
    local nodes = network.nodes
    for _, junction in ipairs(junctions) do
        if #signs >= R.maxSigns then
            break
        end
        if not isSpaced(junction.cluster.x, junction.cluster.z, signs) then
            countReject(rejected, TCAuctionSigns.REJECT.TOO_CLOSE)
        else
            for _, arm in ipairs(junction.arms) do
                local at, walked, towards = walkApproach(network, arm, junctionIds)
                if walked >= R.minApproach and towards ~= nil and
                        not TCAuctionSigns.leadsOn(network, at, towards, junction.cluster.id) then
                    countReject(rejected, TCAuctionSigns.REJECT.DEAD_END)
                elseif walked >= R.minApproach and towards ~= nil then
                    local node = nodes[at]
                    -- The driver's heading here, towards the junction.
                    local hx, hz = normalise(nodes[towards].x - node.x, nodes[towards].z - node.z)
                    local base = {
                        roadX = node.x, roadZ = node.z, roadY = node.y,
                        junctionX = junction.cluster.x, junctionZ = junction.cluster.z,
                        busyMetres = junction.busyMetres,
                    }
                    local spot = placeOnVerge(network, node.x, node.z, getSides(hx, hz), base, isClear, rejected,
                        hx, hz, getDesignOrder(signs))
                    if spot ~= nil then
                        table.insert(signs, spot)
                        break
                    end
                end
            end
        end
    end
    return result
end
