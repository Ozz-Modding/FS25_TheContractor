-- The "Choose who stands here" prompt (120): one activatable for every
-- standing spot, registered at loadMap, offered while the local player is
-- on foot within ACTIVATE_DISTANCE of one of their farm's spots (the
-- spot's whole footprint is barely bigger than the worker standing on it,
-- so it goes by distance rather than by standing inside it). It opens 086's
-- TCParkingSlotDialog with SPOT_ADAPTER: the farm's workers and office
-- staff, those standing on the spot now first. Built like
-- TCParkingSlotActivatable; the nearer prompt wins.

TCStandingSpotActivatable = {}
local TCStandingSpotActivatable_mt = Class(TCStandingSpotActivatable)

-- Metres from the stand node.
TCStandingSpotActivatable.ACTIVATE_DISTANCE = 2

TCStandingSpotActivatable.SPOT_ADAPTER = {
    headingKey = "tc_standingSpot_dialogHeading",
    emptyKey = "tc_standingSpot_nothingToPick",
    getTitle = function()
        return g_i18n:getText("tc_standingSpot_dialogTitle")
    end,
    getHint = function(spot)
        return g_i18n:getText("tc_standingSpot_dialogHint")
    end,
    getFilter = function(spot)
        return PlaceableTCStandingSpot.getFilter(spot)
    end,
    getTickedKeys = function(filter)
        return { staff = filter.staffIds }
    end,
    newFilter = function(keys)
        return PlaceableTCStandingSpot.newFilter(keys.staff)
    end,
    getRows = function(adapter, spot, farmId, filter)
        return TCStandingSpotActivatable.getRows(spot, farmId)
    end,
    getSummary = function(spot, filter)
        return TCStandingSpotActivatable.getSummary(spot:getOwnerFarmId(), filter)
    end,
    send = function(spot, farmId, filter)
        g_client:getServerConnection():sendEvent(TCStandingSpotFilterEvent.new(NetworkUtil.getObjectId(spot), farmId,
            filter))
    end,
}

-- The farm's staff, in a list: { person, isOffice }.
function TCStandingSpotActivatable.getStaff(farmId)
    local tc = g_currentMission.TheContractor
    local staff = {}
    for _, worker in ipairs(tc.Staff:getRoster(farmId)) do
        table.insert(staff, { person = worker, isOffice = false })
    end
    if tc.Office ~= nil then
        for _, member in ipairs(tc.Office:getMembers(farmId)) do
            table.insert(staff, { person = member, isOffice = true })
        end
    end
    return staff
end

-- Dialog rows: whoever's standing on the spot now first, then by name.
function TCStandingSpotActivatable.getRows(spot, farmId)
    local x, _, z = PlaceableTCStandingSpot.getStandPose(spot)
    local spotKey = x ~= nil and TCIdleStaff.getSpotKey(x, z) or nil
    local rows = {}
    for _, entry in ipairs(TCStandingSpotActivatable.getStaff(farmId)) do
        local figure = TCIdleStaff.figures[entry.person.id]
        table.insert(rows, {
            kind = "staff",
            key = entry.person.id,
            title = entry.person.name,
            isHere = figure ~= nil and figure.spot.key == spotKey,
            chipKey = entry.isOffice and "tc_standingSpot_kind_office" or "tc_standingSpot_kind_worker",
        })
    end
    table.sort(rows, function(a, b)
        if a.isHere ~= b.isHere then
            return a.isHere
        end
        if a.title ~= b.title then
            return a.title < b.title
        end
        return a.key < b.key
    end)
    return rows
end

-- "Anyone", or up to SUMMARY_MAX_NAMES names, or a count. Staff who've
-- left don't count.
function TCStandingSpotActivatable.getSummary(farmId, filter)
    local names = {}
    for _, entry in ipairs(TCStandingSpotActivatable.getStaff(farmId)) do
        if filter.staffSet[entry.person.id] then
            table.insert(names, entry.person.name)
        end
    end
    if #names == 0 then
        return g_i18n:getText("tc_standingSpot_keptForAnyone")
    end
    if #names > TCParkingSlotFilter.SUMMARY_MAX_NAMES then
        return string.format(g_i18n:getText("tc_standingSpot_keptForCount"), #names)
    end
    table.sort(names)
    return table.concat(names, ", ")
end

-- Server: the requested filter with anyone who isn't the farm's staff
-- dropped.
function TCStandingSpotActivatable.sanitise(farmId, filter)
    local tc = g_currentMission.TheContractor
    local staffIds = {}
    for _, id in ipairs(filter.staffIds) do
        if TCIdleStaff.isFarmStaff(tc, farmId, id) then
            table.insert(staffIds, id)
        end
    end
    return PlaceableTCStandingSpot.newFilter(staffIds)
end

function TCStandingSpotActivatable.new()
    local self = setmetatable({}, TCStandingSpotActivatable_mt)
    self.activateText = g_i18n:getText("tc_standingSpot_activate")
    -- The spot the player's next to, from getIsActivatable.
    self.spot = nil
    return self
end

-- Registered once per load, taken away in deleteMap.
function TCStandingSpotActivatable.install()
    local system = g_currentMission.activatableObjectsSystem
    if system == nil then
        return
    end
    TCStandingSpotActivatable.INSTANCE = TCStandingSpotActivatable.new()
    system:addActivatable(TCStandingSpotActivatable.INSTANCE)
end

function TCStandingSpotActivatable.uninstall()
    local activatable = TCStandingSpotActivatable.INSTANCE
    if activatable == nil then
        return
    end
    local system = g_currentMission ~= nil and g_currentMission.activatableObjectsSystem or nil
    if system ~= nil then
        system:removeActivatable(activatable)
    end
    TCStandingSpotActivatable.INSTANCE = nil
end

-- The local farm's nearest spot within ACTIVATE_DISTANCE of x, z, or nil.
function TCStandingSpotActivatable.getOwnSpotNear(x, z)
    local placeableSystem = g_currentMission.placeableSystem
    if placeableSystem == nil then
        return nil
    end
    local farmId = g_currentMission:getFarmId()
    local best, bestDistance = nil, TCStandingSpotActivatable.ACTIVATE_DISTANCE
    for _, placeable in ipairs(placeableSystem.placeables) do
        if PlaceableTCStandingSpot.isSpot(placeable) and not placeable.isDeleted and
            not placeable.markedForDeletion and placeable:getOwnerFarmId() == farmId then
            local sx, _, sz = PlaceableTCStandingSpot.getStandPose(placeable)
            if sx ~= nil then
                local distance = MathUtil.vector2Length(x - sx, z - sz)
                if distance <= bestDistance then
                    best, bestDistance = placeable, distance
                end
            end
        end
    end
    return best
end

function TCStandingSpotActivatable:getIsActivatable()
    self.spot = nil
    local player = g_localPlayer
    if player == nil or player.getCurrentVehicle == nil or player:getCurrentVehicle() ~= nil then
        return false
    end
    local x, _, z = player:getPosition()
    self.spot = TCStandingSpotActivatable.getOwnSpotNear(x, z)
    return self.spot ~= nil
end

function TCStandingSpotActivatable:getDistance(x, y, z)
    local sx, _, sz
    if self.spot ~= nil then
        sx, _, sz = PlaceableTCStandingSpot.getStandPose(self.spot)
    end
    if sx == nil then
        return math.huge
    end
    return MathUtil.vector2Length(x - sx, z - sz)
end

function TCStandingSpotActivatable:run()
    if self.spot ~= nil then
        TCParkingSlotDialog.show(self.spot, TCStandingSpotActivatable.SPOT_ADAPTER)
    end
end
