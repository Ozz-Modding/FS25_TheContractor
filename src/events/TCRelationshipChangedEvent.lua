-- Broadcast-only (113): the server has moved a farm's relationship with a
-- customer (TheContractorRelationships:adjust) and sends the absolute score,
-- which clients just apply. Changes only ever come from server-side job,
-- invoice and drift logic. See src/events/README.md.

TCRelationshipChangedEvent = {}
local TCRelationshipChangedEvent_mt = Class(TCRelationshipChangedEvent, Event)

InitEventClass(TCRelationshipChangedEvent, "TCRelationshipChangedEvent")

function TCRelationshipChangedEvent.emptyNew()
    return Event.new(TCRelationshipChangedEvent_mt)
end

function TCRelationshipChangedEvent.new(farmId, customerId, score)
    local self = TCRelationshipChangedEvent.emptyNew()
    self.farmId = farmId
    self.customerId = customerId
    self.score = score
    return self
end

function TCRelationshipChangedEvent:writeStream(streamId, connection)
    streamWriteInt32(streamId, self.farmId)
    streamWriteInt32(streamId, self.customerId)
    streamWriteInt32(streamId, self.score)
end

function TCRelationshipChangedEvent:readStream(streamId, connection)
    self.farmId = streamReadInt32(streamId)
    self.customerId = streamReadInt32(streamId)
    self.score = streamReadInt32(streamId)
    self:run(connection)
end

function TCRelationshipChangedEvent:run(connection)
    g_currentMission.TheContractor.Relationships:applyScore(self.farmId, self.customerId, self.score)
end
