-- Broadcast-only (128): a farmer has retired on the server and a successor
-- has taken over (TheContractorFarmers:retireFarmer). Carries the old id,
-- the successor as clients hold people, and the people counter. Each client
-- hands the old farmer's jobs, relationships and the rest over itself
-- (TheContractorFarmers:applyRetirement).

TCFarmerRetiredEvent = {}
local TCFarmerRetiredEvent_mt = Class(TCFarmerRetiredEvent, Event)

InitEventClass(TCFarmerRetiredEvent, "TCFarmerRetiredEvent")

function TCFarmerRetiredEvent.emptyNew()
    return Event.new(TCFarmerRetiredEvent_mt)
end

function TCFarmerRetiredEvent.new(oldId, successor, nextId)
    local self = TCFarmerRetiredEvent.emptyNew()
    self.oldId = oldId
    self.successor = successor
    self.nextId = nextId
    return self
end

function TCFarmerRetiredEvent:writeStream(streamId, connection)
    streamWriteInt32(streamId, self.oldId)
    TheContractorFarmers.writePerson(streamId, self.successor)
    streamWriteInt32(streamId, self.nextId)
end

function TCFarmerRetiredEvent:readStream(streamId, connection)
    self.oldId = streamReadInt32(streamId)
    self.successor = TheContractorFarmers.readPerson(streamId)
    self.nextId = streamReadInt32(streamId)
    self:run(connection)
end

function TCFarmerRetiredEvent:run(connection)
    if not connection:getIsServer() then
        return
    end
    g_currentMission.TheContractor.Farmers:applyRetirement(self.oldId, self.successor, self.nextId)
end
