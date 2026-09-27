-- Broadcast-only: a completed job grew one of a hired worker's stats (via
-- TheContractorStaff:rollWorkerGrowth, 030) and the server sends just that
-- stat's new value to every client - same "changed field only" shape as
-- TCWorkerStatusChangedEvent. growthPotential isn't sent: it's hidden and
-- only the server needs it. See src/events/README.md for the general event
-- conventions.

TCWorkerGrewEvent = {}
local TCWorkerGrewEvent_mt = Class(TCWorkerGrewEvent, Event)

InitEventClass(TCWorkerGrewEvent, "TCWorkerGrewEvent")

function TCWorkerGrewEvent.emptyNew()
    return Event.new(TCWorkerGrewEvent_mt)
end

-- stat is "workSpeed" or a tier key (see TheContractorWorker:getStat).
function TCWorkerGrewEvent.new(farmId, workerId, stat, value)
    local self = TCWorkerGrewEvent.emptyNew()
    self.farmId = farmId
    self.workerId = workerId
    self.stat = stat
    self.value = value
    return self
end

function TCWorkerGrewEvent:writeStream(streamId, connection)
    streamWriteInt32(streamId, self.farmId)
    streamWriteInt32(streamId, self.workerId)
    streamWriteString(streamId, self.stat)
    streamWriteInt32(streamId, self.value)
end

function TCWorkerGrewEvent:readStream(streamId, connection)
    self.farmId = streamReadInt32(streamId)
    self.workerId = streamReadInt32(streamId)
    self.stat = streamReadString(streamId)
    self.value = streamReadInt32(streamId)
    self:run(connection)
end

function TCWorkerGrewEvent:run(connection)
    local staff = g_currentMission.TheContractor.Staff
    local worker = staff:getWorker(self.farmId, self.workerId)
    if worker == nil then
        return
    end

    local oldValue = worker:getStat(self.stat)
    staff:applyWorkerGrowth(self.farmId, self.workerId, self.stat, self.value)
    TCWorkerGrewEvent.showNotification(worker, self.stat, oldValue, self.value)
end

-- Level-up notification for the worker's own farm. Shared by run() (remote
-- clients) and rollWorkerGrowth (the host's own copy, since the broadcast
-- doesn't loop back to it). oldValue is nil for a new tier certification.
function TCWorkerGrewEvent.showNotification(worker, stat, oldValue, newValue)
    if worker.farmId ~= g_currentMission:getFarmId() then
        return
    end

    local statName = g_i18n:getText("tc_growth_stat_" .. stat)
    local text
    if oldValue == nil then
        text = string.format(g_i18n:getText("tc_growth_certified"), worker.name, statName)
    else
        text = string.format(g_i18n:getText("tc_growth_improved"), worker.name, statName, oldValue, newValue)
    end

    g_currentMission:addIngameNotification(FSBaseMission.INGAME_NOTIFICATION_OK, text)
end
