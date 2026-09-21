-- Broadcast-only: the server creates a job (via TheContractorJobs:createJob
-- — always triggered by server-side business logic, generation in 011 or
-- the tcCreateTestJob debug command in main.lua) and sends the full job
-- snapshot to other clients, who just register it directly. See
-- src/events/README.md for the general event conventions.

TCJobCreatedEvent = {}
local TCJobCreatedEvent_mt = Class(TCJobCreatedEvent, Event)

InitEventClass(TCJobCreatedEvent, "TCJobCreatedEvent")

function TCJobCreatedEvent.emptyNew()
    return Event.new(TCJobCreatedEvent_mt)
end

function TCJobCreatedEvent.new(job)
    local self = TCJobCreatedEvent.emptyNew()
    self.job = job
    return self
end

function TCJobCreatedEvent:writeStream(streamId, connection)
    TheContractorJobs.writeJob(streamId, self.job)
end

function TCJobCreatedEvent:readStream(streamId, connection)
    self.job = TheContractorJobs.readJob(streamId)
    self:run(connection)
end

function TCJobCreatedEvent:run(connection)
    g_currentMission.TheContractor.Jobs:registerJob(self.job)
end
