-- Broadcast-only: the server flips a hired worker's status (via
-- TheContractorStaff:setWorkerStatus — first triggered by allocation, 018,
-- flipping idle -> assigned; 022/023 flip it back, 031 to/from sick) and
-- sends just the changed field to every client, rather than a full worker
-- snapshot — status is the only thing this ever moves on its own. See
-- src/events/README.md for the general event conventions.

TCWorkerStatusChangedEvent = {}
local TCWorkerStatusChangedEvent_mt = Class(TCWorkerStatusChangedEvent, Event)

InitEventClass(TCWorkerStatusChangedEvent, "TCWorkerStatusChangedEvent")

function TCWorkerStatusChangedEvent.emptyNew()
    return Event.new(TCWorkerStatusChangedEvent_mt)
end

function TCWorkerStatusChangedEvent.new(farmId, workerId, status)
    local self = TCWorkerStatusChangedEvent.emptyNew()
    self.farmId = farmId
    self.workerId = workerId
    self.status = status
    return self
end

function TCWorkerStatusChangedEvent:writeStream(streamId, connection)
    streamWriteInt32(streamId, self.farmId)
    streamWriteInt32(streamId, self.workerId)
    streamWriteString(streamId, self.status)
end

function TCWorkerStatusChangedEvent:readStream(streamId, connection)
    self.farmId = streamReadInt32(streamId)
    self.workerId = streamReadInt32(streamId)
    self.status = streamReadString(streamId)
    self:run(connection)
end

function TCWorkerStatusChangedEvent:run(connection)
    local staff = g_currentMission.TheContractor.Staff
    local oldStatus = staff:applyWorkerStatusChanged(self.farmId, self.workerId, self.status)
    TCWorkerStatusChangedEvent.showNotification(staff:getWorker(self.farmId, self.workerId), oldStatus, self.status)
end

-- 031: tells the worker's own farm when someone goes off sick or comes
-- back (and 040, on holiday or back). Other status changes are already visible through the job they
-- belong to, so they stay silent. Shared by run() (remote clients) and
-- TheContractorStaff:setWorkerStatus (the host's own copy, since the
-- broadcast doesn't loop back to it).
function TCWorkerStatusChangedEvent.showNotification(worker, oldStatus, newStatus)
    if worker == nil or worker.farmId ~= g_currentMission:getFarmId() or oldStatus == newStatus then
        return
    end

    -- 040: going on/back from holiday. Checked first, because a sick worker
    -- can go straight onto a holiday - that isn't "back at work".
    local holiday = TheContractorWorker.STATUS.HOLIDAY
    if newStatus == holiday then
        local text = worker:hasHolidayBooked() and
            string.format(g_i18n:getText("tc_holiday_started"), worker.name,
                TCCalendar.formatDay(worker:getHolidayEndDay())) or
            string.format(g_i18n:getText("tc_holiday_startedNoDate"), worker.name)
        g_currentMission:addIngameNotification(FSBaseMission.INGAME_NOTIFICATION_INFO, text)
        return
    elseif oldStatus == holiday then
        g_currentMission:addIngameNotification(FSBaseMission.INGAME_NOTIFICATION_OK,
            string.format(g_i18n:getText("tc_holiday_ended"), worker.name))
        return
    end

    local sick = TheContractorWorker.STATUS.SICK
    if newStatus == sick then
        g_currentMission:addIngameNotification(FSBaseMission.INGAME_NOTIFICATION_CRITICAL,
            string.format(g_i18n:getText("tc_sickness_offSick"), worker.name))
    elseif oldStatus == sick then
        g_currentMission:addIngameNotification(FSBaseMission.INGAME_NOTIFICATION_OK,
            string.format(g_i18n:getText("tc_sickness_recovered"), worker.name))
    end
end
