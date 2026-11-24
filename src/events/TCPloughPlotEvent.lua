-- Client -> server (169): a player takes a ploughing plot for their farm at
-- its start peg, or says their run on it's finished. The server checks it
-- (PloughingMatch:getTakeProblem/getFinishProblem, as the prompt did before
-- sending), applies it and sends every machine the match
-- (TCPloughMatchEvent). The requester never reads the answer straight back.

TCPloughPlotEvent = {}
local TCPloughPlotEvent_mt = Class(TCPloughPlotEvent, Event)

InitEventClass(TCPloughPlotEvent, "TCPloughPlotEvent")

TCPloughPlotEvent.TAKE = 1
TCPloughPlotEvent.FINISH = 2

function TCPloughPlotEvent.emptyNew()
    return Event.new(TCPloughPlotEvent_mt)
end

function TCPloughPlotEvent.new(action, number, farmId)
    local self = TCPloughPlotEvent.emptyNew()
    self.action = action
    self.number = number
    self.farmId = farmId
    return self
end

function TCPloughPlotEvent:writeStream(streamId, connection)
    streamWriteUInt8(streamId, self.action)
    streamWriteUInt8(streamId, self.number)
    streamWriteInt32(streamId, self.farmId)
end

function TCPloughPlotEvent:readStream(streamId, connection)
    self.action = streamReadUInt8(streamId)
    self.number = streamReadUInt8(streamId)
    self.farmId = streamReadInt32(streamId)
    self:run(connection)
end

-- The farm a request's player is on (single player and the host's own
-- requests: the local player's farm).
local function getConnectionFarmId(connection)
    local player = g_currentMission.connectionsToPlayer ~= nil and g_currentMission.connectionsToPlayer[connection] or
        nil
    if player ~= nil then
        return player.farmId
    end
    return g_currentMission:getFarmId()
end

function TCPloughPlotEvent:run(connection)
    if connection:getIsServer() then
        return
    end
    local match = g_currentMission.TheContractor ~= nil and g_currentMission.TheContractor.PloughingMatch or nil
    -- A player takes a plot for their own farm only.
    if match == nil or getConnectionFarmId(connection) ~= self.farmId then
        return
    end
    if self.action == TCPloughPlotEvent.TAKE then
        match:takePlot(self.number, self.farmId)
    elseif self.action == TCPloughPlotEvent.FINISH then
        match:finishPlot(self.number, self.farmId)
    end
end
