-- Server -> clients (135): the auction site's field, its lots and its
-- walkways, the whole site when it goes up, is cleared or loses a lot, and
-- (138) one lot at a time as each comes out or (139) is sold. Clients lock the lots
-- (TCVehicleLock) and protect the field (Jobs:isFieldProtected) from it,
-- the crowd walks its walkways (137), the "View lot" prompt, the lot
-- card and the menu's catalogue read its lots (138), and the site's
-- dressing and the crowd's spots come from its scene (140,
-- TCAuctionLayout.getScene).
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
-- getPublicLot's. walkways: { { x1, z1, x2, z2, halfWidth } }. scene: 140's,
-- or nil.
function TCAuctionSiteEvent.new(fieldId, lots, walkways, scene)
    local self = TCAuctionSiteEvent.emptyNew()
    self.fieldId = fieldId or 0
    self.lots = lots or {}
    self.walkways = walkways or {}
    self.scene = scene
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

-- 140: the scene (TCAuctionLayout.getScene's), or nil.
function TCAuctionSiteEvent.writeScene(streamId, scene)
    if not streamWriteBool(streamId, scene ~= nil) then
        return
    end
    streamWriteInt32(streamId, scene.seed or 0)
    -- 163: the kind of day it's dressed for ("": the auction).
    streamWriteString(streamId, scene.dressing or "")
    for _, key in ipairs({ "cx", "cz", "angle", "halfV", "nearEdge", "farEdge", "aisleWidth", "endAisle", "gateV" }) do
        streamWriteFloat32(streamId, scene[key] or 0)
    end
    streamWriteBool(streamId, scene.nearSign > 0)
    local reserve = scene.reserve
    for _, key in ipairs({ "uFrom", "uTo", "vFrom", "vTo" }) do
        streamWriteFloat32(streamId, reserve[key])
    end
    streamWriteUInt8(streamId, #scene.rows)
    for _, row in ipairs(scene.rows) do
        streamWriteFloat32(streamId, row.vFrom)
        streamWriteFloat32(streamId, row.vTo)
        streamWriteFloat32(streamId, row.frontV)
        streamWriteBool(streamId, row.facing > 0)
        streamWriteFloat32(streamId, row.used or 0)
        streamWriteUInt16(streamId, row.lotFrom)
        streamWriteUInt16(streamId, row.lotTo)
        local slots = row.slots or {}
        streamWriteUInt8(streamId, #slots)
        for _, u in ipairs(slots) do
            streamWriteFloat32(streamId, u)
        end
    end
end

function TCAuctionSiteEvent.readScene(streamId)
    if not streamReadBool(streamId) then
        return nil
    end
    local scene = { seed = streamReadInt32(streamId) }
    local dressing = streamReadString(streamId)
    scene.dressing = dressing ~= "" and dressing or nil
    for _, key in ipairs({ "cx", "cz", "angle", "halfV", "nearEdge", "farEdge", "aisleWidth", "endAisle", "gateV" }) do
        scene[key] = streamReadFloat32(streamId)
    end
    scene.nearSign = streamReadBool(streamId) and 1 or -1
    scene.reserve = {}
    for _, key in ipairs({ "uFrom", "uTo", "vFrom", "vTo" }) do
        scene.reserve[key] = streamReadFloat32(streamId)
    end
    scene.rows = {}
    for _ = 1, streamReadUInt8(streamId) do
        local row = {
            vFrom = streamReadFloat32(streamId),
            vTo = streamReadFloat32(streamId),
            frontV = streamReadFloat32(streamId),
            facing = streamReadBool(streamId) and 1 or -1,
            used = streamReadFloat32(streamId),
            lotFrom = streamReadUInt16(streamId),
            lotTo = streamReadUInt16(streamId),
            slots = {},
        }
        for _ = 1, streamReadUInt8(streamId) do
            table.insert(row.slots, streamReadFloat32(streamId))
        end
        table.insert(scene.rows, row)
    end
    return scene
end

-- Also the site's part of the initial client state.
function TCAuctionSiteEvent.writeSite(streamId, fieldId, lots, walkways, scene)
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
    TCAuctionSiteEvent.writeScene(streamId, scene)
end

-- Returns fieldId, lots, walkways, scene.
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
    return fieldId, lots, walkways, TCAuctionSiteEvent.readScene(streamId)
end

function TCAuctionSiteEvent:writeStream(streamId, connection)
    if streamWriteBool(streamId, self.lot ~= nil) then
        TCAuctionSiteEvent.writeLot(streamId, self.lot)
    else
        TCAuctionSiteEvent.writeSite(streamId, self.fieldId, self.lots, self.walkways, self.scene)
    end
end

function TCAuctionSiteEvent:readStream(streamId, connection)
    if streamReadBool(streamId) then
        self.lot = TCAuctionSiteEvent.readLot(streamId)
    else
        self.fieldId, self.lots, self.walkways, self.scene = TCAuctionSiteEvent.readSite(streamId)
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
        site:applySync(self.fieldId, self.lots, self.walkways, self.scene)
    end
end
