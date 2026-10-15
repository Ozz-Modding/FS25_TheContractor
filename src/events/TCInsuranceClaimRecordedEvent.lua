-- Broadcast-only: a settled machinery insurance claim went on a farm's
-- claims history (070, TheContractorMachineryInsurance:settle). Clients need
-- the history to price the policy for the Finances tab. See
-- src/events/README.md for the general event conventions.

TCInsuranceClaimRecordedEvent = {}
local TCInsuranceClaimRecordedEvent_mt = Class(TCInsuranceClaimRecordedEvent, Event)

InitEventClass(TCInsuranceClaimRecordedEvent, "TCInsuranceClaimRecordedEvent")

function TCInsuranceClaimRecordedEvent.emptyNew()
    return Event.new(TCInsuranceClaimRecordedEvent_mt)
end

function TCInsuranceClaimRecordedEvent.new(farmId, record)
    local self = TCInsuranceClaimRecordedEvent.emptyNew()
    self.farmId = farmId
    self.record = record
    return self
end

function TCInsuranceClaimRecordedEvent:writeStream(streamId, connection)
    streamWriteInt32(streamId, self.farmId)
    TheContractorMachineryInsurance.writeRecord(streamId, self.record)
end

function TCInsuranceClaimRecordedEvent:readStream(streamId, connection)
    self.farmId = streamReadInt32(streamId)
    self.record = TheContractorMachineryInsurance.readRecord(streamId)
    self:run(connection)
end

function TCInsuranceClaimRecordedEvent:run(connection)
    g_currentMission.TheContractor.MachineryInsurance:applyClaimRecorded(self.farmId, self.record)
end
