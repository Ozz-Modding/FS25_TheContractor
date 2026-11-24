-- Server -> clients (167): the show's livestock entries, whole, each time
-- one's made or withdrawn, the entries are judged, or they start again for
-- a new show. Every farm's entries, with their placings and the stats that
-- counted once judged; never a score, the judge's eye or a farmer's entry
-- (ShowLivestock.writeState). Also the livestock's part of the initial
-- client state.

TCShowLivestockEvent = {}
local TCShowLivestockEvent_mt = Class(TCShowLivestockEvent, Event)

InitEventClass(TCShowLivestockEvent, "TCShowLivestockEvent")

function TCShowLivestockEvent.emptyNew()
    return Event.new(TCShowLivestockEvent_mt)
end

-- livestock: the server's TheContractorShowLivestock.
function TCShowLivestockEvent.new(livestock)
    local self = TCShowLivestockEvent.emptyNew()
    self.livestock = livestock
    return self
end

function TCShowLivestockEvent:writeStream(streamId, connection)
    TheContractorShowLivestock.writeState(streamId, self.livestock)
end

function TCShowLivestockEvent:readStream(streamId, connection)
    self.state = TheContractorShowLivestock.readState(streamId)
    self:run(connection)
end

function TCShowLivestockEvent:run(connection)
    if not connection:getIsServer() then
        -- Only the server says what the entries are.
        return
    end
    local livestock = g_currentMission.TheContractor ~= nil and g_currentMission.TheContractor.ShowLivestock or nil
    if livestock ~= nil and self.state ~= nil then
        livestock:applyState(self.state)
    end
end
