-- Broadcast-only: a hired worker has handed in their notice (039, from
-- TheContractorStaff:announceRetirement on a birthday roll) and will retire
-- at the start of retiresAtPeriod (a TCCalendar period index). See
-- src/events/README.md for the general event conventions.

TCWorkerRetirementAnnouncedEvent = {}
local TCWorkerRetirementAnnouncedEvent_mt = Class(TCWorkerRetirementAnnouncedEvent, Event)

InitEventClass(TCWorkerRetirementAnnouncedEvent, "TCWorkerRetirementAnnouncedEvent")

function TCWorkerRetirementAnnouncedEvent.emptyNew()
    return Event.new(TCWorkerRetirementAnnouncedEvent_mt)
end

function TCWorkerRetirementAnnouncedEvent.new(farmId, workerId, retiresAtPeriod)
    local self = TCWorkerRetirementAnnouncedEvent.emptyNew()
    self.farmId = farmId
    self.workerId = workerId
    self.retiresAtPeriod = retiresAtPeriod
    return self
end

function TCWorkerRetirementAnnouncedEvent:writeStream(streamId, connection)
    streamWriteInt32(streamId, self.farmId)
    streamWriteInt32(streamId, self.workerId)
    streamWriteInt32(streamId, self.retiresAtPeriod)
end

function TCWorkerRetirementAnnouncedEvent:readStream(streamId, connection)
    self.farmId = streamReadInt32(streamId)
    self.workerId = streamReadInt32(streamId)
    self.retiresAtPeriod = streamReadInt32(streamId)
    self:run(connection)
end

function TCWorkerRetirementAnnouncedEvent:run(connection)
    local staff = g_currentMission.TheContractor.Staff
    staff:applyRetirementAnnounced(self.farmId, self.workerId, self.retiresAtPeriod)
    TCWorkerRetirementAnnouncedEvent.showNotification(staff:getWorker(self.farmId, self.workerId))
end

-- Only the worker's own farm hears about it. Shared by run() (remote
-- clients) and TheContractorStaff:announceRetirement (the host's own copy,
-- since the broadcast doesn't loop back to it).
function TCWorkerRetirementAnnouncedEvent.showNotification(worker)
    if worker == nil or worker.farmId ~= g_currentMission:getFarmId() or worker.retiresAtPeriod == nil then
        return
    end

    g_currentMission:addIngameNotification(FSBaseMission.INGAME_NOTIFICATION_INFO,
        string.format(g_i18n:getText("tc_retirement_announced"), worker.name,
            TCCalendar.formatPeriodIndex(worker.retiresAtPeriod)))
end
