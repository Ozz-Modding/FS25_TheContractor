-- Dividing the land between farmers (109, a spike): how the map's fields
-- would be shared out among the generated farmers (110), previewed from the
-- console so the numbers can be tuned before anything is saved.
--
-- Only farmlands with at least one field and no player owner are split; a
-- farmland's size is its fields' area in acres, and it sits in the middle
-- of its fields (by area). Every one of them goes to a farmer.
--
-- split() is pure (farmlands, yards and a seed in, farmers out) and draws
-- only from its own seeded generator, so the same seed always gives the
-- same split:
--   1. Count: max(MIN_FARMERS, round(total / target)), no more than there
--      are farmlands. Each farmer's target is the average scaled by up to
--      +-SIZE_SPREAD, normalised so the targets add up to the total.
--   2. Starts: yards on or within MAX_YARD_DISTANCE of field land, the
--      most yard-like first (isMoreYardLike), each start a farmer; a small
--      yard (isSmallYard) never does. The rest start on the farmland
--      furthest
--      from every start so far (a random one when there's none yet).
--   3. Sharing out: a farmer with no land takes the farmland nearest their
--      start; then, until none is left, the farmer furthest below target
--      takes the unclaimed farmland nearest their land.
--   4. Balancing: a farmland moves to another farmer whose land is within
--      MAX_SWAP_DISTANCE of it whenever that brings both nearer their
--      targets, until nothing improves.
--   5. Yards: a yard that didn't start a farmer (a small one's only way
--      in, a last resort), the most yard-like first, goes to the farmer
--      whose land is nearest, if they have no yard and it's within
--      MAX_YARD_DISTANCE. A yard the player declared (117) goes to the
--      nearest farmer without one, however far.
--
-- A declared yard's farmland is never field land, so it's never shared
-- out (splitLiveMap leaves it out).
--
-- Nothing here is saved or synced: 110's TheContractorFarmers runs the
-- split once and keeps the result, and tcCompany farmers preview|show
-- previews a split and marks it on this machine's map.

TheContractorFarmerSplit = {}

-- Acres per farmer: 30 to start with, raised to 50 after 111's first look
-- in game (fewer farmers, each with more land).
TheContractorFarmerSplit.TARGET_ACRES = 50
TheContractorFarmerSplit.MIN_FARMERS = 4
-- How far a farmer's target can stray from the average, either way.
TheContractorFarmerSplit.SIZE_SPREAD = 0.3
-- Metres, between farmland middles (and a yard).
TheContractorFarmerSplit.MAX_SWAP_DISTANCE = 600
TheContractorFarmerSplit.MAX_YARD_DISTANCE = 400
-- Safety cap on the balancing passes (each pass that moves anything makes
-- the split strictly better, so it ends anyway).
TheContractorFarmerSplit.MAX_SWAP_PASSES = 200

TheContractorFarmerSplit.ACRES_PER_HA = 2.471

-- Map markers (this machine only): one colour per farmer, round again
-- after the last.
TheContractorFarmerSplit.MARKER_COLORS = {
    { 0.90, 0.20, 0.20, 1 },
    { 0.20, 0.55, 0.95, 1 },
    { 0.25, 0.80, 0.30, 1 },
    { 0.95, 0.75, 0.10, 1 },
    { 0.70, 0.35, 0.90, 1 },
    { 0.10, 0.80, 0.80, 1 },
    { 0.95, 0.50, 0.15, 1 },
    { 0.95, 0.45, 0.70, 1 },
}

-- nil when off, else the markers shown.
TheContractorFarmerSplit.hotspots = nil

-- A seeded generator (Park-Miller), [0, 1). math.random would share its
-- state with everything else in the game.
function TheContractorFarmerSplit.newRandom(seed)
    local state = math.floor(math.abs(seed or 1)) % 2147483646 + 1
    return function()
        state = (state * 16807) % 2147483647
        return (state - 1) / 2147483646
    end
end

-- A yard with this many yard buildings (108's YARD_CATEGORIES) or fewer is
-- small: a house and a shed or two. It never starts a farmer, and is handed
-- out after every bigger one.
TheContractorFarmerSplit.SMALL_YARD_BUILDINGS = 4

-- Whether a yard is small (see SMALL_YARD_BUILDINGS). One the player
-- declared (117) never is.
function TheContractorFarmerSplit.isSmallYard(yard)
    return not yard.declared and (yard.buildings or 0) <= TheContractorFarmerSplit.SMALL_YARD_BUILDINGS
end

-- Whether yard a is more yard-like than b, so it's handed out first: one
-- the player declared (117); then one that isn't small; then one without a
-- sell point (a farm shop or a buyer is less of a farm); then the more
-- yard buildings; then the more sheds and farmhouses (its anchors). nil
-- when they're level, for the caller's own tie-break.
function TheContractorFarmerSplit.isMoreYardLike(a, b)
    if (a.declared == true) ~= (b.declared == true) then
        return a.declared == true
    end
    local aSmall, bSmall = TheContractorFarmerSplit.isSmallYard(a), TheContractorFarmerSplit.isSmallYard(b)
    if aSmall ~= bSmall then
        return not aSmall
    end
    if (a.sells == true) ~= (b.sells == true) then
        return b.sells == true
    end
    if (a.buildings or 0) ~= (b.buildings or 0) then
        return (a.buildings or 0) > (b.buildings or 0)
    end
    if (a.anchors or 0) ~= (b.anchors or 0) then
        return (a.anchors or 0) > (b.anchors or 0)
    end
    return nil
end

local function distance(ax, az, bx, bz)
    local dx, dz = ax - bx, az - bz
    return math.sqrt(dx * dx + dz * dz)
end

-- The distance from x, z to the nearest of the farmer's farmlands (bar
-- `except`), or to their start with none.
local function distanceToLand(farmer, byId, x, z, except)
    local nearest = math.huge
    for farmlandId in pairs(farmer.farmlandIds) do
        if farmlandId ~= except then
            local farmland = byId[farmlandId]
            nearest = math.min(nearest, distance(farmland.x, farmland.z, x, z))
        end
    end
    if nearest == math.huge and except == nil then
        nearest = distance(farmer.x, farmer.z, x, z)
    end
    return nearest
end

local function claim(farmer, farmland, owners)
    farmer.farmlandIds[farmland.id] = true
    farmer.acres = farmer.acres + farmland.acres
    owners[farmland.id] = farmer
end

local function release(farmer, farmland, owners)
    farmer.farmlandIds[farmland.id] = nil
    farmer.acres = farmer.acres - farmland.acres
    owners[farmland.id] = nil
end

local function countKeys(set)
    local count = 0
    for _ in pairs(set) do
        count = count + 1
    end
    return count
end

-- The unclaimed farmland nearest the farmer's land (ties to the lowest id).
local function nearestUnclaimed(farmer, farmlands, byId, owners)
    local best, bestDistance = nil, math.huge
    for _, farmland in ipairs(farmlands) do
        if owners[farmland.id] == nil then
            local d = distanceToLand(farmer, byId, farmland.x, farmland.z)
            if d < bestDistance then
                best, bestDistance = farmland, d
            end
        end
    end
    return best
end

-- The farmers' targets: the average, each scaled by up to +-SIZE_SPREAD,
-- normalised so they add up to the total.
function TheContractorFarmerSplit.getTargets(totalAcres, count, random)
    local factors, sum = {}, 0
    for i = 1, count do
        factors[i] = 1 + (random() * 2 - 1) * TheContractorFarmerSplit.SIZE_SPREAD
        sum = sum + factors[i]
    end
    local targets = {}
    for i = 1, count do
        targets[i] = totalAcres * factors[i] / sum
    end
    return targets
end

-- Steps 1 and 2: the farmers, each with a target and a start, the yard
-- starts already holding their yard's farmland if it's eligible.
local function makeStarts(farmlands, byId, yards, targets, random, owners)
    local S = TheContractorFarmerSplit
    local farmers = {}
    local function newFarmer(x, z)
        local farmer = { index = #farmers + 1, x = x, z = z, farmlandIds = {}, acres = 0 }
        farmer.target = targets[farmer.index]
        table.insert(farmers, farmer)
        return farmer
    end

    -- Yards on or near field land, the most yard-like first, then the
    -- nearest.
    local candidates = {}
    for _, yard in ipairs(yards) do
        local d = 0
        if byId[yard.farmlandId] == nil then
            d = math.huge
            for _, farmland in ipairs(farmlands) do
                d = math.min(d, distance(farmland.x, farmland.z, yard.x, yard.z))
            end
        end
        if d <= S.MAX_YARD_DISTANCE and not S.isSmallYard(yard) then
            table.insert(candidates, { yard = yard, distance = d })
        end
    end
    table.sort(candidates, function(a, b)
        local better = S.isMoreYardLike(a.yard, b.yard)
        if better ~= nil then
            return better
        end
        if a.distance ~= b.distance then
            return a.distance < b.distance
        end
        return a.yard.farmlandId < b.yard.farmlandId
    end)
    for _, candidate in ipairs(candidates) do
        if #farmers >= #targets then
            break
        end
        local yard = candidate.yard
        local farmer = newFarmer(yard.x, yard.z)
        farmer.yardFarmlandId = yard.farmlandId
        farmer.startedAtYard = true
        local farmland = byId[yard.farmlandId]
        if farmland ~= nil and owners[farmland.id] == nil then
            claim(farmer, farmland, owners)
        end
    end

    -- The rest, spread out.
    while #farmers < #targets do
        local start
        if #farmers == 0 then
            start = farmlands[math.min(math.floor(random() * #farmlands) + 1, #farmlands)]
        else
            local bestDistance = -1
            for _, farmland in ipairs(farmlands) do
                if owners[farmland.id] == nil then
                    local nearest = math.huge
                    for _, farmer in ipairs(farmers) do
                        nearest = math.min(nearest, distance(farmer.x, farmer.z, farmland.x, farmland.z))
                    end
                    if nearest > bestDistance then
                        start, bestDistance = farmland, nearest
                    end
                end
            end
        end
        local farmer = newFarmer(start.x, start.z)
        claim(farmer, start, owners)
    end
    return farmers
end

-- Step 4: moves farmlands between neighbours while that brings both nearer
-- their targets. Returns how many moves were made.
local function balance(farmlands, byId, farmers, owners)
    local S = TheContractorFarmerSplit
    local moves = 0
    for _ = 1, S.MAX_SWAP_PASSES do
        local moved = false
        for _, farmland in ipairs(farmlands) do
            local from = owners[farmland.id]
            if countKeys(from.farmlandIds) > 1 then
                local fromError = from.acres - from.target
                local best, bestGain = nil, 0
                for _, to in ipairs(farmers) do
                    if to ~= from and distanceToLand(to, byId, farmland.x, farmland.z, farmland.id) <=
                            S.MAX_SWAP_DISTANCE then
                        local toError = to.acres - to.target
                        local newFrom = math.abs(fromError - farmland.acres)
                        local newTo = math.abs(toError + farmland.acres)
                        if newFrom < math.abs(fromError) and newTo < math.abs(toError) then
                            local gain = math.abs(fromError) + math.abs(toError) - newFrom - newTo
                            if gain > bestGain then
                                best, bestGain = to, gain
                            end
                        end
                    end
                end
                if best ~= nil then
                    release(from, farmland, owners)
                    claim(best, farmland, owners)
                    moves = moves + 1
                    moved = true
                end
            end
        end
        if not moved then
            break
        end
    end
    return moves
end

-- Step 5: the yards that didn't start a farmer.
local function giveYards(yards, byId, farmers)
    local S = TheContractorFarmerSplit
    local taken = {}
    for _, farmer in ipairs(farmers) do
        if farmer.yardFarmlandId ~= nil then
            taken[farmer.yardFarmlandId] = true
        end
    end
    local sorted = {}
    for _, yard in ipairs(yards) do
        if not taken[yard.farmlandId] then
            table.insert(sorted, yard)
        end
    end
    table.sort(sorted, function(a, b)
        local better = S.isMoreYardLike(a, b)
        if better ~= nil then
            return better
        end
        return a.farmlandId < b.farmlandId
    end)
    for _, yard in ipairs(sorted) do
        -- 117: a declared yard goes to the nearest farmer without one,
        -- however far.
        local nearest, nearestDistance = nil, math.huge
        for _, farmer in ipairs(farmers) do
            if not yard.declared or farmer.yardFarmlandId == nil then
                local d = farmer.farmlandIds[yard.farmlandId] and 0 or distanceToLand(farmer, byId, yard.x, yard.z)
                if nearest == nil or d < nearestDistance then
                    nearest, nearestDistance = farmer, d
                end
            end
        end
        if nearest ~= nil and nearest.yardFarmlandId == nil and
                (yard.declared or nearestDistance <= S.MAX_YARD_DISTANCE) then
            nearest.yardFarmlandId = yard.farmlandId
        end
    end
end

-- farmlands: { id, x, z, acres } (eligible ones only). yards: { farmlandId,
-- x, z } (no player owner). Returns { farmers, totalAcres, moves }, each
-- farmer { index, target, acres, farmlandIds (sorted list), yardFarmlandId
-- (or nil), startedAtYard, x, z (start) }, and owners: farmlandId ->
-- farmer index.
function TheContractorFarmerSplit.split(farmlands, yards, targetAcres, seed)
    local S = TheContractorFarmerSplit
    local random = S.newRandom(seed)
    local sorted, byId, totalAcres = {}, {}, 0
    for _, farmland in ipairs(farmlands) do
        table.insert(sorted, farmland)
        byId[farmland.id] = farmland
        totalAcres = totalAcres + farmland.acres
    end
    table.sort(sorted, function(a, b)
        return a.id < b.id
    end)
    local result = { farmers = {}, owners = {}, totalAcres = totalAcres, moves = 0 }
    if #sorted == 0 then
        return result
    end

    local count = math.max(S.MIN_FARMERS, math.floor(totalAcres / math.max(targetAcres, 1) + 0.5))
    count = math.min(count, #sorted)
    local targets = S.getTargets(totalAcres, count, random)

    local owners = {}
    local farmers = makeStarts(sorted, byId, yards, targets, random, owners)

    -- Everyone holds something before anyone takes a second share.
    for _, farmer in ipairs(farmers) do
        if farmer.acres == 0 and next(farmer.farmlandIds) == nil then
            local farmland = nearestUnclaimed(farmer, sorted, byId, owners)
            if farmland ~= nil then
                claim(farmer, farmland, owners)
            end
        end
    end
    while true do
        local neediest = nil
        for _, farmer in ipairs(farmers) do
            if neediest == nil or farmer.target - farmer.acres > neediest.target - neediest.acres then
                neediest = farmer
            end
        end
        local farmland = nearestUnclaimed(neediest, sorted, byId, owners)
        if farmland == nil then
            break
        end
        claim(neediest, farmland, owners)
    end

    result.moves = balance(sorted, byId, farmers, owners)
    giveYards(yards, byId, farmers)

    for _, farmer in ipairs(farmers) do
        local ids = {}
        for farmlandId in pairs(farmer.farmlandIds) do
            table.insert(ids, farmlandId)
        end
        table.sort(ids)
        farmer.farmlandIds = ids
        for _, farmlandId in ipairs(ids) do
            result.owners[farmlandId] = farmer.index
        end
    end
    result.farmers = farmers
    return result
end

-- The live map -------------------------------------------------------------------

-- Every farmland with a field, whoever owns it: { id, x, z (middle of its
-- fields, by area), acres, ownerFarmId }, by id. 110 needs the owned ones
-- too, for land changing hands.
function TheContractorFarmerSplit.getFieldFarmlands()
    local S = TheContractorFarmerSplit
    local byId, list = {}, {}
    if g_fieldManager == nil or g_farmlandManager == nil then
        return list
    end
    for _, field in ipairs(g_fieldManager:getFields() or {}) do
        local farmland = field.getFarmland ~= nil and field:getFarmland() or nil
        local areaHa = field.getAreaHa ~= nil and field:getAreaHa() or 0
        if farmland ~= nil and areaHa ~= nil and areaHa > 0 then
            local farmlandId = farmland:getId()
            local entry = byId[farmlandId]
            if entry == nil then
                entry = { id = farmlandId, sumX = 0, sumZ = 0, areaHa = 0 }
                byId[farmlandId] = entry
                table.insert(list, entry)
            end
            local x, z = field:getCenterOfFieldWorldPosition()
            entry.sumX, entry.sumZ = entry.sumX + x * areaHa, entry.sumZ + z * areaHa
            entry.areaHa = entry.areaHa + areaHa
        end
    end
    local farmlands = {}
    for _, entry in ipairs(list) do
        table.insert(farmlands, { id = entry.id, x = entry.sumX / entry.areaHa, z = entry.sumZ / entry.areaHa,
            acres = entry.areaHa * S.ACRES_PER_HA, ownerFarmId = g_farmlandManager:getFarmlandOwner(entry.id) })
    end
    table.sort(farmlands, function(a, b)
        return a.id < b.id
    end)
    return farmlands
end

-- The ones the split shares out: no player owner.
function TheContractorFarmerSplit.getEligibleFarmlands()
    local farmlands = {}
    for _, farmland in ipairs(TheContractorFarmerSplit.getFieldFarmlands()) do
        if farmland.ownerFarmId == FarmlandManager.NO_OWNER_FARM_ID then
            table.insert(farmlands, farmland)
        end
    end
    return farmlands
end

-- 108's yards on land no player owns: { farmlandId, x, z, declared (117:
-- the player set it), buildings (in YARD_CATEGORIES), anchors (sheds and
-- farmhouses), sells (any of its buildings is a sell point) }.
function TheContractorFarmerSplit.getFreeYards()
    local yards = {}
    local tc = g_currentMission.TheContractor
    if tc == nil or tc.Yards == nil then
        return yards
    end
    for _, yard in ipairs((tc.Yards:getYards())) do
        if yard.ownerFarmId == FarmlandManager.NO_OWNER_FARM_ID and yard.x ~= nil then
            local group = yard.group
            local sells = false
            for _, building in ipairs(group ~= nil and group.buildings or {}) do
                sells = sells or building.hasSellingStation == true
            end
            table.insert(yards, { farmlandId = yard.farmlandId, x = yard.x, z = yard.z,
                declared = yard.how == "declared", buildings = group ~= nil and group.yardBuildingCount or 0,
                anchors = group ~= nil and group.anchorCount or 0, sells = sells })
        end
    end
    return yards
end

function TheContractorFarmerSplit.splitLiveMap(targetAcres, seed)
    local yards = TheContractorFarmerSplit.getFreeYards()
    local declared = {}
    for _, yard in ipairs(yards) do
        declared[yard.farmlandId] = yard.declared
    end
    local farmlands = {}
    for _, farmland in ipairs(TheContractorFarmerSplit.getEligibleFarmlands()) do
        if not declared[farmland.id] then
            table.insert(farmlands, farmland)
        end
    end
    return TheContractorFarmerSplit.split(farmlands, yards, targetAcres, seed), farmlands, yards
end

-- Map markers --------------------------------------------------------------------------

-- A text label on the map, coloured, added to hotspots.
function TheContractorFarmerSplit.addLabel(hotspots, x, z, text, color)
    local hotspot = FarmlandHotspot.new()
    hotspot:setWorldPosition(x, z)
    hotspot.name = text
    -- Vanilla colours it by owner on its first render; ours is by farmer.
    hotspot.isFirstRendering = false
    if hotspot.icon ~= nil then
        hotspot.icon:setColor(color[1], color[2], color[3], color[4])
    end
    hotspot.color = { color[1], color[2], color[3], color[4] }
    hotspot.textColor = { 0, 0, 0 }
    g_currentMission:addMapHotspot(hotspot)
    table.insert(hotspots, hotspot)
end

local addLabel = TheContractorFarmerSplit.addLabel

-- A label on each farmland's middle with its farmer's number, and "Y" and
-- the number on each farmer's yard, coloured by farmer. Returns how many.
function TheContractorFarmerSplit.showMarkers(result, farmlands, yards)
    local S = TheContractorFarmerSplit
    S.hideMarkers()
    if FarmlandHotspot == nil or g_currentMission.addMapHotspot == nil then
        return 0
    end
    S.hotspots = {}
    local yardsById = {}
    for _, yard in ipairs(yards) do
        yardsById[yard.farmlandId] = yard
    end
    for _, farmland in ipairs(farmlands) do
        local index = result.owners[farmland.id]
        if index ~= nil then
            addLabel(S.hotspots, farmland.x, farmland.z, tostring(index), S.MARKER_COLORS[(index - 1) % #S.MARKER_COLORS + 1])
        end
    end
    for _, farmer in ipairs(result.farmers) do
        local yard = farmer.yardFarmlandId ~= nil and yardsById[farmer.yardFarmlandId] or nil
        if yard ~= nil then
            addLabel(S.hotspots, yard.x, yard.z, "Y" .. farmer.index,
                S.MARKER_COLORS[(farmer.index - 1) % #S.MARKER_COLORS + 1])
        end
    end
    return #S.hotspots
end

function TheContractorFarmerSplit.hideMarkers()
    local S = TheContractorFarmerSplit
    if S.hotspots == nil then
        return
    end
    for _, hotspot in ipairs(S.hotspots) do
        if g_currentMission ~= nil and g_currentMission.removeMapHotspot ~= nil and g_currentMission.hud ~= nil then
            g_currentMission:removeMapHotspot(hotspot)
        end
        hotspot:delete()
    end
    S.hotspots = nil
end

-- Console ----------------------------------------------------------------------------------

function TheContractorFarmerSplit.getPreviewText(result, targetAcres, seed, farmlandCount, yardCount)
    local lines = { string.format("Farmer split: %.0f acres over %d farmland(s), target %s acres, seed %d: %d farmer(s).",
        result.totalAcres, farmlandCount, tostring(targetAcres), seed, #result.farmers) }
    local largest, smallest, yardsUsed = nil, nil, 0
    for _, farmer in ipairs(result.farmers) do
        largest = math.max(largest or farmer.acres, farmer.acres)
        smallest = math.min(smallest or farmer.acres, farmer.acres)
        local yard = "no yard"
        if farmer.yardFarmlandId ~= nil then
            yardsUsed = yardsUsed + 1
            yard = string.format("yard %d%s", farmer.yardFarmlandId, farmer.startedAtYard and " (start)" or "")
        end
        table.insert(lines, string.format("  #%d %.0f acres (target %.0f), %d farmland(s): %s, %s", farmer.index,
            farmer.acres, farmer.target, #farmer.farmlandIds, table.concat(farmer.farmlandIds, ", "), yard))
    end
    if largest ~= nil then
        table.insert(lines, string.format("Largest %.0f acres, smallest %.0f acres (%.1fx). %d of %d yard(s) used, %d balancing move(s).",
            largest, smallest, smallest > 0 and largest / smallest or 0, yardsUsed, yardCount, result.moves))
    end
    return table.concat(lines, "\n")
end

-- tcCompany farmers preview|show|hide (110 registers the command, which
-- also lists and regenerates the real farmers). Returns the text, or false
-- for bad arguments.
function TheContractorFarmerSplit.runPreview(mode, args)
    local S = TheContractorFarmerSplit
    if mode == "hide" then
        S.hideMarkers()
        return "Farmer markers cleared."
    end
    local targetAcres = args[2] ~= nil and tonumber(args[2]) or S.TARGET_ACRES
    local seed = args[3] ~= nil and tonumber(args[3]) or math.random(1, 99999)
    if targetAcres == nil or targetAcres <= 0 or seed == nil then
        return false
    end
    seed = math.floor(seed)

    local result, farmlands, yards = S.splitLiveMap(targetAcres, seed)
    local text = S.getPreviewText(result, targetAcres, seed, #farmlands, #yards)
    if mode == "show" then
        local count = S.showMarkers(result, farmlands, yards)
        text = text .. string.format("\nMarked %d place(s) on the map. tcCompany farmers hide to clear.", count)
    end
    return text
end
