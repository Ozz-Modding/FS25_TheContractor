-- Broadcast-only: fired by TheContractorJobs:missJob once a job's deadline
-- has passed without it reaching `completed`. Purely an "show an ingame
-- notification" signal — TCJobStateChangedEvent (broadcast alongside this
-- one) is what actually syncs the job's state to `missed`. Needs its own
-- event because the transition is asynchronous (a server-side day-changed
-- tick, not a client action), so every affected client needs telling
-- separately, including the host: g_server:broadcastEvent doesn't loop back
-- to the local client in single-player (see src/events/README.md).
--
-- Reputation loss and worker/equipment release are TheContractorJobs:missJob's
-- concern (synced via their own events) — this event only owns the
-- notification.

TCJobMissedEvent = {}
local TCJobMissedEvent_mt = Class(TCJobMissedEvent, Event)

InitEventClass(TCJobMissedEvent, "TCJobMissedEvent")

function TCJobMissedEvent.emptyNew()
    return Event.new(TCJobMissedEvent_mt)
end

-- typeLabel: the job's TheContractorJob:getTypeLabel(), the suffix of its
-- tc_jobType_ key ("plant" for a sow job for a planted crop).
function TCJobMissedEvent.new(farmId, jobType, fieldId, typeLabel)
    local self = TCJobMissedEvent.emptyNew()
    self.farmId = farmId
    self.jobType = jobType
    self.fieldId = fieldId
    self.typeLabel = typeLabel
    return self
end

function TCJobMissedEvent:writeStream(streamId, connection)
    streamWriteInt32(streamId, self.farmId)
    streamWriteString(streamId, self.jobType)
    streamWriteInt32(streamId, self.fieldId)
    streamWriteString(streamId, self.typeLabel or self.jobType)
end

function TCJobMissedEvent:readStream(streamId, connection)
    self.farmId = streamReadInt32(streamId)
    self.jobType = streamReadString(streamId)
    self.fieldId = streamReadInt32(streamId)
    self.typeLabel = streamReadString(streamId)
    self:run(connection)
end

function TCJobMissedEvent:run(connection)
    TCJobMissedEvent.showNotification(self.farmId, self.jobType, self.fieldId, self.typeLabel)
end

-- Shared by run() (remote clients) and TheContractorJobs:missJob (the
-- server/host's own local notification — see this file's header comment on
-- why that can't just rely on the broadcast).
function TCJobMissedEvent.showNotification(farmId, jobType, fieldId, typeLabel)
    typeLabel = typeLabel or jobType
    if farmId ~= g_currentMission:getFarmId() then
        return
    end

    -- 141: nothing was riding on it (an auction no one went to), so it just
    -- ends, with a word that it's over.
    local quietDef = TheContractorJobGeneration.JOB_TYPES[jobType]
    if quietDef ~= nil and quietDef.noConsequences then
        local field = g_fieldManager:getFieldById(fieldId)
        g_currentMission:addIngameNotification(FSBaseMission.INGAME_NOTIFICATION_INFO,
            string.format(g_i18n:getText("tc_" .. jobType .. "_overNotification"),
                field ~= nil and field:getName() or tostring(fieldId)))
        return
    end

    -- 100: a workshop job has no field (fieldId 0).
    if fieldId == 0 then
        -- 116: a favour was the farmer's own machine.
        local jobDef = TheContractorJobGeneration.JOB_TYPES[jobType]
        if jobDef ~= nil and jobDef.favour then
            g_currentMission:addIngameNotification(FSBaseMission.INGAME_NOTIFICATION_CRITICAL,
                g_i18n:getText("tc_favour_missedNotification"))
            return
        end
        -- 101: a breakdown was out in a field, not in the repair zone.
        if jobType == TheContractorRepairContracts.JOB_TYPES.breakdown then
            g_currentMission:addIngameNotification(FSBaseMission.INGAME_NOTIFICATION_CRITICAL,
                g_i18n:getText("tc_breakdown_missedNotification"))
            return
        end
        g_currentMission:addIngameNotification(FSBaseMission.INGAME_NOTIFICATION_CRITICAL,
            string.format(g_i18n:getText("tc_repair_missedNotification"), g_i18n:getText("tc_jobType_" .. jobType)))
        return
    end

    -- 124, 126: a job in a farmer's yard; its field only said where it was.
    local jobDef = TheContractorJobGeneration.JOB_TYPES[jobType]
    if jobDef ~= nil and jobDef.yardDelivery then
        g_currentMission:addIngameNotification(FSBaseMission.INGAME_NOTIFICATION_CRITICAL,
            g_i18n:getText("tc_" .. jobType .. "_missedNotification"))
        return
    end

    local field = g_fieldManager:getFieldById(fieldId)
    local fieldLabel = field ~= nil and field:getName() or tostring(fieldId)

    g_currentMission:addIngameNotification(FSBaseMission.INGAME_NOTIFICATION_CRITICAL,
        string.format(g_i18n:getText("tc_job_missedNotification"), g_i18n:getText("tc_jobType_" .. typeLabel),
            fieldLabel))
end
