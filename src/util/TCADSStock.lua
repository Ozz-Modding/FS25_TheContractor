-- Supplies tab (064): the workshop stock FS25_AdvancedDamageSystem (ADS)
-- adds - oils, coolant, grease, batteries, air filters and spare parts
-- boxes - when it's loaded. The only place the tab touches ADS.
--
-- Nothing about ADS's items is written out here. ADS is in active
-- development, so the list is built from ADS itself every time:
--
--   consumables   every farm-owned object goes through ADS's own stock
--                 classifier, ADS_PlayerWorkshop.collectStockSources (the
--                 one its workshop uses to find stock near a vehicle). It
--                 reports fluids, grease and packs as { kind, key, tier,
--                 grade, amount, ... }, grouped here by kind/key/tier/grade.
--   parts boxes   ADS_SparePartsBox.isBox/getState, one row per part and
--                 tier, and isReserved for the ones a work order holds.
--
-- Each feature has its own capability flag, worked out once per loadMap
-- (detect). A missing entry point hides only what needs it, with one
-- warning per session naming it: no consumables view without the
-- classifier, no spare parts view without isBox/getState, no free/reserved
-- split without isReserved. Checked against refs/FS25_AdvancedDamageSystem
-- (0.10.0.0). Tier labels use ADS's own texts where it has one, and the raw
-- tier otherwise.

TCADSStock = {}

TCADSStock.MOD_NAME = "FS25_AdvancedDamageSystem"

-- ADS's text keys for a tier: consumables (LIZARD/ORIGINAL/PREMIUM) and
-- spare parts (OEM/AFTERMARKET/PREMIUM/USED).
TCADSStock.CONSUMABLE_TIER_PREFIX = "ads_ws_quality_"
TCADSStock.PART_TIER_PREFIX = "ads_spec_part_types_"

-- Display order of the consumable kinds ADS reports.
local KIND_ORDER = { fluid = 1, grease = 2, pack = 3 }

local capabilities = {}
local entryPoints = {}
-- Entry points already warned about this session.
local warned = {}

-- The ADS mod environment, or nil when it isn't loaded. A function so the
-- tests can swap it.
function TCADSStock.getEnv()
    return TheContractorDrivers.getModEnv(TCADSStock.MOD_NAME)
end

local function lookUp(env, tableName, fieldName, expectedType)
    local owner = env[tableName]
    local value = type(owner) == "table" and owner[fieldName] or nil
    if type(value) ~= expectedType then
        local name = tableName .. "." .. fieldName
        if not warned[name] then
            warned[name] = true
            Logging.warning("TheContractor: %s's %s is missing or has changed - the Supplies tab hides what needs it",
                TCADSStock.MOD_NAME, name)
        end
        return nil
    end
    return value
end

-- Called every loadMap: which parts of the ADS view can be offered.
function TCADSStock.detect()
    capabilities = {}
    entryPoints = {}

    local env = TCADSStock.getEnv()
    if env == nil then
        return
    end

    entryPoints.collectStockSources = lookUp(env, "ADS_PlayerWorkshop", "collectStockSources", "function")
    entryPoints.stockKinds = lookUp(env, "ADS_PlayerWorkshop", "STOCK_KINDS", "table")
    capabilities.consumables = entryPoints.collectStockSources ~= nil and entryPoints.stockKinds ~= nil

    entryPoints.isBox = lookUp(env, "ADS_SparePartsBox", "isBox", "function")
    entryPoints.getBoxState = lookUp(env, "ADS_SparePartsBox", "getState", "function")
    capabilities.partsBoxes = entryPoints.isBox ~= nil and entryPoints.getBoxState ~= nil

    if capabilities.partsBoxes then
        entryPoints.isReserved = lookUp(env, "ADS_SparePartsBox", "isReserved", "function")
        capabilities.reservations = entryPoints.isReserved ~= nil
    end
end

function TCADSStock.hasConsumables()
    return capabilities.consumables == true
end

function TCADSStock.hasPartsBoxes()
    return capabilities.partsBoxes == true
end

function TCADSStock.hasReservations()
    return capabilities.reservations == true
end

function TCADSStock.isAvailable()
    return TCADSStock.hasConsumables() or TCADSStock.hasPartsBoxes()
end

-- ADS's own text for a tier, or the tier as it is.
function TCADSStock.getTierText(prefix, tier)
    if tier == nil or tier == "" then
        return ""
    end
    local key = prefix .. string.lower(tostring(tier))
    if g_i18n.hasText ~= nil and g_i18n:hasText(key, TCADSStock.MOD_NAME) then
        return g_i18n:getText(key, TCADSStock.MOD_NAME)
    end
    return tostring(tier)
end

local function getFarmObjects(farmId)
    local result = {}
    for _, object in ipairs(g_currentMission.vehicleSystem.vehicles) do
        if not object.isDeleted and object.getOwnerFarmId ~= nil and object:getOwnerFarmId() == farmId then
            table.insert(result, object)
        end
    end
    return result
end

local function getObjectName(object)
    return object.getName ~= nil and object:getName() or ""
end

-- Consumables -----------------------------------------------------------------

local function getConsumableName(source, object, tierText)
    if source.fillTypeIndex ~= nil then
        local title = g_fillTypeManager:getFillTypeTitleByIndex(source.fillTypeIndex)
        if title ~= nil and title ~= "" then
            return title
        end
    end
    local parts = { getObjectName(object) }
    if source.grade ~= nil and source.grade ~= "" then
        table.insert(parts, tostring(source.grade))
    end
    if tierText ~= "" then
        table.insert(parts, tierText)
    end
    return table.concat(parts, ", ")
end

-- The farm's ADS consumables, one row per kind/key/tier/grade: {
--   key, kind, name, tierText, fillTypeIndex (fluids and grease),
--   amount     litres/grams of a fluid or grease, a count of packs
--   capacity   the fluid/grease containers' capacity, nil for packs
--   sources    { { name, amount, capacity }... }, one per object
-- }. Empty if the classifier isn't there.
function TCADSStock.getConsumableRows(farmId)
    local rows = {}
    if not TCADSStock.hasConsumables() then
        return rows
    end

    local packKind = entryPoints.stockKinds.PACK
    local rowsByKey = {}
    for _, object in ipairs(getFarmObjects(farmId)) do
        local list = {}
        entryPoints.collectStockSources(object, list)

        local countedUnits = {}
        for _, source in ipairs(list) do
            local amount = tonumber(source.amount) or 0
            if source.key ~= nil and amount > 0 then
                local key = table.concat({ tostring(source.kind), tostring(source.key), tostring(source.tier),
                    tostring(source.grade or "") }, "|")
                local row = rowsByKey[key]
                if row == nil then
                    local tierText = TCADSStock.getTierText(TCADSStock.CONSUMABLE_TIER_PREFIX, source.tier)
                    local isPack = source.kind == packKind
                    row = {
                        key = key,
                        kind = source.kind,
                        tierText = tierText,
                        name = getConsumableName(source, object, tierText),
                        fillTypeIndex = not isPack and source.fillTypeIndex or nil,
                        amount = 0,
                        capacity = not isPack and 0 or nil,
                        sources = {},
                        sourceByObject = {},
                    }
                    rowsByKey[key] = row
                    table.insert(rows, row)
                end

                row.amount = row.amount + amount
                local entry = row.sourceByObject[object]
                if entry == nil then
                    entry = { name = getObjectName(object), amount = 0, capacity = row.capacity ~= nil and 0 or nil }
                    row.sourceByObject[object] = entry
                    table.insert(row.sources, entry)
                end
                entry.amount = entry.amount + amount

                -- A drum pallet reports its opened drum and its full ones
                -- separately, from the same fill unit: count its room once.
                local unitKey = tostring(source.fillUnitIndex)
                if row.capacity ~= nil and source.fillUnitIndex ~= nil and not countedUnits[unitKey] and
                    object.getFillUnitCapacity ~= nil then
                    countedUnits[unitKey] = true
                    local capacity = tonumber(object:getFillUnitCapacity(source.fillUnitIndex)) or 0
                    row.capacity = row.capacity + capacity
                    entry.capacity = entry.capacity + capacity
                end
            end
        end
    end

    for _, row in ipairs(rows) do
        row.sourceByObject = nil
        if row.capacity ~= nil and row.capacity <= 0 then
            row.capacity = nil
        end
    end
    table.sort(rows, function(a, b)
        local orderA, orderB = KIND_ORDER[a.kind] or 99, KIND_ORDER[b.kind] or 99
        if orderA ~= orderB then
            return orderA < orderB
        end
        return a.name < b.name
    end)
    return rows
end

-- Spare parts boxes -----------------------------------------------------------

-- The farm's spare parts boxes, one row per part and tier: {
--   key, name, tierText, count,
--   reserved   how many a work order holds, nil without isReserved
--   fits       { { vehicleName, count }... }
-- }. ADS's free preview samples aren't stock. Empty without isBox/getState.
function TCADSStock.getPartBoxRows(farmId)
    local rows = {}
    if not TCADSStock.hasPartsBoxes() then
        return rows
    end

    local rowsByKey = {}
    for _, object in ipairs(getFarmObjects(farmId)) do
        if entryPoints.isBox(object) then
            local state = entryPoints.getBoxState(object)
            if state ~= nil and not state.isPreview then
                local key = tostring(state.componentId) .. "|" .. tostring(state.tier)
                local row = rowsByKey[key]
                if row == nil then
                    row = {
                        key = key,
                        name = getObjectName(object),
                        tierText = TCADSStock.getTierText(TCADSStock.PART_TIER_PREFIX, state.tier),
                        count = 0,
                        reserved = TCADSStock.hasReservations() and 0 or nil,
                        fits = {},
                        fitsByName = {},
                    }
                    rowsByKey[key] = row
                    table.insert(rows, row)
                end

                row.count = row.count + 1
                if row.reserved ~= nil and entryPoints.isReserved(object) then
                    row.reserved = row.reserved + 1
                end
                local vehicleName = state.vehicleName ~= nil and state.vehicleName ~= "" and state.vehicleName or "-"
                local fit = row.fitsByName[vehicleName]
                if fit == nil then
                    fit = { vehicleName = vehicleName, count = 0 }
                    row.fitsByName[vehicleName] = fit
                    table.insert(row.fits, fit)
                end
                fit.count = fit.count + 1
            end
        end
    end

    for _, row in ipairs(rows) do
        row.fitsByName = nil
        table.sort(row.fits, function(a, b)
            return a.vehicleName < b.vehicleName
        end)
    end
    table.sort(rows, function(a, b)
        if a.name ~= b.name then
            return a.name < b.name
        end
        return a.tierText < b.tierText
    end)
    return rows
end
