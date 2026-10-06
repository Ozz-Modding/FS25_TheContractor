-- Client asks to take out, cancel, keep (undo a cancel) or switch the
-- billing of one of its farm's overheads, from the Finances tab (051). The
-- server re-checks it (TheContractorOverheads:handleRequest); the result
-- goes out as a TCOverheadStateEvent. billing is only used to take one out.
-- See src/events/README.md for the general event conventions.

TCOverheadRequestEvent = {}
local TCOverheadRequestEvent_mt = Class(TCOverheadRequestEvent, Event)

InitEventClass(TCOverheadRequestEvent, "TCOverheadRequestEvent")

function TCOverheadRequestEvent.emptyNew()
    return Event.new(TCOverheadRequestEvent_mt)
end

function TCOverheadRequestEvent.new(farmId, key, request, billing)
    local self = TCOverheadRequestEvent.emptyNew()
    self.farmId = farmId
    self.key = key
    self.request = request
    self.billing = billing or ""
    return self
end

function TCOverheadRequestEvent:writeStream(streamId, connection)
    streamWriteInt32(streamId, self.farmId)
    streamWriteString(streamId, self.key)
    streamWriteString(streamId, self.request)
    streamWriteString(streamId, self.billing)
end

function TCOverheadRequestEvent:readStream(streamId, connection)
    self.farmId = streamReadInt32(streamId)
    self.key = streamReadString(streamId)
    self.request = streamReadString(streamId)
    self.billing = streamReadString(streamId)
    self:run(connection)
end

function TCOverheadRequestEvent:run(connection)
    if g_currentMission:getIsServer() then
        g_currentMission.TheContractor.Overheads:handleRequest(self.farmId, self.key, self.request, self.billing)
    end
end
