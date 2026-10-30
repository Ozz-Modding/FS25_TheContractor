-- Broadcast-only (122): a farmer's machines changed on the server, as their
-- fleet grew (TheContractorFarmerFleet.ensureAll) or a machine was edited
-- (editMachine). Carries the part of the fleet clients hold
-- (TheContractorFarmerFleet.writeStream).

TCFarmerFleetEvent = {}
local TCFarmerFleetEvent_mt = Class(TCFarmerFleetEvent, Event)

InitEventClass(TCFarmerFleetEvent, "TCFarmerFleetEvent")

function TCFarmerFleetEvent.emptyNew()
    return Event.new(TCFarmerFleetEvent_mt)
end

function TCFarmerFleetEvent.new(farmer)
    local self = TCFarmerFleetEvent.emptyNew()
    self.personId = farmer.id
    self.machines = farmer.machines
    return self
end

function TCFarmerFleetEvent:writeStream(streamId, connection)
    streamWriteInt32(streamId, self.personId)
    TheContractorFarmerFleet.writeStream(streamId, self.machines)
end

function TCFarmerFleetEvent:readStream(streamId, connection)
    self.personId = streamReadInt32(streamId)
    self.machines = TheContractorFarmerFleet.readStream(streamId)
    self:run(connection)
end

function TCFarmerFleetEvent:run(connection)
    if not connection:getIsServer() then
        return
    end
    g_currentMission.TheContractor.Farmers:applyFleet(self.personId, self.machines)
end
