-- Broadcast-only: a hired worker's training state changed on the server
-- (054, TheContractorTraining) - a course booked, a day attended or slid,
-- an assessment passed or failed, a request declined. Sends the whole
-- visible state (TheContractorTraining.writeState) rather than a diff, plus
-- what to tell the farm about it. See src/events/README.md for the general
-- event conventions.

TCWorkerTrainingChangedEvent = {}
local TCWorkerTrainingChangedEvent_mt = Class(TCWorkerTrainingChangedEvent, Event)

InitEventClass(TCWorkerTrainingChangedEvent, "TCWorkerTrainingChangedEvent")

function TCWorkerTrainingChangedEvent.emptyNew()
    return Event.new(TCWorkerTrainingChangedEvent_mt)
end

-- cert and amount are only for the notification ("" and 0 when unused).
function TCWorkerTrainingChangedEvent.new(worker, notify, cert, amount)
    local self = TCWorkerTrainingChangedEvent.emptyNew()
    self.worker = worker
    self.farmId = worker.farmId
    self.workerId = worker.id
    self.notify = notify
    self.cert = cert
    self.amount = amount
    return self
end

function TCWorkerTrainingChangedEvent:writeStream(streamId, connection)
    streamWriteInt32(streamId, self.farmId)
    streamWriteInt32(streamId, self.workerId)
    TheContractorTraining.writeState(streamId, self.worker)
    streamWriteUInt8(streamId, self.notify)
    streamWriteString(streamId, self.cert)
    streamWriteFloat32(streamId, self.amount)
end

function TCWorkerTrainingChangedEvent:readStream(streamId, connection)
    self.farmId = streamReadInt32(streamId)
    self.workerId = streamReadInt32(streamId)
    self.state = TheContractorTraining.readState(streamId)
    self.notify = streamReadUInt8(streamId)
    self.cert = streamReadString(streamId)
    self.amount = streamReadFloat32(streamId)
    self:run(connection)
end

function TCWorkerTrainingChangedEvent:run(connection)
    local worker = g_currentMission.TheContractor.Staff:getWorker(self.farmId, self.workerId)
    if worker == nil then
        return
    end

    TheContractorTraining.applyState(worker, self.state)
    TCWorkerTrainingChangedEvent.showNotification(worker, self.notify, self.cert, self.amount)
end

-- Only the worker's own farm hears about it. Shared by run() (remote
-- clients) and TheContractorTraining:sendTrainingChanged (the host's own
-- copy, since the broadcast doesn't loop back to it).
function TCWorkerTrainingChangedEvent.showNotification(worker, notify, cert, amount)
    if worker == nil or worker.farmId ~= g_currentMission:getFarmId() or
            notify == TheContractorTraining.NOTIFY.NONE or TheContractorTraining.getDefinition(cert) == nil then
        return
    end

    local certName = TheContractorTraining.getCertName(cert)
    local NOTIFY = TheContractorTraining.NOTIFY

    if notify == NOTIFY.BOOKED and worker:hasTrainingBooked() then
        local courseDates = TheContractorTraining.formatCourseDates(worker)
        local text
        if courseDates ~= nil then
            text = string.format(g_i18n:getText("tc_training_booked"), worker.name, certName, courseDates,
                TCCalendar.formatDay(worker.assessmentDay))
        else
            text = string.format(g_i18n:getText("tc_training_bookedRetake"), worker.name, certName,
                TCCalendar.formatDay(worker.assessmentDay))
        end
        g_currentMission:addIngameNotification(FSBaseMission.INGAME_NOTIFICATION_INFO, text)
    elseif notify == NOTIFY.PASSED then
        g_currentMission:addIngameNotification(FSBaseMission.INGAME_NOTIFICATION_OK,
            string.format(g_i18n:getText("tc_training_passed"), worker.name, certName))
    elseif notify == NOTIFY.FAILED then
        g_currentMission:addIngameNotification(FSBaseMission.INGAME_NOTIFICATION_CRITICAL,
            string.format(g_i18n:getText("tc_training_failed"), worker.name, certName))
    elseif notify == NOTIFY.CANNOT_AFFORD then
        g_currentMission:addIngameNotification(FSBaseMission.INGAME_NOTIFICATION_CRITICAL,
            string.format(g_i18n:getText("tc_training_cannotAffordNotice"), worker.name, certName,
                TheContractorTraining.formatPrice(amount)))
    end
end
