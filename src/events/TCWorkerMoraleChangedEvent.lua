-- Broadcast-only: some of a farm's workers' morale changed on the server
-- (056, TheContractorMorale) - the monthly drift, a bonus, a knock - or an
-- old save's worker got their hire date. Sends each worker's whole visible
-- morale state (TheContractorMorale.writeState), plus what to tell the farm
-- about it. See src/events/README.md for the general event conventions.

TCWorkerMoraleChangedEvent = {}
local TCWorkerMoraleChangedEvent_mt = Class(TCWorkerMoraleChangedEvent, Event)

InitEventClass(TCWorkerMoraleChangedEvent, "TCWorkerMoraleChangedEvent")

function TCWorkerMoraleChangedEvent.emptyNew()
    return Event.new(TCWorkerMoraleChangedEvent_mt)
end

-- notify (TheContractorMorale.NOTIFY) and amount are only for the
-- notification.
function TCWorkerMoraleChangedEvent.new(farmId, workers, notify, amount)
    local self = TCWorkerMoraleChangedEvent.emptyNew()
    self.farmId = farmId
    self.workers = workers
    self.notify = notify
    self.amount = amount
    return self
end

function TCWorkerMoraleChangedEvent:writeStream(streamId, connection)
    streamWriteInt32(streamId, self.farmId)
    streamWriteInt32(streamId, #self.workers)
    for _, worker in ipairs(self.workers) do
        streamWriteInt32(streamId, worker.id)
        TheContractorMorale.writeState(streamId, worker)
    end
    streamWriteUInt8(streamId, self.notify)
    streamWriteFloat32(streamId, self.amount)
end

function TCWorkerMoraleChangedEvent:readStream(streamId, connection)
    self.farmId = streamReadInt32(streamId)
    self.entries = {}
    for _ = 1, streamReadInt32(streamId) do
        local workerId = streamReadInt32(streamId)
        local morale, hiredPeriod = TheContractorMorale.readState(streamId)
        table.insert(self.entries, { workerId = workerId, morale = morale, hiredPeriod = hiredPeriod })
    end
    self.notify = streamReadUInt8(streamId)
    self.amount = streamReadFloat32(streamId)
    self:run(connection)
end

function TCWorkerMoraleChangedEvent:run(connection)
    local staff = g_currentMission.TheContractor.Staff
    local workers = {}
    for _, entry in ipairs(self.entries) do
        local worker = staff:getWorker(self.farmId, entry.workerId)
        if worker ~= nil then
            worker.morale = entry.morale
            worker.hiredPeriod = entry.hiredPeriod
            table.insert(workers, worker)
        end
    end

    TCWorkerMoraleChangedEvent.showNotification(self.farmId, workers, self.notify, self.amount)
end

-- Only the workers' own farm hears about it. Shared by run() (remote
-- clients) and TheContractorMorale:sendMoraleChanged (the host's own copy,
-- since the broadcast doesn't loop back to it).
function TCWorkerMoraleChangedEvent.showNotification(farmId, workers, notify, amount)
    if farmId ~= g_currentMission:getFarmId() or #workers == 0 then
        return
    end

    local NOTIFY = TheContractorMorale.NOTIFY
    local money = g_i18n:formatMoney(amount, 0, true, true)

    if notify == NOTIFY.BONUS then
        g_currentMission:addIngameNotification(FSBaseMission.INGAME_NOTIFICATION_OK,
            string.format(g_i18n:getText("tc_morale_bonusNotice"), workers[1].name, money))
    elseif notify == NOTIFY.HARVEST_BONUS then
        g_currentMission:addIngameNotification(FSBaseMission.INGAME_NOTIFICATION_OK,
            string.format(g_i18n:getText("tc_morale_harvestBonusNotice"), money))
    elseif notify == NOTIFY.NO_HARVEST_BONUS then
        g_currentMission:addIngameNotification(FSBaseMission.INGAME_NOTIFICATION_CRITICAL,
            g_i18n:getText("tc_morale_noHarvestBonusNotice"))
    elseif notify == NOTIFY.ROUGH_PATCH then
        g_currentMission:addIngameNotification(FSBaseMission.INGAME_NOTIFICATION_INFO,
            string.format(g_i18n:getText("tc_morale_roughPatchNotice"), workers[1].name))
    end
end
