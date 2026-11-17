-- Broadcast-only (160): the days per period changed or was planned to, and
-- the server moved live jobs' dates to the same calendar dates
-- (TheContractorJobs:onCalendarMaybeChanged). Carries each moved job's new
-- deadline, ready day and target date, worked out on the server, so a
-- client never has to work them out against a calendar its own settings
-- event may not have reached yet. See src/events/README.md for the general
-- event conventions.

TCJobDatesChangedEvent = {}
local TCJobDatesChangedEvent_mt = Class(TCJobDatesChangedEvent, Event)

InitEventClass(TCJobDatesChangedEvent, "TCJobDatesChangedEvent")

function TCJobDatesChangedEvent.emptyNew()
    return Event.new(TCJobDatesChangedEvent_mt)
end

-- changes: { farmId, jobId, deadlineDay, readyDay, targetPeriod,
-- targetDayInPeriod } each, as TheContractorJobs:applyJobDates takes them.
function TCJobDatesChangedEvent.new(changes)
    local self = TCJobDatesChangedEvent.emptyNew()
    self.changes = changes
    return self
end

-- -1 stands in for nil (no deadline, or ready now).
function TCJobDatesChangedEvent:writeStream(streamId, connection)
    streamWriteInt32(streamId, #self.changes)
    for _, change in ipairs(self.changes) do
        streamWriteInt32(streamId, change.farmId)
        streamWriteInt32(streamId, change.jobId)
        streamWriteInt32(streamId, change.deadlineDay or -1)
        streamWriteInt32(streamId, change.readyDay or -1)
        streamWriteInt32(streamId, change.targetPeriod)
        streamWriteInt32(streamId, change.targetDayInPeriod)
    end
end

function TCJobDatesChangedEvent:readStream(streamId, connection)
    self.changes = {}
    local count = streamReadInt32(streamId)
    for _ = 1, count do
        local change = {
            farmId = streamReadInt32(streamId),
            jobId = streamReadInt32(streamId),
            deadlineDay = streamReadInt32(streamId),
            readyDay = streamReadInt32(streamId),
            targetPeriod = streamReadInt32(streamId),
            targetDayInPeriod = streamReadInt32(streamId),
        }
        if change.deadlineDay < 0 then
            change.deadlineDay = nil
        end
        if change.readyDay < 0 then
            change.readyDay = nil
        end
        table.insert(self.changes, change)
    end
    self:run(connection)
end

function TCJobDatesChangedEvent:run(connection)
    g_currentMission.TheContractor.Jobs:applyJobDates(self.changes)
end
