-- A player at the show's breeders' pen (173) buys an animal: client ->
-- server as a request (the animal's key, the trailer or husbandry it's to
-- go to), the server's answer back to that client alone (as
-- TCShowTalkEvent's). The server checks everything again
-- (BreedersPen:handleBuy) and RealisticLivestock moves the animal; the
-- trailers' contents reach every machine through RL's own sync. The
-- server's own player never comes through here (TCBreedersPenWorld.request
-- calls it directly).

TCBreederBuyEvent = {}
local TCBreederBuyEvent_mt = Class(TCBreederBuyEvent, Event)

InitEventClass(TCBreederBuyEvent, "TCBreederBuyEvent")

function TCBreederBuyEvent.emptyNew()
    return Event.new(TCBreederBuyEvent_mt)
end

-- Client to server. key: the animal's (TCRealisticLivestock.getAPIKey);
-- targetId: the place's object id; token: the client's, sent back.
function TCBreederBuyEvent.newRequest(farmId, key, targetId, token)
    local self = TCBreederBuyEvent.emptyNew()
    self.isAnswer = false
    self.farmId = farmId
    self.key = key
    self.targetId = targetId
    self.token = token or 0
    return self
end

-- Server to that client: a TCBreedersPen.ANSWER and what was paid.
function TCBreederBuyEvent.newAnswer(token, answer, value)
    local self = TCBreederBuyEvent.emptyNew()
    self.isAnswer = true
    self.token = token or 0
    self.answer = answer
    self.value = value or 0
    return self
end

function TCBreederBuyEvent:writeStream(streamId, connection)
    streamWriteBool(streamId, self.isAnswer)
    streamWriteInt32(streamId, self.token)
    if self.isAnswer then
        streamWriteUInt8(streamId, self.answer)
        streamWriteInt32(streamId, self.value)
    else
        streamWriteInt32(streamId, self.farmId)
        streamWriteString(streamId, self.key or "")
        streamWriteInt32(streamId, self.targetId or 0)
    end
end

function TCBreederBuyEvent:readStream(streamId, connection)
    self.isAnswer = streamReadBool(streamId)
    self.token = streamReadInt32(streamId)
    if self.isAnswer then
        self.answer = streamReadUInt8(streamId)
        self.value = streamReadInt32(streamId)
    else
        self.farmId = streamReadInt32(streamId)
        self.key = streamReadString(streamId)
        self.targetId = streamReadInt32(streamId)
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

function TCBreederBuyEvent:run(connection)
    if self.isAnswer then
        if connection:getIsServer() and TCBreedersPenWorld ~= nil then
            TCBreedersPenWorld.onAnswer(self.token, self.answer, self.value)
        end
        return
    end
    local tc = g_currentMission.TheContractor
    if connection:getIsServer() or tc == nil or tc.BreedersPen == nil then
        return
    end
    -- A player buys for their own farm only.
    if getConnectionFarmId(connection) ~= self.farmId then
        return
    end
    local answer, value = tc.BreedersPen:handleBuy(self.farmId, self.key, self.targetId, connection)
    connection:sendEvent(TCBreederBuyEvent.newAnswer(self.token, answer, value))
end
