-- Mod settings (048), shown in the vanilla in-game Settings page under a
-- "The Contractor" header (see TCSettingsMenu). Server-wide, one value per
-- savegame - not farm-scoped, unlike the rest of the mod.
--
-- Adding a setting: a DEFINITIONS entry (values + display strings, or
-- stringKeys for l10n keys, + default index), its id in ITEMS, and tc_setting_<id>/tc_toolTip_<id> l10n keys.
-- Save/load, MP sync and the menu control all follow from ITEMS. Values are
-- numbers or booleans.
--
-- Only the server/host or an admin (master user) can change them, as with
-- RedTape's server settings; the server re-checks it (TCSettingsEvent).
-- The exception is LOCAL_ITEMS (086): each machine's own display
-- preferences, kept in modSettings and never synced.

TheContractorSettings = {}
TheContractorSettings_mt = Class(TheContractorSettings)

-- min..max in step-sized percent options, and the index of defaultValue.
local function percentOptions(min, max, step, defaultValue)
    local values, strings, defaultIndex = {}, {}, 1
    for value = min, max, step do
        table.insert(values, value)
        table.insert(strings, string.format("%d%%", value))
        if value == defaultValue then
            defaultIndex = #values
        end
    end
    return values, strings, defaultIndex
end

TheContractorSettings.DEFINITIONS = {}

-- 048: scales every new job offer's price. 100% is
-- TheContractorJobGeneration.JOB_PAY_BASELINE of vanilla's mission pay.
do
    local values, strings, defaultIndex = percentOptions(50, 500, 25, 100)
    TheContractorSettings.DEFINITIONS.jobPayRate = {
        values = values,
        strings = strings,
        default = defaultIndex
    }
end

-- 049: off pays every job in full on completion (the pre-049 behaviour)
-- instead of invoicing it. Invoices already issued still run their course.
TheContractorSettings.DEFINITIONS.lateInvoices = {
    values = { true, false },
    strings = { g_i18n:getText("ui_on"), g_i18n:getText("ui_off") },
    default = 1
}

-- 068: how often random events (theft and the like) happen, as a
-- multiplier on every event type's monthly rate. Its display strings are
-- the mod's own l10n keys (stringKeys), looked up when the menu is built.
TheContractorSettings.DEFINITIONS.randomEvents = {
    values = { 0, 0.5, 1 },
    stringKeys = { "tc_setting_randomEvents_off", "tc_setting_randomEvents_rare", "tc_setting_randomEvents_normal" },
    default = 3
}

-- Where new workers' and administrators' names come from (TCNames): one
-- style, or a mix. Saved as the option's number, so a new style goes on the
-- end of NAME_STYLES. Names already given never change.
TheContractorSettings.NAME_STYLES = {
    "british", "irish", "american", "french", "german", "dutch", "scandinavian", "spanish", "italian", "polish",
    "european", "all",
}
do
    local values, stringKeys = {}, {}
    for i, key in ipairs(TheContractorSettings.NAME_STYLES) do
        values[i] = i
        stringKeys[i] = "tc_nameStyle_" .. key
    end
    TheContractorSettings.DEFINITIONS.nameStyle = {
        values = values,
        stringKeys = stringKeys,
        default = 1
    }
end

-- 100/102: the benchmark margin over a repair contract's cost (the cheapest
-- fix's parts and labour): one for jobs in a repair zone, one for 101's
-- field breakdowns. The Negotiate dialog starts there, and reputation is
-- judged against it (TheContractorRepairContracts.getMarginFactor).
-- isShown keeps them off the menu without ADS; they're still
-- saved and synced like the rest. They replaced 100's adsMargin (a margin
-- over the whole quote, labour included), so an old save's value is ignored.
local function adsMarginDefinition(defaultValue)
    local values, strings, defaultIndex = percentOptions(0, 150, 5, defaultValue)
    return {
        values = values,
        strings = strings,
        default = defaultIndex,
        isShown = function()
            return TCADSRepairContracts.isActive()
        end
    }
end
TheContractorSettings.DEFINITIONS.adsWorkshopMargin = adsMarginDefinition(40)
TheContractorSettings.DEFINITIONS.adsFieldMargin = adsMarginDefinition(50)

-- 128: whether farmers retire and hand their farm to a successor on their
-- own (TheContractorFarmerLandChanges). Off by default: players curate
-- their farmers (111, 122). The console can retire one either way.
TheContractorSettings.DEFINITIONS.farmerRetirements = {
    values = { true, false },
    strings = { g_i18n:getText("ui_on"), g_i18n:getText("ui_off") },
    default = 2
}

TheContractorSettings.ITEMS = { "jobPayRate", "lateInvoices", "randomEvents", "nameStyle", "adsWorkshopMargin",
    "adsFieldMargin", "farmerRetirements" }

-- 086: whether parking slots show outside the construction menu too. A
-- display preference, so it's a local item (below). onChanged runs on this
-- machine whenever it changes.
TheContractorSettings.DEFINITIONS.showParkingSlots = {
    values = { true, false },
    strings = { g_i18n:getText("ui_on"), g_i18n:getText("ui_off") },
    default = 2,
    onChanged = function()
        TCParking.updateVisuals()
    end
}

-- Which jobs get a HUD progress bar (TCJobHud): those allocated to a
-- player, every allocated or started job, or none. A display preference,
-- so a local item. Saved as the option's number.
TheContractorSettings.JOB_PROGRESS_BARS = { PLAYER_ONLY = 1, ALL = 2, NONE = 3 }
TheContractorSettings.DEFINITIONS.jobProgressBars = {
    values = { 1, 2, 3 },
    stringKeys = { "tc_setting_jobProgressBars_player", "tc_setting_jobProgressBars_all",
        "tc_setting_jobProgressBars_none" },
    default = 1,
    onChanged = function()
        TCJobHud.refresh()
    end
}

-- Local items: one value per machine (each player's own), not per savegame.
-- Shown in the same menu section and changeable by anyone, never synced,
-- and kept in LOCAL_FILENAME in this machine's modSettings folder rather
-- than the savegame. Adding one: a DEFINITIONS entry, its id here and the
-- same two l10n keys.
TheContractorSettings.LOCAL_ITEMS = { "showParkingSlots", "jobProgressBars" }
TheContractorSettings.LOCAL_FILENAME = "localSettings.xml"
TheContractorSettings.LOCAL_SAVE_KEY = "TheContractorLocal"

-- modSettings/FS25_TheContractor/; g_currentModSettingsDirectory is only
-- set while the mod's scripts are sourced.
TheContractorSettings.localSettingsDir = g_currentModSettingsDirectory

function TheContractorSettings.new()
    local self = {}
    setmetatable(self, TheContractorSettings_mt)

    self.values = {}
    for _, id in ipairs(TheContractorSettings.ITEMS) do
        self.values[id] = TheContractorSettings.getDefaultValue(id)
    end
    for _, id in ipairs(TheContractorSettings.LOCAL_ITEMS) do
        self.values[id] = TheContractorSettings.getDefaultValue(id)
    end

    return self
end

function TheContractorSettings.isLocalItem(id)
    for _, localId in ipairs(TheContractorSettings.LOCAL_ITEMS) do
        if localId == id then
            return true
        end
    end
    return false
end

-- A local item's new value on this machine: kept, saved to the local file
-- and acted on (its onChanged).
function TheContractorSettings:setLocal(id, value)
    local definition = TheContractorSettings.DEFINITIONS[id]
    if definition == nil or not TheContractorSettings.isLocalItem(id) then
        return
    end
    self:set(id, value)
    self:saveLocalFile()
    if definition.onChanged ~= nil then
        definition.onChanged(self.values[id])
    end
end

function TheContractorSettings.getLocalFilename()
    local dir = TheContractorSettings.localSettingsDir
    return dir ~= nil and dir .. TheContractorSettings.LOCAL_FILENAME or nil
end

-- Every machine at loadMap (after TCCompanyLogo.createSettingsFolder has
-- made the folder).
function TheContractorSettings:loadLocalFile()
    local filename = TheContractorSettings.getLocalFilename()
    if filename == nil or not fileExists(filename) then
        return
    end
    local xmlFile = loadXMLFile(TheContractorSettings.LOCAL_SAVE_KEY, filename)
    if xmlFile == nil or xmlFile == 0 then
        return
    end
    for _, id in ipairs(TheContractorSettings.LOCAL_ITEMS) do
        local key = string.format("%s.%s#value", TheContractorSettings.LOCAL_SAVE_KEY, id)
        if hasXMLProperty(xmlFile, key) then
            if type(TheContractorSettings.getDefaultValue(id)) == "boolean" then
                self:set(id, getXMLBool(xmlFile, key))
            else
                self:set(id, getXMLFloat(xmlFile, key))
            end
        end
    end
    delete(xmlFile)
end

function TheContractorSettings:saveLocalFile()
    local filename = TheContractorSettings.getLocalFilename()
    if filename == nil then
        return
    end
    local xmlFile = createXMLFile(TheContractorSettings.LOCAL_SAVE_KEY, filename, TheContractorSettings.LOCAL_SAVE_KEY)
    if xmlFile == nil or xmlFile == 0 then
        return
    end
    for _, id in ipairs(TheContractorSettings.LOCAL_ITEMS) do
        local key = string.format("%s.%s#value", TheContractorSettings.LOCAL_SAVE_KEY, id)
        local value = self.values[id]
        if type(value) == "boolean" then
            setXMLBool(xmlFile, key, value)
        else
            setXMLFloat(xmlFile, key, value)
        end
    end
    saveXMLFile(xmlFile)
    delete(xmlFile)
end

function TheContractorSettings.getDefaultValue(id)
    local definition = TheContractorSettings.DEFINITIONS[id]
    return definition.values[definition.default]
end

-- The option index for a value: the exact match, or for numbers the
-- nearest one (an old save, or a retuned option list).
function TheContractorSettings.getValueIndex(id, value)
    local definition = TheContractorSettings.DEFINITIONS[id]
    if type(value) == "number" then
        local bestIndex, bestDiff = definition.default, math.huge
        for i, candidate in ipairs(definition.values) do
            local diff = math.abs(candidate - value)
            if diff < bestDiff then
                bestIndex, bestDiff = i, diff
            end
        end
        return bestIndex
    end
    for i, candidate in ipairs(definition.values) do
        if candidate == value then
            return i
        end
    end
    return definition.default
end

function TheContractorSettings:get(id)
    return self.values[id]
end

-- Local only - TCSettingsEvent does the syncing.
function TheContractorSettings:set(id, value)
    local definition = TheContractorSettings.DEFINITIONS[id]
    if definition == nil then
        return
    end
    self.values[id] = definition.values[TheContractorSettings.getValueIndex(id, value)]
end

-- The local player may change settings: the host, or an admin client.
function TheContractorSettings.getCanLocalPlayerChange()
    return g_currentMission:getIsServer() or g_currentMission.isMasterUser == true
end

-- A request from this connection may change settings (server side).
function TheContractorSettings.getCanConnectionChange(connection)
    return connection:getIsLocal() or g_currentMission.userManager:getIsConnectionMasterUser(connection)
end

-- The nameStyle setting's style or mix key, for TCNames.generate.
function TheContractorSettings:getNameStyle()
    return TheContractorSettings.NAME_STYLES[self.values.nameStyle] or TheContractorSettings.NAME_STYLES[1]
end

-- 100/102: the benchmark repair contract margin over the cost as a fraction
-- (0.4 for 40%): a field breakdown's (101) or a repair zone job's.
function TheContractorSettings:getADSMargin(isFieldBreakdown)
    local id = isFieldBreakdown and "adsFieldMargin" or "adsWorkshopMargin"
    return self.values[id] / 100
end

-- 048: the multiplier on a new job's price. FS25_EconomyScale's factor
-- isn't in it: jobs store their price without it and apply it as it's read
-- (TheContractorJob:getPrice), until they're paid.
function TheContractorSettings:getJobPayMultiplier()
    return self.values.jobPayRate / 100 * TheContractorJobGeneration.JOB_PAY_BASELINE
end

-- The business's fixed costs - overheads (051), claims and the excess (052),
-- the solicitor's fee (053), training (054) and fines (055) - are written at
-- 1x UK prices but charged at COST_BASELINE times that, scaled by the job pay
-- rate too, so they keep the same weight against job income whatever the
-- setting. Job pay is far above real UK contractor rates (047), so at 1x UK
-- they'd hardly register. Wages, bonuses and severance stay at UK pay.
-- FS25_EconomyScale's factor (TCEconomyScale) applies on top, as it does
-- to job pay and wages.
TheContractorSettings.COST_BASELINE = 5

function TheContractorSettings:getCostMultiplier()
    return self.values.jobPayRate / 100 * TheContractorSettings.COST_BASELINE * TCEconomyScale.getFactor()
end

-- A 1x UK cost at the current scale, to the nearest whole unit.
function TheContractorSettings:scaleCost(amount)
    return math.floor(amount * self:getCostMultiplier() + 0.5)
end

-- Streaming (TCSettingsEvent and initial client state) -------------------

function TheContractorSettings:copyValues()
    local values = {}
    for id, value in pairs(self.values) do
        values[id] = value
    end
    return values
end

function TheContractorSettings.writeValues(streamId, values)
    for _, id in ipairs(TheContractorSettings.ITEMS) do
        local value = values[id]
        if type(value) == "boolean" then
            streamWriteBool(streamId, value)
        else
            streamWriteFloat32(streamId, value)
        end
    end
end

-- Returns { id = value } rather than applying, so the server can check
-- permission before taking a client's values.
function TheContractorSettings.readValues(streamId)
    local values = {}
    for _, id in ipairs(TheContractorSettings.ITEMS) do
        if type(TheContractorSettings.getDefaultValue(id)) == "boolean" then
            values[id] = streamReadBool(streamId)
        else
            values[id] = streamReadFloat32(streamId)
        end
    end
    return values
end

function TheContractorSettings:applyValues(values)
    for id, value in pairs(values) do
        self:set(id, value)
    end
end

-- Persistence --------------------------------------------------------------

function TheContractorSettings:loadFromXMLFile(xmlFile)
    for _, id in ipairs(TheContractorSettings.ITEMS) do
        local key = string.format("%s.settings.%s#value", TheContractor.SaveKey, id)
        if hasXMLProperty(xmlFile, key) then
            if type(TheContractorSettings.getDefaultValue(id)) == "boolean" then
                self:set(id, getXMLBool(xmlFile, key))
            else
                self:set(id, getXMLFloat(xmlFile, key))
            end
        end
    end
end

function TheContractorSettings:saveToXmlFile(xmlFile)
    for _, id in ipairs(TheContractorSettings.ITEMS) do
        local key = string.format("%s.settings.%s#value", TheContractor.SaveKey, id)
        local value = self.values[id]
        if type(value) == "boolean" then
            setXMLBool(xmlFile, key, value)
        else
            setXMLFloat(xmlFile, key, value)
        end
    end
end

function TheContractorSettings:writeInitialClientState(streamId, connection)
    TheContractorSettings.writeValues(streamId, self.values)
end

function TheContractorSettings:readInitialClientState(streamId, connection)
    self:applyValues(TheContractorSettings.readValues(streamId))
end
