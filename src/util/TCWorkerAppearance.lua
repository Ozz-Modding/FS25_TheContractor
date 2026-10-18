-- Worker appearance (041). Every worker gets a gender and a look, rolled
-- once at creation and kept for life, so the same person is seen in the cab
-- every time they're out driving.
--
-- Vanilla AI Helpers don't build a random look from parts: AIJob:start
-- picks one of the map's fixed helpers (HelperManager, from
-- maps_helpers.xml), each with its own preset PlayerStyle, and
-- AIJobVehicle:aiJobStarted hands that helper to
-- Enterable:setRandomVehicleCharacter on every machine. AutoDrive calls the
-- same function when it starts. That's the hook: a vehicle with one of our
-- workers on it gets that worker's own style instead.
--
-- A look is rolled from the player models the wardrobe uses
-- (PlayerSystem.PLAYER_STYLES, each tagged male/female) - a model of the
-- worker's gender, one of its wardrobe outfit presets, then a random face,
-- hairstyle, hair colour and (men only, sometimes) beard. It's stored as
-- plain data - the model file plus an item name and colour index per
-- wardrobe slot - so it saves, syncs and survives the game's item list
-- changing (a slot whose item has gone just falls back to the model's
-- default). The PlayerStyle itself is built from that on demand, on any
-- machine, and cached on the worker.

TCWorkerAppearance = {}

TCWorkerAppearance.GENDER = {
    MALE = "male",
    FEMALE = "female",
}

TCWorkerAppearance.FEMALE_CHANCE = 0.5
TCWorkerAppearance.BEARD_CHANCE = 0.5

-- Wardrobe presets (by name) too costume-like for a hired hand.
TCWorkerAppearance.BLOCKED_PRESETS = {
    horsebackRider = true,
    motorbikeRacer = true,
    beekeeper = true,
}

-- Every wardrobe slot, in a fixed order for the network stream.
TCWorkerAppearance.CONFIG_NAMES = {
    "hairStyle", "glasses", "headgear", "facegear", "face", "beard", "top", "gloves", "bottom", "footwear",
    "onepiece",
}

function TCWorkerAppearance.rollGender()
    if math.random() < TCWorkerAppearance.FEMALE_CHANCE then
        return TCWorkerAppearance.GENDER.FEMALE
    end
    return TCWorkerAppearance.GENDER.MALE
end

-- Rolling (server) ---------------------------------------------------------------

local function pickRandom(list)
    if #list == 0 then
        return nil
    end
    return list[math.random(#list)]
end

-- The wardrobe's loaded base style for every player model of `gender` (all
-- of them if none match, e.g. a mod has replaced the list).
local function getModelStyles(gender)
    local matching, all = {}, {}
    for _, entry in ipairs(PlayerSystem.PLAYER_STYLES) do
        if entry.style ~= nil and entry.style.isConfigurationLoaded then
            table.insert(all, entry.style)
            if entry.gender == gender then
                table.insert(matching, entry.style)
            end
        end
    end
    return #matching > 0 and matching or all
end

local function rollItem(config)
    local index = pickRandom(config:getPossibleItemIndices())
    if index ~= nil then
        config:setSelectedItemIndex(index, true)
    end
end

local function rollColor(config)
    local item = config:getSelectedItem()
    if item ~= nil and item.possibleColors ~= nil and #item.possibleColors > 0 then
        config:setSelectedColorIndex(math.random(#item.possibleColors))
    end
end

-- Outfits come from the model's own wardrobe presets - complete,
-- matching sets - rather than random tops and bottoms. Only ones the
-- wardrobe offers to everyone (no DLC/extra content), minus BLOCKED_PRESETS.
local function isPresetEligible(preset)
    return preset.isSelectable and preset.extraContentId == nil
        and not TCWorkerAppearance.BLOCKED_PRESETS[preset.name]
end

local function rollOutfit(style)
    local presets = {}
    for _, preset in ipairs(style:getPresets()) do
        if isPresetEligible(preset) then
            table.insert(presets, preset)
        end
    end

    local preset = pickRandom(presets)
    if preset ~= nil then
        preset:applyToStyle(style, true)
    end

    -- Anything still missing (no presets, or one that leaves a slot empty)
    -- gets a random item, so the look stays valid.
    local configs = style.configs
    if configs.onepiece.selectedItemIndex == 0 then
        for _, configName in ipairs({ "top", "bottom" }) do
            if configs[configName].selectedItemIndex == 0 then
                rollItem(configs[configName])
            end
        end
    end
    if configs.footwear.selectedItemIndex == 0 and not style.disabledOptionsForSelection.footwear then
        rollItem(configs.footwear)
    end
end

-- A new look for a worker of `gender`, as appearance data (see toData), or
-- nil if no valid one could be made - the worker then just gets vanilla's
-- random helper look in the cab.
function TCWorkerAppearance.roll(gender)
    local models = getModelStyles(gender)
    if #models == 0 then
        return nil
    end

    local style = PlayerStyle.new()
    style:copyConfigurationFrom(pickRandom(models))

    rollOutfit(style)

    -- Face before beard: which beards fit depends on the face.
    local configs = style.configs
    rollItem(configs.face)
    rollItem(configs.hairStyle)
    rollColor(configs.hairStyle)

    configs.beard.selectedItemIndex = 0
    if gender == TCWorkerAppearance.GENDER.MALE and math.random() < TCWorkerAppearance.BEARD_CHANCE then
        rollItem(configs.beard)
    end
    -- Beard and hair share one colour.
    configs.hairStyle:setSelectedColorIndex(configs.hairStyle:getSelectedColorIndex())

    style:updateDisabledOptions()
    if not style:isValid() then
        Logging.warning("TheContractor: rolled an invalid worker appearance (%s), using the helper look instead",
            tostring(style.xmlFilename))
        return nil
    end

    return TCWorkerAppearance.toData(style)
end

-- Data <-> PlayerStyle -------------------------------------------------------

-- { model = player model xml filename, configs = { [slot] = { name = item
-- name or nil, color = colour index } } }
function TCWorkerAppearance.toData(style)
    local data = { model = style.xmlFilename, configs = {} }
    for _, configName in ipairs(TCWorkerAppearance.CONFIG_NAMES) do
        local config = style.configs[configName]
        if config ~= nil then
            local item = config:getSelectedItem()
            data.configs[configName] = {
                name = item ~= nil and item.name or nil,
                color = config:getSelectedColorIndex(),
            }
        end
    end
    return data
end

-- The PlayerStyle for appearance data, or nil if it can't be made (the
-- model's no longer installed, or what's left isn't a valid look).
function TCWorkerAppearance.toPlayerStyle(data)
    if data == nil or data.model == nil then
        return nil
    end

    local entry = PlayerSystem.PLAYER_STYLES_BY_FILENAME[data.model]
    if entry == nil or entry.style == nil or not entry.style.isConfigurationLoaded then
        return nil
    end

    local style = PlayerStyle.new()
    style:copyConfigurationFrom(entry.style)

    for configName, saved in pairs(data.configs) do
        local config = style.configs[configName]
        if config ~= nil then
            local index = saved.name ~= nil and config:getItemNameIndex(saved.name) or nil
            if index ~= nil then
                config.selectedItemIndex = index
            elseif saved.name == nil then
                config.selectedItemIndex = 0
            end
            config.selectedColorIndex = saved.color or 1
        end
    end

    style:updateDisabledOptions()
    style.configs.hairStyle:setSelectedColorIndex(style.configs.hairStyle:getSelectedColorIndex())

    if not style:isValid() then
        return nil
    end
    return style
end

-- Whether appearance data is a usable look for `gender` (066's edit check
-- on the server): it builds, on a model of that gender - or any model, if
-- none has it, matching getModelStyles.
function TCWorkerAppearance.isValidLook(data, gender)
    if data == nil or data.model == nil then
        return false
    end
    local entry = PlayerSystem.PLAYER_STYLES_BY_FILENAME[data.model]
    if entry == nil then
        return false
    end
    if entry.gender ~= gender then
        for _, other in ipairs(PlayerSystem.PLAYER_STYLES) do
            if other.gender == gender and other.style ~= nil and other.style.isConfigurationLoaded then
                return false
            end
        end
    end
    return TCWorkerAppearance.toPlayerStyle(data) ~= nil
end

-- The gender of the model a look is on (077: in the wardrobe the gender
-- follows the body picked), or `fallback` for a model that's gone or has
-- no gender of ours.
function TCWorkerAppearance.getGender(data, fallback)
    local entry = data ~= nil and data.model ~= nil and PlayerSystem.PLAYER_STYLES_BY_FILENAME[data.model] or nil
    if entry ~= nil and (entry.gender == TCWorkerAppearance.GENDER.MALE or
            entry.gender == TCWorkerAppearance.GENDER.FEMALE) then
        return entry.gender
    end
    return fallback
end

-- Whether two looks' data are the same look (077: back from the wardrobe
-- with nothing changed).
function TCWorkerAppearance.isSameLook(a, b)
    if a == nil or b == nil then
        return a == b
    end
    if a.model ~= b.model then
        return false
    end
    for _, configName in ipairs(TCWorkerAppearance.CONFIG_NAMES) do
        local savedA, savedB = a.configs[configName], b.configs[configName]
        if (savedA == nil) ~= (savedB == nil) then
            return false
        end
        if savedA ~= nil and (savedA.name ~= savedB.name or savedA.color ~= savedB.color) then
            return false
        end
    end
    return true
end

-- The worker's PlayerStyle, built once per machine and cached (nil if they
-- have no usable appearance).
function TCWorkerAppearance.getPlayerStyle(worker)
    if worker.appearance == nil then
        return nil
    end
    if worker.playerStyle == nil then
        worker.playerStyle = TCWorkerAppearance.toPlayerStyle(worker.appearance)
    end
    return worker.playerStyle
end

-- Whether a loaded worker needs a fresh look: none saved (a save from
-- before 041), or the saved one can't be rebuilt any more.
function TCWorkerAppearance.needsReroll(worker)
    return TCWorkerAppearance.getPlayerStyle(worker) == nil
end

-- Persistence / wire ------------------------------------------------------------

function TCWorkerAppearance.writeXML(xmlFile, key, data)
    if data == nil then
        return
    end

    setXMLString(xmlFile, key .. "#model", data.model)
    for _, configName in ipairs(TCWorkerAppearance.CONFIG_NAMES) do
        local saved = data.configs[configName]
        if saved ~= nil then
            local configKey = key .. "." .. configName
            if saved.name ~= nil then
                setXMLString(xmlFile, configKey .. "#name", saved.name)
            end
            setXMLInt(xmlFile, configKey .. "#color", saved.color)
        end
    end
end

function TCWorkerAppearance.readXML(xmlFile, key)
    local model = getXMLString(xmlFile, key .. "#model")
    if model == nil then
        return nil
    end

    local data = { model = model, configs = {} }
    for _, configName in ipairs(TCWorkerAppearance.CONFIG_NAMES) do
        local configKey = key .. "." .. configName
        if hasXMLProperty(xmlFile, configKey) then
            data.configs[configName] = {
                name = getXMLString(xmlFile, configKey .. "#name"),
                color = getXMLInt(xmlFile, configKey .. "#color") or 1,
            }
        end
    end
    return data
end

-- Names rather than item indexes, so it doesn't depend on both ends having
-- loaded the wardrobe in the same order.
function TCWorkerAppearance.writeStream(streamId, data)
    streamWriteBool(streamId, data ~= nil)
    if data == nil then
        return
    end

    streamWriteString(streamId, data.model)
    for _, configName in ipairs(TCWorkerAppearance.CONFIG_NAMES) do
        local saved = data.configs[configName]
        streamWriteBool(streamId, saved ~= nil)
        if saved ~= nil then
            streamWriteString(streamId, saved.name or "")
            streamWriteUInt8(streamId, saved.color)
        end
    end
end

function TCWorkerAppearance.readStream(streamId)
    if not streamReadBool(streamId) then
        return nil
    end

    local data = { model = streamReadString(streamId), configs = {} }
    for _, configName in ipairs(TCWorkerAppearance.CONFIG_NAMES) do
        if streamReadBool(streamId) then
            local name = streamReadString(streamId)
            data.configs[configName] = {
                name = name ~= "" and name or nil,
                color = streamReadUInt8(streamId),
            }
        end
    end
    return data
end

-- In the cab ---------------------------------------------------------------------

-- The hired worker on a vehicle, on any machine: its staff driver (037 -
-- AI Helper, AutoDrive or Courseplay), or the operator of a contract job
-- it's assigned to. nil for anything else - a helper on a vehicle of a farm
-- with no company, a player-driven job. The second value says which: true
-- for a contract job, false for a staff driver.
function TCWorkerAppearance.getWorkerOnVehicle(vehicle)
    local tc = g_currentMission ~= nil and g_currentMission.TheContractor or nil
    if tc == nil or tc.Staff == nil then
        return nil
    end

    local binding = tc.Drivers ~= nil and tc.Drivers:getBinding(vehicle) or nil
    if binding ~= nil then
        return tc.Staff:getWorker(binding.farmId, binding.workerId), false
    end

    local vehicleId = NetworkUtil.getObjectId(vehicle)
    local farmId = vehicle.getOwnerFarmId ~= nil and vehicle:getOwnerFarmId() or nil
    if vehicleId == nil or farmId == nil or tc.Jobs == nil then
        return nil
    end

    for _, job in ipairs(tc.Jobs:getAllJobs(farmId)) do
        if job.assignedWorkerId ~= nil and (job.state == TheContractorJob.STATE.ALLOCATED or
                job.state == TheContractorJob.STATE.IN_PROGRESS) then
            for _, equipmentId in ipairs(job.assignedEquipmentIds) do
                if equipmentId == vehicleId then
                    return tc.Staff:getWorker(farmId, job.assignedWorkerId), true
                end
            end
        end
    end
    return nil
end

function TCWorkerAppearance.setRandomVehicleCharacter(vehicle, superFunc, helper)
    local worker = TCWorkerAppearance.getWorkerOnVehicle(vehicle)
    local style = worker ~= nil and TCWorkerAppearance.getPlayerStyle(worker) or nil
    if style ~= nil and vehicle.spec_enterable.vehicleCharacter ~= nil then
        vehicle:setVehicleCharacter(style)
        return
    end
    return superFunc(vehicle, helper)
end

-- Hooked at module scope, guarded so it can't stack: vehicle types pick up
-- Enterable's functions when they're finalized, after mods' sources run.
if not Enterable.tcAppearanceHookInstalled then
    Enterable.setRandomVehicleCharacter = Utils.overwrittenFunction(Enterable.setRandomVehicleCharacter,
        TCWorkerAppearance.setRandomVehicleCharacter)
    Enterable.tcAppearanceHookInstalled = true
end
