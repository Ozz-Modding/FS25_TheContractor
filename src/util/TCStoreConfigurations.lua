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
