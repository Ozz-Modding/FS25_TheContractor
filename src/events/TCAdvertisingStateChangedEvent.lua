-- Server-authoritative broadcast of one of a farm's advertising campaigns
-- changing — sent both after a purchase (TCPurchaseAdvertisingEvent: a new
-- or extended campaign) and after a daily expiry check
-- (TheContractorAdvertising:onDayChanged), same split as Reputation's
-- addReputation/TCReputationChangedEvent: advertising state changes never
-- originate from a direct player action reaching clients directly, always
-- from server-side business logic. expiresOnMonth nil means the campaign
-- has ended.

TCAdvertisingStateChangedEvent = {}
local TCAdvertisingStateChangedEvent_mt = Class(TCAdvertisingStateChangedEvent, Event)

InitEventClass(TCAdvertisingStateChangedEvent, "TCAdvertisingStateChangedEvent")

function TCAdvertisingStateChangedEvent.emptyNew()
    return Event.new(TCAdvertisingStateChangedEvent_mt)
end

function TCAdvertisingStateChangedEvent.new(farmId, levelKey, expiresOnMonth)
    local self = TCAdvertisingStateChangedEvent.emptyNew()
    self.farmId = farmId
    self.levelKey = levelKey
    self.expiresOnMonth = expiresOnMonth
    return self
end

function TCAdvertisingStateChangedEvent:writeStream(streamId, connection)
    streamWriteInt32(streamId, self.farmId)
    streamWriteString(streamId, self.levelKey)
    streamWriteBool(streamId, self.expiresOnMonth ~= nil)
    if self.expiresOnMonth ~= nil then
        streamWriteInt32(streamId, self.expiresOnMonth)
    end
end

function TCAdvertisingStateChangedEvent:readStream(streamId, connection)
    self.farmId = streamReadInt32(streamId)
    self.levelKey = streamReadString(streamId)
    if streamReadBool(streamId) then
        self.expiresOnMonth = streamReadInt32(streamId)
    end
    self:run(connection)
end

function TCAdvertisingStateChangedEvent:run(connection)
    g_currentMission.TheContractor.Advertising:applyAdvertisingState(self.farmId, self.levelKey, self.expiresOnMonth)
end
