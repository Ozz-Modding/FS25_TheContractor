-- Client -> server (139): leave, change or withdraw (amount 0) a farm's bid
-- on an auction lot. The server checks it (AuctionSale:getBidProblem),
-- applies it and sends the farm's bids back to that farm's players
-- (TCAuctionBidsEvent), with the refusal if it was refused. The requester
-- never reads its own bid straight back after sending.

TCAuctionBidEvent = {}
local TCAuctionBidEvent_mt = Class(TCAuctionBidEvent, Event)

InitEventClass(TCAuctionBidEvent, "TCAuctionBidEvent")

function TCAuctionBidEvent.emptyNew()
    return Event.new(TCAuctionBidEvent_mt)
end

function TCAuctionBidEvent.new(farmId, lotNumber, amount)
    local self = TCAuctionBidEvent.emptyNew()
    self.farmId = farmId
    self.lotNumber = lotNumber
    self.amount = amount
    return self
end

function TCAuctionBidEvent:writeStream(streamId, connection)
    streamWriteInt32(streamId, self.farmId)
    streamWriteUInt16(streamId, self.lotNumber)
    streamWriteInt32(streamId, self.amount)
end

function TCAuctionBidEvent:readStream(streamId, connection)
    self.farmId = streamReadInt32(streamId)
    self.lotNumber = streamReadUInt16(streamId)
    self.amount = streamReadInt32(streamId)
    self:run(connection)
end

-- The farm a request's player is on, or nil (single player and the host's
-- own requests: the local player's farm).
local function getConnectionFarmId(connection)
    local player = g_currentMission.connectionsToPlayer ~= nil and g_currentMission.connectionsToPlayer[connection] or
        nil
    if player ~= nil then
        return player.farmId
    end
    return g_currentMission:getFarmId()
end

function TCAuctionBidEvent:run(connection)
    if connection:getIsServer() then
        return
    end
    local sale = g_currentMission.TheContractor.AuctionSale
    -- A player bids for their own farm only.
    if sale == nil or getConnectionFarmId(connection) ~= self.farmId then
        return
    end
    sale:placeBid(self.farmId, self.lotNumber, self.amount)
end
