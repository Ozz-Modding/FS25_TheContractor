-- Farm yards (108, a spike): where the map's unbought farms are, so the
-- generated farmers (109, 110) can be given one.
--
-- Vanilla ties a map's buildings to land through placeables: a placeable
-- that's bought with its farmland changes hands with the farmland under
-- its root node. A map's buildings are either preplaced (nodes in its i3d)
-- or default placeables (its placeables XML, loaded into a new savegame
-- like any other placeable, so not flagged preplaced); both count. So an
-- unbought farm on the map is a farmland with bought-with-farmland
-- buildings on it. A
-- farmland is a yard when at least MIN_BUILDINGS of those are in
-- YARD_CATEGORIES (store categories), at least one of them a shed or a
-- farmhouse (ANCHOR_CATEGORIES) and one not a farmhouse (a working
-- building), with no more than MAX_FARMHOUSES farmhouses (more is a
-- village). The yard sits in the middle of its
-- yard buildings.
--
-- Detection runs on the live map every time it's asked for, on every
-- machine (preplaced placeables are the same everywhere), and nothing
-- detected is saved. The player's overrides (a farmland declared a yard,
-- or ruled out) are server-wide, saved and synced (TCYardOverrideEvent),
-- because farmers are shared by every farm.
--
-- Each yard has open standing spots for 114's farmer: points along the
-- edges of its buildings' placement footprints, stepping outwards, and a
-- ring round its middle, kept if they're on the yard's farmland, outdoors
-- (vanilla's indoor mask), clear of anything solid, gently sloped, off the fields, outside every building's
-- footprint and on the AI navigation map. The navigation map only exists
-- on the server, and vehicles and the like come and go, so the spots 114's
-- farmers stand on are the server's: worked out once a load (setUp) and
-- again when a farmland's override changes, kept in memory (not saved) and
-- sent to the clients (initial client state, TCYardSpotsEvent).
--
-- tcCompany yards (and yard) is the spike's way in, with map markers on
-- this machine only. The host or an admin can also set or unset a yard
-- from a farmland's box on the in-game map (117, TCYardMapAction).

TheContractorYards = {}
TheContractorYards_mt = Class(TheContractorYards)

-- A farmland needs this many buildings in YARD_CATEGORIES to be a yard.
TheContractorYards.MIN_BUILDINGS = 2

-- Store categories (upper case, as vanilla keeps them) that count towards
-- a yard. A first cut: tcCompany yards lists every category it finds, so
-- this can be set from real maps.
TheContractorYards.YARD_CATEGORIES = {
    SHEDS = true,
    SILOS = true,
    SILOEXTENSIONS = true,
    ANIMALPENS = true,
    FARMHOUSES = true,
    BUILDINGS = true,
    STORAGES = true,
    WORKSHOPS = true,
}

-- More farmhouses than this on a farmland is a village or a town, not a
-- farm.
TheContractorYards.MAX_FARMHOUSES = 5

-- A yard needs at least one of these among them: a farm has a shed or a
-- farmhouse, where a few silos on their own are just a store.
TheContractorYards.ANCHOR_CATEGORIES = {
    SHEDS = true,
    FARMHOUSES = true,
}

-- An override's mode. AUTO (none) is never stored.
TheContractorYards.MODE = { AUTO = 0, ON = 1, OFF = 2 }
TheContractorYards.MODE_NAMES = { [0] = "auto", [1] = "on", [2] = "off" }

-- Standing spots ---------------------------------------------------------

-- Metres between candidate points along a footprint's edge.
TheContractorYards.EDGE_STEP = 4
-- How far out from a footprint's edge candidates go.
TheContractorYards.EDGE_OFFSETS = { 2, 5, 9 }
-- Rings round the yard's middle: radii, and points per ring.
TheContractorYards.RING_RADII = { 12, 20, 30 }
TheContractorYards.RING_POINTS = 12
-- A building without a footprint gets a ring of its own at this radius.
TheContractorYards.BUILDING_RING_RADIUS = 10
-- Kept spots are at least this far apart.
TheContractorYards.SPOT_SEPARATION = 3
-- Most spots a yard keeps, spread over all the open ones it finds.
TheContractorYards.MAX_SPOTS = 40
-- 114: a spot this close (metres) to a farmhouse (its footprint, or its
-- position without one) is near the house, which its farmer favours.
TheContractorYards.NEAR_HOUSE_DISTANCE = 15
TheContractorYards.HOUSE_CATEGORY = "FARMHOUSES"
-- The box a person needs to stand: half width and height (metres), from
-- just above the ground.
TheContractorYards.SPOT_HALF_SIZE = 0.75
TheContractorYards.SPOT_HEIGHT = 1.8
TheContractorYards.SPOT_GROUND_GAP = 0.15
-- Steepest ground a spot can be on (rise over run), measured over
-- SLOPE_SAMPLE metres either side.
TheContractorYards.MAX_SLOPE = 0.2
TheContractorYards.SLOPE_SAMPLE = 1

local SPOT_MASK = CollisionFlag ~= nil and (CollisionFlag.STATIC_OBJECT + CollisionFlag.BUILDING +
    CollisionFlag.TREE + CollisionFlag.VEHICLE + CollisionFlag.DYNAMIC_OBJECT + CollisionFlag.TRAFFIC_VEHICLE +
    CollisionFlag.ANIMAL + CollisionFlag.WATER) or 0

-- Map markers (this machine only) ------------------------------------------

TheContractorYards.YARD_MARKER_RADIUS = 30
TheContractorYards.SPOT_MARKER_RADIUS = 2
-- Checking which way farmhouses face (show <farmlandId>): a big circle this
-- far out along the house's own +Z, and a small one on its spawn node.
TheContractorYards.FORWARD_MARKER_DISTANCE = 10
TheContractorYards.FORWARD_MARKER_RADIUS = 4
TheContractorYards.SPAWN_MARKER_RADIUS = 1

function TheContractorYards.new()
    local self = {}
    setmetatable(self, TheContractorYards_mt)

    -- farmlandId -> MODE.ON / MODE.OFF
    self.overrides = {}

    -- 114: farmlandId -> { x, z (the yard's middle), spots = { { x, z, nearHouse }, ... } }
    -- for every yard, the server's, synced in this order.
    self.spots = {}

    -- Map markers: nil when off, else { farmlandId = shown yard or nil,
    -- hotspots = { ... } }.
    self.markers = nil

    return self
end

-- Detection (pure, given the placeables) ----------------------------------

local function isBoughtWithFarmland(placeable)
    if placeable.boughtWithFarmlandSavegameOverwrite ~= nil then
        return placeable.boughtWithFarmlandSavegameOverwrite
    end
    return placeable.boughtWithFarmland == true
end

-- Whether any of the placeable's unloading stations sells, and whether any
-- just takes a load in (a silo, an animal pen's feed).
local function getStations(placeable)
    local sells = placeable.spec_sellingStation ~= nil
    local unloads = false
    local storageSystem = g_currentMission.storageSystem
    local stations = storageSystem ~= nil and storageSystem.placeableUnloadingStations ~= nil and
        storageSystem.placeableUnloadingStations[placeable] or nil
    for _, station in ipairs(stations or {}) do
        if station.isSellingPoint then
            sells = true
        else
            unloads = true
        end
    end
    return sells, unloads
end

-- The corners, in order round the edge, of each of the placeable's
-- placement test areas where it stands.
local function getFootprints(placeable)
    local footprints = {}
    local spec = placeable.spec_placement
    if spec == nil or spec.testAreas == nil or placeable.getTestParallelogramAtWorldPosition == nil or
            placeable.rootNode == nil then
        return footprints
    end
    local x, _, z = getWorldTranslation(placeable.rootNode)
    local _, rotY, _ = getWorldRotation(placeable.rootNode)
    for _, area in ipairs(spec.testAreas) do
        local x1, z1, x2, z2, x3, z3, x4, z4 = placeable:getTestParallelogramAtWorldPosition(area, x, z, rotY)
        -- start, width end, height end, far corner: round the edge it's
        -- start, width end, far corner, height end.
        table.insert(footprints, { { x = x1, z = z1 }, { x = x2, z = z2 }, { x = x4, z = z4 }, { x = x3, z = z3 } })
    end
    return footprints
end

-- Why detection leaves a placeable out (EXCLUSION). A map's buildings can
-- be preplaced (nodes in the map's i3d) or default placeables (the map's
-- placeables XML, loaded into a new savegame like any other): either way
-- what makes one part of a farm is that it changes hands with its land.
TheContractorYards.EXCLUSION = {
    DELETED = "deleted",
    -- Its store item's setting: it stays put whoever owns the land.
    NOT_BOUGHT = "notBoughtWithFarmland",
    -- The map's placeables XML, or the savegame, overrides it to not bought.
    SAVE_NOT_BOUGHT = "saveNotBoughtWithFarmland",
    NO_FARMLAND = "noFarmland",
}

-- Every reason detection leaves the placeable out (EXCLUSIONs), empty if
-- it's a building bought with a valid farmland.
function TheContractorYards.getExclusions(placeable)
    local exclusion = TheContractorYards.EXCLUSION
    local exclusions = {}
    if placeable.isDeleted or placeable.isDeleting then
        table.insert(exclusions, exclusion.DELETED)
    end
    if not isBoughtWithFarmland(placeable) then
        table.insert(exclusions, placeable.boughtWithFarmlandSavegameOverwrite == false and
            exclusion.SAVE_NOT_BOUGHT or exclusion.NOT_BOUGHT)
    end
    if placeable.getFarmlandId == nil or not g_farmlandManager:getIsValidFarmlandId(placeable:getFarmlandId()) then
        table.insert(exclusions, exclusion.NO_FARMLAND)
    end
    return exclusions
end

local function getNameAndCategory(placeable)
    local storeItem = placeable.storeItem
    local category = storeItem ~= nil and storeItem.categoryName or nil
    local name = placeable.getName ~= nil and placeable:getName() or nil
    if name == nil and storeItem ~= nil then
        name = storeItem.name
    end
    return name or "?", string.upper(category or "UNKNOWN")
end

-- What detection needs to know about a placeable, or nil if it isn't a
-- building bought with a valid farmland.
function TheContractorYards.describePlaceable(placeable)
    if #TheContractorYards.getExclusions(placeable) > 0 then
        return nil
    end
    local farmlandId = placeable:getFarmlandId()
    local name, category = getNameAndCategory(placeable)
    local x, _, z = placeable:getPosition()
    local sells, unloads = getStations(placeable)

    return {
        placeable = placeable,
        farmlandId = farmlandId,
        category = category,
        name = name,
        x = x,
        z = z,
        hasSellingStation = sells,
        hasUnloadingStation = unloads,
        footprints = getFootprints(placeable),
    }
end

function TheContractorYards.isYardCategory(category)
    return TheContractorYards.YARD_CATEGORIES[category] == true
end

-- farmlandId -> { farmlandId, buildings, yardBuildingCount, anchorCount,
-- houseCount, workingCount (yard buildings that aren't farmhouses),
-- categories = { [category] = count } } for every farmland with candidate
-- buildings.
function TheContractorYards.groupByFarmland(buildings)
    local groups = {}
    for _, building in ipairs(buildings) do
        local group = groups[building.farmlandId]
        if group == nil then
            group = { farmlandId = building.farmlandId, buildings = {}, yardBuildingCount = 0, anchorCount = 0,
                houseCount = 0, workingCount = 0, categories = {} }
            groups[building.farmlandId] = group
        end
        table.insert(group.buildings, building)
        group.categories[building.category] = (group.categories[building.category] or 0) + 1
        if TheContractorYards.isYardCategory(building.category) then
            group.yardBuildingCount = group.yardBuildingCount + 1
            if building.category == TheContractorYards.HOUSE_CATEGORY then
                group.houseCount = group.houseCount + 1
            else
                group.workingCount = group.workingCount + 1
            end
        end
        if TheContractorYards.ANCHOR_CATEGORIES[building.category] then
            group.anchorCount = group.anchorCount + 1
        end
    end
    return groups
end

function TheContractorYards.isYardByRule(group)
    return #TheContractorYards.getRuleFailures(group) == 0
end

-- Why the group fails the yard rule: a list of RULE_FAILURE, empty if it
-- passes.
TheContractorYards.RULE_FAILURE = {
    NO_BUILDINGS = "noBuildings",
    TOO_FEW_YARD_BUILDINGS = "tooFewYardBuildings",
    NO_ANCHOR = "noAnchor",
    NO_WORKING_BUILDING = "noWorkingBuilding",
    TOO_MANY_HOUSES = "tooManyHouses",
}

function TheContractorYards.getRuleFailures(group)
    local failure = TheContractorYards.RULE_FAILURE
    if group == nil then
        return { failure.NO_BUILDINGS }
    end
    local failures = {}
    if group.yardBuildingCount < TheContractorYards.MIN_BUILDINGS then
        table.insert(failures, failure.TOO_FEW_YARD_BUILDINGS)
    end
    if group.anchorCount == 0 then
        table.insert(failures, failure.NO_ANCHOR)
    end
    if group.workingCount == 0 then
        table.insert(failures, failure.NO_WORKING_BUILDING)
    end
    if group.houseCount > TheContractorYards.MAX_FARMHOUSES then
        table.insert(failures, failure.TOO_MANY_HOUSES)
    end
    return failures
end

-- The placeables standing on the farmland that detection leaves out:
-- { name, category, exclusions, isPreplaced, ownerFarmId, x, z }, in the
-- placeables' order.
function TheContractorYards.getExcludedOn(placeables, farmlandId)
    local excluded = {}
    for _, placeable in ipairs(placeables) do
        if placeable.getFarmlandId ~= nil and placeable:getFarmlandId() == farmlandId then
            local exclusions = TheContractorYards.getExclusions(placeable)
            if #exclusions > 0 then
                local name, category = getNameAndCategory(placeable)
                local x, _, z = placeable:getPosition()
                table.insert(excluded, { name = name, category = category, exclusions = exclusions,
                    isPreplaced = placeable.isPreplaced == true, ownerFarmId = placeable.ownerFarmId, x = x, z = z })
            end
        end
    end
    return excluded
end

-- The middle of the group's yard buildings, or of all of them if none are
-- yard buildings; nil with no buildings.
function TheContractorYards.getMiddle(group)
    if group == nil then
        return nil, nil
    end
    local sumX, sumZ, count = 0, 0, 0
    for _, building in ipairs(group.buildings) do
        if TheContractorYards.isYardCategory(building.category) then
            sumX, sumZ, count = sumX + building.x, sumZ + building.z, count + 1
        end
    end
    if count == 0 then
        for _, building in ipairs(group.buildings) do
            sumX, sumZ, count = sumX + building.x, sumZ + building.z, count + 1
        end
    end
    if count == 0 then
        return nil, nil
    end
    return sumX / count, sumZ / count
end

-- Whether the group, given its override (MODE), is a yard, and how that
-- was decided: "detected", "declared" (on), "ruledOut" (off) or nil (no
-- yard, by the rule).
function TheContractorYards.decide(group, mode)
    if mode == TheContractorYards.MODE.ON then
        return true, "declared"
    elseif mode == TheContractorYards.MODE.OFF then
        return false, "ruledOut"
    end
    if TheContractorYards.isYardByRule(group) then
        return true, "detected"
    end
    return false, nil
end

local function sortByFarmland(list)
    table.sort(list, function(a, b)
        return a.farmlandId < b.farmlandId
    end)
    return list
end

-- The yards and near misses from a list of placeables and the overrides
-- (farmlandId -> MODE). A yard: { farmlandId, ownerFarmId, how, group (nil
-- for a declared yard with no buildings), x, z }. A near miss: a farmland
-- with candidate buildings that isn't a yard, { farmlandId, ownerFarmId,
-- how, group }. Both sorted by farmland. categories: every category seen,
-- category -> count.
function TheContractorYards.detect(placeables, overrides)
    local buildings = {}
    for _, placeable in ipairs(placeables) do
        local building = TheContractorYards.describePlaceable(placeable)
        if building ~= nil then
            table.insert(buildings, building)
        end
    end

    local groups = TheContractorYards.groupByFarmland(buildings)
    local yards, nearMisses, categories = {}, {}, {}
    for _, building in ipairs(buildings) do
        categories[building.category] = (categories[building.category] or 0) + 1
    end

    local farmlandIds = {}
    for farmlandId in pairs(groups) do
        farmlandIds[farmlandId] = true
    end
    for farmlandId in pairs(overrides) do
        if g_farmlandManager:getIsValidFarmlandId(farmlandId) then
            farmlandIds[farmlandId] = true
        end
    end

    for farmlandId in pairs(farmlandIds) do
        local group = groups[farmlandId]
        local isYard, how = TheContractorYards.decide(group, overrides[farmlandId])
        local entry = {
            farmlandId = farmlandId,
            ownerFarmId = g_farmlandManager:getFarmlandOwner(farmlandId),
            how = how,
            group = group,
        }
        if isYard then
            entry.x, entry.z = TheContractorYards.getMiddle(group)
            if entry.x == nil then
                local farmland = g_farmlandManager:getFarmlandById(farmlandId)
                if farmland ~= nil then
                    entry.x, entry.z = farmland.xWorldPos, farmland.zWorldPos
                end
            end
            table.insert(yards, entry)
        elseif group ~= nil then
            table.insert(nearMisses, entry)
        end
    end

    return sortByFarmland(yards), sortByFarmland(nearMisses), categories
end

-- The live map's yards (see detect).
local function getMapPlaceables()
    local placeableSystem = g_currentMission.placeableSystem
    return placeableSystem ~= nil and placeableSystem.placeables or {}
end

function TheContractorYards:getYards()
    return TheContractorYards.detect(getMapPlaceables(), self.overrides)
end

-- The live map's placeables on the farmland that detection leaves out (see
-- getExcludedOn).
function TheContractorYards:getMapExcludedOn(farmlandId)
    return TheContractorYards.getExcludedOn(getMapPlaceables(), farmlandId)
end

function TheContractorYards:getYard(farmlandId)
    for _, yard in ipairs((self:getYards())) do
        if yard.farmlandId == farmlandId then
            return yard
        end
    end
    return nil
end

-- Standing spots ---------------------------------------------------------------

-- Candidate points outside a footprint (corners in order round its edge):
-- every EDGE_STEP along each edge, at each of EDGE_OFFSETS outwards.
function TheContractorYards.getEdgeCandidates(corners)
    local Y = TheContractorYards
    local candidates = {}
    local cx, cz = 0, 0
    for _, corner in ipairs(corners) do
        cx, cz = cx + corner.x / #corners, cz + corner.z / #corners
    end
    for i, a in ipairs(corners) do
        local b = corners[i % #corners + 1]
        local dx, dz = b.x - a.x, b.z - a.z
        local length = math.sqrt(dx * dx + dz * dz)
        if length > 0.001 then
            local ux, uz = dx / length, dz / length
            -- The edge's normal, turned away from the middle.
            local nx, nz = -uz, ux
            local mx, mz = (a.x + b.x) * 0.5, (a.z + b.z) * 0.5
            if (mx - cx) * nx + (mz - cz) * nz < 0 then
                nx, nz = -nx, -nz
            end
            local steps = math.max(math.floor(length / Y.EDGE_STEP), 1)
            for step = 0, steps do
                local along = length * step / steps
                for _, offset in ipairs(Y.EDGE_OFFSETS) do
                    table.insert(candidates, { x = a.x + ux * along + nx * offset, z = a.z + uz * along + nz * offset })
                end
            end
        end
    end
    return candidates
end

function TheContractorYards.getRingCandidates(x, z, radii)
    local candidates = {}
    for ringIndex, radius in ipairs(radii) do
        -- Each ring turned half a step on from the last, so they don't line up.
        local turn = (ringIndex - 1) * math.pi / TheContractorYards.RING_POINTS
        for i = 0, TheContractorYards.RING_POINTS - 1 do
            local angle = turn + 2 * math.pi * i / TheContractorYards.RING_POINTS
            table.insert(candidates, { x = x + math.cos(angle) * radius, z = z + math.sin(angle) * radius })
        end
    end
    return candidates
end

-- Whether x, z is inside a convex footprint (corners in order). A
-- footprint with no area (a test area of no size, its corners on one point
-- or one line) has nothing inside it.
function TheContractorYards.isInside(corners, x, z)
    local sign = 0
    for i, a in ipairs(corners) do
        local b = corners[i % #corners + 1]
        local cross = (b.x - a.x) * (z - a.z) - (b.z - a.z) * (x - a.x)
        if cross ~= 0 then
            local side = cross > 0 and 1 or -1
            if sign == 0 then
                sign = side
            elseif side ~= sign then
                return false
            end
        end
    end
    return sign ~= 0
end

-- Every candidate point for a yard, edges first, then the rings.
function TheContractorYards.getCandidates(yard)
    local candidates = {}
    local buildings = yard.group ~= nil and yard.group.buildings or {}
    for _, building in ipairs(buildings) do
        if #building.footprints == 0 then
            for _, point in ipairs(TheContractorYards.getRingCandidates(building.x, building.z,
                    { TheContractorYards.BUILDING_RING_RADIUS })) do
                table.insert(candidates, point)
            end
        end
        for _, corners in ipairs(building.footprints) do
            for _, point in ipairs(TheContractorYards.getEdgeCandidates(corners)) do
                table.insert(candidates, point)
            end
        end
    end
    if yard.x ~= nil then
        for _, point in ipairs(TheContractorYards.getRingCandidates(yard.x, yard.z, TheContractorYards.RING_RADII)) do
            table.insert(candidates, point)
        end
    end
    return candidates
end

-- Up to MAX_SPOTS of the open points, spread out: the one nearest the
-- yard's middle first, then each time the one furthest from those already
-- kept. Taking them in order would fill up on the first buildings' edges.
function TheContractorYards.spreadSpots(yard, open)
    local Y = TheContractorYards
    if #open <= Y.MAX_SPOTS then
        return open
    end
    local mx, mz = yard.x or open[1].x, yard.z or open[1].z
    local nearest, nearestSq = 1, math.huge
    -- Each open point's squared distance to the nearest kept one.
    local gaps = {}
    for i, point in ipairs(open) do
        local distanceSq = (point.x - mx) ^ 2 + (point.z - mz) ^ 2
        if distanceSq < nearestSq then
            nearest, nearestSq = i, distanceSq
        end
        gaps[i] = math.huge
    end
    local spots = {}
    local next = nearest
    while #spots < Y.MAX_SPOTS do
        local kept = open[next]
        table.insert(spots, kept)
        gaps[next] = -1
        local furthest, furthestSq = nil, -1
        for i, point in ipairs(open) do
            if gaps[i] >= 0 then
                gaps[i] = math.min(gaps[i], (point.x - kept.x) ^ 2 + (point.z - kept.z) ^ 2)
                if gaps[i] > furthestSq then
                    furthest, furthestSq = i, gaps[i]
                end
            end
        end
        next = furthest
    end
    return spots
end

-- Why a candidate isn't a spot (SPOT_REJECTION): pickSpots' own checks,
-- then isOpenGround's, in the order they're made.
TheContractorYards.SPOT_REJECTION = {
    SEPARATION = "separation",
    FOOTPRINT = "footprint",
    FARMLAND = "farmland",
    INDOOR = "indoor",
    SLOPE = "slope",
    FIELD = "field",
    NAVIGATION = "navigation",
    BLOCKED = "blocked",
}

-- The ground checks on every candidate (see the header); isOpen does the
-- engine's part, returning whether the point's open and, if not, a
-- SPOT_REJECTION and what blocked it (a name, or nil); a footprint's
-- blocker is its building's name. Returns the
-- spread-out spots kept and how many were open. With tally given
-- ({}), it's filled in as { candidates, rejected = { [rejection] = count },
-- blockers = { [name] = count } }. Pure apart from isOpen, for the tests.
function TheContractorYards.pickSpots(yard, candidates, isOpen, tally)
    local Y = TheContractorYards
    local spots = {}
    local separationSq = Y.SPOT_SEPARATION * Y.SPOT_SEPARATION
    local buildings = yard.group ~= nil and yard.group.buildings or {}
    if tally ~= nil then
        tally.candidates, tally.rejected, tally.blockers = #candidates, {}, {}
    end
    local function reject(rejection, blocker)
        if tally ~= nil then
            tally.rejected[rejection] = (tally.rejected[rejection] or 0) + 1
            if blocker ~= nil then
                tally.blockers[blocker] = (tally.blockers[blocker] or 0) + 1
            end
        end
    end
    for _, point in ipairs(candidates) do
        local rejection, blocker = nil, nil
        for _, spot in ipairs(spots) do
            if (spot.x - point.x) ^ 2 + (spot.z - point.z) ^ 2 < separationSq then
                rejection = Y.SPOT_REJECTION.SEPARATION
                break
            end
        end
        if rejection == nil then
            for _, building in ipairs(buildings) do
                for _, corners in ipairs(building.footprints) do
                    if Y.isInside(corners, point.x, point.z) then
                        rejection, blocker = Y.SPOT_REJECTION.FOOTPRINT, building.name
                        break
                    end
                end
                if rejection ~= nil then
                    break
                end
            end
        end
        if rejection == nil then
            local open, openRejection, blocker = isOpen(point.x, point.z)
            if open then
                table.insert(spots, point)
            else
                reject(openRejection, blocker)
            end
        else
            reject(rejection, blocker)
        end
    end
    return TheContractorYards.spreadSpots(yard, spots), #spots
end

local overlapHit = nil
local overlapTarget = {}
function overlapTarget.onOverlap(_, node)
    if node == g_terrainNode then
        return true
    end
    overlapHit = node
    return false
end

-- What an overlap hit, for tcCompany yards: its object's name (a
-- placeable's or vehicle's) and the node's.
local function describeHit(node)
    local name = getName ~= nil and getName(node) or tostring(node)
    local object = g_currentMission.getNodeObject ~= nil and g_currentMission:getNodeObject(node) or nil
    if object ~= nil and object.getName ~= nil then
        return string.format("%s (%s)", tostring(object:getName()), name)
    end
    return name
end

-- The engine's checks on a point, for a yard on farmlandId: whether it's
-- open, and if not, why (a SPOT_REJECTION) and, if something solid's in
-- the way, what (describeHit).
function TheContractorYards.isOpenGround(farmlandId, x, z)
    local Y = TheContractorYards
    local rejection = Y.SPOT_REJECTION
    if g_farmlandManager:getFarmlandIdAtWorldPosition(x, z) ~= farmlandId then
        return false, rejection.FARMLAND
    end

    -- Vanilla's indoor mask (what keeps rain out of buildings): placeables'
    -- indoor areas and whatever the map painted.
    local indoorMask = g_currentMission.indoorMask
    if indoorMask ~= nil and indoorMask.getIsIndoorAtWorldPosition ~= nil and
            indoorMask:getIsIndoorAtWorldPosition(x, z) then
        return false, rejection.INDOOR
    end

    local y = getTerrainHeightAtWorldPos(g_terrainNode, x, 0, z)
    local s = Y.SLOPE_SAMPLE
    local dx = getTerrainHeightAtWorldPos(g_terrainNode, x + s, 0, z) -
        getTerrainHeightAtWorldPos(g_terrainNode, x - s, 0, z)
    local dz = getTerrainHeightAtWorldPos(g_terrainNode, x, 0, z + s) -
        getTerrainHeightAtWorldPos(g_terrainNode, x, 0, z - s)
    if math.abs(dx) > Y.MAX_SLOPE * 2 * s or math.abs(dz) > Y.MAX_SLOPE * 2 * s then
        return false, rejection.SLOPE
    end

    if FSDensityMapUtil ~= nil and FSDensityMapUtil.getFieldDataAtWorldPosition ~= nil and
            g_currentMission.fieldGroundSystem ~= nil then
        local isField = FSDensityMapUtil.getFieldDataAtWorldPosition(x, y, z)
        if isField then
            return false, rejection.FIELD
        end
    end

    -- Server only: a client has no navigation map, and vanilla answers true.
    local aiSystem = g_currentMission.aiSystem
    if aiSystem ~= nil and aiSystem.getIsPositionReachable ~= nil and not aiSystem:getIsPositionReachable(x, y, z) then
        return false, rejection.NAVIGATION
    end

    local halfHeight = Y.SPOT_HEIGHT * 0.5
    overlapHit = nil
    overlapBox(x, y + Y.SPOT_GROUND_GAP + halfHeight, z, 0, 0, 0, Y.SPOT_HALF_SIZE, halfHeight, Y.SPOT_HALF_SIZE,
        "onOverlap", overlapTarget, SPOT_MASK, true, true, true, true)
    if overlapHit ~= nil then
        return false, rejection.BLOCKED, describeHit(overlapHit)
    end
    return true
end

-- A yard's standing spots, as { x, z }, worked out now, and how many open
-- ones there were to pick from. tally: see pickSpots.
function TheContractorYards.findSpots(yard, tally)
    return TheContractorYards.pickSpots(yard, TheContractorYards.getCandidates(yard), function(x, z)
        return TheContractorYards.isOpenGround(yard.farmlandId, x, z)
    end, tally)
end

-- Synced spots (114) ---------------------------------------------------------------

-- Server, once a load's map is in place (TheContractor:resolveSavedVehicles):
-- every yard's spots.
function TheContractorYards:setUp()
    if not g_currentMission:getIsServer() then
        return
    end
    self.spots = {}
    for _, yard in ipairs((self:getYards())) do
        self.spots[yard.farmlandId] = TheContractorYards.makeSpotsEntry(yard)
    end
end

local function distanceToSegment(x, z, a, b)
    local dx, dz = b.x - a.x, b.z - a.z
    local lengthSq = dx * dx + dz * dz
    local t = 0
    if lengthSq > 0 then
        t = math.max(0, math.min(1, ((x - a.x) * dx + (z - a.z) * dz) / lengthSq))
    end
    local px, pz = a.x + dx * t - x, a.z + dz * t - z
    return math.sqrt(px * px + pz * pz)
end

-- Whether x, z is within NEAR_HOUSE_DISTANCE of one of the buildings'
-- farmhouses.
function TheContractorYards.isNearHouse(buildings, x, z)
    local Y = TheContractorYards
    for _, building in ipairs(buildings) do
        if building.category == Y.HOUSE_CATEGORY then
            local distance = math.sqrt((building.x - x) ^ 2 + (building.z - z) ^ 2)
            for _, corners in ipairs(building.footprints or {}) do
                for i, a in ipairs(corners) do
                    distance = math.min(distance, distanceToSegment(x, z, a, corners[i % #corners + 1]))
                end
            end
            if distance <= Y.NEAR_HOUSE_DISTANCE then
                return true
            end
        end
    end
    return false
end

-- { x, z, spots } for a yard and its spots (findSpots'), each marked
-- nearHouse or not.
function TheContractorYards.makeSpotsEntry(yard, spots)
    local entry = { x = yard.x, z = yard.z, spots = {} }
    local buildings = yard.group ~= nil and yard.group.buildings or {}
    for _, spot in ipairs(spots or (TheContractorYards.findSpots(yard))) do
        table.insert(entry.spots, { x = spot.x, z = spot.z,
            nearHouse = TheContractorYards.isNearHouse(buildings, spot.x, spot.z) })
    end
    return entry
end

-- Server: works one farmland's spots out again (nil once it isn't a yard)
-- and tells the clients.
function TheContractorYards:refreshSpots(farmlandId)
    local yard = self:getYard(farmlandId)
    local entry = yard ~= nil and yard.x ~= nil and TheContractorYards.makeSpotsEntry(yard) or nil
    self:applySpots(farmlandId, entry)
    if g_server ~= nil then
        g_server:broadcastEvent(TCYardSpotsEvent.new(farmlandId, entry))
    end
end

-- Every machine.
function TheContractorYards:applySpots(farmlandId, entry)
    self.spots[farmlandId] = entry
    TCLog.info("TheContractor: yard %d has %d synced spot(s)", farmlandId, entry ~= nil and #entry.spots or 0)
end

-- A yard's synced { x, z, spots }, or nil.
function TheContractorYards:getSpots(farmlandId)
    return self.spots[farmlandId]
end

function TheContractorYards.writeSpotsEntry(streamId, entry)
    if streamWriteBool(streamId, entry ~= nil) then
        streamWriteFloat32(streamId, entry.x)
        streamWriteFloat32(streamId, entry.z)
        streamWriteUInt16(streamId, #entry.spots)
        for _, spot in ipairs(entry.spots) do
            streamWriteFloat32(streamId, spot.x)
            streamWriteFloat32(streamId, spot.z)
            streamWriteBool(streamId, spot.nearHouse == true)
        end
    end
end

function TheContractorYards.readSpotsEntry(streamId)
    if not streamReadBool(streamId) then
        return nil
    end
    local entry = { x = streamReadFloat32(streamId), z = streamReadFloat32(streamId), spots = {} }
    for _ = 1, streamReadUInt16(streamId) do
        table.insert(entry.spots, { x = streamReadFloat32(streamId), z = streamReadFloat32(streamId),
            nearHouse = streamReadBool(streamId) })
    end
    return entry
end

-- Overrides ---------------------------------------------------------------------

function TheContractorYards:getOverride(farmlandId)
    return self.overrides[farmlandId] or TheContractorYards.MODE.AUTO
end

-- The override that turns a farmland's yard on (wantYard) or off, given
-- whether detection alone makes it one: AUTO when detection already
-- agrees, so the override is only kept where the player and the rule
-- differ.
function TheContractorYards.getModeFor(wantYard, isYardByRule)
    local MODE = TheContractorYards.MODE
    if wantYard == isYardByRule then
        return MODE.AUTO
    end
    return wantYard and MODE.ON or MODE.OFF
end

-- Whether a farmland is a yard now, and the override that would turn it
-- the other way (the map's Set/Unset as farmer yard, TCYardMapAction).
function TheContractorYards:getToggle(farmlandId)
    local placeableSystem = g_currentMission.placeableSystem
    local placeables = placeableSystem ~= nil and placeableSystem.placeables or {}
    local isYardByRule = false
    for _, yard in ipairs((TheContractorYards.detect(placeables, {}))) do
        if yard.farmlandId == farmlandId then
            isYardByRule = true
        end
    end
    local isYard = isYardByRule
    local mode = self:getOverride(farmlandId)
    if mode ~= TheContractorYards.MODE.AUTO then
        isYard = mode == TheContractorYards.MODE.ON
    end
    return isYard, TheContractorYards.getModeFor(not isYard, isYardByRule)
end

-- Server: sets a farmland's override and tells the clients. The farmers'
-- yards follow (110's reconcileLand): a new yard goes to a farmer near it
-- with none, and a farmer whose yard is ruled out loses it.
function TheContractorYards:setOverride(farmlandId, mode)
    self:applyOverride(farmlandId, mode)
    if g_server ~= nil then
        g_server:broadcastEvent(TCYardOverrideEvent.new(farmlandId, mode))
    end
    self:refreshSpots(farmlandId)
    local farmers = g_currentMission.TheContractor.Farmers
    if farmers ~= nil and farmers.isSetUp then
        farmers:reconcileLand()
    end
end

-- Every machine.
function TheContractorYards:applyOverride(farmlandId, mode)
    if mode == TheContractorYards.MODE.AUTO then
        self.overrides[farmlandId] = nil
    else
        self.overrides[farmlandId] = mode
    end
    TCLog.info("TheContractor: farmland %d yard override %s", farmlandId, TheContractorYards.MODE_NAMES[mode] or "?")
    if self.markers ~= nil then
        self:showMarkers(self.markers.farmlandId)
    end
    if TCYardMapAction ~= nil then
        TCYardMapAction.refresh()
    end
end

function TheContractorYards:loadFromXMLFile(xmlFile)
    if not g_currentMission:getIsServer() then return end

    self.overrides = {}
    local i = 0
    while true do
        local key = string.format("%s.yards.override(%d)", TheContractor.SaveKey, i)
        if not hasXMLProperty(xmlFile, key) then
            break
        end
        local farmlandId = getXMLInt(xmlFile, key .. "#farmlandId")
        local modeName = getXMLString(xmlFile, key .. "#mode")
        local mode = nil
        for value, name in pairs(TheContractorYards.MODE_NAMES) do
            if name == modeName and value ~= TheContractorYards.MODE.AUTO then
                mode = value
            end
        end
        if farmlandId ~= nil and mode ~= nil then
            self.overrides[farmlandId] = mode
        else
            TCLog.warning("TheContractor: skipping yard override %s (farmland %s, mode %s)", key,
                tostring(farmlandId), tostring(modeName))
        end
        i = i + 1
    end
end

function TheContractorYards:saveToXmlFile(xmlFile)
    if not g_currentMission:getIsServer() then return end

    local farmlandIds = {}
    for farmlandId in pairs(self.overrides) do
        table.insert(farmlandIds, farmlandId)
    end
    table.sort(farmlandIds)
    for i, farmlandId in ipairs(farmlandIds) do
        local key = string.format("%s.yards.override(%d)", TheContractor.SaveKey, i - 1)
        setXMLInt(xmlFile, key .. "#farmlandId", farmlandId)
        setXMLString(xmlFile, key .. "#mode", TheContractorYards.MODE_NAMES[self.overrides[farmlandId]])
    end
end

function TheContractorYards.writeOverrides(streamId, overrides)
    local count = 0
    for _ in pairs(overrides) do
        count = count + 1
    end
    streamWriteInt32(streamId, count)
    for farmlandId, mode in pairs(overrides) do
        streamWriteInt32(streamId, farmlandId)
        streamWriteUInt8(streamId, mode)
    end
end

function TheContractorYards.readOverrides(streamId)
    local overrides = {}
    local count = streamReadInt32(streamId)
    for _ = 1, count do
        local farmlandId = streamReadInt32(streamId)
        overrides[farmlandId] = streamReadUInt8(streamId)
    end
    return overrides
end

function TheContractorYards:writeInitialClientState(streamId, connection)
    TheContractorYards.writeOverrides(streamId, self.overrides)
    local farmlandIds = {}
    for farmlandId in pairs(self.spots) do
        table.insert(farmlandIds, farmlandId)
    end
    table.sort(farmlandIds)
    streamWriteInt32(streamId, #farmlandIds)
    for _, farmlandId in ipairs(farmlandIds) do
        streamWriteInt32(streamId, farmlandId)
        TheContractorYards.writeSpotsEntry(streamId, self.spots[farmlandId])
    end
end

function TheContractorYards:readInitialClientState(streamId, connection)
    self.overrides = TheContractorYards.readOverrides(streamId)
    self.spots = {}
    for _ = 1, streamReadInt32(streamId) do
        local farmlandId = streamReadInt32(streamId)
        self.spots[farmlandId] = TheContractorYards.readSpotsEntry(streamId)
    end
end

-- Map markers ---------------------------------------------------------------------

-- A circle of radius (metres) on the map, added to hotspots and returned.
-- Vanilla's field mission circle, which pulses.
function TheContractorYards.addMarker(hotspots, x, z, radius)
    local hotspot = AbstractFieldMissionHotspot.new()
    hotspot:setWorldRadius(radius)
    hotspot:setWorldPosition(x, z)
    g_currentMission:addMapHotspot(hotspot)
    table.insert(hotspots, hotspot)
    return hotspot
end
local addMarker = TheContractorYards.addMarker

-- The angle (degrees, -180 to 180, positive clockwise seen from above)
-- from a house's +Z direction (fx, fz) to the direction (dx, dz) of its
-- spawn node, or nil with the node on the root.
function TheContractorYards.getTurnFromForward(fx, fz, dx, dz)
    if dx * dx + dz * dz < 0.0001 then
        return nil
    end
    -- From above, with x east and z south, clockwise is +x towards +z.
    return math.deg(math.atan2(fx * dz - fz * dx, fx * dx + fz * dz))
end

-- A farmhouse's facing, for checking it against the map: where its root
-- is, its own +Z direction, and its spawn node (nil without one).
local function getHouseFacing(placeable)
    if placeable == nil or placeable.rootNode == nil then
        return nil
    end
    local x, _, z = getWorldTranslation(placeable.rootNode)
    local fx, _, fz = localDirectionToWorld(placeable.rootNode, 0, 0, 1)
    local facing = { x = x, z = z, fx = fx, fz = fz }
    local spec = placeable.spec_farmhouse
    if spec ~= nil and spec.spawnNode ~= nil and spec.spawnNode ~= placeable.rootNode then
        facing.spawnX, _, facing.spawnZ = getWorldTranslation(spec.spawnNode)
    end
    return facing
end

-- Markers and a line for each farmhouse in a yard: its +Z, and its spawn
-- node with the turn from +Z to it.
function TheContractorYards:markHouses(yard)
    local Y = TheContractorYards
    local lines = {}
    for _, building in ipairs(yard.group ~= nil and yard.group.buildings or {}) do
        local facing = building.category == Y.HOUSE_CATEGORY and getHouseFacing(building.placeable) or nil
        if facing ~= nil then
            addMarker(self.markers.hotspots, facing.x + facing.fx * Y.FORWARD_MARKER_DISTANCE,
                facing.z + facing.fz * Y.FORWARD_MARKER_DISTANCE, Y.FORWARD_MARKER_RADIUS)
            local spawn = "no spawn node"
            if facing.spawnX ~= nil then
                addMarker(self.markers.hotspots, facing.spawnX, facing.spawnZ, Y.SPAWN_MARKER_RADIUS)
                local dx, dz = facing.spawnX - facing.x, facing.spawnZ - facing.z
                local turn = Y.getTurnFromForward(facing.fx, facing.fz, dx, dz)
                spawn = string.format("spawn node %.1f m out, %s", math.sqrt(dx * dx + dz * dz),
                    turn ~= nil and string.format("%.0f degrees clockwise from +Z", turn) or "on the root")
            end
            table.insert(lines, string.format("  %s at %.0f, %.0f: +Z points to %.2f, %.2f (big circle), %s%s",
                building.name, facing.x, facing.z, facing.fx, facing.fz, spawn,
                facing.spawnX ~= nil and " (small circle)" or ""))
        end
    end
    return lines
end

-- A circle on every yard, or with farmlandId just that yard's, with a
-- small one on each of its spots and its farmhouses' facing markers.
-- Returns how many yards and spots, and a line per farmhouse.
function TheContractorYards:showMarkers(farmlandId)
    self:hideMarkers()
    if AbstractFieldMissionHotspot == nil or g_currentMission.addMapHotspot == nil then
        return 0, 0, {}
    end
    self.markers = { farmlandId = farmlandId, hotspots = {} }
    local yardCount, spotCount, houseLines = 0, 0, {}
    for _, yard in ipairs((self:getYards())) do
        if yard.x ~= nil and (farmlandId == nil or yard.farmlandId == farmlandId) then
            addMarker(self.markers.hotspots, yard.x, yard.z, TheContractorYards.YARD_MARKER_RADIUS)
            yardCount = yardCount + 1
            if farmlandId ~= nil then
                -- The synced spots 114's farmers stand on, if there are any.
                local synced = self.spots[yard.farmlandId]
                local spots = synced ~= nil and synced.spots or TheContractorYards.findSpots(yard)
                for _, spot in ipairs(spots) do
                    addMarker(self.markers.hotspots, spot.x, spot.z, TheContractorYards.SPOT_MARKER_RADIUS)
                    spotCount = spotCount + 1
                end
                houseLines = self:markHouses(yard)
            end
        end
    end
    return yardCount, spotCount, houseLines
end

function TheContractorYards:hideMarkers()
    if self.markers == nil then
        return
    end
    for _, hotspot in ipairs(self.markers.hotspots) do
        if g_currentMission ~= nil and g_currentMission.removeMapHotspot ~= nil and g_currentMission.hud ~= nil then
            g_currentMission:removeMapHotspot(hotspot)
        end
        hotspot:delete()
    end
    self.markers = nil
end

-- Console ---------------------------------------------------------------------------

local function formatCategories(categories)
    local names = {}
    for category in pairs(categories) do
        table.insert(names, category)
    end
    table.sort(names)
    local parts = {}
    for _, category in ipairs(names) do
        table.insert(parts, string.format("%s %d", category, categories[category]))
    end
    return table.concat(parts, ", ")
end

local function formatStations(group)
    local sells, unloads = false, false
    for _, building in ipairs(group ~= nil and group.buildings or {}) do
        sells = sells or building.hasSellingStation
        unloads = unloads or building.hasUnloadingStation
    end
    local parts = {}
    if sells then
        table.insert(parts, "sell point")
    end
    if unloads then
        table.insert(parts, "unloading")
    end
    return #parts > 0 and (", " .. table.concat(parts, " and ")) or ""
end

local function formatBuildings(group)
    if group == nil then
        return "no buildings"
    end
    return string.format("%d building(s) (%s)", #group.buildings, formatCategories(group.categories))
end

function TheContractorYards.getListText(yards, nearMisses, categories, isServer)
    local lines = { string.format("Yards (%d):", #yards) }
    for _, yard in ipairs(yards) do
        local kept, openCount = TheContractorYards.findSpots(yard)
        local spots = string.format("%d of %d", #kept, openCount)
        if not isServer then
            spots = spots .. " (no navigation check on a client)"
        end
        local position = yard.x ~= nil and string.format("%.0f, %.0f", yard.x, yard.z) or "unknown"
        table.insert(lines, string.format("  #%d owner %d, %s, %s%s, spots %s, at %s", yard.farmlandId,
            yard.ownerFarmId, yard.how, formatBuildings(yard.group), formatStations(yard.group), spots, position))
    end
    table.insert(lines, string.format("Farmlands with buildings but no yard (%d):", #nearMisses))
    for _, miss in ipairs(nearMisses) do
        table.insert(lines, string.format("  #%d owner %d%s, %s%s", miss.farmlandId, miss.ownerFarmId,
            miss.how == "ruledOut" and ", ruled out" or "", formatBuildings(miss.group), formatStations(miss.group)))
    end
    table.insert(lines, "Categories seen: " .. formatCategories(categories))
    return table.concat(lines, "\n")
end

local RULE_FAILURE_TEXTS = {
    [TheContractorYards.RULE_FAILURE.NO_BUILDINGS] = function()
        return "no buildings that count"
    end,
    [TheContractorYards.RULE_FAILURE.TOO_FEW_YARD_BUILDINGS] = function(group)
        return string.format("%d yard building(s), needs %d", group.yardBuildingCount, TheContractorYards.MIN_BUILDINGS)
    end,
    [TheContractorYards.RULE_FAILURE.NO_ANCHOR] = function()
        return "no shed or farmhouse among them"
    end,
    [TheContractorYards.RULE_FAILURE.NO_WORKING_BUILDING] = function()
        return "no yard building that isn't a farmhouse"
    end,
    [TheContractorYards.RULE_FAILURE.TOO_MANY_HOUSES] = function(group)
        return string.format("%d farmhouses, more than %d (a village)", group.houseCount,
            TheContractorYards.MAX_FARMHOUSES)
    end,
}

local EXCLUSION_TEXTS = {
    [TheContractorYards.EXCLUSION.DELETED] = "being deleted",
    [TheContractorYards.EXCLUSION.NOT_BOUGHT] = "its store item isn't sold with the farmland",
    [TheContractorYards.EXCLUSION.SAVE_NOT_BOUGHT] = "the map or savegame says it isn't sold with the farmland",
    [TheContractorYards.EXCLUSION.NO_FARMLAND] = "not on a valid farmland",
}

local SPOT_REJECTION_ORDER = { "SEPARATION", "FOOTPRINT", "FARMLAND", "INDOOR", "SLOPE", "FIELD", "NAVIGATION",
    "BLOCKED" }
local SPOT_REJECTION_TEXTS = {
    separation = "too close to a kept spot",
    footprint = "inside a building's footprint",
    farmland = "off the farmland",
    indoor = "indoors (indoor mask)",
    slope = "too steep",
    field = "on a field",
    navigation = "off the AI navigation map",
    blocked = "something solid in the way",
}
-- Most blockers listed by name.
local MAX_BLOCKERS_LISTED = 8

-- spots: { kept, open, synced (the server's count, or nil), tally
-- (pickSpots') } for a yard's spots worked out now.
local function getSpotLines(spots, isServer)
    local tally = spots.tally
    local lines = { string.format("Spots: %d kept of %d open, from %d candidates%s", spots.kept, spots.open,
        tally.candidates, isServer and "" or " (no navigation check on a client)") }
    if spots.synced ~= nil then
        table.insert(lines, string.format("  The server's list for the farmer: %d", spots.synced))
    end
    for _, key in ipairs(SPOT_REJECTION_ORDER) do
        local rejection = TheContractorYards.SPOT_REJECTION[key]
        local count = tally.rejected[rejection]
        if count ~= nil then
            table.insert(lines, string.format("  %d %s", count, SPOT_REJECTION_TEXTS[rejection]))
        end
    end
    local names = {}
    for name in pairs(tally.blockers) do
        table.insert(names, name)
    end
    table.sort(names, function(a, b)
        if tally.blockers[a] ~= tally.blockers[b] then
            return tally.blockers[a] > tally.blockers[b]
        end
        return a < b
    end)
    if #names > 0 then
        table.insert(lines, "  In the way:")
        for i = 1, math.min(#names, MAX_BLOCKERS_LISTED) do
            table.insert(lines, string.format("    %s: %d", names[i], tally.blockers[names[i]]))
        end
        if #names > MAX_BLOCKERS_LISTED then
            table.insert(lines, string.format("    and %d more", #names - MAX_BLOCKERS_LISTED))
        end
    end
    return lines
end

-- One farmland's verdict and why, its candidate buildings, one per line,
-- the placeables on it that detection leaves out (getExcludedOn) and, for
-- a yard, how its standing spots came out (spots: see getSpotLines).
function TheContractorYards.getFarmlandText(farmlandId, yards, nearMisses, excluded, spots, isServer)
    local entry
    for _, list in ipairs({ yards, nearMisses }) do
        for _, candidate in ipairs(list) do
            if candidate.farmlandId == farmlandId then
                entry = candidate
            end
        end
    end
    local group = entry ~= nil and entry.group or nil
    local mode = g_currentMission.TheContractor.Yards:getOverride(farmlandId)

    local failures = TheContractorYards.getRuleFailures(group)
    local detection
    if #failures == 0 then
        detection = "a yard"
    else
        local reasons = {}
        for _, failure in ipairs(failures) do
            table.insert(reasons, RULE_FAILURE_TEXTS[failure](group))
        end
        detection = "not a yard: " .. table.concat(reasons, "; ")
    end
    local lines = { string.format("Farmland %d: %s (override %s)", farmlandId,
        entry ~= nil and entry.how ~= nil and entry.how or "not a yard", TheContractorYards.MODE_NAMES[mode]),
        "  Detection alone: " .. detection }

    table.insert(lines, string.format("Counted (%d):", group ~= nil and #group.buildings or 0))
    for _, building in ipairs(group ~= nil and group.buildings or {}) do
        local stations = {}
        if building.hasSellingStation then
            table.insert(stations, "sell point")
        end
        if building.hasUnloadingStation then
            table.insert(stations, "unloading")
        end
        table.insert(lines, string.format("  %s [%s]%s%s at %.0f, %.0f", building.name, building.category,
            TheContractorYards.isYardCategory(building.category) and " (yard)" or "",
            #stations > 0 and (" " .. table.concat(stations, ", ")) or "", building.x, building.z))
    end

    table.insert(lines, string.format("Not counted (%d):", #excluded))
    for _, placeable in ipairs(excluded) do
        local reasons = {}
        for _, exclusion in ipairs(placeable.exclusions) do
            table.insert(reasons, EXCLUSION_TEXTS[exclusion] or exclusion)
        end
        table.insert(lines, string.format("  %s [%s] at %.0f, %.0f (%s, owner %s): %s", placeable.name,
            placeable.category, placeable.x, placeable.z, placeable.isPreplaced and "preplaced" or "placed",
            tostring(placeable.ownerFarmId), table.concat(reasons, "; ")))
    end
    if group == nil and #excluded == 0 then
        table.insert(lines, "No placeables stand on this farmland. Buildings built into the map's own scene " ..
            "aren't placeables, so detection can't see them: declare it with tcCompany yard " .. farmlandId .. " on.")
    end
    if spots ~= nil then
        for _, line in ipairs(getSpotLines(spots, isServer)) do
            table.insert(lines, line)
        end
    end
    return table.concat(lines, "\n")
end

function TheContractorYards.registerConsoleCommands()
    TCConsole.register("company", "yards", {
        args = "[farmlandId|here|show [farmlandId]|hide]",
        description = "List the map's farm yards, check why a farmland is or isn't one, or mark yards on this machine's map",
        serverOnly = false,
        run = function(farmId, args, context)
            local yardsSystem = g_currentMission.TheContractor.Yards
            local first = args[1] ~= nil and string.lower(args[1]) or nil
            if first == "show" then
                local farmlandId = args[2] ~= nil and tonumber(args[2]) or nil
                if args[2] ~= nil and farmlandId == nil then
                    return false
                end
                local yardCount, spotCount, houseLines = yardsSystem:showMarkers(farmlandId)
                if farmlandId ~= nil then
                    if yardCount == 0 then
                        yardsSystem:hideMarkers()
                        return string.format("Farmland %d isn't a yard.", farmlandId)
                    end
                    local text = string.format("Marked yard %d and its %d spot(s). tcCompany yards hide to clear.",
                        farmlandId, spotCount)
                    if #houseLines > 0 then
                        text = text .. "\nFarmhouses:\n" .. table.concat(houseLines, "\n")
                    end
                    return text
                end
                return string.format("Marked %d yard(s). tcCompany yards hide to clear.", yardCount)
            elseif first == "hide" then
                yardsSystem:hideMarkers()
                return "Yard markers cleared."
            end

            local yards, nearMisses, categories = yardsSystem:getYards()
            if first ~= nil then
                local farmlandId
                if first == "here" then
                    if not TCConsole.hasPosition(context) then
                        return "Error: no position for the current player"
                    end
                    farmlandId = g_farmlandManager:getFarmlandIdAtWorldPosition(context.x, context.z)
                    if not g_farmlandManager:getIsValidFarmlandId(farmlandId) then
                        return "You're not standing on a farmland."
                    end
                else
                    farmlandId = tonumber(first)
                    if farmlandId == nil then
                        return false
                    end
                end
                local spots = nil
                for _, yard in ipairs(yards) do
                    if yard.farmlandId == farmlandId then
                        local tally = {}
                        local kept, open = TheContractorYards.findSpots(yard, tally)
                        local synced = yardsSystem:getSpots(farmlandId)
                        spots = { kept = #kept, open = open, tally = tally,
                            synced = synced ~= nil and #synced.spots or nil }
                    end
                end
                return TheContractorYards.getFarmlandText(farmlandId, yards, nearMisses,
                    yardsSystem:getMapExcludedOn(farmlandId), spots, g_currentMission:getIsServer())
            end
            return TheContractorYards.getListText(yards, nearMisses, categories, g_currentMission:getIsServer())
        end,
    })

    TCConsole.register("company", "yard", {
        args = "<farmlandId> <on|off|auto>",
        description = "Declare a farmland a yard, rule one out, or go back to detection",
        run = function(farmId, args)
            local farmlandId = args[1] ~= nil and tonumber(args[1]) or nil
            local modeName = args[2] ~= nil and string.lower(args[2]) or nil
            local mode = nil
            for value, name in pairs(TheContractorYards.MODE_NAMES) do
                if name == modeName then
                    mode = value
                end
            end
            if farmlandId == nil or mode == nil then
                return false
            end
            if not g_farmlandManager:getIsValidFarmlandId(farmlandId) then
                return string.format("Error: no farmland %d on this map", farmlandId)
            end
            g_currentMission.TheContractor.Yards:setOverride(farmlandId, mode)
            local yard = g_currentMission.TheContractor.Yards:getYard(farmlandId)
            return string.format("Farmland %d set to %s: %s.", farmlandId, modeName,
                yard ~= nil and ("a yard (" .. yard.how .. ")") or "not a yard")
        end,
    })
end
