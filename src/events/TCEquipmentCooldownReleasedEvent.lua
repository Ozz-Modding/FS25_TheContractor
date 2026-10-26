-- Broadcast-only (105): the server has taken some vehicles out of their
-- cooldown early (TheContractorCooldown:releaseVehicles), leaving the rest
-- of it running. Just the vehicle ids: every machine finds the entries
-- holding them itself. See src/events/README.md for the general event
-- conventions.

TCEquipmentCooldownReleasedEvent = {}
local TCEquipmentCooldownReleasedEvent_mt = Class(TCEquipmentCooldownReleasedEvent, Event)

InitEventClass(TCEquipmentCooldownReleasedEvent, "TCEquipmentCooldownReleasedEvent")

function TCEquipmentCooldownReleasedEvent.emptyNew()
    return Event.new(TCEquipmentCooldownReleasedEvent_mt)
end

function TCEquipmentCooldownReleasedEvent.new(vehicleIds)
    local self = TCEquipmentCooldownReleasedEvent.emptyNew()
    self.vehicleIds = vehicleIds
    return self
end

function TCEquipmentCooldownReleasedEvent:writeStream(streamId, connection)
    streamWriteInt32(streamId, #self.vehicleIds)
    for _, vehicleId in ipairs(self.vehicleIds) do
        streamWriteInt32(streamId, vehicleId)
    end
end

function TCEquipmentCooldownReleasedEvent:readStream(streamId, connection)
    self.vehicleIds = {}
    local count = streamReadInt32(streamId)
    for i = 1, count do
        self.vehicleIds[i] = streamReadInt32(streamId)
    end
    self:run(connection)
end

function TCEquipmentCooldownReleasedEvent:run(connection)
    g_currentMission.TheContractor.Cooldown:applyVehiclesReleased(self.vehicleIds)
end
