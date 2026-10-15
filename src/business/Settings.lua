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

TheContractorSettings.ITEMS = { "jobPayRate", "lateInvoices", "randomEvents" }

function TheContractorSettings.new()
    local self = {}
    setmetatable(self, TheContractorSettings_mt)

    self.values = {}
    for _, id in ipairs(TheContractorSettings.ITEMS) do
        self.values[id] = TheContractorSettings.getDefaultValue(id)
    end

    return self
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

-- 048: the multiplier on a new job's price.
function TheContractorSettings:getJobPayMultiplier()
    return self.values.jobPayRate / 100 * TheContractorJobGeneration.JOB_PAY_BASELINE
end

-- The business's fixed costs - overheads (051), claims and the excess (052),
-- the solicitor's fee (053), training (054) and fines (055) - are written at
-- 1x UK prices but charged at COST_BASELINE times that, scaled by the job pay
-- rate too, so they keep the same weight against job income whatever the
-- setting. Job pay is far above real UK contractor rates (047), so at 1x UK
-- they'd hardly register. Wages, bonuses and severance stay at UK pay.
TheContractorSettings.COST_BASELINE = 5

function TheContractorSettings:getCostMultiplier()
    return self.values.jobPayRate / 100 * TheContractorSettings.COST_BASELINE
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
