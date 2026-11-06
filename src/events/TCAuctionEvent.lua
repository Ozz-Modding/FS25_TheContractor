-- Server -> clients (137): the machinery auction, whole, each time it's
-- announced, changes state, or is over or cancelled (nil). Each machine
-- protects its field, shows its marker and puts the crowd up from it
-- (TheContractorAuctions:applySync).

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
    if not streamWriteBool(streamId, auction ~= nil) then
        return
    end
    streamWriteInt32(streamId, auction.id)
    streamWriteInt32(streamId, auction.fieldId)
    streamWriteInt32(streamId, auction.hostFarmerId)
    streamWriteInt32(streamId, auction.announcedDay)
    streamWriteInt32(streamId, auction.signsDay)
    streamWriteInt32(streamId, auction.reminderDay or -1)
    streamWriteInt32(streamId, auction.saleDay)
    streamWriteUInt8(streamId, TheContractorAuctions.getStateIndex(auction.state))
    if streamWriteBool(streamId, auction.entrance ~= nil) then
        streamWriteFloat32(streamId, auction.entrance.x)
        streamWriteFloat32(streamId, auction.entrance.z)
    end
end

-- Returns the auction, or nil.
function TCAuctionEvent.readAuction(streamId)
    if not streamReadBool(streamId) then
        return nil
    end
    local auction = {
        id = streamReadInt32(streamId),
        fieldId = streamReadInt32(streamId),
        hostFarmerId = streamReadInt32(streamId),
        announcedDay = streamReadInt32(streamId),
        signsDay = streamReadInt32(streamId),
        reminderDay = streamReadInt32(streamId),
        saleDay = streamReadInt32(streamId),
    }
    if auction.reminderDay < 0 then
        auction.reminderDay = nil
    end
    auction.state = TheContractorAuctions.STATE_ORDER[streamReadUInt8(streamId)] or
        TheContractorAuctions.STATE.ANNOUNCED
    if streamReadBool(streamId) then
        auction.entrance = { x = streamReadFloat32(streamId), z = streamReadFloat32(streamId) }
    end
    return auction
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
