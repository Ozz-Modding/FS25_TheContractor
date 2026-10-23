-- Vehicle condition snapshots (060), for the Logbook. A snapshot records
-- the damage model it was taken under, and the Logbook shows each one in
-- its own terms, so a vehicle FS25_AdvancedDamageSystem (ADS) excludes, or
-- a save that gained ADS halfway through, still reads correctly:
--
--   vanilla  damage (0-1), paint wear (0-1), repair price
--   ads      what the player knows (099): the last inspection's condition
--            (knownCondition, 0-1, nil if never inspected, with
--            conditionExact after a complete inspection and conditionStale
--            once the vehicle has run a while since), paint wear (ADS
--            leaves vanilla's paint wear alone), and the faults found
--            (isVisible) at the time, as { id }. ADS's live condition and
--            undiscovered faults are its hidden state, revealed only by an
--            inspection or a symptom, so they're never recorded here. Our
--            own maths (job quality, road accidents) reads them live.
--
-- Both also note the vehicle's operating hours, which is how long a
-- machine actually ran between two snapshots.
--
-- ADS zeroes vanilla damage on the vehicles it manages, so a vehicle is
-- only snapshotted as vanilla when ADS isn't managing it. Detected by the
-- vehicle's own functions, like TCJobConsequences.canBreakDown, not the mod
-- name.
--
-- Snapshots are plain values, so they're streamed and saved as they are.
-- The Logbook takes them on the server; the Logbook tab takes one of a
-- vehicle as it is now on any machine (ADS streams its breakdowns, with
-- isVisible, and its inspection log to clients).

TCVehicleCondition = {}

TCVehicleCondition.ADS_MOD_NAME = "FS25_AdvancedDamageSystem"

TCVehicleCondition.MODEL = {
    VANILLA = 0,
    ADS = 1,
}

function TCVehicleCondition.isManagedByADS(vehicle)
    return vehicle.spec_AdvancedDamageSystem ~= nil and vehicle.getConditionLevel ~= nil and
        (vehicle.getIsADSExcluded == nil or not vehicle:getIsADSExcluded())
end

local function sortFaults(faults)
    table.sort(faults, function(a, b)
        return a.id < b.id
    end)
end

-- nil for a vehicle with no wear model at all.
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
        if vehicle.getLastInspectedCondition ~= nil then
            local value, isExact, isStale = vehicle:getLastInspectedCondition()
            snapshot.knownCondition = tonumber(value)
            snapshot.conditionExact = snapshot.knownCondition ~= nil and isExact == true
            snapshot.conditionStale = snapshot.knownCondition ~= nil and isStale == true
        end
        snapshot.faults = {}
        local breakdowns = vehicle.getActiveBreakdowns ~= nil and vehicle:getActiveBreakdowns() or nil
        for id, breakdown in pairs(breakdowns or {}) do
            if type(breakdown) == "table" and breakdown.isVisible == true then
                table.insert(snapshot.faults, { id = tostring(id) })
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

local function hasFault(snapshot, id)
    for _, fault in ipairs(snapshot.faults or {}) do
        if fault.id == id then
            return true
        end
    end
    return false
end

-- Faults found in `after` that weren't known in `before`: { { id } }. One
-- found during a use may have been there, undiscovered, before it.
function TCVehicleCondition.getNewFaults(before, after)
    local result = {}
    if after == nil or after.model ~= TCVehicleCondition.MODEL.ADS then
        return result
    end
    for _, fault in ipairs(after.faults or {}) do
        if before == nil or before.model ~= after.model or not hasFault(before, fault.id) then
            table.insert(result, { id = fault.id })
        end
    end
    return result
end

-- ADS's own global environment (mods' globals live in their own, see
-- TheContractorDrivers.getModEnv). Looked up once a session; false once
-- known to be missing.
local adsEnv = nil
local function getADSEnv()
    if adsEnv == nil then
        adsEnv = TheContractorDrivers.getModEnv(TCVehicleCondition.ADS_MOD_NAME) or false
    end
    return adsEnv or nil
end

-- Server-only, with the vehicle still there: what the change from `before`
-- to `after` costs to put right, estimated. Vanilla: the rise in repair
-- price. Never negative - a repair in between doesn't make money. 0 when
-- the two snapshots used different models.
function TCVehicleCondition.getWearCost(vehicle, before, after)
    if vehicle == nil or before == nil or after == nil or before.model ~= after.model then
        return 0
    end

    if after.model == TCVehicleCondition.MODEL.VANILLA then
        return math.max(0, (after.repairPrice or 0) - (before.repairPrice or 0))
    end

    -- TODO (099): ADS no longer has getBreakdownRepairPrice; its author
    -- plans a repair cost function. When it comes, price only the faults
    -- found (getNewFaults), never hidden ones, or the cost gives them away.
    return 0
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

-- ADS's own name for a fault (the component it's in, as ADS's maintenance
-- log names it), or a tidied-up id when ADS isn't loaded on this machine.
function TCVehicleCondition.getFaultName(id)
    local env = getADSEnv()
    local performance = env ~= nil and env.ADS_VehiclePerformance or nil
    local components = env ~= nil and env.ADS_Components or nil
    local entry = performance ~= nil and performance.ConditionRegistry ~= nil and
        performance.ConditionRegistry[id] or nil
    local component = entry ~= nil and entry.componentId ~= nil and components ~= nil and
        components.getComponentDefinition ~= nil and components.getComponentDefinition(entry.componentId) or nil
    local key = component ~= nil and component.name or nil
    local text = type(key) == "string" and getOtherModText(key) or nil
    if text ~= nil then
        return text
    end
    local name = string.lower((string.gsub(tostring(id), "_", " ")))
    return (string.gsub(name, "^%l", string.upper))
end

-- The condition the player knows, as ADS's own workshop shows it
-- (ADS_Utils.formatCondition): a percentage after a complete inspection,
-- else a word ("Good"), or "Unknown" if it's never been inspected, marked
-- outdated once the vehicle has run a while since (unless noOutdated).
-- Without ADS on this machine: the percentage after a complete inspection,
-- else "Unknown".
function TCVehicleCondition.formatKnownCondition(snapshot, noOutdated)
    local env = getADSEnv()
    local utils = env ~= nil and env.ADS_Utils or nil
    local text
    if utils ~= nil and utils.formatCondition ~= nil then
        text = utils.formatCondition(snapshot.knownCondition, snapshot.conditionExact == true)
    elseif snapshot.knownCondition ~= nil and snapshot.conditionExact then
        text = percent(snapshot.knownCondition)
    else
        text = g_i18n:getText("tc_logbook_unknown")
    end
    if snapshot.knownCondition ~= nil and snapshot.conditionStale and not noOutdated then
        text = string.format(g_i18n:getText("tc_logbook_conditionOutdated"), text)
    end
    return text
end

-- The headline figure for a list chip or summary: damage for vanilla,
-- the known condition for ADS, as ADS words it ("Normal") and without the
-- outdated mark, to fit a chip.
function TCVehicleCondition.getHeadline(snapshot)
    if snapshot == nil then
        return nil
    end
    if snapshot.model == TCVehicleCondition.MODEL.ADS then
        return TCVehicleCondition.formatKnownCondition(snapshot, true)
    end
    return string.format(g_i18n:getText("tc_logbook_damageShort"), percent(snapshot.damage))
end

-- Label/value rows comparing two snapshots ("Damage 12% -> 19%"), in the
-- model `after` (or `before`, if there's no after) was taken under. Either
-- may be nil, shown as "-". ADS's known condition only changes with an
-- inspection, so it's one value unless there was one in between.
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
        local function known(snapshot)
            return snapshot ~= nil and snapshot.model == reference.model and
                TCVehicleCondition.formatKnownCondition(snapshot) or "-"
        end
        local from, to = known(before), known(after)
        table.insert(rows, { label = g_i18n:getText("tc_logbook_condition"),
            value = from == to and to or string.format(g_i18n:getText("tc_logbook_change"), from, to) })
    else
        table.insert(rows, { label = g_i18n:getText("tc_logbook_damage"), value = change("damage") })
    end
    table.insert(rows, { label = g_i18n:getText("tc_logbook_paint"), value = change("wear") })

    for _, fault in ipairs(TCVehicleCondition.getNewFaults(before, after)) do
        table.insert(rows, { label = g_i18n:getText("tc_logbook_newFault"),
            value = TCVehicleCondition.getFaultName(fault.id), tone = "bad" })
    end
    return rows
end

-- How much worse a vehicle got between two snapshots, as fractions:
-- vanilla damage and paint wear. Either is nil when there's nothing to
-- compare (a missing snapshot, or the two taken under different models),
-- and damage always is for ADS, whose condition the player only knows from
-- inspections. A repair in between can make them negative.
function TCVehicleCondition.getDeltas(before, after)
    if before == nil or after == nil or before.model ~= after.model then
        return nil, nil
    end
    local damage = nil
    if after.model == TCVehicleCondition.MODEL.VANILLA then
        damage = (after.damage or 0) - (before.damage or 0)
    end
    return damage, (after.wear or 0) - (before.wear or 0)
end

-- The names of the faults found, for an ADS snapshot; nil for vanilla.
function TCVehicleCondition.getKnownFaultNames(snapshot)
    if snapshot == nil or snapshot.model ~= TCVehicleCondition.MODEL.ADS then
        return nil
    end
    local names = {}
    for _, fault in ipairs(snapshot.faults or {}) do
        table.insert(names, TCVehicleCondition.getFaultName(fault.id))
    end
    return names
end

-- Label/value rows for one snapshot on its own (a vehicle as it is now).
-- ADS's known faults aren't here: getKnownFaultNames lists them.
function TCVehicleCondition.getStateRows(snapshot)
    if snapshot == nil then
        return {}
    end
    local rows = {}
    if snapshot.model == TCVehicleCondition.MODEL.ADS then
        table.insert(rows, { label = g_i18n:getText("tc_logbook_condition"),
            value = TCVehicleCondition.formatKnownCondition(snapshot) })
    else
        table.insert(rows, { label = g_i18n:getText("tc_logbook_damage"), value = percent(snapshot.damage) })
    end
    table.insert(rows, { label = g_i18n:getText("tc_logbook_paint"), value = percent(snapshot.wear) })
    return rows
end

-- "good"/"warn"/"bad" for a vehicle's condition chip: by damage for
-- vanilla; for ADS, bad with any fault found, else by the known condition
-- (neutral if it's never been inspected).
function TCVehicleCondition.getTone(snapshot)
    if snapshot == nil then
        return "neutral"
    end
    local health
    if snapshot.model == TCVehicleCondition.MODEL.ADS then
        if #(snapshot.faults or {}) > 0 then
            return "bad"
        end
        if snapshot.knownCondition == nil then
            return "neutral"
        end
        health = snapshot.knownCondition
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
        streamWriteBool(streamId, snapshot.knownCondition ~= nil)
        if snapshot.knownCondition ~= nil then
            streamWriteFloat32(streamId, snapshot.knownCondition)
            streamWriteBool(streamId, snapshot.conditionExact == true)
            streamWriteBool(streamId, snapshot.conditionStale == true)
        end
        local faults = snapshot.faults or {}
        streamWriteUInt8(streamId, math.min(#faults, 255))
        for i = 1, math.min(#faults, 255) do
            streamWriteString(streamId, faults[i].id)
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
        if streamReadBool(streamId) then
            snapshot.knownCondition = streamReadFloat32(streamId)
            snapshot.conditionExact = streamReadBool(streamId)
            snapshot.conditionStale = streamReadBool(streamId)
        end
        snapshot.faults = {}
        for _ = 1, streamReadUInt8(streamId) do
            table.insert(snapshot.faults, { id = streamReadString(streamId) })
        end
    else
        snapshot.damage = streamReadFloat32(streamId)
        snapshot.repairPrice = streamReadFloat32(streamId)
    end
    return snapshot
end

-- Save ------------------------------------------------------------------------

-- Faults found are saved as "ID;ID". Snapshots from before 099 held ADS's
-- live condition (#condition) and every fault, hidden ones too (#faults,
-- "ID:stage"). Those are ignored, so they read as never inspected with no
-- faults found.
function TCVehicleCondition.saveToXML(xmlFile, key, snapshot)
    if snapshot == nil then
        return
    end
    setXMLInt(xmlFile, key .. "#model", snapshot.model)
    setXMLFloat(xmlFile, key .. "#wear", snapshot.wear or 0)
    setXMLFloat(xmlFile, key .. "#hours", snapshot.hours or 0)
    if snapshot.model == TCVehicleCondition.MODEL.ADS then
        if snapshot.knownCondition ~= nil then
            setXMLFloat(xmlFile, key .. "#knownCondition", snapshot.knownCondition)
            setXMLBool(xmlFile, key .. "#conditionExact", snapshot.conditionExact == true)
            setXMLBool(xmlFile, key .. "#conditionStale", snapshot.conditionStale == true)
        end
        local ids = {}
        for _, fault in ipairs(snapshot.faults or {}) do
            table.insert(ids, fault.id)
        end
        setXMLString(xmlFile, key .. "#knownFaults", table.concat(ids, ";"))
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
        snapshot.knownCondition = getXMLFloat(xmlFile, key .. "#knownCondition")
        snapshot.conditionExact = snapshot.knownCondition ~= nil and
            Utils.getNoNil(getXMLBool(xmlFile, key .. "#conditionExact"), false)
        snapshot.conditionStale = snapshot.knownCondition ~= nil and
            Utils.getNoNil(getXMLBool(xmlFile, key .. "#conditionStale"), false)
        snapshot.faults = {}
        for id in string.gmatch(getXMLString(xmlFile, key .. "#knownFaults") or "", "([^;]+)") do
            table.insert(snapshot.faults, { id = id })
        end
        sortFaults(snapshot.faults)
    else
        snapshot.damage = Utils.getNoNil(getXMLFloat(xmlFile, key .. "#damage"), 0)
        snapshot.repairPrice = Utils.getNoNil(getXMLFloat(xmlFile, key .. "#repairPrice"), 0)
    end
    return snapshot
end
