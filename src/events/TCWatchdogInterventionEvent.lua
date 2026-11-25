-- Broadcast-only: fired by TheContractorWatchdog:notify (021) whenever the
-- stuck-detection watchdog acts on an AI-dispatched job - either a
-- reset-and-retry intervention (NOTICE.RETRIED) or, once
-- MAX_RETRIES_PER_JOB is exhausted, a "needs your attention" escalation
-- (NOTICE.NEEDS_ATTENTION), or (184) a spreading job held after finishing
-- its course short twice (NOTICE.CANT_FINISH). Purely an "show an ingame notification" signal, same
-- shape as TCJobMissedEvent/TCDispatchFailedEvent - nothing here changes the
-- job's state (008). Needs its own event because the watchdog fires from a
-- server-side timer, not a direct per-client action, so every affected
-- client needs telling separately, including the host: g_server:
-- broadcastEvent doesn't loop back to the local client in single-player
-- (see src/events/README.md).

TCWatchdogInterventionEvent = {}
local TCWatchdogInterventionEvent_mt = Class(TCWatchdogInterventionEvent, Event)

InitEventClass(TCWatchdogInterventionEvent, "TCWatchdogInterventionEvent")

function TCWatchdogInterventionEvent.emptyNew()
    return Event.new(TCWatchdogInterventionEvent_mt)
end

-- notice: one of TheContractorWatchdog.NOTICE.
function TCWatchdogInterventionEvent.new(farmId, typeLabel, fieldId, notice)
    local self = TCWatchdogInterventionEvent.emptyNew()
    self.farmId = farmId
    self.typeLabel = typeLabel
    self.fieldId = fieldId
    self.notice = notice
    return self
end

function TCWatchdogInterventionEvent:writeStream(streamId, connection)
    streamWriteInt32(streamId, self.farmId)
    streamWriteString(streamId, self.typeLabel)
    streamWriteInt32(streamId, self.fieldId)
    streamWriteUInt8(streamId, self.notice)
end

function TCWatchdogInterventionEvent:readStream(streamId, connection)
    self.farmId = streamReadInt32(streamId)
    self.typeLabel = streamReadString(streamId)
    self.fieldId = streamReadInt32(streamId)
    self.notice = streamReadUInt8(streamId)
    self:run(connection)
end

function TCWatchdogInterventionEvent:run(connection)
    TCWatchdogInterventionEvent.showNotification(self.farmId, self.typeLabel, self.fieldId, self.notice)
end

-- Shared by run() (remote clients) and TheContractorWatchdog's own
-- server/host local notification - see this file's header comment on why
-- that can't just rely on the broadcast.
TCWatchdogInterventionEvent.TEXT_KEYS = {
    [TheContractorWatchdog.NOTICE.RETRIED] = "tc_watchdog_retriedNotification",
    [TheContractorWatchdog.NOTICE.NEEDS_ATTENTION] = "tc_watchdog_needsAttentionNotification",
    [TheContractorWatchdog.NOTICE.CANT_FINISH] = "tc_watchdog_cantFinishNotification",
}

function TCWatchdogInterventionEvent.showNotification(farmId, typeLabel, fieldId, notice)
    if farmId ~= g_currentMission:getFarmId() then
        return
    end

    local field = g_fieldManager:getFieldById(fieldId)
    local fieldLabel = field ~= nil and field:getName() or tostring(fieldId)

    local textKey = TCWatchdogInterventionEvent.TEXT_KEYS[notice]
    if textKey == nil then
        return
    end
    local notificationType = notice == TheContractorWatchdog.NOTICE.RETRIED and
        FSBaseMission.INGAME_NOTIFICATION_INFO or FSBaseMission.INGAME_NOTIFICATION_CRITICAL

    g_currentMission:addIngameNotification(notificationType,
        string.format(g_i18n:getText(textKey), g_i18n:getText("tc_jobType_" .. typeLabel), fieldLabel))
end
