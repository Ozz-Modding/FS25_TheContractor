-- Client requests allocating a worker (or nil, "do it myself") plus a set of
-- equipment vehicle ids to one of its farm's `accepted` jobs. The server is
-- the sole arbiter of whether the job/worker/equipment are all still free —
-- this is the MP double-booking race point between clients on the same farm
-- (see TheContractorAllocation:allocateJob's re-check-then-act shape, same
-- pattern as TCHireWorkerEvent's pool race). equipmentIds travels the same
-- comma-joined-string wire shape TheContractorJobs.writeJob already uses for
-- a job's own assignedEquipmentIds. See src/events/README.md for the general
-- event conventions.

TCAllocateJobEvent = {}
local TCAllocateJobEvent_mt = Class(TCAllocateJobEvent, Event)

InitEventClass(TCAllocateJobEvent, "TCAllocateJobEvent")

function TCAllocateJobEvent.emptyNew()
    return Event.new(TCAllocateJobEvent_mt)
end

function TCAllocateJobEvent.new(farmId, jobId, workerId, equipmentIds)
    local self = TCAllocateJobEvent.emptyNew()
    self.farmId = farmId
    self.jobId = jobId
    self.workerId = workerId
    self.equipmentIds = equipmentIds
    return self
end

function TCAllocateJobEvent:writeStream(streamId, connection)
    streamWriteInt32(streamId, self.farmId)
    streamWriteInt32(streamId, self.jobId)

    streamWriteBool(streamId, self.workerId ~= nil)
    if self.workerId ~= nil then
        streamWriteInt32(streamId, self.workerId)
    end

    streamWriteString(streamId, TheContractorJobs.encodeIdList(self.equipmentIds))
end

function TCAllocateJobEvent:readStream(streamId, connection)
    self.farmId = streamReadInt32(streamId)
    self.jobId = streamReadInt32(streamId)

    if streamReadBool(streamId) then
        self.workerId = streamReadInt32(streamId)
    end

    self.equipmentIds = TheContractorJobs.decodeIdList(streamReadString(streamId))

    self:run(connection)
end

function TCAllocateJobEvent:run(connection)
    if g_currentMission:getIsServer() then
        g_currentMission.TheContractor.Allocation:allocateJob(self.farmId, self.jobId, self.workerId,
            self.equipmentIds)
    end
end
