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

test("one configuration chosen: with no sets, just that one", function()
    setup()
    local configurations = TCStoreConfigurations.getSetWith({}, "fillUnit", 2)
    assertEquals(configurations.fillUnit, 2)
    assertEquals(next(configurations, "fillUnit"), nil)
end)

test("one configuration chosen: the default set if it allows it, else another that does, else none", function()
    setup()
    local storeItem = { configurationSets = {
        { configurations = { fillUnit = 2, design = 3 } },
        { isDefault = true, configurations = { design = 1 } },
    } }
    local configurations = TCStoreConfigurations.getSetWith(storeItem, "fillUnit", 2)
    assertEquals(configurations.design, 1, "the default set names no fill unit, so allows any")
    assertEquals(configurations.fillUnit, 2)
    assertEquals(storeItem.configurationSets[2].configurations.fillUnit, nil, "the set's never changed")

    storeItem.configurationSets[2].configurations.fillUnit = 1
    assertEquals(TCStoreConfigurations.getSetWith(storeItem, "fillUnit", 2).design, 3)
    assertEquals(TCStoreConfigurations.getSetWith(storeItem, "fillUnit", 4), nil)
end)

test("chosen configurations go on the loading data as a copy; none chosen, the default set's", function()
    setup()
    local chosen = { fillUnit = 2 }
    local loadingData = fakeLoadingData()
    TCStoreConfigurations.applyChosen(loadingData, {}, chosen)
    loadingData.configurations.fillUnit = 9
    assertEquals(chosen.fillUnit, 2)

    loadingData = fakeLoadingData()
    TCStoreConfigurations.applyChosen(loadingData,
        { configurationSets = { { configurations = { fillUnit = 3 } } } }, nil)
    assertEquals(loadingData.configurations.fillUnit, 3)
end)
