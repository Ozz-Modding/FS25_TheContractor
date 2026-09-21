-- Broadcast-only: the server allocates a worker/equipment to a job (via
-- TheContractorAllocation:allocateJob, always triggered by server-side
-- application of TCAllocateJobEvent) and sends the full job snapshot to
-- every client. Reuses TheContractorJobs.writeJob/readJob (same shape as
-- TCJobCreatedEvent/TCJobNegotiationUpdatedEvent) rather than a
-- partial-field update, since state/assignedWorkerId/assignedEquipmentIds
-- all move together. Applied via the existing registerJob (isNewArrival =
-- false, same as a negotiation update) since an allocation is never a "new
-- offer" for HUD purposes. See src/events/README.md for the general event
-- conventions.

TCJobAllocatedEvent = {}
local TCJobAllocatedEvent_mt = Class(TCJobAllocatedEvent, Event)

InitEventClass(TCJobAllocatedEvent, "TCJobAllocatedEvent")

function TCJobAllocatedEvent.emptyNew()
    return Event.new(TCJobAllocatedEvent_mt)
end

function TCJobAllocatedEvent.new(job)
    local self = TCJobAllocatedEvent.emptyNew()
    self.job = job
    return self
end

function TCJobAllocatedEvent:writeStream(streamId, connection)
    TheContractorJobs.writeJob(streamId, self.job)
end

function TCJobAllocatedEvent:readStream(streamId, connection)
    self.job = TheContractorJobs.readJob(streamId)
    self:run(connection)
end

function TCJobAllocatedEvent:run(connection)
    g_currentMission.TheContractor.Jobs:registerJob(self.job, false)
end
