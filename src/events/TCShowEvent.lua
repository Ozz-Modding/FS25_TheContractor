-- Server -> clients (165): the agricultural show, whole, each time it's
-- announced, changes state, gives its results, or is over or cancelled
-- (nil), with the last results (kept until the next show's). Each machine
-- protects its fields, shows its marker, puts the crowd up and draws the
-- Show tab from it. The event's written as every event day is (163,
-- TheContractorEventDay.writeEvent), then the show's own.

TCShowEvent = {}
local TCShowEvent_mt = Class(TCShowEvent, Event)

InitEventClass(TCShowEvent, "TCShowEvent")

function TCShowEvent.emptyNew()
    return Event.new(TCShowEvent_mt)
end

-- event, results: nil for none.
function TCShowEvent.new(event, results)
    local self = TCShowEvent.emptyNew()
    self.event = event
    self.results = results
    return self
end

-- Also the show's part of the initial client state.
function TCShowEvent.writeShow(streamId, event, results)
    TheContractorEventDay.writeEvent(streamId, event)
    TheContractorShow.writeShowExtra(streamId, event)
    TheContractorShow.writeResults(streamId, results)
end

-- Returns the event and the results (each nil for none).
function TCShowEvent.readShow(streamId)
    local event = TheContractorEventDay.readEvent(streamId)
    TheContractorShow.readShowExtra(streamId, event)
    return event, TheContractorShow.readResults(streamId)
end

function TCShowEvent:writeStream(streamId, connection)
    TCShowEvent.writeShow(streamId, self.event, self.results)
end

function TCShowEvent:readStream(streamId, connection)
    self.event, self.results = TCShowEvent.readShow(streamId)
    self:run(connection)
end

function TCShowEvent:run(connection)
    if not connection:getIsServer() then
        -- Only the server says what the show is.
        return
    end
    local show = g_currentMission.TheContractor ~= nil and g_currentMission.TheContractor.Show or nil
    if show ~= nil then
        show:applyShowSync(self.event, self.results)
    end
end
