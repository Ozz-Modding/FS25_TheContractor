-- Broadcast-only: the server starts a post-completion buffer (via
-- TheContractorCooldown:startCooldown, 023) and sends the full cooldown
-- entry to every client so they hide the same equipment - hiding/revealing
-- a vehicle (removeFromPhysics/setVisibility) is local rendering/physics
-- state the base game never networks on its own, unlike a vehicle's
-- position. See src/events/README.md for the general event conventions.

TCEquipmentCooldownStartedEvent = {}
local TCEquipmentCooldownStartedEvent_mt = Class(TCEquipmentCooldownStartedEvent, Event)

InitEventClass(TCEquipmentCooldownStartedEvent, "TCEquipmentCooldownStartedEvent")

function TCEquipmentCooldownStartedEvent.emptyNew()
    return Event.new(TCEquipmentCooldownStartedEvent_mt)
end

function TCEquipmentCooldownStartedEvent.new(entry)
    local self = TCEquipmentCooldownStartedEvent.emptyNew()
    self.entry = entry
    return self
end

function TCEquipmentCooldownStartedEvent:writeStream(streamId, connection)
    TheContractorCooldown.writeEntry(streamId, self.entry)
end

function TCEquipmentCooldownStartedEvent:readStream(streamId, connection)
    self.entry = TheContractorCooldown.readEntry(streamId)
    self:run(connection)
end

function TCEquipmentCooldownStartedEvent:run(connection)
    g_currentMission.TheContractor.Cooldown:applyCooldownStarted(self.entry)
end
