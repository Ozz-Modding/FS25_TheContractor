-- Broadcast-only: a staff driver's or a player's stint in one of the
-- business's machines went on its logbook history (060). See
-- src/events/README.md for the general event conventions.

TCLogVehicleEntryEvent = {}
local TCLogVehicleEntryEvent_mt = Class(TCLogVehicleEntryEvent, Event)

InitEventClass(TCLogVehicleEntryEvent, "TCLogVehicleEntryEvent")

function TCLogVehicleEntryEvent.emptyNew()
    return Event.new(TCLogVehicleEntryEvent_mt)
end

function TCLogVehicleEntryEvent.new(record, entry)
    local self = TCLogVehicleEntryEvent.emptyNew()
    self.record = record
    self.entry = entry
    return self
end

function TCLogVehicleEntryEvent:writeStream(streamId, connection)
    TheContractorLogbook.writeVehicleHeader(streamId, self.record)
    TheContractorLogbook.writeVehicleEntry(streamId, self.entry)
end

function TCLogVehicleEntryEvent:readStream(streamId, connection)
    self.record = TheContractorLogbook.readVehicleHeader(streamId)
    self.entry = TheContractorLogbook.readVehicleEntry(streamId)
    self:run(connection)
end

function TCLogVehicleEntryEvent:run(connection)
    g_currentMission.TheContractor.Logbook:applyVehicleEntry(self.record, self.entry)
end
