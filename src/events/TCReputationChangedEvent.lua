-- Broadcast-only: the server computes and clamps a new reputation score
-- (via TheContractorReputation:addReputation) and sends the resulting
-- absolute score to other clients, who just apply it directly. There's no
-- client -> server request branch here — reputation changes are always
-- triggered by server-side business logic (job completion, missed jobs,
-- etc.), never by a direct player action. See src/events/README.md for the
-- general event conventions.

TCReputationChangedEvent = {}
local TCReputationChangedEvent_mt = Class(TCReputationChangedEvent, Event)

InitEventClass(TCReputationChangedEvent, "TCReputationChangedEvent")

function TCReputationChangedEvent.emptyNew()
    return Event.new(TCReputationChangedEvent_mt)
end

function TCReputationChangedEvent.new(farmId, score)
    local self = TCReputationChangedEvent.emptyNew()
    self.farmId = farmId
    self.score = score
    return self
end

function TCReputationChangedEvent:writeStream(streamId, connection)
    streamWriteInt32(streamId, self.farmId)
    streamWriteInt32(streamId, self.score)
end

function TCReputationChangedEvent:readStream(streamId, connection)
    self.farmId = streamReadInt32(streamId)
    self.score = streamReadInt32(streamId)
    self:run(connection)
end

function TCReputationChangedEvent:run(connection)
    g_currentMission.TheContractor.Reputation:applyReputationScore(self.farmId, self.score)
end
