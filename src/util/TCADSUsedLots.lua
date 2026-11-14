-- FS25_AdvancedDamageSystem for auction lots (135): ADS gives a used machine
-- a believable history from its hours and damage. Found through ADS's
-- public reinitializeVehicle (AdvancedDamageSystem's, or ADS_UsedVehicles'
-- where the alias has gone), looked up once per loadMap (detect) and
-- nil-checked; without it a lot keeps vanilla's damage and wear.
--
-- The generic route, with no change to ADS (checked against
-- FS25_AdvancedDamageSystem at 6cbc127):
--   - ADS blocks setOperatingTime unless it's writing it itself, ADS
--     excludes the vehicle, or the write says it's loading. A lot's hours are
--     written as loading (TheContractorAuctionSite.applyCondition), the way
--     ADS's own save and stream reads write them, so the lot needn't be
--     excluded and included again around it.
--   - ADS builds a history by itself the first time it registers a machine
--     with no saved state (its registerVehicle, in its onUpdate, a moment
--     after the vehicle loads). reinitializeVehicle builds it again from the
--     hours, age and damage the lot has by then (and turns the damage into
--     ADS's own wear: vanilla damage goes to 0), and marks the state as
--     loaded, so ADS's registration leaves it alone.
--   - reinitializeVehicle makes the vehicle tabbable (Enterable's flag);
--     lots are kept out of the Tab cycle by TCVehicleLock's wrap, which that
--     doesn't touch.
--
-- Lots are for sale to ADS (152): we register as a seller with
-- ADS_UsedVehicles.registerSeller, so a lot gets a UEY listing's rules: any
-- farm may order an inspection of it (it's farm 0's), nothing else can be
-- done to it, and the farm that orders one pays. Registered on every
-- machine (ADS's client UI asks too) at loadMap, taken off at deleteMap. The
-- answer is AuctionSite:isLot, live and the same on every machine from the
-- synced lots, so a won lot (out of the lot set at once, 139) is the
-- winner's to service with no word to ADS. Without registerSeller (an ADS
-- from before it) lots can't be inspected, with one warning.
--
-- What's been inspected (152's lot inspection jobs), through ADS's own
-- public ADS_Maintenance functions, with no change to ADS (checked at
-- 80ecc85): getInspectionZones (every part the impact wrench inspects on the
-- vehicle, zone by zone), getConfirmedData and getConfirmedComponentCoverage
-- (for each part, the last inspection that covered it: its log record's id
-- and its depth, INSPECTION_LEVELS: 1 visual, 2 standard, 3 complete). A
-- workshop inspection covers every part at once; the wrench's covers the
-- parts of each zone scanned. Record ids are saved by ADS, so they hold
-- across a load. Nothing ADS found is read. Without them (one warning) no
-- lot inspection jobs are offered.
--
-- Rule 099: nothing here returns or shows ADS's condition.

TCADSUsedLots = {}

TCADSUsedLots.MOD_NAME = "FS25_AdvancedDamageSystem"
TCADSUsedLots.SELLER_ID = "FS25_TheContractor"

-- ADS's reinitializeVehicle(vehicle, options) -> ok, condition, reason; nil
-- without ADS.
local reinitialize = nil
-- ADS_UsedVehicles while we're registered as a seller with it, else nil.
local sellerRegistry = nil
-- ADS_Maintenance while it can say what's been inspected, and the depth of
-- its standard inspection; nil otherwise.
local maintenance = nil
local standardLevel = nil
local warned = {}

local function warnOnce(key, text, ...)
    if not warned[key] then
        warned[key] = true
        TCLog.warning("TheContractor: " .. text, ...)
    end
end

-- The ADS mod environment, or nil when it isn't loaded. A function so the
-- tests can swap it.
function TCADSUsedLots.getEnv()
    return TheContractorDrivers.getModEnv(TCADSUsedLots.MOD_NAME)
end

local function findReinitialize(env)
    for _, name in ipairs({ "AdvancedDamageSystem", "ADS_UsedVehicles" }) do
        local holder = env[name]
        if type(holder) == "table" and type(holder.reinitializeVehicle) == "function" then
            return holder.reinitializeVehicle
        end
    end
    warnOnce("reinitialize", "%s has no reinitializeVehicle - auction lots get vanilla condition only",
        TCADSUsedLots.MOD_NAME)
    return nil
end

-- Whether a vehicle is one of the auction's lots for sale: ADS's seller
-- callback. Every machine.
function TCADSUsedLots.isLotForSale(vehicle)
    local tc = g_currentMission ~= nil and g_currentMission.TheContractor or nil
    local site = tc ~= nil and tc.AuctionSite or nil
    return site ~= nil and site:isLot(vehicle)
end

local function registerSeller(env)
    local usedVehicles = env.ADS_UsedVehicles
    if type(usedVehicles) ~= "table" or type(usedVehicles.registerSeller) ~= "function"
        or type(usedVehicles.unregisterSeller) ~= "function" then
        warnOnce("seller", "%s has no ADS_UsedVehicles.registerSeller - auction lots can't be inspected",
            TCADSUsedLots.MOD_NAME)
        return
    end
    if usedVehicles.registerSeller(TCADSUsedLots.SELLER_ID, TCADSUsedLots.isLotForSale) == true then
        sellerRegistry = usedVehicles
    end
end

TCADSUsedLots.INSPECTION_FUNCTIONS = { "getInspectionZones", "getConfirmedData", "getConfirmedComponentCoverage" }

local function findInspections(env)
    local candidate = env.ADS_Maintenance
    local levels = type(candidate) == "table" and candidate.INSPECTION_LEVELS or nil
    local level = type(levels) == "table" and tonumber(levels.CONSUMABLES) or nil
    local isComplete = level ~= nil
    for _, name in ipairs(TCADSUsedLots.INSPECTION_FUNCTIONS) do
        if not isComplete or type(candidate[name]) ~= "function" then
            isComplete = false
        end
    end
    if not isComplete then
        warnOnce("inspections", "%s's ADS_Maintenance can't say what's been inspected - no auction lot inspection jobs",
            TCADSUsedLots.MOD_NAME)
        return
    end
    maintenance = candidate
    standardLevel = level
end

-- Called every loadMap, on every machine.
function TCADSUsedLots.detect()
    TCADSUsedLots.uninstall()
    reinitialize = nil
    maintenance = nil
    standardLevel = nil
    local env = TCADSUsedLots.getEnv()
    if env == nil then
        return
    end
    reinitialize = findReinitialize(env)
    registerSeller(env)
    findInspections(env)
end

-- deleteMap: lots are no longer ADS's business.
function TCADSUsedLots.uninstall()
    if sellerRegistry ~= nil then
        sellerRegistry.unregisterSeller(TCADSUsedLots.SELLER_ID)
        sellerRegistry = nil
    end
end

function TCADSUsedLots.isActive()
    return reinitialize ~= nil
end

-- 152: whether ADS treats our lots as for sale (any farm may inspect one).
function TCADSUsedLots.isSellerRegistered()
    return sellerRegistry ~= nil
end

-- 152: whether ADS can say what's been inspected.
function TCADSUsedLots.canReadInspections()
    return maintenance ~= nil
end

-- Every part's coverage: { { entryId, level } or false }, one per part of
-- every zone, or nil without ADS or parts.
local function getCoverage(vehicle)
    if maintenance == nil or vehicle == nil then
        return nil
    end
    local zones = maintenance.getInspectionZones(vehicle)
    local report = maintenance.getConfirmedData(vehicle)
    if type(zones) ~= "table" or #zones == 0 then
        return nil
    end
    local result = {}
    for _, zone in ipairs(zones) do
        for _, component in ipairs(type(zone) == "table" and zone.components or {}) do
            local source = component.id ~= nil and maintenance.getConfirmedComponentCoverage(report, component.id) or nil
            if type(source) == "table" then
                table.insert(result, { entryId = tonumber(source.entryId) or 0, level = tonumber(source.level) or 0 })
            else
                table.insert(result, false)
            end
        end
    end
    return #result > 0 and result or nil
end

-- 152, server: where the vehicle's inspections stand now, to count new
-- ones from: the newest log record covering any part (0 for none).
function TCADSUsedLots.getInspectionMark(vehicle)
    local mark = 0
    for _, source in ipairs(getCoverage(vehicle) or {}) do
        if source and source.entryId > mark then
            mark = source.entryId
        end
    end
    return mark
end

-- 152, server: whether every part of the vehicle has been inspected at
-- standard depth or deeper (never the quick visual one) by a log record
-- newer than mark: a workshop inspection, or the impact wrench's standard
-- inspection of every zone.
function TCADSUsedLots.isInspectedSince(vehicle, mark)
    local coverage = getCoverage(vehicle)
    if coverage == nil then
        return false
    end
    for _, source in ipairs(coverage) do
        if not source or source.level < standardLevel or source.entryId <= (mark or 0) then
            return false
        end
    end
    return true
end

-- Whether ADS looks after this vehicle: it has ADS's specialization and
-- isn't excluded (an electric machine is, by default).
function TCADSUsedLots.isADSVehicle(vehicle)
    return vehicle ~= nil and vehicle.spec_AdvancedDamageSystem ~= nil and
        (vehicle.getIsADSExcluded == nil or not vehicle:getIsADSExcluded())
end

-- Server: ADS's history for a lot from the hours, age and damage it's been
-- given. Returns true, or false and why ("noADS", "notADS", or ADS's own
-- reason: "EXCLUDED", "BUSY", ...).
function TCADSUsedLots.initialiseLot(vehicle)
    if reinitialize == nil then
        return false, "noADS"
    end
    if not TCADSUsedLots.isADSVehicle(vehicle) then
        return false, "notADS"
    end
    local ok, _, reason = reinitialize(vehicle)
    if ok ~= true then
        return false, tostring(reason or "failed")
    end
    return true
end
