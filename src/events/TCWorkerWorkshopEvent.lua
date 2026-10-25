-- A worker's ADS workshop skills and role (091, TheContractorWorkshop).
-- Sent by a client as a request to tick a worker into a role (or untick
-- them, with role nil): the server checks it (TheContractorWorkshop.setRole)
-- and broadcasts the result, the same event, which every client applies.
-- See src/events/README.md for the general event conventions.

TCWorkerWorkshopEvent = {}
local TCWorkerWorkshopEvent_mt = Class(TCWorkerWorkshopEvent, Event)

InitEventClass(TCWorkerWorkshopEvent, "TCWorkerWorkshopEvent")

function TCWorkerWorkshopEvent.emptyNew()
    return Event.new(TCWorkerWorkshopEvent_mt)
end

-- adsSkills is ignored in a request: only the role is asked for.
function TCWorkerWorkshopEvent.new(farmId, workerId, adsSkills, workshopRole)
    local self = TCWorkerWorkshopEvent.emptyNew()
    self.farmId = farmId
    self.workerId = workerId
    self.adsSkills = adsSkills or {}
    self.workshopRole = workshopRole
    return self
end

function TCWorkerWorkshopEvent:writeStream(streamId, connection)
    streamWriteInt32(streamId, self.farmId)
    streamWriteInt32(streamId, self.workerId)
    TheContractorWorkshop.writeSkills(streamId, self.adsSkills)
    streamWriteString(streamId, self.workshopRole or "")
end

function TCWorkerWorkshopEvent:readStream(streamId, connection)
    self.farmId = streamReadInt32(streamId)
    self.workerId = streamReadInt32(streamId)
    self.adsSkills = TheContractorWorkshop.readSkills(streamId)
    local role = streamReadString(streamId)
    self.workshopRole = role ~= "" and role or nil
    self:run(connection)
end

function TCWorkerWorkshopEvent:run(connection)
    if g_currentMission:getIsServer() then
        TheContractorWorkshop.setRole(self.farmId, self.workerId, self.workshopRole)
        return
    end
    local worker = g_currentMission.TheContractor.Staff:getWorker(self.farmId, self.workerId)
    if worker ~= nil then
        TheContractorWorkshop.apply(worker, self.adsSkills, self.workshopRole)
    end
end
