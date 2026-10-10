-- Broadcast-only: a finished job went in the logbook (060,
-- TheContractorLogbook:recordJob), with an entry for each machine it used
-- on that machine's own history. See src/events/README.md for the general
-- event conventions.

TCLogJobRecordedEvent = {}
local TCLogJobRecordedEvent_mt = Class(TCLogJobRecordedEvent, Event)

InitEventClass(TCLogJobRecordedEvent, "TCLogJobRecordedEvent")

function TCLogJobRecordedEvent.emptyNew()
    return Event.new(TCLogJobRecordedEvent_mt)
end

-- vehicleUpdates: { { record, entry } }.
function TCLogJobRecordedEvent.new(entry, vehicleUpdates)
    local self = TCLogJobRecordedEvent.emptyNew()
    self.entry = entry
    self.vehicleUpdates = vehicleUpdates
    return self
end

function TCLogJobRecordedEvent:writeStream(streamId, connection)
    TheContractorLogbook.writeJobEntry(streamId, self.entry)
    streamWriteUInt8(streamId, #self.vehicleUpdates)
    for _, update in ipairs(self.vehicleUpdates) do
        TheContractorLogbook.writeVehicleHeader(streamId, update.record)
        TheContractorLogbook.writeVehicleEntry(streamId, update.entry)
    end
end

function TCLogJobRecordedEvent:readStream(streamId, connection)
    self.entry = TheContractorLogbook.readJobEntry(streamId)
    self.vehicleUpdates = {}
    for _ = 1, streamReadUInt8(streamId) do
        local record = TheContractorLogbook.readVehicleHeader(streamId)
        table.insert(self.vehicleUpdates, { record = record, entry = TheContractorLogbook.readVehicleEntry(streamId) })
    end
    self:run(connection)
end

function TCLogJobRecordedEvent:run(connection)
    local logbook = g_currentMission.TheContractor.Logbook
    logbook:applyJobEntry(self.entry)
    for _, update in ipairs(self.vehicleUpdates) do
        logbook:applyVehicleEntry(update.record, update.entry)
    end
end
