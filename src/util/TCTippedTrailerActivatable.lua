-- The "Push the trailer back onto its wheels" prompt (105): one activatable
-- for every tipped trailer, registered at loadMap, built like
-- TCParkingSlotActivatable. It's offered while the local player is on foot
-- within ACTIVATE_DISTANCE of one of their farm's tipped trailers (an open
-- tippedTrailer incident, synced to every machine), and asks the server to
-- right it (TCRightTrailerEvent). The trailer's frozen while it's over, so
-- this is the only way to push it back by hand.
--
-- The activatable system picks the nearest offer, so getDistance is the
-- distance to the trailer.

TCTippedTrailerActivatable = {}
local TCTippedTrailerActivatable_mt = Class(TCTippedTrailerActivatable)

-- From the trailer's origin, which lies at its wheels' edge: a trailer's
-- length either way, and its height across.
TCTippedTrailerActivatable.ACTIVATE_DISTANCE = 7

function TCTippedTrailerActivatable.new()
    local self = setmetatable({}, TCTippedTrailerActivatable_mt)
    self.activateText = g_i18n:getText("tc_tippedTrailer_activate")
    -- The nearest one in reach, from getIsActivatable: its incident id and
    -- distance.
    self.incidentId = nil
    self.distance = math.huge
    return self
end

-- Registered once per load, taken away in deleteMap.
function TCTippedTrailerActivatable.install()
    local system = g_currentMission.activatableObjectsSystem
    if system == nil then
        return
    end
    TCTippedTrailerActivatable.INSTANCE = TCTippedTrailerActivatable.new()
    system:addActivatable(TCTippedTrailerActivatable.INSTANCE)
end

function TCTippedTrailerActivatable.uninstall()
    local activatable = TCTippedTrailerActivatable.INSTANCE
    if activatable == nil then
        return
    end
    local system = g_currentMission ~= nil and g_currentMission.activatableObjectsSystem or nil
    if system ~= nil then
        system:removeActivatable(activatable)
    end
    TCTippedTrailerActivatable.INSTANCE = nil
end

-- The local farm's tipped trailer nearest x, z within ACTIVATE_DISTANCE:
-- its incident id and distance, or nil.
function TCTippedTrailerActivatable.findNearest(x, z)
    local tc = g_currentMission.TheContractor
    local randomEvents = tc ~= nil and tc.RandomEvents or nil
    if randomEvents == nil then
        return nil
    end
    local farmId = g_currentMission:getFarmId()
    local bestId, bestDistance = nil, TCTippedTrailerActivatable.ACTIVATE_DISTANCE
    for _, incident in pairs(randomEvents.incidents) do
        if incident.eventType == TheContractorTippedTrailer.EVENT_TYPE and incident.farmId == farmId and
                incident.stage ~= TheContractorTippedTrailer.STAGE.TIPPED then
            local vehicleId = incident.data.vehicleId
            local trailer = vehicleId ~= nil and vehicleId ~= 0 and NetworkUtil.getObject(vehicleId) or nil
            if trailer ~= nil and not trailer.isDeleted and trailer.rootNode ~= nil then
                local tx, _, tz = getWorldTranslation(trailer.rootNode)
                local distance = MathUtil.vector2Length(x - tx, z - tz)
                if distance <= bestDistance then
                    bestId, bestDistance = incident.id, distance
                end
            end
        end
    end
    return bestId, bestDistance
end

function TCTippedTrailerActivatable:getIsActivatable()
    self.incidentId, self.distance = nil, math.huge
    local player = g_localPlayer
    if player == nil or player.getCurrentVehicle == nil or player:getCurrentVehicle() ~= nil then
        return false
    end
    local x, _, z = player:getPosition()
    local incidentId, distance = TCTippedTrailerActivatable.findNearest(x, z)
    if incidentId == nil then
        return false
    end
    self.incidentId, self.distance = incidentId, distance
    return true
end

function TCTippedTrailerActivatable:getDistance(x, y, z)
    return self.distance
end

function TCTippedTrailerActivatable:run()
    if self.incidentId ~= nil then
        g_client:getServerConnection():sendEvent(TCRightTrailerEvent.new(g_currentMission:getFarmId(),
            self.incidentId))
    end
end
