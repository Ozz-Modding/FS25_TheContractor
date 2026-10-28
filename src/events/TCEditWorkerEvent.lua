-- Client asks to edit one of its farm's hired workers (066): a new name,
-- gender and look from TCEditPersonDialog. The server checks them again
-- (TheContractorStaff:editWorker), and the result goes out as a
-- TCWorkerEditedEvent. See src/events/README.md for the general event
-- conventions.

TCEditWorkerEvent = {}
local TCEditWorkerEvent_mt = Class(TCEditWorkerEvent, Event)

InitEventClass(TCEditWorkerEvent, "TCEditWorkerEvent")

function TCEditWorkerEvent.emptyNew()
    return Event.new(TCEditWorkerEvent_mt)
end

function TCEditWorkerEvent.new(farmId, workerId, name, gender, appearance)
    local self = TCEditWorkerEvent.emptyNew()
    self.farmId = farmId
    self.workerId = workerId
    self.name = name
    self.gender = gender
    self.appearance = appearance
    return self
end

function TCEditWorkerEvent:writeStream(streamId, connection)
    streamWriteInt32(streamId, self.farmId)
    streamWriteInt32(streamId, self.workerId)
    streamWriteString(streamId, self.name)
    streamWriteString(streamId, self.gender)
    TCWorkerAppearance.writeStream(streamId, self.appearance)
end

function TCEditWorkerEvent:readStream(streamId, connection)
    self.farmId = streamReadInt32(streamId)
    self.workerId = streamReadInt32(streamId)
    self.name = streamReadString(streamId)
    self.gender = streamReadString(streamId)
    self.appearance = TCWorkerAppearance.readStream(streamId)
    self:run(connection)
end

function TCEditWorkerEvent:run(connection)
    if g_currentMission:getIsServer() then
        g_currentMission.TheContractor.Staff:editWorker(self.farmId, self.workerId, self.name, self.gender,
            self.appearance)
    end
end
