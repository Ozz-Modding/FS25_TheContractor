-- FS25_AdvancedDamageSystem's repair contracts API (100): ADS prepares a
-- customer's vehicle (age, wear, hidden faults or worn consumables), prices
-- the work, tells us the tools it needs and whether a farm has them, and
-- reports when it's done or tampered with. Everything else is ours
-- (TheContractorRepairContracts). See docs/ads-repair-contracts.md and
-- ADS's own guide, docs/ADS_RepairContracts_API_1.md.
--
-- The entry points are looked up once per loadMap (detect), the TCADSStock
-- way: anything missing, or an older API version, leaves the feature off
-- with one warning. Nothing else in the mod calls ADS_RepairContracts. Checked
-- against FS25_AdvancedDamageSystem 0.10.0.8 (commit a0285ed).

TCADSRepairContracts = {}

TCADSRepairContracts.MOD_NAME = "FS25_AdvancedDamageSystem"
TCADSRepairContracts.MIN_API_VERSION = 1
TCADSRepairContracts.LISTENER_ID = "TheContractor"

TCADSRepairContracts.KIND = {
    BREAKDOWN = "breakdown",
    REPAIR = "repair",
    MAINTENANCE = "maintenance",
}

TCADSRepairContracts.STATE = {
    OPEN = "open",
    DONE = "done",
    TAMPERED = "tampered",
    INVALID = "invalid",
}

TCADSRepairContracts.FIELD_SERVICE = {
    PLAYER = "player",
    MOBILE = "mobile",
}

-- getFarmTools' places (101 reads the two that can work in a field).
TCADSRepairContracts.PLACE = {
    PLAYER = "player",
    OWN_MOBILE = "ownMobile",
    OWN_WORKSHOP = "ownWorkshop",
}

TCADSRepairContracts.REQUIRED_FUNCTIONS = { "getInfo", "prepareVehicle", "getQuote", "getStatus", "checkTampering",
    "checkFarmTools", "getFarmTools", "registerListener", "unregisterListener", "release" }

-- ADS_RepairContracts, while it has everything we need; nil otherwise.
local api = nil
local warned = {}

local function warnOnce(key, text, ...)
    if not warned[key] then
        warned[key] = true
        Logging.warning("TheContractor: " .. text, ...)
    end
end

-- The ADS mod environment, or nil when it isn't loaded. A function so the
-- tests can swap it.
function TCADSRepairContracts.getEnv()
    return TheContractorDrivers.getModEnv(TCADSRepairContracts.MOD_NAME)
end

-- Called every loadMap.
function TCADSRepairContracts.detect()
    api = nil

    local env = TCADSRepairContracts.getEnv()
    if env == nil then
        return
    end

    local contracts = env.ADS_RepairContracts
    if type(contracts) ~= "table" then
        warnOnce("missing", "%s has no repair contracts API - repair zones get no work",
            TCADSRepairContracts.MOD_NAME)
        return
    end
    for _, name in ipairs(TCADSRepairContracts.REQUIRED_FUNCTIONS) do
        if type(contracts[name]) ~= "function" then
            warnOnce("function", "%s's repair contracts API has no %s - repair zones get no work",
                TCADSRepairContracts.MOD_NAME, name)
            return
        end
    end
    local info = contracts.getInfo()
    local version = type(info) == "table" and tonumber(info.version) or nil
    if version == nil or version < TCADSRepairContracts.MIN_API_VERSION then
        warnOnce("version", "%s's repair contracts API is version %s, we need %d - repair zones get no work",
            TCADSRepairContracts.MOD_NAME, tostring(version), TCADSRepairContracts.MIN_API_VERSION)
        return
    end
    api = contracts
end

-- ADS is loaded with an API we can use.
function TCADSRepairContracts.isActive()
    return api ~= nil
end

-- Server: prepares a freshly spawned vehicle. true, contractId or false,
-- reason.
function TCADSRepairContracts.prepareVehicle(vehicle, request)
    if api == nil then
        return false, "noAPI"
    end
    return api.prepareVehicle(vehicle, request)
end

-- Server: the contract comes off the vehicle (before it's deleted).
function TCADSRepairContracts.release(vehicle)
    if api == nil or vehicle == nil then
        return false
    end
    return api.release(vehicle)
end

-- The estimate fixed at preparation, or nil (any machine).
function TCADSRepairContracts.getQuote(vehicle)
    if api == nil or vehicle == nil then
        return nil
    end
    return api.getQuote(vehicle)
end

-- { state, items, operational, ... } or nil (any machine).
function TCADSRepairContracts.getStatus(vehicle)
    if api == nil or vehicle == nil then
        return nil
    end
    return api.getStatus(vehicle)
end

-- What the player can know of a contract's progress (any machine), or nil:
-- { kind, total, fixed, allKnown, items = { { kind, nameKey, operation,
-- price, done } } }. A fault counts as known once it's been found
-- (isVisible) or fixed, so nothing hidden is named or counted (099): items
-- lists the known ones, and total is only the real count while every fault
-- is known. Consumables are never hidden. operation is what to do: for a
-- fault, how the dealer's quote priced it ("repair" or "replacement"; any
-- way that clears it counts), for a consumable the service it needs
-- ("change", "topUp", "grease" or "replace"), else "service".
TCADSRepairContracts.OPERATIONS = {
    repairComponent = "repair",
    replaceComponent = "replacement",
    replaceFluid = "change",
    topUpFluid = "topUp",
    lubricate = "grease",
    replaceConsumable = "replace",
}

function TCADSRepairContracts.getProgress(vehicle)
    local quote = TCADSRepairContracts.getQuote(vehicle)
    local status = TCADSRepairContracts.getStatus(vehicle)
    if quote == nil or status == nil then
        return nil
    end
    local doneById = {}
    for _, item in ipairs(status.items or {}) do
        doneById[tostring(item.id)] = item.done == true
    end
    local breakdowns = vehicle.getActiveBreakdowns ~= nil and vehicle:getActiveBreakdowns() or {}
    local progress = { kind = quote.kind, total = 0, fixed = 0, allKnown = true, items = {} }
    for _, item in ipairs(quote.items or {}) do
        if item.kind == "fault" or item.kind == "consumable" then
            local done = doneById[tostring(item.id)] == true
            local known = item.kind == "consumable" or done
            if not known then
                local breakdown = breakdowns[item.id]
                known = type(breakdown) == "table" and breakdown.isVisible == true
            end
            progress.total = progress.total + 1
            if known then
                if done then
                    progress.fixed = progress.fixed + 1
                end
                local operation = TCADSRepairContracts.OPERATIONS[item.procedure] or "service"
                table.insert(progress.items, { kind = item.kind, nameKey = item.nameKey, operation = operation,
                    price = tonumber(item.price) or 0, done = done })
            else
                progress.allKnown = false
            end
        end
    end
    if not progress.allKnown then
        progress.total = nil
    end
    return progress
end

-- An ADS l10n key in ADS's own words, or the key itself.
function TCADSRepairContracts.getText(key)
    local modName = TCADSRepairContracts.MOD_NAME
    if key ~= nil and g_i18n.hasText ~= nil and g_i18n:hasText(key, modName) then
        return g_i18n:getText(key, modName)
    end
    return tostring(key)
end

-- tampered, findings (any machine).
function TCADSRepairContracts.checkTampering(vehicle)
    if api == nil or vehicle == nil then
        return false, {}
    end
    return api.checkTampering(vehicle)
end

-- { canDo, missing, items } or nil (any machine). The farm defaults to the
-- vehicle's owner, which for a contract vehicle is ours.
function TCADSRepairContracts.checkFarmTools(vehicle, farmId)
    if api == nil or vehicle == nil then
        return nil
    end
    return api.checkFarmTools(vehicle, farmId)
end

-- 101: placeId -> true for every place the farm can work from (an ADS tool
-- box, its own mobile workshop, its own workshop), any machine. Empty
-- without ADS.
function TCADSRepairContracts.getFarmPlaces(farmId)
    local places = {}
    if api == nil then
        return places
    end
    local farmTools = api.getFarmTools(farmId)
    for _, place in ipairs(type(farmTools) == "table" and farmTools.places or {}) do
        if place.id ~= nil then
            places[place.id] = true
        end
    end
    return places
end

-- Server: fn(vehicle, status) on a status change.
function TCADSRepairContracts.registerListener(fn)
    if api == nil then
        return false
    end
    return api.registerListener(TCADSRepairContracts.LISTENER_ID, function(vehicle, status)
        fn(vehicle, status)
    end)
end

function TCADSRepairContracts.unregisterListener()
    if api ~= nil then
        api.unregisterListener(TCADSRepairContracts.LISTENER_ID)
    end
end

-- ADS's list price of a new OEM part for one of the vehicle's components
-- (its parts shop's price), or nil if ADS can't say. Values what a
-- tampered vehicle lost.
function TCADSRepairContracts.getPartPrice(vehicle, componentId)
    local env = TCADSRepairContracts.getEnv()
    local maintenance = env ~= nil and env.ADS_Maintenance or nil
    local ads = env ~= nil and env.AdvancedDamageSystem or nil
    if api == nil or vehicle == nil or maintenance == nil or type(maintenance.getPartPrice) ~= "function" or
            ads == nil or ads.PART_TYPES == nil then
        return nil
    end
    local price = maintenance.getPartPrice(vehicle, componentId, ads.PART_TYPES.OEM)
    return tonumber(price)
end

-- "Lift, Machining" from ADS tool ids, in ADS's own words.
function TCADSRepairContracts.getToolNames(toolIds)
    local names = {}
    local modName = TCADSRepairContracts.MOD_NAME
    for _, toolId in ipairs(toolIds or {}) do
        local key = "ads_ws_tool_" .. tostring(toolId)
        if g_i18n.hasText ~= nil and g_i18n:hasText(key, modName) then
            table.insert(names, g_i18n:getText(key, modName))
        else
            table.insert(names, tostring(toolId))
        end
    end
    return table.concat(names, ", ")
end

-- One line for tcJob repairStatus.
function TCADSRepairContracts.describe()
    if TCADSRepairContracts.getEnv() == nil then
        return "ADS repair contracts: ADS not loaded"
    end
    if api == nil then
        return "ADS repair contracts: no usable API"
    end
    return string.format("ADS repair contracts: API version %s", tostring(api.getInfo().version))
end
