-- Client asks to set a repair zone's filter (100, TCParkingSlotDialog with
-- TCRepairZoneActivatable.ZONE_ADAPTER); the server checks the zone is the
-- farm's, drops unknown categories, applies it and broadcasts the result. A
-- joining client gets filters with the zones themselves
-- (PlaceableTCRepairZone:onWriteStream). Same shape as
-- TCParkingSlotFilterEvent; see src/events/README.md.

TCRepairZoneFilterEvent = {}
local TCRepairZoneFilterEvent_mt = Class(TCRepairZoneFilterEvent, Event)

InitEventClass(TCRepairZoneFilterEvent, "TCRepairZoneFilterEvent")

function TCRepairZoneFilterEvent.emptyNew()
    return Event.new(TCRepairZoneFilterEvent_mt)
end

function TCRepairZoneFilterEvent.new(zoneId, farmId, filter)
    local self = TCRepairZoneFilterEvent.emptyNew()
    self.zoneId = zoneId
    self.farmId = farmId
    self.filter = filter
    return self
end

function TCRepairZoneFilterEvent:writeStream(streamId, connection)
    streamWriteInt32(streamId, self.zoneId)
    streamWriteInt32(streamId, self.farmId)
    PlaceableTCParkingSlot.writeFilter(streamId, self.filter)
end

function TCRepairZoneFilterEvent:readStream(streamId, connection)
    self.zoneId = streamReadInt32(streamId)
    self.farmId = streamReadInt32(streamId)
    self.filter = PlaceableTCParkingSlot.readFilter(streamId)
    self:run(connection)
end

function TCRepairZoneFilterEvent:run(connection)
    local zone = NetworkUtil.getObject(self.zoneId)
    if zone == nil or not PlaceableTCRepairZone.isZone(zone) then
        return
    end

    if g_currentMission:getIsServer() then
        if zone:getOwnerFarmId() ~= self.farmId then
            return
        end
        local filter = TCRepairZoneActivatable.sanitise(self.filter)
        -- Applied here: the broadcast doesn't loop back in single-player.
        PlaceableTCRepairZone.setFilter(zone, filter)
        TCLog.info("TheContractor: farm %d set a repair zone to take %s", self.farmId,
            TCRepairZoneActivatable.getSummary(zone, filter))
        g_server:broadcastEvent(TCRepairZoneFilterEvent.new(self.zoneId, self.farmId, filter))
    else
        PlaceableTCRepairZone.setFilter(zone, self.filter)
    end
end
