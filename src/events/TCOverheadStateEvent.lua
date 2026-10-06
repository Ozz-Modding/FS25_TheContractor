-- Broadcast-only: one farm's state for one overhead changed (051,
-- TheContractorOverheads:commitState) - taken out, billed, renewed,
-- cancelled, billing switched or lapsed. Sends the whole state, so a client
-- can't drift. See src/events/README.md for the general event conventions.

TCOverheadStateEvent = {}
local TCOverheadStateEvent_mt = Class(TCOverheadStateEvent, Event)

InitEventClass(TCOverheadStateEvent, "TCOverheadStateEvent")

function TCOverheadStateEvent.emptyNew()
    return Event.new(TCOverheadStateEvent_mt)
end

function TCOverheadStateEvent.new(farmId, key, state)
    local self = TCOverheadStateEvent.emptyNew()
    self.farmId = farmId
    self.key = key
    self.state = state
    return self
end

function TCOverheadStateEvent:writeStream(streamId, connection)
    streamWriteInt32(streamId, self.farmId)
    streamWriteString(streamId, self.key)
    TheContractorOverheads.writeState(streamId, self.state)
end

function TCOverheadStateEvent:readStream(streamId, connection)
    self.farmId = streamReadInt32(streamId)
    self.key = streamReadString(streamId)
    self.state = TheContractorOverheads.readState(streamId)
    self:run(connection)
end

function TCOverheadStateEvent:run(connection)
    g_currentMission.TheContractor.Overheads:applyState(self.farmId, self.key, self.state)
end
