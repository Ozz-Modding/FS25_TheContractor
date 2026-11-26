-- Server -> clients (173): the show's breeders' pen, whole
-- (BreedersPen.writeState: the show it's for, its spare farm id, the
-- breeder and the trailers' object ids), each time it opens, a trailer's
-- stocked or it closes. Also the pen's part of the initial client state.
-- The animals themselves never come through here: RealisticLivestock
-- streams a trailer's contents itself.

TCBreedersPenEvent = {}
local TCBreedersPenEvent_mt = Class(TCBreedersPenEvent, Event)

InitEventClass(TCBreedersPenEvent, "TCBreedersPenEvent")

function TCBreedersPenEvent.emptyNew()
    return Event.new(TCBreedersPenEvent_mt)
end

-- pen: the server's TheContractorBreedersPen.
function TCBreedersPenEvent.new(pen)
    local self = TCBreedersPenEvent.emptyNew()
    self.pen = pen
    return self
end

function TCBreedersPenEvent:writeStream(streamId, connection)
    TheContractorBreedersPen.writeState(streamId, self.pen)
end

function TCBreedersPenEvent:readStream(streamId, connection)
    self.state = TheContractorBreedersPen.readState(streamId)
    self:run(connection)
end

function TCBreedersPenEvent:run(connection)
    if not connection:getIsServer() then
        -- Only the server says where the pen is.
        return
    end
    local pen = g_currentMission.TheContractor ~= nil and g_currentMission.TheContractor.BreedersPen or nil
    if pen ~= nil and self.state ~= nil then
        pen:applyState(self.state)
    end
end
