-- Broadcast-only: one of a farm's office staff was hired, released or
-- trained (057, 090, TheContractorOffice:commit). member is nil once
-- released. See src/events/README.md for the general event conventions.

TCOfficeChangedEvent = {}
local TCOfficeChangedEvent_mt = Class(TCOfficeChangedEvent, Event)

InitEventClass(TCOfficeChangedEvent, "TCOfficeChangedEvent")

function TCOfficeChangedEvent.emptyNew()
    return Event.new(TCOfficeChangedEvent_mt)
end

function TCOfficeChangedEvent.new(farmId, role, member)
    local self = TCOfficeChangedEvent.emptyNew()
    self.farmId = farmId
    self.role = role
    self.member = member
    return self
end

function TCOfficeChangedEvent:writeStream(streamId, connection)
    streamWriteInt32(streamId, self.farmId)
    streamWriteString(streamId, self.role)
    TheContractorOffice.writeMember(streamId, self.member)
end

function TCOfficeChangedEvent:readStream(streamId, connection)
    self.farmId = streamReadInt32(streamId)
    self.role = streamReadString(streamId)
    self.member = TheContractorOffice.readMember(streamId, self.farmId, self.role)
    self:run(connection)
end

function TCOfficeChangedEvent:run(connection)
    g_currentMission.TheContractor.Office:applyMember(self.farmId, self.role, self.member)
end
