-- Protest (151): the pure half. Where the farm's base is, which roads near
-- it the groups stand on, where each person stands in a group and whether
-- they hold a placard (and which), and who's there at what hour. Tested in
-- tests/test_protestLayout.lua. TheContractorProtest (the event) picks the
-- groups on the server; TCProtestCrowd puts the people, placards and
-- collision out on every machine from the incident's synced data.
--
-- A group is { x, z (the road's middle), dirX, dirZ (along the road,
-- towards the base, normalised), count }: a round crowd in the road,
-- centred on its middle. Everything
-- else comes from the incident's seed through TCProtestLayout.random, never
-- math.random, so every machine lays out the same people. Everyone's there
-- the whole time a protest is out (START_HOUR to END_HOUR, the server's
-- call): no coming and going through the day.

TCProtestLayout = {}

-- The day: out at START_HOUR, gone at END_HOUR (the server moves the
-- incident on and ends it then).
TCProtestLayout.START_HOUR = 7
TCProtestLayout.END_HOUR = 19

-- Groups and people.
TCProtestLayout.GROUPS_MIN = 2
TCProtestLayout.GROUPS_MAX = 3
TCProtestLayout.PEOPLE_MIN = 15
TCProtestLayout.PEOPLE_MAX = 20
-- The share holding a placard.
TCProtestLayout.PLACARD_SHARE = 0.7
-- The slogans on the placard atlas (genProtestPlacardI3d.py's SLOGANS).
TCProtestLayout.SLOGAN_COUNT = 17
-- The placards' styles (genProtestPlacardI3d.py's STYLES): 1 white card,
-- 2 a chalkboard. CHALK_SHARE of placards are chalkboards.
TCProtestLayout.STYLE_COUNT = 2
TCProtestLayout.STYLE = { CARD = 1, CHALK = 2 }
TCProtestLayout.CHALK_SHARE = 0.35

-- Where (metres). Road samples between MIN_DISTANCE and MAX_DISTANCE from
-- the base, nearest first; groups at least SPACING apart. A sample within
-- JUNCTION_DISTANCE of a road crossing or joining its own is a junction.
-- A parallel stretch of road spline (within PARALLEL_DOT, running either
-- way) LANE_PAIR_MIN to LANE_PAIR_DISTANCE straight across from a sample is
-- the road's other lane, and the road's middle is between them; the
-- nearest across wins. It may be the same spline: a map can draw one
-- spline up one lane and back down the other (seen in game: the crowd sat
-- on one lane while other splines alone were looked at). LANE_PAIR_MIN
-- keeps the sample's own lane out (its own points are about 0 across).
-- Samples are taken within LANE_PAIR_REACH along the road either way (over
-- half the samples' spacing, so the nearest is always seen: comparing
-- points alone missed a lane 4 m across, its nearest point 10 m along).
TCProtestLayout.MIN_DISTANCE = 60
TCProtestLayout.MAX_DISTANCE = 500
TCProtestLayout.SPACING = 100
TCProtestLayout.JUNCTION_DISTANCE = 15
TCProtestLayout.LANE_PAIR_DISTANCE = 7
TCProtestLayout.LANE_PAIR_MIN = 1
TCProtestLayout.LANE_PAIR_REACH = 12
TCProtestLayout.PARALLEL_DOT = 0.9

-- A group's people: scattered over a circle on the road's middle, as
-- big as gives each AREA_PER_PERSON (square metres): about 8 m across for
-- 20, so it fills the road and spills onto the verges. Each takes the first of up to SCATTER_TRIES spots (from the seed) at
-- least MIN_GAP from everyone placed so far, or the roomiest of them.
-- FACE_BASE_SHARE face along the road towards the base, the rest the other
-- way, each give or take YAW_JITTER (radians, 60 degrees).
TCProtestLayout.AREA_PER_PERSON = 2.6
TCProtestLayout.MIN_GAP = 0.9
TCProtestLayout.SCATTER_TRIES = 60
TCProtestLayout.YAW_JITTER = 1.05
TCProtestLayout.FACE_BASE_SHARE = 0.6

-- A fraction in [0, 1) from the seed and up to three whole numbers, the
-- same on every machine. TCAuctionScene.hash alone is affine in its
-- numbers: two picks that differ only in one of them move in step, so a
-- person's along and across picks fell on one line and the people stood in
-- file (seen in game). Its result is mixed here through a quadratic map
-- modulo MIX_PRIME (whole numbers below 2^53 throughout, so exact).
TCProtestLayout.MIX_PRIME = 1000003

function TCProtestLayout.random(seed, a, b, c)
    local P = TCProtestLayout.MIX_PRIME
    local h = math.floor(TCAuctionScene.hash(seed, a, b, c) * 2147483647)
    local x, y = h % P, math.floor(h / P) % P
    for round = 1, 3 do
        x = (x * x + y * 7 + 1013 + round) % P
        y = (y * y + x * 13 + 4093 + round) % P
    end
    return (x + y / P) / P
end

local hash = TCProtestLayout.random

-- The base ----------------------------------------------------------------------------

-- The farm's base from its own buildings: { farmlandId, x, z, isYard }
-- (isYard: a yard category, TheContractorYards.isYardCategory). The
-- farmland with the most yard buildings (then the most buildings, then the
-- lowest id), at the middle of its yard buildings (all of them if it has
-- none). Returns x, z, or nil with no buildings.
function TCProtestLayout.findBase(buildings)
    local groups = {}
    for _, building in ipairs(buildings) do
        local group = groups[building.farmlandId]
        if group == nil then
            group = { farmlandId = building.farmlandId, buildings = {}, yardCount = 0 }
            groups[building.farmlandId] = group
        end
        table.insert(group.buildings, building)
        if building.isYard then
            group.yardCount = group.yardCount + 1
        end
    end
    local best = nil
    for _, group in pairs(groups) do
        if best == nil or group.yardCount > best.yardCount or
                (group.yardCount == best.yardCount and (#group.buildings > #best.buildings or
                (#group.buildings == #best.buildings and group.farmlandId < best.farmlandId))) then
            best = group
        end
    end
    if best == nil then
        return nil, nil
    end
    local sumX, sumZ, count = 0, 0, 0
    for _, building in ipairs(best.buildings) do
        if building.isYard or best.yardCount == 0 then
            sumX, sumZ, count = sumX + building.x, sumZ + building.z, count + 1
        end
    end
    return sumX / count, sumZ / count
end

-- The roads ---------------------------------------------------------------------------

local function distance(ax, az, bx, bz)
    return math.sqrt((ax - bx) ^ 2 + (az - bz) ^ 2)
end

-- Whether another spline crosses or joins this sample's road nearby: a
-- sample of another spline within JUNCTION_DISTANCE that isn't parallel to
-- it (the other lane of the same road is).
function TCProtestLayout.isNearJunction(sample, samples)
    local T = TCProtestLayout
    for _, other in ipairs(samples) do
        if other.splineId ~= sample.splineId and
                distance(sample.x, sample.z, other.x, other.z) < T.JUNCTION_DISTANCE and
                math.abs(sample.dirX * other.dirX + sample.dirZ * other.dirZ) < T.PARALLEL_DOT then
            return true
        end
    end
    return false
end

-- The road's middle at a sample: halfway across to the road's other lane
-- (see LANE_PAIR_DISTANCE) where it has one, else the sample itself.
-- Returns x, z and whether another lane was found.
function TCProtestLayout.getRoadMiddle(sample, samples)
    local T = TCProtestLayout
    local rightX, rightZ = sample.dirZ, -sample.dirX
    local best, bestAcross = nil, math.huge
    for _, other in ipairs(samples) do
        if other ~= sample and
                math.abs(sample.dirX * other.dirX + sample.dirZ * other.dirZ) > T.PARALLEL_DOT then
            local dx, dz = other.x - sample.x, other.z - sample.z
            local along = math.abs(dx * sample.dirX + dz * sample.dirZ)
            -- Straight across to the other lane's line, wherever along it
            -- the sample falls.
            local across = (dx * rightX + dz * rightZ) - (dx * other.dirX + dz * other.dirZ) *
                (other.dirX * rightX + other.dirZ * rightZ)
            local size = math.abs(across)
            if along <= T.LANE_PAIR_REACH and size >= T.LANE_PAIR_MIN and size <= T.LANE_PAIR_DISTANCE and
                    size < bestAcross then
                best, bestAcross = across, size
            end
        end
    end
    if best == nil then
        return sample.x, sample.z, false
    end
    return sample.x + rightX * best * 0.5, sample.z + rightZ * best * 0.5, true
end

-- Where the groups go (server): up to wanted road samples ({ x, z, dirX,
-- dirZ, splineId }) between MIN_DISTANCE and MAX_DISTANCE from the base,
-- nearest first, none at a junction, each SPACING from the others, on a
-- road (spline) of its own where there are enough. isUsable(spot), if
-- given, is the engine's say (bridges, slopes, room) about the crowd's
-- spot: the sample moved to the road's middle. Returns the samples.
function TCProtestLayout.pickSpots(samples, baseX, baseZ, wanted, isUsable)
    local T = TCProtestLayout
    local candidates = {}
    for _, sample in ipairs(samples) do
        local d = distance(sample.x, sample.z, baseX, baseZ)
        if d >= T.MIN_DISTANCE and d <= T.MAX_DISTANCE then
            table.insert(candidates, { sample = sample, distance = d })
        end
    end
    table.sort(candidates, function(a, b)
        if a.distance ~= b.distance then
            return a.distance < b.distance
        end
        if a.sample.x ~= b.sample.x then
            return a.sample.x < b.sample.x
        end
        return a.sample.z < b.sample.z
    end)

    local picked = {}
    local rejected = {}
    local function isSpaced(sample)
        for _, other in ipairs(picked) do
            if distance(sample.x, sample.z, other.x, other.z) < T.SPACING then
                return false
            end
        end
        return true
    end
    local function onUsedRoad(sample)
        for _, other in ipairs(picked) do
            if other.splineId == sample.splineId then
                return true
            end
        end
        return false
    end
    -- First pass: a road each; second: any road.
    for pass = 1, 2 do
        for _, candidate in ipairs(candidates) do
            if #picked >= wanted then
                return picked
            end
            local sample = candidate.sample
            if not rejected[sample] and isSpaced(sample) and (pass == 2 or not onUsedRoad(sample)) then
                local mx, mz = TCProtestLayout.getRoadMiddle(sample, samples)
                local spot = { x = mx, y = sample.y, z = mz, dirX = sample.dirX, dirZ = sample.dirZ,
                    splineId = sample.splineId }
                if TCProtestLayout.isNearJunction(sample, samples) or (isUsable ~= nil and not isUsable(spot)) then
                    rejected[sample] = true
                else
                    table.insert(picked, sample)
                end
            end
        end
    end
    return picked
end

-- A group at a picked sample: on the road's middle, its way along the
-- road towards the base (the farm's traffic comes from there). paired:
-- whether the road's other lane was found (tcDebug protest shows it).
function TCProtestLayout.makeGroup(sample, samples, baseX, baseZ, count)
    local x, z, paired = TCProtestLayout.getRoadMiddle(sample, samples)
    local dirX, dirZ = sample.dirX, sample.dirZ
    local sign = 1
    if (baseX - x) * dirX + (baseZ - z) * dirZ < 0 then
        sign = -1
    end
    return { x = x, z = z, dirX = dirX * sign, dirZ = dirZ * sign, count = count, paired = paired }
end

-- The people ------------------------------------------------------------------------------

-- Slogan numbers (1 to SLOGAN_COUNT) in the group's order, shuffled from
-- the seed: none repeats until all have been used.
function TCProtestLayout.getSloganOrder(seed, groupIndex)
    local order = {}
    for i = 1, TCProtestLayout.SLOGAN_COUNT do
        order[i] = i
    end
    for i = #order, 2, -1 do
        local j = math.floor(hash(seed, groupIndex, 1000 + i) * i) + 1
        order[i], order[j] = order[j], order[i]
    end
    return order
end

-- The radius of a group's circle (metres).
function TCProtestLayout.getRadius(count)
    return math.sqrt(math.max(1, count) * TCProtestLayout.AREA_PER_PERSON / math.pi)
end

-- The group's scatter over its circle (pure): a list of { along, across }
-- from its middle (along the group's way, across to its right), see
-- SCATTER_TRIES. Spots are even over the circle's area (radius from the
-- square root).
function TCProtestLayout.scatter(count, seed, groupIndex)
    local T = TCProtestLayout
    local radius = TCProtestLayout.getRadius(count)
    local placed = {}
    for i = 1, count do
        local best, bestGap = nil, -1
        for try = 1, T.SCATTER_TRIES do
            local r = radius * math.sqrt(hash(seed, groupIndex, i * 100 + try, 1))
            local angle = 2 * math.pi * hash(seed, groupIndex, i * 100 + try, 2)
            local spot = { along = r * math.cos(angle), across = r * math.sin(angle) }
            local gap = math.huge
            for _, other in ipairs(placed) do
                gap = math.min(gap, math.sqrt((spot.along - other.along) ^ 2 + (spot.across - other.across) ^ 2))
            end
            if gap > bestGap then
                best, bestGap = spot, gap
            end
            if gap >= T.MIN_GAP then
                break
            end
        end
        table.insert(placed, best)
    end
    return placed
end

-- Where a group's people stand: a list of { x, z, yaw, slogan, style }
-- (slogan and style nil without a placard), yaw as MathUtil.getYRotationFromDirection's
-- (atan2(dirX, dirZ)). Scattered over a circle on the road's middle
-- (scatter), most facing the base's way, each their own way.
function TCProtestLayout.layOutGroup(group, seed, groupIndex)
    local T = TCProtestLayout
    local people = {}
    local count = group.count or 0
    local rightX, rightZ = group.dirZ, -group.dirX
    local baseYaw = math.atan2(group.dirX, group.dirZ)
    local slogans = TCProtestLayout.getSloganOrder(seed, groupIndex)
    local nextSlogan = 1
    for i, spot in ipairs(TCProtestLayout.scatter(count, seed, groupIndex)) do
        local yaw = baseYaw
        if hash(seed, groupIndex, i, 5) >= T.FACE_BASE_SHARE then
            yaw = yaw + math.pi
        end
        local person = {
            x = group.x + group.dirX * spot.along + rightX * spot.across,
            z = group.z + group.dirZ * spot.along + rightZ * spot.across,
            yaw = yaw + (hash(seed, groupIndex, i, 3) * 2 - 1) * T.YAW_JITTER,
        }
        if hash(seed, groupIndex, i, 4) < T.PLACARD_SHARE then
            person.slogan = slogans[(nextSlogan - 1) % #slogans + 1]
            nextSlogan = nextSlogan + 1
            person.style = hash(seed, groupIndex, i, 6) < T.CHALK_SHARE and T.STYLE.CHALK or T.STYLE.CARD
        end
        table.insert(people, person)
    end
    return people
end

-- Everyone in a protest, group by group, each with group (its index).
function TCProtestLayout.layOut(groups, seed)
    local people = {}
    for groupIndex, group in ipairs(groups) do
        for _, person in ipairs(TCProtestLayout.layOutGroup(group, seed, groupIndex)) do
            person.group = groupIndex
            table.insert(people, person)
        end
    end
    return people
end

-- The groups in an incident's flat data (data.groupCount, then g<n>_x,
-- _z, _dirX, _dirZ, _count), and back.
TCProtestLayout.GROUP_KEYS = { "x", "z", "dirX", "dirZ", "count", "paired" }

function TCProtestLayout.getGroups(data)
    local groups = {}
    for n = 1, data.groupCount or 0 do
        local group = {}
        for _, key in ipairs(TCProtestLayout.GROUP_KEYS) do
            group[key] = data[string.format("g%d_%s", n, key)]
        end
        table.insert(groups, group)
    end
    return groups
end

function TCProtestLayout.setGroups(data, groups)
    data.groupCount = #groups
    for n, group in ipairs(groups) do
        for _, key in ipairs(TCProtestLayout.GROUP_KEYS) do
            data[string.format("g%d_%s", n, key)] = group[key]
        end
    end
end
