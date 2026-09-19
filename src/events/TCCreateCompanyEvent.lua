-- Client requests a new company for its farm (name + implicit cost);
-- server validates funds and applies, then broadcasts the resulting state
-- to the other clients on that farm. See src/events/README.md for the
-- general event conventions.

TCCreateCompanyEvent = {}
local TCCreateCompanyEvent_mt = Class(TCCreateCompanyEvent, Event)

InitEventClass(TCCreateCompanyEvent, "TCCreateCompanyEvent")

function TCCreateCompanyEvent.emptyNew()
    return Event.new(TCCreateCompanyEvent_mt)
end

function TCCreateCompanyEvent.new(farmId, name)
    local self = TCCreateCompanyEvent.emptyNew()
    self.farmId = farmId
    self.name = name
    return self
end

function TCCreateCompanyEvent:writeStream(streamId, connection)
    streamWriteInt32(streamId, self.farmId)
    streamWriteString(streamId, self.name)
end

function TCCreateCompanyEvent:readStream(streamId, connection)
    self.farmId = streamReadInt32(streamId)
    self.name = streamReadString(streamId)
    self:run(connection)
end

function TCCreateCompanyEvent:run(connection)
    local company = g_currentMission.TheContractor.Company

    if g_currentMission:getIsServer() then
        if company:canCreateCompany(self.farmId) then
            -- Apply directly rather than relying on the broadcast to loop
            -- back to us — it won't, in single-player (see events/README.md).
            company:createCompany(self.farmId, self.name)
            g_server:broadcastEvent(TCCreateCompanyEvent.new(self.farmId, self.name), false, connection)
        end
    else
        company:applyCompanyCreation(self.farmId, self.name)
    end
end
