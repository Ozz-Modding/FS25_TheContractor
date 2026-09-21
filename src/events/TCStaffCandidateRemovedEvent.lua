-- Broadcast-only: the server removes a candidate from the shared staff pool
-- without anyone hiring them (via TheContractorStaff:removeCandidateFromPool
-- — the daily tick rolling a departure) and tells every client to drop it
-- from their local copy of the pool. See src/events/README.md for the
-- general event conventions.

TCStaffCandidateRemovedEvent = {}
local TCStaffCandidateRemovedEvent_mt = Class(TCStaffCandidateRemovedEvent, Event)

InitEventClass(TCStaffCandidateRemovedEvent, "TCStaffCandidateRemovedEvent")

function TCStaffCandidateRemovedEvent.emptyNew()
    return Event.new(TCStaffCandidateRemovedEvent_mt)
end

function TCStaffCandidateRemovedEvent.new(candidateId)
    local self = TCStaffCandidateRemovedEvent.emptyNew()
    self.candidateId = candidateId
    return self
end

function TCStaffCandidateRemovedEvent:writeStream(streamId, connection)
    streamWriteInt32(streamId, self.candidateId)
end

function TCStaffCandidateRemovedEvent:readStream(streamId, connection)
    self.candidateId = streamReadInt32(streamId)
    self:run(connection)
end

function TCStaffCandidateRemovedEvent:run(connection)
    g_currentMission.TheContractor.Staff:applyCandidateRemoved(self.candidateId)
end
