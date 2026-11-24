-- Server -> clients (169): the show's ploughing match, whole, each time a
-- plot's set out, taken or finished, the kit comes or goes, the match starts
-- or ends, or the results are given: the plots (who's on each and the kit's
-- ids), the match's phase, each plot's scorecard once the results are in,
-- and every farm's best. Never the ground, the path, a live score or a
-- farmer's skill (PloughingMatch.writeState). Also the match's part of the
-- initial client state.

TCPloughMatchEvent = {}
local TCPloughMatchEvent_mt = Class(TCPloughMatchEvent, Event)

InitEventClass(TCPloughMatchEvent, "TCPloughMatchEvent")

function TCPloughMatchEvent.emptyNew()
    return Event.new(TCPloughMatchEvent_mt)
end

-- match: the server's TheContractorPloughingMatch.
function TCPloughMatchEvent.new(match)
    local self = TCPloughMatchEvent.emptyNew()
    self.match = match
    return self
end

function TCPloughMatchEvent:writeStream(streamId, connection)
    TheContractorPloughingMatch.writeState(streamId, self.match)
end

function TCPloughMatchEvent:readStream(streamId, connection)
    self.state = TheContractorPloughingMatch.readState(streamId)
    self:run(connection)
end

function TCPloughMatchEvent:run(connection)
    if not connection:getIsServer() then
        -- Only the server says what the match is.
        return
    end
    local match = g_currentMission.TheContractor ~= nil and g_currentMission.TheContractor.PloughingMatch or nil
    if match ~= nil and self.state ~= nil then
        match:applyState(self.state)
    end
end
