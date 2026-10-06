-- Client asks to hire or release its farm's office administrator, from the
-- Finances tab (057). The server re-checks it (TheContractorAdministrator:
-- handleRequest); the result goes out as a TCAdministratorChangedEvent.
-- See src/events/README.md for the general event conventions.

TCAdministratorRequestEvent = {}
local TCAdministratorRequestEvent_mt = Class(TCAdministratorRequestEvent, Event)

InitEventClass(TCAdministratorRequestEvent, "TCAdministratorRequestEvent")

function TCAdministratorRequestEvent.emptyNew()
    return Event.new(TCAdministratorRequestEvent_mt)
end

function TCAdministratorRequestEvent.new(farmId, request)
    local self = TCAdministratorRequestEvent.emptyNew()
    self.farmId = farmId
    self.request = request
    return self
end

function TCAdministratorRequestEvent:writeStream(streamId, connection)
    streamWriteInt32(streamId, self.farmId)
    streamWriteString(streamId, self.request)
end

function TCAdministratorRequestEvent:readStream(streamId, connection)
    self.farmId = streamReadInt32(streamId)
    self.request = streamReadString(streamId)
    self:run(connection)
end

function TCAdministratorRequestEvent:run(connection)
    if g_currentMission:getIsServer() then
        g_currentMission.TheContractor.Administrator:handleRequest(self.farmId, self.request)
    end
end
