-- Client asks for one of its farm's idle workers to drive a vehicle under
-- AutoDrive/Courseplay (037), from TCDriverPickerDialog. The server
-- re-validates and binds - see TheContractorDrivers:assignDriver - and the
-- result reaches every client as TCDriverBindingEvent plus the usual
-- TCWorkerStatusChangedEvent. The client sends the AD/CP start itself right
-- after this, on the same connection, so the server always has the binding
-- in place by the time the start arrives. See src/events/README.md for the
-- general event conventions.

TCAssignDriverEvent = {}
local TCAssignDriverEvent_mt = Class(TCAssignDriverEvent, Event)

InitEventClass(TCAssignDriverEvent, "TCAssignDriverEvent")

function TCAssignDriverEvent.emptyNew()
    return Event.new(TCAssignDriverEvent_mt)
end

-- vehicleId: the root vehicle's network object id.
function TCAssignDriverEvent.new(farmId, workerId, vehicleId)
    local self = TCAssignDriverEvent.emptyNew()
    self.farmId = farmId
    self.workerId = workerId
    self.vehicleId = vehicleId
    return self
end

function TCAssignDriverEvent:writeStream(streamId, connection)
    streamWriteInt32(streamId, self.farmId)
    streamWriteInt32(streamId, self.workerId)
    streamWriteInt32(streamId, self.vehicleId)
end

function TCAssignDriverEvent:readStream(streamId, connection)
    self.farmId = streamReadInt32(streamId)
    self.workerId = streamReadInt32(streamId)
    self.vehicleId = streamReadInt32(streamId)
    self:run(connection)
end

function TCAssignDriverEvent:run(connection)
    if g_currentMission:getIsServer() then
        g_currentMission.TheContractor.Drivers:assignDriver(self.farmId, self.workerId,
            NetworkUtil.getObject(self.vehicleId))
    end
end
