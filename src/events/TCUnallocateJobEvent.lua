-- Client requests taking the crew and equipment off one of its farm's
-- allocated or in-progress jobs (094, from the Calendar's Job details).
-- The server re-checks (TheContractorJobs.getUnallocateProblem) and applies
-- it with TheContractorJobs:unallocateJob, which sends every client the
-- job's new snapshot (TCJobAllocatedEvent) - so this has no apply side of
-- its own. See src/events/README.md for the general event conventions.

TCUnallocateJobEvent = {}
local TCUnallocateJobEvent_mt = Class(TCUnallocateJobEvent, Event)

InitEventClass(TCUnallocateJobEvent, "TCUnallocateJobEvent")

function TCUnallocateJobEvent.emptyNew()
    return Event.new(TCUnallocateJobEvent_mt)
end

function TCUnallocateJobEvent.new(farmId, jobId)
    local self = TCUnallocateJobEvent.emptyNew()
    self.farmId = farmId
    self.jobId = jobId
    return self
end

function TCUnallocateJobEvent:writeStream(streamId, connection)
    streamWriteInt32(streamId, self.farmId)
    streamWriteInt32(streamId, self.jobId)
end

function TCUnallocateJobEvent:readStream(streamId, connection)
    self.farmId = streamReadInt32(streamId)
    self.jobId = streamReadInt32(streamId)
    self:run(connection)
end

function TCUnallocateJobEvent:run(connection)
    if g_currentMission:getIsServer() then
        g_currentMission.TheContractor.Jobs:unallocateJob(self.farmId, self.jobId)
    end
end
