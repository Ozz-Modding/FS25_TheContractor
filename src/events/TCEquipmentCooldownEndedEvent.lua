-- Broadcast-only: the server ends a buffer, on schedule (via
-- TheContractorCooldown:endCooldown, 023, driven by its own update(dt)) and
-- tells every client to reveal the same equipment. Just the farmId/
-- cooldownId pair, not a full entry snapshot - applyCooldownEnded already
-- has the vehicle ids on hand locally (self.entriesByFarm), same
-- "broadcast the minimum, look the rest up locally" shape
-- TCWorkerStatusChangedEvent uses. See src/events/README.md for the general
-- event conventions.

TCEquipmentCooldownEndedEvent = {}
local TCEquipmentCooldownEndedEvent_mt = Class(TCEquipmentCooldownEndedEvent, Event)

InitEventClass(TCEquipmentCooldownEndedEvent, "TCEquipmentCooldownEndedEvent")

function TCEquipmentCooldownEndedEvent.emptyNew()
    return Event.new(TCEquipmentCooldownEndedEvent_mt)
end

function TCEquipmentCooldownEndedEvent.new(farmId, cooldownId)
    local self = TCEquipmentCooldownEndedEvent.emptyNew()
    self.farmId = farmId
    self.cooldownId = cooldownId
    return self
end

function TCEquipmentCooldownEndedEvent:writeStream(streamId, connection)
    streamWriteInt32(streamId, self.farmId)
    streamWriteInt32(streamId, self.cooldownId)
end

function TCEquipmentCooldownEndedEvent:readStream(streamId, connection)
    self.farmId = streamReadInt32(streamId)
    self.cooldownId = streamReadInt32(streamId)
    self:run(connection)
end

function TCEquipmentCooldownEndedEvent:run(connection)
    g_currentMission.TheContractor.Cooldown:applyCooldownEnded(self.farmId, self.cooldownId)
end
