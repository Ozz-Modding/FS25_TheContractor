-- Client asks to give one of its farm's workers a pay rise, from the Staff
-- tab (058). optionKey is one of TheContractorPayReviews.getRiseOptions'
-- keys; the server re-checks the worker and works the new pay out again
-- (TheContractorPayReviews:requestRise). The result goes out as a
-- TCWorkerPayChangedEvent. See src/events/README.md for the general event
-- conventions.

TCPayRiseEvent = {}
local TCPayRiseEvent_mt = Class(TCPayRiseEvent, Event)

InitEventClass(TCPayRiseEvent, "TCPayRiseEvent")

function TCPayRiseEvent.emptyNew()
    return Event.new(TCPayRiseEvent_mt)
end

function TCPayRiseEvent.new(farmId, workerId, optionKey)
    local self = TCPayRiseEvent.emptyNew()
    self.farmId = farmId
    self.workerId = workerId
    self.optionKey = optionKey
    return self
end

function TCPayRiseEvent:writeStream(streamId, connection)
    streamWriteInt32(streamId, self.farmId)
    streamWriteInt32(streamId, self.workerId)
    streamWriteString(streamId, self.optionKey)
end

function TCPayRiseEvent:readStream(streamId, connection)
    self.farmId = streamReadInt32(streamId)
    self.workerId = streamReadInt32(streamId)
    self.optionKey = streamReadString(streamId)
    self:run(connection)
end

function TCPayRiseEvent:run(connection)
    if g_currentMission:getIsServer() then
        g_currentMission.TheContractor.PayReviews:requestRise(self.farmId, self.workerId, self.optionKey)
    end
end
