-- Server -> clients (137): the machinery auction, whole, each time it's
-- announced, changes state, or is over or cancelled (nil). Each machine
-- protects its field, shows its marker and puts the crowd up from it
-- (TheContractorEventDay:applySync). Written as every event day is (163,
-- TheContractorEventDay.writeEvent).

TCAuctionEvent = {}
local TCAuctionEvent_mt = Class(TCAuctionEvent, Event)

InitEventClass(TCAuctionEvent, "TCAuctionEvent")

function TCAuctionEvent.emptyNew()
    return Event.new(TCAuctionEvent_mt)
end

-- auction: nil for none.
function TCAuctionEvent.new(auction)
    local self = TCAuctionEvent.emptyNew()
    self.auction = auction
    return self
end

-- Also the auction's part of the initial client state.
function TCAuctionEvent.writeAuction(streamId, auction)
    TheContractorEventDay.writeEvent(streamId, auction)
end

-- Returns the auction, or nil.
function TCAuctionEvent.readAuction(streamId)
    return TheContractorEventDay.readEvent(streamId)
end

function TCAuctionEvent:writeStream(streamId, connection)
    TCAuctionEvent.writeAuction(streamId, self.auction)
end

function TCAuctionEvent:readStream(streamId, connection)
    self.auction = TCAuctionEvent.readAuction(streamId)
    self:run(connection)
end

function TCAuctionEvent:run(connection)
    if not connection:getIsServer() then
        -- Only the server says what the auction is.
        return
    end
    local auctions = g_currentMission.TheContractor ~= nil and g_currentMission.TheContractor.Auctions or nil
    if auctions ~= nil then
        auctions:applySync(self.auction)
    end
end
