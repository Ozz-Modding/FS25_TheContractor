-- Broadcast-only: a hired worker has retired (039,
-- TheContractorStaff:retireWorker) and leaves their farm's roster, the same
-- way a released worker does. See src/events/README.md for the general
-- event conventions.

TCWorkerRetiredEvent = {}
local TCWorkerRetiredEvent_mt = Class(TCWorkerRetiredEvent, Event)

InitEventClass(TCWorkerRetiredEvent, "TCWorkerRetiredEvent")

function TCWorkerRetiredEvent.emptyNew()
    return Event.new(TCWorkerRetiredEvent_mt)
end

function TCWorkerRetiredEvent.new(farmId, workerId)
    local self = TCWorkerRetiredEvent.emptyNew()
    self.farmId = farmId
    self.workerId = workerId
    return self
end

function TCWorkerRetiredEvent:writeStream(streamId, connection)
    streamWriteInt32(streamId, self.farmId)
    streamWriteInt32(streamId, self.workerId)
end

function TCWorkerRetiredEvent:readStream(streamId, connection)
    self.farmId = streamReadInt32(streamId)
    self.workerId = streamReadInt32(streamId)
    self:run(connection)
end

function TCWorkerRetiredEvent:run(connection)
    local staff = g_currentMission.TheContractor.Staff
    -- Before the roster drops them, while the name's still there.
    TCWorkerRetiredEvent.showNotification(staff:getWorker(self.farmId, self.workerId))
    staff:applyWorkerReleased(self.farmId, self.workerId)
end

-- Only the worker's own farm hears about it. Shared by run() (remote
-- clients) and TheContractorStaff:retireWorker (the host's own copy).
function TCWorkerRetiredEvent.showNotification(worker)
    if worker == nil or worker.farmId ~= g_currentMission:getFarmId() then
        return
    end

    g_currentMission:addIngameNotification(FSBaseMission.INGAME_NOTIFICATION_INFO,
        string.format(g_i18n:getText("tc_retirement_retired"), worker.name))
end
