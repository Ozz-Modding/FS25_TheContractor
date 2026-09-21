-- Client requests a price counter-offer on an offered/negotiating job from
-- the Inbox (014). Server re-resolves the round via
-- TheContractorJobs:proposeCounterOffer — which owns the eagerness state,
-- the state-machine transition, and the TCJobNegotiationUpdatedEvent
-- broadcast — so eagerness stays server-authoritative and a client can't
-- just resend the same counter until it happens to succeed. See
-- src/events/README.md for the general event conventions.

TCCounterOfferEvent = {}
local TCCounterOfferEvent_mt = Class(TCCounterOfferEvent, Event)

InitEventClass(TCCounterOfferEvent, "TCCounterOfferEvent")

function TCCounterOfferEvent.emptyNew()
    return Event.new(TCCounterOfferEvent_mt)
end

function TCCounterOfferEvent.new(farmId, jobId, counterPrice)
    local self = TCCounterOfferEvent.emptyNew()
    self.farmId = farmId
    self.jobId = jobId
    self.counterPrice = counterPrice
    return self
end

function TCCounterOfferEvent:writeStream(streamId, connection)
    streamWriteInt32(streamId, self.farmId)
    streamWriteInt32(streamId, self.jobId)
    streamWriteFloat32(streamId, self.counterPrice)
end

function TCCounterOfferEvent:readStream(streamId, connection)
    self.farmId = streamReadInt32(streamId)
    self.jobId = streamReadInt32(streamId)
    self.counterPrice = streamReadFloat32(streamId)
    self:run(connection)
end

function TCCounterOfferEvent:run(connection)
    if not g_currentMission:getIsServer() then
        return
    end

    g_currentMission.TheContractor.Jobs:proposeCounterOffer(self.farmId, self.jobId, self.counterPrice)
end
