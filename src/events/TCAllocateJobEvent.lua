-- Client requests allocating a crew (workerIds - empty for "do it myself",
-- two for a two-worker haulage job, see TheContractorAllocation's Crew
-- section) plus a set of equipment vehicle ids, and for a haulage crew the
-- haulage rig's ids, to one of its farm's `accepted` jobs. The server is
-- the sole arbiter of whether the job/workers/equipment are all still free
-- — this is the MP double-booking race point between clients on the same
-- farm (see TheContractorAllocation:allocateJob's re-check-then-act shape,
-- same pattern as TCHireWorkerEvent's pool race). Id lists travel the same
-- comma-joined-string wire shape TheContractorJobs.writeJob already uses
-- for a job's own assignedEquipmentIds. fixedRoles: the player chose who
-- operates (workerIds[1]) and who hauls (workerIds[2]) rather than leaving
-- it to TheContractorAllocation:assignCrewRoles. See src/events/README.md
-- for the general event conventions.

TCAllocateJobEvent = {}
local TCAllocateJobEvent_mt = Class(TCAllocateJobEvent, Event)

InitEventClass(TCAllocateJobEvent, "TCAllocateJobEvent")

function TCAllocateJobEvent.emptyNew()
    return Event.new(TCAllocateJobEvent_mt)
end

function TCAllocateJobEvent.new(farmId, jobId, workerIds, equipmentIds, haulageEquipmentIds, fixedRoles)
    local self = TCAllocateJobEvent.emptyNew()
    self.farmId = farmId
    self.jobId = jobId
    self.workerIds = workerIds
    self.equipmentIds = equipmentIds
    self.haulageEquipmentIds = haulageEquipmentIds
    self.fixedRoles = fixedRoles == true
    return self
end

function TCAllocateJobEvent:writeStream(streamId, connection)
    streamWriteInt32(streamId, self.farmId)
    streamWriteInt32(streamId, self.jobId)
    streamWriteString(streamId, TheContractorJobs.encodeIdList(self.workerIds))
    streamWriteString(streamId, TheContractorJobs.encodeIdList(self.equipmentIds))
    streamWriteString(streamId, TheContractorJobs.encodeIdList(self.haulageEquipmentIds))
    streamWriteBool(streamId, self.fixedRoles)
end

function TCAllocateJobEvent:readStream(streamId, connection)
    self.farmId = streamReadInt32(streamId)
    self.jobId = streamReadInt32(streamId)
    self.workerIds = TheContractorJobs.decodeIdList(streamReadString(streamId))
    self.equipmentIds = TheContractorJobs.decodeIdList(streamReadString(streamId))
    self.haulageEquipmentIds = TheContractorJobs.decodeIdList(streamReadString(streamId))
    self.fixedRoles = streamReadBool(streamId)

    self:run(connection)
end

function TCAllocateJobEvent:run(connection)
    if g_currentMission:getIsServer() then
        g_currentMission.TheContractor.Allocation:allocateJob(self.farmId, self.jobId, self.workerIds,
            self.equipmentIds, self.haulageEquipmentIds, self.fixedRoles)
    end
end
