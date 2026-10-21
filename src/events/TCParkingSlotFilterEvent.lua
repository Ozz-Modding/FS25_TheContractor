-- Client asks to set a parking slot's filter (086, TCParkingSlotDialog);
-- the server checks the slot is the farm's, drops anything from the filter
-- that doesn't belong (TCParkingSlotFilter.sanitise), applies it and
-- broadcasts the result. A joining client gets filters with the slots
-- themselves (PlaceableTCParkingSlot:onWriteStream). See
-- src/events/README.md for the general event conventions.

TCParkingSlotFilterEvent = {}
local TCParkingSlotFilterEvent_mt = Class(TCParkingSlotFilterEvent, Event)

InitEventClass(TCParkingSlotFilterEvent, "TCParkingSlotFilterEvent")

function TCParkingSlotFilterEvent.emptyNew()
    return Event.new(TCParkingSlotFilterEvent_mt)
end

function TCParkingSlotFilterEvent.new(slotId, farmId, filter)
    local self = TCParkingSlotFilterEvent.emptyNew()
    self.slotId = slotId
    self.farmId = farmId
    self.filter = filter
    return self
end

function TCParkingSlotFilterEvent:writeStream(streamId, connection)
    streamWriteInt32(streamId, self.slotId)
    streamWriteInt32(streamId, self.farmId)
    PlaceableTCParkingSlot.writeFilter(streamId, self.filter)
end

function TCParkingSlotFilterEvent:readStream(streamId, connection)
    self.slotId = streamReadInt32(streamId)
    self.farmId = streamReadInt32(streamId)
    self.filter = PlaceableTCParkingSlot.readFilter(streamId)
    self:run(connection)
end

function TCParkingSlotFilterEvent:run(connection)
    local slot = NetworkUtil.getObject(self.slotId)
    if slot == nil or not PlaceableTCParkingSlot.isSlot(slot) then
        return
    end

    if g_currentMission:getIsServer() then
        if slot:getOwnerFarmId() ~= self.farmId then
            return
        end
        local filter = TCParkingSlotFilter.sanitise(slot, self.farmId, self.filter)
        -- Applied here: the broadcast doesn't loop back in single-player.
        PlaceableTCParkingSlot.setFilter(slot, filter)
        Logging.info("TheContractor: farm %d set a parking slot to take %s", self.farmId,
            TCParkingSlotFilter.getSummary(slot, filter))
        -- To every client, the requester included: it only sent a request.
        g_server:broadcastEvent(TCParkingSlotFilterEvent.new(self.slotId, self.farmId, filter))
    else
        PlaceableTCParkingSlot.setFilter(slot, self.filter)
    end
end
