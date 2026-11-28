-- Auction site and lots (135, spike): a machinery auction's field, laid out
-- with rows of used equipment, driven from the console (tcDebug
-- auctionSite) with no auction around it yet (137 owns the auction).
--
--   Picking the field (getCandidates): a field nobody's farm owns (a
--     farmer's, 110) that's grass, bare or harvested (isCropFit, 143), with
--     no live job, ranked by TCAuctionLayout: the ones
--     that can hold the sale first (enough lots fit, gentle enough, a road
--     near), then by area. The entrance is the road point nearest the
--     field's edge (FallenTree's road samples), where buyers drive out and
--     136's gate sign goes.
--   Laying it out: TCAuctionLayout.layOut (pure, tested), from each lot's
--     footprint (its model's size, and its attachment's in front).
--   The lots: roles drawn by LOT_ROLES' weights and count ranges, a model
--     for each from 121's catalog (the fleet's roles, plus the implements
--     135 adds there), the cheaper models likelier (LOT_ROLES' cheapShare). A
--     combine or telehandler comes bare, and headers are lots of their own
--     (the user's call, 2026-11-23). Each gets Used
--     Equipment Yards' MEDIUM condition (CONDITION: hours, damage, wear; the
--     age from the hours), light dirt and a low tank. With ADS, ADS builds
--     its history from those (TCADSUsedLots). Its guide price is vanilla's
--     sell price for that age, hours, damage and wear (Vehicle.
--     calculateSellPrice, as UEY works it out): a vanilla price, never
--     scaled again for EconomyScale. Nothing shows ADS's condition (099).
--   Spawning: on the server, one lot after another (as UEY does), owned by
--     nobody (farm 0), locked for driving and out of the Tab cycle
--     (TCVehicleLock, from the lot ids this sends every machine), and kept
--     out of our lists (farm 0 is nobody's, so the farm lists skip them;
--     isLot for anything that lists every vehicle). The grass is cut short
--     first; a field that isn't grass is put down to short grass, its state
--     kept (groundSnapshot, saved) and put back when the site's cleared
--     (143's prepareGround/restoreGround). The field is protected while the site's up (Jobs:
--     isFieldProtected, so 034's freeze and job generation leave it be).
--   The crowd's walks (137): each row aisle's middle line and width
--     (TCAuctionLayout's walkways), sent to every machine and saved, so the
--     crowd walks the aisles and never through a lot.
--   The scene (140): the layout's frame, entrance space, gate and rows with
--     their lots' numbers and places (TCAuctionLayout.getScene, with a seed
--     rolled here), sent to every machine and saved, for the site's
--     dressing (TCAuctionProps) and the crowd's spots. A site saved before
--     140 has none, so it goes undressed.
--   The lots as everyone sees them (138): each lot's number (in the order
--     they're walked, TCAuctionLayout.getWalkOrder), model, hours, age,
--     guide price and closing time (CLOSE_HOURS, in lot order), with its
--     vehicle ids, sent to every machine for the "View lot" prompt, the
--     card and the menu's catalogue, and (139) whether it's sold (RESULT:
--     never to whom or for what). Only those fields go on the wire
--     (writeLot): the rolls, ADS's result and the hidden local bid's roll
--     (localRoll, 139) stay on the server.
--   Sold (139, AuctionSale): a lot a farm won is the farm's (soldTo), off the
--     lock and never deleted with the site; a local buyer's (soldTo 0) goes
--     at the first midnight (removeUnsold).
--   Saving: vanilla saves the vehicles; we save each lot's uniqueId
--     (TCVehicleIds) with its rolls and guide price. Lots still to spawn
--     when the game saves are dropped. The layout's debug lines are this
--     session's only (not saved).
--
-- Server-wide, not a farm's: nothing to forget when a farm is deleted.

TheContractorAuctionSite = {}
local TheContractorAuctionSite_mt = Class(TheContractorAuctionSite)

-- A sale's size comes from its field: as many lots as fit, up to the
-- preferred number (145's size setting will set it). A field that fits
-- fewer than MIN_LOTS can't hold a sale. MAX_LOTS caps the console's own.
TheContractorAuctionSite.PREFERRED_LOTS = 120
TheContractorAuctionSite.MIN_LOTS = 30
TheContractorAuctionSite.MAX_LOTS = 200
-- Plans tried to size a sale to its field (sizeSale).
TheContractorAuctionSite.SIZING_ATTEMPTS = 3
-- The most lots of one model in a sale.
TheContractorAuctionSite.MAX_DUPLICATES = 3
-- Added to every lot's store size (metres), centred on it: a store's size
-- often leaves out drawbars, hitches and folded parts, and lots strayed
-- into their neighbours' space without it (UEY adds a buffer for the same).
TheContractorAuctionSite.FOOTPRINT_MARGIN = { width = 1, length = 2 }
-- The candidates listed.
TheContractorAuctionSite.TOP_CANDIDATES = 8
-- A field smaller than this isn't laid out at all when ranking.
TheContractorAuctionSite.MIN_AREA_HA = 1
-- Metres between the terrain samples the slope is measured from.
TheContractorAuctionSite.SLOPE_STEP = 8
-- The fixed seed of the typical sale the candidates are measured against,
-- so the list is the same each time it's asked for.
TheContractorAuctionSite.CANDIDATE_SEED = 135

-- Used Equipment Yards' MEDIUM preset, and its hours a year for the age.
TheContractorAuctionSite.CONDITION = {
    hoursMin = 17, hoursMax = 28, damageMin = 0.15, damageMax = 0.45, wearMin = 0.2, wearMax = 0.65,
}
TheContractorAuctionSite.HOURS_PER_YEAR = 800
-- Light dirt, and a low tank: above the 10% Motorized charges a farm to
-- fill on load (UEY's FUEL_MIN).
TheContractorAuctionSite.DIRT = { 0.05, 0.25 }
TheContractorAuctionSite.FUEL = { 0.12, 0.25 }

-- How far a lot may have moved from where it was put and still count as
-- settled (metres).
TheContractorAuctionSite.SETTLE_DISTANCE = 1
-- A lot tilted past this a while after it's out has tipped over: it's put
-- back where it was spawned, upright, once (UPRIGHT_ATTEMPTS), then checked
-- again.
TheContractorAuctionSite.TIP_DEGREES = 25
TheContractorAuctionSite.UPRIGHT_CHECK_MS = 3000
TheContractorAuctionSite.UPRIGHT_ATTEMPTS = 1

-- 138: bidding on the lots closes between these hours on the sale day, one
-- lot after another in lot order: lot 1 at the first, the last at the
-- second (139).
TheContractorAuctionSite.CLOSE_HOURS = { 17, 18 }

-- 163: the kind of day a site's for when none's named (the auction's KIND).
TheContractorAuctionSite.DEFAULT_KIND = "auction"

-- 139: a lot's result as everyone sees it.
TheContractorAuctionSite.RESULT = { OPEN = 0, LOCAL = 1, FARM = 2 }

local ROLE = TheContractorFarmerFleet.ROLE

-- The roles a sale's lots are, in the order they're listed: weight and
-- count range per sale (TCAuctionLayout.pickRoles). Grows over time.
-- Within a role: first, any model priced over medianPriceCap times the
-- role's median store price is left out (no flagships at a farm sale;
-- TCAuctionLayout.getLotModels). Then the cheapest cheapShare of the rest are
-- CHEAP_BOOST times as likely as the rest (cheapBoost overrides it for a
-- role), so a sale has less of the top end (TCAuctionLayout.getModelWeights).
TheContractorAuctionSite.CHEAP_BOOST = 3
TheContractorAuctionSite.LOT_ROLES = {
    { role = ROLE.SMALL_TRACTOR, weight = 8, min = 1, max = 25, cheapShare = 0.8 },
    { role = ROLE.MEDIUM_TRACTOR, weight = 5, min = 1, max = 25, cheapShare = 0.6 },
    { role = ROLE.LARGE_TRACTOR, weight = 2, min = 0, max = 10, cheapShare = 0.4, medianPriceCap = 1.3 },
    { role = ROLE.TELEHANDLER, weight = 2, min = 1, max = 10, cheapShare = 0.6, medianPriceCap = 2 },
    { role = ROLE.COMBINE, weight = 1, min = 1, max = 6, cheapShare = 0.4, medianPriceCap = 1.6 },
    -- Sold on their own, not on a combine (TCAuctionLayout.ATTACHED_ROLES).
    { role = ROLE.HEADER, weight = 1, min = 1, max = 6, cheapShare = 0.5, medianPriceCap = 1.6 },
    { role = ROLE.MOWER, weight = 2, min = 1, max = 10, cheapShare = 0.6 },
    { role = ROLE.TEDDER, weight = 2, min = 1, max = 10, cheapShare = 0.7 },
    { role = ROLE.RAKE, weight = 2, min = 1, max = 10, cheapShare = 0.6 },
    { role = ROLE.BALER, weight = 2, min = 1, max = 10, cheapShare = 0.5, medianPriceCap = 1.5 },
    { role = ROLE.TRAILER, weight = 3, min = 1, max = 15, cheapShare = 0.7, medianPriceCap = 2 },
    { role = ROLE.PLOUGH, weight = 2, min = 1, max = 10, cheapShare = 0.6 },
    { role = ROLE.CULTIVATOR, weight = 2, min = 1, max = 10, cheapShare = 0.5 },
    { role = ROLE.SEED_DRILL, weight = 2, min = 1, max = 10, cheapShare = 0.5, medianPriceCap = 1.5 },
}

function TheContractorAuctionSite.new()
    local self = setmetatable({}, TheContractorAuctionSite_mt)
    -- Server: the site, or nil. { fieldId, entrance = { x, z, distance },
    -- lots, planned, unplaced, layout (this session's, for the debug
    -- lines), isSpawning, timings }.
    self.site = nil
    -- Server: lots still to spawn, and the one loading.
    self.queue = {}
    self.loading = nil
    -- Every machine: the site's field (0: none), its lots as everyone sees
    -- them (138, getPublicLot's, by number), their vehicle ids (lots and
    -- attachments), its walkways (137) and its scene (140, or nil), as the
    -- server sent them.
    self.fieldId = 0
    self.lots = {}
    self.vehicleIdSet = {}
    self.walkways = {}
    self.scene = nil
    -- Server: the frame time, smoothed (ms).
    self.frameMs = nil
    -- Server: lots to check for tipping over, { lot, dueMs }, and the clock
    -- they're due by (ms since load).
    self.uprightChecks = {}
    self.clockMs = 0
    return self
end

-- A live vehicle by its object id, or nil.
local function getVehicle(vehicleId)
    local vehicle = vehicleId ~= nil and NetworkUtil.getObject(vehicleId) or nil
    if vehicle == nil or vehicle.isDeleted then
        return nil
    end
    return vehicle
end

-- Every machine ------------------------------------------------------------------------

function TheContractorAuctionSite:isFieldInUse(fieldId)
    return fieldId ~= nil and self.fieldId ~= 0 and self.fieldId == fieldId
end

-- vehicleId -> true for every lot and attachment (TCVehicleLock).
function TheContractorAuctionSite:getLotVehicleIds()
    return self.vehicleIdSet
end

function TheContractorAuctionSite:isLot(vehicle)
    local vehicleId = vehicle ~= nil and NetworkUtil.getObjectId(vehicle) or nil
    return vehicleId ~= nil and self.vehicleIdSet[vehicleId] == true
end

-- 137: the crowd's walks, { { x1, z1, x2, z2, halfWidth } }.
function TheContractorAuctionSite:getWalkways()
    return self.walkways
end

-- 140: the site's scene (TCAuctionLayout.getScene's), or nil.
function TheContractorAuctionSite:getScene()
    return self.scene
end

-- 138: the lots as everyone sees them, by number.
function TheContractorAuctionSite:getLots()
    return self.lots
end

function TheContractorAuctionSite:getLot(number)
    for _, lot in ipairs(self.lots) do
        if lot.number == number then
            return lot
        end
    end
    return nil
end

local function sortByNumber(lots)
    table.sort(lots, function(a, b)
        return a.number < b.number
    end)
end

-- Every machine: the site as the server sent it (TCAuctionSiteEvent).
-- lots: getPublicLot's. scene: 140's, or nil.
function TheContractorAuctionSite:applySync(fieldId, lots, walkways, scene)
    self.fieldId = fieldId or 0
    self.walkways = walkways or {}
    self.scene = self.fieldId ~= 0 and scene or nil
    self.lots = {}
    for _, lot in ipairs(lots or {}) do
        table.insert(self.lots, lot)
    end
    self:onLotsChanged()
end

-- Every machine: one lot more (the server's lots come out one at a time),
-- or one that's changed (139: sold).
function TheContractorAuctionSite:appendLot(lot)
    for i, other in ipairs(self.lots) do
        if other.number == lot.number then
            table.remove(self.lots, i)
            break
        end
    end
    table.insert(self.lots, lot)
    self:onLotsChanged()
end

-- The lots by number, and the locked vehicles: every lot's still standing
-- that no farm has won (139: a won lot's the farm's).
function TheContractorAuctionSite:onLotsChanged()
    sortByNumber(self.lots)
    self.vehicleIdSet = {}
    for _, lot in ipairs(self.lots) do
        if (lot.result or 0) ~= TheContractorAuctionSite.RESULT.FARM then
            for _, vehicleId in ipairs({ lot.vehicleId or false, lot.attachmentId or false }) do
                if vehicleId then
                    self.vehicleIdSet[vehicleId] = true
                end
            end
        end
    end
end

-- Server: a lot's RESULT (139).
function TheContractorAuctionSite.getResult(lot)
    local R = TheContractorAuctionSite.RESULT
    if lot.soldTo == nil then
        return R.OPEN
    end
    return lot.soldTo > 0 and R.FARM or R.LOCAL
end

-- Server: what everyone may know of a lot (138), or nil while an unsold
-- lot's vehicle isn't out (a sold one stays listed after it's gone). Only
-- these fields are ever sent (TCAuctionSiteEvent.writeLot).
function TheContractorAuctionSite.getPublicLot(lot)
    if lot.failed ~= nil or (lot.soldTo == nil and getVehicle(lot.vehicleId) == nil) then
        return nil
    end
    local vehicleId = getVehicle(lot.vehicleId) ~= nil and lot.vehicleId or nil
    local attachmentId = getVehicle(lot.attachmentId) ~= nil and lot.attachmentId or nil
    return {
        number = lot.number,
        xmlFilename = lot.xmlFilename,
        attachmentXml = attachmentId ~= nil and lot.attachmentXml or nil,
        hours = lot.hours or 0,
        ageMonths = lot.ageMonths or 0,
        guidePrice = lot.guidePrice or 0,
        closeMinute = lot.closeMinute or 0,
        result = TheContractorAuctionSite.getResult(lot),
        vehicleId = vehicleId,
        attachmentId = attachmentId,
    }
end

-- Server: the site's field and the lots that are out, to this machine and
-- every client.
function TheContractorAuctionSite:sync()
    local site = self.site
    local lots = {}
    if site ~= nil then
        for _, lot in ipairs(site.lots) do
            local public = TheContractorAuctionSite.getPublicLot(lot)
            if public ~= nil then
                table.insert(lots, public)
            end
        end
    end
    local walkways = site ~= nil and site.walkways or {}
    local scene = site ~= nil and site.scene or nil
    self:applySync(site ~= nil and site.fieldId or 0, lots, walkways, scene)
    if g_server ~= nil then
        g_server:broadcastEvent(TCAuctionSiteEvent.new(self.fieldId, self.lots, walkways, scene))
    end
end

-- Server: a lot that's just come out, to this machine and every client,
-- without sending the whole site again.
function TheContractorAuctionSite:syncLot(lot)
    local public = TheContractorAuctionSite.getPublicLot(lot)
    if public == nil then
        return
    end
    self:appendLot(public)
    if g_server ~= nil then
        g_server:broadcastEvent(TCAuctionSiteEvent.newLot(public))
    end
end

-- A lot's closing time (138), in minutes after midnight on the sale day:
-- lot 1 at the first of CLOSE_HOURS, the last at the second, the rest
-- spread evenly between in lot order (whole minutes).
function TheContractorAuctionSite.getCloseMinute(number, lotCount)
    local hours = TheContractorAuctionSite.CLOSE_HOURS
    local span = (hours[2] - hours[1]) * 60
    if lotCount <= 1 then
        return hours[1] * 60
    end
    return hours[1] * 60 + math.floor((number - 1) * span / (lotCount - 1) + 0.5)
end

-- "17:24".
function TheContractorAuctionSite.formatCloseTime(minute)
    return string.format("%02d:%02d", math.floor(minute / 60), minute % 60)
end

-- Whether bidding on a lot is open or closed (138; 139 adds the farm's bid
-- and the result). saleDay: the auction's (nil for the console's site,
-- which has no sale: always open); today a monotonic day, minute the
-- minutes after midnight.
TheContractorAuctionSite.LOT_STATE = { OPEN = "open", CLOSED = "closed" }
function TheContractorAuctionSite.getLotState(lot, saleDay, today, minute)
    local S = TheContractorAuctionSite.LOT_STATE
    if saleDay == nil or today < saleDay then
        return S.OPEN
    end
    if today > saleDay or minute >= lot.closeMinute then
        return S.CLOSED
    end
    return S.OPEN
end

-- The sale day of the auction (137) these lots are for, or nil for the
-- console's site.
function TheContractorAuctionSite:getSaleDay()
    local auctions = g_currentMission.TheContractor.Auctions
    local auction = auctions ~= nil and auctions:getAuction() or nil
    if auction ~= nil and self.fieldId ~= 0 and auction.fieldId == self.fieldId then
        return auction.day
    end
    return nil
end

-- getLotState now.
function TheContractorAuctionSite:getLotStateNow(lot)
    local environment = g_currentMission.environment
    return TheContractorAuctionSite.getLotState(lot, self:getSaleDay(), environment.currentMonotonicDay,
        (environment.currentHour or 0) * 60 + (environment.currentMinute or 0))
end

-- A lot's name: its model, and the header that goes with it.
function TheContractorAuctionSite.getLotName(lot)
    local name = TheContractorFarmerFleet.getModelName(lot.xmlFilename)
    if lot.attachmentXml ~= nil then
        return string.format(g_i18n:getText("tc_auctionLot_withAttachment"), name,
            TheContractorFarmerFleet.getModelName(lot.attachmentXml))
    end
    return name
end

-- Lots ---------------------------------------------------------------------------------

-- A lot's footprint, its attachment in front (FarmerFleet.getFootprint)
-- with the gap it's loaded at, and FOOTPRINT_MARGIN round it: width,
-- length, widthOffset, lengthOffset, height, and the models. false when the
-- store hasn't got it.
function TheContractorAuctionSite.setFootprint(lot)
    local F = TheContractorFarmerFleet
    local model = F.getSizeModel(lot.xmlFilename)
    if model == nil then
        return false
    end
    local attachment = lot.attachmentXml ~= nil and F.getSizeModel(lot.attachmentXml) or nil
    local footprint = F.getFootprint(model, attachment)
    lot.model, lot.attachmentModel = model, attachment
    lot.width = footprint.width
    lot.length = footprint.length
    lot.widthOffset = footprint.widthOffset or 0
    lot.lengthOffset = footprint.lengthOffset or 0
    lot.height = footprint.height
    if attachment ~= nil then
        local gap = TheContractorRepairContracts.CLEARANCE
        lot.length = lot.length + gap
        lot.lengthOffset = lot.lengthOffset + gap * 0.5
    end
    local margin = TheContractorAuctionSite.FOOTPRINT_MARGIN
    lot.width = lot.width + margin.width
    lot.length = lot.length + margin.length
    return true
end

-- A sale's lots with their footprints: roles, models and attachments from
-- the catalog. Lots the store can't size are left out.
function TheContractorAuctionSite.planLots(lotCount, random)
    local catalog = TheContractorFarmerFleet.buildCatalog()
    local roleDefs = TheContractorAuctionSite.LOT_ROLES
    local roles = TCAuctionLayout.pickRoles(roleDefs, lotCount, random,
        TCAuctionLayout.getAvailableRoles(catalog, roleDefs, TheContractorAuctionSite.MAX_DUPLICATES))
    local lots = {}
    for _, lot in ipairs(TCAuctionLayout.pickLots(catalog, roles, random,
            TheContractorAuctionSite.MAX_DUPLICATES, roleDefs, TheContractorAuctionSite.CHEAP_BOOST)) do
        if TheContractorAuctionSite.setFootprint(lot) then
            table.insert(lots, lot)
        end
    end
    return lots
end

local function seededRandom(seed)
    local state = seed
    return function()
        state = state * 16807 % 2147483647
        return (state - 1) / 2147483646
    end
end

-- Picking the field (server) -------------------------------------------------------------

local function getHolderName(field)
    local farmers = g_currentMission.TheContractor.Farmers
    local farmland = field.getFarmland ~= nil and field:getFarmland() or nil
    local holder = farmers ~= nil and farmland ~= nil and farmers:getHolder(farmland:getId()) or nil
    return holder ~= nil and holder.name or nil
end

-- The field's slope over the layout's rectangle: steepest, average (%), rise (m).
local function measureSlope(rect)
    local step = TheContractorAuctionSite.SLOPE_STEP
    local heights = {}
    for _, point in ipairs(TCAuctionLayout.getSamplePoints(rect, step)) do
        heights[point.row] = heights[point.row] or {}
        heights[point.row][point.col] = getTerrainHeightAtWorldPos(g_terrainNode, point.x, 0, point.z)
    end
    return TCAuctionLayout.measureSlope(heights, step)
end

-- Why a field can't be a site at all (nil if it can): the console's words.
-- A field with any live job is refused, whatever its dates (137: an
-- auction's field must be free of work from its announcement, so no job
-- can run into its sale day). forEventId: the event day (137's auction, or
-- 163's other kinds: forKind, the auction if nil) the site's for, whose own
-- field it may be; any other event's field is refused.
function TheContractorAuctionSite.getFieldRefusal(field, forEventId, forKind)
    if field:getOwner() ~= FarmlandManager.NO_OWNER_FARM_ID then
        return "a farm owns it"
    end
    local tc = g_currentMission.TheContractor
    if tc.Jobs:hasLiveJob(field:getId()) then
        return "it has a live job"
    end
    local publicEvents = tc.PublicEvents
    local kind, event = nil, nil
    if publicEvents ~= nil then
        kind, event = publicEvents:getEventOnField(field:getId())
    end
    if event ~= nil and not (kind.KIND == (forKind or TheContractorAuctionSite.DEFAULT_KIND) and event.id == forEventId) then
        return string.format("%s's announced on it", kind:getArticleName())
    end
    return nil
end

-- One field measured for a sale of these lots: { fieldId, areaHa, fitted,
-- of, slopePercent, averageSlope, rise, entranceDistance, holder, entrance,
-- layout }.
function TheContractorAuctionSite.measureField(field, lots, roads)
    local polygon = TCAuctionCrowd.getFieldPolygon(field)
    local entrance = TCAuctionLayout.findEntrance(polygon, roads, TCAuctionLayout.RULES.entranceReach)
    local layout = TCAuctionLayout.layOut(polygon, entrance, lots)
    local candidate = {
        fieldId = field:getId(),
        areaHa = field:getAreaHa() or 0,
        fitted = layout ~= nil and layout.placedCount or 0,
        of = #lots,
        entranceDistance = entrance ~= nil and entrance.distance or nil,
        holder = getHolderName(field),
        entrance = entrance,
        layout = layout,
    }
    if layout ~= nil then
        candidate.slopePercent, candidate.averageSlope, candidate.rise = measureSlope(layout.rect)
    end
    return candidate
end

-- 143: whether a field's crop lets it be picked as a site: grass, no crop,
-- or a crop at a cut (harvested) state. A sown, growing or withered crop
-- doesn't. Only the pick asks: the consoles' sites can be any field, and on
-- the sale day whatever's there is put down to grass and put back after.
function TheContractorAuctionSite.isCropFit(field)
    local fieldState = field:getFieldState()
    if fieldState == nil or not fieldState.isValid then
        return false
    end
    local fruitTypeIndex = fieldState.fruitTypeIndex
    if fruitTypeIndex == nil or fruitTypeIndex == FruitType.UNKNOWN then
        return true
    end
    if TheContractorJobGeneration.isGrass(fruitTypeIndex) then
        return true
    end
    local fruitType = g_fruitTypeManager:getFruitTypeByIndex(fruitTypeIndex)
    return fruitType ~= nil and fruitType.cutStates ~= nil and fruitType.cutStates[fieldState.growthState] == true
end

-- Every field that could be a site (grass, bare or harvested, nobody's
-- farm, no live job, big enough to try), measured against a typical sale of
-- the preferred size and ranked: those that fit MIN_LOTS first, the most
-- lots first. Returns the ranked list and how many fields there are in all.
function TheContractorAuctionSite:getCandidates(preferredLots)
    local lots = TheContractorAuctionSite.planLots(preferredLots,
        seededRandom(TheContractorAuctionSite.CANDIDATE_SEED))
    local roads = TheContractorFallenTree.sampleRoads()
    local candidates = {}
    local fields = g_fieldManager:getFields()
    for _, field in ipairs(fields) do
        if TheContractorAuctionSite.isCropFit(field) and TheContractorAuctionSite.getFieldRefusal(field) == nil and
                (field:getAreaHa() or 0) >= TheContractorAuctionSite.MIN_AREA_HA then
            table.insert(candidates, TheContractorAuctionSite.measureField(field, lots, roads))
        end
    end
    return TCAuctionLayout.rankCandidates(candidates, TheContractorAuctionSite.MIN_LOTS), #fields
end

-- Spawning (server) ----------------------------------------------------------------------

local function range(values, random)
    return values[1] + random() * (values[2] - values[1])
end

-- A sale sized to its field: a plan of the wanted lots, laid out; if fewer
-- fit, a new plan of as many as did (so the mix of roles is drawn for that
-- size, rather than the last ones in being left out), up to
-- SIZING_ATTEMPTS. Returns the lots and the field's measure (with their
-- layout) of the plan that placed the most.
function TheContractorAuctionSite.sizeSale(field, wantedLots, roads, random)
    local bestLots, best = nil, nil
    local count = wantedLots
    for _ = 1, TheContractorAuctionSite.SIZING_ATTEMPTS do
        local lots = TheContractorAuctionSite.planLots(count, random)
        if #lots == 0 then
            break
        end
        local candidate = TheContractorAuctionSite.measureField(field, lots, roads)
        -- A tie goes to the later plan: its roles were drawn for that size.
        if best == nil or candidate.fitted >= best.fitted then
            bestLots, best = lots, candidate
        end
        if candidate.fitted >= #lots or candidate.fitted == 0 then
            break
        end
        count = candidate.fitted
    end
    return bestLots or {}, best
end

-- 143: the site's field made ready for the lots. A grass field is cut short
-- (nothing kept: it grows back); any other has its state kept on the site
-- (groundSnapshot, saved with it) and is put down to short grass. Returns
-- "cut", "grassed" or "left" (neither could be done).
function TheContractorAuctionSite.prepareGround(site, field)
    if TheContractorJoyriders.isGrassField(field) then
        return TCFieldPreparation.cutGrass(field) and "cut" or "left"
    end
    local snapshot = TCFieldPreparation.snapshotField(field)
    if snapshot == nil or not TCFieldPreparation.putDownGrass(field) then
        return "left"
    end
    site.groundSnapshot = snapshot
    return "grassed"
end

-- 143: the field as it was before the sale, if it was put down to grass.
-- Done as the site's cleared, which is the auction's end at the collection
-- day's midnight. That's before the month's growth on the same midnight:
-- vanilla publishes HOUR_CHANGED and DAY_CHANGED (which end the auction)
-- before PERIOD_CHANGED (GrowthSystem:onPeriodChanged), so the growth
-- applies to the crop put back. Don't move the end to beat it.
function TheContractorAuctionSite.restoreGround(site)
    local snapshot = site.groundSnapshot
    if snapshot == nil then
        return false
    end
    site.groundSnapshot = nil
    local field = g_fieldManager:getFieldById(site.fieldId)
    if field == nil then
        return false
    end
    TCLog.info("TheContractor: auction field %d put back to %s", site.fieldId, snapshot.fruitType)
    return TCFieldPreparation.restoreField(field, snapshot)
end

-- Puts a site on a field: lays it out, cuts the grass and starts spawning
-- its lots one after another. lotCount: nil for as many as fit, up to the
-- preferred number. auctionId: the auction (137) it's for, whose protected
-- field it is; without one (the console's spike), the layout's debug lines
-- are drawn. Returns the text to print; self.site is set if it went up.
function TheContractorAuctionSite:start(fieldId, lotCount, auctionId)
    if self.site ~= nil then
        return string.format("There's a site on field %d already: 'tcDebug auctionSite clear' first.",
            self.site.fieldId)
    end
    local field = g_fieldManager:getFieldById(fieldId)
    if field == nil then
        return string.format("No field %d.", fieldId)
    end
    local refusal = TheContractorAuctionSite.getFieldRefusal(field, auctionId)
    if refusal ~= nil then
        return string.format("Field %d can't be a site: %s.", fieldId, refusal)
    end

    local lots, candidate = TheContractorAuctionSite.sizeSale(field,
        lotCount or TheContractorAuctionSite.PREFERRED_LOTS, TheContractorFallenTree.sampleRoads(), math.random)
    if candidate == nil then
        return "The store has nothing for any of the lots' roles."
    end
    local layout = candidate.layout
    if layout == nil or layout.placedCount == 0 then
        return string.format("Field %d has no room for a lot.", fieldId)
    end

    local site = {
        fieldId = fieldId,
        entrance = candidate.entrance,
        lots = {},
        planned = #lots,
        unplaced = #layout.unplaced,
        layout = layout,
        walkways = layout.walkways or {},
        -- 140: the dressing's, with its own seed for the props' picks.
        scene = TCAuctionLayout.getScene(layout, candidate.entrance, math.random(1, 1000000000)),
        isSpawning = true,
        startedAt = getTimeSec(),
        frames = 0,
        frameMsTotal = 0,
        worstFrameMs = 0,
    }
    -- 138: numbered in the order they're walked, and spawned in that order.
    local order = TCAuctionLayout.getWalkOrder(layout.placed)
    for _, index in ipairs(order) do
        local lot, spot = lots[index], layout.placed[index]
        local condition = TCAuctionLayout.rollCondition(TheContractorAuctionSite.CONDITION,
            TheContractorAuctionSite.HOURS_PER_YEAR, math.random)
        lot.hours, lot.damage, lot.wear, lot.ageMonths = condition.hours, condition.damage, condition.wear,
            condition.ageMonths
        lot.dirt = range(TheContractorAuctionSite.DIRT, math.random)
        lot.fuel = range(TheContractorAuctionSite.FUEL, math.random)
        lot.x, lot.z, lot.yaw = spot.x, spot.z, spot.yaw
        lot.rootX, lot.rootZ = spot.rootX, spot.rootZ
        lot.number = #site.lots + 1
        lot.closeMinute = TheContractorAuctionSite.getCloseMinute(lot.number, #order)
        -- 139: the room's hidden bid for it, rolled now (AuctionSale).
        lot.localRoll = math.random()
        table.insert(site.lots, lot)
    end
    self.site = site
    self.queue = TheContractorFarmerFleet.copy(site.lots)
    self.debugVisible = auctionId == nil

    -- The lots aren't to stand in long grass, or in a crop or bare earth
    -- (143): a grass field is cut short and grows back; any other is put
    -- down to short grass for the sale, its state kept to put back (clear).
    local ground = TheContractorAuctionSite.prepareGround(site, field)
    TCLog.info("TheContractor: auction site on field %d, %d of %d lots laid out, ground %s", fieldId,
        #site.lots, #lots, ground)
    self:sync()
    self:spawnNext()

    local lines = { string.format("Auction site on field %d: %d of %d lots laid out (%d didn't fit), spawning one at a time.",
        fieldId, #site.lots, #lots, site.unplaced) }
    table.insert(lines, TheContractorAuctionSite.describeCandidate(
        TCAuctionLayout.rankCandidates({ candidate }, TheContractorAuctionSite.MIN_LOTS)[1]))
    if ground == "grassed" then
        table.insert(lines, "  Not a grass field: put down to grass for the sale, put back when it's cleared.")
    elseif ground == "left" then
        table.insert(lines, "  The ground was left as it is.")
    end
    table.insert(lines, "Rows red, aisles green, the entrance's space blue, the entrance yellow (this machine). 'tcDebug auctionSite' for progress.")
    return table.concat(lines, "\n")
end

-- 163: puts bare ground on a field for a day out with no lots (another
-- kind of event day than the auction): the field's rectangle laid out
-- open (TCAuctionLayout.layOutOpen: the entrance space, walking lanes over
-- the rest), its scene dressed as that kind is (dressing: its KIND), and
-- the ground made ready as for a sale (143). eventId: the event it's for,
-- whose protected field it is. options (165), any of: rect (lay out in
-- this rectangle, not the field's largest: the show's showground),
-- entrance (the road point to use), keepGround (leave the ground alone:
-- the show dresses its own, 164), getWalkways(scene) (the crowd's walks
-- from the scene, in place of the open lanes), plots (169: the ploughing
-- plots, 164's, kept on the scene for every machine to mark out), pens
-- (182: the small pens, 0 for none), breeders (188: the breeders' pens,
-- TCShowScene's scene.breeders). Returns the text to print; self.site is
-- set if it went up.
function TheContractorAuctionSite:startOpen(fieldId, dressing, eventId, options)
    options = options or {}
    if self.site ~= nil then
        return string.format("There's a site on field %d already.", self.site.fieldId)
    end
    local field = g_fieldManager:getFieldById(fieldId)
    if field == nil then
        return string.format("No field %d.", fieldId)
    end
    local refusal = TheContractorAuctionSite.getFieldRefusal(field, eventId, dressing)
    if refusal ~= nil then
        return string.format("Field %d can't be a site: %s.", fieldId, refusal)
    end
    local polygon = TCAuctionCrowd.getFieldPolygon(field)
    local entrance = options.entrance or TCAuctionLayout.findEntrance(polygon, TheContractorFallenTree.sampleRoads(),
        TCAuctionLayout.RULES.entranceReach)
    local layout
    if options.rect ~= nil then
        layout = TCAuctionLayout.layOutOpenRect(options.rect, entrance)
    else
        layout = TCAuctionLayout.layOutOpen(polygon, entrance)
    end
    if layout == nil then
        return string.format("Field %d has no room.", fieldId)
    end
    local scene = TCAuctionLayout.getScene(layout, entrance, math.random(1, 1000000000))
    scene.dressing = dressing
    -- 169: the show's ploughing plots, so every machine marks them out.
    scene.plots = {}
    for _, plot in ipairs(options.plots or {}) do
        table.insert(scene.plots, { cx = plot.cx, cz = plot.cz, angle = plot.angle, half = plot.half })
    end
    -- 182: the show's pens, one an animal (nil: TCShowScene's default).
    scene.pens = options.pens
    -- 188: the show's breeders' pens ({ length, depth, trailer, typeName }).
    if options.breeders ~= nil then
        scene.breeders = {}
        for _, breeder in ipairs(options.breeders) do
            table.insert(scene.breeders, { length = breeder.length, depth = breeder.depth,
                trailer = breeder.trailer == true, typeName = breeder.typeName })
        end
    end
    if options.getWalkways ~= nil then
        layout.walkways = options.getWalkways(scene)
    end
    local site = {
        fieldId = fieldId,
        entrance = entrance,
        lots = {},
        planned = 0,
        unplaced = 0,
        layout = layout,
        walkways = layout.walkways,
        scene = scene,
        isSpawning = false,
    }
    self.site = site
    self.queue = {}
    local ground = "kept"
    if not options.keepGround then
        ground = TheContractorAuctionSite.prepareGround(site, field)
    end
    TCLog.info("TheContractor: open site (%s) on field %d, %d walkway(s), ground %s", tostring(dressing), fieldId,
        #site.walkways, ground)
    self:sync()
    return string.format("Open site on field %d: %d walkway(s), ground %s.", fieldId, #site.walkways, ground)
end

function TheContractorAuctionSite:spawnNext()
    local site = self.site
    if self.loading ~= nil or site == nil then
        return
    end
    local lot = table.remove(self.queue, 1)
    if lot == nil then
        if site.isSpawning then
            site.isSpawning = false
            site.spawnedAt = getTimeSec()
            TCLog.info("TheContractor: auction site on field %d spawned in %.1f s", site.fieldId,
                site.spawnedAt - site.startedAt)
            -- 152: the farmers needn't wait for the next hour to ask.
            TCLotInspections.onLotsOut()
        end
        return
    end
    local storeItem = g_storeManager:getItemByXMLFilename(lot.xmlFilename)
    if storeItem == nil then
        lot.failed = "not in the store"
        self:spawnNext()
        return
    end
    if not TCParking.isAreaClear(lot.x, lot.z, lot.yaw, lot.width, lot.length, lot.height) then
        lot.failed = "something in the way"
        self:spawnNext()
        return
    end

    local loadingData = VehicleLoadingData.new()
    loadingData:setStoreItem(storeItem)
    TCStoreConfigurations.apply(loadingData, storeItem)
    -- The store's own offset puts an implement down on its stands, as the
    -- shop sets it down (a mower on a small stand tipped over without it).
    loadingData:setIgnoreShopOffset(false)
    loadingData:setPosition(lot.rootX, nil, lot.rootZ, TCParking.PLACE_HEIGHT_OFFSET)
    loadingData:setRotation(0, lot.yaw, 0)
    loadingData:setPropertyState(VehiclePropertyState.OWNED)
    loadingData:setOwnerFarmId(0)
    lot.loadStarted = getTimeSec()
    self.loading = lot
    loadingData:load(self.onLotLoaded, self, { lot = lot, site = site })
end

local function deleteAll(vehicles)
    for _, vehicle in ipairs(vehicles or {}) do
        if vehicle ~= nil and not vehicle.isDeleted then
            vehicle:delete()
        end
    end
end

-- VehicleLoadingData's callback.
function TheContractorAuctionSite:onLotLoaded(vehicles, loadingState, args)
    local lot = args.lot
    if args.site ~= self.site then
        -- Cleared while it loaded.
        deleteAll(vehicles)
        return
    end
    local vehicle = vehicles ~= nil and vehicles[1] or nil
    if vehicle == nil or loadingState ~= VehicleLoadingState.OK then
        deleteAll(vehicles)
        lot.failed = "didn't load"
        self.loading = nil
        self:spawnNext()
        return
    end
    lot.vehicleId = NetworkUtil.getObjectId(vehicle)
    -- Where it was set down, to stand it back there if it tips over.
    if vehicle.rootNode ~= nil then
        local x, y, z = getWorldTranslation(vehicle.rootNode)
        local rx, ry, rz = getWorldRotation(vehicle.rootNode)
        lot.pose = { x, y, z, rx, ry, rz }
        table.insert(self.uprightChecks, { lot = lot, dueMs = self.clockMs + TheContractorAuctionSite.UPRIGHT_CHECK_MS })
    end
    TheContractorAuctionSite.applyCondition(vehicle, lot)
    if lot.attachmentModel ~= nil then
        self:loadAttachment(lot, vehicle)
        return
    end
    self:finishLot(lot, vehicle, nil)
end

-- A combine's header, loaded in front of it and hitched on
-- (RepairContracts:loadAttachment's way).
function TheContractorAuctionSite:loadAttachment(lot, vehicle)
    local storeItem = g_storeManager:getItemByXMLFilename(lot.attachmentXml)
    if storeItem == nil or vehicle.rootNode == nil then
        self:finishLot(lot, vehicle, nil)
        return
    end
    local model, attachment = lot.model, lot.attachmentModel
    local x, _, z = getWorldTranslation(vehicle.rootNode)
    local dirX, _, dirZ = localDirectionToWorld(vehicle.rootNode, 0, 0, 1)
    local ahead = (model.lengthOffset or 0) + model.length * 0.5 + attachment.length * 0.5 +
        TheContractorRepairContracts.CLEARANCE
    local loadingData = VehicleLoadingData.new()
    loadingData:setStoreItem(storeItem)
    TCStoreConfigurations.apply(loadingData, storeItem)
    loadingData:setIgnoreShopOffset(true)
    loadingData:setPosition(x + dirX * ahead, nil, z + dirZ * ahead, TCParking.PLACE_HEIGHT_OFFSET)
    loadingData:setRotation(0, MathUtil.getYRotationFromDirection(dirX, dirZ), 0)
    loadingData:setPropertyState(VehiclePropertyState.OWNED)
    loadingData:setOwnerFarmId(0)
    loadingData:load(self.onAttachmentLoaded, self, { lot = lot, site = self.site, vehicle = vehicle })
end

function TheContractorAuctionSite:onAttachmentLoaded(vehicles, loadingState, args)
    local lot, vehicle = args.lot, args.vehicle
    if args.site ~= self.site then
        deleteAll(vehicles)
        deleteAll({ vehicle })
        return
    end
    local attachment = vehicles ~= nil and vehicles[1] or nil
    if attachment ~= nil and (loadingState ~= VehicleLoadingState.OK or vehicle.isDeleted or
            not TCJobSiteSetup.hitchImplement(vehicle, attachment, 0)) then
        TCLog.info("TheContractor: auction lot %d: %s couldn't be hitched to %s, left out", lot.number,
            attachment:getFullName(), vehicle:getFullName())
        lot.attachmentFailed = true
        deleteAll(vehicles)
        attachment = nil
    end
    if attachment ~= nil then
        TheContractorAuctionSite.applyCondition(attachment, lot)
    end
    self:finishLot(lot, vehicle, attachment)
end

-- The lot's rolled condition on a vehicle, as UEY applies its own: wear,
-- damage (with the wear's dirty flag cleared, so no delta goes to clients
-- before they've its nodes), hours (written as loading, which ADS lets
-- through: TCADSUsedLots), age, dirt and a low tank.
function TheContractorAuctionSite.applyCondition(vehicle, lot)
    if vehicle.addWearAmount ~= nil then
        vehicle:addWearAmount(lot.wear)
    end
    if vehicle.setDamageAmount ~= nil then
        vehicle:setDamageAmount(lot.damage)
    end
    if vehicle.spec_wearable ~= nil and vehicle.clearDirtyFlags ~= nil then
        vehicle:clearDirtyFlags(vehicle.spec_wearable.dirtyFlag)
    end
    if vehicle.setOperatingTime ~= nil then
        vehicle:setOperatingTime(lot.hours * 3600000, true)
    end
    vehicle.age = lot.ageMonths
    if vehicle.setDirtAmount ~= nil then
        vehicle:setDirtAmount(lot.dirt)
    end
    if vehicle.getConsumerFillUnitIndex ~= nil then
        -- TCJobSupplies' diesels: a farm machine runs on FS25_RedDiesel's red.
        local fuels = TCJobSupplies.getDieselFillTypes()
        table.insert(fuels, FillType.ELECTRICCHARGE)
        table.insert(fuels, FillType.METHANE)
        for _, fillType in ipairs(fuels) do
            local fillUnitIndex = fillType ~= nil and vehicle:getConsumerFillUnitIndex(fillType) or nil
            if fillUnitIndex ~= nil then
                local capacity = vehicle:getFillUnitCapacity(fillUnitIndex)
                if capacity > 0 then
                    local delta = capacity * lot.fuel - vehicle:getFillUnitFillLevel(fillUnitIndex)
                    vehicle:addFillUnitFillLevel(vehicle:getOwnerFarmId(), fillUnitIndex, delta, fillType,
                        ToolType.UNDEFINED, nil)
                end
            end
        end
    end
end

-- Vanilla's sell price for a vehicle with the lot's age, hours, damage and
-- wear (UEY's way). A vanilla price: never scaled again.
function TheContractorAuctionSite.getGuidePrice(vehicle, lot)
    local storeItem = g_storeManager:getItemByXMLFilename(vehicle.configFileName)
    if storeItem == nil then
        return 0
    end
    local price = vehicle.getPrice ~= nil and vehicle:getPrice() or storeItem.price or 0
    local repairPrice = Wearable.calculateRepairPrice(price, lot.damage)
    local repaintPrice = Wearable.calculateRepaintPrice(price, lot.wear)
    return Vehicle.calculateSellPrice(storeItem, lot.ageMonths, lot.hours * 3600000, price, repairPrice, repaintPrice)
end

function TheContractorAuctionSite:finishLot(lot, vehicle, attachment)
    lot.loadMs = (getTimeSec() - lot.loadStarted) * 1000
    lot.attachmentId = attachment ~= nil and NetworkUtil.getObjectId(attachment) or nil
    local ok, reason = TCADSUsedLots.initialiseLot(vehicle)
    lot.adsResult = ok and "ok" or reason
    if attachment ~= nil then
        TCADSUsedLots.initialiseLot(attachment)
    end
    lot.guidePrice = TheContractorAuctionSite.getGuidePrice(vehicle, lot) +
        (attachment ~= nil and TheContractorAuctionSite.getGuidePrice(attachment, lot) or 0)
    TCLog.info("TheContractor: auction lot %d (%s) %s out in %.0f ms, %.1f h, %d months, ADS %s", lot.number,
        lot.role, vehicle:getFullName(), lot.loadMs, lot.hours, lot.ageMonths, lot.adsResult)
    self.loading = nil
    self:syncLot(lot)
    self:spawnNext()
end

-- Takes every lot away. Returns the text to print.
function TheContractorAuctionSite:clear()
    local site = self.site
    if site == nil then
        return "There's no auction site."
    end
    local count = 0
    for _, lot in ipairs(site.lots) do
        -- 139: a lot a farm won is the farm's.
        if lot.soldTo == nil or lot.soldTo <= 0 then
            for _, vehicle in ipairs({ getVehicle(lot.attachmentId) or false, getVehicle(lot.vehicleId) or false }) do
                if vehicle then
                    vehicle:delete()
                    count = count + 1
                end
            end
        end
    end
    local restored = TheContractorAuctionSite.restoreGround(site)
    -- A lot still loading is deleted when it arrives (its site has gone).
    self.site = nil
    self.queue = {}
    self.loading = nil
    self.uprightChecks = {}
    self.debugVisible = false
    self:sync()
    return string.format("Auction site on field %d cleared: %d vehicle(s) deleted%s.", site.fieldId, count,
        restored and ", the field put back as it was" or "")
end

-- Server (139): the lots nobody's farm won taken off the field (the
-- collection day's midnight), still listed as sold. Returns how many.
function TheContractorAuctionSite:removeUnsold()
    local site = self.site
    if site == nil then
        return 0
    end
    local count = 0
    for _, lot in ipairs(site.lots) do
        if lot.failed == nil and (lot.soldTo == nil or lot.soldTo <= 0) and lot.vehicleId ~= nil then
            for _, vehicle in ipairs({ getVehicle(lot.attachmentId) or false, getVehicle(lot.vehicleId) or false }) do
                if vehicle then
                    vehicle:delete()
                end
            end
            lot.soldTo = lot.soldTo or 0
            lot.vehicleId, lot.attachmentId = nil, nil
            count = count + 1
        end
    end
    if count > 0 then
        TCLog.info("TheContractor: %d unsold auction lot(s) taken away", count)
        self:sync()
    end
    return count
end

-- A vehicle's tilt from upright, in degrees.
function TheContractorAuctionSite.getTilt(vehicle)
    local _, upY = localDirectionToWorld(vehicle.rootNode, 0, 1, 0)
    return math.deg(math.acos(math.max(-1, math.min(1, upY))))
end

-- What to do about a lot's tilt (pure): "ok", "right" (stand it back up)
-- or "tipped" (it's been stood up as often as it will be).
function TheContractorAuctionSite.getUprightAction(tiltDegrees, attempts)
    if tiltDegrees <= TheContractorAuctionSite.TIP_DEGREES then
        return "ok"
    end
    if (attempts or 0) < TheContractorAuctionSite.UPRIGHT_ATTEMPTS then
        return "right"
    end
    return "tipped"
end

-- Server: a lot that's tipped over put back as it was set down, the shop's
-- offset included (vanilla's setAbsolutePosition, out of physics
-- meanwhile), and checked again later; one that tips again is taken away
-- (removeLot). A lot with its attachment hitched on isn't stood up (moving
-- the machine would leave the attachment behind), so a tipped one goes at
-- once.
function TheContractorAuctionSite:checkUpright(lot)
    local vehicle = getVehicle(lot.vehicleId)
    if vehicle == nil or vehicle.rootNode == nil or lot.pose == nil or self.site == nil then
        return
    end
    local action = TheContractorAuctionSite.getUprightAction(TheContractorAuctionSite.getTilt(vehicle),
        lot.attachmentId ~= nil and TheContractorAuctionSite.UPRIGHT_ATTEMPTS or lot.uprightAttempts)
    if action == "tipped" then
        self:removeLot(lot, "tipped over")
        return
    elseif action ~= "right" then
        return
    end
    lot.uprightAttempts = (lot.uprightAttempts or 0) + 1
    local pose = lot.pose
    TCLog.info("TheContractor: auction lot %d (%s) tipped over, stood back up", lot.number, vehicle:getFullName())
    vehicle:removeFromPhysics()
    vehicle:setAbsolutePosition(pose[1], pose[2], pose[3], pose[4], pose[5], pose[6])
    vehicle:addToPhysics()
    table.insert(self.uprightChecks, { lot = lot, dueMs = self.clockMs + TheContractorAuctionSite.UPRIGHT_CHECK_MS })
end

-- Server: a lot taken off the field (it and its attachment deleted), kept
-- in the site's list as failed, and every machine told.
function TheContractorAuctionSite:removeLot(lot, reason)
    TCLog.info("TheContractor: auction lot %d (%s) removed: %s", lot.number, lot.xmlFilename, reason)
    for _, vehicle in ipairs({ getVehicle(lot.attachmentId) or false, getVehicle(lot.vehicleId) or false }) do
        if vehicle then
            vehicle:delete()
        end
    end
    lot.failed = reason
    lot.vehicleId, lot.attachmentId = nil, nil
    self:sync()
end

-- Every frame (server): the frame time, and while lots spawn, its worst;
-- lots due a check for tipping over.
function TheContractorAuctionSite:update(dt)
    self.frameMs = self.frameMs ~= nil and (self.frameMs * 0.95 + dt * 0.05) or dt
    self.clockMs = self.clockMs + dt
    local site = self.site
    if site ~= nil and site.isSpawning then
        site.frames = site.frames + 1
        site.frameMsTotal = site.frameMsTotal + dt
        site.worstFrameMs = math.max(site.worstFrameMs, dt)
    end
    for i = #self.uprightChecks, 1, -1 do
        local check = self.uprightChecks[i]
        if self.clockMs >= check.dueMs then
            table.remove(self.uprightChecks, i)
            self:checkUpright(check.lot)
        end
    end
end

-- Debug lines -------------------------------------------------------------------------------

local function drawPolyline(points, r, g, b, closed)
    local count = #points
    local last = closed and count or count - 1
    for i = 1, last do
        local a, c = points[i], points[i % count + 1]
        local ay = getTerrainHeightAtWorldPos(g_terrainNode, a.x, 0, a.z) + 0.3
        local cy = getTerrainHeightAtWorldPos(g_terrainNode, c.x, 0, c.z) + 0.3
        drawDebugLine(a.x, ay, a.z, r, g, b, c.x, cy, c.z, r, g, b)
    end
end

-- Every frame on a machine with a client: the layout this session laid out.
function TheContractorAuctionSite:draw()
    local site = self.site
    if not self.debugVisible or site == nil or site.layout == nil or drawDebugLine == nil then
        return
    end
    local layout = site.layout
    for _, row in ipairs(layout.rows) do
        drawPolyline(row.corners, 1, 0.2, 0.2, true)
    end
    for _, aisle in ipairs(layout.aisles) do
        drawPolyline(aisle.points, 0.2, 1, 0.2, false)
    end
    drawPolyline(layout.reserve.corners, 0.3, 0.5, 1, true)
    local entrance = site.entrance
    if entrance ~= nil then
        local y = getTerrainHeightAtWorldPos(g_terrainNode, entrance.x, 0, entrance.z)
        drawDebugLine(entrance.x, y, entrance.z, 1, 1, 0, entrance.x, y + 6, entrance.z, 1, 1, 0)
        drawPolyline({ entrance, { x = entrance.edgeX, z = entrance.edgeZ } }, 1, 1, 0, false)
    end
end

-- Console text ------------------------------------------------------------------------------

local PROBLEM_WORDS = {
    [TCAuctionLayout.PROBLEM.TOO_SMALL] = "too small",
    [TCAuctionLayout.PROBLEM.TOO_STEEP] = "too steep",
    [TCAuctionLayout.PROBLEM.NO_ROAD] = "no road near",
}

function TheContractorAuctionSite.describeCandidate(candidate)
    local problems = {}
    for _, problem in ipairs(candidate.problems or {}) do
        table.insert(problems, PROBLEM_WORDS[problem] or problem)
    end
    return string.format("  field %d%s: %.2f ha, %d of %d lots fit, slope %s, road %s - %s", candidate.fieldId,
        candidate.holder ~= nil and (" (" .. candidate.holder .. ")") or "", candidate.areaHa, candidate.fitted,
        candidate.of,
        candidate.slopePercent ~= nil and string.format("steepest %.1f%%, average %.1f%%, rise %.1f m",
            candidate.slopePercent, candidate.averageSlope, candidate.rise) or "-",
        candidate.entranceDistance ~= nil and string.format("%.0f m from the edge", candidate.entranceDistance) or
            "none",
        #problems == 0 and "can hold the sale" or table.concat(problems, ", "))
end

-- tcDebug auctionSite: the site, if there's one, and the best fields.
function TheContractorAuctionSite:getListText(preferredLots)
    local lines = {}
    if self.site ~= nil then
        table.insert(lines, self:describe())
        table.insert(lines, "")
    end
    local started = getTimeSec()
    local ranked, fieldCount = self:getCandidates(preferredLots)
    table.insert(lines, string.format(
        "Auction site candidates (grass, bare or harvested, nobody's farm, no live job, %.0f ha or more), measured against a sale of %d lots, a sale needing %d, most lots first:",
        TheContractorAuctionSite.MIN_AREA_HA, preferredLots, TheContractorAuctionSite.MIN_LOTS))
    for i = 1, math.min(#ranked, TheContractorAuctionSite.TOP_CANDIDATES) do
        table.insert(lines, TheContractorAuctionSite.describeCandidate(ranked[i]))
    end
    local qualifying = 0
    for _, candidate in ipairs(ranked) do
        if #candidate.problems == 0 then
            qualifying = qualifying + 1
        end
    end
    table.insert(lines, string.format("%d of %d candidates can hold the sale (%d fields on the map), checked in %.0f ms.",
        qualifying, #ranked, fieldCount, (getTimeSec() - started) * 1000))
    return table.concat(lines, "\n")
end

-- The site: how far its spawning's got and what it cost, whether the lots
-- stayed where they were put, and what ADS made of them.
function TheContractorAuctionSite:describe()
    local site = self.site
    if site == nil then
        return "There's no auction site."
    end
    local lines = {}
    local out, failed, adsCounts = 0, {}, {}
    for _, lot in ipairs(site.lots) do
        if lot.failed ~= nil then
            table.insert(failed, string.format("  lot %d (%s, %s): %s", lot.number, lot.role, lot.xmlFilename,
                lot.failed))
        elseif getVehicle(lot.vehicleId) ~= nil then
            out = out + 1
            if lot.adsResult ~= nil then
                adsCounts[lot.adsResult] = (adsCounts[lot.adsResult] or 0) + 1
            end
        end
    end
    table.insert(lines, string.format("Auction site on field %d: %d of %d lots out, %d failed, %d didn't fit%s",
        site.fieldId, out, #site.lots, #failed, site.unplaced or 0,
        site.entrance ~= nil and string.format(", entrance %.0f m from the edge", site.entrance.distance) or
            ", no entrance"))

    if site.startedAt ~= nil then
        local done = site.spawnedAt or getTimeSec()
        local loadTotal, loadWorst, loaded = 0, 0, 0
        for _, lot in ipairs(site.lots) do
            if lot.loadMs ~= nil then
                loadTotal, loadWorst, loaded = loadTotal + lot.loadMs, math.max(loadWorst, lot.loadMs), loaded + 1
            end
        end
        table.insert(lines, string.format(
            "  %s %.1f s: %.0f ms a lot on average (longest %.0f ms). Frames while spawning: %.1f ms on average (%.0f fps), worst %.0f ms.",
            site.isSpawning and "Spawning for" or "Spawned in", done - site.startedAt,
            loaded > 0 and loadTotal / loaded or 0, loadWorst,
            site.frames > 0 and site.frameMsTotal / site.frames or 0,
            site.frames > 0 and 1000 * site.frames / math.max(site.frameMsTotal, 1) or 0, site.worstFrameMs))
    end
    if self.frameMs ~= nil then
        table.insert(lines, string.format("  Now: %.1f ms a frame (%.0f fps).", self.frameMs,
            1000 / math.max(self.frameMs, 0.001)))
    end

    -- Settling: how far each lot is from where it was put, and its tilt.
    local settled, measured, mostMoved, movedLot, mostTilt, tiltLot = 0, 0, 0, nil, 0, nil
    for _, lot in ipairs(site.lots) do
        local vehicle = getVehicle(lot.vehicleId)
        if vehicle ~= nil and vehicle.rootNode ~= nil and lot.rootX ~= nil then
            local x, _, z = getWorldTranslation(vehicle.rootNode)
            local moved = math.sqrt((x - lot.rootX) ^ 2 + (z - lot.rootZ) ^ 2)
            local tilt = TheContractorAuctionSite.getTilt(vehicle)
            measured = measured + 1
            if moved <= TheContractorAuctionSite.SETTLE_DISTANCE then
                settled = settled + 1
            end
            if moved > mostMoved then
                mostMoved, movedLot = moved, lot.number
            end
            if tilt > mostTilt then
                mostTilt, tiltLot = tilt, lot.number
            end
        end
    end
    local righted = {}
    for _, lot in ipairs(site.lots) do
        if (lot.uprightAttempts or 0) > 0 and lot.failed == nil then
            table.insert(righted, string.format("%d %s", lot.number, lot.role))
        end
    end
    if #righted > 0 then
        table.insert(lines, string.format("  Stood back up after tipping over: %s (any that tipped again were removed, below).",
            table.concat(righted, ", ")))
    end
    if measured > 0 then
        table.insert(lines, string.format(
            "  Settled: %d of %d within %.0f m of where they were put; most moved %.1f m (lot %s), most tilted %.0f degrees (lot %s).",
            settled, measured, TheContractorAuctionSite.SETTLE_DISTANCE, mostMoved, tostring(movedLot), mostTilt,
            tostring(tiltLot)))
    end

    if not TCADSUsedLots.isActive() then
        table.insert(lines, "  ADS: not loaded (or no reinitializeVehicle), vanilla condition only.")
    else
        local parts = {}
        for result, count in pairs(adsCounts) do
            table.insert(parts, string.format("%s %d", result, count))
        end
        table.sort(parts)
        table.insert(lines, "  ADS: " .. (#parts > 0 and table.concat(parts, ", ") or "none yet"))
    end

    local total = 0
    for _, lot in ipairs(site.lots) do
        total = total + (lot.guidePrice or 0)
    end
    table.insert(lines, string.format("  Guide prices: %s in all.", g_i18n:formatMoney(total, 0, true, true)))
    for _, lot in ipairs(site.lots) do
        if lot.guidePrice ~= nil then
            table.insert(lines, string.format("  lot %d %s: %s, %.1f h, %d months, guide %s%s", lot.number, lot.role,
                TheContractorFarmerFleet.getModelName(lot.xmlFilename), lot.hours, lot.ageMonths,
                g_i18n:formatMoney(lot.guidePrice, 0, true, true),
                lot.attachmentXml ~= nil and (lot.attachmentId ~= nil and " (with header)" or " (header left out)") or ""))
        end
    end
    for _, line in ipairs(failed) do
        table.insert(lines, line)
    end
    return table.concat(lines, "\n")
end

-- Persistence -----------------------------------------------------------------------------

function TheContractorAuctionSite:saveToXmlFile(xmlFile)
    if not g_currentMission:getIsServer() or self.site == nil then
        return
    end
    local site = self.site
    local key = TheContractor.SaveKey .. ".auctionSite"
    setXMLInt(xmlFile, key .. "#fieldId", site.fieldId)
    setXMLInt(xmlFile, key .. "#planned", site.planned or #site.lots)
    setXMLInt(xmlFile, key .. "#unplaced", site.unplaced or 0)
    if site.entrance ~= nil then
        setXMLFloat(xmlFile, key .. "#entranceX", site.entrance.x)
        setXMLFloat(xmlFile, key .. "#entranceZ", site.entrance.z)
        setXMLFloat(xmlFile, key .. "#entranceEdgeX", site.entrance.edgeX)
        setXMLFloat(xmlFile, key .. "#entranceEdgeZ", site.entrance.edgeZ)
        setXMLFloat(xmlFile, key .. "#entranceDistance", site.entrance.distance)
    end
    local index = 0
    for _, lot in ipairs(site.lots) do
        local uniqueId = lot.uniqueId or TCVehicleIds.getUniqueId(lot.vehicleId)
        if uniqueId ~= nil and lot.failed == nil then
            local lotKey = string.format("%s.lot(%d)", key, index)
            setXMLInt(xmlFile, lotKey .. "#number", lot.number)
            setXMLString(xmlFile, lotKey .. "#role", lot.role)
            setXMLString(xmlFile, lotKey .. "#xmlFilename", lot.xmlFilename)
            setXMLString(xmlFile, lotKey .. "#uniqueId", uniqueId)
            local attachmentUniqueId = lot.attachmentUniqueId or TCVehicleIds.getUniqueId(lot.attachmentId)
            if lot.attachmentXml ~= nil then
                setXMLString(xmlFile, lotKey .. "#attachmentXml", lot.attachmentXml)
            end
            if attachmentUniqueId ~= nil then
                setXMLString(xmlFile, lotKey .. "#attachmentUniqueId", attachmentUniqueId)
            end
            setXMLFloat(xmlFile, lotKey .. "#hours", lot.hours)
            setXMLInt(xmlFile, lotKey .. "#ageMonths", lot.ageMonths)
            setXMLFloat(xmlFile, lotKey .. "#damage", lot.damage)
            setXMLFloat(xmlFile, lotKey .. "#wear", lot.wear)
            setXMLFloat(xmlFile, lotKey .. "#guidePrice", lot.guidePrice or 0)
            setXMLInt(xmlFile, lotKey .. "#closeMinute", lot.closeMinute or 0)
            setXMLFloat(xmlFile, lotKey .. "#localRoll", lot.localRoll or 0.5)
            if lot.soldTo ~= nil then
                setXMLInt(xmlFile, lotKey .. "#soldTo", lot.soldTo)
                setXMLInt(xmlFile, lotKey .. "#salePrice", lot.salePrice or 0)
            end
            setXMLFloat(xmlFile, lotKey .. "#x", lot.rootX)
            setXMLFloat(xmlFile, lotKey .. "#z", lot.rootZ)
            setXMLFloat(xmlFile, lotKey .. "#yaw", lot.yaw)
            setXMLString(xmlFile, lotKey .. "#ads", lot.adsResult or "")
            index = index + 1
        end
    end
    if site.groundSnapshot ~= nil then
        TCFieldPreparation.saveSnapshot(xmlFile, key .. ".groundSnapshot", site.groundSnapshot)
    end
    for i, walkway in ipairs(site.walkways or {}) do
        local walkwayKey = string.format("%s.walkway(%d)", key, i - 1)
        setXMLFloat(xmlFile, walkwayKey .. "#x1", walkway.x1)
        setXMLFloat(xmlFile, walkwayKey .. "#z1", walkway.z1)
        setXMLFloat(xmlFile, walkwayKey .. "#x2", walkway.x2)
        setXMLFloat(xmlFile, walkwayKey .. "#z2", walkway.z2)
        setXMLFloat(xmlFile, walkwayKey .. "#halfWidth", walkway.halfWidth)
    end
    if site.scene ~= nil then
        TheContractorAuctionSite.saveScene(xmlFile, key .. ".scene", site.scene)
    end
end

-- 140: the scene's numbers, as written to the stream (TCAuctionSiteEvent).
local SCENE_FLOATS = { "cx", "cz", "angle", "halfV", "nearEdge", "farEdge", "aisleWidth", "endAisle", "gateV" }
local RESERVE_FLOATS = { "uFrom", "uTo", "vFrom", "vTo" }
-- 169: a ploughing plot's (164's plot).
local PLOT_FLOATS = { "cx", "cz", "angle", "half" }

function TheContractorAuctionSite.saveScene(xmlFile, key, scene)
    setXMLInt(xmlFile, key .. "#seed", scene.seed or 0)
    -- 163: dressed as another kind of day than the auction.
    if scene.dressing ~= nil then
        setXMLString(xmlFile, key .. "#dressing", scene.dressing)
    end
    if scene.pens ~= nil then
        setXMLInt(xmlFile, key .. "#pens", scene.pens)
    end
    setXMLInt(xmlFile, key .. "#nearSign", scene.nearSign)
    for _, name in ipairs(SCENE_FLOATS) do
        setXMLFloat(xmlFile, key .. "#" .. name, scene[name] or 0)
    end
    for _, name in ipairs(RESERVE_FLOATS) do
        setXMLFloat(xmlFile, key .. ".reserve#" .. name, scene.reserve[name])
    end
    for i, row in ipairs(scene.rows) do
        local rowKey = string.format("%s.row(%d)", key, i - 1)
        setXMLFloat(xmlFile, rowKey .. "#vFrom", row.vFrom)
        setXMLFloat(xmlFile, rowKey .. "#vTo", row.vTo)
        setXMLFloat(xmlFile, rowKey .. "#frontV", row.frontV)
        setXMLInt(xmlFile, rowKey .. "#facing", row.facing)
        setXMLFloat(xmlFile, rowKey .. "#used", row.used or 0)
        setXMLInt(xmlFile, rowKey .. "#lotFrom", row.lotFrom)
        setXMLInt(xmlFile, rowKey .. "#lotTo", row.lotTo)
        local slots = {}
        for _, u in ipairs(row.slots or {}) do
            table.insert(slots, string.format("%.3f", u))
        end
        setXMLString(xmlFile, rowKey .. "#slots", table.concat(slots, " "))
    end
    -- 169: the show's ploughing plots.
    for i, plot in ipairs(scene.plots or {}) do
        local plotKey = string.format("%s.plot(%d)", key, i - 1)
        for _, name in ipairs(PLOT_FLOATS) do
            setXMLFloat(xmlFile, plotKey .. "#" .. name, plot[name] or 0)
        end
    end
    -- 188: the show's breeders' pens.
    for i, breeder in ipairs(scene.breeders or {}) do
        local breederKey = string.format("%s.breeder(%d)", key, i - 1)
        setXMLInt(xmlFile, breederKey .. "#length", breeder.length or 2)
        setXMLInt(xmlFile, breederKey .. "#depth", breeder.depth or 2)
        setXMLBool(xmlFile, breederKey .. "#trailer", breeder.trailer == true)
        if breeder.typeName ~= nil then
            setXMLString(xmlFile, breederKey .. "#type", breeder.typeName)
        end
    end
end

-- The scene saved at key, or nil (none, or a save from before 140).
function TheContractorAuctionSite.loadScene(xmlFile, key)
    local seed = getXMLInt(xmlFile, key .. "#seed")
    local nearSign = getXMLInt(xmlFile, key .. "#nearSign")
    if seed == nil or nearSign == nil then
        return nil
    end
    local scene = { seed = seed, nearSign = nearSign >= 0 and 1 or -1, reserve = {}, rows = {},
        dressing = getXMLString(xmlFile, key .. "#dressing"), pens = getXMLInt(xmlFile, key .. "#pens") }
    for _, name in ipairs(SCENE_FLOATS) do
        scene[name] = getXMLFloat(xmlFile, key .. "#" .. name)
        if scene[name] == nil then
            return nil
        end
    end
    for _, name in ipairs(RESERVE_FLOATS) do
        scene.reserve[name] = getXMLFloat(xmlFile, key .. ".reserve#" .. name)
        if scene.reserve[name] == nil then
            return nil
        end
    end
    local i = 0
    while true do
        local rowKey = string.format("%s.row(%d)", key, i)
        if not hasXMLProperty(xmlFile, rowKey) then
            break
        end
        local row = {
            vFrom = getXMLFloat(xmlFile, rowKey .. "#vFrom"),
            vTo = getXMLFloat(xmlFile, rowKey .. "#vTo"),
            frontV = getXMLFloat(xmlFile, rowKey .. "#frontV"),
            facing = (getXMLInt(xmlFile, rowKey .. "#facing") or 1) >= 0 and 1 or -1,
            used = getXMLFloat(xmlFile, rowKey .. "#used") or 0,
            lotFrom = getXMLInt(xmlFile, rowKey .. "#lotFrom"),
            lotTo = getXMLInt(xmlFile, rowKey .. "#lotTo"),
            slots = {},
        }
        for word in string.gmatch(getXMLString(xmlFile, rowKey .. "#slots") or "", "%S+") do
            table.insert(row.slots, tonumber(word))
        end
        if row.vFrom ~= nil and row.vTo ~= nil and row.frontV ~= nil and row.lotFrom ~= nil and row.lotTo ~= nil then
            table.insert(scene.rows, row)
        end
        i = i + 1
    end
    scene.plots = {}
    i = 0
    while hasXMLProperty(xmlFile, string.format("%s.plot(%d)", key, i)) do
        local plotKey = string.format("%s.plot(%d)", key, i)
        local plot = {}
        for _, name in ipairs(PLOT_FLOATS) do
            plot[name] = getXMLFloat(xmlFile, plotKey .. "#" .. name) or 0
        end
        table.insert(scene.plots, plot)
        i = i + 1
    end
    -- 188: the show's breeders' pens.
    i = 0
    while hasXMLProperty(xmlFile, string.format("%s.breeder(%d)", key, i)) do
        local breederKey = string.format("%s.breeder(%d)", key, i)
        scene.breeders = scene.breeders or {}
        table.insert(scene.breeders, { length = getXMLInt(xmlFile, breederKey .. "#length") or 2,
            depth = getXMLInt(xmlFile, breederKey .. "#depth") or 2,
            trailer = getXMLBool(xmlFile, breederKey .. "#trailer") == true,
            typeName = getXMLString(xmlFile, breederKey .. "#type") })
        i = i + 1
    end
    return scene
end

function TheContractorAuctionSite:loadFromXMLFile(xmlFile)
    if not g_currentMission:getIsServer() then
        return
    end
    local key = TheContractor.SaveKey .. ".auctionSite"
    local fieldId = getXMLInt(xmlFile, key .. "#fieldId")
    if fieldId == nil then
        return
    end
    local site = {
        fieldId = fieldId,
        planned = getXMLInt(xmlFile, key .. "#planned"),
        unplaced = getXMLInt(xmlFile, key .. "#unplaced") or 0,
        lots = {},
        isSpawning = false,
        groundSnapshot = TCFieldPreparation.loadSnapshot(xmlFile, key .. ".groundSnapshot"),
    }
    local entranceX = getXMLFloat(xmlFile, key .. "#entranceX")
    if entranceX ~= nil then
        site.entrance = {
            x = entranceX,
            z = getXMLFloat(xmlFile, key .. "#entranceZ"),
            edgeX = getXMLFloat(xmlFile, key .. "#entranceEdgeX"),
            edgeZ = getXMLFloat(xmlFile, key .. "#entranceEdgeZ"),
            distance = getXMLFloat(xmlFile, key .. "#entranceDistance") or 0,
        }
    end
    local i = 0
    while true do
        local lotKey = string.format("%s.lot(%d)", key, i)
        if not hasXMLProperty(xmlFile, lotKey) then
            break
        end
        local lot = {
            number = getXMLInt(xmlFile, lotKey .. "#number") or i + 1,
            role = getXMLString(xmlFile, lotKey .. "#role"),
            xmlFilename = getXMLString(xmlFile, lotKey .. "#xmlFilename"),
            uniqueId = getXMLString(xmlFile, lotKey .. "#uniqueId"),
            attachmentXml = getXMLString(xmlFile, lotKey .. "#attachmentXml"),
            attachmentUniqueId = getXMLString(xmlFile, lotKey .. "#attachmentUniqueId"),
            hours = getXMLFloat(xmlFile, lotKey .. "#hours") or 0,
            ageMonths = getXMLInt(xmlFile, lotKey .. "#ageMonths") or 0,
            damage = getXMLFloat(xmlFile, lotKey .. "#damage") or 0,
            wear = getXMLFloat(xmlFile, lotKey .. "#wear") or 0,
            guidePrice = getXMLFloat(xmlFile, lotKey .. "#guidePrice"),
            closeMinute = getXMLInt(xmlFile, lotKey .. "#closeMinute"),
            -- 139: a save from before the sale rolls the room now.
            localRoll = getXMLFloat(xmlFile, lotKey .. "#localRoll") or math.random(),
            soldTo = getXMLInt(xmlFile, lotKey .. "#soldTo"),
            salePrice = getXMLInt(xmlFile, lotKey .. "#salePrice"),
            rootX = getXMLFloat(xmlFile, lotKey .. "#x"),
            rootZ = getXMLFloat(xmlFile, lotKey .. "#z"),
            yaw = getXMLFloat(xmlFile, lotKey .. "#yaw"),
        }
        local ads = getXMLString(xmlFile, lotKey .. "#ads")
        lot.adsResult = ads ~= nil and ads ~= "" and ads or nil
        if lot.role ~= nil and lot.xmlFilename ~= nil and lot.uniqueId ~= nil then
            table.insert(site.lots, lot)
        else
            TCLog.xmlWarning(xmlFile, "TheContractor: skipping auction lot %s", lotKey)
        end
        i = i + 1
    end
    -- A save from before 138 had no closing times: spread them now.
    for _, lot in ipairs(site.lots) do
        lot.closeMinute = lot.closeMinute or
            TheContractorAuctionSite.getCloseMinute(lot.number, math.max(site.planned or 0, #site.lots))
    end
    site.walkways = {}
    i = 0
    while true do
        local walkwayKey = string.format("%s.walkway(%d)", key, i)
        if not hasXMLProperty(xmlFile, walkwayKey) then
            break
        end
        local walkway = {
            x1 = getXMLFloat(xmlFile, walkwayKey .. "#x1"),
            z1 = getXMLFloat(xmlFile, walkwayKey .. "#z1"),
            x2 = getXMLFloat(xmlFile, walkwayKey .. "#x2"),
            z2 = getXMLFloat(xmlFile, walkwayKey .. "#z2"),
            halfWidth = getXMLFloat(xmlFile, walkwayKey .. "#halfWidth"),
        }
        if walkway.x1 ~= nil and walkway.z1 ~= nil and walkway.x2 ~= nil and walkway.z2 ~= nil and
                walkway.halfWidth ~= nil then
            table.insert(site.walkways, walkway)
        end
        i = i + 1
    end
    site.scene = TheContractorAuctionSite.loadScene(xmlFile, key .. ".scene")
    self.site = site
    -- Protected from the start; the vehicles follow in resolveSavedVehicles.
    self:applySync(fieldId, {}, site.walkways, site.scene)
end

-- Every machine (TCVehicleReplace): a lot reloaded as a new object (a lot
-- vanilla reset after it fell through the ground) is still the lot.
function TheContractorAuctionSite:remapVehicle(oldId, newId)
    local lotLists = { self.lots, self.site ~= nil and self.site.lots or nil }
    for _, lots in pairs(lotLists) do
        for _, lot in ipairs(lots) do
            TCVehicleIds.replaceField(lot, "vehicleId", oldId, newId)
            TCVehicleIds.replaceField(lot, "attachmentId", oldId, newId)
        end
    end
    if self.vehicleIdSet[oldId] then
        self:onLotsChanged()
    end
end

-- Server, once vehicles exist: each lot's vehicle again, a lot whose
-- vehicle has gone left out.
function TheContractorAuctionSite:resolveSavedVehicles()
    local site = self.site
    if site == nil then
        return
    end
    local lots = {}
    for _, lot in ipairs(site.lots) do
        lot.vehicleId = TCVehicleIds.getObjectId(lot.uniqueId)
        lot.attachmentId = lot.attachmentUniqueId ~= nil and TCVehicleIds.getObjectId(lot.attachmentUniqueId) or nil
        lot.uniqueId, lot.attachmentUniqueId = nil, nil
        if lot.vehicleId ~= nil then
            table.insert(lots, lot)
        else
            TCLog.info("TheContractor: auction lot %d (%s) has gone", lot.number, tostring(lot.xmlFilename))
        end
    end
    site.lots = lots
    self:sync()
end

function TheContractorAuctionSite:writeInitialClientState(streamId, connection)
    TCAuctionSiteEvent.writeSite(streamId, self.fieldId, self.lots, self.walkways, self.scene)
end

function TheContractorAuctionSite:readInitialClientState(streamId, connection)
    self:applySync(TCAuctionSiteEvent.readSite(streamId))
end

-- Console ---------------------------------------------------------------------------------

function TheContractorAuctionSite.registerConsoleCommands()
    TCConsole.register("debug", "auctionSite", {
        args = "[fieldId [lots]|clear]",
        description = "Auction site spike: the best fields for a sale, or lay out and spawn lots on a field, or clear them",
        run = function(_, args)
            local site = g_currentMission.TheContractor.AuctionSite
            if args[1] == nil then
                return site:getListText(TheContractorAuctionSite.PREFERRED_LOTS)
            end
            if string.lower(args[1]) == "clear" then
                return site:clear()
            end
            local fieldId = tonumber(args[1])
            local lots = args[2] ~= nil and tonumber(args[2]) or nil
            if fieldId == nil or (args[2] ~= nil and (lots == nil or lots < 1)) then
                return false
            end
            return site:start(fieldId, lots ~= nil and math.min(math.floor(lots), TheContractorAuctionSite.MAX_LOTS) or nil)
        end,
    })
end
