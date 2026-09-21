-- Broadcast-only: the server hires a candidate out of the shared staff pool
-- (via TheContractorStaff:hireWorker — always triggered by server-side
-- application of TCHireWorkerEvent) and sends the full worker snapshot to
-- every client, who move it from their local copy of the pool into that
-- farm's roster via applyWorkerHired. See src/events/README.md for the
-- general event conventions.

TCWorkerHiredEvent = {}
local TCWorkerHiredEvent_mt = Class(TCWorkerHiredEvent, Event)

InitEventClass(TCWorkerHiredEvent, "TCWorkerHiredEvent")

function TCWorkerHiredEvent.emptyNew()
    return Event.new(TCWorkerHiredEvent_mt)
end

function TCWorkerHiredEvent.new(worker)
    local self = TCWorkerHiredEvent.emptyNew()
    self.worker = worker
    return self
end

function TCWorkerHiredEvent:writeStream(streamId, connection)
    TheContractorStaff.writeWorker(streamId, self.worker)
end

function TCWorkerHiredEvent:readStream(streamId, connection)
    self.worker = TheContractorStaff.readWorker(streamId)
    self:run(connection)
end

function TCWorkerHiredEvent:run(connection)
    g_currentMission.TheContractor.Staff:applyWorkerHired(self.worker)
end
