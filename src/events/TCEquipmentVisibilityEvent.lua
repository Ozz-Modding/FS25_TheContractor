-- Broadcast-only: the server hides or reveals a set of equipment outside
-- the cooldown flow (020's dispatch staging - see
-- TheContractorDispatch:startJobForWorker) and tells every client to do the
-- same, since hiding is local rendering/physics state the base game never
-- networks itself. See TCEquipmentVisibility.setVisibleEverywhere and
-- src/events/README.md for the general event conventions.

TCEquipmentVisibilityEvent = {}
local TCEquipmentVisibilityEvent_mt = Class(TCEquipmentVisibilityEvent, Event)

InitEventClass(TCEquipmentVisibilityEvent, "TCEquipmentVisibilityEvent")

function TCEquipmentVisibilityEvent.emptyNew()
    return Event.new(TCEquipmentVisibilityEvent_mt)
end

function TCEquipmentVisibilityEvent.new(vehicleIds, isVisible)
    local self = TCEquipmentVisibilityEvent.emptyNew()
    self.vehicleIds = vehicleIds
    self.isVisible = isVisible
    return self
end

function TCEquipmentVisibilityEvent:writeStream(streamId, connection)
    streamWriteBool(streamId, self.isVisible)
    streamWriteInt32(streamId, #self.vehicleIds)
    for _, vehicleId in ipairs(self.vehicleIds) do
        streamWriteInt32(streamId, vehicleId)
    end
end

function TCEquipmentVisibilityEvent:readStream(streamId, connection)
    self.isVisible = streamReadBool(streamId)
    self.vehicleIds = {}
    local count = streamReadInt32(streamId)
    for i = 1, count do
        self.vehicleIds[i] = streamReadInt32(streamId)
    end
    self:run(connection)
end

function TCEquipmentVisibilityEvent:run(connection)
    if self.isVisible then
        TCEquipmentVisibility.revealVehicles(self.vehicleIds)
    else
        TCEquipmentVisibility.hideVehicles(self.vehicleIds)
    end
end
