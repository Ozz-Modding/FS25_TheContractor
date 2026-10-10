-- Broadcast-only: a claim (052) landed on a logged job, and comes off its
-- margin (060). See src/events/README.md for the general event conventions.

TCLogClaimEvent = {}
local TCLogClaimEvent_mt = Class(TCLogClaimEvent, Event)

InitEventClass(TCLogClaimEvent, "TCLogClaimEvent")

function TCLogClaimEvent.emptyNew()
    return Event.new(TCLogClaimEvent_mt)
end

function TCLogClaimEvent.new(farmId, jobId, claim)
    local self = TCLogClaimEvent.emptyNew()
    self.farmId = farmId
    self.jobId = jobId
    self.claim = claim
    return self
end

function TCLogClaimEvent:writeStream(streamId, connection)
    streamWriteInt32(streamId, self.farmId)
    streamWriteInt32(streamId, self.jobId)
    TheContractorLogbook.writeClaim(streamId, self.claim)
end

function TCLogClaimEvent:readStream(streamId, connection)
    self.farmId = streamReadInt32(streamId)
    self.jobId = streamReadInt32(streamId)
    self.claim = TheContractorLogbook.readClaim(streamId)
    self:run(connection)
end

function TCLogClaimEvent:run(connection)
    g_currentMission.TheContractor.Logbook:applyClaim(self.farmId, self.jobId, self.claim)
end
