-- Broadcast-only: tells a farm something about parking (062) - machines
-- waiting for a free parking space, a shop with no room, an allocation
-- refused for want of one. textKey is formatted with arg (machine names,
-- finished on the server) on each client. Same "no SP loopback" shape as
-- TCDispatchFailedEvent: the server shows its own copy directly (see
-- src/events/README.md).

TCParkingNoticeEvent = {}
local TCParkingNoticeEvent_mt = Class(TCParkingNoticeEvent, Event)

InitEventClass(TCParkingNoticeEvent, "TCParkingNoticeEvent")

function TCParkingNoticeEvent.emptyNew()
    return Event.new(TCParkingNoticeEvent_mt)
end

function TCParkingNoticeEvent.new(farmId, textKey, arg)
    local self = TCParkingNoticeEvent.emptyNew()
    self.farmId = farmId
    self.textKey = textKey
    self.arg = arg
    return self
end

function TCParkingNoticeEvent:writeStream(streamId, connection)
    streamWriteInt32(streamId, self.farmId)
    streamWriteString(streamId, self.textKey)
    streamWriteString(streamId, self.arg)
end

function TCParkingNoticeEvent:readStream(streamId, connection)
    self.farmId = streamReadInt32(streamId)
    self.textKey = streamReadString(streamId)
    self.arg = streamReadString(streamId)
    self:run(connection)
end

function TCParkingNoticeEvent:run(connection)
    TCParkingNoticeEvent.showNotification(self.farmId, self.textKey, self.arg)
end

function TCParkingNoticeEvent.showNotification(farmId, textKey, arg)
    if farmId ~= g_currentMission:getFarmId() then
        return
    end

    g_currentMission:addIngameNotification(FSBaseMission.INGAME_NOTIFICATION_CRITICAL,
        string.format(g_i18n:getText(textKey), arg))
end
