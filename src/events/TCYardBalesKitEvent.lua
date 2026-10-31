-- Broadcast-only (124): a yard bale job's kit is out - the farmer's
-- telehandler and its bale fork, by their network object ids (0 for none),
-- so every machine keeps them off its lists of the farm's vehicles
-- (TheContractorRepairContracts.isContractVehicle). See src/events/README.md.

TCYardBalesKitEvent = {}
local TCYardBalesKitEvent_mt = Class(TCYardBalesKitEvent, Event)

InitEventClass(TCYardBalesKitEvent, "TCYardBalesKitEvent")

function TCYardBalesKitEvent.emptyNew()
    return Event.new(TCYardBalesKitEvent_mt)
end

function TCYardBalesKitEvent.new(farmId, jobId, vehicleId, attachmentId)
    local self = TCYardBalesKitEvent.emptyNew()
    self.farmId = farmId
    self.jobId = jobId
    self.vehicleId = vehicleId
    self.attachmentId = attachmentId
    return self
end

function TCYardBalesKitEvent:writeStream(streamId, connection)
    streamWriteInt32(streamId, self.farmId)
    streamWriteInt32(streamId, self.jobId)
    streamWriteInt32(streamId, self.vehicleId or 0)
    streamWriteInt32(streamId, self.attachmentId or 0)
end

function TCYardBalesKitEvent:readStream(streamId, connection)
    self.farmId = streamReadInt32(streamId)
    self.jobId = streamReadInt32(streamId)
    self.vehicleId = streamReadInt32(streamId)
    self.attachmentId = streamReadInt32(streamId)
    self:run(connection)
end

function TCYardBalesKitEvent:run(connection)
    g_currentMission.TheContractor.YardBales:applyKit(self.farmId, self.jobId, self.vehicleId, self.attachmentId)
end
