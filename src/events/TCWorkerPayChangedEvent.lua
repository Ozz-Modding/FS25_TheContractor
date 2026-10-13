-- Broadcast-only: a hired worker's pay or expected pay changed on the
-- server (058, TheContractorPayReviews) - a rise, or a pay review's new
-- expectation. Sends the salary and the rest of the visible pay state
-- (TheContractorPayReviews.writeState), plus what to tell the farm about
-- it. See src/events/README.md for the general event conventions.

TCWorkerPayChangedEvent = {}
local TCWorkerPayChangedEvent_mt = Class(TCWorkerPayChangedEvent, Event)

InitEventClass(TCWorkerPayChangedEvent, "TCWorkerPayChangedEvent")

function TCWorkerPayChangedEvent.emptyNew()
    return Event.new(TCWorkerPayChangedEvent_mt)
end

-- notify (TheContractorPayReviews.NOTIFY) is only for the notification.
function TCWorkerPayChangedEvent.new(worker, notify)
    local self = TCWorkerPayChangedEvent.emptyNew()
    self.worker = worker
    self.notify = notify
    return self
end

function TCWorkerPayChangedEvent:writeStream(streamId, connection)
    streamWriteInt32(streamId, self.worker.farmId)
    streamWriteInt32(streamId, self.worker.id)
    streamWriteFloat32(streamId, self.worker.salary)
    TheContractorPayReviews.writeState(streamId, self.worker)
    streamWriteUInt8(streamId, self.notify)
end

function TCWorkerPayChangedEvent:readStream(streamId, connection)
    self.farmId = streamReadInt32(streamId)
    self.workerId = streamReadInt32(streamId)
    self.salary = streamReadFloat32(streamId)
    self.expectedSalary = TheContractorPayReviews.readState(streamId)
    self.notify = streamReadUInt8(streamId)
    self:run(connection)
end

function TCWorkerPayChangedEvent:run(connection)
    local worker = g_currentMission.TheContractor.Staff:getWorker(self.farmId, self.workerId)
    if worker == nil then
        return
    end

    worker.salary = self.salary
    worker.expectedSalary = self.expectedSalary
    TCWorkerPayChangedEvent.showNotification(worker, self.notify)
end

-- Only the worker's own farm hears about it. Shared by run() (remote
-- clients) and TheContractorPayReviews:sendPayChanged (the host's own copy,
-- since the broadcast doesn't loop back to it).
function TCWorkerPayChangedEvent.showNotification(worker, notify)
    if worker.farmId ~= g_currentMission:getFarmId() then
        return
    end

    if notify == TheContractorPayReviews.NOTIFY.RISE then
        g_currentMission:addIngameNotification(FSBaseMission.INGAME_NOTIFICATION_OK,
            string.format(g_i18n:getText("tc_pay_riseNotice"), worker.name,
                g_i18n:formatMoney(TheContractorStaff.scalePay(worker.salary), 0, true, true)))
    end
end
