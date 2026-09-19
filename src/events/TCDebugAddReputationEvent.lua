-- Cheat-command-only: request half of the tcAddReputation console command
-- (see main.lua). Unlike TCReputationChangedEvent (the server -> client
-- broadcast of a resulting score), this is a client -> server request —
-- the server applies the delta via Reputation:addReputation, which itself
-- clamps and broadcasts the result to other clients. See
-- src/events/README.md for the general event conventions.

TCDebugAddReputationEvent = {}
local TCDebugAddReputationEvent_mt = Class(TCDebugAddReputationEvent, Event)

InitEventClass(TCDebugAddReputationEvent, "TCDebugAddReputationEvent")

function TCDebugAddReputationEvent.emptyNew()
    return Event.new(TCDebugAddReputationEvent_mt)
end

function TCDebugAddReputationEvent.new(farmId, delta)
    local self = TCDebugAddReputationEvent.emptyNew()
    self.farmId = farmId
    self.delta = delta
    return self
end

function TCDebugAddReputationEvent:writeStream(streamId, connection)
    streamWriteInt32(streamId, self.farmId)
    streamWriteInt32(streamId, self.delta)
end

function TCDebugAddReputationEvent:readStream(streamId, connection)
    self.farmId = streamReadInt32(streamId)
    self.delta = streamReadInt32(streamId)
    self:run(connection)
end

function TCDebugAddReputationEvent:run(connection)
    if g_currentMission:getIsServer() then
        g_currentMission.TheContractor.Reputation:addReputation(self.farmId, self.delta)
    end
end
