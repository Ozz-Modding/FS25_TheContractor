-- Client requests advertising at a given level for its farm; server
-- validates funds + reputation-tier gating and applies, which itself
-- broadcasts the resulting state via TCAdvertisingStateChangedEvent. See
-- src/events/README.md for the general event conventions, and
-- TCCreateCompanyEvent.lua for the closest sibling of this request/validate
-- shape.

TCPurchaseAdvertisingEvent = {}
local TCPurchaseAdvertisingEvent_mt = Class(TCPurchaseAdvertisingEvent, Event)

InitEventClass(TCPurchaseAdvertisingEvent, "TCPurchaseAdvertisingEvent")

function TCPurchaseAdvertisingEvent.emptyNew()
    return Event.new(TCPurchaseAdvertisingEvent_mt)
end

function TCPurchaseAdvertisingEvent.new(farmId, levelKey)
    local self = TCPurchaseAdvertisingEvent.emptyNew()
    self.farmId = farmId
    self.levelKey = levelKey
    return self
end

function TCPurchaseAdvertisingEvent:writeStream(streamId, connection)
    streamWriteInt32(streamId, self.farmId)
    streamWriteString(streamId, self.levelKey)
end

function TCPurchaseAdvertisingEvent:readStream(streamId, connection)
    self.farmId = streamReadInt32(streamId)
    self.levelKey = streamReadString(streamId)
    self:run(connection)
end

function TCPurchaseAdvertisingEvent:run(connection)
    if not g_currentMission:getIsServer() then
        return
    end

    local advertising = g_currentMission.TheContractor.Advertising
    if advertising:canPurchase(self.farmId, self.levelKey) then
        advertising:purchaseAdvertising(self.farmId, self.levelKey)
    end
end
