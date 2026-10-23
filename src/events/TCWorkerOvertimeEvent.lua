-- Broadcast-only (097): the overtime a farm's workers have built up this
-- month, sent by the server every game hour for those whose figures have
-- changed (TheContractorWorkingHours:syncOvertime), and when the month's
-- overtime is paid. See src/events/README.md for the general event
-- conventions.

TCWorkerOvertimeEvent = {}
local TCWorkerOvertimeEvent_mt = Class(TCWorkerOvertimeEvent, Event)

InitEventClass(TCWorkerOvertimeEvent, "TCWorkerOvertimeEvent")

function TCWorkerOvertimeEvent.emptyNew()
    return Event.new(TCWorkerOvertimeEvent_mt)
end

-- entries: { { workerId, minutes, owed } }
function TCWorkerOvertimeEvent.new(farmId, entries)
    local self = TCWorkerOvertimeEvent.emptyNew()
    self.farmId = farmId
    self.entries = entries
    return self
end

function TCWorkerOvertimeEvent:writeStream(streamId, connection)
    streamWriteInt32(streamId, self.farmId)
    streamWriteInt32(streamId, #self.entries)
    for _, entry in ipairs(self.entries) do
        streamWriteInt32(streamId, entry.workerId)
        streamWriteInt32(streamId, entry.minutes)
        streamWriteFloat32(streamId, entry.owed)
    end
end

function TCWorkerOvertimeEvent:readStream(streamId, connection)
    self.farmId = streamReadInt32(streamId)
    self.entries = {}
    for _ = 1, streamReadInt32(streamId) do
        table.insert(self.entries, {
            workerId = streamReadInt32(streamId),
            minutes = streamReadInt32(streamId),
            owed = streamReadFloat32(streamId),
        })
    end
    self:run(connection)
end

function TCWorkerOvertimeEvent:run(connection)
    local tc = g_currentMission.TheContractor
    for _, entry in ipairs(self.entries) do
        local worker = tc.Staff:getWorker(self.farmId, entry.workerId)
        if worker ~= nil then
            TheContractorWorkingHours.applyOvertime(worker, entry.minutes, entry.owed)
        end
    end
end
