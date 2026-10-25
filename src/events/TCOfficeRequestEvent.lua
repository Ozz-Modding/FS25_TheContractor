-- Client asks to hire, release or train one of its farm's office staff,
-- from the Staff tab (057, 090). The server re-checks it
-- (TheContractorOffice:handleRequest); the result goes out as a
-- TCOfficeChangedEvent. See src/events/README.md for the general event
-- conventions.

TCOfficeRequestEvent = {}
local TCOfficeRequestEvent_mt = Class(TCOfficeRequestEvent, Event)

InitEventClass(TCOfficeRequestEvent, "TCOfficeRequestEvent")

function TCOfficeRequestEvent.emptyNew()
    return Event.new(TCOfficeRequestEvent_mt)
end

function TCOfficeRequestEvent.new(farmId, role, request)
    local self = TCOfficeRequestEvent.emptyNew()
    self.farmId = farmId
    self.role = role
    self.request = request
    return self
end

function TCOfficeRequestEvent:writeStream(streamId, connection)
    streamWriteInt32(streamId, self.farmId)
    streamWriteString(streamId, self.role)
    streamWriteString(streamId, self.request)
end

function TCOfficeRequestEvent:readStream(streamId, connection)
    self.farmId = streamReadInt32(streamId)
    self.role = streamReadString(streamId)
    self.request = streamReadString(streamId)
    self:run(connection)
end

function TCOfficeRequestEvent:run(connection)
    if g_currentMission:getIsServer() then
        g_currentMission.TheContractor.Office:handleRequest(self.farmId, self.role, self.request)
    end
end
