-- Server -> clients (172): each farm's answer about the show's staff day
-- off, whole, each time a farm's asked or answers, or they start again for
-- a new show (ShowDayOff.writeState). Also its part of the initial client
-- state.

TCShowDayOffEvent = {}
local TCShowDayOffEvent_mt = Class(TCShowDayOffEvent, Event)

InitEventClass(TCShowDayOffEvent, "TCShowDayOffEvent")

function TCShowDayOffEvent.emptyNew()
    return Event.new(TCShowDayOffEvent_mt)
end

-- dayOff: the server's TheContractorShowDayOff.
function TCShowDayOffEvent.new(dayOff)
    local self = TCShowDayOffEvent.emptyNew()
    self.dayOff = dayOff
    return self
end

function TCShowDayOffEvent:writeStream(streamId, connection)
    TheContractorShowDayOff.writeState(streamId, self.dayOff)
end

function TCShowDayOffEvent:readStream(streamId, connection)
    self.state = TheContractorShowDayOff.readState(streamId)
    self:run(connection)
end

function TCShowDayOffEvent:run(connection)
    if not connection:getIsServer() then
        -- Only the server says who's answered.
        return
    end
    local dayOff = g_currentMission.TheContractor ~= nil and g_currentMission.TheContractor.ShowDayOff or nil
    if dayOff ~= nil and self.state ~= nil then
        dayOff:applyState(self.state)
    end
end
