-- Server -> clients (163): a public day out of any kind but the auction
-- (which has TCAuctionEvent), whole, each time it's announced, changes
-- state, or is over or cancelled (nil). The kind's found by its KIND
-- through tc.PublicEvents.

TCEventDayEvent = {}
local TCEventDayEvent_mt = Class(TCEventDayEvent, Event)

InitEventClass(TCEventDayEvent, "TCEventDayEvent")

function TCEventDayEvent.emptyNew()
    return Event.new(TCEventDayEvent_mt)
end

-- kind: the kind's KIND. event: nil for none.
function TCEventDayEvent.new(kind, event)
    local self = TCEventDayEvent.emptyNew()
    self.kind = kind
    self.event = event
    return self
end

function TCEventDayEvent:writeStream(streamId, connection)
    streamWriteString(streamId, self.kind)
    TheContractorEventDay.writeEvent(streamId, self.event)
end

function TCEventDayEvent:readStream(streamId, connection)
    self.kind = streamReadString(streamId)
    self.event = TheContractorEventDay.readEvent(streamId)
    self:run(connection)
end

function TCEventDayEvent:run(connection)
    if not connection:getIsServer() then
        -- Only the server says what's on.
        return
    end
    local tc = g_currentMission.TheContractor
    local publicEvents = tc ~= nil and tc.PublicEvents or nil
    local kind = publicEvents ~= nil and publicEvents:getKind(self.kind) or nil
    if kind ~= nil then
        kind:applySync(self.event)
    end
end
