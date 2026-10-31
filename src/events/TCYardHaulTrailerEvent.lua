-- Broadcast-only (126): a farmer's trailer is out for a load they want
-- sold, by its network object id, with the load it came with, so every
-- machine keeps it off its lists of the farm's vehicles
-- (TheContractorRepairContracts.isContractVehicle), marks it on the map and
-- shows the load. See src/events/README.md.

TCYardHaulTrailerEvent = {}
local TCYardHaulTrailerEvent_mt = Class(TCYardHaulTrailerEvent, Event)

InitEventClass(TCYardHaulTrailerEvent, "TCYardHaulTrailerEvent")

function TCYardHaulTrailerEvent.emptyNew()
    return Event.new(TCYardHaulTrailerEvent_mt)
end

function TCYardHaulTrailerEvent.new(farmId, jobId, vehicleId, liters)
    local self = TCYardHaulTrailerEvent.emptyNew()
    self.farmId = farmId
    self.jobId = jobId
    self.vehicleId = vehicleId
    self.liters = liters
    return self
end

function TCYardHaulTrailerEvent:writeStream(streamId, connection)
    streamWriteInt32(streamId, self.farmId)
    streamWriteInt32(streamId, self.jobId)
    streamWriteInt32(streamId, self.vehicleId or 0)
    streamWriteFloat32(streamId, self.liters or 0)
end

function TCYardHaulTrailerEvent:readStream(streamId, connection)
    self.farmId = streamReadInt32(streamId)
    self.jobId = streamReadInt32(streamId)
    self.vehicleId = streamReadInt32(streamId)
    self.liters = streamReadFloat32(streamId)
    self:run(connection)
end

function TCYardHaulTrailerEvent:run(connection)
    g_currentMission.TheContractor.YardHaul:applyTrailer(self.farmId, self.jobId, self.vehicleId, self.liters)
end
