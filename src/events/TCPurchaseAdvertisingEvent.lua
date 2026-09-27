-- Client requests an advertising campaign at a given level and duration
-- (in periods, 027) for its farm; server validates the duration, funds and
-- reputation-tier gating and applies, which itself broadcasts the resulting
-- state via TCAdvertisingStateChangedEvent. See src/events/README.md for the
-- general event conventions, and TCCreateCompanyEvent.lua for the closest
-- sibling of this request/validate shape.

TCPurchaseAdvertisingEvent = {}
local TCPurchaseAdvertisingEvent_mt = Class(TCPurchaseAdvertisingEvent, Event)

InitEventClass(TCPurchaseAdvertisingEvent, "TCPurchaseAdvertisingEvent")

function TCPurchaseAdvertisingEvent.emptyNew()
    return Event.new(TCPurchaseAdvertisingEvent_mt)
end

function TCPurchaseAdvertisingEvent.new(farmId, levelKey, durationPeriods)
    local self = TCPurchaseAdvertisingEvent.emptyNew()
    self.farmId = farmId
    self.levelKey = levelKey
    self.durationPeriods = durationPeriods
    return self
end

function TCPurchaseAdvertisingEvent:writeStream(streamId, connection)
    streamWriteInt32(streamId, self.farmId)
    streamWriteString(streamId, self.levelKey)
    streamWriteInt32(streamId, self.durationPeriods)
end

function TCPurchaseAdvertisingEvent:readStream(streamId, connection)
    self.farmId = streamReadInt32(streamId)
    self.levelKey = streamReadString(streamId)
    self.durationPeriods = streamReadInt32(streamId)
    self:run(connection)
end

function TCPurchaseAdvertisingEvent:run(connection)
    if not g_currentMission:getIsServer() then
        return
    end

    local advertising = g_currentMission.TheContractor.Advertising
    if advertising:canPurchase(self.farmId, self.levelKey, self.durationPeriods) then
        advertising:purchaseAdvertising(self.farmId, self.levelKey, self.durationPeriods)
    end
end
