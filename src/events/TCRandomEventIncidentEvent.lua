-- Broadcast-only: a random event incident (068) opened, moved on a stage or
-- closed (TheContractorRandomEvents:commitIncident/closeIncident). Clients
-- keep the incidents and cooldowns so menus can show them. See
-- src/events/README.md for the general event conventions.

TCRandomEventIncidentEvent = {}
local TCRandomEventIncidentEvent_mt = Class(TCRandomEventIncidentEvent, Event)

InitEventClass(TCRandomEventIncidentEvent, "TCRandomEventIncidentEvent")

function TCRandomEventIncidentEvent.emptyNew()
    return Event.new(TCRandomEventIncidentEvent_mt)
end

function TCRandomEventIncidentEvent.new(incident, isClosed)
    local self = TCRandomEventIncidentEvent.emptyNew()
    self.incident = incident
    self.isClosed = isClosed
    return self
end

function TCRandomEventIncidentEvent:writeStream(streamId, connection)
    streamWriteBool(streamId, self.isClosed)
    TheContractorRandomEvents.writeIncident(streamId, self.incident)
end

function TCRandomEventIncidentEvent:readStream(streamId, connection)
    self.isClosed = streamReadBool(streamId)
    self.incident = TheContractorRandomEvents.readIncident(streamId)
    self:run(connection)
end

function TCRandomEventIncidentEvent:run(connection)
    local randomEvents = g_currentMission.TheContractor.RandomEvents
    -- Applied first even when closing, so the cooldown it started is kept.
    randomEvents:applyIncident(self.incident)
    if self.isClosed then
        randomEvents:applyIncidentClosed(self.incident.id)
    end
end
