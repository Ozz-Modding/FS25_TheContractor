-- Server -> clients (170): the workers entered in the show's ploughing
-- match, whole, each time one's entered or withdrawn, or they start again
-- for a new show (ShowWorker.writeState: who, never a score). Also the
-- entries' part of the initial client state.

TCShowWorkerEvent = {}
local TCShowWorkerEvent_mt = Class(TCShowWorkerEvent, Event)

InitEventClass(TCShowWorkerEvent, "TCShowWorkerEvent")

function TCShowWorkerEvent.emptyNew()
    return Event.new(TCShowWorkerEvent_mt)
end

-- showWorker: the server's TheContractorShowWorker.
function TCShowWorkerEvent.new(showWorker)
    local self = TCShowWorkerEvent.emptyNew()
    self.showWorker = showWorker
    return self
end

function TCShowWorkerEvent:writeStream(streamId, connection)
    TheContractorShowWorker.writeState(streamId, self.showWorker)
end

function TCShowWorkerEvent:readStream(streamId, connection)
    self.state = TheContractorShowWorker.readState(streamId)
    self:run(connection)
end

function TCShowWorkerEvent:run(connection)
    if not connection:getIsServer() then
        -- Only the server says who's entered.
        return
    end
    local showWorker = g_currentMission.TheContractor ~= nil and g_currentMission.TheContractor.ShowWorker or nil
    if showWorker ~= nil and self.state ~= nil then
        showWorker:applyState(self.state)
    end
end
