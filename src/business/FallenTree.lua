-- Fallen tree (107), a random event (068) after bad weather: TREES_MIN to
-- TREES_MAX big beeches have come down across roads in one part of the
-- map, and the council's highways team asks the contractor to clear them,
-- today, as one job. The player cuts each up with a chainsaw and gets it
-- off the road; the wood is theirs to keep or sell.
--
-- When: rolled once at the end of each spell of bad weather (068's
-- chancePerStorm, CHANCE_PER_STORM, no cooldown), found the next hour if
-- the weather clears in the morning, else between TRIGGER_HOURS that
-- morning or the next. Never while the farm has one already.
--
-- Where (findRoadSpots): points on AI road splines anywhere on the map, in
-- random order, the first tree's anywhere and the rest within MAX_SPREAD
-- of it, every tree's road at least TREE_SEPARATION from any other (this
-- incident's or another open one's). Each tree's base is BASE_OFFSET off the road's middle on
-- one side, and it falls across the road at right angles, ROOM_LENGTH long.
-- A spot's skipped if it's a bridge (the ground well away from the
-- spline), if the ground rises along the fall line, if anything's in the
-- way of the trunk (buildings, walls, standing trees, vehicles, traffic,
-- players), if a player is within MIN_PLAYER_DISTANCE (so nobody sees it
-- planted, and every client has the tree before it's cut, below), or if no
-- field without a live job is within MAX_FIELD_DISTANCE: the nearest one
-- names that tree in the offer, and the first tree's names the job
-- ("Roads around Field 12") and is its field, nothing more (JOB_TYPES'
-- offField). Fewer than TREES_MIN found and nothing happens.
--
-- How it's put down: vanilla's own tree loading and trunk cut, not ours.
-- TreePlantManager:loadTreeTrunk (the gsTreeAdd dev command) would do it in
-- one call, but it loads through loadTreeNode, not plantTree, so no
-- TreePlantEvent goes to clients and they never get the split shape's file
-- id mapping. So the server plants it with plantTree (broadcast, and saved
-- in vanilla's treePlant.xml with the rest), and CUT_DELAY_MS later, once
-- every client has had the tree, queues the same entry loadTreeTrunk would
-- on g_treePlantManager.loadTreeTrunkDatas. Vanilla's updateTrees then cuts
-- it over the next two frames: a cut at TRUNK_LENGTH + 0.5 up (past the
-- top, so the whole tree is kept, crown and all, delimb off), then one at
-- 0.5 m (the stump goes), and lays what's left along the fall to drop as a
-- dynamic body. It's planted SPAWN_HEIGHT above the ground, as gsTreeAdd
-- does, so the trunk lands rather than starting inside the ground.
--
-- The job (JOB_TYPES' fallenTree): offered through the inbox (endsWithJob),
-- due the same day, PRICE_PER_TREE_MIN-PRICE_PER_TREE_MAX for each tree
-- that came down at the default job pay rate (the job pay setting scales
-- it), a fixed reputation reward. Each tree's road has its own map marker
-- (TCJobHotspots) until it's clear. Accepting it
-- allocates it to the farm's players at once (allocateOnAccept). While it's
-- taken on, a loose piece on its site can be chainsawed off the farm's land
-- (SplitShapeManager.getIsShapeCutAllowed, patched below). Every
-- CHECK_INTERVAL_MS the server looks for loose pieces on each tree's road
-- (ROAD_HALF_WIDTH either side of its middle, ROAD_CLEAR_HALF_LENGTH along
-- it): none for CLEAR_CHECKS checks in a row and that road's clear (the
-- tree's isClear). Every road clear is the job done (TCJobProgress, which
-- shows the share cleared till then). Wood stacked on the verge counts as
-- cleared.
--
-- Turned down or left to lapse: a small reputation loss
-- (DECLINE_REPUTATION_PENALTY), and the council's own crew clears it (every
-- loose piece on every tree's site deleted). Missed once taken on: the usual missed
-- job penalty, and the council clears it too. Done: the incident closes and
-- the wood stays.
--
-- No state of its own: the incident's data (flat, saved and synced) holds
-- treeType, stage, fieldId (the job's), jobId (0 until offered) and
-- treeCount, and for each tree n its TREE_KEYS as "tree<n>_<key>"
-- (getTree/setTrees): variation, the base (x, y, z) and fall (dirX, dirZ),
-- the road's middle (roadX, roadZ) and direction (roadDirX, roadDirZ), its
-- own nearest fieldId, the trunk's saveable split shape id (shapeId1-3, 0
-- until it's down) and isClear. Once they're down, a tree that didn't make
-- it is dropped and the rest renumbered.

TheContractorFallenTree = {}
TheContractorFallenTree_mt = Class(TheContractorFallenTree)

TheContractorFallenTree.EVENT_TYPE = "fallenTree"
TheContractorFallenTree.JOB_TYPE = "fallenTree"
TheContractorFallenTree.MESSAGE_KIND = "fallenTree"

TheContractorFallenTree.CHANCE_PER_STORM = 0.15
TheContractorFallenTree.TRIGGER_HOURS = { 7, 9 }

-- A fully grown beech: the only tree that looked right lying across a road.
TheContractorFallenTree.TREE_TYPE = "beech"

-- How many come down at once.
TheContractorFallenTree.TREES_MIN = 2
TheContractorFallenTree.TREES_MAX = 4

-- What the council pays for each tree, at the default job pay rate.
TheContractorFallenTree.PRICE_PER_TREE_MIN = 1250
TheContractorFallenTree.PRICE_PER_TREE_MAX = 1750
TheContractorFallenTree.DECLINE_REPUTATION_PENALTY = 3

-- Where: road spline points every ROAD_SAMPLE_STEP metres, at most
-- SPOT_TRIES of them tried for all the trees. The base BASE_OFFSET from
-- the road's middle,
-- the trunk ROOM_LENGTH long and TRUNK_HALF_WIDTH either side checked for
-- room, from ROOM_FLOOR to ROOM_TOP above the base's ground.
TheContractorFallenTree.ROAD_SAMPLE_STEP = 20
TheContractorFallenTree.SPOT_TRIES = 120
TheContractorFallenTree.BASE_OFFSET = 6
TheContractorFallenTree.ROOM_LENGTH = 30
TheContractorFallenTree.TRUNK_HALF_WIDTH = 1.5
TheContractorFallenTree.ROOM_FLOOR = 0.5
TheContractorFallenTree.ROOM_TOP = 3
TheContractorFallenTree.ROOM_STEP = 5
-- Further than this between the spline and the ground is a bridge.
TheContractorFallenTree.MAX_ROAD_HEIGHT_GAP = 1.5
-- The ground along the fall can't rise more than this over the base's
-- (the trunk lands about SPAWN_HEIGHT up).
TheContractorFallenTree.MAX_GROUND_RISE = 0.8
TheContractorFallenTree.MIN_PLAYER_DISTANCE = 150
TheContractorFallenTree.MAX_FIELD_DISTANCE = 2000
-- Trees' roads at least this far apart, and the rest within MAX_SPREAD of
-- the first's.
TheContractorFallenTree.TREE_SEPARATION = 200
TheContractorFallenTree.MAX_SPREAD = 1000

-- tcCompany event fallenTree here: this far ahead of the player.
TheContractorFallenTree.FRONT_DISTANCE = 8

TheContractorFallenTree.SPAWN_HEIGHT = 1
-- Vanilla's first cut goes this far up the trunk; past any tree's top, so
-- nothing's cut off.
TheContractorFallenTree.TRUNK_LENGTH = 200
-- Planted this long before the cut, so every client has the tree first.
TheContractorFallenTree.CUT_DELAY_MS = 3000

-- The site, from the base along the fall: cutting is allowed on it (and
-- SITE_MARGIN past it), and the council clears it.
TheContractorFallenTree.CORRIDOR_LENGTH = 35
TheContractorFallenTree.CORRIDOR_HALF_WIDTH = 6
TheContractorFallenTree.SITE_MARGIN = 3
-- The road itself, which has to be clear.
TheContractorFallenTree.ROAD_HALF_WIDTH = 4
TheContractorFallenTree.ROAD_CLEAR_HALF_LENGTH = 8
TheContractorFallenTree.CHECK_HALF_HEIGHT = 4

TheContractorFallenTree.CHECK_INTERVAL_MS = 2000
TheContractorFallenTree.SITE_REFRESH_MS = 1000
TheContractorFallenTree.CLEAR_CHECKS = 2

-- Each tree's values in the incident's data, as "tree<n>_<key>".
TheContractorFallenTree.TREE_KEYS = { "variation", "x", "y", "z", "dirX", "dirZ", "roadX", "roadZ", "roadDirX",
    "roadDirZ", "fieldId", "shapeId1", "shapeId2", "shapeId3", "isClear" }

-- falling: planted, vanilla's cuts still to run. open: down, with its job
-- offered or taken on.
TheContractorFallenTree.STAGE = {
    FALLING = "falling",
    OPEN = "open",
}

-- What the room check stops for (the terrain and the road aren't in it).
local ROOM_MASK = CollisionFlag ~= nil and (CollisionFlag.STATIC_OBJECT + CollisionFlag.BUILDING +
    CollisionFlag.TREE + CollisionFlag.VEHICLE + CollisionFlag.DYNAMIC_OBJECT + CollisionFlag.TRAFFIC_VEHICLE +
    CollisionFlag.PLAYER) or 0

-- farmId -> { tree, ... } of taken-on jobs, every machine (refreshSites).
local sitesByFarm = {}

function TheContractorFallenTree.new()
    local self = {}
    setmetatable(self, TheContractorFallenTree_mt)

    -- Server, not saved: incident id -> { plantedAt (g_time), isQueued,
    -- trees = { [tree index] = { shape, entry (vanilla's cut, once
    -- queued) } } } (a tree that didn't plant isn't in trees).
    self.pendingFalls = {}
    -- Server, not saved: incident id -> { [tree index] = clear checks in a
    -- row with nothing on its road }.
    self.clearCounts = {}
    -- tcCompany event fallenTree here: the next one comes down in front of
    -- the player. Server, not saved.
    self.consoleHere = false

    self.checkMs = 0
    self.refreshMs = 0

    return self
end

-- Every machine, at load, before the save loads (068).
function TheContractorFallenTree:register(randomEvents, inbox)
    self.randomEvents = randomEvents
    local STAGE = TheContractorFallenTree.STAGE

    randomEvents:registerEventType(TheContractorFallenTree.EVENT_TYPE, {
        l10nKey = "tc_fallenTree_eventName",
        chancePerStorm = TheContractorFallenTree.CHANCE_PER_STORM,
        triggerHours = TheContractorFallenTree.TRIGGER_HOURS,
        canTrigger = function(farmId)
            return self:pickSpot(farmId, math.random)
        end,
        -- tcCompany event fallenTree [here]
        console = {
            prepareTrigger = function(farmId, details)
                return self:prepareConsole(details)
            end,
            clearTrigger = function()
                self.consoleHere = false
            end,
        },
        stages = {
            { key = STAGE.FALLING, run = function(incident)
                return self:onFalling(incident)
            end },
            { key = STAGE.OPEN, run = function(incident)
                return TheContractorRandomEvents.WAIT
            end },
        },
    })

    inbox:registerMessageKind(TheContractorFallenTree.MESSAGE_KIND, {
        endsWithJob = true,
        chipKey = "tc_inbox_chipFallenTree",
        chipTone = "bad",
    })
end

-- The trees in the data ----------------------------------------------------------------

local function treeKey(i, key)
    return "tree" .. i .. "_" .. key
end

-- Tree i's values (TREE_KEYS), plus its index. A copy: change the data
-- with setTreeValue.
function TheContractorFallenTree.getTree(data, i)
    local tree = { index = i }
    for _, key in ipairs(TheContractorFallenTree.TREE_KEYS) do
        tree[key] = data[treeKey(i, key)]
    end
    return tree
end

function TheContractorFallenTree.getTrees(data)
    local trees = {}
    for i = 1, data.treeCount or 0 do
        table.insert(trees, TheContractorFallenTree.getTree(data, i))
    end
    return trees
end

function TheContractorFallenTree.setTreeValue(data, i, key, value)
    data[treeKey(i, key)] = value
end

-- Replaces every tree in the data with these, numbered from 1.
function TheContractorFallenTree.setTrees(data, trees)
    local keys = TheContractorFallenTree.TREE_KEYS
    for i = 1, data.treeCount or 0 do
        for _, key in ipairs(keys) do
            data[treeKey(i, key)] = nil
        end
    end
    data.treeCount = #trees
    for i, tree in ipairs(trees) do
        for _, key in ipairs(keys) do
            data[treeKey(i, key)] = tree[key]
        end
    end
end

function TheContractorFallenTree.countClear(data)
    local count = 0
    for i = 1, data.treeCount or 0 do
        if data[treeKey(i, "isClear")] then
            count = count + 1
        end
    end
    return count
end

-- Geometry (of one tree) ---------------------------------------------------------------

-- A point's place along a tree's fall (from the base) and across it.
function TheContractorFallenTree.getCorridorPosition(tree, x, z)
    local dx, dz = x - tree.x, z - tree.z
    local along = dx * tree.dirX + dz * tree.dirZ
    local across = dz * tree.dirX - dx * tree.dirZ
    return along, across
end

function TheContractorFallenTree.isInCorridor(tree, x, z, margin)
    margin = margin or 0
    local along, across = TheContractorFallenTree.getCorridorPosition(tree, x, z)
    return along >= -margin and along <= TheContractorFallenTree.CORRIDOR_LENGTH + margin and
        math.abs(across) <= TheContractorFallenTree.CORRIDOR_HALF_WIDTH + margin
end

-- A tree's corridor's bounding rectangle: minX, maxX, minZ, maxZ.
function TheContractorFallenTree.getCorridorBounds(tree)
    local T = TheContractorFallenTree
    local sideX, sideZ = -tree.dirZ * T.CORRIDOR_HALF_WIDTH, tree.dirX * T.CORRIDOR_HALF_WIDTH
    local endX, endZ = tree.x + tree.dirX * T.CORRIDOR_LENGTH, tree.z + tree.dirZ * T.CORRIDOR_LENGTH
    local xs = { tree.x + sideX, tree.x - sideX, endX + sideX, endX - sideX }
    local zs = { tree.z + sideZ, tree.z - sideZ, endZ + sideZ, endZ - sideZ }
    return math.min(xs[1], xs[2], xs[3], xs[4]), math.max(xs[1], xs[2], xs[3], xs[4]),
        math.min(zs[1], zs[2], zs[3], zs[4]), math.max(zs[1], zs[2], zs[3], zs[4])
end

-- The tree for a road point (roadX, roadZ) heading (roadDirX, roadDirZ),
-- on side (+1 right of the road's direction, -1 left): its base, falling
-- across the road to the other side.
function TheContractorFallenTree.getPlacement(roadX, roadZ, roadDirX, roadDirZ, side)
    local rightX, rightZ = roadDirZ, -roadDirX
    local offset = TheContractorFallenTree.BASE_OFFSET
    return {
        x = roadX + rightX * side * offset,
        z = roadZ + rightZ * side * offset,
        dirX = -rightX * side,
        dirZ = -rightZ * side,
        roadX = roadX,
        roadZ = roadZ,
        roadDirX = roadDirX,
        roadDirZ = roadDirZ,
    }
end

-- tcCompany event fallenTree here: the player's view line is the road, the
-- point FRONT_DISTANCE ahead its middle, and the tree falls across it from
-- their left.
function TheContractorFallenTree.getHerePlacement(px, pz, faceX, faceZ)
    local length = math.sqrt(faceX * faceX + faceZ * faceZ)
    if length < 0.001 then
        faceX, faceZ, length = 0, 1, 1
    end
    faceX, faceZ = faceX / length, faceZ / length
    local distance = TheContractorFallenTree.FRONT_DISTANCE
    return TheContractorFallenTree.getPlacement(px + faceX * distance, pz + faceZ * distance, faceX, faceZ, -1)
end

-- A piece of a felled tree: a split shape that's been cut and isn't static.
-- Standing map trees are static (on a client our pieces are kinematic, on
-- the server dynamic).
function TheContractorFallenTree.isLoosePiece(shape)
    return shape ~= nil and shape ~= 0 and entityExists(shape) and getHasClassId(shape, ClassIds.MESH_SPLIT_SHAPE) and
        getIsSplitShapeSplit(shape) and getRigidBodyType(shape) ~= RigidBodyType.STATIC
end

-- Finding a spot (server) --------------------------------------------------------------

-- Every road spline point, as { x, y, z, dirX, dirZ } with the direction
-- flat and normalised. Server only (vanilla only keeps the splines there).
function TheContractorFallenTree.sampleRoads()
    local samples = {}
    local aiSystem = g_currentMission.aiSystem
    if aiSystem == nil or aiSystem.getRoadSplines == nil then
        return samples
    end
    local step = TheContractorFallenTree.ROAD_SAMPLE_STEP
    for spline in pairs(aiSystem:getRoadSplines()) do
        local length = getSplineLength(spline)
        if length ~= nil and length > 0 then
            local count = math.max(1, math.floor(length / step))
            for i = 0, count do
                local t = i / count
                local x, y, z = getSplinePosition(spline, t)
                local dirX, _, dirZ = getSplineDirection(spline, t)
                local dirLength = math.sqrt(dirX * dirX + dirZ * dirZ)
                if dirLength > 0.001 then
                    table.insert(samples, { x = x, y = y, z = z, dirX = dirX / dirLength, dirZ = dirZ / dirLength })
                end
            end
        end
    end
    return samples
end

-- Where every player is, as { x, z }.
function TheContractorFallenTree.getPlayerPositions()
    local positions = {}
    local playerSystem = g_currentMission.playerSystem
    if playerSystem ~= nil and playerSystem.getPlayerCount ~= nil then
        for i = 1, playerSystem:getPlayerCount() do
            local player = playerSystem:getPlayerByIndex(i)
            if player ~= nil and player.getPosition ~= nil then
                local x, _, z = player:getPosition()
                if x ~= nil then
                    table.insert(positions, { x = x, z = z })
                end
            end
        end
    end
    return positions
end

local function isNear(x, z, points, distance)
    for _, point in ipairs(points) do
        local dx, dz = x - point.x, z - point.z
        if dx * dx + dz * dz < distance * distance then
            return true
        end
    end
    return false
end

-- The nearest field with no live job on it within MAX_FIELD_DISTANCE, or
-- nil: it names the job.
function TheContractorFallenTree.findNearestField(x, z)
    local jobs = g_currentMission.TheContractor.Jobs
    local best, bestDistanceSq = nil, TheContractorFallenTree.MAX_FIELD_DISTANCE ^ 2
    for _, field in ipairs(g_fieldManager:getFields()) do
        local fieldId = field:getId()
        if fieldId ~= nil and not jobs:isFieldProtected(fieldId) then
            local fx, fz = field:getCenterOfFieldWorldPosition()
            local distanceSq = (fx - x) ^ 2 + (fz - z) ^ 2
            if distanceSq < bestDistanceSq then
                best, bestDistanceSq = field, distanceSq
            end
        end
    end
    return best
end

-- Whether the ground along the fall never rises more than MAX_GROUND_RISE
-- over the base's.
function TheContractorFallenTree.isGroundFlatEnough(placement)
    local T = TheContractorFallenTree
    local baseY = getTerrainHeightAtWorldPos(g_terrainNode, placement.x, 0, placement.z)
    for along = T.ROOM_STEP, T.ROOM_LENGTH, T.ROOM_STEP do
        local y = getTerrainHeightAtWorldPos(g_terrainNode, placement.x + placement.dirX * along, 0,
            placement.z + placement.dirZ * along)
        if y > baseY + T.MAX_GROUND_RISE then
            return false
        end
    end
    return true
end

-- Whether nothing's in the trunk's way (ROOM_MASK) along the fall.
function TheContractorFallenTree.isFallLineClear(placement)
    local T = TheContractorFallenTree
    local half = T.ROOM_LENGTH * 0.5
    local cx, cz = placement.x + placement.dirX * half, placement.z + placement.dirZ * half
    local baseY = getTerrainHeightAtWorldPos(g_terrainNode, placement.x, 0, placement.z)
    local halfHeight = (T.ROOM_TOP - T.ROOM_FLOOR) * 0.5
    local rotY = MathUtil.getYRotationFromDirection(placement.dirX, placement.dirZ)
    local target = { blocked = false }
    function target:onOverlap(node)
        if node ~= g_terrainNode then
            self.blocked = true
            return false
        end
        return true
    end
    overlapBox(cx, baseY + T.ROOM_FLOOR + halfHeight, cz, 0, rotY, 0, T.TRUNK_HALF_WIDTH, halfHeight, half,
        "onOverlap", target, ROOM_MASK, true, true, true, true)
    return not target.blocked
end

-- Up to count road spots that work (see the header), as placements with
-- their fieldId. picked: placements already chosen for this incident (the
-- console's), kept away from, the first the one the rest spread round.
-- random is for the tests.
function TheContractorFallenTree:findRoadSpots(random, count, picked)
    local T = TheContractorFallenTree
    local found = {}
    if count <= 0 then
        return found
    end
    local samples = T.sampleRoads()
    for i = #samples, 2, -1 do
        local j = math.min(i, math.floor(random() * i) + 1)
        samples[i], samples[j] = samples[j], samples[i]
    end

    local players = T.getPlayerPositions()
    local taken = self:getOpenSpots()
    local first = picked ~= nil and picked[1] or nil
    for _, placement in ipairs(picked or {}) do
        table.insert(taken, { x = placement.roadX, z = placement.roadZ })
    end
    for i = 1, math.min(T.SPOT_TRIES, #samples) do
        local sample = samples[i]
        local side = random() < 0.5 and -1 or 1
        local placement = T.getPlacement(sample.x, sample.z, sample.dirX, sample.dirZ, side)
        local groundY = getTerrainHeightAtWorldPos(g_terrainNode, sample.x, 0, sample.z)
        if math.abs(groundY - sample.y) <= T.MAX_ROAD_HEIGHT_GAP and
                (first == nil or isNear(sample.x, sample.z, { { x = first.roadX, z = first.roadZ } }, T.MAX_SPREAD)) and
                not isNear(sample.x, sample.z, players, T.MIN_PLAYER_DISTANCE) and
                not isNear(sample.x, sample.z, taken, T.TREE_SEPARATION) and
                T.isGroundFlatEnough(placement) and T.isFallLineClear(placement) then
            local field = T.findNearestField(sample.x, sample.z)
            if field ~= nil then
                placement.fieldId = field:getId()
                table.insert(found, placement)
                table.insert(taken, { x = sample.x, z = sample.z })
                first = first or placement
                if #found >= count then
                    break
                end
            end
        end
    end
    return found
end

-- The road points of every open incident's trees, as { x, z }.
function TheContractorFallenTree:getOpenSpots()
    local spots = {}
    for _, incident in pairs(self.randomEvents.incidents) do
        if incident.eventType == TheContractorFallenTree.EVENT_TYPE then
            for _, tree in ipairs(TheContractorFallenTree.getTrees(incident.data)) do
                if tree.roadX ~= nil then
                    table.insert(spots, { x = tree.roadX, z = tree.roadZ })
                end
            end
        end
    end
    return spots
end

function TheContractorFallenTree:hasOpenTree(farmId)
    for _, incident in pairs(self.randomEvents.incidents) do
        if incident.eventType == TheContractorFallenTree.EVENT_TYPE and incident.farmId == farmId then
            return true
        end
    end
    return false
end

-- tcCompany event fallenTree [here]. Returns nil, or an error.
function TheContractorFallenTree:prepareConsole(details)
    if #details > 1 or (details[1] ~= nil and string.lower(details[1]) ~= "here") then
        return "Error: fallenTree takes nothing, or 'here' for a tree in front of you"
    end
    if details[1] ~= nil then
        if g_localPlayer == nil then
            return "Error: fallenTree here comes down in front of you, so it needs a player in the game"
        end
        self.consoleHere = true
    end
    return nil
end

-- canTrigger (068): the incident's starting data, or nil.
function TheContractorFallenTree:pickSpot(farmId, random)
    local T = TheContractorFallenTree
    local manager = g_treePlantManager
    local treeType = manager ~= nil and manager:getTreeTypeDescFromName(T.TREE_TYPE) or nil
    if treeType == nil or manager.loadTreeTrunkDatas == nil or self:hasOpenTree(farmId) then
        return nil
    end

    local count = T.TREES_MIN + math.min(T.TREES_MAX - T.TREES_MIN,
        math.floor(random() * (T.TREES_MAX - T.TREES_MIN + 1)))
    -- tcCompany event fallenTree here: the first in front of the player,
    -- and that one will do on its own.
    local placements = {}
    local fewest = T.TREES_MIN
    if self.consoleHere then
        local px, _, pz = g_localPlayer:getPosition()
        local faceX, faceZ = g_localPlayer:getCurrentFacingDirection()
        local placement = T.getHerePlacement(px, pz, faceX, faceZ)
        local field = T.findNearestField(placement.roadX, placement.roadZ)
        if field == nil then
            return nil
        end
        placement.fieldId = field:getId()
        table.insert(placements, placement)
        fewest = 1
    end
    for _, placement in ipairs(self:findRoadSpots(random, count - #placements, placements)) do
        table.insert(placements, placement)
    end
    if #placements < fewest then
        return nil
    end

    local stage = #treeType.stages
    local variations = #treeType.stages[stage]
    local trees = {}
    for _, placement in ipairs(placements) do
        table.insert(trees, {
            variation = math.min(variations, 1 + math.floor(random() * variations)),
            x = placement.x,
            y = getTerrainHeightAtWorldPos(g_terrainNode, placement.x, 0, placement.z) + T.SPAWN_HEIGHT,
            z = placement.z,
            dirX = placement.dirX,
            dirZ = placement.dirZ,
            roadX = placement.roadX,
            roadZ = placement.roadZ,
            roadDirX = placement.roadDirX,
            roadDirZ = placement.roadDirZ,
            fieldId = placement.fieldId,
            shapeId1 = 0,
            shapeId2 = 0,
            shapeId3 = 0,
            isClear = false,
        })
    end
    local data = {
        treeType = treeType.name,
        stage = stage,
        fieldId = placements[1].fieldId,
        jobId = 0,
    }
    T.setTrees(data, trees)
    return data
end

-- The tree coming down (server) ----------------------------------------------------------

-- Plants them (see the header); update() queues vanilla's cuts
-- CUT_DELAY_MS later and moves it on once they've run.
function TheContractorFallenTree:onFalling(incident)
    local data = incident.data
    local manager = g_treePlantManager
    local treeType = manager ~= nil and manager:getTreeTypeDescFromName(data.treeType) or nil
    if treeType == nil or manager.loadTreeTrunkDatas == nil then
        TCLog.warning("TheContractor: incident %d: no tree type '%s' to plant", incident.id, tostring(data.treeType))
        return TheContractorRandomEvents.DONE
    end
    local fall = { plantedAt = g_time or 0, isQueued = false, trees = {} }
    local planted = 0
    for _, tree in ipairs(TheContractorFallenTree.getTrees(data)) do
        if not manager:canPlantTree() then
            TCLog.warning("TheContractor: incident %d: the map has as many trees as it can take", incident.id)
            break
        end
        local node = manager:plantTree(treeType.index, tree.x, tree.y, tree.z, 0, 0, 0, data.stage, tree.variation,
            false)
        local shape = node ~= nil and node ~= 0 and SplitShapeUtil.getSplitShapeId(node) or nil
        if shape == nil then
            TCLog.warning("TheContractor: incident %d: planting %s %d failed", incident.id, data.treeType, tree.index)
        else
            fall.trees[tree.index] = { shape = shape }
            planted = planted + 1
            TCLog.info("TheContractor: farm %d incident %d: planted %s %d (stage %d, variation %d) at %.1f, %.1f to fall across the road towards %.2f, %.2f",
                incident.farmId, incident.id, data.treeType, tree.index, data.stage, tree.variation, tree.x, tree.z,
                tree.dirX, tree.dirZ)
        end
    end
    if planted == 0 then
        return TheContractorRandomEvents.DONE
    end
    self.pendingFalls[incident.id] = fall
    return TheContractorRandomEvents.WAIT
end

-- loadTreeTrunk's own entry for a tree, with the right shape (it guesses
-- node + 2).
function TheContractorFallenTree.queueCut(tree, shape)
    local entry = {
        framesLeft = 2,
        shape = shape,
        x = tree.x,
        y = tree.y,
        z = tree.z,
        length = TheContractorFallenTree.TRUNK_LENGTH,
        offset = 0.5,
        dirX = tree.dirX,
        dirY = 0,
        dirZ = tree.dirZ,
        delimb = false,
        useOnlyStump = false,
        cutTreeTrunkCallback = TreePlantManager.cutTreeTrunkCallback,
    }
    table.insert(g_treePlantManager.loadTreeTrunkDatas, entry)
    return entry
end

-- Whether vanilla has run every queued cut of a fall (it takes each entry
-- off its list).
local function areCutsDone(fall)
    for _, queued in ipairs(g_treePlantManager.loadTreeTrunkDatas) do
        for _, treeFall in pairs(fall.trees) do
            if queued == treeFall.entry then
                return false
            end
        end
    end
    return true
end

-- The trunk after the cut: the part above the stump cut that's still there.
function TheContractorFallenTree.findTrunk(entry)
    for _, part in ipairs(entry.parts or {}) do
        if not part.isBelow and part.shape ~= nil and entityExists(part.shape) then
            return part.shape
        end
    end
    return nil
end

-- Vanilla only marks the area round a tree's base; the whole length is in
-- the way now (and out of it, once it's gone), for AI and for tipping onto
-- the ground.
function TheContractorFallenTree.markAreaDirty(tree)
    local minX, maxX, minZ, maxZ = TheContractorFallenTree.getCorridorBounds(tree)
    if g_densityMapHeightManager ~= nil then
        g_densityMapHeightManager:setCollisionMapAreaDirty(minX, minZ, maxX, maxZ, true)
    end
    if g_currentMission.aiSystem ~= nil then
        g_currentMission.aiSystem:setAreaDirty(minX, maxX, minZ, maxZ)
    end
end

-- Down: any tree that didn't plant or left no trunk dropped, and the job
-- offered for the rest.
function TheContractorFallenTree:onDown(incident, fall)
    local T = TheContractorFallenTree
    self.pendingFalls[incident.id] = nil
    local data = incident.data
    local down = {}
    for _, tree in ipairs(T.getTrees(data)) do
        local treeFall = fall.trees[tree.index]
        local trunk = treeFall ~= nil and T.findTrunk(treeFall.entry) or nil
        if trunk ~= nil then
            tree.shapeId1, tree.shapeId2, tree.shapeId3 = getSaveableSplitShapeId(trunk)
            T.markAreaDirty(tree)
            table.insert(down, tree)
        elseif treeFall ~= nil then
            TCLog.warning("TheContractor: incident %d: vanilla's cut left no trunk of %s %d", incident.id,
                data.treeType, tree.index)
        end
    end
    if #down == 0 then
        self.randomEvents:closeIncident(incident)
        return
    end
    T.setTrees(data, down)
    data.fieldId = down[1].fieldId

    local job = self:offerJob(incident)
    if job == nil then
        for _, tree in ipairs(down) do
            T.clearTree(tree)
        end
        self.randomEvents:closeIncident(incident)
        return
    end
    data.jobId = job.id
    TCLog.info("TheContractor: farm %d incident %d: %d %s(s) down across the roads around field %d, job %d offered at %.0f",
        incident.farmId, incident.id, data.treeCount, data.treeType, data.fieldId, job.id, job:getPrice())
    self.randomEvents:goToStage(incident, T.STAGE.OPEN)
end

-- What the council pays: PRICE_PER_TREE_MIN-PRICE_PER_TREE_MAX for each of
-- treeCount trees, at the default job pay rate (the setting's multiplier
-- over its default, JOB_PAY_BASELINE). roll (0-1). The base price, as jobs
-- store it.
function TheContractorFallenTree.getBasePrice(roll, treeCount)
    local T = TheContractorFallenTree
    local perTree = T.PRICE_PER_TREE_MIN + roll * (T.PRICE_PER_TREE_MAX - T.PRICE_PER_TREE_MIN)
    local payRate = g_currentMission.TheContractor.Settings:getJobPayMultiplier() /
        TheContractorJobGeneration.JOB_PAY_BASELINE
    return math.floor(perTree * treeCount * payRate + 0.5)
end

-- The fields naming the trees, each once, in order: "12, 7".
function TheContractorFallenTree.getFieldNames(data)
    local names, seen = {}, {}
    for _, tree in ipairs(TheContractorFallenTree.getTrees(data)) do
        if tree.fieldId ~= nil and not seen[tree.fieldId] then
            seen[tree.fieldId] = true
            local field = g_fieldManager:getFieldById(tree.fieldId)
            table.insert(names, field ~= nil and field:getName() or tostring(tree.fieldId))
        end
    end
    return table.concat(names, ", ")
end

-- Due by the end of today.
function TheContractorFallenTree:offerJob(incident)
    local tc = g_currentMission.TheContractor
    local environment = g_currentMission.environment
    local today = environment.currentMonotonicDay
    local data = incident.data
    local job = tc.Jobs:createJob(incident.farmId, TheContractorFallenTree.JOB_TYPE, data.fieldId, 1,
        environment:getPeriodFromDay(today), environment:getDayInPeriodFromDay(today),
        TheContractorFallenTree.getBasePrice(math.random(), data.treeCount), true, nil, today)
    if job == nil then
        return nil
    end
    local field = g_fieldManager:getFieldById(data.fieldId)
    tc.Inbox:postMessage(incident.farmId, TheContractorFallenTree.MESSAGE_KIND, "tc_fallenTree_offerTitle",
        "tc_fallenTree_offerBody", { field ~= nil and field:getName() or tostring(data.fieldId),
            tostring(data.treeCount), TheContractorFallenTree.getFieldNames(data),
            "$money_" .. math.floor(job:getPrice()) }, nil, { incidentId = incident.id, jobId = job.id })
    return job
end

-- Every frame while they're coming down: the cuts queued once the clients
-- have had the trees, and the trees down once vanilla's run them.
function TheContractorFallenTree:checkFalls()
    for _, incident in ipairs(self:getIncidentsAt(TheContractorFallenTree.STAGE.FALLING)) do
        local fall = self.pendingFalls[incident.id]
        if fall == nil then
            -- Saved between planting and the cut: vanilla's queue isn't
            -- saved, so it may be standing. Nothing's been offered yet.
            TCLog.warning("TheContractor: incident %d: the %ss' fall was lost in a save, they may be standing",
                incident.id, incident.data.treeType)
            self.randomEvents:closeIncident(incident)
        elseif not fall.isQueued then
            if (g_time or 0) - fall.plantedAt >= TheContractorFallenTree.CUT_DELAY_MS then
                fall.isQueued = true
                for i = 1, incident.data.treeCount do
                    local treeFall = fall.trees[i]
                    if treeFall ~= nil then
                        treeFall.entry = TheContractorFallenTree.queueCut(
                            TheContractorFallenTree.getTree(incident.data, i), treeFall.shape)
                    end
                end
            end
        elseif areCutsDone(fall) then
            self:onDown(incident, fall)
        end
    end
end

-- The job (server) ---------------------------------------------------------------------

function TheContractorFallenTree:getIncidentsAt(stage)
    local result = {}
    for _, incident in pairs(self.randomEvents.incidents) do
        if incident.eventType == TheContractorFallenTree.EVENT_TYPE and incident.stage == stage then
            table.insert(result, incident)
        end
    end
    table.sort(result, function(a, b)
        return a.id < b.id
    end)
    return result
end

-- The open incident for a job, or nil. Every machine.
function TheContractorFallenTree.getIncidentForJob(job)
    local tc = g_currentMission.TheContractor
    if job == nil or tc == nil or tc.RandomEvents == nil then
        return nil
    end
    for _, incident in pairs(tc.RandomEvents.incidents) do
        if incident.eventType == TheContractorFallenTree.EVENT_TYPE and incident.data.jobId == job.id then
            return incident
        end
    end
    return nil
end

-- TCJobProgress (server): the share of the roads clear, done once they all
-- are.
function TheContractorFallenTree.getJobCompletion(job)
    local incident = TheContractorFallenTree.getIncidentForJob(job)
    local count = incident ~= nil and incident.data.treeCount or 0
    if count == 0 then
        return 0
    end
    return TheContractorFallenTree.countClear(incident.data) / count
end

-- TCJobHotspots (every machine): where its map markers go, a { x, z,
-- index } on the road of each tree that isn't clear yet. Empty for any
-- other job.
function TheContractorFallenTree.getJobSpots(job)
    local spots = {}
    if job.jobType ~= TheContractorFallenTree.JOB_TYPE then
        return spots
    end
    local incident = TheContractorFallenTree.getIncidentForJob(job)
    if incident == nil then
        return spots
    end
    for _, tree in ipairs(TheContractorFallenTree.getTrees(incident.data)) do
        if not tree.isClear and tree.roadX ~= nil then
            table.insert(spots, { x = tree.roadX, z = tree.roadZ, index = tree.index })
        end
    end
    return spots
end

-- Whether any loose piece is on a tree's road.
function TheContractorFallenTree.hasPiecesOnRoad(tree)
    local T = TheContractorFallenTree
    local cy = getTerrainHeightAtWorldPos(g_terrainNode, tree.roadX, 0, tree.roadZ)
    local rotY = MathUtil.getYRotationFromDirection(tree.roadDirX, tree.roadDirZ)
    local target = { found = false }
    function target:onOverlap(node)
        if TheContractorFallenTree.isLoosePiece(node) then
            self.found = true
            return false
        end
        return true
    end
    overlapBox(tree.roadX, cy, tree.roadZ, 0, rotY, 0, T.ROAD_HALF_WIDTH, T.CHECK_HALF_HEIGHT, T.ROAD_CLEAR_HALF_LENGTH,
        "onOverlap", target, CollisionFlag.TREE + CollisionFlag.DYNAMIC_OBJECT, true, true, false, true)
    return target.found
end

-- The council's crew: every loose piece on a tree's site, gone. Returns
-- how many.
function TheContractorFallenTree.clearTree(tree)
    local T = TheContractorFallenTree
    local half = (T.CORRIDOR_LENGTH + T.SITE_MARGIN * 2) * 0.5
    local along = T.CORRIDOR_LENGTH * 0.5
    local cx, cz = tree.x + tree.dirX * along, tree.z + tree.dirZ * along
    local cy = getTerrainHeightAtWorldPos(g_terrainNode, cx, 0, cz)
    local rotY = MathUtil.getYRotationFromDirection(tree.dirX, tree.dirZ)
    local target = { pieces = {}, seen = {} }
    function target:onOverlap(node)
        if not self.seen[node] and TheContractorFallenTree.isLoosePiece(node) then
            self.seen[node] = true
            table.insert(self.pieces, node)
        end
        return true
    end
    overlapBox(cx, cy, cz, 0, rotY, 0, T.CORRIDOR_HALF_WIDTH + T.SITE_MARGIN, T.CHECK_HALF_HEIGHT, half, "onOverlap",
        target, CollisionFlag.TREE + CollisionFlag.DYNAMIC_OBJECT, true, true, false, true)
    for _, shape in ipairs(target.pieces) do
        delete(shape)
    end
    TheContractorFallenTree.markAreaDirty(tree)
    return #target.pieces
end

-- Every CHECK_INTERVAL_MS: each open incident's job, and its roads.
function TheContractorFallenTree:checkJobs()
    local STATE = TheContractorJob.STATE
    local tc = g_currentMission.TheContractor
    for _, incident in ipairs(self:getIncidentsAt(TheContractorFallenTree.STAGE.OPEN)) do
        local data = incident.data
        local job = tc.Jobs:getJob(incident.farmId, data.jobId)
        local state = job ~= nil and job.state or nil
        if state == nil or state == STATE.DECLINED or state == STATE.MISSED then
            if state == STATE.DECLINED then
                tc.Reputation:addReputation(incident.farmId, -TheContractorFallenTree.DECLINE_REPUTATION_PENALTY)
            end
            local count = 0
            for _, tree in ipairs(TheContractorFallenTree.getTrees(data)) do
                count = count + TheContractorFallenTree.clearTree(tree)
            end
            TCLog.info("TheContractor: farm %d incident %d: job %d %s, the council cleared the %ss (%d piece(s))",
                incident.farmId, incident.id, data.jobId, tostring(state), data.treeType, count)
            self:close(incident)
        elseif state == STATE.COMPLETED then
            TCLog.info("TheContractor: farm %d incident %d: the roads are clear, job %d done", incident.farmId,
                incident.id, data.jobId)
            self:close(incident)
        elseif state == STATE.ALLOCATED or state == STATE.IN_PROGRESS then
            self:checkRoads(incident)
        end
    end
end

-- Each road not clear yet: nothing of its tree on it for CLEAR_CHECKS
-- checks running and it is.
function TheContractorFallenTree:checkRoads(incident)
    local T = TheContractorFallenTree
    local data = incident.data
    local counts = self.clearCounts[incident.id] or {}
    self.clearCounts[incident.id] = counts
    local changed = false
    for _, tree in ipairs(T.getTrees(data)) do
        if not tree.isClear then
            if T.hasPiecesOnRoad(tree) then
                counts[tree.index] = 0
            else
                counts[tree.index] = (counts[tree.index] or 0) + 1
                if counts[tree.index] >= T.CLEAR_CHECKS then
                    counts[tree.index] = nil
                    T.setTreeValue(data, tree.index, "isClear", true)
                    T.markAreaDirty(tree)
                    changed = true
                    TCLog.info("TheContractor: farm %d incident %d: the road's clear of %s %d (%d of %d)",
                        incident.farmId, incident.id, data.treeType, tree.index, T.countClear(data), data.treeCount)
                end
            end
        end
    end
    if changed then
        self.randomEvents:commitIncident(incident)
    end
end

function TheContractorFallenTree:close(incident)
    self.clearCounts[incident.id] = nil
    self.randomEvents:closeIncident(incident)
    TheContractorFallenTree.refreshSites()
end

-- The site's access (every machine) ------------------------------------------------------

local function isTakenOn(state)
    return state == TheContractorJob.STATE.ACCEPTED or state == TheContractorJob.STATE.ALLOCATED or
        state == TheContractorJob.STATE.IN_PROGRESS
end

function TheContractorFallenTree.refreshSites()
    local tc = g_currentMission.TheContractor
    local result = {}
    if tc ~= nil and tc.RandomEvents ~= nil and tc.Jobs ~= nil then
        for _, incident in pairs(tc.RandomEvents.incidents) do
            if incident.eventType == TheContractorFallenTree.EVENT_TYPE then
                local job = tc.Jobs:getJob(incident.farmId, incident.data.jobId)
                if job ~= nil and isTakenOn(job.state) then
                    result[incident.farmId] = result[incident.farmId] or {}
                    for _, tree in ipairs(TheContractorFallenTree.getTrees(incident.data)) do
                        table.insert(result[incident.farmId], tree)
                    end
                end
            end
        end
    end
    sitesByFarm = result
end

-- Whether a point is on the site of a tree of one of the farm's taken-on
-- jobs.
function TheContractorFallenTree.isOnSite(farmId, x, z)
    local sites = farmId ~= nil and sitesByFarm[farmId] or nil
    if sites == nil or x == nil or z == nil then
        return false
    end
    for _, tree in ipairs(sites) do
        if TheContractorFallenTree.isInCorridor(tree, x, z, TheContractorFallenTree.SITE_MARGIN) then
            return true
        end
    end
    return false
end

-- Every machine: the sites; the server also moves falls on every frame
-- (the cut takes two) and checks the jobs every CHECK_INTERVAL_MS.
function TheContractorFallenTree:update(dt)
    if self.randomEvents == nil then
        return
    end
    self.refreshMs = self.refreshMs + dt
    if self.refreshMs >= TheContractorFallenTree.SITE_REFRESH_MS then
        self.refreshMs = 0
        TheContractorFallenTree.refreshSites()
    end

    if not g_currentMission:getIsServer() then
        return
    end
    self:checkFalls()
    self.checkMs = self.checkMs + dt
    if self.checkMs < TheContractorFallenTree.CHECK_INTERVAL_MS then
        return
    end
    self.checkMs = 0
    self:checkJobs()
end

-- Cutting on the site ------------------------------------------------------------------
--
-- Vanilla's check, then (if it said no) a loose piece on the site of one of
-- the farm's taken-on jobs, with the cutTrees permission. A no for any
-- other reason (a yarder using the tree) is overridden too on a site;
-- there are none on a road. SplitShapeManager outlives any one savegame, so
-- guard against wrapping it twice.

if SplitShapeManager ~= nil and SplitShapeManager.getIsShapeCutAllowed ~= nil and
        SplitShapeManager.tcOriginalGetIsShapeCutAllowed == nil then
    SplitShapeManager.tcOriginalGetIsShapeCutAllowed = SplitShapeManager.getIsShapeCutAllowed

    function SplitShapeManager:getIsShapeCutAllowed(x, z, shape, farmId, connection)
        if SplitShapeManager.tcOriginalGetIsShapeCutAllowed(self, x, z, shape, farmId, connection) then
            return true
        end
        if TheContractorFallenTree.isOnSite(farmId, x, z) and TheContractorFallenTree.isLoosePiece(shape) then
            return g_currentMission:getHasPlayerPermission("cutTrees", connection)
        end
        return false
    end
end
