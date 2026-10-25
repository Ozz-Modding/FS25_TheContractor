-- 102: client asks for a workshop job (an ADS repair contract) to be
-- quoted at a margin over its cost, from the Negotiate dialog. The server
-- re-checks it (an inspected offer of the farm's, a margin in range) and the
-- customer answers once (TheContractorRepairContracts:proposeQuote): the
-- job's accepted at that price, or declined. Both go out to every client
-- the usual way (TCJobNegotiationUpdatedEvent for the price and margin,
-- TCJobStateChangedEvent for the state), so this needs no reply: the
-- asking client watches the job's state (MenuContractor's pending quote).
-- See src/events/README.md for the general event conventions.

TCRepairQuoteEvent = {}
local TCRepairQuoteEvent_mt = Class(TCRepairQuoteEvent, Event)

InitEventClass(TCRepairQuoteEvent, "TCRepairQuoteEvent")

function TCRepairQuoteEvent.emptyNew()
    return Event.new(TCRepairQuoteEvent_mt)
end

function TCRepairQuoteEvent.new(farmId, jobId, margin)
    local self = TCRepairQuoteEvent.emptyNew()
    self.farmId = farmId
    self.jobId = jobId
    self.margin = margin
    return self
end

function TCRepairQuoteEvent:writeStream(streamId, connection)
    streamWriteInt32(streamId, self.farmId)
    streamWriteInt32(streamId, self.jobId)
    streamWriteFloat32(streamId, self.margin)
end

function TCRepairQuoteEvent:readStream(streamId, connection)
    self.farmId = streamReadInt32(streamId)
    self.jobId = streamReadInt32(streamId)
    self.margin = streamReadFloat32(streamId)
    self:run(connection)
end

function TCRepairQuoteEvent:run(connection)
    if not g_currentMission:getIsServer() then
        return
    end

    g_currentMission.TheContractor.RepairContracts:proposeQuote(self.farmId, self.jobId, self.margin)
end
