-- Client takes one of an inbox message's actions, from the Inbox's bottom
-- bar (050). The server re-checks the message is the farm's and offers the
-- action, runs the kind's handler and removes the message
-- (TheContractorInbox:requestAction); the removal goes out as a
-- TCMessageRemovedEvent. See src/events/README.md for the general event
-- conventions.

TCMessageActionEvent = {}
local TCMessageActionEvent_mt = Class(TCMessageActionEvent, Event)

InitEventClass(TCMessageActionEvent, "TCMessageActionEvent")

function TCMessageActionEvent.emptyNew()
    return Event.new(TCMessageActionEvent_mt)
end

function TCMessageActionEvent.new(farmId, messageId, actionKey)
    local self = TCMessageActionEvent.emptyNew()
    self.farmId = farmId
    self.messageId = messageId
    self.actionKey = actionKey
    return self
end

function TCMessageActionEvent:writeStream(streamId, connection)
    streamWriteInt32(streamId, self.farmId)
    streamWriteInt32(streamId, self.messageId)
    streamWriteString(streamId, self.actionKey)
end

function TCMessageActionEvent:readStream(streamId, connection)
    self.farmId = streamReadInt32(streamId)
    self.messageId = streamReadInt32(streamId)
    self.actionKey = streamReadString(streamId)
    self:run(connection)
end

function TCMessageActionEvent:run(connection)
    if g_currentMission:getIsServer() then
        g_currentMission.TheContractor.Inbox:requestAction(self.farmId, self.messageId, self.actionKey)
    end
end
