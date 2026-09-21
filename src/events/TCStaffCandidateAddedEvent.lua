-- Broadcast-only: the server adds a new candidate to the shared staff pool
-- (via TheContractorStaff:addCandidateToPool — the daily tick, or
-- ensureInitialPool at loadMap) and sends the full candidate snapshot to
-- every client, who just add it to their local copy of the pool directly.
-- See src/events/README.md for the general event conventions.

TCStaffCandidateAddedEvent = {}
local TCStaffCandidateAddedEvent_mt = Class(TCStaffCandidateAddedEvent, Event)

InitEventClass(TCStaffCandidateAddedEvent, "TCStaffCandidateAddedEvent")

function TCStaffCandidateAddedEvent.emptyNew()
    return Event.new(TCStaffCandidateAddedEvent_mt)
end

function TCStaffCandidateAddedEvent.new(candidate)
    local self = TCStaffCandidateAddedEvent.emptyNew()
    self.candidate = candidate
    return self
end

function TCStaffCandidateAddedEvent:writeStream(streamId, connection)
    TheContractorStaff.writeWorker(streamId, self.candidate)
end

function TCStaffCandidateAddedEvent:readStream(streamId, connection)
    self.candidate = TheContractorStaff.readWorker(streamId)
    self:run(connection)
end

function TCStaffCandidateAddedEvent:run(connection)
    g_currentMission.TheContractor.Staff:applyCandidateAdded(self.candidate)
end
