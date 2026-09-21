-- Client requests accept/decline on an offered (or negotiating) job from the
-- Inbox (013). Server re-validates the job belongs to the requesting farm
-- and is still in a respondable state, then drives the transition through
-- TheContractorJobs:transitionJobState — which already owns the state-machine
-- check, local apply, and TCJobStateChangedEvent broadcast to other clients
-- (see TCDebugSetJobStateEvent.lua for the closest sibling of this
-- request/validate shape). No negotiation here (014's territory) — accept
-- always requests STATE.ACCEPTED directly, per Job.lua's offered->accepted
-- shortcut transition. See src/events/README.md for the general event
-- conventions.

TCRespondToJobOfferEvent = {}
local TCRespondToJobOfferEvent_mt = Class(TCRespondToJobOfferEvent, Event)

InitEventClass(TCRespondToJobOfferEvent, "TCRespondToJobOfferEvent")

function TCRespondToJobOfferEvent.emptyNew()
    return Event.new(TCRespondToJobOfferEvent_mt)
end

function TCRespondToJobOfferEvent.new(farmId, jobId, accept)
    local self = TCRespondToJobOfferEvent.emptyNew()
    self.farmId = farmId
    self.jobId = jobId
    self.accept = accept
    return self
end

function TCRespondToJobOfferEvent:writeStream(streamId, connection)
    streamWriteInt32(streamId, self.farmId)
    streamWriteInt32(streamId, self.jobId)
    streamWriteBool(streamId, self.accept)
end

function TCRespondToJobOfferEvent:readStream(streamId, connection)
    self.farmId = streamReadInt32(streamId)
    self.jobId = streamReadInt32(streamId)
    self.accept = streamReadBool(streamId)
    self:run(connection)
end

function TCRespondToJobOfferEvent:run(connection)
    if not g_currentMission:getIsServer() then
        return
    end

    local jobs = g_currentMission.TheContractor.Jobs
    local job = jobs:getJob(self.farmId, self.jobId)
    if job == nil or job.farmId ~= self.farmId then
        return
    end

    local newState = self.accept and TheContractorJob.STATE.ACCEPTED or TheContractorJob.STATE.DECLINED
    jobs:transitionJobState(self.farmId, self.jobId, newState)
end
