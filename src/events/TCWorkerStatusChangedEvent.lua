-- Broadcast-only: the server flips a hired worker's status (via
-- TheContractorStaff:setWorkerStatus — first triggered by allocation, 018,
-- flipping idle -> assigned; later tickets, 022/023, will flip it back) and
-- sends just the changed field to every client, rather than a full worker
-- snapshot — status is the only thing this ever moves on its own. See
-- src/events/README.md for the general event conventions.

TCWorkerStatusChangedEvent = {}
local TCWorkerStatusChangedEvent_mt = Class(TCWorkerStatusChangedEvent, Event)

InitEventClass(TCWorkerStatusChangedEvent, "TCWorkerStatusChangedEvent")

function TCWorkerStatusChangedEvent.emptyNew()
    return Event.new(TCWorkerStatusChangedEvent_mt)
end

function TCWorkerStatusChangedEvent.new(farmId, workerId, status)
    local self = TCWorkerStatusChangedEvent.emptyNew()
    self.farmId = farmId
    self.workerId = workerId
    self.status = status
    return self
end

function TCWorkerStatusChangedEvent:writeStream(streamId, connection)
    streamWriteInt32(streamId, self.farmId)
    streamWriteInt32(streamId, self.workerId)
    streamWriteString(streamId, self.status)
end

function TCWorkerStatusChangedEvent:readStream(streamId, connection)
    self.farmId = streamReadInt32(streamId)
    self.workerId = streamReadInt32(streamId)
    self.status = streamReadString(streamId)
    self:run(connection)
end

function TCWorkerStatusChangedEvent:run(connection)
    g_currentMission.TheContractor.Staff:applyWorkerStatusChanged(self.farmId, self.workerId, self.status)
end
