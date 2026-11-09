-- Broadcast-only (110): the server has generated the farmers again
-- (tcFarmer regenerate, server only). Carries everyone, and every
-- job whose customer changed with them. See TheContractorFarmers:regenerate.

TCFarmersEvent = {}
local TCFarmersEvent_mt = Class(TCFarmersEvent, Event)

InitEventClass(TCFarmersEvent, "TCFarmersEvent")

function TCFarmersEvent.emptyNew()
    return Event.new(TCFarmersEvent_mt)
end

-- links: { farmId, jobId, customerId (0 for none) }.
function TCFarmersEvent.new(farmers, links)
    local self = TCFarmersEvent.emptyNew()
    self.farmers = farmers
    self.links = links
    return self
end

function TCFarmersEvent:writeStream(streamId, connection)
    self.farmers:writeState(streamId)
    streamWriteInt32(streamId, #self.links)
    for _, link in ipairs(self.links) do
        streamWriteInt32(streamId, link.farmId)
        streamWriteInt32(streamId, link.jobId)
        streamWriteInt32(streamId, link.customerId)
    end
end

function TCFarmersEvent:readStream(streamId, connection)
    self.state = TheContractorFarmers.readState(streamId)
    self.links = {}
    for _ = 1, streamReadInt32(streamId) do
        table.insert(self.links, {
            farmId = streamReadInt32(streamId),
            jobId = streamReadInt32(streamId),
            customerId = streamReadInt32(streamId),
        })
    end
    self:run(connection)
end

function TCFarmersEvent:run(connection)
    if not connection:getIsServer() then
        return
    end
    g_currentMission.TheContractor.Farmers:applyState(self.state, self.links)
end
