-- Client requests parking all its farm's free machines in the farm's
-- parking slots (159, the Logbook's Park all button). The server re-checks
-- the sender's farm and starts the run (TheContractorParking:parkAll):
-- vehicle positions replicate by themselves and the farm hears how it went
-- through TCParkingNoticeEvent, so this has no apply side of its own. See
-- src/events/README.md for the general event conventions.

TCParkAllEvent = {}
local TCParkAllEvent_mt = Class(TCParkAllEvent, Event)

InitEventClass(TCParkAllEvent, "TCParkAllEvent")

function TCParkAllEvent.emptyNew()
    return Event.new(TCParkAllEvent_mt)
end

function TCParkAllEvent.new(farmId)
    local self = TCParkAllEvent.emptyNew()
    self.farmId = farmId
    return self
end

function TCParkAllEvent:writeStream(streamId, connection)
    streamWriteInt32(streamId, self.farmId)
end

function TCParkAllEvent:readStream(streamId, connection)
    self.farmId = streamReadInt32(streamId)
    self:run(connection)
end

function TCParkAllEvent:run(connection)
    if g_currentMission:getIsServer() then
        g_currentMission.TheContractor.Parking:parkAll(self.farmId)
    end
end
