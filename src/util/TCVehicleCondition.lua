-- Vehicle condition snapshots (060), for the Logbook. A snapshot records
-- the damage model it was taken under, and the Logbook shows each one in
-- its own terms, so a vehicle FS25_AdvancedDamageSystem (ADS) excludes, or
-- a save that gained ADS halfway through, still reads correctly:
--
--   vanilla  damage (0-1), paint wear (0-1), repair price
--   ads      condition and service (0-1, ADS's own levels), paint wear
--            (ADS leaves vanilla's paint wear alone), and the faults
--            active at the time as { id, stage }
--
-- Both also note the vehicle's operating hours, which is how long a
-- machine actually ran between two snapshots.
--
-- ADS zeroes vanilla damage on the vehicles it manages, so a vehicle is
-- only snapshotted as vanilla when ADS isn't managing it. Detected by the
-- vehicle's own functions, like TCJobConsequences.canBreakDown, not the mod
-- name.
--
-- Snapshots are taken on the server and are plain values, so they're
-- streamed and saved as they are.

TCVehicleCondition = {}

TCVehicleCondition.MODEL = {
    VANILLA = 0,
    ADS = 1,
}

function TCVehicleCondition.isManagedByADS(vehicle)
    return vehicle.spec_AdvancedDamageSystem ~= nil and vehicle.getConditionLevel ~= nil and
        vehicle.getServiceLevel ~= nil and (vehicle.getIsADSExcluded == nil or not vehicle:getIsADSExcluded())
end

local function sortFaults(faults)
    table.sort(faults, function(a, b)
        return a.id < b.id
    end)
end

-- Server-only. nil for a vehicle with no wear model at all.
function TCVehicleCondition.capture(vehicle)
    if vehicle == nil or vehicle.spec_wearable == nil then
        return nil
    end

    local snapshot = {
        wear = vehicle:getWearTotalAmount() or 0,
        hours = (vehicle.getOperatingTime ~= nil and vehicle:getOperatingTime() or 0) / 3600000,
    }

    if TCVehicleCondition.isManagedByADS(vehicle) then
        snapshot.model = TCVehicleCondition.MODEL.ADS
        snapshot.condition = vehicle:getConditionLevel() or 1
        snapshot.service = vehicle:getServiceLevel() or 1
        snapshot.faults = {}
        local breakdowns = vehicle.getActiveBreakdowns ~= nil and vehicle:getActiveBreakdowns() or nil
        for id, breakdown in pairs(breakdowns or {}) do
            if type(breakdown) == "table" and breakdown.isActive ~= false then
                table.insert(snapshot.faults, { id = tostring(id), stage = breakdown.stage or 1 })
            end
        end
        sortFaults(snapshot.faults)
    else
        snapshot.model = TCVehicleCondition.MODEL.VANILLA
        snapshot.damage = vehicle:getDamageAmount() or 0
        snapshot.repairPrice = vehicle.getRepairPrice ~= nil and vehicle:getRepairPrice() or 0
    end

    return snapshot
end

-- A fault's stage in a snapshot, or nil if it wasn't there.
local function getFaultStage(snapshot, id)
    for _, fault in ipairs(snapshot.faults or {}) do
        if fault.id == id then
            return fault.stage
        end
    end
    return nil
end

-- Faults in `after` that are new, or have got worse, since `before`:
-- { { id, stage, previousStage (nil if new) } }.
function TCVehicleCondition.getNewFaults(before, after)
    local result = {}
    if after == nil or after.model ~= TCVehicleCondition.MODEL.ADS then
        return result
    end
    for _, fault in ipairs(after.faults or {}) do
        local previousStage = before ~= nil and getFaultStage(before, fault.id) or nil
        if previousStage == nil or fault.stage > previousStage then
            table.insert(result, { id = fault.id, stage = fault.stage, previousStage = previousStage })
        end
    end
    return result
end

-- ADS's own global environment (mods' globals live in their own, see
-- TheContractorDrivers.getModEnv), found by what's in it rather than the
-- folder name. Looked up once a session; false once known to be missing.
local adsEnv = nil
local function getADSEnv()
    if adsEnv == nil then
        adsEnv = false
        for modName, isLoaded in pairs(g_modIsLoaded or {}) do
            local env = isLoaded and getfenv(0)[modName] or nil
            if type(env) == "table" and env.ADS_Breakdowns ~= nil then
                adsEnv = env
                break
            end
        end
    end
    return adsEnv or nil
end

local function getADSRepairPrice(vehicle, id, stage)
    if vehicle.getBreakdownRepairPrice == nil then
        return 0
    end
    local env = getADSEnv()
    local partType = env ~= nil and env.AdvancedDamageSystem ~= nil and env.AdvancedDamageSystem.PART_TYPES ~= nil and
        env.AdvancedDamageSystem.PART_TYPES.OEM or nil
    local ok, price = pcall(vehicle.getBreakdownRepairPrice, vehicle, id, stage, partType)
    return ok and tonumber(price) or 0
end

-- Server-only, with the vehicle still there: what the change from `before`
-- to `after` costs to put right, estimated. Vanilla: the rise in repair
-- price. ADS: the repair price of each new fault (or of the step up, for
-- one that got worse). Never negative - a repair in between doesn't make
-- money. 0 when the two snapshots used different models.
function TCVehicleCondition.getWearCost(vehicle, before, after)
    if vehicle == nil or before == nil or after == nil or before.model ~= after.model then
        return 0
    end

    if after.model == TCVehicleCondition.MODEL.VANILLA then
        return math.max(0, (after.repairPrice or 0) - (before.repairPrice or 0))
    end

    local cost = 0
    for _, fault in ipairs(TCVehicleCondition.getNewFaults(before, after)) do
        local price = getADSRepairPrice(vehicle, fault.id, fault.stage)
        if fault.previousStage ~= nil then
            price = price - getADSRepairPrice(vehicle, fault.id, fault.previousStage)
        end
        cost = cost + math.max(0, price)
    end
    return cost
end

-- Display ---------------------------------------------------------------------

local function percent(value)
    return string.format("%d%%", math.floor((value or 0) * 100 + 0.5))
end

-- A text from another mod's l10n. Each mod's texts live in its own I18N
-- environment, so ours can't see ADS's directly; this finds whichever
-- environment has the key, whatever ADS's folder is called.
local function getOtherModText(key)
    for _, env in pairs(g_i18n.modEnvironments or {}) do
        local text = env.texts ~= nil and rawget(env.texts, key) or nil
        if text ~= nil then
            return text
        end
    end
    return nil
end

-- ADS's own name for a fault (the part or system it's in), or a tidied-up
-- id when ADS isn't loaded on this machine.
function TCVehicleCondition.getFaultName(id)
    local env = getADSEnv()
    local registry = env ~= nil and env.ADS_Breakdowns.BreakdownRegistry or nil
    local entry = registry ~= nil and registry[id] or nil
    local key = entry ~= nil and (entry.part or entry.system) or nil
    local text = type(key) == "string" and getOtherModText(key) or nil
    if text ~= nil then
        return text
    end
    local name = string.lower((string.gsub(tostring(id), "_", " ")))
    return (string.gsub(name, "^%l", string.upper))
end

-- "Hydraulics (stage 2)".
function TCVehicleCondition.formatFault(fault)
    return string.format(g_i18n:getText("tc_logbook_faultStage"), TCVehicleCondition.getFaultName(fault.id),
        fault.stage)
end

-- The headline figure for a list chip or summary: damage for vanilla,
-- condition for ADS.
function TCVehicleCondition.getHeadline(snapshot)
    if snapshot == nil then
        return nil
    end
    if snapshot.model == TCVehicleCondition.MODEL.ADS then
        return string.format(g_i18n:getText("tc_logbook_conditionShort"), percent(snapshot.condition))
    end
    return string.format(g_i18n:getText("tc_logbook_damageShort"), percent(snapshot.damage))
end

-- Label/value rows comparing two snapshots ("Damage 12% -> 19%"), in the
-- model `after` (or `before`, if there's no after) was taken under. Either
-- may be nil, shown as "-".
function TCVehicleCondition.getChangeRows(before, after)
    local reference = after or before
    if reference == nil then
        return {}
    end

    local function change(field)
        local from = before ~= nil and before.model == reference.model and percent(before[field]) or "-"
        local to = after ~= nil and percent(after[field]) or "-"
        return string.format(g_i18n:getText("tc_logbook_change"), from, to)
    end

    local rows = {}
    if reference.model == TCVehicleCondition.MODEL.ADS then
        table.insert(rows, { label = g_i18n:getText("tc_logbook_condition"), value = change("condition") })
        table.insert(rows, { label = g_i18n:getText("tc_logbook_service"), value = change("service") })
    else
        table.insert(rows, { label = g_i18n:getText("tc_logbook_damage"), value = change("damage") })
    end
    table.insert(rows, { label = g_i18n:getText("tc_logbook_paint"), value = change("wear") })

    for _, fault in ipairs(TCVehicleCondition.getNewFaults(before, after)) do
        table.insert(rows, { label = g_i18n:getText(fault.previousStage == nil and "tc_logbook_newFault" or
            "tc_logbook_worseFault"), value = TCVehicleCondition.formatFault(fault), tone = "bad" })
    end
    return rows
end

-- Label/value rows for one snapshot on its own (a vehicle as it is now),
-- with every active fault listed for ADS.
function TCVehicleCondition.getStateRows(snapshot)
    if snapshot == nil then
        return {}
    end
    local rows = {}
    if snapshot.model == TCVehicleCondition.MODEL.ADS then
        table.insert(rows, { label = g_i18n:getText("tc_logbook_condition"), value = percent(snapshot.condition) })
        table.insert(rows, { label = g_i18n:getText("tc_logbook_service"), value = percent(snapshot.service) })
    else
        table.insert(rows, { label = g_i18n:getText("tc_logbook_damage"), value = percent(snapshot.damage) })
    end
    table.insert(rows, { label = g_i18n:getText("tc_logbook_paint"), value = percent(snapshot.wear) })
    if snapshot.model == TCVehicleCondition.MODEL.ADS then
        local faults = {}
        for _, fault in ipairs(snapshot.faults or {}) do
            table.insert(faults, TCVehicleCondition.formatFault(fault))
        end
        table.insert(rows, { label = g_i18n:getText("tc_logbook_activeFaults"),
            value = #faults > 0 and table.concat(faults, ", ") or g_i18n:getText("tc_logbook_none"),
            tone = #faults > 0 and "bad" or nil })
    end
    return rows
end

-- "good"/"warn"/"bad" for a vehicle's condition chip: by damage for
-- vanilla, by condition for ADS, and bad with any ADS fault active.
function TCVehicleCondition.getTone(snapshot)
    if snapshot == nil then
        return "neutral"
    end
    local health
    if snapshot.model == TCVehicleCondition.MODEL.ADS then
        if #(snapshot.faults or {}) > 0 then
            return "bad"
        end
        health = snapshot.condition or 1
    else
        health = 1 - (snapshot.damage or 0)
    end
    if health >= 0.7 then
        return "good"
    elseif health >= 0.4 then
        return "warn"
    end
    return "bad"
end

-- Operating hours between two snapshots, or nil if either's missing.
function TCVehicleCondition.getHoursBetween(before, after)
    if before == nil or after == nil then
        return nil
    end
    return math.max(0, (after.hours or 0) - (before.hours or 0))
end

-- Network ---------------------------------------------------------------------

function TCVehicleCondition.writeStream(streamId, snapshot)
    streamWriteBool(streamId, snapshot ~= nil)
    if snapshot == nil then
        return
    end
    streamWriteUInt8(streamId, snapshot.model)
    streamWriteFloat32(streamId, snapshot.wear or 0)
    streamWriteFloat32(streamId, snapshot.hours or 0)
    if snapshot.model == TCVehicleCondition.MODEL.ADS then
        streamWriteFloat32(streamId, snapshot.condition or 1)
        streamWriteFloat32(streamId, snapshot.service or 1)
        local faults = snapshot.faults or {}
        streamWriteUInt8(streamId, math.min(#faults, 255))
        for i = 1, math.min(#faults, 255) do
            streamWriteString(streamId, faults[i].id)
            streamWriteUInt8(streamId, math.min(faults[i].stage, 255))
        end
    else
        streamWriteFloat32(streamId, snapshot.damage or 0)
        streamWriteFloat32(streamId, snapshot.repairPrice or 0)
    end
end

function TCVehicleCondition.readStream(streamId)
    if not streamReadBool(streamId) then
        return nil
    end
    local snapshot = {
        model = streamReadUInt8(streamId),
        wear = streamReadFloat32(streamId),
        hours = streamReadFloat32(streamId),
    }
    if snapshot.model == TCVehicleCondition.MODEL.ADS then
        snapshot.condition = streamReadFloat32(streamId)
        snapshot.service = streamReadFloat32(streamId)
        snapshot.faults = {}
        for _ = 1, streamReadUInt8(streamId) do
            table.insert(snapshot.faults, { id = streamReadString(streamId), stage = streamReadUInt8(streamId) })
        end
    else
        snapshot.damage = streamReadFloat32(streamId)
        snapshot.repairPrice = streamReadFloat32(streamId)
    end
    return snapshot
end

-- Save ------------------------------------------------------------------------

-- Faults are saved as "ID:stage;ID:stage".
function TCVehicleCondition.saveToXML(xmlFile, key, snapshot)
    if snapshot == nil then
        return
    end
    setXMLInt(xmlFile, key .. "#model", snapshot.model)
    setXMLFloat(xmlFile, key .. "#wear", snapshot.wear or 0)
    setXMLFloat(xmlFile, key .. "#hours", snapshot.hours or 0)
    if snapshot.model == TCVehicleCondition.MODEL.ADS then
        setXMLFloat(xmlFile, key .. "#condition", snapshot.condition or 1)
        setXMLFloat(xmlFile, key .. "#service", snapshot.service or 1)
        local parts = {}
        for _, fault in ipairs(snapshot.faults or {}) do
            table.insert(parts, string.format("%s:%d", fault.id, fault.stage))
        end
        setXMLString(xmlFile, key .. "#faults", table.concat(parts, ";"))
    else
        setXMLFloat(xmlFile, key .. "#damage", snapshot.damage or 0)
        setXMLFloat(xmlFile, key .. "#repairPrice", snapshot.repairPrice or 0)
    end
end

function TCVehicleCondition.loadFromXML(xmlFile, key)
    local model = getXMLInt(xmlFile, key .. "#model")
    if model == nil then
        return nil
    end
    local snapshot = {
        model = model,
        wear = Utils.getNoNil(getXMLFloat(xmlFile, key .. "#wear"), 0),
        hours = Utils.getNoNil(getXMLFloat(xmlFile, key .. "#hours"), 0),
    }
    if model == TCVehicleCondition.MODEL.ADS then
        snapshot.condition = Utils.getNoNil(getXMLFloat(xmlFile, key .. "#condition"), 1)
        snapshot.service = Utils.getNoNil(getXMLFloat(xmlFile, key .. "#service"), 1)
        snapshot.faults = {}
        for part in string.gmatch(getXMLString(xmlFile, key .. "#faults") or "", "([^;]+)") do
            local id, stage = string.match(part, "^(.+):(%d+)$")
            if id ~= nil then
                table.insert(snapshot.faults, { id = id, stage = tonumber(stage) })
            end
        end
        sortFaults(snapshot.faults)
    else
        snapshot.damage = Utils.getNoNil(getXMLFloat(xmlFile, key .. "#damage"), 0)
        snapshot.repairPrice = Utils.getNoNil(getXMLFloat(xmlFile, key .. "#repairPrice"), 0)
    end
    return snapshot
end
