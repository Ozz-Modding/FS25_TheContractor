-- Client asks to book one of its farm's workers on a certification course,
-- or a retake after a failed assessment, from the Staff tab (054), or on
-- a trade course (092, cert = TheContractorWorkshop.getCourseKey). The
-- server re-checks the worker, their readiness and the price
-- (TheContractorTraining:requestBooking); the result goes out as a
-- TCWorkerTrainingChangedEvent. See src/events/README.md for the general
-- event conventions.

TCBookTrainingEvent = {}
local TCBookTrainingEvent_mt = Class(TCBookTrainingEvent, Event)

InitEventClass(TCBookTrainingEvent, "TCBookTrainingEvent")

function TCBookTrainingEvent.emptyNew()
    return Event.new(TCBookTrainingEvent_mt)
end

function TCBookTrainingEvent.new(farmId, workerId, cert)
    local self = TCBookTrainingEvent.emptyNew()
    self.farmId = farmId
    self.workerId = workerId
    self.cert = cert
    return self
end

function TCBookTrainingEvent:writeStream(streamId, connection)
    streamWriteInt32(streamId, self.farmId)
    streamWriteInt32(streamId, self.workerId)
    streamWriteString(streamId, self.cert)
end

function TCBookTrainingEvent:readStream(streamId, connection)
    self.farmId = streamReadInt32(streamId)
    self.workerId = streamReadInt32(streamId)
    self.cert = streamReadString(streamId)
    self:run(connection)
end

function TCBookTrainingEvent:run(connection)
    if g_currentMission:getIsServer() then
        g_currentMission.TheContractor.Training:requestBooking(self.farmId, self.workerId, self.cert)
    end
end
