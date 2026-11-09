-- A farmland's yard override (108). Client -> server (117, the map's
-- Set/Unset as farmer yard): the server checks the sender is the host or
-- an admin and the farmland and mode are real, then sets it as tcYard
-- set does. Server -> client: the server has set it (TheContractorYards:
-- setOverride) and the clients apply it.

TCYardOverrideEvent = {}
local TCYardOverrideEvent_mt = Class(TCYardOverrideEvent, Event)

InitEventClass(TCYardOverrideEvent, "TCYardOverrideEvent")

function TCYardOverrideEvent.emptyNew()
    return Event.new(TCYardOverrideEvent_mt)
end

function TCYardOverrideEvent.new(farmlandId, mode)
    local self = TCYardOverrideEvent.emptyNew()
    self.farmlandId = farmlandId
    self.mode = mode
    return self
end

-- Client: asks the server to set a farmland's override.
function TCYardOverrideEvent.sendRequest(farmlandId, mode)
    g_client:getServerConnection():sendEvent(TCYardOverrideEvent.new(farmlandId, mode))
end

function TCYardOverrideEvent:writeStream(streamId, connection)
    streamWriteInt32(streamId, self.farmlandId)
    streamWriteUInt8(streamId, self.mode)
end

function TCYardOverrideEvent:readStream(streamId, connection)
    self.farmlandId = streamReadInt32(streamId)
    self.mode = streamReadUInt8(streamId)
    self:run(connection)
end

function TCYardOverrideEvent:run(connection)
    local yards = g_currentMission.TheContractor.Yards
    if connection:getIsServer() then
        yards:applyOverride(self.farmlandId, self.mode)
        return
    end
    if not TheContractorSettings.getCanConnectionChange(connection) then
        TCLog.warning("TheContractor: refused a yard override for farmland %s from a player who isn't an admin",
            tostring(self.farmlandId))
        return
    end
    if TheContractorYards.MODE_NAMES[self.mode] == nil or
            not g_farmlandManager:getIsValidFarmlandId(self.farmlandId) then
        TCLog.warning("TheContractor: refused a yard override for farmland %s (mode %s)",
            tostring(self.farmlandId), tostring(self.mode))
        return
    end
    yards:setOverride(self.farmlandId, self.mode)
end
