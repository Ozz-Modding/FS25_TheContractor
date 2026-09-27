-- Broadcast-only: a period change gave some pool candidates/hired workers a
-- birthday (via TheContractorStaff:onPeriodChanged, 030 follow-up) and the
-- server sends every aged worker's id and new age in one batch. Ids are
-- unique across the pool and all rosters, so no farmId is needed. See
-- src/events/README.md for the general event conventions.

TCWorkersAgedEvent = {}
local TCWorkersAgedEvent_mt = Class(TCWorkersAgedEvent, Event)

InitEventClass(TCWorkersAgedEvent, "TCWorkersAgedEvent")

function TCWorkersAgedEvent.emptyNew()
    return Event.new(TCWorkersAgedEvent_mt)
end

-- aged is a list of { id = workerId, age = newAge }.
function TCWorkersAgedEvent.new(aged)
    local self = TCWorkersAgedEvent.emptyNew()
    self.aged = aged
    return self
end

function TCWorkersAgedEvent:writeStream(streamId, connection)
    streamWriteInt32(streamId, #self.aged)
    for _, entry in ipairs(self.aged) do
        streamWriteInt32(streamId, entry.id)
        streamWriteInt32(streamId, entry.age)
    end
end

function TCWorkersAgedEvent:readStream(streamId, connection)
    self.aged = {}
    local count = streamReadInt32(streamId)
    for _ = 1, count do
        local id = streamReadInt32(streamId)
        local age = streamReadInt32(streamId)
        table.insert(self.aged, { id = id, age = age })
    end
    self:run(connection)
end

function TCWorkersAgedEvent:run(connection)
    local staff = g_currentMission.TheContractor.Staff
    for _, entry in ipairs(self.aged) do
        staff:applyWorkerAged(entry.id, entry.age)
    end
end
