-- Broadcast-only: a hired worker's name, gender and look were edited on the
-- server (066, TheContractorStaff:editWorker). See src/events/README.md for
-- the general event conventions.

TCWorkerEditedEvent = {}
local TCWorkerEditedEvent_mt = Class(TCWorkerEditedEvent, Event)

InitEventClass(TCWorkerEditedEvent, "TCWorkerEditedEvent")

function TCWorkerEditedEvent.emptyNew()
    return Event.new(TCWorkerEditedEvent_mt)
end

function TCWorkerEditedEvent.new(farmId, workerId, name, gender, appearance)
    local self = TCWorkerEditedEvent.emptyNew()
    self.farmId = farmId
    self.workerId = workerId
    self.name = name
    self.gender = gender
    self.appearance = appearance
    return self
end

function TCWorkerEditedEvent:writeStream(streamId, connection)
    streamWriteInt32(streamId, self.farmId)
    streamWriteInt32(streamId, self.workerId)
    streamWriteString(streamId, self.name)
    streamWriteString(streamId, self.gender)
    TCWorkerAppearance.writeStream(streamId, self.appearance)
end

function TCWorkerEditedEvent:readStream(streamId, connection)
    self.farmId = streamReadInt32(streamId)
    self.workerId = streamReadInt32(streamId)
    self.name = streamReadString(streamId)
    self.gender = streamReadString(streamId)
    self.appearance = TCWorkerAppearance.readStream(streamId)
    self:run(connection)
end

function TCWorkerEditedEvent:run(connection)
    g_currentMission.TheContractor.Staff:applyWorkerEdited(self.farmId, self.workerId, self.name, self.gender,
        self.appearance)
end
