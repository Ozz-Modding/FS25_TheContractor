-- Client asks to take out, cancel, keep (undo a cancel), switch the billing
-- of, or change the level of cover of one of its farm's overheads, from the
-- Finances tab (051, 070). The server re-checks it
-- (TheContractorOverheads:handleRequest); the result goes out as a
-- TCOverheadStateEvent. billing is only used to take one out, level to take
-- one with levels out or change it ("" for none).
-- See src/events/README.md for the general event conventions.

TCOverheadRequestEvent = {}
local TCOverheadRequestEvent_mt = Class(TCOverheadRequestEvent, Event)

InitEventClass(TCOverheadRequestEvent, "TCOverheadRequestEvent")

function TCOverheadRequestEvent.emptyNew()
    return Event.new(TCOverheadRequestEvent_mt)
end

function TCOverheadRequestEvent.new(farmId, key, request, billing, level)
    local self = TCOverheadRequestEvent.emptyNew()
    self.farmId = farmId
    self.key = key
    self.request = request
    self.billing = billing or ""
    self.level = level or ""
    return self
end

function TCOverheadRequestEvent:writeStream(streamId, connection)
    streamWriteInt32(streamId, self.farmId)
    streamWriteString(streamId, self.key)
    streamWriteString(streamId, self.request)
    streamWriteString(streamId, self.billing)
    streamWriteString(streamId, self.level)
end

function TCOverheadRequestEvent:readStream(streamId, connection)
    self.farmId = streamReadInt32(streamId)
    self.key = streamReadString(streamId)
    self.request = streamReadString(streamId)
    self.billing = streamReadString(streamId)
    self.level = streamReadString(streamId)
    self:run(connection)
end

function TCOverheadRequestEvent:run(connection)
    if g_currentMission:getIsServer() then
        g_currentMission.TheContractor.Overheads:handleRequest(self.farmId, self.key, self.request, self.billing,
            self.level ~= "" and self.level or nil)
    end
end
