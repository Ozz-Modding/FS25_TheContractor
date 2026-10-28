-- Broadcast-only (108): the server has set a farmland's yard override
-- (tcCompany yard, server only) and the clients apply it. See
-- TheContractorYards:setOverride.

TCYardOverrideEvent = {}
local TCYardOverrideEvent_mt = Class(TCYardOverrideEvent, Event)

InitEventClass(TCYardOverrideEvent, "TCYardOverrideEvent")

function TCYardOverrideEvent.emptyNew()
    return Event.new(TCYardOverrideEvent_mt)
end

function TCYardOverrideEvent.new(farmlandId, mode)
    local self = TCYardOverrideEvent.emptyNew()
    self.farmlandId = farmlandId
    self.mode = mode
    return self
end

function TCYardOverrideEvent:writeStream(streamId, connection)
    streamWriteInt32(streamId, self.farmlandId)
    streamWriteUInt8(streamId, self.mode)
end

function TCYardOverrideEvent:readStream(streamId, connection)
    self.farmlandId = streamReadInt32(streamId)
    self.mode = streamReadUInt8(streamId)
    self:run(connection)
end

function TCYardOverrideEvent:run(connection)
    if not connection:getIsServer() then
        return
    end
    g_currentMission.TheContractor.Yards:applyOverride(self.farmlandId, self.mode)
end
