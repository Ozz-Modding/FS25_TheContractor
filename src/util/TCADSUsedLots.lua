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
-- Rule 099: nothing here returns or shows ADS's condition.

TCADSUsedLots = {}

TCADSUsedLots.MOD_NAME = "FS25_AdvancedDamageSystem"

-- ADS's reinitializeVehicle(vehicle, options) -> ok, condition, reason; nil
-- without ADS.
local reinitialize = nil
local warned = false

-- The ADS mod environment, or nil when it isn't loaded. A function so the
-- tests can swap it.
function TCADSUsedLots.getEnv()
    return TheContractorDrivers.getModEnv(TCADSUsedLots.MOD_NAME)
end

-- Called every loadMap.
function TCADSUsedLots.detect()
    reinitialize = nil
    local env = TCADSUsedLots.getEnv()
    if env == nil then
        return
    end
    for _, name in ipairs({ "AdvancedDamageSystem", "ADS_UsedVehicles" }) do
        local holder = env[name]
        if type(holder) == "table" and type(holder.reinitializeVehicle) == "function" then
            reinitialize = holder.reinitializeVehicle
            return
        end
    end
    if not warned then
        warned = true
        TCLog.warning("TheContractor: %s has no reinitializeVehicle - auction lots get vanilla condition only",
            TCADSUsedLots.MOD_NAME)
    end
end

function TCADSUsedLots.isActive()
    return reinitialize ~= nil
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
