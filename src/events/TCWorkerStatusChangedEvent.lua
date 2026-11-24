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

-- sickDays/isInjury: going off sick, how long for and whether it's a
-- workplace injury (104), for the notification only (0/false otherwise).
function TCWorkerStatusChangedEvent.new(farmId, workerId, status, sickDays, isInjury)
    local self = TCWorkerStatusChangedEvent.emptyNew()
    self.farmId = farmId
    self.workerId = workerId
    self.status = status
    self.sickDays = sickDays or 0
    self.isInjury = isInjury == true
    return self
end

function TCWorkerStatusChangedEvent:writeStream(streamId, connection)
    streamWriteInt32(streamId, self.farmId)
    streamWriteInt32(streamId, self.workerId)
    streamWriteString(streamId, self.status)
    streamWriteUInt8(streamId, math.max(0, math.min(255, self.sickDays)))
    streamWriteBool(streamId, self.isInjury)
end

function TCWorkerStatusChangedEvent:readStream(streamId, connection)
    self.farmId = streamReadInt32(streamId)
    self.workerId = streamReadInt32(streamId)
    self.status = streamReadString(streamId)
    self.sickDays = streamReadUInt8(streamId)
    self.isInjury = streamReadBool(streamId)
    self:run(connection)
end

function TCWorkerStatusChangedEvent:run(connection)
    local staff = g_currentMission.TheContractor.Staff
    local oldStatus = staff:applyWorkerStatusChanged(self.farmId, self.workerId, self.status)
    TCWorkerStatusChangedEvent.showNotification(staff:getWorker(self.farmId, self.workerId), oldStatus, self.status,
        self.sickDays, self.isInjury)
end

-- 172: whether a worker's their farm's entrant in the ploughing (170).
function TCWorkerStatusChangedEvent.isPloughingEntrant(worker)
    local tc = g_currentMission.TheContractor
    local showWorker = tc ~= nil and tc.ShowWorker or nil
    local entry = showWorker ~= nil and showWorker:getEntry(worker.farmId) or nil
    return entry ~= nil and entry.workerId == worker.id
end

-- 031: tells the worker's own farm when someone goes off sick or comes
-- back (and 040, on holiday or back). Other status changes are already visible through the job they
-- belong to, so they stay silent. Shared by run() (remote clients) and
-- TheContractorStaff:setWorkerStatus (the host's own copy, since the
-- broadcast doesn't loop back to it).
function TCWorkerStatusChangedEvent.showNotification(worker, oldStatus, newStatus, sickDays, isInjury)
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

    -- 170: off to the show for the ploughing match, and back.
    local show = TheContractorWorker.STATUS.SHOW
    -- 172: the staff's day off is silent (the farm said yes, and the Staff
    -- tab says where they are): only 170's entrant is told.
    if (newStatus == show or oldStatus == show) and not TCWorkerStatusChangedEvent.isPloughingEntrant(worker) then
        return
    end
    if newStatus == show then
        g_currentMission:addIngameNotification(FSBaseMission.INGAME_NOTIFICATION_INFO,
            string.format(g_i18n:getText("tc_showWorker_atShowNotification"), worker.name))
        return
    elseif oldStatus == show then
        g_currentMission:addIngameNotification(FSBaseMission.INGAME_NOTIFICATION_INFO,
            string.format(g_i18n:getText("tc_showWorker_backNotification"), worker.name))
        return
    end

    -- 054: off to the course or the assessment, and back from the course.
    -- Back from the assessment is the pass/fail notification instead
    -- (TCWorkerTrainingChangedEvent), which arrives first.
    local training = TheContractorWorker.STATUS.TRAINING
    if newStatus == training and worker:hasTrainingBooked() then
        local certName = TheContractorTraining.getCourseName(worker, worker.trainingCert)
        local key = worker.courseDaysLeft > 0 and "tc_training_started" or "tc_training_assessmentStarted"
        g_currentMission:addIngameNotification(FSBaseMission.INGAME_NOTIFICATION_INFO,
            string.format(g_i18n:getText(key), worker.name, certName))
        return
    elseif oldStatus == training then
        -- 092: a trade course has no assessment to come back for.
        if worker:hasTrainingBooked() and worker.assessmentDay ~= nil then
            g_currentMission:addIngameNotification(FSBaseMission.INGAME_NOTIFICATION_INFO,
                string.format(g_i18n:getText("tc_training_courseDone"), worker.name,
                    TheContractorTraining.getCertName(worker.trainingCert), TCCalendar.formatDay(worker.assessmentDay)))
        end
        -- Falls through: they may have come back off sick.
    end

    local sick = TheContractorWorker.STATUS.SICK
    if newStatus == sick then
        g_currentMission:addIngameNotification(FSBaseMission.INGAME_NOTIFICATION_CRITICAL,
            TCWorkerStatusChangedEvent.getOffSickText(worker.name, sickDays, isInjury))
    elseif oldStatus == sick then
        g_currentMission:addIngameNotification(FSBaseMission.INGAME_NOTIFICATION_OK,
            string.format(g_i18n:getText("tc_sickness_recovered"), worker.name))
    end
end

-- "Amy has called in sick and can't take jobs today" / "for 3 days", or
-- "has been hurt at work" for an injury. Today counts as the first day.
function TCWorkerStatusChangedEvent.getOffSickText(name, sickDays, isInjury)
    local prefix = isInjury and "tc_injury_off" or "tc_sickness_off"
    if sickDays == nil or sickDays <= 0 then
        return string.format(g_i18n:getText(prefix .. "Sick"), name)
    elseif sickDays == 1 then
        return string.format(g_i18n:getText(prefix .. "Today"), name)
    end
    return string.format(g_i18n:getText(prefix .. "Days"), name, sickDays)
end
