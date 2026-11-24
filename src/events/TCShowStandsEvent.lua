-- Server -> clients (171): who's been where at the show, whole
-- (ShowStands.writeState: each farm's visit, the farmers it's talked to and
-- asked), each time one changes or a new show starts them again. Also the
-- stands' part of the initial client state.

TCShowStandsEvent = {}
local TCShowStandsEvent_mt = Class(TCShowStandsEvent, Event)

InitEventClass(TCShowStandsEvent, "TCShowStandsEvent")

function TCShowStandsEvent.emptyNew()
    return Event.new(TCShowStandsEvent_mt)
end

-- stands: the server's TheContractorShowStands.
function TCShowStandsEvent.new(stands)
    local self = TCShowStandsEvent.emptyNew()
    self.stands = stands
    return self
end

function TCShowStandsEvent:writeStream(streamId, connection)
    TheContractorShowStands.writeState(streamId, self.stands)
end

function TCShowStandsEvent:readStream(streamId, connection)
    self.state = TheContractorShowStands.readState(streamId)
    self:run(connection)
end

function TCShowStandsEvent:run(connection)
    if not connection:getIsServer() then
        -- Only the server says who's been where.
        return
    end
    local stands = g_currentMission.TheContractor ~= nil and g_currentMission.TheContractor.ShowStands or nil
    if stands ~= nil and self.state ~= nil then
        stands:applyState(self.state)
    end
end
