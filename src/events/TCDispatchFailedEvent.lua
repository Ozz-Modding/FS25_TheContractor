-- Broadcast-only: fired by TheContractorDispatch:notifyDispatchFailed when
-- an allocated job's AI Helper dispatch (020) couldn't actually start —
-- equipment not ready (implement never attached, tractor no longer free),
-- validation failure, or the base game's own startability gating (permission/
-- in-use/hire-limit). Purely an "show an ingame notification" signal, same
-- shape as TCJobMissedEvent — the job itself stays `allocated`, nothing here
-- changes its state. Needs its own event because dispatch is server-
-- initiated (a consequence of allocation, not a direct per-client action),
-- so every affected client needs telling separately, including the host:
-- g_server:broadcastEvent doesn't loop back to the local client in
-- single-player (see src/events/README.md).

TCDispatchFailedEvent = {}
local TCDispatchFailedEvent_mt = Class(TCDispatchFailedEvent, Event)

InitEventClass(TCDispatchFailedEvent, "TCDispatchFailedEvent")

function TCDispatchFailedEvent.emptyNew()
    return Event.new(TCDispatchFailedEvent_mt)
end

function TCDispatchFailedEvent.new(farmId, jobType, fieldId, reasonText)
    local self = TCDispatchFailedEvent.emptyNew()
    self.farmId = farmId
    self.jobType = jobType
    self.fieldId = fieldId
    self.reasonText = reasonText
    return self
end

function TCDispatchFailedEvent:writeStream(streamId, connection)
    streamWriteInt32(streamId, self.farmId)
    streamWriteString(streamId, self.jobType)
    streamWriteInt32(streamId, self.fieldId)
    streamWriteString(streamId, self.reasonText)
end

function TCDispatchFailedEvent:readStream(streamId, connection)
    self.farmId = streamReadInt32(streamId)
    self.jobType = streamReadString(streamId)
    self.fieldId = streamReadInt32(streamId)
    self.reasonText = streamReadString(streamId)
    self:run(connection)
end

function TCDispatchFailedEvent:run(connection)
    TCDispatchFailedEvent.showNotification(self.farmId, self.jobType, self.fieldId, self.reasonText)
end

-- Shared by run() (remote clients) and TheContractorDispatch's own
-- server/host local notification — see this file's header comment on why
-- that can't just rely on the broadcast.
function TCDispatchFailedEvent.showNotification(farmId, jobType, fieldId, reasonText)
    if farmId ~= g_currentMission:getFarmId() then
        return
    end

    local field = g_fieldManager:getFieldById(fieldId)
    local fieldLabel = field ~= nil and field:getName() or tostring(fieldId)

    g_currentMission:addIngameNotification(FSBaseMission.INGAME_NOTIFICATION_CRITICAL,
        string.format(g_i18n:getText("tc_dispatch_failedNotification"), g_i18n:getText("tc_jobType_" .. jobType),
            fieldLabel, reasonText))
end
