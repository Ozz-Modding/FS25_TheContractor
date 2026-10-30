-- Client asks to keep a standing spot for some staff (120,
-- TCParkingSlotDialog with TCStandingSpotActivatable.SPOT_ADAPTER); the
-- server checks the spot is the farm's, drops anyone who isn't the farm's
-- staff (TCStandingSpotActivatable.sanitise), applies it and broadcasts the
-- result. A joining client gets filters with the spots themselves
-- (PlaceableTCStandingSpot:onWriteStream). See src/events/README.md for the
-- general event conventions.

TCStandingSpotFilterEvent = {}
local TCStandingSpotFilterEvent_mt = Class(TCStandingSpotFilterEvent, Event)

InitEventClass(TCStandingSpotFilterEvent, "TCStandingSpotFilterEvent")

function TCStandingSpotFilterEvent.emptyNew()
    return Event.new(TCStandingSpotFilterEvent_mt)
end

function TCStandingSpotFilterEvent.new(spotId, farmId, filter)
    local self = TCStandingSpotFilterEvent.emptyNew()
    self.spotId = spotId
    self.farmId = farmId
    self.filter = filter
    return self
end

function TCStandingSpotFilterEvent:writeStream(streamId, connection)
    streamWriteInt32(streamId, self.spotId)
    streamWriteInt32(streamId, self.farmId)
    PlaceableTCStandingSpot.writeFilter(streamId, self.filter)
end

function TCStandingSpotFilterEvent:readStream(streamId, connection)
    self.spotId = streamReadInt32(streamId)
    self.farmId = streamReadInt32(streamId)
    self.filter = PlaceableTCStandingSpot.readFilter(streamId)
    self:run(connection)
end

function TCStandingSpotFilterEvent:run(connection)
    local spot = NetworkUtil.getObject(self.spotId)
    if spot == nil or not PlaceableTCStandingSpot.isSpot(spot) then
        return
    end

    if g_currentMission:getIsServer() then
        if spot:getOwnerFarmId() ~= self.farmId then
            return
        end
        local filter = TCStandingSpotActivatable.sanitise(self.farmId, self.filter)
        -- Applied here: the broadcast doesn't loop back in single-player.
        PlaceableTCStandingSpot.setFilter(spot, filter)
        TCLog.info("TheContractor: farm %d kept a standing spot for %s", self.farmId,
            TCStandingSpotActivatable.getSummary(self.farmId, filter))
        -- To every client, the requester included: it only sent a request.
        g_server:broadcastEvent(TCStandingSpotFilterEvent.new(self.spotId, self.farmId, filter))
    else
        PlaceableTCStandingSpot.setFilter(spot, self.filter)
    end
end
