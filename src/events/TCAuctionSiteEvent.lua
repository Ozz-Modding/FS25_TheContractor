-- Server -> clients (135): the auction site's field and its lots' vehicles
-- (lots and their attachments), the whole list each time a lot comes out
-- or the site's cleared. Clients lock the lots (TCVehicleLock) and protect
-- the field (Jobs:isFieldProtected) from it, and the crowd walks its
-- walkways (137).

TCAuctionSiteEvent = {}
local TCAuctionSiteEvent_mt = Class(TCAuctionSiteEvent, Event)

InitEventClass(TCAuctionSiteEvent, "TCAuctionSiteEvent")

function TCAuctionSiteEvent.emptyNew()
    return Event.new(TCAuctionSiteEvent_mt)
end

-- fieldId: 0 for no site. walkways: { { x1, z1, x2, z2, halfWidth } }.
function TCAuctionSiteEvent.new(fieldId, vehicleIds, walkways)
    local self = TCAuctionSiteEvent.emptyNew()
    self.fieldId = fieldId or 0
    self.vehicleIds = vehicleIds or {}
    self.walkways = walkways or {}
    return self
end

-- Also the site's part of the initial client state.
function TCAuctionSiteEvent.writeSite(streamId, fieldId, vehicleIds, walkways)
    streamWriteInt32(streamId, fieldId or 0)
    streamWriteInt32(streamId, #(vehicleIds or {}))
    for _, vehicleId in ipairs(vehicleIds or {}) do
        streamWriteInt32(streamId, vehicleId)
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

-- Returns fieldId, vehicleIds, walkways.
function TCAuctionSiteEvent.readSite(streamId)
    local fieldId = streamReadInt32(streamId)
    local count = streamReadInt32(streamId)
    local vehicleIds = {}
    for _ = 1, count do
        table.insert(vehicleIds, streamReadInt32(streamId))
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
    return fieldId, vehicleIds, walkways
end

function TCAuctionSiteEvent:writeStream(streamId, connection)
    TCAuctionSiteEvent.writeSite(streamId, self.fieldId, self.vehicleIds, self.walkways)
end

function TCAuctionSiteEvent:readStream(streamId, connection)
    self.fieldId, self.vehicleIds, self.walkways = TCAuctionSiteEvent.readSite(streamId)
    self:run(connection)
end

function TCAuctionSiteEvent:run(connection)
    if not connection:getIsServer() then
        -- Only the server says where the site is.
        return
    end
    local site = g_currentMission.TheContractor ~= nil and g_currentMission.TheContractor.AuctionSite or nil
    if site ~= nil then
        site:applySync(self.fieldId, self.vehicleIds, self.walkways)
    end
end
