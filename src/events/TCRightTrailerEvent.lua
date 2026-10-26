-- Client requests pushing one of its farm's tipped trailers back onto its
-- wheels (105, from TCTippedTrailerActivatable's prompt by it). The server
-- re-checks and applies it with TheContractorTippedTrailer:rightTrailer:
-- the trailer's position replicates by itself and the incident's closing
-- goes to every client (TCRandomEventIncidentEvent), so this has no apply
-- side of its own. See src/events/README.md for the general event
-- conventions.

TCRightTrailerEvent = {}
local TCRightTrailerEvent_mt = Class(TCRightTrailerEvent, Event)

InitEventClass(TCRightTrailerEvent, "TCRightTrailerEvent")

function TCRightTrailerEvent.emptyNew()
    return Event.new(TCRightTrailerEvent_mt)
end

function TCRightTrailerEvent.new(farmId, incidentId)
    local self = TCRightTrailerEvent.emptyNew()
    self.farmId = farmId
    self.incidentId = incidentId
    return self
end

function TCRightTrailerEvent:writeStream(streamId, connection)
    streamWriteInt32(streamId, self.farmId)
    streamWriteInt32(streamId, self.incidentId)
end

function TCRightTrailerEvent:readStream(streamId, connection)
    self.farmId = streamReadInt32(streamId)
    self.incidentId = streamReadInt32(streamId)
    self:run(connection)
end

function TCRightTrailerEvent:run(connection)
    if g_currentMission:getIsServer() then
        g_currentMission.TheContractor.TippedTrailer:rightTrailer(self.farmId, self.incidentId)
    end
end
