-- Broadcast-only (110): a farmer's land or yard changed on the server, as
-- farmland changed hands (TheContractorFarmers:reconcileLand). Carries the
-- farmer's whole holding.

TCFarmerLandEvent = {}
local TCFarmerLandEvent_mt = Class(TCFarmerLandEvent, Event)

InitEventClass(TCFarmerLandEvent, "TCFarmerLandEvent")

function TCFarmerLandEvent.emptyNew()
    return Event.new(TCFarmerLandEvent_mt)
end

function TCFarmerLandEvent.new(farmer)
    local self = TCFarmerLandEvent.emptyNew()
    self.personId = farmer.id
    self.farmlandIds = farmer.farmlandIds
    self.yardFarmlandId = farmer.yardFarmlandId
    return self
end

function TCFarmerLandEvent:writeStream(streamId, connection)
    streamWriteInt32(streamId, self.personId)
    TheContractorFarmers.writeIds(streamId, self.farmlandIds)
    streamWriteInt32(streamId, self.yardFarmlandId or 0)
end

function TCFarmerLandEvent:readStream(streamId, connection)
    self.personId = streamReadInt32(streamId)
    self.farmlandIds = TheContractorFarmers.readIds(streamId)
    local yardFarmlandId = streamReadInt32(streamId)
    self.yardFarmlandId = yardFarmlandId ~= 0 and yardFarmlandId or nil
    self:run(connection)
end

function TCFarmerLandEvent:run(connection)
    if not connection:getIsServer() then
        return
    end
    g_currentMission.TheContractor.Farmers:applyLand(self.personId, self.farmlandIds, self.yardFarmlandId)
end
