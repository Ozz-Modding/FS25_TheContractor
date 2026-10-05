-- Broadcast-only: the server posted an inbox message to a farm (050,
-- TheContractorInbox:postMessage) and sends it to every client. See
-- src/events/README.md for the general event conventions.

TCMessagePostedEvent = {}
local TCMessagePostedEvent_mt = Class(TCMessagePostedEvent, Event)

InitEventClass(TCMessagePostedEvent, "TCMessagePostedEvent")

function TCMessagePostedEvent.emptyNew()
    return Event.new(TCMessagePostedEvent_mt)
end

function TCMessagePostedEvent.new(message)
    local self = TCMessagePostedEvent.emptyNew()
    self.message = message
    return self
end

function TCMessagePostedEvent:writeStream(streamId, connection)
    TheContractorInbox.writeMessage(streamId, self.message)
end

function TCMessagePostedEvent:readStream(streamId, connection)
    self.message = TheContractorInbox.readMessage(streamId)
    self:run(connection)
end

function TCMessagePostedEvent:run(connection)
    g_currentMission.TheContractor.Inbox:applyMessagePosted(self.message, true)
end
