-- Broadcast-only: the server flags a hired-worker job as on the road to its
-- field, or arrived/called off (via TheContractorJobs:setJobTravelling), and
-- sends the flag to other clients, who just apply it directly. See
-- src/events/README.md for the general event conventions.

TCJobTravellingEvent = {}
local TCJobTravellingEvent_mt = Class(TCJobTravellingEvent, Event)

InitEventClass(TCJobTravellingEvent, "TCJobTravellingEvent")

function TCJobTravellingEvent.emptyNew()
    return Event.new(TCJobTravellingEvent_mt)
end

function TCJobTravellingEvent.new(farmId, jobId, isTravelling)
    local self = TCJobTravellingEvent.emptyNew()
    self.farmId = farmId
    self.jobId = jobId
    self.isTravelling = isTravelling
    return self
end

function TCJobTravellingEvent:writeStream(streamId, connection)
    streamWriteInt32(streamId, self.farmId)
    streamWriteInt32(streamId, self.jobId)
    streamWriteBool(streamId, self.isTravelling)
end

function TCJobTravellingEvent:readStream(streamId, connection)
    self.farmId = streamReadInt32(streamId)
    self.jobId = streamReadInt32(streamId)
    self.isTravelling = streamReadBool(streamId)
    self:run(connection)
end

function TCJobTravellingEvent:run(connection)
    g_currentMission.TheContractor.Jobs:applyJobTravelling(self.farmId, self.jobId, self.isTravelling)
end
