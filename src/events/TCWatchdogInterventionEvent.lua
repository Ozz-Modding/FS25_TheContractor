-- Broadcast-only: fired by TheContractorWatchdog:notify (021) whenever the
-- stuck-detection watchdog acts on an AI-dispatched job - either a
-- reset-and-retry intervention (isEscalation false) or, once
-- MAX_RETRIES_PER_JOB is exhausted, a "needs your attention" escalation
-- (isEscalation true). Purely an "show an ingame notification" signal, same
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

function TCWatchdogInterventionEvent.new(farmId, typeLabel, fieldId, isEscalation)
    local self = TCWatchdogInterventionEvent.emptyNew()
    self.farmId = farmId
    self.typeLabel = typeLabel
    self.fieldId = fieldId
    self.isEscalation = isEscalation
    return self
end

function TCWatchdogInterventionEvent:writeStream(streamId, connection)
    streamWriteInt32(streamId, self.farmId)
    streamWriteString(streamId, self.typeLabel)
    streamWriteInt32(streamId, self.fieldId)
    streamWriteBool(streamId, self.isEscalation)
end

function TCWatchdogInterventionEvent:readStream(streamId, connection)
    self.farmId = streamReadInt32(streamId)
    self.typeLabel = streamReadString(streamId)
    self.fieldId = streamReadInt32(streamId)
    self.isEscalation = streamReadBool(streamId)
    self:run(connection)
end

function TCWatchdogInterventionEvent:run(connection)
    TCWatchdogInterventionEvent.showNotification(self.farmId, self.typeLabel, self.fieldId, self.isEscalation)
end

-- Shared by run() (remote clients) and TheContractorWatchdog's own
-- server/host local notification - see this file's header comment on why
-- that can't just rely on the broadcast.
function TCWatchdogInterventionEvent.showNotification(farmId, typeLabel, fieldId, isEscalation)
    if farmId ~= g_currentMission:getFarmId() then
        return
    end

    local field = g_fieldManager:getFieldById(fieldId)
    local fieldLabel = field ~= nil and field:getName() or tostring(fieldId)

    local textKey = isEscalation and "tc_watchdog_needsAttentionNotification" or "tc_watchdog_retriedNotification"
    local notificationType = isEscalation and FSBaseMission.INGAME_NOTIFICATION_CRITICAL or
        FSBaseMission.INGAME_NOTIFICATION_INFO

    g_currentMission:addIngameNotification(notificationType,
        string.format(g_i18n:getText(textKey), g_i18n:getText("tc_jobType_" .. typeLabel), fieldLabel))
end
