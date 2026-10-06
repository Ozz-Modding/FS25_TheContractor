-- Broadcast-only: a hired worker has handed in their notice and will leave
-- at the start of leavesAtPeriod (a TCCalendar period index) - retiring
-- (039, from a birthday roll) or, with isQuitting, quitting (056, from low
-- morale). See TheContractorStaff:announceLeaving, and src/events/README.md
-- for the general event conventions.

TCWorkerRetirementAnnouncedEvent = {}
local TCWorkerRetirementAnnouncedEvent_mt = Class(TCWorkerRetirementAnnouncedEvent, Event)

InitEventClass(TCWorkerRetirementAnnouncedEvent, "TCWorkerRetirementAnnouncedEvent")

function TCWorkerRetirementAnnouncedEvent.emptyNew()
    return Event.new(TCWorkerRetirementAnnouncedEvent_mt)
end

function TCWorkerRetirementAnnouncedEvent.new(farmId, workerId, leavesAtPeriod, isQuitting)
    local self = TCWorkerRetirementAnnouncedEvent.emptyNew()
    self.farmId = farmId
    self.workerId = workerId
    self.leavesAtPeriod = leavesAtPeriod
    self.isQuitting = isQuitting
    return self
end

function TCWorkerRetirementAnnouncedEvent:writeStream(streamId, connection)
    streamWriteInt32(streamId, self.farmId)
    streamWriteInt32(streamId, self.workerId)
    streamWriteInt32(streamId, self.leavesAtPeriod)
    streamWriteBool(streamId, self.isQuitting)
end

function TCWorkerRetirementAnnouncedEvent:readStream(streamId, connection)
    self.farmId = streamReadInt32(streamId)
    self.workerId = streamReadInt32(streamId)
    self.leavesAtPeriod = streamReadInt32(streamId)
    self.isQuitting = streamReadBool(streamId)
    self:run(connection)
end

function TCWorkerRetirementAnnouncedEvent:run(connection)
    local staff = g_currentMission.TheContractor.Staff
    staff:applyLeavingAnnounced(self.farmId, self.workerId, self.leavesAtPeriod, self.isQuitting)
    TCWorkerRetirementAnnouncedEvent.showNotification(staff:getWorker(self.farmId, self.workerId))
end

-- Only the worker's own farm hears about it. Shared by run() (remote
-- clients) and TheContractorStaff:announceLeaving (the host's own copy,
-- since the broadcast doesn't loop back to it).
function TCWorkerRetirementAnnouncedEvent.showNotification(worker)
    if worker == nil or worker.farmId ~= g_currentMission:getFarmId() or worker.leavesAtPeriod == nil then
        return
    end

    local key = worker.isQuitting and "tc_morale_quitAnnounced" or "tc_retirement_announced"
    g_currentMission:addIngameNotification(worker.isQuitting and FSBaseMission.INGAME_NOTIFICATION_CRITICAL or
        FSBaseMission.INGAME_NOTIFICATION_INFO,
        string.format(g_i18n:getText(key), worker.name, TCCalendar.formatPeriodIndex(worker.leavesAtPeriod)))
end
