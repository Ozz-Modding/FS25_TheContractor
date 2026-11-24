-- A player at the show (171) talks to a farmer, asks them for work, joins
-- the association at its stall or leaves their details at the careers
-- stand: client -> server as a request, the server's answer back to that
-- client alone (as TCConsoleEvent's). The server checks everything again
-- (ShowStands:handleRequest); the visits themselves reach every machine in
-- TCShowStandsEvent. The host's own requests never come through here
-- (TCShowStandsWorld.request calls the server directly).

TCShowTalkEvent = {}
local TCShowTalkEvent_mt = Class(TCShowTalkEvent, Event)

InitEventClass(TCShowTalkEvent, "TCShowTalkEvent")

function TCShowTalkEvent.emptyNew()
    return Event.new(TCShowTalkEvent_mt)
end

-- Client to server. request: a TCShowStands.REQUEST; personId: the farmer
-- (0 for a stall); token: the client's, sent back with the answer.
function TCShowTalkEvent.newRequest(farmId, request, personId, token)
    local self = TCShowTalkEvent.emptyNew()
    self.isAnswer = false
    self.farmId = farmId
    self.request = request
    self.personId = personId or 0
    self.token = token or 0
    return self
end

-- Server to that client: a TCShowStands.ANSWER and its value.
function TCShowTalkEvent.newAnswer(request, token, answer, value)
    local self = TCShowTalkEvent.emptyNew()
    self.isAnswer = true
    self.request = request
    self.token = token or 0
    self.answer = answer
    self.value = value or 0
    return self
end

function TCShowTalkEvent:writeStream(streamId, connection)
    streamWriteBool(streamId, self.isAnswer)
    streamWriteUInt8(streamId, self.request)
    streamWriteInt32(streamId, self.token)
    if self.isAnswer then
        streamWriteUInt8(streamId, self.answer)
        streamWriteInt32(streamId, self.value)
    else
        streamWriteInt32(streamId, self.farmId)
        streamWriteInt32(streamId, self.personId)
    end
end

function TCShowTalkEvent:readStream(streamId, connection)
    self.isAnswer = streamReadBool(streamId)
    self.request = streamReadUInt8(streamId)
    self.token = streamReadInt32(streamId)
    if self.isAnswer then
        self.answer = streamReadUInt8(streamId)
        self.value = streamReadInt32(streamId)
    else
        self.farmId = streamReadInt32(streamId)
        self.personId = streamReadInt32(streamId)
    end
    self:run(connection)
end

-- The farm a request's player is on.
local function getConnectionFarmId(connection)
    local player = g_currentMission.connectionsToPlayer ~= nil and g_currentMission.connectionsToPlayer[connection] or
        nil
    if player ~= nil then
        return player.farmId
    end
    return g_currentMission:getFarmId()
end

function TCShowTalkEvent:run(connection)
    if self.isAnswer then
        if connection:getIsServer() and TCShowStandsWorld ~= nil then
            TCShowStandsWorld.onAnswer(self.request, self.token, self.answer, self.value)
        end
        return
    end
    local tc = g_currentMission.TheContractor
    if connection:getIsServer() or tc == nil or tc.ShowStands == nil then
        return
    end
    -- A player asks for their own farm only.
    if getConnectionFarmId(connection) ~= self.farmId then
        return
    end
    local answer, value = tc.ShowStands:handleRequest(self.farmId, self.request,
        self.personId > 0 and self.personId or nil)
    connection:sendEvent(TCShowTalkEvent.newAnswer(self.request, self.token, answer, value))
end
