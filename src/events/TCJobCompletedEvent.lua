-- Broadcast-only: the server pays out and completes a job (via
-- TheContractorJobs:completeJob, 022) and sends the full job snapshot to
-- every client. Reuses TheContractorJobs.writeJob/readJob (same shape as
-- TCJobCreatedEvent/TCJobAllocatedEvent) rather than a partial-field update,
-- since state/paymentAmount/completionPercentage all move together. Applied
-- via the existing registerJob (isNewArrival = false, same as an allocation
-- update) since a completion is never a "new offer" for HUD purposes. See
-- src/events/README.md for the general event conventions.

TCJobCompletedEvent = {}
local TCJobCompletedEvent_mt = Class(TCJobCompletedEvent, Event)

InitEventClass(TCJobCompletedEvent, "TCJobCompletedEvent")

function TCJobCompletedEvent.emptyNew()
    return Event.new(TCJobCompletedEvent_mt)
end

function TCJobCompletedEvent.new(job)
    local self = TCJobCompletedEvent.emptyNew()
    self.job = job
    return self
end

function TCJobCompletedEvent:writeStream(streamId, connection)
    TheContractorJobs.writeJob(streamId, self.job)
end

function TCJobCompletedEvent:readStream(streamId, connection)
    self.job = TheContractorJobs.readJob(streamId)
    self:run(connection)
end

function TCJobCompletedEvent:run(connection)
    g_currentMission.TheContractor.Jobs:registerJob(self.job, false)
end
