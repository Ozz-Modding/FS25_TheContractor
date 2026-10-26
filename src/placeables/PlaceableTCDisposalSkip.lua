-- Disposal skip (075): where fly-tipped debris (TCDebris) from a clearing
-- job is taken. A piece dropped in or next to the skip disappears and counts
-- towards its job (TheContractorFlyTipping:disposeDebris). It also takes
-- the old parts an ADS replacement leaves (103, TCADSStock.isUsedPart: a
-- used spare parts box, a worn loose battery or air filter), charging their
-- owner the tipping fee (disposeUsedPart). New parts are left alone. Any
-- farm's skip will do. Vanilla saves it, streams it to clients and syncs the
-- owner, so it has no state of its own here.
--
-- Trigger-based, the way vanilla's sell points are (BaleUnloadTrigger): the
-- engine reports pieces entering and leaving the skip's trigger box (server
-- only), entering pieces go on a list, and the skip only updates while
-- that list has something on it (raiseActive). Disposal waits for the
-- update rather than happening in the physics callback, and waits for a
-- piece to be let go of: one still in a player's hands, or strapped down
-- or on a fork (like BaleUnloadTrigger's mount check, and
-- PalletUnloadTrigger's dynamicMountType for a part), or a box a work order
-- holds, stays on the list until it's free, or carried back out. Nothing
-- runs while the skip is empty.
--
-- The trigger box (Static + Trigger) is part of the i3d. Its collision mask
-- has DYNAMIC_OBJECT for debris and VEHICLE for ADS's parts, which are
-- pallets. A construction-menu preview never arms it.
--
-- Loaded by the base game's placeable specialization manager (modDesc), not
-- sourced by main.lua.

PlaceableTCDisposalSkip = {}

PlaceableTCDisposalSkip.KEY = "tcDisposalSkipData"

local function indexOf(list, value)
    for i, item in ipairs(list) do
        if item == value then
            return i
        end
    end
    return nil
end

function PlaceableTCDisposalSkip.prerequisitesPresent(specializations)
    return true
end

function PlaceableTCDisposalSkip.registerXMLPaths(schema, basePath)
    schema:setXMLSpecializationType("TCDisposalSkip")
    schema:register(XMLValueType.NODE_INDEX, basePath .. ".disposalSkip#triggerNode",
        "Trigger box debris and old parts are dropped into (mask must include DYNAMIC_OBJECT and VEHICLE)")
    schema:setXMLSpecializationType()
end

function PlaceableTCDisposalSkip.registerFunctions(placeableType)
    SpecializationUtil.registerFunction(placeableType, "tcDisposalTriggerCallback",
        PlaceableTCDisposalSkip.tcDisposalTriggerCallback)
end

function PlaceableTCDisposalSkip.registerEventListeners(placeableType)
    SpecializationUtil.registerEventListener(placeableType, "onLoad", PlaceableTCDisposalSkip)
    SpecializationUtil.registerEventListener(placeableType, "onDelete", PlaceableTCDisposalSkip)
    SpecializationUtil.registerEventListener(placeableType, "onUpdate", PlaceableTCDisposalSkip)
end

function PlaceableTCDisposalSkip:onLoad(savegame)
    local data = {
        triggerNode = self.xmlFile:getValue("placeable.disposalSkip#triggerNode", nil, self.components,
            self.i3dMappings),
        -- Pieces in the trigger waiting to be disposed of, in arrival order.
        waiting = {},
        isTriggerAdded = false,
    }
    self[PlaceableTCDisposalSkip.KEY] = data

    if not self.isServer or self.propertyState == PlaceablePropertyState.CONSTRUCTION_PREVIEW then
        return
    end
    if data.triggerNode == nil then
        Logging.xmlWarning(self.xmlFile, "Disposal skip has no trigger node, debris won't be taken")
        return
    end
    if not CollisionFlag.getHasMaskFlagSet(data.triggerNode, CollisionFlag.DYNAMIC_OBJECT) then
        Logging.xmlWarning(self.xmlFile, "Disposal skip trigger doesn't have bit %d (%s) in its collision mask",
            CollisionFlag.getBit(CollisionFlag.DYNAMIC_OBJECT), "DYNAMIC_OBJECT")
        return
    end
    if not CollisionFlag.getHasMaskFlagSet(data.triggerNode, CollisionFlag.VEHICLE) then
        Logging.xmlWarning(self.xmlFile, "Disposal skip trigger doesn't have bit %d (%s) in its collision mask, "
            .. "old parts won't be taken", CollisionFlag.getBit(CollisionFlag.VEHICLE), "VEHICLE")
    end
    addTrigger(data.triggerNode, "tcDisposalTriggerCallback", self)
    data.isTriggerAdded = true
end

function PlaceableTCDisposalSkip:onDelete()
    local data = self[PlaceableTCDisposalSkip.KEY]
    if data ~= nil and data.isTriggerAdded then
        removeTrigger(data.triggerNode)
        data.isTriggerAdded = false
    end
end

-- Whether the skip takes an object: fly-tipped debris, or an old ADS part.
function PlaceableTCDisposalSkip.isTaken(object)
    return TCDebris.isDebris(object) or TCADSStock.isUsedPart(object)
end

function PlaceableTCDisposalSkip:tcDisposalTriggerCallback(triggerId, otherId, onEnter, onLeave, onStay, otherShapeId)
    local item = g_currentMission:getNodeObject(otherId)
    if item == nil then
        return
    end
    local data = self[PlaceableTCDisposalSkip.KEY]
    local index = indexOf(data.waiting, item)
    if onEnter and index == nil and PlaceableTCDisposalSkip.isTaken(item) then
        table.insert(data.waiting, item)
        self:raiseActive()
    elseif onLeave and index ~= nil then
        table.remove(data.waiting, index)
    end
end

-- Whether a waiting item has been let go of: not in anyone's hands, not
-- strapped or on a fork, and for a part not held by a work order.
function PlaceableTCDisposalSkip.isLetGo(item)
    if TCDebris.isHeld(item) then
        return false
    elseif TCDebris.isDebris(item) then
        return item:getIsFree()
    end
    local isMounted = item.dynamicMountType ~= nil and item.dynamicMountType ~= MountableObject.MOUNT_TYPE_NONE
    return not isMounted and not TCADSStock.isReservedPart(item)
end

-- Server: disposes of every waiting item that's been let go of, and keeps
-- updating while any are still held.
function PlaceableTCDisposalSkip:onUpdate(dt)
    local data = self[PlaceableTCDisposalSkip.KEY]
    if data == nil or #data.waiting == 0 then
        return
    end
    PlaceableTCDisposalSkip.processWaiting(data.waiting)
    if #data.waiting > 0 then
        self:raiseActive()
    end
end

-- The list work, apart from the placeable for the tests: deleted items
-- drop off, held ones stay, the rest are disposed of. A part that's no
-- longer an old one (nothing in ADS changes that, but it's checked again
-- before anything's charged) drops off too.
function PlaceableTCDisposalSkip.processWaiting(waiting)
    local flyTipping = g_currentMission.TheContractor ~= nil and g_currentMission.TheContractor.FlyTipping or nil
    for i = #waiting, 1, -1 do
        local item = waiting[i]
        local isDebris = TCDebris.isDebris(item)
        if item.isDeleted or (isDebris and item.nodeId == 0) then
            table.remove(waiting, i)
        elseif not isDebris and not TCADSStock.isUsedPart(item) then
            table.remove(waiting, i)
        elseif PlaceableTCDisposalSkip.isLetGo(item) then
            table.remove(waiting, i)
            if flyTipping == nil then
                item:delete()
            elseif isDebris then
                flyTipping:disposeDebris(item)
            else
                flyTipping:disposeUsedPart(item)
            end
        end
    end
end
