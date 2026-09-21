-- Client requests releasing (firing) a worker from its farm's roster, from
-- the Staff UI (017). Server re-validates the worker actually belongs to the
-- requesting farm's roster before acting — see TheContractorStaff:releaseWorker.
-- See src/events/README.md for the general event conventions.

TCReleaseWorkerEvent = {}
local TCReleaseWorkerEvent_mt = Class(TCReleaseWorkerEvent, Event)

InitEventClass(TCReleaseWorkerEvent, "TCReleaseWorkerEvent")

function TCReleaseWorkerEvent.emptyNew()
    return Event.new(TCReleaseWorkerEvent_mt)
end

function TCReleaseWorkerEvent.new(farmId, workerId)
    local self = TCReleaseWorkerEvent.emptyNew()
    self.farmId = farmId
    self.workerId = workerId
    return self
end

function TCReleaseWorkerEvent:writeStream(streamId, connection)
    streamWriteInt32(streamId, self.farmId)
    streamWriteInt32(streamId, self.workerId)
end

function TCReleaseWorkerEvent:readStream(streamId, connection)
    self.farmId = streamReadInt32(streamId)
    self.workerId = streamReadInt32(streamId)
    self:run(connection)
end

function TCReleaseWorkerEvent:run(connection)
    if g_currentMission:getIsServer() then
        g_currentMission.TheContractor.Staff:releaseWorker(self.farmId, self.workerId)
    end
end
