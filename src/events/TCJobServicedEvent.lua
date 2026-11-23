-- Broadcast-only: a hired worker's job held for a service (150's
-- needsService) has had its machine seen to, and the worker carries on
-- once Dispatch.SERVICE_GRACE_MS is up. Shown to the job's farm only, from
-- the job each machine already holds (the machine's name is its synced
-- supplyFillTypeName). See src/events/README.md for the general event
-- conventions.

TCJobServicedEvent = {}
local TCJobServicedEvent_mt = Class(TCJobServicedEvent, Event)

InitEventClass(TCJobServicedEvent, "TCJobServicedEvent")

function TCJobServicedEvent.emptyNew()
    return Event.new(TCJobServicedEvent_mt)
end

function TCJobServicedEvent.new(farmId, jobId)
    local self = TCJobServicedEvent.emptyNew()
    self.farmId = farmId
    self.jobId = jobId
    return self
end

function TCJobServicedEvent:writeStream(streamId, connection)
    streamWriteInt32(streamId, self.farmId)
    streamWriteInt32(streamId, self.jobId)
end

function TCJobServicedEvent:readStream(streamId, connection)
    self.farmId = streamReadInt32(streamId)
    self.jobId = streamReadInt32(streamId)
    self:run(connection)
end

function TCJobServicedEvent:run(connection)
    TCJobServicedEvent.showNotification(self.farmId, self.jobId)
end

-- The server sends it, and shows the host's own copy (the broadcast doesn't
-- loop back to it).
function TCJobServicedEvent.send(job)
    TCJobServicedEvent.showNotification(job.farmId, job.id)
    if g_server ~= nil then
        g_server:broadcastEvent(TCJobServicedEvent.new(job.farmId, job.id))
    end
end

function TCJobServicedEvent.showNotification(farmId, jobId)
    if g_client == nil or farmId ~= g_currentMission:getFarmId() then
        return
    end
    local job = g_currentMission.TheContractor.Jobs:getJob(farmId, jobId)
    if job == nil then
        return
    end
    g_currentMission:addIngameNotification(FSBaseMission.INGAME_NOTIFICATION_OK,
        string.format(g_i18n:getText("tc_supplies_serviced"), job.supplyFillTypeName or "?", job:getTypeText(),
            job:getLocationText()))
end
