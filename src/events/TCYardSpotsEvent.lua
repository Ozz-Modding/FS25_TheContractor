-- Broadcast-only (114): the server has worked a yard's standing spots out
-- again (its override changed) and the clients take its list, so every
-- machine puts the yard's farmer on the same spot. See
-- TheContractorYards:refreshSpots.

TCYardSpotsEvent = {}
local TCYardSpotsEvent_mt = Class(TCYardSpotsEvent, Event)

InitEventClass(TCYardSpotsEvent, "TCYardSpotsEvent")

function TCYardSpotsEvent.emptyNew()
    return Event.new(TCYardSpotsEvent_mt)
end

-- entry: { x, z, spots }, or nil once the farmland isn't a yard.
function TCYardSpotsEvent.new(farmlandId, entry)
    local self = TCYardSpotsEvent.emptyNew()
    self.farmlandId = farmlandId
    self.entry = entry
    return self
end

function TCYardSpotsEvent:writeStream(streamId, connection)
    streamWriteInt32(streamId, self.farmlandId)
    TheContractorYards.writeSpotsEntry(streamId, self.entry)
end

function TCYardSpotsEvent:readStream(streamId, connection)
    self.farmlandId = streamReadInt32(streamId)
    self.entry = TheContractorYards.readSpotsEntry(streamId)
    self:run(connection)
end

function TCYardSpotsEvent:run(connection)
    if not connection:getIsServer() then
        return
    end
    g_currentMission.TheContractor.Yards:applySpots(self.farmlandId, self.entry)
end
