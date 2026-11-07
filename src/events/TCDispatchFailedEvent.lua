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
--
-- The reason travels as its l10n key's place in REASON_KEYS, with plain
-- string args (machine names), and is put into words on each machine, in
-- its own language. Index 0 is a reason with no key: its one arg is the text
-- as it came (another mod's AI validation, say).

TCDispatchFailedEvent = {}
local TCDispatchFailedEvent_mt = Class(TCDispatchFailedEvent, Event)

InitEventClass(TCDispatchFailedEvent, "TCDispatchFailedEvent")

-- Append only: the index is what's sent.
TCDispatchFailedEvent.REASON_KEYS = {
    "tc_dispatch_noVehicleReady",
    -- args: the implements, the vehicle.
    "tc_dispatch_noAttachPoint",
    -- Vanilla's AI job validation (AIParameterVehicle:validate).
    "ai_validationErrorNoVehicle",
    "ai_validationErrorVehicleDoesNotExistAnymore",
    "ai_validationErrorVehicleDoesNotSupportAI",
    -- And its startability (AIJobFieldWork.getIsStartErrorText).
    "ai_startStateLimitReached",
    "ai_startStateVehicleDeleted",
    "ai_startStateNoPermission",
    "ai_startStateVehicleInUse",
}

TCDispatchFailedEvent.REASON_INDEX = {}
for index, key in ipairs(TCDispatchFailedEvent.REASON_KEYS) do
    TCDispatchFailedEvent.REASON_INDEX[key] = index
end

function TCDispatchFailedEvent.emptyNew()
    return Event.new(TCDispatchFailedEvent_mt)
end

-- reasonKey: one of REASON_KEYS, or nil with the text as args[1].
function TCDispatchFailedEvent.new(farmId, typeLabel, fieldId, reasonKey, reasonArgs)
    local self = TCDispatchFailedEvent.emptyNew()
    self.farmId = farmId
    self.typeLabel = typeLabel
    self.fieldId = fieldId
    self.reasonKey = reasonKey
    self.reasonArgs = reasonArgs or {}
    return self
end

function TCDispatchFailedEvent:writeStream(streamId, connection)
    streamWriteInt32(streamId, self.farmId)
    streamWriteString(streamId, self.typeLabel)
    streamWriteInt32(streamId, self.fieldId)
    streamWriteUInt8(streamId, TCDispatchFailedEvent.REASON_INDEX[self.reasonKey] or 0)
    streamWriteUInt8(streamId, #self.reasonArgs)
    for _, arg in ipairs(self.reasonArgs) do
        streamWriteString(streamId, tostring(arg))
    end
end

function TCDispatchFailedEvent:readStream(streamId, connection)
    self.farmId = streamReadInt32(streamId)
    self.typeLabel = streamReadString(streamId)
    self.fieldId = streamReadInt32(streamId)
    self.reasonKey = TCDispatchFailedEvent.REASON_KEYS[streamReadUInt8(streamId)]
    self.reasonArgs = {}
    for i = 1, streamReadUInt8(streamId) do
        self.reasonArgs[i] = streamReadString(streamId)
    end
    self:run(connection)
end

function TCDispatchFailedEvent:run(connection)
    TCDispatchFailedEvent.showNotification(self.farmId, self.typeLabel, self.fieldId, self.reasonKey, self.reasonArgs)
end

-- The reason in this machine's language.
function TCDispatchFailedEvent.getReasonText(reasonKey, reasonArgs)
    if reasonKey == nil then
        return reasonArgs[1] or ""
    end
    return string.format(g_i18n:getText(reasonKey), unpack(reasonArgs))
end

-- The REASON_KEYS key whose text this machine renders as text, or nil:
-- vanilla's validation only gives the words.
function TCDispatchFailedEvent.findReasonKey(text)
    for _, key in ipairs(TCDispatchFailedEvent.REASON_KEYS) do
        if g_i18n:getText(key) == text then
            return key
        end
    end
    return nil
end

function TCDispatchFailedEvent.showNotification(farmId, typeLabel, fieldId, reasonKey, reasonArgs)
    if farmId ~= g_currentMission:getFarmId() then
        return
    end
    local field = g_fieldManager:getFieldById(fieldId)
    local fieldLabel = field ~= nil and field:getName() or tostring(fieldId)
    g_currentMission:addIngameNotification(FSBaseMission.INGAME_NOTIFICATION_CRITICAL,
        string.format(g_i18n:getText("tc_dispatch_failedNotification"), g_i18n:getText("tc_jobType_" .. typeLabel),
            fieldLabel, TCDispatchFailedEvent.getReasonText(reasonKey, reasonArgs or {})))
end
