-- A worker gone on a break (131, TheContractorBreaks), until breakUntil
-- (absolute game minutes). Server to clients only: the server decides when
-- breaks start, and the end is worked out from the time on every machine,
-- so nothing is sent then. See src/events/README.md for the general event
-- conventions.

TCWorkerBreakEvent = {}
local TCWorkerBreakEvent_mt = Class(TCWorkerBreakEvent, Event)

InitEventClass(TCWorkerBreakEvent, "TCWorkerBreakEvent")

function TCWorkerBreakEvent.emptyNew()
    return Event.new(TCWorkerBreakEvent_mt)
end

function TCWorkerBreakEvent.new(farmId, workerId, breakUntil)
    local self = TCWorkerBreakEvent.emptyNew()
    self.farmId = farmId
    self.workerId = workerId
    self.breakUntil = breakUntil
    return self
end

function TCWorkerBreakEvent:writeStream(streamId, connection)
    streamWriteInt32(streamId, self.farmId)
    streamWriteInt32(streamId, self.workerId)
    streamWriteInt32(streamId, self.breakUntil)
end

function TCWorkerBreakEvent:readStream(streamId, connection)
    self.farmId = streamReadInt32(streamId)
    self.workerId = streamReadInt32(streamId)
    self.breakUntil = streamReadInt32(streamId)
    self:run(connection)
end

function TCWorkerBreakEvent:run(connection)
    if g_currentMission:getIsServer() then
        return
    end
    local worker = g_currentMission.TheContractor.Staff:getWorker(self.farmId, self.workerId)
    if worker ~= nil then
        TheContractorBreaks.applyBreak(worker, self.breakUntil)
    end
end
