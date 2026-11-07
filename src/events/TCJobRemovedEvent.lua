-- Broadcast-only (141): the server takes a job away as if it had never
-- been (TheContractorJobs:removeJob: an attend job whose auction's called
-- off), and every client drops its copy. See src/events/README.md for the
-- general event conventions.

TCJobRemovedEvent = {}
local TCJobRemovedEvent_mt = Class(TCJobRemovedEvent, Event)

InitEventClass(TCJobRemovedEvent, "TCJobRemovedEvent")

function TCJobRemovedEvent.emptyNew()
    return Event.new(TCJobRemovedEvent_mt)
end

function TCJobRemovedEvent.new(farmId, jobId)
    local self = TCJobRemovedEvent.emptyNew()
    self.farmId = farmId
    self.jobId = jobId
    return self
end

function TCJobRemovedEvent:writeStream(streamId, connection)
    streamWriteInt32(streamId, self.farmId)
    streamWriteInt32(streamId, self.jobId)
end

function TCJobRemovedEvent:readStream(streamId, connection)
    self.farmId = streamReadInt32(streamId)
    self.jobId = streamReadInt32(streamId)
    self:run(connection)
end

function TCJobRemovedEvent:run(connection)
    g_currentMission.TheContractor.Jobs:applyJobRemoved(self.farmId, self.jobId)
end
