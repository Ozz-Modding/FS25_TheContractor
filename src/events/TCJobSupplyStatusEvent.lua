-- Broadcast-only: the server puts a job on hold for supplies, or takes it
-- off hold (032, via TheContractorJobs:setJobSupplyStatus - see
-- TCJobSupplies), and sends the status to other clients, who just apply it
-- directly. An empty status string stands for "not on hold". See
-- src/events/README.md for the general event conventions.

TCJobSupplyStatusEvent = {}
local TCJobSupplyStatusEvent_mt = Class(TCJobSupplyStatusEvent, Event)

InitEventClass(TCJobSupplyStatusEvent, "TCJobSupplyStatusEvent")

function TCJobSupplyStatusEvent.emptyNew()
    return Event.new(TCJobSupplyStatusEvent_mt)
end

function TCJobSupplyStatusEvent.new(farmId, jobId, status, fillTypeName)
    local self = TCJobSupplyStatusEvent.emptyNew()
    self.farmId = farmId
    self.jobId = jobId
    self.status = status
    self.fillTypeName = fillTypeName
    return self
end

function TCJobSupplyStatusEvent:writeStream(streamId, connection)
    streamWriteInt32(streamId, self.farmId)
    streamWriteInt32(streamId, self.jobId)
    streamWriteString(streamId, self.status or "")
    streamWriteString(streamId, self.fillTypeName or "")
end

function TCJobSupplyStatusEvent:readStream(streamId, connection)
    self.farmId = streamReadInt32(streamId)
    self.jobId = streamReadInt32(streamId)
    local status = streamReadString(streamId)
    local fillTypeName = streamReadString(streamId)
    self.status = status ~= "" and status or nil
    self.fillTypeName = fillTypeName ~= "" and fillTypeName or nil
    self:run(connection)
end

function TCJobSupplyStatusEvent:run(connection)
    g_currentMission.TheContractor.Jobs:applyJobSupplyStatus(self.farmId, self.jobId, self.status, self.fillTypeName)
end
