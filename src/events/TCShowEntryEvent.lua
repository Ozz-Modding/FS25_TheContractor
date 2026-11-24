-- Client -> server (167): a farm enters an animal (or a herd) in a show
-- class, or withdraws an entry. The server checks it
-- (ShowLivestock:getEntryProblem, as the menu did before sending), applies
-- it and sends every machine the entries (TCShowLivestockEvent). 170: or
-- enters one of its workers in the ploughing match, or withdraws them
-- (ShowWorker:getEntryProblem; every machine gets TCShowWorkerEvent). The
-- requester never reads its entry straight back after sending.

TCShowEntryEvent = {}
local TCShowEntryEvent_mt = Class(TCShowEntryEvent, Event)

InitEventClass(TCShowEntryEvent, "TCShowEntryEvent")

TCShowEntryEvent.ENTER = 1
TCShowEntryEvent.WITHDRAW = 2
TCShowEntryEvent.ENTER_WORKER = 3
TCShowEntryEvent.WITHDRAW_WORKER = 4

function TCShowEntryEvent.emptyNew()
    return Event.new(TCShowEntryEvent_mt)
end

-- husbandryId: the husbandry's network object id; animalKey: RL's key, or
-- nil for a vanilla animal or a herd.
function TCShowEntryEvent.newEnter(farmId, classKey, husbandryId, animalKey)
    local self = TCShowEntryEvent.emptyNew()
    self.action = TCShowEntryEvent.ENTER
    self.farmId = farmId
    self.classKey = classKey
    self.husbandryId = husbandryId
    self.animalKey = animalKey
    return self
end

function TCShowEntryEvent.newWithdraw(farmId, entryId)
    local self = TCShowEntryEvent.emptyNew()
    self.action = TCShowEntryEvent.WITHDRAW
    self.farmId = farmId
    self.entryId = entryId
    return self
end

-- 170.
function TCShowEntryEvent.newEnterWorker(farmId, workerId)
    local self = TCShowEntryEvent.emptyNew()
    self.action = TCShowEntryEvent.ENTER_WORKER
    self.farmId = farmId
    self.workerId = workerId
    return self
end

function TCShowEntryEvent.newWithdrawWorker(farmId)
    local self = TCShowEntryEvent.emptyNew()
    self.action = TCShowEntryEvent.WITHDRAW_WORKER
    self.farmId = farmId
    return self
end

function TCShowEntryEvent:writeStream(streamId, connection)
    streamWriteUInt8(streamId, self.action)
    streamWriteInt32(streamId, self.farmId)
    if self.action == TCShowEntryEvent.ENTER then
        streamWriteString(streamId, self.classKey)
        streamWriteInt32(streamId, self.husbandryId or -1)
        streamWriteString(streamId, self.animalKey or "")
    elseif self.action == TCShowEntryEvent.WITHDRAW then
        streamWriteInt32(streamId, self.entryId)
    elseif self.action == TCShowEntryEvent.ENTER_WORKER then
        streamWriteInt32(streamId, self.workerId)
    end
end

function TCShowEntryEvent:readStream(streamId, connection)
    self.action = streamReadUInt8(streamId)
    self.farmId = streamReadInt32(streamId)
    if self.action == TCShowEntryEvent.ENTER then
        self.classKey = streamReadString(streamId)
        local husbandryId = streamReadInt32(streamId)
        self.husbandryId = husbandryId >= 0 and husbandryId or nil
        local animalKey = streamReadString(streamId)
        self.animalKey = animalKey ~= "" and animalKey or nil
    elseif self.action == TCShowEntryEvent.WITHDRAW then
        self.entryId = streamReadInt32(streamId)
    elseif self.action == TCShowEntryEvent.ENTER_WORKER then
        self.workerId = streamReadInt32(streamId)
    end
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

function TCShowEntryEvent:run(connection)
    if connection:getIsServer() then
        return
    end
    local tc = g_currentMission.TheContractor
    -- A player enters for their own farm only.
    if tc == nil or getConnectionFarmId(connection) ~= self.farmId then
        return
    end
    if self.action == TCShowEntryEvent.ENTER_WORKER or self.action == TCShowEntryEvent.WITHDRAW_WORKER then
        if tc.ShowWorker == nil then
            return
        end
        if self.action == TCShowEntryEvent.ENTER_WORKER then
            tc.ShowWorker:enter(self.farmId, self.workerId)
        else
            tc.ShowWorker:withdraw(self.farmId)
        end
        return
    end
    local livestock = tc.ShowLivestock
    if livestock == nil then
        return
    end
    if self.action == TCShowEntryEvent.ENTER then
        livestock:enter(self.farmId, self.classKey, self.husbandryId, self.animalKey)
    elseif self.action == TCShowEntryEvent.WITHDRAW then
        livestock:withdraw(self.farmId, self.entryId)
    end
end
