-- Broadcast-only: a farm hired or released its office administrator (057,
-- TheContractorAdministrator:commit). admin is nil once released. See
-- src/events/README.md for the general event conventions.

TCAdministratorChangedEvent = {}
local TCAdministratorChangedEvent_mt = Class(TCAdministratorChangedEvent, Event)

InitEventClass(TCAdministratorChangedEvent, "TCAdministratorChangedEvent")

function TCAdministratorChangedEvent.emptyNew()
    return Event.new(TCAdministratorChangedEvent_mt)
end

function TCAdministratorChangedEvent.new(farmId, admin)
    local self = TCAdministratorChangedEvent.emptyNew()
    self.farmId = farmId
    self.admin = admin
    return self
end

function TCAdministratorChangedEvent:writeStream(streamId, connection)
    streamWriteInt32(streamId, self.farmId)
    TheContractorAdministrator.writeAdministrator(streamId, self.admin)
end

function TCAdministratorChangedEvent:readStream(streamId, connection)
    self.farmId = streamReadInt32(streamId)
    self.admin = TheContractorAdministrator.readAdministrator(streamId)
    self:run(connection)
end

function TCAdministratorChangedEvent:run(connection)
    g_currentMission.TheContractor.Administrator:applyAdministrator(self.farmId, self.admin)
end
