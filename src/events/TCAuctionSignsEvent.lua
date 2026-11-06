-- Server -> clients (136): the auction's roadside signs and their month, the
-- whole list each time they go up or come down. Each machine loads the
-- models and map markers from it (TheContractorAuctionSigns:applySync).

TCAuctionSignsEvent = {}
local TCAuctionSignsEvent_mt = Class(TCAuctionSignsEvent, Event)

InitEventClass(TCAuctionSignsEvent, "TCAuctionSignsEvent")

-- The month's bits on the wire (0 to 12).
TCAuctionSignsEvent.MONTH_BITS = 4

function TCAuctionSignsEvent.emptyNew()
    return Event.new(TCAuctionSignsEvent_mt)
end

-- month: 0 for none up. signs: { x, z, yaw }.
function TCAuctionSignsEvent.new(month, signs)
    local self = TCAuctionSignsEvent.emptyNew()
    self.month = month or 0
    self.signs = signs or {}
    return self
end

-- Also the signs' part of the initial client state.
function TCAuctionSignsEvent.writeSigns(streamId, month, signs)
    streamWriteUIntN(streamId, month or 0, TCAuctionSignsEvent.MONTH_BITS)
    streamWriteInt32(streamId, #(signs or {}))
    for _, sign in ipairs(signs or {}) do
        streamWriteFloat32(streamId, sign.x)
        streamWriteFloat32(streamId, sign.z)
        streamWriteFloat32(streamId, sign.yaw)
    end
end

-- Returns month, signs.
function TCAuctionSignsEvent.readSigns(streamId)
    local month = streamReadUIntN(streamId, TCAuctionSignsEvent.MONTH_BITS)
    local count = streamReadInt32(streamId)
    local signs = {}
    for _ = 1, count do
        table.insert(signs, {
            x = streamReadFloat32(streamId),
            z = streamReadFloat32(streamId),
            yaw = streamReadFloat32(streamId),
        })
    end
    return month, signs
end

function TCAuctionSignsEvent:writeStream(streamId, connection)
    TCAuctionSignsEvent.writeSigns(streamId, self.month, self.signs)
end

function TCAuctionSignsEvent:readStream(streamId, connection)
    self.month, self.signs = TCAuctionSignsEvent.readSigns(streamId)
    self:run(connection)
end

function TCAuctionSignsEvent:run(connection)
    if not connection:getIsServer() then
        -- Only the server puts signs up.
        return
    end
    local signs = g_currentMission.TheContractor ~= nil and g_currentMission.TheContractor.AuctionSigns or nil
    if signs ~= nil then
        signs:applySync(self.month, self.signs)
    end
end
