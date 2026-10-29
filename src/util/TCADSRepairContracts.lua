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
-- against FS25_AdvancedDamageSystem 0.10.0.8 (commit a0285ed), and 102's
-- stage gate and per-option costs at fffc957 (still API version 1, so they're
-- detected by their functions). 116's targets are optional (hasTargets,
-- getStockParts).

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

-- 102: a contract allows inspections only until we authorize it (the
-- customer's agreed a price).
TCADSRepairContracts.STAGE = {
    INSPECTION = "inspection",
    AUTHORIZED = "authorized",
}

TCADSRepairContracts.REQUIRED_FUNCTIONS = { "getInfo", "prepareVehicle", "getQuote", "getStatus", "checkTampering",
    "checkFarmTools", "getFarmTools", "registerListener", "unregisterListener", "release", "authorize", "getStage",
    "isWorkLocked" }

-- ADS_RepairContracts, while it has everything we need; nil otherwise.
local api = nil
local warned = {}

local function warnOnce(key, text, ...)
    if not warned[key] then
        warned[key] = true
        TCLog.warning("TheContractor: " .. text, ...)
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

-- 116: whether ADS can be told which consumables a service is
-- (prepareVehicle's targets), which getInfo says. Optional: without it
-- there are no farmer favours, and everything else works as before.
function TCADSRepairContracts.hasTargets()
    if api == nil then
        return false
    end
    local info = api.getInfo()
    if type(info) ~= "table" or info.targets ~= true then
        warnOnce("targets", "%s's repair contracts API takes no targets - no farmer favours",
            TCADSRepairContracts.MOD_NAME)
        return false
    end
    return true
end

-- 116: the parts a farm can keep in stock and fit to any machine: ADS's
-- fixed-size parts (SPARE_PARTS_BOX.GRADED_PARTS, the battery and the air
-- filter), sold in S/M/L as items of their own rather than in a parts box
-- made for one model, and fitted by hand. { { id, nameKey } }, empty
-- without them (one warning).
function TCADSRepairContracts.getStockParts()
    local env = TCADSRepairContracts.getEnv()
    local config = env ~= nil and env.ADS_Config or nil
    local box = type(config) == "table" and config.SPARE_PARTS_BOX or nil
    local parts = type(box) == "table" and box.GRADED_PARTS or nil
    if type(parts) ~= "table" then
        warnOnce("stockParts", "%s has no ADS_Config.SPARE_PARTS_BOX.GRADED_PARTS - no farmer favours",
            TCADSRepairContracts.MOD_NAME)
        return {}
    end
    local result = {}
    for _, part in ipairs(parts) do
        if type(part) == "table" and part.id ~= nil then
            table.insert(result, { id = part.id, nameKey = part.nameKey })
        end
    end
    return result
end

-- 116: the size (ADS's grade, "S", "M" or "L") of a stock part the vehicle
-- takes, from ADS's parts shop, or nil (one warning without it).
function TCADSRepairContracts.getPartGrade(vehicle, partId)
    local env = TCADSRepairContracts.getEnv()
    local partsShop = env ~= nil and env.ADS_PartsShop or nil
    if partsShop == nil or type(partsShop.getPartGrade) ~= "function" then
        warnOnce("partGrade", "%s has no ADS_PartsShop.getPartGrade - favours don't say the part's size",
            TCADSRepairContracts.MOD_NAME)
        return nil
    end
    if vehicle == nil then
        return nil
    end
    local grade = partsShop.getPartGrade(vehicle, partId)
    return grade ~= nil and tostring(grade) or nil
end

-- Server: prepares a freshly spawned vehicle. true, contractId or false,
-- reason.
function TCADSRepairContracts.prepareVehicle(vehicle, request)
    if api == nil then
        return false, "noAPI"
    end
    return api.prepareVehicle(vehicle, request)
end

-- 102, server: the customer's agreed a price, so ADS lets the work start.
function TCADSRepairContracts.authorize(vehicle)
    if api == nil or vehicle == nil then
        return false
    end
    return api.authorize(vehicle)
end

-- "inspection" or "authorized", or nil (any machine).
function TCADSRepairContracts.getStage(vehicle)
    if api == nil or vehicle == nil then
        return nil
    end
    return api.getStage(vehicle)
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
-- is known. A service's consumables are known once the machine's been
-- inspected (102, isServiceInspected). operation is what to do: for a
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

-- 102: a service's consumables are only known once the machine's been
-- inspected: ADS makes a contract vehicle's history unknown to the farm
-- (setBaselineUnknown), so it shows nothing about them before. The
-- inspection date is nil until the first inspection after preparation (and
-- 0 for an empty log). Without ADS_Maintenance.getLastInspectionDate the
-- consumables count as known, as they did before ADS hid them.
function TCADSRepairContracts.isServiceInspected(vehicle)
    local env = TCADSRepairContracts.getEnv()
    local maintenance = env ~= nil and env.ADS_Maintenance or nil
    if maintenance == nil or type(maintenance.getLastInspectionDate) ~= "function" then
        warnOnce("inspectionDate", "%s has no ADS_Maintenance.getLastInspectionDate - services count as inspected",
            TCADSRepairContracts.MOD_NAME)
        return true
    end
    local date = maintenance.getLastInspectionDate(vehicle)
    return date ~= nil and date ~= 0
end

-- Whether each of the contract's faults (or, for a service, the machine)
-- is known: a fault once it's been found (isVisible) or fixed. doneById is
-- the status's items by id; breakdowns the vehicle's active breakdowns.
local function isItemKnown(item, done, breakdowns, serviceInspected)
    if done then
        return true
    end
    if item.kind == "consumable" then
        return serviceInspected
    end
    local breakdown = breakdowns[item.id]
    return type(breakdown) == "table" and breakdown.isVisible == true
end

local function getDoneById(vehicle)
    local status = TCADSRepairContracts.getStatus(vehicle)
    if status == nil then
        return nil
    end
    local doneById = {}
    for _, item in ipairs(status.items or {}) do
        doneById[tostring(item.id)] = item.done == true
    end
    return doneById
end

local function getBreakdowns(vehicle)
    return vehicle.getActiveBreakdowns ~= nil and vehicle:getActiveBreakdowns() or {}
end

-- 102: whether the whole contract is known, so it can be priced: every
-- fault found or fixed, or a service's machine inspected. Any machine.
function TCADSRepairContracts.isInspected(vehicle)
    local quote = TCADSRepairContracts.getQuote(vehicle)
    local doneById = quote ~= nil and getDoneById(vehicle) or nil
    if doneById == nil then
        return false
    end
    if quote.kind == TCADSRepairContracts.KIND.MAINTENANCE then
        return TCADSRepairContracts.isServiceInspected(vehicle)
    end
    local breakdowns = getBreakdowns(vehicle)
    for _, item in ipairs(quote.items or {}) do
        if item.kind == "fault" and not isItemKnown(item, doneById[tostring(item.id)] == true, breakdowns, false) then
            return false
        end
    end
    return true
end

-- 116: allKnown (a farmer's favour): the customer has said what's wrong, so
-- every item's known whatever's been inspected.
function TCADSRepairContracts.getProgress(vehicle, allKnown)
    local quote = TCADSRepairContracts.getQuote(vehicle)
    local doneById = quote ~= nil and getDoneById(vehicle) or nil
    if doneById == nil then
        return nil
    end
    local breakdowns = getBreakdowns(vehicle)
    local serviceInspected = quote.kind ~= TCADSRepairContracts.KIND.MAINTENANCE or
        TCADSRepairContracts.isServiceInspected(vehicle)
    local progress = { kind = quote.kind, total = 0, fixed = 0, allKnown = true, items = {} }
    for _, item in ipairs(quote.items or {}) do
        if item.kind == "fault" or item.kind == "consumable" then
            local done = doneById[tostring(item.id)] == true
            local known = allKnown == true or isItemKnown(item, done, breakdowns, serviceInspected)
            progress.total = progress.total + 1
            if known then
                if done then
                    progress.fixed = progress.fixed + 1
                end
                local operation = TCADSRepairContracts.OPERATIONS[item.procedure] or "service"
                table.insert(progress.items, { id = tostring(item.id), kind = item.kind, nameKey = item.nameKey,
                    operation = operation,
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

-- 102: what the farm can do about the contract, as far as it's known (any
-- machine), or nil:
--   { inspected,
--     faults = { { nameKey, done, subcontractPrice,
--                  options = { { operation, tools, canDo, place, missing, partsCost, laborHours } } } },
--     plan = { canDo, partsCost, laborHours, subcontractCost } or nil,
--     missing = { toolId, ... } or nil }
-- faults lists only those found or fixed (099). The plan and missing cover
-- every fault ADS knows of, found or not, so they're only given once
-- isInspected: before then a total would give the hidden faults away.
-- Costs are ADS's, at the price level of the day the contract was prepared.
function TCADSRepairContracts.getFarmPlan(vehicle, farmId)
    local quote = TCADSRepairContracts.getQuote(vehicle)
    local check = quote ~= nil and TCADSRepairContracts.checkFarmTools(vehicle, farmId) or nil
    local doneById = check ~= nil and getDoneById(vehicle) or nil
    if doneById == nil then
        return nil
    end
    local checkById = {}
    for _, item in ipairs(check.items or {}) do
        checkById[tostring(item.id)] = item
    end
    local breakdowns = getBreakdowns(vehicle)
    local result = { inspected = TCADSRepairContracts.isInspected(vehicle), faults = {} }
    for _, item in ipairs(quote.items or {}) do
        local done = doneById[tostring(item.id)] == true
        if item.kind == "fault" and isItemKnown(item, done, breakdowns, false) then
            local checked = checkById[tostring(item.id)] or {}
            table.insert(result.faults, {
                id = tostring(item.id),
                nameKey = item.nameKey,
                done = done,
                subcontractPrice = tonumber(checked.subcontractPrice or item.price) or 0,
                options = checked.options or {},
            })
        end
    end
    if result.inspected and type(check.plan) == "table" then
        result.plan = {
            canDo = check.plan.canDo ~= false,
            partsCost = tonumber(check.plan.partsCost) or 0,
            laborHours = tonumber(check.plan.laborHours) or 0,
            subcontractCost = tonumber(check.plan.subcontractCost) or 0,
        }
        result.missing = check.missing or {}
        -- What a full repair (no replacing where a repair's allowed) still
        -- needs: every unfixed fault's repair option the farm can't do.
        local needs, seen = {}, {}
        for _, fault in ipairs(result.faults) do
            if not fault.done then
                for _, option in ipairs(fault.options) do
                    if option.operation == "repair" and not option.canDo then
                        for _, toolId in ipairs(option.missing or {}) do
                            if not seen[toolId] then
                                seen[toolId] = true
                                table.insert(needs, toolId)
                            end
                        end
                    end
                end
            end
        end
        result.repairNeeds = needs
    end
    return result
end

-- 102: one found fault as a checklist, a row per way to fix it, always
-- repair then replace: { operation, status, tools, missing, partsCost,
-- laborHours }. status is "available" (the farm can do it at one of its
-- places), "missing" (it lacks the kit: missing) or "notPossible" (ADS
-- doesn't allow it on this fault: too far gone, or a part that can't be
-- repaired).
TCADSRepairContracts.FIX_OPERATIONS = { "repair", "replacement" }

function TCADSRepairContracts.getFaultChecklist(fault)
    local byOperation = {}
    for _, option in ipairs(fault.options or {}) do
        byOperation[option.operation] = option
    end
    local rows = {}
    for _, operation in ipairs(TCADSRepairContracts.FIX_OPERATIONS) do
        local option = byOperation[operation]
        if option == nil then
            table.insert(rows, { operation = operation, status = "notPossible", tools = {}, missing = {} })
        else
            table.insert(rows, {
                operation = operation,
                status = option.canDo and "available" or "missing",
                tools = option.tools or {},
                missing = option.canDo and {} or (option.missing or {}),
                place = option.place,
                partsCost = tonumber(option.partsCost) or 0,
                laborHours = tonumber(option.laborHours) or 0,
            })
        end
    end
    return rows
end

-- 102: tool ids as the own workshop upgrades that bring them ("Machine
-- tools, Overhead crane"), from ADS's own workshop config, in ADS's words;
-- a tool no upgrade brings (the jack: the tool box has it) by its own name.
-- One name per upgrade, however many of its tools are asked for.
function TCADSRepairContracts.getUpgradeNames(toolIds)
    return table.concat(TCADSRepairContracts.getUpgradeNameList(toolIds), ", ")
end

-- The same names as a list, one per upgrade (a chip each).
function TCADSRepairContracts.getUpgradeNameList(toolIds)
    local env = TCADSRepairContracts.getEnv()
    local ownWorkshop = env ~= nil and env.ADS_OwnWorkshop or nil
    local upgradeByTool = {}
    if ownWorkshop ~= nil and type(ownWorkshop.getEquipmentIds) == "function" and
            type(ownWorkshop.getEquipmentConfig) == "function" then
        for _, equipmentId in ipairs(ownWorkshop.getEquipmentIds() or {}) do
            local config = ownWorkshop.getEquipmentConfig(equipmentId) or {}
            for _, toolId in ipairs(config.TOOLS or {}) do
                upgradeByTool[toolId] = upgradeByTool[toolId] or equipmentId
            end
        end
    end
    local names, seen = {}, {}
    local modName = TCADSRepairContracts.MOD_NAME
    for _, toolId in ipairs(toolIds or {}) do
        local equipmentId = upgradeByTool[toolId]
        local key = equipmentId ~= nil and "ads_own_equipment_" .. equipmentId or "ads_ws_tool_" .. tostring(toolId)
        if not seen[key] then
            seen[key] = true
            local name = tostring(equipmentId or toolId)
            if g_i18n.hasText ~= nil and g_i18n:hasText(key, modName) then
                name = g_i18n:getText(key, modName)
            end
            -- ADS writes them in lower case, for the middle of its sentences.
            table.insert(names, (name:gsub("^%l", string.upper)))
        end
    end
    return names
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

-- ADS's list price of a new OEM part for one of the vehicle's components,
-- or nil if ADS can't say. Values what a tampered vehicle lost. Vanilla:
-- FS25_EconomyScale scales the parts shop's price on top of this, never this
-- function, so the caller applies the factor.
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
