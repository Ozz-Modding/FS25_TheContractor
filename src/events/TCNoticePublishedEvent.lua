-- Broadcast-only: the server published a notice to a farm's board (038,
-- TheContractorNotices:publish) and sends it to every client. See
-- src/events/README.md for the general event conventions.

TCNoticePublishedEvent = {}
local TCNoticePublishedEvent_mt = Class(TCNoticePublishedEvent, Event)

InitEventClass(TCNoticePublishedEvent, "TCNoticePublishedEvent")

function TCNoticePublishedEvent.emptyNew()
    return Event.new(TCNoticePublishedEvent_mt)
end

function TCNoticePublishedEvent.new(notice)
    local self = TCNoticePublishedEvent.emptyNew()
    self.notice = notice
    return self
end

function TCNoticePublishedEvent:writeStream(streamId, connection)
    TheContractorNotices.writeNotice(streamId, self.notice)
end

function TCNoticePublishedEvent:readStream(streamId, connection)
    self.notice = TheContractorNotices.readNotice(streamId)
    self:run(connection)
end

function TCNoticePublishedEvent:run(connection)
    g_currentMission.TheContractor.Notices:applyNoticePublished(self.notice)
end
