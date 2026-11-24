-- Broadcast-only: a vehicle was reloaded as a new object (TCVehicleReplace),
-- so every client swaps its old object id for the new one too. Ids only,
-- never the vehicles: the new one may not have streamed in yet.

TCVehicleReplacedEvent = {}
local TCVehicleReplacedEvent_mt = Class(TCVehicleReplacedEvent, Event)

InitEventClass(TCVehicleReplacedEvent, "TCVehicleReplacedEvent")

function TCVehicleReplacedEvent.emptyNew()
    return Event.new(TCVehicleReplacedEvent_mt)
end

function TCVehicleReplacedEvent.new(oldId, newId)
    local self = TCVehicleReplacedEvent.emptyNew()
    self.oldId = oldId
    self.newId = newId
    return self
end

function TCVehicleReplacedEvent:writeStream(streamId, connection)
    streamWriteInt32(streamId, self.oldId)
    streamWriteInt32(streamId, self.newId)
end

function TCVehicleReplacedEvent:readStream(streamId, connection)
    self.oldId = streamReadInt32(streamId)
    self.newId = streamReadInt32(streamId)
    self:run(connection)
end

function TCVehicleReplacedEvent:run(connection)
    if not connection:getIsServer() then
        return
    end
    TCVehicleReplace.replace(self.oldId, self.newId)
end
