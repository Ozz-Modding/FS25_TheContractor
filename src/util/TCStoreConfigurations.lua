-- The configurations a vehicle we spawn from a store item loads with: its
-- default configuration set's (the one marked isDefault, else the first),
-- as the shop starts from one. Loaded with none, each configuration takes
-- its own default, which a mod with configuration sets may never pair: the
-- Welger DK 115 (FS25_dk115) then loads as a bale loader with a bulk
-- trailer's fill units, and BaleLoader's update errors every frame. Vanilla
-- only puts the closest set back once the vehicle type's already chosen.
-- Every VehicleLoadingData built from a store item goes through apply.

TCStoreConfigurations = {}

-- A copy of the default set's { configName = index }, or nil for an item
-- with no sets (pure).
function TCStoreConfigurations.getDefaultSet(storeItem)
    local sets = storeItem ~= nil and storeItem.configurationSets or nil
    if sets == nil or #sets == 0 then
        return nil
    end
    local chosen = sets[1]
    for _, set in ipairs(sets) do
        if set.isDefault then
            chosen = set
            break
        end
    end
    local configurations = {}
    for name, index in pairs(chosen.configurations or {}) do
        configurations[name] = index
    end
    return configurations
end

-- Sets loadingData's configurations to storeItem's default set, if it has
-- sets. Call after setStoreItem.
function TCStoreConfigurations.apply(loadingData, storeItem)
    local configurations = TCStoreConfigurations.getDefaultSet(storeItem)
    if configurations ~= nil then
        loadingData:setConfigurations(configurations)
    end
end

-- The configurations to load storeItem with one configuration chosen
-- (configName = index): with sets, a copy of the first set that allows it
-- (the default set first; a set that doesn't name configName allows any),
-- with configName set; nil if no set does. With no sets, { configName =
-- index }, the rest left to the game's defaults.
function TCStoreConfigurations.getSetWith(storeItem, configName, index)
    local sets = storeItem ~= nil and storeItem.configurationSets or nil
    if sets == nil or #sets == 0 then
        return { [configName] = index }
    end
    local ordered = {}
    for _, set in ipairs(sets) do
        if set.isDefault then
            table.insert(ordered, 1, set)
        else
            table.insert(ordered, set)
        end
    end
    for _, set in ipairs(ordered) do
        local named = set.configurations ~= nil and set.configurations[configName] or nil
        if named == nil or named == index then
            local configurations = {}
            for name, value in pairs(set.configurations or {}) do
                configurations[name] = value
            end
            configurations[configName] = index
            return configurations
        end
    end
    return nil
end

-- Sets loadingData's configurations: the given ones (a copy) if any, else
-- the default set's (apply). Call after setStoreItem.
function TCStoreConfigurations.applyChosen(loadingData, storeItem, configurations)
    if configurations == nil then
        TCStoreConfigurations.apply(loadingData, storeItem)
        return
    end
    local copy = {}
    for name, value in pairs(configurations) do
        copy[name] = value
    end
    loadingData:setConfigurations(copy)
end
