-- Broadcast-only: the server removed an inbox message (050,
-- TheContractorInbox:removeMessage - answered, or expired). See
-- src/events/README.md for the general event conventions.

TCMessageRemovedEvent = {}
local TCMessageRemovedEvent_mt = Class(TCMessageRemovedEvent, Event)

InitEventClass(TCMessageRemovedEvent, "TCMessageRemovedEvent")

function TCMessageRemovedEvent.emptyNew()
    return Event.new(TCMessageRemovedEvent_mt)
end

function TCMessageRemovedEvent.new(messageId)
    local self = TCMessageRemovedEvent.emptyNew()
    self.messageId = messageId
    return self
end

function TCMessageRemovedEvent:writeStream(streamId, connection)
    streamWriteInt32(streamId, self.messageId)
end

function TCMessageRemovedEvent:readStream(streamId, connection)
    self.messageId = streamReadInt32(streamId)
    self:run(connection)
end

function TCMessageRemovedEvent:run(connection)
    g_currentMission.TheContractor.Inbox:applyMessageRemoved(self.messageId)
end
