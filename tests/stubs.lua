-- Fake FS25 engine globals for the unit tests. stubs.install() replaces
-- them all with fresh ones and returns a `world` for building the scene a
-- test needs (vehicles, storages, farms) and reading back what happened
-- (farm stats, notifications, log lines). Call it at the start of every
-- test, before loading any src/ file: several of them patch engine classes
-- (Motorized, Sprayer, ...) as they load.
--
-- These are our assumptions about the base game, checked against
-- ../Reference/FS25_Lua where it matters - not the game itself. A test
-- that passes here can still be wrong in-game.
--
-- Mod modules a test doesn't load (TheContractorNegotiation, Jobs,
-- Dispatch, ...) are faked in the test file itself, not here.

local stubs = {}

stubs.FILL_TYPES = {
    { name = "UNKNOWN", title = "Unknown" },
    { name = "DIESEL", title = "Diesel" },
    { name = "DEF", title = "DEF" },
    { name = "SEEDS", title = "Seeds" },
    { name = "FERTILIZER", title = "Fertilizer" },
    { name = "LIQUIDFERTILIZER", title = "Liquid fertilizer" },
    { name = "HERBICIDE", title = "Herbicide" },
    { name = "MANURE", title = "Manure" },
    { name = "LIQUIDMANURE", title = "Slurry" },
    { name = "POTATO", title = "Potatoes" },
    { name = "BALENET", title = "Bale net", unitShort = "pcs" },
    { name = "WHEAT", title = "Wheat" },
}

-- The mod's real English texts, so a missing key fails the test.
local function loadTexts(path)
    local file = io.open(path, "r")
    assert(file ~= nil, "can't open " .. path)
    local content = file:read("*a")
    file:close()

    local entities = { amp = "&", lt = "<", gt = ">", quot = "\"", apos = "'" }
    local texts = {}
    for name, text in content:gmatch("<text%s+name=\"([^\"]+)\"%s+text=\"([^\"]*)\"") do
        texts[name] = text:gsub("&(%a+);", entities)
    end
    return texts
end

local function toSet(list)
    local set = {}
    for _, value in ipairs(list) do
        set[value] = true
    end
    return set
end

local function installXML()
    -- An xmlFile is a plain table, key -> value.
    local function set(xmlFile, key, value)
        xmlFile[key] = value
    end
    local function get(xmlFile, key)
        return xmlFile[key]
    end
    setXMLInt, setXMLFloat, setXMLString, setXMLBool = set, set, set, set
    getXMLInt, getXMLFloat, getXMLString, getXMLBool = get, get, get, get
    hasXMLProperty = function(xmlFile, key)
        for existing in pairs(xmlFile) do
            if existing == key or existing:sub(1, #key + 1) == key .. "#" or existing:sub(1, #key + 1) == key .. "." then
                return true
            end
        end
        return false
    end
end

-- A stream is a plain table used as a queue: every streamWrite* appends,
-- every streamRead* takes the oldest value. world:newStream() makes one.
-- Float32 values aren't rounded to 32 bits.
local function installStreams()
    local function write(streamId, value)
        table.insert(streamId.values, value)
    end
    local function read(streamId)
        streamId.position = streamId.position + 1
        return streamId.values[streamId.position]
    end
    for _, name in ipairs({ "Bool", "Int8", "Int16", "Int32", "UInt8", "UInt16", "UInt32", "Float32", "String" }) do
        _G["streamWrite" .. name] = write
        _G["streamRead" .. name] = read
    end
    streamWriteUIntN = function(streamId, value) write(streamId, value) end
    streamReadUIntN = function(streamId) return read(streamId) end
end

function stubs.install()
    local world = {
        farms = { { farmId = 1 } },
        objects = {},
        nextObjectId = 1,
        storages = {},
        farmStats = {},
        notifications = {},
        logs = {},
        warnings = {},
        dieselPrice = 1.5,
        texts = loadTexts("languages/l10n_en.xml"),
        -- modName -> key -> text: other mods' own texts (g_i18n's
        -- customEnv lookups).
        modTexts = {},
    }

    Class = function(classTable)
        return { __index = classTable }
    end

    Utils = {
        getNoNil = function(value, default)
            if value == nil then
                return default
            end
            return value
        end,
        -- Same shape as the engine's: the new function gets the old one
        -- as its second argument.
        overwrittenFunction = function(oldFunc, newFunc)
            return function(self, ...)
                return newFunc(self, oldFunc, ...)
            end
        end,
        appendedFunction = function(oldFunc, newFunc)
            return function(...)
                oldFunc(...)
                newFunc(...)
            end
        end,
    }

    Logging = {
        info = function(fmt, ...)
            table.insert(world.logs, string.format(fmt, ...))
        end,
        warning = function(fmt, ...)
            table.insert(world.warnings, string.format(fmt, ...))
        end,
        error = function(fmt, ...)
            error(string.format(fmt, ...), 2)
        end,
    }

    FillType = {}
    local fillTypeByIndex = {}
    for index, fillType in ipairs(stubs.FILL_TYPES) do
        FillType[fillType.name] = index
        fillTypeByIndex[index] = fillType
    end
    g_fillTypeManager = {
        getFillTypeIndexByName = function(_, name)
            return FillType[name]
        end,
        getFillTypeNameByIndex = function(_, index)
            return fillTypeByIndex[index] ~= nil and fillTypeByIndex[index].name or nil
        end,
        getFillTypeTitleByIndex = function(_, index)
            return fillTypeByIndex[index] ~= nil and fillTypeByIndex[index].title or nil
        end,
        getFillTypeByIndex = function(_, index)
            return fillTypeByIndex[index]
        end,
    }

    ToolType = { UNDEFINED = 0 }

    g_i18n = {
        getText = function(_, key, customEnv)
            local modTexts = customEnv ~= nil and world.modTexts[customEnv] or nil
            local text = modTexts ~= nil and modTexts[key] or world.texts[key]
            assert(text ~= nil, "missing l10n key " .. tostring(key))
            return text
        end,
        hasText = function(_, key, customEnv)
            local modTexts = customEnv ~= nil and world.modTexts[customEnv] or nil
            return (modTexts ~= nil and modTexts[key] ~= nil) or world.texts[key] ~= nil
        end,
        formatVolume = function(_, liters)
            return string.format("%d l", math.floor(liters))
        end,
        formatNumber = function(_, number)
            return tostring(number)
        end,
        formatMoney = function(_, amount)
            return string.format("%.0f", amount)
        end,
    }

    installXML()
    installStreams()

    function world:newStream()
        return { values = {}, position = 0 }
    end

    -- Engine classes the mod patches as it loads. Motorized's
    -- updateConsumers reports one fuel step through g_farmManager (like
    -- the real one, which batches usage into >1 l steps) and notes the
    -- helperBuyFuel it saw.
    Motorized = {
        updateConsumers = function(vehicle, dt, accInput)
            world.helperBuyFuelSeen = g_currentMission.missionInfo.helperBuyFuel
            g_farmManager:updateFarmStats(vehicle:getOwnerFarmId(), "fuelUsage", vehicle.fuelStep or 2)
        end,
    }
    -- Vanilla's base: every map hotspot shown (specializations narrow it).
    Vehicle = {
        getIsMapHotspotVisible = function(vehicle)
            return true
        end,
    }
    FarmManager = {
        updateFarmStats = function(_, farmId, statName, delta)
            table.insert(world.farmStats, { farmId = farmId, statName = statName, delta = delta })
        end,
    }
    SowingMachine = {
        processSowingMachineArea = function() end,
        onEndWorkAreaProcessing = function() end,
    }
    Sprayer = {
        getIsSprayerExternallyFilled = function()
            return true
        end,
    }

    g_farmManager = setmetatable({
        getFarms = function()
            return world.farms
        end,
    }, { __index = FarmManager })

    NetworkUtil = {
        getObject = function(id)
            return world.objects[id]
        end,
        getObjectId = function(object)
            return object.id
        end,
    }

    FSBaseMission = { INGAME_NOTIFICATION_OK = "ok", INGAME_NOTIFICATION_CRITICAL = "critical" }

    g_server = nil
    g_client = nil

    g_currentMission = {
        missionInfo = { helperBuyFuel = true, helperBuySeeds = true, helperBuyFertilizer = true, fuelUsage = 2 },
        economyManager = {
            getCostPerLiter = function(_, fillTypeIndex)
                return world.dieselPrice
            end,
        },
        storageSystem = {
            getStorages = function()
                return world.storages
            end,
        },
        vehicleSystem = { vehicles = {} },
        getIsServer = function()
            return true
        end,
        getFarmId = function()
            return 1
        end,
        addIngameNotification = function(_, notificationType, text)
            table.insert(world.notifications, { type = notificationType, text = text })
        end,
        TheContractor = {},
    }

    -- Builders --------------------------------------------------------------

    function world:register(object)
        object.id = self.nextObjectId
        self.nextObjectId = self.nextObjectId + 1
        self.objects[object.id] = object
        return object.id
    end

    -- def: { name, farmId, isPallet, isAIActive, fuelStep,
    --        fillUnits = { { capacity, level, fillType, supported = {...} }... },
    --        dieselUsagePerHour, dieselCapacity, dieselLevel }
    -- The diesel tank, if any, is added as the last fill unit with a
    -- Motorized diesel consumer, the way vanilla vehicles have one.
    function world:addVehicle(def)
        local vehicle = {
            name = def.name or "Vehicle",
            farmId = def.farmId or 1,
            isPallet = def.isPallet,
            isAIActive = def.isAIActive,
            fuelStep = def.fuelStep,
            fillUnits = {},
        }

        for _, unit in ipairs(def.fillUnits or {}) do
            table.insert(vehicle.fillUnits, {
                capacity = unit.capacity,
                level = unit.level or 0,
                fillType = unit.fillType or FillType.UNKNOWN,
                lastValidFillType = unit.fillType,
                supported = toSet(unit.supported or { unit.fillType }),
            })
        end

        if def.dieselUsagePerHour ~= nil then
            table.insert(vehicle.fillUnits, {
                capacity = def.dieselCapacity or 400,
                level = def.dieselLevel or def.dieselCapacity or 400,
                fillType = FillType.DIESEL,
                lastValidFillType = FillType.DIESEL,
                supported = toSet({ FillType.DIESEL }),
            })
            local consumer = {
                fillUnitIndex = #vehicle.fillUnits,
                fillType = FillType.DIESEL,
                usage = def.dieselUsagePerHour / 3600000,
                permanentConsumption = true,
            }
            vehicle.spec_motorized = { consumers = { consumer }, consumersByFillType = { [FillType.DIESEL] = consumer } }
        end

        vehicle.spec_fillUnit = { fillUnits = vehicle.fillUnits }
        if def.isPallet then
            vehicle.spec_pallet = { fillUnitIndex = 1 }
        end

        function vehicle:getName() return self.name end
        function vehicle:getOwnerFarmId() return self.farmId end
        function vehicle:getIsAIActive() return self.isAIActive == true end
        function vehicle:getFillUnitCapacity(index) return self.fillUnits[index].capacity end
        function vehicle:getFillUnitFillLevel(index) return self.fillUnits[index].level end
        function vehicle:getFillUnitLastValidFillType(index) return self.fillUnits[index].lastValidFillType end
        function vehicle:getFillUnitFillType(index)
            local unit = self.fillUnits[index]
            return unit.level > 0 and unit.fillType or FillType.UNKNOWN
        end
        function vehicle:getFillUnitSupportsFillType(index, fillTypeIndex)
            return self.fillUnits[index].supported[fillTypeIndex] == true
        end
        function vehicle:getFillUnitSupportedFillTypes(index)
            return self.fillUnits[index].supported
        end
        function vehicle:getFillUnitFreeCapacity(index)
            local unit = self.fillUnits[index]
            return unit.capacity - unit.level
        end
        function vehicle:addFillUnitFillLevel(farmId, index, delta, fillTypeIndex)
            local unit = self.fillUnits[index]
            local newLevel = math.max(0, math.min(unit.capacity, unit.level + delta))
            local applied = newLevel - unit.level
            unit.level = newLevel
            if newLevel > 0 then
                unit.fillType = fillTypeIndex
                unit.lastValidFillType = fillTypeIndex
            end
            return applied
        end

        self:register(vehicle)
        table.insert(g_currentMission.vehicleSystem.vehicles, vehicle)
        return vehicle
    end

    -- def: { farmId, levels = { [fillTypeIndex] = liters }, capacity,
    --        capacities = { [fillTypeIndex] = liters } } - supports
    -- whatever fill types it's given levels for (0 allowed). Like vanilla's
    -- Storage, a fill type with its own entry in capacities has that much
    -- room to itself; the rest share `capacity` (default 100000).
    function world:addStorage(def)
        local storage = {
            farmId = def.farmId or 1,
            levels = def.levels or {},
            capacity = def.capacity or 100000,
            capacities = def.capacities or {},
        }
        function storage:getOwnerFarmId() return self.farmId end
        function storage:getIsFillTypeSupported(fillTypeIndex) return self.levels[fillTypeIndex] ~= nil end
        function storage:getFillLevel(fillTypeIndex) return self.levels[fillTypeIndex] or 0 end
        function storage:setFillLevel(level, fillTypeIndex) self.levels[fillTypeIndex] = level end
        function storage:getFreeCapacity(fillTypeIndex)
            if self.levels[fillTypeIndex] == nil then
                return 0
            end
            if self.capacities[fillTypeIndex] ~= nil then
                return math.max(self.capacities[fillTypeIndex] - self.levels[fillTypeIndex], 0)
            end
            local used = 0
            for typeIndex, level in pairs(self.levels) do
                if self.capacities[typeIndex] == nil then
                    used = used + level
                end
            end
            return math.max(self.capacity - used, 0)
        end
        table.insert(self.storages, storage)
        return storage
    end

    -- A placeable owning storages, the way vanilla's keep them in their
    -- spec tables: def { name, farmId, specs = { spec_silo = { storages =
    -- {...} }, ... } }.
    function world:addPlaceable(def)
        local placeable = { name = def.name or "Placeable", farmId = def.farmId or 1 }
        for key, spec in pairs(def.specs or {}) do
            placeable[key] = spec
        end
        function placeable:getName() return self.name end
        function placeable:getOwnerFarmId() return self.farmId end
        g_currentMission.placeableSystem = g_currentMission.placeableSystem or { placeables = {} }
        table.insert(g_currentMission.placeableSystem.placeables, placeable)
        return placeable
    end

    -- A mod-registered fill type (e.g. ADS's oils), after the built-in ones.
    function world:addFillType(name, title, unitShort)
        table.insert(fillTypeByIndex, { name = name, title = title, unitShort = unitShort })
        FillType[name] = #fillTypeByIndex
        return FillType[name]
    end

    -- Loads a src/ file (path relative to the repo root).
    function world:load(path)
        dofile(path)
    end

    return world
end

return stubs
