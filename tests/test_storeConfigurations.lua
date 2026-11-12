-- The configurations a vehicle spawned from a store item loads with
-- (TCStoreConfigurations): its default configuration set's, so a mod whose
-- configurations only work in sets (FS25_dk115's bale loader) loads whole.

local function setup()
    local world = stubs.install()
    world:load("src/util/TCStoreConfigurations.lua")
    return world
end

local function fakeLoadingData()
    return {
        setConfigurations = function(self, configurations)
            self.configurations = configurations
        end,
    }
end

test("an item with sets loads with the set marked default", function()
    setup()
    local storeItem = { configurationSets = {
        { configurations = { vehicleType = 1, fillUnit = 3 } },
        { isDefault = true, configurations = { vehicleType = 2, fillUnit = 1 } },
    } }
    local loadingData = fakeLoadingData()
    TCStoreConfigurations.apply(loadingData, storeItem)
    assertEquals(2, loadingData.configurations.vehicleType)
    assertEquals(1, loadingData.configurations.fillUnit)
end)

test("with no set marked default, the first set", function()
    setup()
    local storeItem = { configurationSets = {
        { configurations = { vehicleType = 1, fillUnit = 3 } },
        { configurations = { vehicleType = 2, fillUnit = 1 } },
    } }
    local loadingData = fakeLoadingData()
    TCStoreConfigurations.apply(loadingData, storeItem)
    assertEquals(1, loadingData.configurations.vehicleType)
    assertEquals(3, loadingData.configurations.fillUnit)
end)

test("the loading data gets a copy: the store item's set is never changed", function()
    setup()
    local set = { isDefault = true, configurations = { fillUnit = 1 } }
    local loadingData = fakeLoadingData()
    TCStoreConfigurations.apply(loadingData, { configurationSets = { set } })
    loadingData.configurations.fillUnit = 9
    assertEquals(1, set.configurations.fillUnit)
end)

test("an item with no sets is left to the game's defaults", function()
    setup()
    for _, storeItem in ipairs({ {}, { configurationSets = {} } }) do
        local loadingData = fakeLoadingData()
        TCStoreConfigurations.apply(loadingData, storeItem)
        assertEquals(nil, loadingData.configurations)
    end
end)
