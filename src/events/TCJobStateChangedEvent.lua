-- Broadcast-only: the server validates and applies a job state transition
-- (via TheContractorJobs:transitionJobState) and sends the resulting state
-- to other clients, who just apply it directly. See src/events/README.md
-- for the general event conventions.

TCJobStateChangedEvent = {}
local TCJobStateChangedEvent_mt = Class(TCJobStateChangedEvent, Event)

InitEventClass(TCJobStateChangedEvent, "TCJobStateChangedEvent")

function TCJobStateChangedEvent.emptyNew()
    return Event.new(TCJobStateChangedEvent_mt)
end

function TCJobStateChangedEvent.new(farmId, jobId, state)
    local self = TCJobStateChangedEvent.emptyNew()
    self.farmId = farmId
    self.jobId = jobId
    self.state = state
    return self
end

function TCJobStateChangedEvent:writeStream(streamId, connection)
    streamWriteInt32(streamId, self.farmId)
    streamWriteInt32(streamId, self.jobId)
    streamWriteString(streamId, self.state)
end

function TCJobStateChangedEvent:readStream(streamId, connection)
    self.farmId = streamReadInt32(streamId)
    self.jobId = streamReadInt32(streamId)
    self.state = streamReadString(streamId)
    self:run(connection)
end

function TCJobStateChangedEvent:run(connection)
    g_currentMission.TheContractor.Jobs:applyJobStateChanged(self.farmId, self.jobId, self.state)
end
