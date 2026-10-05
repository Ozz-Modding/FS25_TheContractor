-- Broadcast-only: a farm's year-to-date totals changed (049,
-- TheContractorFinances:addToYearStats) - invoiced, received, written off
-- or wages. Sends the whole set, so a client can't drift. See
-- src/events/README.md for the general event conventions.

TCFinanceYearStatsEvent = {}
local TCFinanceYearStatsEvent_mt = Class(TCFinanceYearStatsEvent, Event)

InitEventClass(TCFinanceYearStatsEvent, "TCFinanceYearStatsEvent")

function TCFinanceYearStatsEvent.emptyNew()
    return Event.new(TCFinanceYearStatsEvent_mt)
end

function TCFinanceYearStatsEvent.new(farmId, stats)
    local self = TCFinanceYearStatsEvent.emptyNew()
    self.farmId = farmId
    self.stats = stats
    return self
end

function TCFinanceYearStatsEvent:writeStream(streamId, connection)
    streamWriteInt32(streamId, self.farmId)
    TheContractorFinances.writeYearStats(streamId, self.stats)
end

function TCFinanceYearStatsEvent:readStream(streamId, connection)
    self.farmId = streamReadInt32(streamId)
    self.stats = TheContractorFinances.readYearStats(streamId)
    self:run(connection)
end

function TCFinanceYearStatsEvent:run(connection)
    g_currentMission.TheContractor.Finances:applyYearStats(self.farmId, self.stats)
end
