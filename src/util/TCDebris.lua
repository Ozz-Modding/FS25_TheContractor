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
-- mask). A prop's i3d needs a dynamic root collision, binarized again after
-- the edit (docs/tools/binarize.py) so its .shapes matches (a scenery
-- prop's static one stays frozen whatever we set at runtime). load() gives
-- it the DYNAMIC_OBJECT collision preset, and every piece weighs
-- TCDebris.MASS, whatever density GE gave it.
--
-- 147: bin bags, picked for a random pile by weight like the rest, our own model
-- (docs/tools/genBinBagI3d.py) that squashes, stretches and swings as it's
-- dropped and carried: TCBinBagSquash works the pose out from how the bag
-- moves, and updateSquash puts it on the bag's nodes, on every machine
-- that draws it, each for itself.

TCDebris = {}
local TCDebris_mt = Class(TCDebris, MountableObject)
InitObjectClass(TCDebris, "TCDebris")

-- ItemSystem finds the class again from this name on load.
TCDebris.CLASS_NAME = g_currentModName .. ".TCDebris"

-- Every piece's mass in tonnes, light enough to carry (the hands lift up
-- to 0.2). GE works mass out from density x collision volume, so a big
-- prop would otherwise be too heavy.
TCDebris.MASS = 0.01

-- Each prop's weight is how often a random pile picks it, against the
-- others' (1 if not given; 0 never, only by name). Not its mass: that's
-- MASS for every piece.
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
    -- 147: our own model, squashed in code (TCBinBagSquash). neck is the
    -- generator's HEIGHT, where its `hang` node is.
    binBag = { filename = "i3d/debris/binBag.i3d", isBinBag = true, neck = 0.6, weight = 6 },
}

TCDebris.BIN_BAG = "binBag"

-- A bin bag is dropped nearly upright: tipped at most this far (radians).
TCDebris.BIN_BAG_TIP = 0.3

-- Beyond this from the camera a bin bag isn't squashed (metres).
TCDebris.SQUASH_DISTANCE = 60

-- A bag moved further than this in a frame was put there, not moved: no
-- squash from it (metres).
TCDebris.SQUASH_JUMP = 2

-- Every prop, sorted so a random pick walks the same list everywhere.
TCDebris.RANDOM_PROPS = {}
for key in pairs(TCDebris.PROPS) do
    table.insert(TCDebris.RANDOM_PROPS, key)
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
        TCLog.warning("TheContractor: unknown debris prop '%s'", tostring(propKey))
        return false
    end
    local filename = Utils.getFilename(def.filename, TheContractor.dir)
    local root, sharedLoadRequestId = g_i3DManager:loadSharedI3DFile(filename, false, false)
    if root == nil or root == 0 then
        TCLog.warning("TheContractor: could not load debris i3d '%s'", filename)
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
        -- 147: the bag's nodes for its squash (the i3d's hang > squash).
        if def.isBinBag and getNumOfChildren(node) > 0 then
            local hang = getChildAt(node, 0)
            if getNumOfChildren(hang) > 0 then
                self.squash = { hang = hang, node = getChildAt(hang, 0), neck = def.neck,
                    state = TCBinBagSquash.new() }
            end
        end
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
                TCLog.warning("TheContractor: debris %s didn't settle (mass %.3f t, sleeping %s)",
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

function TCDebris.getWeight(propKey)
    local def = TCDebris.PROPS[propKey]
    if def == nil then
        return 0
    end
    return def.weight or 1
end

-- Whether a random pile has anything to pick from.
function TCDebris.hasRandomProps()
    for _, key in ipairs(TCDebris.RANDOM_PROPS) do
        if TCDebris.getWeight(key) > 0 then
            return true
        end
    end
    return false
end

-- Which prop a random pile's next piece is: each in proportion to its
-- weight. Nil if every weight is 0.
function TCDebris.pickRandomProp()
    local total = 0
    for _, key in ipairs(TCDebris.RANDOM_PROPS) do
        total = total + TCDebris.getWeight(key)
    end
    if total <= 0 then
        return nil
    end
    local roll = math.random() * total
    for _, key in ipairs(TCDebris.RANDOM_PROPS) do
        roll = roll - TCDebris.getWeight(key)
        if roll < 0 then
            return key
        end
    end
    -- Rounding at the very top of the range.
    for i = #TCDebris.RANDOM_PROPS, 1, -1 do
        local key = TCDebris.RANDOM_PROPS[i]
        if TCDebris.getWeight(key) > 0 then
            return key
        end
    end
    return nil
end

-- Server: drops count pieces from a little height around (cx, cz),
-- scattered and tumbled so they settle into a pile, and returns them.
-- propKey nil picks each piece (pickRandomProp). A bin bag is dropped
-- nearly upright, so it lands on its bottom and squashes.
function TCDebris.spawnPileAt(cx, cz, count, farmId, propKey)
    local pieces = {}
    for i = 1, count do
        local key = propKey or TCDebris.pickRandomProp()
        if key == nil then
            break
        end
        local tip = TCDebris.PROPS[key] ~= nil and TCDebris.PROPS[key].isBinBag and TCDebris.BIN_BAG_TIP * 2 or math.pi
        local x = cx + (math.random() - 0.5) * TCDebris.PILE_SPREAD
        local z = cz + (math.random() - 0.5) * TCDebris.PILE_SPREAD
        local y = getTerrainHeightAtWorldPos(g_terrainNode, x, 0, z) + 0.6 + (i - 1) * 0.4
        local rx = (math.random() - 0.5) * tip
        local ry = math.random() * 2 * math.pi
        local rz = (math.random() - 0.5) * tip
        local debris = TCDebris.spawn(key, x, y, z, rx, ry, rz, farmId)
        if debris ~= nil then
            table.insert(pieces, debris)
        end
    end
    return pieces
end

-- The console's pile, a few metres in front of the typing player
-- (TCConsole's context). Returns how many pieces it dropped, or nil with no
-- player in the game.
function TCDebris.spawnPile(propKey, count, farmId, context)
    if not TCConsole.hasPosition(context) then
        return nil
    end
    local x, z = context.x + context.dirX * 4, context.z + context.dirZ * 4
    return #TCDebris.spawnPileAt(x, z, count, farmId, propKey)
end

function TCDebris.isDebris(object)
    return TCDebris.instances[object] == true
end

-- 147: every frame, on any machine that draws (TheContractor:update). Each
-- bin bag near the camera is squashed from how its velocity changed since
-- the last frame (TCBinBagSquash), measured from its position, so it works
-- the same for a client's interpolated copy as for the server's body. A
-- bag out of range, or put somewhere rather than moved there (SQUASH_JUMP),
-- starts afresh.
function TCDebris.updateSquash(dt)
    local dtSec = dt / 1000
    if dtSec <= 0 then
        return
    end
    local camera = g_cameraManager ~= nil and g_cameraManager:getActiveCamera() or nil
    local cx, cy, cz = nil, nil, nil
    if camera ~= nil and camera ~= 0 then
        cx, cy, cz = getWorldTranslation(camera)
    end
    for debris in pairs(TCDebris.instances) do
        local squash = debris.squash
        if squash ~= nil and debris.nodeId ~= nil and debris.nodeId ~= 0 and not debris.isDeleted then
            TCDebris.updateBagSquash(debris, squash, dtSec, cx, cy, cz)
        end
    end
end

function TCDebris.updateBagSquash(debris, squash, dtSec, cx, cy, cz)
    local node = debris.nodeId
    local x, y, z = getWorldTranslation(node)
    local far = cx ~= nil and MathUtil.vector3Length(x - cx, y - cy, z - cz) > TCDebris.SQUASH_DISTANCE
    local jumped = squash.x ~= nil and MathUtil.vector3Length(x - squash.x, y - squash.y, z - squash.z) > TCDebris.SQUASH_JUMP
    if far or jumped or squash.x == nil then
        squash.x, squash.y, squash.z = x, y, z
        squash.vx = nil
        if far and not squash.isPlain then
            squash.state = TCBinBagSquash.new()
            TCDebris.applySquashPose(squash)
        end
        return
    end
    local vx, vy, vz = (x - squash.x) / dtSec, (y - squash.y) / dtSec, (z - squash.z) / dtSec
    squash.x, squash.y, squash.z = x, y, z
    local dvx, dvy, dvz = 0, 0, 0
    if squash.vx ~= nil then
        dvx, dvy, dvz = worldDirectionToLocal(node, vx - squash.vx, vy - squash.vy, vz - squash.vz)
    end
    squash.vx, squash.vy, squash.vz = vx, vy, vz

    local state = squash.state
    TCBinBagSquash.step(state, dtSec, dvx, dvy, dvz, TCDebris.isHeld(debris))
    if TCBinBagSquash.isSettled(state) then
        if not squash.isPlain then
            squash.state = TCBinBagSquash.new()
            TCDebris.applySquashPose(squash)
        end
        return
    end
    TCDebris.applySquashPose(squash)
end

function TCDebris.applySquashPose(squash)
    local sides, height, y, tiltX, tiltZ = TCBinBagSquash.getPose(squash.state, squash.neck)
    setScale(squash.node, sides, height, sides)
    setTranslation(squash.node, 0, y, 0)
    setRotation(squash.hang, tiltX, 0, tiltZ)
    squash.isPlain = TCBinBagSquash.isSettled(squash.state)
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
        description = "Drop a pile of hand-movable debris in front of you (random props and bin bags unless one is named)",
        run = function(farmId, args, context)
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
            local spawned = TCDebris.spawnPile(propKey, math.min(math.floor(count), 50), farmId, context)
            if spawned == nil then
                return "No player to spawn in front of"
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
