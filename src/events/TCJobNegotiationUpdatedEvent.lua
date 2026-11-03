-- Broadcast-only: the server resolves a negotiation round (via
-- TheContractorJobs:proposeCounterOffer) and sends the resulting job
-- snapshot to other clients. Reuses TheContractorJobs.writeJob/readJob (full
-- snapshot, same as TCJobCreatedEvent) rather than just the changed fields —
-- price/state/negotiationRounds can all move in one round, and
-- there's no existing partial-update wire helper to build on. Applied via
-- the existing registerJob (isNewArrival=false, same as initial-client-state
-- replay) since a negotiation update is never a "new offer" for HUD
-- purposes. See src/events/README.md for the general event conventions.

TCJobNegotiationUpdatedEvent = {}
local TCJobNegotiationUpdatedEvent_mt = Class(TCJobNegotiationUpdatedEvent, Event)

InitEventClass(TCJobNegotiationUpdatedEvent, "TCJobNegotiationUpdatedEvent")

function TCJobNegotiationUpdatedEvent.emptyNew()
    return Event.new(TCJobNegotiationUpdatedEvent_mt)
end

function TCJobNegotiationUpdatedEvent.new(job)
    local self = TCJobNegotiationUpdatedEvent.emptyNew()
    self.job = job
    return self
end

function TCJobNegotiationUpdatedEvent:writeStream(streamId, connection)
    TheContractorJobs.writeJob(streamId, self.job)
end

function TCJobNegotiationUpdatedEvent:readStream(streamId, connection)
    self.job = TheContractorJobs.readJob(streamId)
    self:run(connection)
end

function TCJobNegotiationUpdatedEvent:run(connection)
    g_currentMission.TheContractor.Jobs:registerJob(self.job, false)
end
