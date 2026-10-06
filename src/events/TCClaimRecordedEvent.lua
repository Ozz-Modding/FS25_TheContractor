-- Broadcast-only: an insured claim went on a farm's claims history (052,
-- TheContractorClaims:deliverClaim). Clients need the history to price
-- public liability for the Finances tab. See src/events/README.md for the
-- general event conventions.

TCClaimRecordedEvent = {}
local TCClaimRecordedEvent_mt = Class(TCClaimRecordedEvent, Event)

InitEventClass(TCClaimRecordedEvent, "TCClaimRecordedEvent")

function TCClaimRecordedEvent.emptyNew()
    return Event.new(TCClaimRecordedEvent_mt)
end

function TCClaimRecordedEvent.new(farmId, record)
    local self = TCClaimRecordedEvent.emptyNew()
    self.farmId = farmId
    self.record = record
    return self
end

function TCClaimRecordedEvent:writeStream(streamId, connection)
    streamWriteInt32(streamId, self.farmId)
    TheContractorClaims.writeRecord(streamId, self.record)
end

function TCClaimRecordedEvent:readStream(streamId, connection)
    self.farmId = streamReadInt32(streamId)
    self.record = TheContractorClaims.readRecord(streamId)
    self:run(connection)
end

function TCClaimRecordedEvent:run(connection)
    g_currentMission.TheContractor.Claims:applyClaimRecorded(self.farmId, self.record)
end
