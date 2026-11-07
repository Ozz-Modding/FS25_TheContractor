-- The "View lot 12: <name>" prompt (138): one activatable for every
-- auction lot, registered at loadMap, built like TCTippedTrailerActivatable.
-- It's offered while the local player is on foot within ACTIVATE_DISTANCE of
-- a lot's machine (or the header in front of it), measured from the edge of
-- its size box, so a combine and a mower are both in reach from beside
-- them. Activating it opens the lot's card (TCAuctionLotDialog). Everything
-- it needs is the site's synced lots, so it works the same on every
-- machine, a client that's just joined included (a lot whose vehicle
-- hasn't streamed in yet just isn't offered).
--
-- The activatable system picks the nearest offer, so getDistance is the
-- distance to the lot.

TCAuctionLotActivatable = {}
local TCAuctionLotActivatable_mt = Class(TCAuctionLotActivatable)

-- Metres from the machine's size box.
TCAuctionLotActivatable.ACTIVATE_DISTANCE = 3
-- Lots whose root is further than this aren't measured at all.
TCAuctionLotActivatable.SEARCH_DISTANCE = 25

function TCAuctionLotActivatable.new()
    local self = setmetatable({}, TCAuctionLotActivatable_mt)
    -- The text changes with the lot (getIsActivatable); the system reads it
    -- every frame.
    self.activateText = g_i18n:getText("tc_auctionLot_viewGeneric")
    self.lotNumber = nil
    self.distance = math.huge
    return self
end

-- Registered once per load, taken away in deleteMap.
function TCAuctionLotActivatable.install()
    local system = g_currentMission.activatableObjectsSystem
    if system == nil then
        return
    end
    TCAuctionLotActivatable.INSTANCE = TCAuctionLotActivatable.new()
    system:addActivatable(TCAuctionLotActivatable.INSTANCE)
end

function TCAuctionLotActivatable.uninstall()
    local activatable = TCAuctionLotActivatable.INSTANCE
    if activatable == nil then
        return
    end
    local system = g_currentMission ~= nil and g_currentMission.activatableObjectsSystem or nil
    if system ~= nil then
        system:removeActivatable(activatable)
    end
    TCAuctionLotActivatable.INSTANCE = nil
end

-- How far a point in a vehicle's own frame (lx across, lz along) is from
-- its size box (pure): 0 inside. size: vehicle.size's width, length,
-- widthOffset and lengthOffset (the box's centre from the root).
function TCAuctionLotActivatable.getBoxDistance(lx, lz, size)
    local dx = math.max(math.abs(lx - (size.widthOffset or 0)) - size.width * 0.5, 0)
    local dz = math.max(math.abs(lz - (size.lengthOffset or 0)) - size.length * 0.5, 0)
    return math.sqrt(dx * dx + dz * dz)
end

local function getVehicle(vehicleId)
    local vehicle = vehicleId ~= nil and NetworkUtil.getObject(vehicleId) or nil
    if vehicle == nil or vehicle.isDeleted or vehicle.rootNode == nil or vehicle.size == nil then
        return nil
    end
    return vehicle
end

-- A point's distance from a vehicle's size box, or nil if it's out of reach
-- of searching.
local function getVehicleDistance(vehicle, x, y, z)
    local vx, _, vz = getWorldTranslation(vehicle.rootNode)
    if MathUtil.vector2Length(x - vx, z - vz) > TCAuctionLotActivatable.SEARCH_DISTANCE then
        return nil
    end
    local lx, _, lz = worldToLocal(vehicle.rootNode, x, y, z)
    return TCAuctionLotActivatable.getBoxDistance(lx, lz, vehicle.size)
end

-- The lot nearest x, y, z within ACTIVATE_DISTANCE: the lot and distance,
-- or nil.
function TCAuctionLotActivatable.findNearest(x, y, z)
    local tc = g_currentMission.TheContractor
    local site = tc ~= nil and tc.AuctionSite or nil
    if site == nil then
        return nil
    end
    local best, bestDistance = nil, TCAuctionLotActivatable.ACTIVATE_DISTANCE
    for _, lot in ipairs(site:getLots()) do
        -- 139: a lot a farm's won is that farm's machine now, not a lot.
        if lot.vehicleId ~= nil and (lot.result or 0) ~= TheContractorAuctionSite.RESULT.FARM then
            for _, vehicleId in ipairs({ lot.vehicleId, lot.attachmentId or false }) do
                local vehicle = vehicleId and getVehicle(vehicleId) or nil
                local distance = vehicle ~= nil and getVehicleDistance(vehicle, x, y, z) or nil
                if distance ~= nil and distance <= bestDistance then
                    best, bestDistance = lot, distance
                end
            end
        end
    end
    return best, bestDistance
end

function TCAuctionLotActivatable:getIsActivatable()
    self.lotNumber, self.distance = nil, math.huge
    local player = g_localPlayer
    if player == nil or player.getCurrentVehicle == nil or player:getCurrentVehicle() ~= nil then
        return false
    end
    local tc = g_currentMission.TheContractor
    if tc == nil or tc.AuctionSite == nil or #tc.AuctionSite:getLots() == 0 then
        return false
    end
    local x, y, z = player:getPosition()
    local lot, distance = TCAuctionLotActivatable.findNearest(x, y, z)
    if lot == nil then
        return false
    end
    if lot.vehicleId ~= self.shownVehicleId then
        self.shownVehicleId = lot.vehicleId
        self.activateText = string.format(g_i18n:getText("tc_auctionLot_view"), lot.number,
            TheContractorAuctionSite.getLotName(lot))
    end
    self.lotNumber, self.distance = lot.number, distance
    return true
end

function TCAuctionLotActivatable:getDistance(x, y, z)
    return self.distance
end

function TCAuctionLotActivatable:run()
    if self.lotNumber ~= nil then
        TCAuctionLotDialog.show(self.lotNumber)
    end
end
