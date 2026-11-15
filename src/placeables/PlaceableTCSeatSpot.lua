-- Seat spot (153): a standing spot (065) with a chair, where an idle
-- worker is shown sitting. The placeable type has the standing spot's
-- specialization too, so everything a spot has comes with it: the
-- footprint, the construction-only decals, the filter of who sits there
-- (120, its prompt and event) and its place in TCIdleStaff's assignment.
-- This adds the chair and says how to sit on it.
--
-- The chair type is a configuration (tcSeatType), picked while placing it
-- as the company sign's design is (085). Its options are a fixed list in
-- xml/seatSpot.xml, the same on every machine, so vanilla syncing the
-- chosen index is safe in multiplayer. Each option's saveId names a
-- TCSeatTypes entry: the base-game model, loaded from $data, and the
-- sitter's seat and limb targets.
--
-- The model hangs under a node of our own below the stand node (the
-- standing spot's), on every machine (its collision matters to everyone).
-- One loaded after the placeable was finalized is added to physics here;
-- one that arrives before goes in with the placeable. The standing spot's
-- player blocker stays in physics for good (#keepBlocker), as the chair is
-- always there.
--
-- Loaded by the base game's placeable specialization manager (modDesc), not
-- sourced by main.lua.

PlaceableTCSeatSpot = {}

PlaceableTCSeatSpot.KEY = "tcSeatSpotData"
PlaceableTCSeatSpot.CONFIG = "tcSeatType"

function PlaceableTCSeatSpot.prerequisitesPresent(specializations)
    return true
end

function PlaceableTCSeatSpot.initSpecialization()
    -- The title shown is the xml's own (tcSeatTypeConfigurations#title).
    g_placeableConfigurationManager:addConfigurationType(PlaceableTCSeatSpot.CONFIG, "Chair", nil,
        PlaceableConfigurationItem)
end

function PlaceableTCSeatSpot.registerEventListeners(placeableType)
    SpecializationUtil.registerEventListener(placeableType, "onLoad", PlaceableTCSeatSpot)
    SpecializationUtil.registerEventListener(placeableType, "onFinalizePlacement", PlaceableTCSeatSpot)
    SpecializationUtil.registerEventListener(placeableType, "onDelete", PlaceableTCSeatSpot)
end

function PlaceableTCSeatSpot.isSeat(object)
    return type(object) == "table" and object[PlaceableTCSeatSpot.KEY] ~= nil
end

-- The chosen configuration's saveId, or nil.
function PlaceableTCSeatSpot.getTypeKey(placeable)
    local storeItem = placeable.storeItem
    if storeItem == nil or storeItem.configurations == nil then
        return nil
    end
    local items = storeItem.configurations[PlaceableTCSeatSpot.CONFIG]
    if items == nil then
        return nil
    end
    local configId = placeable.configurations ~= nil and placeable.configurations[PlaceableTCSeatSpot.CONFIG] or 1
    local item = items[configId] or items[1]
    return item ~= nil and item.saveId or nil
end

function PlaceableTCSeatSpot:onLoad(savegame)
    local standNode = self.xmlFile:getValue("placeable.standingSpot#standNode", nil, self.components, self.i3dMappings)
    local typeKey = PlaceableTCSeatSpot.getTypeKey(self)
    local seatType = TCSeatTypes.get(typeKey)
    local data = { typeKey = typeKey, seatType = seatType, node = nil, model = nil, requestId = nil,
        isFinalized = false }
    self[PlaceableTCSeatSpot.KEY] = data
    if standNode == nil then
        TCLog.xmlWarning(self.xmlFile, "Seat spot has no stand node")
        return
    end
    if seatType == nil then
        TCLog.xmlWarning(self.xmlFile, "Seat spot has no chair type '%s'", tostring(typeKey))
        return
    end

    data.node = createTransformGroup("tcSeatSpot")
    link(standNode, data.node)
    local filename = Utils.getFilename(seatType.filename, nil)
    data.requestId = g_i3DManager:loadSharedI3DFileAsync(filename, false, false, PlaceableTCSeatSpot.onModelLoaded,
        self, { data = data, filename = filename })
end

-- A node by an index path below it ("4": its fifth child), or nil.
function PlaceableTCSeatSpot.nodeAt(root, path)
    local node = root
    for index in string.gmatch(path or "", "%d+") do
        local i = tonumber(index)
        if node == nil or i >= getNumOfChildren(node) then
            return nil
        end
        node = getChildAt(node, i)
    end
    return node
end

function PlaceableTCSeatSpot:onModelLoaded(root, failedReason, args)
    local data = args.data
    if root == nil or root == 0 then
        TCLog.warning("TheContractor: seat spot chair '%s' could not be loaded", tostring(args.filename))
        return
    end
    if self[PlaceableTCSeatSpot.KEY] ~= data or data.node == nil or not entityExists(data.node) then
        delete(root)
        return
    end
    local model = PlaceableTCSeatSpot.nodeAt(getChildAt(root, 0), data.seatType.part)
    if model == nil then
        TCLog.warning("TheContractor: seat spot chair '%s' has no part %s", tostring(args.filename),
            tostring(data.seatType.part))
        delete(root)
        return
    end
    link(data.node, model)
    delete(root)
    data.model = model
    local part = data.seatType.model
    setTranslation(model, part.pos[1], part.pos[2], part.pos[3])
    setRotation(model, math.rad(part.rot[1]), math.rad(part.rot[2]), math.rad(part.rot[3]))
    if data.isFinalized and data.seatType.collision then
        addToPhysics(model)
    end
end

function PlaceableTCSeatSpot:onFinalizePlacement()
    local data = self[PlaceableTCSeatSpot.KEY]
    if data ~= nil then
        data.isFinalized = true
    end
end

function PlaceableTCSeatSpot:onDelete()
    local data = self[PlaceableTCSeatSpot.KEY]
    if data == nil then
        return
    end
    if data.requestId ~= nil then
        g_i3DManager:releaseSharedI3DFile(data.requestId)
        data.requestId = nil
    end
    -- The model and node go with the placeable's own nodes.
    data.model = nil
    data.node = nil
end

-- What TCIdleStaff needs to sit someone here: { typeKey, type, node (the
-- seat's link node, on the ground facing +Z) }, or nil.
function PlaceableTCSeatSpot.getSeat(placeable)
    local data = placeable[PlaceableTCSeatSpot.KEY]
    if data == nil or data.seatType == nil or data.node == nil or not entityExists(data.node) then
        return nil
    end
    return { typeKey = data.typeKey, type = data.seatType, node = data.node }
end
