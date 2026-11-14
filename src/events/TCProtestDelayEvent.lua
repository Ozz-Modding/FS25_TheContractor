-- Broadcast-only: a protest (151) has added time to a job's trip out or
-- back (TheContractorProtest.TRAVEL_DELAY_MINUTES). Shown to the job's own
-- farm as a base-game notification, the job's place worked out on each
-- machine. Same "no SP loopback" shape as TCParkingNoticeEvent: the server
-- shows its own copy directly (see src/events/README.md).

TCProtestDelayEvent = {}
local TCProtestDelayEvent_mt = Class(TCProtestDelayEvent, Event)

InitEventClass(TCProtestDelayEvent, "TCProtestDelayEvent")

function TCProtestDelayEvent.emptyNew()
    return Event.new(TCProtestDelayEvent_mt)
end

function TCProtestDelayEvent.new(farmId, jobId, minutes, isReturn)
    local self = TCProtestDelayEvent.emptyNew()
    self.farmId = farmId
    self.jobId = jobId
    self.minutes = minutes
    self.isReturn = isReturn == true
    return self
end

function TCProtestDelayEvent:writeStream(streamId, connection)
    streamWriteInt32(streamId, self.farmId)
    streamWriteInt32(streamId, self.jobId)
    streamWriteInt32(streamId, self.minutes)
    streamWriteBool(streamId, self.isReturn)
end

function TCProtestDelayEvent:readStream(streamId, connection)
    self.farmId = streamReadInt32(streamId)
    self.jobId = streamReadInt32(streamId)
    self.minutes = streamReadInt32(streamId)
    self.isReturn = streamReadBool(streamId)
    self:run(connection)
end

function TCProtestDelayEvent:run(connection)
    TCProtestDelayEvent.showNotification(self.farmId, self.jobId, self.minutes, self.isReturn)
end

function TCProtestDelayEvent.showNotification(farmId, jobId, minutes, isReturn)
    if g_currentMission.addIngameNotification == nil or farmId ~= g_currentMission:getFarmId() then
        return
    end
    local tc = g_currentMission.TheContractor
    local job = tc ~= nil and tc.Jobs ~= nil and tc.Jobs:getJobById(jobId) or nil
    if job == nil then
        return
    end
    local textKey = isReturn and "tc_protest_delayReturn" or "tc_protest_delayOut"
    g_currentMission:addIngameNotification(FSBaseMission.INGAME_NOTIFICATION_INFO,
        string.format(g_i18n:getText(textKey), job:getLocationText(), minutes))
end
