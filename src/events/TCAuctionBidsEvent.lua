-- Server -> one farm's players (139, broadcastEventToFarm): that farm's
-- bids on the auction's lots, whole, each time they change; with what's
-- become of any just settled (won, lost, couldn't pay, delivered: the
-- notifications) and a refused request (shown to the player who asked).
-- Never another farm's bids, and never a lot's hidden local bid.

TCAuctionBidsEvent = {}
local TCAuctionBidsEvent_mt = Class(TCAuctionBidsEvent, Event)

InitEventClass(TCAuctionBidsEvent, "TCAuctionBidsEvent")

function TCAuctionBidsEvent.emptyNew()
    return Event.new(TCAuctionBidsEvent_mt)
end

-- farmBids: lotNumber -> { amount, outcome, paid, fee }. outcomes: { {
-- lotNumber, outcome, amount, fee } } or nil. refusal: { lotNumber, key }
-- or nil.
function TCAuctionBidsEvent.new(farmId, farmBids, outcomes, refusal)
    local self = TCAuctionBidsEvent.emptyNew()
    self.farmId = farmId
    self.farmBids = farmBids or {}
    self.outcomes = outcomes or {}
    self.refusal = refusal
    return self
end

-- Also the bids' part of the initial client state.
function TCAuctionBidsEvent.writeBids(streamId, farmBids)
    local lotNumbers = {}
    for lotNumber in pairs(farmBids) do
        table.insert(lotNumbers, lotNumber)
    end
    table.sort(lotNumbers)
    streamWriteUInt16(streamId, #lotNumbers)
    for _, lotNumber in ipairs(lotNumbers) do
        local bid = farmBids[lotNumber]
        streamWriteUInt16(streamId, lotNumber)
        streamWriteInt32(streamId, bid.amount)
        streamWriteString(streamId, bid.outcome or "")
        streamWriteInt32(streamId, bid.paid or 0)
        streamWriteInt32(streamId, bid.fee or 0)
    end
end

function TCAuctionBidsEvent.readBids(streamId)
    local farmBids = {}
    for _ = 1, streamReadUInt16(streamId) do
        local lotNumber = streamReadUInt16(streamId)
        local bid = {
            amount = streamReadInt32(streamId),
            outcome = streamReadString(streamId),
            paid = streamReadInt32(streamId),
            fee = streamReadInt32(streamId),
        }
        bid.outcome = bid.outcome ~= "" and bid.outcome or nil
        bid.paid = bid.paid ~= 0 and bid.paid or nil
        bid.fee = bid.fee ~= 0 and bid.fee or nil
        farmBids[lotNumber] = bid
    end
    return farmBids
end

function TCAuctionBidsEvent:writeStream(streamId, connection)
    streamWriteInt32(streamId, self.farmId)
    TCAuctionBidsEvent.writeBids(streamId, self.farmBids)
    streamWriteUInt8(streamId, #self.outcomes)
    for _, outcome in ipairs(self.outcomes) do
        streamWriteUInt16(streamId, outcome.lotNumber)
        streamWriteString(streamId, outcome.outcome)
        streamWriteInt32(streamId, outcome.amount or 0)
        streamWriteInt32(streamId, outcome.fee or 0)
    end
    if streamWriteBool(streamId, self.refusal ~= nil) then
        streamWriteUInt16(streamId, self.refusal.lotNumber)
        streamWriteString(streamId, self.refusal.key)
    end
end

function TCAuctionBidsEvent:readStream(streamId, connection)
    self.farmId = streamReadInt32(streamId)
    self.farmBids = TCAuctionBidsEvent.readBids(streamId)
    self.outcomes = {}
    for _ = 1, streamReadUInt8(streamId) do
        table.insert(self.outcomes, {
            lotNumber = streamReadUInt16(streamId),
            outcome = streamReadString(streamId),
            amount = streamReadInt32(streamId),
            fee = streamReadInt32(streamId),
        })
    end
    if streamReadBool(streamId) then
        self.refusal = { lotNumber = streamReadUInt16(streamId), key = streamReadString(streamId) }
    end
    self:run(connection)
end

function TCAuctionBidsEvent:run(connection)
    if not connection:getIsServer() then
        return
    end
    local sale = g_currentMission.TheContractor.AuctionSale
    -- The server holds every farm's bids already, and told its own player
    -- (AuctionSale:sendFarmBids).
    if sale == nil or g_currentMission:getIsServer() then
        return
    end
    sale:applyFarmBids(self.farmId, self.farmBids)
    sale:showNotices(self.farmId, self.outcomes, self.refusal)
end
