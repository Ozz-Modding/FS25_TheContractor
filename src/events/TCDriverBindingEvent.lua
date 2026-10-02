-- Broadcast-only: the server bound a staff driver to a vehicle, or freed
-- one (037, TheContractorDrivers:bindDriver/releaseDriver). Clients need
-- the binding itself - not just the worker's DRIVING status, which travels
-- separately as TCWorkerStatusChangedEvent - so their start gates know a
-- vehicle already has a driver (no picker for a hand-off) and the Staff UI
-- can say what each driver is out in. The vehicle goes as its network
-- object id and is only ever resolved lazily, same as initial client
-- state. See src/events/README.md for the general event conventions.

TCDriverBindingEvent = {}
local TCDriverBindingEvent_mt = Class(TCDriverBindingEvent, Event)

InitEventClass(TCDriverBindingEvent, "TCDriverBindingEvent")

function TCDriverBindingEvent.emptyNew()
    return Event.new(TCDriverBindingEvent_mt)
end

function TCDriverBindingEvent.new(vehicleId, farmId, workerId, isBound)
    local self = TCDriverBindingEvent.emptyNew()
    self.vehicleId = vehicleId
    self.farmId = farmId
    self.workerId = workerId
    self.isBound = isBound
    return self
end

function TCDriverBindingEvent:writeStream(streamId, connection)
    streamWriteInt32(streamId, self.vehicleId)
    streamWriteInt32(streamId, self.farmId)
    streamWriteInt32(streamId, self.workerId)
    streamWriteBool(streamId, self.isBound)
end

function TCDriverBindingEvent:readStream(streamId, connection)
    self.vehicleId = streamReadInt32(streamId)
    self.farmId = streamReadInt32(streamId)
    self.workerId = streamReadInt32(streamId)
    self.isBound = streamReadBool(streamId)
    self:run(connection)
end

function TCDriverBindingEvent:run(connection)
    local drivers = g_currentMission.TheContractor.Drivers
    if self.isBound then
        drivers:applyBindingSet(self.vehicleId, self.farmId, self.workerId)
    else
        drivers:applyBindingCleared(self.vehicleId)
    end
end
