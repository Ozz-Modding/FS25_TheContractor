-- Protest (151): the engine half, on every machine, from each protest
-- incident's synced data (TheContractorProtest, TCProtestLayout.layOut):
--   - the people (a machine with a client): TCFigures' standers, playing
--     vanilla's NPC idle, all there while the protest's out;
--   - their placards (a machine with a client): i3d/protestPlacard.i3d,
--     showing the person's slogan on their style of board (white card or a
--     chalkboard), held as vanilla holds a hand tool
--     (HandTool:attachToolToHand): linked once, as the person's model
--     loads, under its thirdPersonRightHandNode with
--     HandToolUtil.linkAndTransformRelativeToParent, the placard's own
--     handNode (GRIP) lining up with the hand. It moves with the hand from
--     then on, and goes with the model;
--   - a collision block for each person (every machine, a dedicated server
--     too: it runs the vehicles' physics), so players and their vehicles
--     stop at them; and one crowd block round each group for the map's
--     traffic (protestCrowdBlock.i3d), flagged as a player, since traffic
--     brakes for players (TrafficSystem's stopMask) but drives through
--     static objects. Its mask is traffic alone, so players still walk in
--     among the crowd. A person's block isn't put where a vehicle, player
--     or traffic is; it's tried again until the spot's clear. The crowd
--     block goes down regardless: nothing but traffic meets it, and a check
--     over 9 m of road kept it waiting while anyone stood in the crowd or
--     traffic went by (seen in game);
--   - a map marker for each group (the protest's own farm only), from the
--     warning the evening before until it's over.
-- Nothing here is saved or sent: it's all rebuilt from the incident.

TCProtestCrowd = {}

TCProtestCrowd.PLACARD_FILENAME = "i3d/protestPlacard.i3d"
TCProtestCrowd.BLOCK_FILENAME = "i3d/protestBlock.i3d"
TCProtestCrowd.CROWD_BLOCK_FILENAME = "i3d/protestCrowdBlock.i3d"
-- The placard's handNode, which lines up with the hand bone: its
-- translation (metres) and rotation (degrees) in the placard's own frame.
-- Tuned in game with tcDebug protestPlacard (2026-11-14), starting from the
-- base game's flashlight's handNode (data/handTools/brandless/flashlight:
-- 0 0 0, -169.8 13.3 91.9), whose +Z points the beam ahead and +Y up, as
-- the placard's board faces +Z with its pole up +Y. The model's handNode
-- carries the same (genProtestPlacardI3d.py's GRIP_*): keep them alike.
TCProtestCrowd.GRIP = { -0.05, 0.2, -0.05, -110.8, 8.5, 91.9 }
-- protestPlacard.i3d: visuals (0) > faces (2) > one per slogan; handNode (1).
TCProtestCrowd.FACES_INDEX = 2
-- protestPlacard.i3d: visuals (0) > boards (1) > one per style.
TCProtestCrowd.BOARDS_INDEX = 1
TCProtestCrowd.HAND_NODE_INDEX = 1
-- How often blocks are checked (ms).
TCProtestCrowd.BLOCK_INTERVAL_MS = 1000
-- The room a block needs clear of vehicles and players (half sizes).
TCProtestCrowd.BLOCK_HALF_SIZE = 0.45
TCProtestCrowd.BLOCK_HEIGHT = 2
-- The crowd block's half side (genProtestPlacardI3d.py's CROWD_HALF): a
-- body ignores its i3d's scale, so it's one size, room for the biggest
-- group's circle (TCProtestLayout.getRadius(PEOPLE_MAX)) and a margin.
TCProtestCrowd.CROWD_BLOCK_HALF = 4.6

local BLOCK_CLEAR_MASK = CollisionFlag ~= nil and (CollisionFlag.VEHICLE + CollisionFlag.PLAYER +
    CollisionFlag.TRAFFIC_VEHICLE + CollisionFlag.DYNAMIC_OBJECT) or 0

-- incidentId -> { incident, seed, people, figures (client), blocks =
-- { [person index or "g<group>"] = node }, markers = { hotspot, ... } }.
TCProtestCrowd.active = {}
-- Loaded templates: name -> { requestId, node } (node nil while loading,
-- false if it failed).
TCProtestCrowd.templates = {}
TCProtestCrowd.blockMs = 0

local function hasClient()
    return g_dedicatedServer == nil and g_currentMission:getIsClient()
end

-- Templates ---------------------------------------------------------------------------------

function TCProtestCrowd.onTemplateLoaded(_, root, failedReason, args)
    local entry = TCProtestCrowd.templates[args.name]
    if entry == nil or entry.generation ~= args.generation then
        if root ~= nil and root ~= 0 then
            delete(root)
        end
        return
    end
    if root == nil or root == 0 then
        TCLog.warning("TheContractor: protest model '%s' could not be loaded", args.filename)
        entry.node = false
        return
    end
    entry.node = root
end

-- A loaded model's root to clone from, or nil (loading, or failed).
local function getTemplate(name, filename)
    local entry = TCProtestCrowd.templates[name]
    if entry == nil then
        TCProtestCrowd.generation = (TCProtestCrowd.generation or 0) + 1
        entry = { generation = TCProtestCrowd.generation }
        TCProtestCrowd.templates[name] = entry
        local path = Utils.getFilename(filename, TheContractor.dir)
        entry.requestId = g_i3DManager:loadSharedI3DFileAsync(path, false, false, TCProtestCrowd.onTemplateLoaded,
            nil, { name = name, filename = path, generation = entry.generation })
    end
    return entry.node or nil
end

local function releaseTemplates()
    for _, entry in pairs(TCProtestCrowd.templates) do
        if entry.node then
            delete(entry.node)
        end
        if entry.requestId ~= nil then
            g_i3DManager:releaseSharedI3DFile(entry.requestId)
        end
    end
    TCProtestCrowd.templates = {}
end

-- A copy of the template's first child, linked to the scene's root.
local function cloneFrom(template)
    local node = clone(getChildAt(template, 0), false, false, false)
    link(getRootNode(), node)
    return node
end

-- Placards ----------------------------------------------------------------------------------

-- Shows one slogan's face (1 to SLOGAN_COUNT), the rest hidden.
-- Shows one style's board (TCProtestLayout.STYLE) and its slogan's face
-- (faces are style by style, the slogans in order in each); the rest
-- hidden.
function TCProtestCrowd.setSlogan(node, slogan, style)
    style = style or TCProtestLayout.STYLE.CARD
    local visuals = getChildAt(node, 0)
    local boards = getChildAt(visuals, TCProtestCrowd.BOARDS_INDEX)
    for i = 0, getNumOfChildren(boards) - 1 do
        setVisibility(getChildAt(boards, i), i == style - 1)
    end
    local shown = (style - 1) * TCProtestLayout.SLOGAN_COUNT + slogan - 1
    local faces = getChildAt(visuals, TCProtestCrowd.FACES_INDEX)
    for i = 0, getNumOfChildren(faces) - 1 do
        setVisibility(getChildAt(faces, i), i == shown)
    end
end

local function freePlacard(figure)
    if figure.placard ~= nil then
        if entityExists(figure.placard) then
            delete(figure.placard)
        end
        figure.placard = nil
    end
end

local function getHandNode(figure)
    local model = figure.graphics ~= nil and figure.graphics.model or nil
    return model ~= nil and model.thirdPersonRightHandNode or nil
end

-- Puts the placard's handNode where GRIP says, then lines it up with the
-- hand (vanilla's transformRelativeToParent: the placard's root is placed
-- under the hand so its handNode sits on the hand bone).
function TCProtestCrowd.applyGrip(placard, hand)
    local g = TCProtestCrowd.GRIP
    local handNode = getChildAt(placard, TCProtestCrowd.HAND_NODE_INDEX)
    setTranslation(handNode, g[1], g[2], g[3])
    setRotation(handNode, math.rad(g[4]), math.rad(g[5]), math.rad(g[6]))
    HandToolUtil.transformRelativeToParent(placard, handNode, hand)
end

-- Hands a placard with the person's slogan to a loaded figure, once.
-- Returns false if it has to wait (the model's still loading).
function TCProtestCrowd.attachPlacard(figure)
    if figure.slogan == nil or figure.placard ~= nil then
        return true
    end
    local hand = getHandNode(figure)
    local template = getTemplate("placard", TCProtestCrowd.PLACARD_FILENAME)
    if hand == nil or hand == 0 or template == nil then
        return false
    end
    local placard = clone(getChildAt(template, 0), false, false, false)
    TCProtestCrowd.setSlogan(placard, figure.slogan, figure.style)
    link(hand, placard)
    TCProtestCrowd.applyGrip(placard, hand)
    figure.placard = placard
    return true
end

-- tcDebug protestPlacard: every placard held on this machine takes the
-- grip again.
function TCProtestCrowd.regrip()
    local count = 0
    for _, entry in pairs(TCProtestCrowd.active) do
        for _, figure in ipairs(entry.figures) do
            local hand = getHandNode(figure)
            if figure.placard ~= nil and hand ~= nil and hand ~= 0 then
                TCProtestCrowd.applyGrip(figure.placard, hand)
                count = count + 1
            end
        end
    end
    return count
end

local FIGURE_HOOKS = {
    onLoaded = function(figure)
        TCProtestCrowd.attachPlacard(figure)
    end,
    onFreed = freePlacard,
}

-- Blocks ------------------------------------------------------------------------------------

-- Our own blocks' shapes, which the clear check looks past (the crowd
-- block is flagged as a player).
TCProtestCrowd.ownShapes = {}

local function setOwn(node, isOwn)
    TCProtestCrowd.ownShapes[node] = isOwn or nil
    for i = 0, getNumOfChildren(node) - 1 do
        setOwn(getChildAt(node, i), isOwn)
    end
end

-- Whether nothing that moves is where a block would go: a box halfSize
-- either side, turned yaw.
local function isBlockSpotClear(x, y, z, yaw, halfSize)
    local T = TCProtestCrowd
    local target = { blocked = false }
    function target:onOverlap(node)
        if node ~= g_terrainNode and not T.ownShapes[node] then
            self.blocked = true
            return false
        end
        return true
    end
    local half = T.BLOCK_HEIGHT * 0.5
    overlapBox(x, y + half, z, 0, yaw, 0, halfSize, half, halfSize, "onOverlap", target, BLOCK_CLEAR_MASK, true,
        true, true, true)
    return not target.blocked
end

local function removeBlock(entry, key)
    local node = entry.blocks[key]
    if node ~= nil then
        if entityExists(node) then
            setOwn(node, false)
            removeFromPhysics(node)
            delete(node)
        end
        entry.blocks[key] = nil
    end
end

-- Puts a block down at x, z turned yaw, if nothing's there (halfSize
-- either side; nil puts it down regardless). Returns false while its
-- model's still loading.
local function placeBlock(entry, key, name, filename, x, z, yaw, halfSize)
    local template = getTemplate(name, filename)
    if template == nil then
        return false
    end
    local y = TCFigures.groundY(x, z)
    if halfSize == nil or isBlockSpotClear(x, y, z, yaw, halfSize) then
        local node = cloneFrom(template)
        setTranslation(node, x, y, z)
        setRotation(node, 0, yaw, 0)
        setOwn(node, true)
        addToPhysics(node)
        entry.blocks[key] = node
    end
    return true
end

-- A block for each person and one round each group, each held back while
-- something's in the way. Keys: the person's index, or "g<n>" for a group.
local function updateBlocks(entry)
    local T = TCProtestCrowd
    for index, person in ipairs(entry.people) do
        if entry.blocks[index] == nil and
                not placeBlock(entry, index, "block", T.BLOCK_FILENAME, person.x, person.z, person.yaw,
                    T.BLOCK_HALF_SIZE) then
            return
        end
    end
    for n, group in ipairs(TCProtestLayout.getGroups(entry.incident.data)) do
        local key = "g" .. n
        if entry.blocks[key] == nil and
                not placeBlock(entry, key, "crowdBlock", T.CROWD_BLOCK_FILENAME, group.x, group.z,
                    math.atan2(group.dirX, group.dirZ), nil) then
            return
        end
    end
end

-- Markers -----------------------------------------------------------------------------------

local function removeMarkers(entry)
    for _, hotspot in ipairs(entry.markers) do
        if g_currentMission.removeMapHotspot ~= nil and g_currentMission.hud ~= nil then
            g_currentMission:removeMapHotspot(hotspot)
        end
        hotspot:delete()
    end
    entry.markers = {}
end

local function addMarkers(entry)
    if g_currentMission.hud == nil or PlaceableHotspot == nil or g_currentMission.addMapHotspot == nil then
        return
    end
    for _, group in ipairs(TCProtestLayout.getGroups(entry.incident.data)) do
        local hotspot = PlaceableHotspot.new()
        hotspot:setName(g_i18n:getText("tc_protest_mapName"))
        hotspot:createIcon()
        hotspot:setPlaceableType(PlaceableHotspot.TYPE.EXCLAMATION_MARK)
        hotspot:setWorldPosition(group.x, group.z)
        g_currentMission:addMapHotspot(hotspot)
        table.insert(entry.markers, hotspot)
    end
end

-- Client: the in-game map, on the protest's first group.
function TCProtestCrowd.showOnMap(incidentId)
    local entry = TCProtestCrowd.active[incidentId]
    local menu = g_inGameMenu
    if entry == nil or entry.markers[1] == nil or menu == nil or menu.openMapOverview == nil then
        return
    end
    menu:openMapOverview()
    local page = menu.pageMapOverview
    if page ~= nil and page.showMapHotspot ~= nil then
        page:showMapHotspot(entry.markers[1])
    end
end

-- Entries -----------------------------------------------------------------------------------

local function wantsMarkers(incident)
    return hasClient() and g_currentMission:getFarmId() == incident.farmId
end

local function buildEntry(incident)
    local data = incident.data
    local entry = {
        incident = incident,
        seed = data.seed,
        people = TCProtestLayout.layOut(TCProtestLayout.getGroups(data), data.seed),
        figures = {},
        blocks = {},
        markers = {},
        isOut = false,
        stats = { loaded = 0, shown = 0, present = 0 },
    }
    if wantsMarkers(incident) then
        addMarkers(entry)
    end
    return entry
end

-- The people (a machine with a client), once it's out.
local function putPeopleOut(entry)
    entry.isOut = true
    if not hasClient() then
        return
    end
    local templates = TCFigures.readTemplates()
    if #templates == 0 then
        return
    end
    -- The placard's model, ready by the time the first person's loads.
    getTemplate("placard", TCProtestCrowd.PLACARD_FILENAME)
    for index, person in ipairs(entry.people) do
        local look = templates[math.floor(TCProtestLayout.random(entry.seed, 7, index) * #templates) + 1]
        table.insert(entry.figures, { kind = "stand", template = look, x = person.x,
            y = TCFigures.groundY(person.x, person.z), z = person.z, yaw = person.yaw, slogan = person.slogan,
            style = person.style })
    end
end

local function clearEntry(entry)
    TCFigures.freeAll(entry.figures, FIGURE_HOOKS)
    entry.figures = {}
    for key in pairs(entry.blocks) do
        removeBlock(entry, key)
    end
    removeMarkers(entry)
end

-- Every machine, every frame.
function TCProtestCrowd.update(dt)
    local tc = g_currentMission ~= nil and g_currentMission.TheContractor or nil
    if tc == nil or tc.RandomEvents == nil then
        return
    end
    local seen = {}
    for _, incident in ipairs(TheContractorProtest.getIncidents()) do
        seen[incident.id] = true
        local entry = TCProtestCrowd.active[incident.id]
        -- A client's copy is replaced with every change: follow the latest.
        if entry ~= nil and entry.seed ~= incident.data.seed then
            clearEntry(entry)
            entry = nil
        end
        if entry == nil then
            entry = buildEntry(incident)
            TCProtestCrowd.active[incident.id] = entry
        end
        entry.incident = incident
        if TheContractorProtest.isOut(incident) and not entry.isOut then
            putPeopleOut(entry)
        end
    end
    for id, entry in pairs(TCProtestCrowd.active) do
        if not seen[id] then
            clearEntry(entry)
            TCProtestCrowd.active[id] = nil
        end
    end

    TCProtestCrowd.blockMs = TCProtestCrowd.blockMs + dt
    local checkBlocks = TCProtestCrowd.blockMs >= TCProtestCrowd.BLOCK_INTERVAL_MS
    if checkBlocks then
        TCProtestCrowd.blockMs = 0
    end
    local cx, cy, cz = TCFigures.getCameraPosition()
    for _, entry in pairs(TCProtestCrowd.active) do
        if entry.isOut then
            if checkBlocks then
                updateBlocks(entry)
                -- A placard whose model hadn't loaded when its person's did.
                for _, figure in ipairs(entry.figures) do
                    if figure.isReady and figure.placard == nil and figure.slogan ~= nil then
                        TCProtestCrowd.attachPlacard(figure)
                    end
                end
            end
            if cx ~= nil and #entry.figures > 0 then
                local loaded, shown, present = TCFigures.update(entry.figures, dt, cx, cy, cz, 1, FIGURE_HOOKS)
                entry.stats.loaded, entry.stats.shown, entry.stats.present = loaded, shown, present
            end
        end
    end
end

-- How it's doing on this machine, for the console.
function TCProtestCrowd.describe()
    local lines = {}
    for id, entry in pairs(TCProtestCrowd.active) do
        local blocks, crowdBlocks, placards = 0, 0, 0
        for key in pairs(entry.blocks) do
            if type(key) == "string" then
                crowdBlocks = crowdBlocks + 1
            else
                blocks = blocks + 1
            end
        end
        for _, figure in ipairs(entry.figures) do
            if figure.placard ~= nil then
                placards = placards + 1
            end
        end
        table.insert(lines, string.format(
            "This machine, incident %d: %s, %d people, models loaded %d, shown %d, placards %d, blocks %d of %d, crowd blocks %d of %d, markers %d",
            id, entry.isOut and "out" or "not out yet", #entry.people, entry.stats.loaded, entry.stats.shown,
            placards, blocks, #entry.people, crowdBlocks, entry.incident.data.groupCount or 0, #entry.markers))
    end
    if #lines == 0 then
        return "This machine shows no protest."
    end
    return table.concat(lines, "\n")
end

-- tcDebug protestShow: every block's outline, drawn from its own node
-- (people's in yellow, crowds' in red), so you can see they're there.
TCProtestCrowd.showBlocks = false

function TCProtestCrowd.draw()
    if not TCProtestCrowd.showBlocks or DebugUtil == nil then
        return
    end
    local T = TCProtestCrowd
    for _, entry in pairs(T.active) do
        for key, node in pairs(entry.blocks) do
            if entityExists(node) then
                if type(key) == "string" then
                    local size = T.CROWD_BLOCK_HALF * 2
                    DebugUtil.drawDebugCube(node, size, T.BLOCK_HEIGHT, size, 1, 0, 0, 0, T.BLOCK_HEIGHT * 0.5, 0)
                else
                    local size = T.BLOCK_HALF_SIZE * 2
                    DebugUtil.drawDebugCube(node, size, T.BLOCK_HEIGHT, size, 1, 1, 0, 0, T.BLOCK_HEIGHT * 0.5, 0)
                end
            end
        end
    end
end

-- deleteMap.
function TCProtestCrowd.reset()
    for _, entry in pairs(TCProtestCrowd.active) do
        clearEntry(entry)
    end
    TCProtestCrowd.active = {}
    releaseTemplates()
    TCProtestCrowd.blockMs = 0
    TCProtestCrowd.showBlocks = false
end
