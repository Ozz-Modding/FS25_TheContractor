-- Disposal skip (075): where fly-tipped debris (TCDebris) from a clearing
-- job is taken. A piece dropped in or next to the skip disappears and counts
-- towards its job (TheContractorFlyTipping:disposeDebris). Any farm's skip
-- will do. Vanilla saves it, streams it to clients and syncs the owner, so
-- it has no state of its own here.
--
-- Trigger-based, the way vanilla's sell points are (BaleUnloadTrigger): the
-- engine reports pieces entering and leaving the skip's trigger box (server
-- only), entering pieces go on a list, and the skip only updates while
-- that list has something on it (raiseActive). Disposal waits for the
-- update rather than happening in the physics callback, and waits for a
-- piece to be let go of: one still in a player's hands, or strapped down
-- or on a fork (like BaleUnloadTrigger's mount check), stays on the list
-- until it's free, or carried back out. Nothing runs while the skip is
-- empty.
--
-- The trigger box (Static + Trigger, collision mask with DYNAMIC_OBJECT) is
-- part of the i3d. A construction-menu preview never arms it.
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
        "Trigger box debris is dropped into (mask must include DYNAMIC_OBJECT)")
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

function PlaceableTCDisposalSkip:tcDisposalTriggerCallback(triggerId, otherId, onEnter, onLeave, onStay, otherShapeId)
    local debris = g_currentMission:getNodeObject(otherId)
    if debris == nil or not TCDebris.isDebris(debris) then
        return
    end
    local data = self[PlaceableTCDisposalSkip.KEY]
    local index = indexOf(data.waiting, debris)
    if onEnter and index == nil then
        table.insert(data.waiting, debris)
        self:raiseActive()
    elseif onLeave and index ~= nil then
        table.remove(data.waiting, index)
    end
end

-- Server: disposes of every waiting piece that's been let go of, and keeps
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

-- The list work, apart from the placeable for the tests: deleted pieces
-- drop off, held ones stay, the rest are disposed of.
function PlaceableTCDisposalSkip.processWaiting(waiting)
    local flyTipping = g_currentMission.TheContractor ~= nil and g_currentMission.TheContractor.FlyTipping or nil
    for i = #waiting, 1, -1 do
        local debris = waiting[i]
        if debris.isDeleted or debris.nodeId == 0 then
            table.remove(waiting, i)
        elseif not TCDebris.isHeld(debris) and debris:getIsFree() then
            table.remove(waiting, i)
            if flyTipping ~= nil then
                flyTipping:disposeDebris(debris)
            else
                debris:delete()
            end
        end
    end
end
