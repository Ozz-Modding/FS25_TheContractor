-- Broadcast-only: the server put equipment into the parking return queue
-- (062, TheContractorParking:returnVehicles). Carries the queue entries as
-- object ids. Every machine keeps its own copy of the queue, since
-- TCVehicleLock locks pending vehicles and the allocation picker marks
-- them. Hiding them is TCEquipmentVisibilityEvent's job. See
-- src/events/README.md for the general event conventions.

TCParkingQueuedEvent = {}
local TCParkingQueuedEvent_mt = Class(TCParkingQueuedEvent, Event)

InitEventClass(TCParkingQueuedEvent, "TCParkingQueuedEvent")

function TCParkingQueuedEvent.emptyNew()
    return Event.new(TCParkingQueuedEvent_mt)
end

function TCParkingQueuedEvent.new(entries)
    local self = TCParkingQueuedEvent.emptyNew()
    self.entries = entries
    return self
end

function TCParkingQueuedEvent:writeStream(streamId, connection)
    TheContractorParking.writeEntries(streamId, self.entries)
end

function TCParkingQueuedEvent:readStream(streamId, connection)
    self.entries = TheContractorParking.readEntries(streamId)
    self:run(connection)
end

function TCParkingQueuedEvent:run(connection)
    g_currentMission.TheContractor.Parking:applyQueued(self.entries)
end
