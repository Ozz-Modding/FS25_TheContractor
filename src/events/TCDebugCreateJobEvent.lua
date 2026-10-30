-- Cheat-command-only: request half of the tcCreateTestJob console command
-- (see main.lua). Client -> server request — the server applies via
-- TheContractorJobs:createJob, which itself registers the job and
-- broadcasts TCJobCreatedEvent to other clients. Exists because job
-- creation is otherwise always server-side business logic (011), and this
-- debug command needs a way in from a client machine. See
-- src/events/README.md for the general event conventions.

TCDebugCreateJobEvent = {}
local TCDebugCreateJobEvent_mt = Class(TCDebugCreateJobEvent, Event)

InitEventClass(TCDebugCreateJobEvent, "TCDebugCreateJobEvent")

function TCDebugCreateJobEvent.emptyNew()
    return Event.new(TCDebugCreateJobEvent_mt)
end

function TCDebugCreateJobEvent.new(farmId, jobType, fieldId, requiredSkillLevel, targetPeriod, targetDayInPeriod,
                                    price)
    local self = TCDebugCreateJobEvent.emptyNew()
    self.farmId = farmId
    self.jobType = jobType
    self.fieldId = fieldId
    self.requiredSkillLevel = requiredSkillLevel
    self.targetPeriod = targetPeriod
    self.targetDayInPeriod = targetDayInPeriod
    self.price = price
    return self
end

function TCDebugCreateJobEvent:writeStream(streamId, connection)
    streamWriteInt32(streamId, self.farmId)
    streamWriteString(streamId, self.jobType)
    streamWriteInt32(streamId, self.fieldId)
    streamWriteInt32(streamId, self.requiredSkillLevel)
    streamWriteInt32(streamId, self.targetPeriod)
    streamWriteInt32(streamId, self.targetDayInPeriod)
    streamWriteFloat32(streamId, self.price)
end

function TCDebugCreateJobEvent:readStream(streamId, connection)
    self.farmId = streamReadInt32(streamId)
    self.jobType = streamReadString(streamId)
    self.fieldId = streamReadInt32(streamId)
    self.requiredSkillLevel = streamReadInt32(streamId)
    self.targetPeriod = streamReadInt32(streamId)
    self.targetDayInPeriod = streamReadInt32(streamId)
    self.price = streamReadFloat32(streamId)
    self:run(connection)
end

function TCDebugCreateJobEvent:run(connection)
    if g_currentMission:getIsServer() then
        -- Compute the real equipmentAvailable flag the same way 011's
        -- generation engine does, rather than leaving it unset — Job.new()'s
        -- default (true) meant every debug-created job showed "Yes" in the
        -- Inbox's Equip. column regardless of what the farm actually owned,
        -- which is misleading for testing that exact column.
        local jobDef = TheContractorJobGeneration.JOB_TYPES[self.jobType]
        local field = g_fieldManager:getFieldById(self.fieldId)
        local equipmentAvailable = nil
        local fruitTypeName = nil
        local startState = nil
        if jobDef ~= nil then
            fruitTypeName = TheContractorJobGeneration.getRecordedFruitTypeName(field, jobDef)
            startState = TheContractorJobGeneration.getFieldStartState(field, jobDef)
            equipmentAvailable = g_currentMission.TheContractor.JobGeneration:canFulfill(self.farmId, jobDef,
                TheContractorJobGeneration.getFruitTypeIndexByName(fruitTypeName))
        end

        g_currentMission.TheContractor.Jobs:createJob(self.farmId, self.jobType, self.fieldId,
            self.requiredSkillLevel, self.targetPeriod, self.targetDayInPeriod, self.price, equipmentAvailable,
            fruitTypeName, nil, nil, nil, startState)
    end
end
