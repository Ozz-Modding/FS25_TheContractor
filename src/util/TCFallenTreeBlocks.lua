-- Fallen tree (107): a traffic block on each fallen tree's road, on every
-- machine, from the incidents' synced data. The map's traffic drives
-- through a tree's collision, shoving the trunk along the road (and
-- off it: issue 19, where two roads counted as clear untouched). Traffic
-- brakes for players, though, so each tree that's down and whose road
-- isn't clear yet gets 151's crowd block (i3d/protestCrowdBlock.i3d: an
-- invisible kinematic box flagged as a player, its mask traffic alone, so
-- players, their vehicles and the wood itself go through it), centred
-- where the trunk crosses the road and turned along it. A tree's block
-- goes as its road's clear, and the rest with the incident when the job's
-- done, turned down or missed. It goes down regardless of what's there,
-- as the crowd block does. Nothing here is saved or sent.

TCFallenTreeBlocks = {}

TCFallenTreeBlocks.FILENAME = "i3d/protestCrowdBlock.i3d"
-- How often the blocks are checked against the incidents (ms).
TCFallenTreeBlocks.INTERVAL_MS = 1000

-- "<incident id>:<tree index>" -> { node, x, z }.
TCFallenTreeBlocks.blocks = {}
TCFallenTreeBlocks.elapsedMs = 0

-- The block template: { requestId, node } (node nil while loading, false
-- if it failed), and a generation so a load finishing after a reset is
-- thrown away.
TCFallenTreeBlocks.template = nil
TCFallenTreeBlocks.generation = 0

function TCFallenTreeBlocks.onTemplateLoaded(_, root, failedReason, args)
    local entry = TCFallenTreeBlocks.template
    if entry == nil or entry.generation ~= args.generation then
        if root ~= nil and root ~= 0 then
            delete(root)
        end
        return
    end
    if root == nil or root == 0 then
        TCLog.warning("TheContractor: fallen tree traffic block '%s' could not be loaded", args.filename)
        entry.node = false
        return
    end
    entry.node = root
end

-- The loaded model's root to clone from, or nil (loading, or failed).
local function getTemplate()
    local entry = TCFallenTreeBlocks.template
    if entry == nil then
        TCFallenTreeBlocks.generation = TCFallenTreeBlocks.generation + 1
        entry = { generation = TCFallenTreeBlocks.generation }
        TCFallenTreeBlocks.template = entry
        local path = Utils.getFilename(TCFallenTreeBlocks.FILENAME, TheContractor.dir)
        entry.requestId = g_i3DManager:loadSharedI3DFileAsync(path, false, false,
            TCFallenTreeBlocks.onTemplateLoaded, nil, { filename = path, generation = entry.generation })
    end
    return entry.node or nil
end

-- The blocks wanted now: key -> { x, z, yaw }, one on the road of each
-- tree of an open fallen tree incident that isn't clear. A tree only
-- planted, its cut to come, already gets one: it comes down in seconds.
function TCFallenTreeBlocks.getWanted(incidents)
    local wanted = {}
    for _, incident in pairs(incidents or {}) do
        if incident.eventType == TheContractorFallenTree.EVENT_TYPE and incident.data ~= nil then
            for _, tree in ipairs(TheContractorFallenTree.getTrees(incident.data)) do
                if not tree.isClear and tree.roadX ~= nil and tree.roadDirX ~= nil then
                    wanted[incident.id .. ":" .. tree.index] = {
                        x = tree.roadX,
                        z = tree.roadZ,
                        yaw = math.atan2(tree.roadDirX, tree.roadDirZ),
                    }
                end
            end
        end
    end
    return wanted
end

local function removeBlock(key)
    local block = TCFallenTreeBlocks.blocks[key]
    if block ~= nil then
        if entityExists(block.node) then
            removeFromPhysics(block.node)
            delete(block.node)
        end
        TCFallenTreeBlocks.blocks[key] = nil
    end
end

local function placeBlock(key, spot, template)
    local node = clone(getChildAt(template, 0), false, false, false)
    link(getRootNode(), node)
    setTranslation(node, spot.x, getTerrainHeightAtWorldPos(g_terrainNode, spot.x, 0, spot.z), spot.z)
    setRotation(node, 0, spot.yaw, 0)
    addToPhysics(node)
    TCFallenTreeBlocks.blocks[key] = { node = node, x = spot.x, z = spot.z }
end

-- Brings the blocks in line with the incidents: a block whose tree is
-- gone, clear or (renumbered once they're down) elsewhere goes, and one
-- goes down for each tree without one.
function TCFallenTreeBlocks.refresh(incidents)
    local wanted = TCFallenTreeBlocks.getWanted(incidents)
    for key, block in pairs(TCFallenTreeBlocks.blocks) do
        local spot = wanted[key]
        if spot == nil or spot.x ~= block.x or spot.z ~= block.z then
            removeBlock(key)
        end
    end
    if next(wanted) == nil then
        return
    end
    local template = getTemplate()
    if template == nil then
        return
    end
    for key, spot in pairs(wanted) do
        if TCFallenTreeBlocks.blocks[key] == nil then
            placeBlock(key, spot, template)
        end
    end
end

-- Every machine, every frame.
function TCFallenTreeBlocks.update(dt)
    local tc = g_currentMission ~= nil and g_currentMission.TheContractor or nil
    if tc == nil or tc.RandomEvents == nil then
        return
    end
    TCFallenTreeBlocks.elapsedMs = TCFallenTreeBlocks.elapsedMs + dt
    if TCFallenTreeBlocks.elapsedMs < TCFallenTreeBlocks.INTERVAL_MS then
        return
    end
    TCFallenTreeBlocks.elapsedMs = 0
    TCFallenTreeBlocks.refresh(tc.RandomEvents.incidents)
end

-- How many blocks are down on this machine.
function TCFallenTreeBlocks.count()
    local count = 0
    for _ in pairs(TCFallenTreeBlocks.blocks) do
        count = count + 1
    end
    return count
end

-- deleteMap.
function TCFallenTreeBlocks.reset()
    for key in pairs(TCFallenTreeBlocks.blocks) do
        removeBlock(key)
    end
    TCFallenTreeBlocks.blocks = {}
    local entry = TCFallenTreeBlocks.template
    if entry ~= nil then
        if entry.node then
            delete(entry.node)
        end
        if entry.requestId ~= nil then
            g_i3DManager:releaseSharedI3DFile(entry.requestId)
        end
    end
    TCFallenTreeBlocks.template = nil
    TCFallenTreeBlocks.elapsedMs = 0
end
