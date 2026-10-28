-- Editing a farmer or the local official (111): a new name, gender and
-- look from TCEditPersonDialog. Both ways, like TCCreateCompanyEvent: a
-- client's request goes to the server, which checks it
-- (TheContractorFarmers:editPerson), applies it and broadcasts this event to
-- every client, the requester included. The people are shared by every
-- farm, so everyone sees the edit. See src/events/README.md for the general
-- event conventions.

TCEditPersonEvent = {}
local TCEditPersonEvent_mt = Class(TCEditPersonEvent, Event)

InitEventClass(TCEditPersonEvent, "TCEditPersonEvent")

function TCEditPersonEvent.emptyNew()
    return Event.new(TCEditPersonEvent_mt)
end

function TCEditPersonEvent.new(farmId, personId, name, gender, appearance)
    local self = TCEditPersonEvent.emptyNew()
    self.farmId = farmId
    self.personId = personId
    self.name = name
    self.gender = gender
    self.appearance = appearance
    return self
end

function TCEditPersonEvent:writeStream(streamId, connection)
    streamWriteInt32(streamId, self.farmId)
    streamWriteInt32(streamId, self.personId)
    streamWriteString(streamId, self.name)
    streamWriteString(streamId, self.gender)
    TCWorkerAppearance.writeStream(streamId, self.appearance)
end

function TCEditPersonEvent:readStream(streamId, connection)
    self.farmId = streamReadInt32(streamId)
    self.personId = streamReadInt32(streamId)
    self.name = streamReadString(streamId)
    self.gender = streamReadString(streamId)
    self.appearance = TCWorkerAppearance.readStream(streamId)
    self:run(connection)
end

function TCEditPersonEvent:run(connection)
    local farmers = g_currentMission.TheContractor.Farmers
    if g_currentMission:getIsServer() then
        farmers:editPerson(self.farmId, self.personId, self.name, self.gender, self.appearance)
    else
        farmers:applyPersonEdited(self.personId, self.name, self.gender, self.appearance)
    end
end
