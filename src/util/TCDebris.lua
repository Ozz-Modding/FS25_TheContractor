-- Debris: loose props the player can pick up by hand, like a cut log
-- segment. 075's fly-tipping dumps a pile of them (spawnPileAt) for the
-- player to carry to a disposal skip (PlaceableTCDisposalSkip); the console
-- can drop a pile too (tcCompany debris).
--
-- Each piece is a MountableObject (vanilla's ForestryLog/MissionPhysicsObject
-- pattern), not a vehicle, so it never shows in vehicle lists. It can be
-- strapped down with tension belts (getSupportsTensionBelts and co., no
-- mesh nodes, so a belt runs straight over it). PhysicsObject syncs position;
-- the prop key is streamed so clients load the same i3d. Saving goes
-- through vanilla's ItemSystem (the savegame's items.xml): it stores our
-- className and modName, calls saveToXMLFile, and recreates the piece with
-- loadFromXMLFile on load.
--
-- Vanilla's hands (HandToolHands:getCanPickUpNode) lift any dynamic rigid
-- body of 200 kg or less that the look ray hits (DYNAMIC_OBJECT is in its
-- mask). A prop's i3d needs a dynamic root collision, re-saved in GE (a
-- scenery prop's static one stays frozen whatever we set at runtime). load()
-- gives it the DYNAMIC_OBJECT collision preset, and every piece weighs
-- TCDebris.MASS, whatever density GE gave it.

TCDebris = {}
local TCDebris_mt = Class(TCDebris, MountableObject)
InitObjectClass(TCDebris, "TCDebris")

-- ItemSystem finds the class again from this name on load.
TCDebris.CLASS_NAME = g_currentModName .. ".TCDebris"

-- Every piece's mass in tonnes, light enough to carry (the hands lift up
-- to 0.2). GE works mass out from density x collision volume, so a big
-- prop would otherwise be too heavy.
TCDebris.MASS = 0.01

TCDebris.PROPS = {
    -- The vanilla motorex barrel, re-exported with a dynamic collision.
    barrel = { filename = "i3d/debris/debrisBarrel.i3d" },
    -- A mapEU construction-material pipe, its collision moved up to be the
    -- root and made dynamic.
    pipe = { filename = "i3d/debris/debrisPipe.i3d" },
    -- Copied from the base-game maps and made dynamic.
    bicycle = { filename = "i3d/debris/bicycle01.i3d" },
    board = { filename = "i3d/debris/boardStack02Board.i3d" },
    cardboard = { filename = "i3d/debris/cardboardStack02.i3d" },
    sawhorse = { filename = "i3d/debris/sawhorse.i3d" },
    trashCan = { filename = "i3d/debris/trashCan01.i3d" },
    trashCan2 = { filename = "i3d/debris/trashCan02.i3d" },
    wheelBarrow = { filename = "i3d/debris/wheelBarrow.i3d" },
    chair = { filename = "i3d/debris/woodenChair.i3d" },
    ladder = { filename = "i3d/debris/woodenLadder.i3d" },
    grill = { filename = "i3d/debris/gardenGrill.i3d" },
    stool = { filename = "i3d/debris/milkingStool.i3d" },
    pitchFork = { filename = "i3d/debris/pitchFork.i3d" },
    crate = { filename = "i3d/debris/woodenCrate01.i3d" },
    crate2 = { filename = "i3d/debris/woodenCrate02.i3d" },
    crate3 = { filename = "i3d/debris/woodenCrate03.i3d" },
    -- Vanilla, already exported dynamic: the control for whether a prop's
    -- collision is the problem. Only spawned by name.
    bakeryBox = { filename = "$data/objects/pallets/bakeryBoxPallet/bakeryBox.i3d", testOnly = true },
}

-- The props a random pile picks from, sorted so it's the same list everywhere.
TCDebris.RANDOM_PROPS = {}
for key, def in pairs(TCDebris.PROPS) do
    if not def.testOnly then
        table.insert(TCDebris.RANDOM_PROPS, key)
    end
end
table.sort(TCDebris.RANDOM_PROPS)

TCDebris.NO_MESH_NODES = {}

-- How far a pile's pieces scatter (metres, the square's side).
TCDebris.PILE_SPREAD = 2

-- How many frames after loading a piece keeps trying to settle its body.
TCDebris.SETTLE_FRAMES = 30

-- Every live piece, so the console can clear them.
TCDebris.instances = {}

-- Mods are sourced before the schema exists (createSchemas runs after, then
-- initSchemas), so register from an init function, as ForestryLog does.
-- Its position/rotation/uniqueId/farmId paths are vanilla's, shared with us.
g_xmlManager:addInitSchemaFunction(function()
    ItemSystem.xmlSchemaSavegame:register(XMLValueType.STRING, "items.item(?)#tcProp", "TheContractor debris prop key")
end)

function TCDebris.new(isServer, isClient, customMt)
    local self = MountableObject.new(isServer, isClient, customMt or TCDebris_mt)
    registerObjectClassName(self, TCDebris.CLASS_NAME)
    self.propKey = nil
    self.uniqueId = nil
    self.sharedLoadRequestId = nil
    self.isInItemSystem = false
    return self
end

function TCDebris:load(propKey, x, y, z, rx, ry, rz)
    local def = TCDebris.PROPS[propKey]
    if def == nil then
        Logging.warning("TheContractor: unknown debris prop '%s'", tostring(propKey))
        return false
    end
    local filename = Utils.getFilename(def.filename, TheContractor.dir)
    local root, sharedLoadRequestId = g_i3DManager:loadSharedI3DFile(filename, false, false)
    if root == nil or root == 0 then
        Logging.warning("TheContractor: could not load debris i3d '%s'", filename)
        return false
    end
    self.sharedLoadRequestId = sharedLoadRequestId
    local node = getChildAt(root, 0)
    link(getRootNode(), node)
    delete(root)

    if x ~= nil then
        setTranslation(node, x, y, z)
        setRotation(node, rx, ry, rz)
    end
    local preset = CollisionPreset.DYNAMIC_OBJECT
    setCollisionFilter(node, preset.group, preset.mask)

    self.propKey = propKey
    self:setNodeId(node)
    if self.isServer then
        -- The body only exists once the engine has cooked the prop's
        -- collision, after this frame: it starts asleep and with GE's mass,
        -- and a wake-up or setMass now is lost. update() settles it instead.
        self.settleFramesLeft = TCDebris.SETTLE_FRAMES
    end
    TCDebris.instances[self] = true
    if self.isClient then
        self:addMapHotspot()
    end
    return true
end

function TCDebris:delete()
    TCDebris.instances[self] = nil
    self:removeMapHotspot()
    if self.isInItemSystem then
        g_currentMission.itemSystem:removeItem(self)
        self.isInItemSystem = false
    end
    if self.sharedLoadRequestId ~= nil then
        g_i3DManager:releaseSharedI3DFile(self.sharedLoadRequestId)
        self.sharedLoadRequestId = nil
    end
    unregisterObjectClassName(self)
    TCDebris:superClass().delete(self)
end

-- Both a fresh spawn and ItemSystem's load register the piece once it's
-- loaded: that's when it can join the update loop to be settled.
function TCDebris:register(alreadySent)
    TCDebris:superClass().register(self, alreadySent)
    if self.settleFramesLeft ~= nil then
        self:raiseActive()
    end
end

-- Settling: sets the mass and wakes the body each frame until it has both.
-- PhysicsObject only stays in the update loop while awake, so a body that
-- starts asleep would never get here on its own: raiseActive keeps it in.
function TCDebris:update(dt)
    if self.isServer and self.settleFramesLeft ~= nil and not self.isDeleted then
        local node = self.nodeId
        if math.abs(getMass(node) - TCDebris.MASS) > 0.0001 then
            setMass(node, TCDebris.MASS)
        end
        if getIsSleeping(node) then
            self:wakeUp()
        end
        if not getIsSleeping(node) and math.abs(getMass(node) - TCDebris.MASS) <= 0.0001 then
            self.settleFramesLeft = nil
        else
            self.settleFramesLeft = self.settleFramesLeft - 1
            if self.settleFramesLeft <= 0 then
                self.settleFramesLeft = nil
                Logging.warning("TheContractor: debris %s didn't settle (mass %.3f t, sleeping %s)",
                    tostring(self.propKey), getMass(node), tostring(getIsSleeping(node)))
            else
                self:raiseActive()
            end
        end
    end
    TCDebris:superClass().update(self, dt)
end

-- Server: a fresh piece, networked and saved.
function TCDebris.spawn(propKey, x, y, z, rx, ry, rz, farmId)
    local debris = TCDebris.new(true, g_client ~= nil)
    if not debris:load(propKey, x, y, z, rx, ry, rz) then
        debris:delete()
        return nil
    end
    debris:setOwnerFarmId(farmId, true)
    debris:register()
    debris:addToItemSystem()
    return debris
end

function TCDebris:addToItemSystem()
    if not self.isInItemSystem then
        g_currentMission.itemSystem:addItem(self)
        self.isInItemSystem = true
    end
end

function TCDebris:readStream(streamId, connection)
    local propKey = streamReadString(streamId)
    if self.nodeId == 0 then
        self:load(propKey)
    end
    TCDebris:superClass().readStream(self, streamId, connection)
end

function TCDebris:writeStream(streamId, connection)
    streamWriteString(streamId, self.propKey)
    TCDebris:superClass().writeStream(self, streamId, connection)
end

function TCDebris:loadFromXMLFile(xmlFile, key, resetItems)
    local x, y, z = xmlFile:getValue(key .. "#position")
    local rx, ry, rz = xmlFile:getValue(key .. "#rotation")
    if x == nil or rx == nil then
        return false
    end
    self:setUniqueId(xmlFile:getValue(key .. "#uniqueId"))
    if not self:load(xmlFile:getValue(key .. "#tcProp"), x, y, z, rx, ry, rz) then
        return false
    end
    self:setOwnerFarmId(xmlFile:getValue(key .. "#farmId", FarmManager.SPECTATOR_FARM_ID), true)
    -- ItemSystem adds it once this returns true.
    self.isInItemSystem = true
    return true
end

function TCDebris:saveToXMLFile(xmlFile, key)
    local x, y, z = getTranslation(self.nodeId)
    local rx, ry, rz = getRotation(self.nodeId)
    xmlFile:setValue(key .. "#uniqueId", self.uniqueId)
    xmlFile:setValue(key .. "#tcProp", self.propKey)
    xmlFile:setValue(key .. "#position", x, y, z)
    xmlFile:setValue(key .. "#rotation", rx, ry, rz)
    xmlFile:setValue(key .. "#farmId", self:getOwnerFarmId())
end

-- Tension belts (vanilla's TensionBelts:getTensionBeltObjectCanBeMounted).
function TCDebris:getSupportsTensionBelts()
    return true
end

function TCDebris:getTensionBeltNodeId()
    return self.nodeId
end

-- No visual meshes for the belt to wrap round, as ForestryLog: it's drawn
-- straight, and still holds the piece.
function TCDebris:getMeshNodes()
    return TCDebris.NO_MESH_NODES
end

-- Not on a fork, a front loader or under a belt.
function TCDebris:getIsFree()
    return self.dynamicMountType == nil or self.dynamicMountType == MountableObject.MOUNT_TYPE_NONE
end

-- A marker on the map for every piece, so a pile in standing crop can be
-- found. It follows the piece (TCDebrisHotspot reads its position as the
-- map draws) and only shows to its owner farm. Local, never networked.
function TCDebris:addMapHotspot()
    if self.mapHotspot ~= nil or g_currentMission.addMapHotspot == nil then
        return
    end
    self.mapHotspot = TCDebrisHotspot.new(self)
    self.mapHotspot:setOwnerFarmId(self:getOwnerFarmId())
    g_currentMission:addMapHotspot(self.mapHotspot)
end

function TCDebris:removeMapHotspot()
    if self.mapHotspot ~= nil then
        g_currentMission:removeMapHotspot(self.mapHotspot)
        self.mapHotspot:delete()
        self.mapHotspot = nil
    end
end

function TCDebris:setOwnerFarmId(farmId, noEventSend)
    TCDebris:superClass().setOwnerFarmId(self, farmId, noEventSend)
    if self.mapHotspot ~= nil then
        self.mapHotspot:setOwnerFarmId(farmId)
    end
end

function TCDebris:setUniqueId(uniqueId)
    self.uniqueId = uniqueId
end

function TCDebris:getUniqueId()
    return self.uniqueId
end

-- Server: drops count pieces from a little height around (cx, cz),
-- scattered and tumbled so they settle into a pile, and returns them.
-- propKey nil picks a random prop for each piece.
function TCDebris.spawnPileAt(cx, cz, count, farmId, propKey)
    local pieces = {}
    for i = 1, count do
        local x = cx + (math.random() - 0.5) * TCDebris.PILE_SPREAD
        local z = cz + (math.random() - 0.5) * TCDebris.PILE_SPREAD
        local y = getTerrainHeightAtWorldPos(g_terrainNode, x, 0, z) + 0.6 + (i - 1) * 0.4
        local rx = (math.random() - 0.5) * math.pi
        local ry = math.random() * 2 * math.pi
        local rz = (math.random() - 0.5) * math.pi
        local key = propKey or TCDebris.RANDOM_PROPS[math.random(#TCDebris.RANDOM_PROPS)]
        local debris = TCDebris.spawn(key, x, y, z, rx, ry, rz, farmId)
        if debris ~= nil then
            table.insert(pieces, debris)
        end
    end
    return pieces
end

-- The console's pile, a few metres in front of the local player. Returns
-- how many pieces it dropped, or nil with no local player.
function TCDebris.spawnPile(propKey, count, farmId)
    local player = g_localPlayer
    if player == nil then
        return nil
    end
    local px, _, pz = player:getPosition()
    local camera = g_cameraManager:getActiveCamera()
    local dx, _, dz = localDirectionToWorld(camera, 0, 0, -1)
    dx, _, dz = MathUtil.vector3Normalize(dx, 0, dz)
    return #TCDebris.spawnPileAt(px + dx * 4, pz + dz * 4, count, farmId, propKey)
end

function TCDebris.isDebris(object)
    return TCDebris.instances[object] == true
end

-- Whether a player has this piece in their hands. The server runs
-- HandToolHands:pickUpTarget for every player, remote ones too, so its
-- heldItemNode is right there. Works for any node object (the disposal
-- skip asks it about ADS parts too, 103).
function TCDebris.isHeld(debris)
    local playerSystem = g_currentMission.playerSystem
    if playerSystem == nil then
        return false
    end
    for i = 1, playerSystem:getPlayerCount() do
        local player = playerSystem:getPlayerByIndex(i)
        local hands = player ~= nil and player.hands or nil
        local spec = hands ~= nil and hands.spec_hands or nil
        local heldNode = spec ~= nil and spec.heldItemNode or nil
        if heldNode ~= nil and (heldNode == debris.nodeId or g_currentMission:getNodeObject(heldNode) == debris) then
            return true
        end
    end
    return false
end

function TCDebris.clearAll()
    local list = {}
    for debris in pairs(TCDebris.instances) do
        table.insert(list, debris)
    end
    for _, debris in ipairs(list) do
        debris:delete()
    end
    return #list
end

function TCDebris.registerConsoleCommands()
    TCConsole.register("company", "debris", {
        args = "[count] [prop]",
        description = "Drop a pile of hand-movable debris in front of you (random props unless one is named)",
        run = function(farmId, args)
            local count = tonumber(args[1] or "8")
            local propKey = args[2]
            if count == nil or count < 1 then
                return false
            end
            if propKey ~= nil and TCDebris.PROPS[propKey] == nil then
                local keys = {}
                for key in pairs(TCDebris.PROPS) do
                    table.insert(keys, key)
                end
                table.sort(keys)
                return string.format("Unknown prop '%s'. Props: %s", propKey, table.concat(keys, ", "))
            end
            local spawned = TCDebris.spawnPile(propKey, math.min(math.floor(count), 50), farmId)
            if spawned == nil then
                return "No local player to spawn in front of"
            end
            return string.format("Spawned %d %s debris", spawned, propKey or "random")
        end,
    })
    TCConsole.register("company", "debrisClear", {
        args = "",
        description = "Remove all debris",
        run = function(farmId, args)
            return string.format("Removed %d debris", TCDebris.clearAll())
        end,
    })
end

-- The map marker for one piece (see TCDebris:addMapHotspot), drawn the way
-- vanilla's collectibles are. Its position is the piece's, read as the map
-- draws, as VehicleHotspot does for a vehicle.
TCDebrisHotspot = {}
local TCDebrisHotspot_mt = Class(TCDebrisHotspot, MapHotspot)

TCDebrisHotspot.SIZE = 30
TCDebrisHotspot.COLOR = { 0.85, 0.25, 0.05 }

function TCDebrisHotspot.new(debris)
    local self = MapHotspot.new(TCDebrisHotspot_mt)
    self.debris = debris
    self.width, self.height = getNormalizedScreenValues(TCDebrisHotspot.SIZE, TCDebrisHotspot.SIZE)
    self.icon = g_overlayManager:createOverlay("mapHotspots.other", 0, 0, self.width, self.height)
    self:setColor(TCDebrisHotspot.COLOR[1], TCDebrisHotspot.COLOR[2], TCDebrisHotspot.COLOR[3])
    return self
end

function TCDebrisHotspot:getCategory()
    return MapHotspot.CATEGORY_MISSION
end

function TCDebrisHotspot:getWorldPosition()
    local debris = self.debris
    if debris == nil or debris.nodeId == nil or debris.nodeId == 0 then
        return self.worldX, self.worldZ
    end
    local x, _, z = getWorldTranslation(debris.nodeId)
    return x, z
end

function TCDebrisHotspot:hasMouseOverlap(x, y)
    return false
end
