-- Cheat-command-only: request half of the tcSetJobState console command
-- (see main.lua). Client -> server request — the server applies via
-- TheContractorJobs:transitionJobState, which validates against the job's
-- state machine, applies, and broadcasts TCJobStateChangedEvent to other
-- clients. Lets state-machine transitions be exercised manually before 018
-- (allocation)/019 (progress)/022 (completion)/024 (missed) exist to drive
-- them for real. See src/events/README.md for the general event
-- conventions.

TCDebugSetJobStateEvent = {}
local TCDebugSetJobStateEvent_mt = Class(TCDebugSetJobStateEvent, Event)

InitEventClass(TCDebugSetJobStateEvent, "TCDebugSetJobStateEvent")

function TCDebugSetJobStateEvent.emptyNew()
    return Event.new(TCDebugSetJobStateEvent_mt)
end

function TCDebugSetJobStateEvent.new(farmId, jobId, state)
    local self = TCDebugSetJobStateEvent.emptyNew()
    self.farmId = farmId
    self.jobId = jobId
    self.state = state
    return self
end

function TCDebugSetJobStateEvent:writeStream(streamId, connection)
    streamWriteInt32(streamId, self.farmId)
    streamWriteInt32(streamId, self.jobId)
    streamWriteString(streamId, self.state)
end

function TCDebugSetJobStateEvent:readStream(streamId, connection)
    self.farmId = streamReadInt32(streamId)
    self.jobId = streamReadInt32(streamId)
    self.state = streamReadString(streamId)
    self:run(connection)
end

function TCDebugSetJobStateEvent:run(connection)
    if g_currentMission:getIsServer() then
        g_currentMission.TheContractor.Jobs:transitionJobState(self.farmId, self.jobId, self.state)
    end
end
