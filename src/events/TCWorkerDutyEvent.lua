-- A worker kept on after hours, or sent home (097, TheContractorWorkingHours).
-- Sent by a client as a request (action and untilMinutes): the server
-- checks it (WorkingHours:requestDuty) and broadcasts the result, the same
-- event with the duty it set (all nil for none), which every client
-- applies. See src/events/README.md for the general event conventions.

TCWorkerDutyEvent = {}
local TCWorkerDutyEvent_mt = Class(TCWorkerDutyEvent, Event)

InitEventClass(TCWorkerDutyEvent, "TCWorkerDutyEvent")

function TCWorkerDutyEvent.emptyNew()
    return Event.new(TCWorkerDutyEvent_mt)
end

-- A request: (farmId, workerId, action, nil, nil, untilMinutes). The
-- server's answer fills in dutyFrom and dutyArrive.
function TCWorkerDutyEvent.new(farmId, workerId, action, dutyFrom, dutyArrive, dutyUntil)
    local self = TCWorkerDutyEvent.emptyNew()
    self.farmId = farmId
    self.workerId = workerId
    self.action = action
    self.dutyFrom = dutyFrom
    self.dutyArrive = dutyArrive
    self.dutyUntil = dutyUntil
    return self
end

local function writeOptionalInt(streamId, value)
    streamWriteBool(streamId, value ~= nil)
    if value ~= nil then
        streamWriteInt32(streamId, value)
    end
end

local function readOptionalInt(streamId)
    if streamReadBool(streamId) then
        return streamReadInt32(streamId)
    end
    return nil
end

function TCWorkerDutyEvent:writeStream(streamId, connection)
    streamWriteInt32(streamId, self.farmId)
    streamWriteInt32(streamId, self.workerId)
    streamWriteString(streamId, self.action)
    writeOptionalInt(streamId, self.dutyFrom)
    writeOptionalInt(streamId, self.dutyArrive)
    writeOptionalInt(streamId, self.dutyUntil)
end

function TCWorkerDutyEvent:readStream(streamId, connection)
    self.farmId = streamReadInt32(streamId)
    self.workerId = streamReadInt32(streamId)
    self.action = streamReadString(streamId)
    self.dutyFrom = readOptionalInt(streamId)
    self.dutyArrive = readOptionalInt(streamId)
    self.dutyUntil = readOptionalInt(streamId)
    self:run(connection)
end

function TCWorkerDutyEvent:run(connection)
    local tc = g_currentMission.TheContractor
    if g_currentMission:getIsServer() then
        tc.WorkingHours:requestDuty(self.farmId, self.workerId, self.action, self.dutyUntil)
        return
    end
    local worker = tc.Staff:getWorker(self.farmId, self.workerId)
    if worker ~= nil then
        TheContractorWorkingHours.applyDuty(worker, self.dutyFrom, self.dutyArrive, self.dutyUntil)
    end
end
