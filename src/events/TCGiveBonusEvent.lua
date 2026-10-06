-- Client asks to give one of its farm's workers a one-off bonus, from the
-- Staff tab (056). The server re-checks the worker, the amount and the
-- balance (TheContractorMorale:requestBonus); the result goes out as a
-- TCWorkerMoraleChangedEvent. See src/events/README.md for the general
-- event conventions.

TCGiveBonusEvent = {}
local TCGiveBonusEvent_mt = Class(TCGiveBonusEvent, Event)

InitEventClass(TCGiveBonusEvent, "TCGiveBonusEvent")

function TCGiveBonusEvent.emptyNew()
    return Event.new(TCGiveBonusEvent_mt)
end

function TCGiveBonusEvent.new(farmId, workerId, amount)
    local self = TCGiveBonusEvent.emptyNew()
    self.farmId = farmId
    self.workerId = workerId
    self.amount = amount
    return self
end

function TCGiveBonusEvent:writeStream(streamId, connection)
    streamWriteInt32(streamId, self.farmId)
    streamWriteInt32(streamId, self.workerId)
    streamWriteInt32(streamId, self.amount)
end

function TCGiveBonusEvent:readStream(streamId, connection)
    self.farmId = streamReadInt32(streamId)
    self.workerId = streamReadInt32(streamId)
    self.amount = streamReadInt32(streamId)
    self:run(connection)
end

function TCGiveBonusEvent:run(connection)
    if g_currentMission:getIsServer() then
        g_currentMission.TheContractor.Morale:requestBonus(self.farmId, self.workerId, self.amount)
    end
end
