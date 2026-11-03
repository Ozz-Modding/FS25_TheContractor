-- Broadcast-only: the server has forgotten a farm deleted in multiplayer
-- (TCFarmDeletion), so every client does too. Sent after anything else the
-- server had to say about the farm, so nothing brings it back.

TCFarmDeletedEvent = {}
local TCFarmDeletedEvent_mt = Class(TCFarmDeletedEvent, Event)

InitEventClass(TCFarmDeletedEvent, "TCFarmDeletedEvent")

function TCFarmDeletedEvent.emptyNew()
    return Event.new(TCFarmDeletedEvent_mt)
end

function TCFarmDeletedEvent.new(farmId)
    local self = TCFarmDeletedEvent.emptyNew()
    self.farmId = farmId
    return self
end

function TCFarmDeletedEvent:writeStream(streamId, connection)
    streamWriteInt32(streamId, self.farmId)
end

function TCFarmDeletedEvent:readStream(streamId, connection)
    self.farmId = streamReadInt32(streamId)
    self:run(connection)
end

function TCFarmDeletedEvent:run(connection)
    if not connection:getIsServer() then
        return
    end
    TCFarmDeletion.forgetFarm(self.farmId)
end
