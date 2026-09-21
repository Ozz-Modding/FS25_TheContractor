-- Server-authoritative broadcast of a farm's new advertising state — sent
-- both after a purchase (TCPurchaseAdvertisingEvent) and after a daily
-- expiry check (TheContractorAdvertising:onDayChanged), same split as
-- Reputation's addReputation/TCReputationChangedEvent: advertising state
-- changes never originate from a direct player action reaching clients
-- directly, always from server-side business logic. levelKey/expiresOnDay
-- both nil means "no active advertising."

TCAdvertisingStateChangedEvent = {}
local TCAdvertisingStateChangedEvent_mt = Class(TCAdvertisingStateChangedEvent, Event)

InitEventClass(TCAdvertisingStateChangedEvent, "TCAdvertisingStateChangedEvent")

function TCAdvertisingStateChangedEvent.emptyNew()
    return Event.new(TCAdvertisingStateChangedEvent_mt)
end

function TCAdvertisingStateChangedEvent.new(farmId, levelKey, expiresOnDay)
    local self = TCAdvertisingStateChangedEvent.emptyNew()
    self.farmId = farmId
    self.levelKey = levelKey
    self.expiresOnDay = expiresOnDay
    return self
end

function TCAdvertisingStateChangedEvent:writeStream(streamId, connection)
    streamWriteInt32(streamId, self.farmId)
    streamWriteBool(streamId, self.levelKey ~= nil)
    if self.levelKey ~= nil then
        streamWriteString(streamId, self.levelKey)
        streamWriteInt32(streamId, self.expiresOnDay)
    end
end

function TCAdvertisingStateChangedEvent:readStream(streamId, connection)
    self.farmId = streamReadInt32(streamId)
    if streamReadBool(streamId) then
        self.levelKey = streamReadString(streamId)
        self.expiresOnDay = streamReadInt32(streamId)
    end
    self:run(connection)
end

function TCAdvertisingStateChangedEvent:run(connection)
    g_currentMission.TheContractor.Advertising:applyAdvertisingState(self.farmId, self.levelKey, self.expiresOnDay)
end
