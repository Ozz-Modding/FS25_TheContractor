-- Broadcast-only (127): an emergency refuel's machine is out on the field -
-- the farmer's machine and its attachment, by their network object ids (0
-- for none), so every machine keeps them off its lists of the farm's
-- vehicles (TheContractorRepairContracts.isContractVehicle), marks the
-- machine on the map and stands the farmer by it. See src/events/README.md.

TCRefuelMachineEvent = {}
local TCRefuelMachineEvent_mt = Class(TCRefuelMachineEvent, Event)

InitEventClass(TCRefuelMachineEvent, "TCRefuelMachineEvent")

function TCRefuelMachineEvent.emptyNew()
    return Event.new(TCRefuelMachineEvent_mt)
end

function TCRefuelMachineEvent.new(farmId, jobId, vehicleId, attachmentId)
    local self = TCRefuelMachineEvent.emptyNew()
    self.farmId = farmId
    self.jobId = jobId
    self.vehicleId = vehicleId
    self.attachmentId = attachmentId
    return self
end

function TCRefuelMachineEvent:writeStream(streamId, connection)
    streamWriteInt32(streamId, self.farmId)
    streamWriteInt32(streamId, self.jobId)
    streamWriteInt32(streamId, self.vehicleId or 0)
    streamWriteInt32(streamId, self.attachmentId or 0)
end

function TCRefuelMachineEvent:readStream(streamId, connection)
    self.farmId = streamReadInt32(streamId)
    self.jobId = streamReadInt32(streamId)
    self.vehicleId = streamReadInt32(streamId)
    self.attachmentId = streamReadInt32(streamId)
    self:run(connection)
end

function TCRefuelMachineEvent:run(connection)
    g_currentMission.TheContractor.EmergencyRefuel:applyMachine(self.farmId, self.jobId, self.vehicleId,
        self.attachmentId)
end
