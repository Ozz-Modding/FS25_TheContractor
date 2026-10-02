-- Broadcast-only: the server stopped or refused an AutoDrive/Courseplay
-- start (037 - no staff driver while the farm has a company, contractor
-- equipment, or a driver assignment that no longer held), or couldn't
-- assign the driver a client picked. Shown to the vehicle's own farm only.
-- See src/events/README.md for the general event conventions.

TCDriverNoticeEvent = {}
local TCDriverNoticeEvent_mt = Class(TCDriverNoticeEvent, Event)

InitEventClass(TCDriverNoticeEvent, "TCDriverNoticeEvent")

function TCDriverNoticeEvent.emptyNew()
    return Event.new(TCDriverNoticeEvent_mt)
end

function TCDriverNoticeEvent.new(farmId, textKey, vehicleName)
    local self = TCDriverNoticeEvent.emptyNew()
    self.farmId = farmId
    self.textKey = textKey
    self.vehicleName = vehicleName
    return self
end

function TCDriverNoticeEvent:writeStream(streamId, connection)
    streamWriteInt32(streamId, self.farmId)
    streamWriteString(streamId, self.textKey)
    streamWriteString(streamId, self.vehicleName)
end

function TCDriverNoticeEvent:readStream(streamId, connection)
    self.farmId = streamReadInt32(streamId)
    self.textKey = streamReadString(streamId)
    self.vehicleName = streamReadString(streamId)
    self:run(connection)
end

function TCDriverNoticeEvent:run(connection)
    TCDriverNoticeEvent.showNotification(self.farmId, self.textKey, self.vehicleName)
end

-- Shared by run() (remote clients) and TheContractorDrivers:notify (the
-- host's own copy, since the broadcast doesn't loop back to it). Every
-- tc_drivers_* notice text takes the vehicle name as its one %s.
function TCDriverNoticeEvent.showNotification(farmId, textKey, vehicleName)
    if farmId ~= g_currentMission:getFarmId() then
        return
    end

    g_currentMission:addIngameNotification(FSBaseMission.INGAME_NOTIFICATION_CRITICAL,
        string.format(g_i18n:getText(textKey), vehicleName))
end
