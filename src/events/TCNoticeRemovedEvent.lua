-- Broadcast-only: the server took a notice down (038,
-- TheContractorNotices:remove - by its publisher, or because it expired).
-- See src/events/README.md for the general event conventions.

TCNoticeRemovedEvent = {}
local TCNoticeRemovedEvent_mt = Class(TCNoticeRemovedEvent, Event)

InitEventClass(TCNoticeRemovedEvent, "TCNoticeRemovedEvent")

function TCNoticeRemovedEvent.emptyNew()
    return Event.new(TCNoticeRemovedEvent_mt)
end

function TCNoticeRemovedEvent.new(noticeId)
    local self = TCNoticeRemovedEvent.emptyNew()
    self.noticeId = noticeId
    return self
end

function TCNoticeRemovedEvent:writeStream(streamId, connection)
    streamWriteInt32(streamId, self.noticeId)
end

function TCNoticeRemovedEvent:readStream(streamId, connection)
    self.noticeId = streamReadInt32(streamId)
    self:run(connection)
end

function TCNoticeRemovedEvent:run(connection)
    g_currentMission.TheContractor.Notices:applyNoticeRemoved(self.noticeId)
end
