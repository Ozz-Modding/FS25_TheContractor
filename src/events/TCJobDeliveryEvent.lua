-- Broadcast-only: the server's delivery progress on a player-driven haulage
-- job (035) - how much of the crop has reached the selling point, out of
-- how much has to, and where to (162: a station the farm can't unload at
-- is swapped when the tracker starts). Sent by TCHaulage at most once per
-- poll interval per job, not per tipped litre. Clients just apply it directly. See
-- src/events/README.md for the general event conventions.

TCJobDeliveryEvent = {}
local TCJobDeliveryEvent_mt = Class(TCJobDeliveryEvent, Event)

InitEventClass(TCJobDeliveryEvent, "TCJobDeliveryEvent")

function TCJobDeliveryEvent.emptyNew()
    return Event.new(TCJobDeliveryEvent_mt)
end

function TCJobDeliveryEvent.new(farmId, jobId, deliveredLiters, requiredLiters, stationName)
    local self = TCJobDeliveryEvent.emptyNew()
    self.stationName = stationName
    self.farmId = farmId
    self.jobId = jobId
    self.deliveredLiters = deliveredLiters
    self.requiredLiters = requiredLiters
    return self
end

function TCJobDeliveryEvent:writeStream(streamId, connection)
    streamWriteInt32(streamId, self.farmId)
    streamWriteInt32(streamId, self.jobId)
    streamWriteFloat32(streamId, self.deliveredLiters)
    streamWriteFloat32(streamId, self.requiredLiters)
    streamWriteString(streamId, self.stationName or "")
end

function TCJobDeliveryEvent:readStream(streamId, connection)
    self.farmId = streamReadInt32(streamId)
    self.jobId = streamReadInt32(streamId)
    self.deliveredLiters = streamReadFloat32(streamId)
    self.requiredLiters = streamReadFloat32(streamId)
    local stationName = streamReadString(streamId)
    if stationName ~= "" then
        self.stationName = stationName
    end
    self:run(connection)
end

function TCJobDeliveryEvent:run(connection)
    g_currentMission.TheContractor.Jobs:applyJobDelivery(self.farmId, self.jobId, self.deliveredLiters,
        self.requiredLiters, self.stationName)
end
