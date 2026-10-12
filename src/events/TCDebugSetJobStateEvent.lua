-- Console-command-only: request half of `tcJob state` (Jobs.lua's
-- registerConsoleCommands). Client -> server request - the server applies
-- via TheContractorJobs:forceJobState, which validates against the job's
-- state machine and sends completed/missed through the real completeJob/
-- missJob (payout or penalty, AI stopped, crew and machines released);
-- other states are a plain transitionJobState. See src/events/README.md
-- for the general event conventions.

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
        g_currentMission.TheContractor.Jobs:forceJobState(self.farmId, self.jobId, self.state)
    end
end
