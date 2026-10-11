-- Broadcast-only: vehicles left the parking return queue (062) - parked,
-- sent to the shop, taken by a dispatch or a cooldown, or gone. See
-- TheContractorParking:removeVehicles and src/events/README.md.

TCParkingRemovedEvent = {}
local TCParkingRemovedEvent_mt = Class(TCParkingRemovedEvent, Event)

InitEventClass(TCParkingRemovedEvent, "TCParkingRemovedEvent")

function TCParkingRemovedEvent.emptyNew()
    return Event.new(TCParkingRemovedEvent_mt)
end

function TCParkingRemovedEvent.new(vehicleIds)
    local self = TCParkingRemovedEvent.emptyNew()
    self.vehicleIds = vehicleIds
    return self
end

function TCParkingRemovedEvent:writeStream(streamId, connection)
    streamWriteInt32(streamId, #self.vehicleIds)
    for _, vehicleId in ipairs(self.vehicleIds) do
        streamWriteInt32(streamId, vehicleId)
    end
end

function TCParkingRemovedEvent:readStream(streamId, connection)
    self.vehicleIds = {}
    local count = streamReadInt32(streamId)
    for i = 1, count do
        self.vehicleIds[i] = streamReadInt32(streamId)
    end
    self:run(connection)
end

function TCParkingRemovedEvent:run(connection)
    g_currentMission.TheContractor.Parking:applyRemoved(self.vehicleIds)
end
