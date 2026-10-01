-- Broadcast-only: the server's progress reading for a serverMeasured job
-- (032 - tedder/bale/bale wrap/weed/hoe, whose progress is measured against
-- something only the server knows, see TCJobProgress), sent whenever it
-- moves by a whole percent. Clients just apply it. See src/events/README.md
-- for the general event conventions.

TCJobProgressEvent = {}
local TCJobProgressEvent_mt = Class(TCJobProgressEvent, Event)

InitEventClass(TCJobProgressEvent, "TCJobProgressEvent")

function TCJobProgressEvent.emptyNew()
    return Event.new(TCJobProgressEvent_mt)
end

function TCJobProgressEvent.new(farmId, jobId, completionPercentage)
    local self = TCJobProgressEvent.emptyNew()
    self.farmId = farmId
    self.jobId = jobId
    self.completionPercentage = completionPercentage
    return self
end

function TCJobProgressEvent:writeStream(streamId, connection)
    streamWriteInt32(streamId, self.farmId)
    streamWriteInt32(streamId, self.jobId)
    streamWriteFloat32(streamId, self.completionPercentage)
end

function TCJobProgressEvent:readStream(streamId, connection)
    self.farmId = streamReadInt32(streamId)
    self.jobId = streamReadInt32(streamId)
    self.completionPercentage = streamReadFloat32(streamId)
    self:run(connection)
end

function TCJobProgressEvent:run(connection)
    g_currentMission.TheContractor.Jobs:applyJobProgress(self.farmId, self.jobId, self.completionPercentage)
end
