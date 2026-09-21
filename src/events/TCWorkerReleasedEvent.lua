-- Broadcast-only: the server released a worker from a farm's roster (via
-- TheContractorStaff:releaseWorker, always triggered by server-side
-- application of TCReleaseWorkerEvent) and tells every client to drop it
-- from their local copy of that farm's roster. See src/events/README.md for
-- the general event conventions.

TCWorkerReleasedEvent = {}
local TCWorkerReleasedEvent_mt = Class(TCWorkerReleasedEvent, Event)

InitEventClass(TCWorkerReleasedEvent, "TCWorkerReleasedEvent")

function TCWorkerReleasedEvent.emptyNew()
    return Event.new(TCWorkerReleasedEvent_mt)
end

function TCWorkerReleasedEvent.new(farmId, workerId)
    local self = TCWorkerReleasedEvent.emptyNew()
    self.farmId = farmId
    self.workerId = workerId
    return self
end

function TCWorkerReleasedEvent:writeStream(streamId, connection)
    streamWriteInt32(streamId, self.farmId)
    streamWriteInt32(streamId, self.workerId)
end

function TCWorkerReleasedEvent:readStream(streamId, connection)
    self.farmId = streamReadInt32(streamId)
    self.workerId = streamReadInt32(streamId)
    self:run(connection)
end

function TCWorkerReleasedEvent:run(connection)
    g_currentMission.TheContractor.Staff:applyWorkerReleased(self.farmId, self.workerId)
end
