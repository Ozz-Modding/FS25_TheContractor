-- Client requests hiring a specific candidate (by id) from the shared staff
-- pool for its farm. The server is the sole arbiter of whether that
-- candidate is still available — this is the MP "race to hire" point (see
-- Staff.lua's file header): if two farms request the same candidateId, the
-- server processes them in order and only the first actually hires anyone,
-- via TheContractorStaff:hireWorker re-checking pool membership itself.
-- See src/events/README.md for the general event conventions.

TCHireWorkerEvent = {}
local TCHireWorkerEvent_mt = Class(TCHireWorkerEvent, Event)

InitEventClass(TCHireWorkerEvent, "TCHireWorkerEvent")

function TCHireWorkerEvent.emptyNew()
    return Event.new(TCHireWorkerEvent_mt)
end

function TCHireWorkerEvent.new(farmId, candidateId)
    local self = TCHireWorkerEvent.emptyNew()
    self.farmId = farmId
    self.candidateId = candidateId
    return self
end

function TCHireWorkerEvent:writeStream(streamId, connection)
    streamWriteInt32(streamId, self.farmId)
    streamWriteInt32(streamId, self.candidateId)
end

function TCHireWorkerEvent:readStream(streamId, connection)
    self.farmId = streamReadInt32(streamId)
    self.candidateId = streamReadInt32(streamId)
    self:run(connection)
end

function TCHireWorkerEvent:run(connection)
    if g_currentMission:getIsServer() then
        g_currentMission.TheContractor.Staff:hireWorker(self.farmId, self.candidateId)
    end
end
