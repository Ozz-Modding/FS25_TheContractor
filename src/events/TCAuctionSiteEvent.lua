-- Server -> clients (135): the auction site's field, its lots and its
-- walkways, the whole site when it goes up, is cleared or loses a lot, and
-- (138) one lot at a time as each comes out or (139) is sold. Clients lock the lots
-- (TCVehicleLock) and protect the field (Jobs:isFieldProtected) from it,
-- the crowd walks its walkways (137), and the "View lot" prompt, the lot
-- card and the menu's catalogue read its lots (138).
--
-- A lot is written field by field (writeLot): only what everyone may know.
-- Nothing else a lot carries on the server (its rolls, ADS's result, 139's
-- hidden bid) is ever put on the stream.

TCAuctionSiteEvent = {}
local TCAuctionSiteEvent_mt = Class(TCAuctionSiteEvent, Event)

InitEventClass(TCAuctionSiteEvent, "TCAuctionSiteEvent")

function TCAuctionSiteEvent.emptyNew()
    return Event.new(TCAuctionSiteEvent_mt)
end

-- The whole site. fieldId: 0 for no site. lots: TheContractorAuctionSite.
-- getPublicLot's. walkways: { { x1, z1, x2, z2, halfWidth } }.
function TCAuctionSiteEvent.new(fieldId, lots, walkways)
    local self = TCAuctionSiteEvent.emptyNew()
    self.fieldId = fieldId or 0
    self.lots = lots or {}
    self.walkways = walkways or {}
    return self
end

-- One lot that's come out, added to what the clients have.
function TCAuctionSiteEvent.newLot(lot)
    local self = TCAuctionSiteEvent.emptyNew()
    self.lot = lot
    return self
end

-- A lot as everyone sees it.
function TCAuctionSiteEvent.writeLot(streamId, lot)
    streamWriteUInt16(streamId, lot.number)
    streamWriteString(streamId, lot.xmlFilename or "")
    streamWriteString(streamId, lot.attachmentXml or "")
    streamWriteFloat32(streamId, lot.hours or 0)
    streamWriteUInt16(streamId, lot.ageMonths or 0)
    streamWriteFloat32(streamId, lot.guidePrice or 0)
    streamWriteUInt16(streamId, lot.closeMinute or 0)
    streamWriteUInt8(streamId, lot.result or 0)
    streamWriteInt32(streamId, lot.vehicleId or 0)
    streamWriteInt32(streamId, lot.attachmentId or 0)
end

function TCAuctionSiteEvent.readLot(streamId)
    local lot = {
        number = streamReadUInt16(streamId),
        xmlFilename = streamReadString(streamId),
        attachmentXml = streamReadString(streamId),
        hours = streamReadFloat32(streamId),
        ageMonths = streamReadUInt16(streamId),
        guidePrice = streamReadFloat32(streamId),
        closeMinute = streamReadUInt16(streamId),
        result = streamReadUInt8(streamId),
        vehicleId = streamReadInt32(streamId),
        attachmentId = streamReadInt32(streamId),
    }
    if lot.attachmentXml == "" then
        lot.attachmentXml = nil
    end
    if lot.attachmentId == 0 then
        lot.attachmentId = nil
    end
    if lot.vehicleId == 0 then
        lot.vehicleId = nil
    end
    return lot
end

-- Also the site's part of the initial client state.
function TCAuctionSiteEvent.writeSite(streamId, fieldId, lots, walkways)
    streamWriteInt32(streamId, fieldId or 0)
    streamWriteUInt16(streamId, #(lots or {}))
    for _, lot in ipairs(lots or {}) do
        TCAuctionSiteEvent.writeLot(streamId, lot)
    end
    streamWriteUInt8(streamId, #(walkways or {}))
    for _, walkway in ipairs(walkways or {}) do
        streamWriteFloat32(streamId, walkway.x1)
        streamWriteFloat32(streamId, walkway.z1)
        streamWriteFloat32(streamId, walkway.x2)
        streamWriteFloat32(streamId, walkway.z2)
        streamWriteFloat32(streamId, walkway.halfWidth)
    end
end

-- Returns fieldId, lots, walkways.
function TCAuctionSiteEvent.readSite(streamId)
    local fieldId = streamReadInt32(streamId)
    local lots = {}
    for _ = 1, streamReadUInt16(streamId) do
        table.insert(lots, TCAuctionSiteEvent.readLot(streamId))
    end
    local walkways = {}
    for _ = 1, streamReadUInt8(streamId) do
        table.insert(walkways, {
            x1 = streamReadFloat32(streamId),
            z1 = streamReadFloat32(streamId),
            x2 = streamReadFloat32(streamId),
            z2 = streamReadFloat32(streamId),
            halfWidth = streamReadFloat32(streamId),
        })
    end
    return fieldId, lots, walkways
end

function TCAuctionSiteEvent:writeStream(streamId, connection)
    if streamWriteBool(streamId, self.lot ~= nil) then
        TCAuctionSiteEvent.writeLot(streamId, self.lot)
    else
        TCAuctionSiteEvent.writeSite(streamId, self.fieldId, self.lots, self.walkways)
    end
end

function TCAuctionSiteEvent:readStream(streamId, connection)
    if streamReadBool(streamId) then
        self.lot = TCAuctionSiteEvent.readLot(streamId)
    else
        self.fieldId, self.lots, self.walkways = TCAuctionSiteEvent.readSite(streamId)
    end
    self:run(connection)
end

function TCAuctionSiteEvent:run(connection)
    if not connection:getIsServer() then
        -- Only the server says where the site is.
        return
    end
    local site = g_currentMission.TheContractor ~= nil and g_currentMission.TheContractor.AuctionSite or nil
    if site == nil then
        return
    end
    if self.lot ~= nil then
        site:appendLot(self.lot)
    else
        site:applySync(self.fieldId, self.lots, self.walkways)
    end
end
