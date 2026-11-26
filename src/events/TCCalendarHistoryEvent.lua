-- Broadcast-only: the server anchored the calendar on a new day because
-- the days per month changed (TCCalendarHistory), so every machine dates
-- past days the same way. See src/events/README.md for the general event
-- conventions.

TCCalendarHistoryEvent = {}
local TCCalendarHistoryEvent_mt = Class(TCCalendarHistoryEvent, Event)

InitEventClass(TCCalendarHistoryEvent, "TCCalendarHistoryEvent")

function TCCalendarHistoryEvent.emptyNew()
    return Event.new(TCCalendarHistoryEvent_mt)
end

function TCCalendarHistoryEvent.new(anchor)
    local self = TCCalendarHistoryEvent.emptyNew()
    self.anchor = anchor
    return self
end

function TCCalendarHistoryEvent:writeStream(streamId, connection)
    TCCalendarHistory.writeAnchor(streamId, self.anchor)
end

function TCCalendarHistoryEvent:readStream(streamId, connection)
    self.anchor = TCCalendarHistory.readAnchor(streamId)
    self:run(connection)
end

function TCCalendarHistoryEvent:run(connection)
    TCCalendarHistory.add(self.anchor)
end
