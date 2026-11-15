-- Standing spots and seats in a farmer's yard (154). The standing spot
-- (065) and the seat spot (153) can also go on a yard no player owns, by
-- the host or an admin (as 146's yard centre marker can: the yard is shared
-- by every farm). There they're the yard's farmer's, not the farm's that
-- placed them: no filter (120), our staff never use them, and the farmer
-- picks between them instead of the yard's generated spots
-- (TCYardFarmers.getWanted).
--
-- Which spots are a yard's is where they stand, not a flag: a spot on a
-- valid farmland no player owns. Vanilla only lets a farm place on its own
-- land and won't sell a farmland with a farm's placeables on it, so any
-- spot on unowned land got there by the yard rules here. Nothing of ours is
-- saved or streamed: vanilla saves, streams and deletes the placeable.
--
-- A player buying the farmland takes the spots away: the server sells them
-- for nothing (they cost nothing) and deletes them, which vanilla passes on
-- to the clients.

TCFarmerYardSpots = {}

-- Why a spot can't go on land no player owns: each its own
-- tc_standingSpot_yard_<value> text.
TCFarmerYardSpots.PLACEMENT_ERROR = {
    NO_PERMISSION = "noPermission",
    NOT_A_YARD = "notYard",
}

-- The placement verdict is asked every frame the cursor is out, and yard
-- detection walks every placeable, so a farmland's is kept this long (ms).
TCFarmerYardSpots.CHECK_CACHE_MS = 500

-- Whether the farmland is a valid one no player owns.
function TCFarmerYardSpots.isUnownedFarmland(farmlandId)
    local manager = g_farmlandManager
    if farmlandId == nil or manager == nil then
        return false
    end
    if manager.getIsValidFarmlandId ~= nil and not manager:getIsValidFarmlandId(farmlandId) then
        return false
    end
    return manager:getFarmlandOwner(farmlandId) == FarmlandManager.NO_OWNER_FARM_ID
end

-- The farmland of the farmer's yard a standing or seat spot is in, or nil
-- if it's on a farm's own land.
function TCFarmerYardSpots.getYardFarmlandId(placeable)
    if placeable.getFarmlandId == nil then
        return nil
    end
    local farmlandId = placeable:getFarmlandId()
    if TCFarmerYardSpots.isUnownedFarmland(farmlandId) then
        return farmlandId
    end
    return nil
end

function TCFarmerYardSpots.isYardSpot(placeable)
    return TCFarmerYardSpots.getYardFarmlandId(placeable) ~= nil
end

-- A spot that counts: placed, not the construction cursor's preview, and
-- not on its way out.
function TCFarmerYardSpots.isLiveSpot(placeable)
    if not PlaceableTCStandingSpot.isSpot(placeable) or placeable.isDeleted or placeable.isDeleting or
            placeable.markedForDeletion then
        return false
    end
    return PlaceablePropertyState == nil or placeable.propertyState ~= PlaceablePropertyState.CONSTRUCTION_PREVIEW
end

-- The placed spots in the yard on farmlandId, sorted by key: { key,
-- placeable, x, y, z, yaw, seat (153: PlaceableTCSeatSpot.getSeat's, or
-- nil) }, the same shape as TCIdleStaff's spots. Keys start "placed:", so
-- they never match a generated spot's.
function TCFarmerYardSpots.getPlacedSpots(placeables, farmlandId)
    local spots = {}
    if farmlandId == nil then
        return spots
    end
    for _, placeable in ipairs(placeables or {}) do
        if TCFarmerYardSpots.isLiveSpot(placeable) and TCFarmerYardSpots.getYardFarmlandId(placeable) == farmlandId then
            local x, y, z, yaw = PlaceableTCStandingSpot.getStandPose(placeable)
            if x ~= nil then
                table.insert(spots, { key = "placed:" .. TCIdleStaff.getSpotKey(x, z), placeable = placeable,
                    x = x, y = y, z = z, yaw = yaw, seat = PlaceableTCSeatSpot.getSeat(placeable) })
            end
        end
    end
    table.sort(spots, function(a, b) return a.key < b.key end)
    return spots
end

-- The live map's placeables.
function TCFarmerYardSpots.getMapPlaceables()
    local placeableSystem = g_currentMission ~= nil and g_currentMission.placeableSystem or nil
    return placeableSystem ~= nil and placeableSystem.placeables or {}
end

-- Placement ---------------------------------------------------------------------

-- The PLACEMENT_ERROR stopping a spot going on a farmland no player owns,
-- or nil: the player's permission first, then the land.
function TCFarmerYardSpots.getPlacementError(canChange, isYard)
    if not canChange then
        return TCFarmerYardSpots.PLACEMENT_ERROR.NO_PERMISSION
    elseif not isYard then
        return TCFarmerYardSpots.PLACEMENT_ERROR.NOT_A_YARD
    end
    return nil
end

-- The live map's verdict for an unowned farmland.
function TCFarmerYardSpots.getPlacementErrorOn(farmlandId)
    local tc = g_currentMission.TheContractor
    local isYard = tc ~= nil and tc.Yards ~= nil and tc.Yards:getYard(farmlandId) ~= nil
    return TCFarmerYardSpots.getPlacementError(TheContractorSettings.getCanLocalPlayerChange(), isYard)
end

-- For a spot being placed at x, z: nil on a farm's land (vanilla's rules
-- apply), else { farmlandId, error } for a yard placement, error nil if it
-- may go there. data.check caches it per farmland (CHECK_CACHE_MS).
function TCFarmerYardSpots.getYardCheck(data, x, z)
    local farmlandId = g_farmlandManager:getFarmlandIdAtWorldPosition(x, z)
    if not TCFarmerYardSpots.isUnownedFarmland(farmlandId) then
        return nil
    end
    local now = g_time or 0
    local check = data.yardCheck
    if check == nil or check.farmlandId ~= farmlandId or now - check.time > TCFarmerYardSpots.CHECK_CACHE_MS then
        check = { farmlandId = farmlandId, time = now, error = TCFarmerYardSpots.getPlacementErrorOn(farmlandId) }
        data.yardCheck = check
    end
    return check
end

-- Land changing hands (server) ----------------------------------------------------

function TCFarmerYardSpots.startListening()
    if g_currentMission:getIsServer() then
        g_messageCenter:subscribe(MessageType.FARMLAND_OWNER_CHANGED, TCFarmerYardSpots.onFarmlandOwnerChanged,
            TCFarmerYardSpots)
    end
end

function TCFarmerYardSpots.stopListening()
    g_messageCenter:unsubscribe(MessageType.FARMLAND_OWNER_CHANGED, TCFarmerYardSpots)
end

-- The yard spots standing on a farmland, live ones only.
function TCFarmerYardSpots.getSpotsOn(placeables, farmlandId)
    local found = {}
    for _, placeable in ipairs(placeables or {}) do
        if TCFarmerYardSpots.isLiveSpot(placeable) and placeable.getFarmlandId ~= nil and
                placeable:getFarmlandId() == farmlandId then
            table.insert(found, placeable)
        end
    end
    return found
end

-- Every spot on a farmland that's just gained an owner was a yard's (a
-- farm can't place on land it doesn't own), so they all go. A savegame's
-- own land is as it was saved.
function TCFarmerYardSpots:onFarmlandOwnerChanged(farmlandId, farmId, loadFromSavegame)
    if loadFromSavegame or farmId == FarmlandManager.NO_OWNER_FARM_ID then
        return
    end
    for _, placeable in ipairs(TCFarmerYardSpots.getSpotsOn(TCFarmerYardSpots.getMapPlaceables(), farmlandId)) do
        TCLog.info("TheContractor: farmland %d bought by farm %d, removing a farmer's yard spot from it",
            farmlandId, farmId)
        placeable:onSell()
        placeable:delete()
    end
end
