-- Broadcast-only: the server pays out and completes a job (via
-- TheContractorJobs:completeJob, 022) and sends the full job snapshot to
-- every client. Reuses TheContractorJobs.writeJob/readJob (same shape as
-- TCJobCreatedEvent/TCJobAllocatedEvent) rather than a partial-field update,
-- since state/paymentAmount/completionPercentage and the completion summary
-- (029: time, fuel, quality) all move together. Applied via the existing
-- registerJob (isNewArrival = false, same as an allocation update) since a
-- completion is never a "new offer" for HUD purposes, then shows the
-- summary notification. See src/events/README.md for the general event
-- conventions.

TCJobCompletedEvent = {}
local TCJobCompletedEvent_mt = Class(TCJobCompletedEvent, Event)

InitEventClass(TCJobCompletedEvent, "TCJobCompletedEvent")

function TCJobCompletedEvent.emptyNew()
    return Event.new(TCJobCompletedEvent_mt)
end

function TCJobCompletedEvent.new(job)
    local self = TCJobCompletedEvent.emptyNew()
    self.job = job
    return self
end

function TCJobCompletedEvent:writeStream(streamId, connection)
    TheContractorJobs.writeJob(streamId, self.job)
end

function TCJobCompletedEvent:readStream(streamId, connection)
    self.job = TheContractorJobs.readJob(streamId)
    self:run(connection)
end

function TCJobCompletedEvent:run(connection)
    g_currentMission.TheContractor.Jobs:registerJob(self.job, false)
    TCJobCompletedEvent.showNotification(self.job)
end

-- Completion summary (029) for the job's own farm. Shared by run() (remote
-- clients) and TheContractorJobs:completeJob (the host's own copy, since
-- the broadcast doesn't loop back to it). A non-blocking notification
-- rather than a dialog, so a job finishing doesn't interrupt whatever the
-- player is doing - the Overview tab keeps the last one on show.
function TCJobCompletedEvent.showNotification(job)
    if job.farmId ~= g_currentMission:getFarmId() then
        return
    end

    g_currentMission:addIngameNotification(FSBaseMission.INGAME_NOTIFICATION_OK,
        string.format(g_i18n:getText("tc_summary_notification"), job:getSummaryText()))

    -- 049: invoiced, or paid there and then.
    g_currentMission:addIngameNotification(FSBaseMission.INGAME_NOTIFICATION_INFO, job:getPaymentText())

    -- 045: what the workers did to the machines. Washing isn't mentioned -
    -- it's in the logbook, and the machines aren't back yet (Parking says
    -- when they are).
    for _, line in ipairs(TCJobConsequences.getReportLines(job)) do
        g_currentMission:addIngameNotification(FSBaseMission.INGAME_NOTIFICATION_INFO, line)
    end
end
