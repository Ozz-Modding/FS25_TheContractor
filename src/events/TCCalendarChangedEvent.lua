-- Broadcast-only (161): the days per month changed or was planned to, and
-- every booked day moves to the same date (TCCalendarChange). Carries the
-- calendar the days were worked out under and the one they move to, both
-- from the server, so a client moves its own copies exactly as the server
-- did, whatever its own calendar says yet. See src/events/README.md for
-- the general event conventions.

TCCalendarChangedEvent = {}
local TCCalendarChangedEvent_mt = Class(TCCalendarChangedEvent, Event)

InitEventClass(TCCalendarChangedEvent, "TCCalendarChangedEvent")

function TCCalendarChangedEvent.emptyNew()
    return Event.new(TCCalendarChangedEvent_mt)
end

function TCCalendarChangedEvent.new(fromModel, toModel)
    local self = TCCalendarChangedEvent.emptyNew()
    self.fromModel = fromModel
    self.toModel = toModel
    return self
end

function TCCalendarChangedEvent:writeStream(streamId, connection)
    TCCalendarChange.writeModel(streamId, self.fromModel)
    TCCalendarChange.writeModel(streamId, self.toModel)
end

function TCCalendarChangedEvent:readStream(streamId, connection)
    self.fromModel = TCCalendarChange.readModel(streamId)
    self.toModel = TCCalendarChange.readModel(streamId)
    self:run(connection)
end

function TCCalendarChangedEvent:run(connection)
    TCCalendarChange.apply(self.fromModel, self.toModel)
end
