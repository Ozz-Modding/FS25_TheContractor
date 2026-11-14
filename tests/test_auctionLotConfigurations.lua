-- 138: an auction lot's configurations in the catalogue's details
-- (TCAuctionLotDialog.getConfigurations). The machine's chosen option per
-- configuration, in the manager's order; never a configuration with one
-- option or a colour; nothing until the machine's streamed in; and the
-- shop's overwritten title. The store, the configuration manager and the
-- streamed-in vehicles are faked.

local function setup()
    local world = stubs.install()
    ConfigurationUtil = { SELECTOR_MULTIOPTION = 0, SELECTOR_COLOR = 1 }
    local multi = { SELECTOR = 0 }
    local color = { SELECTOR = 1 }
    local descs = {
        motor = { title = "Engine", itemClass = multi },
        wheel = { title = "Tyres", itemClass = multi },
        baseColor = { title = "Colour", itemClass = color },
        fillUnit = { title = "Tank", itemClass = multi },
    }
    local order = { motor = 1, wheel = 2, baseColor = 3, fillUnit = 4 }
    g_vehicleConfigurationManager = {
        getConfigurationDescByName = function(_, name) return descs[name] end,
        getConfigurationIndexByName = function(_, name) return order[name] end,
    }
    world.storeItems = {
        ["tractor.xml"] = {
            configurations = {
                wheel = { { index = 1, name = "Narrow" }, { index = 2, name = "Wide" } },
                motor = { { index = 1, name = "150 hp" }, { index = 2, name = "180 hp" },
                    { index = 3, name = "Hidden", isSelectable = false } },
                baseColor = { { index = 1, name = "Red" }, { index = 2, name = "Blue" } },
                -- Only one option to pick: nothing to tell.
                fillUnit = { { index = 1, name = "Standard" } },
            },
        },
        ["plough.xml"] = {
            configurations = {
                wheel = { { index = 1, name = "None", overwrittenTitle = "Support wheel" },
                    { index = 2, name = "Fitted" } },
            },
        },
    }
    g_storeManager = {
        getItemByXMLFilename = function(_, xml) return world.storeItems[xml] end,
    }
    world:load("src/gui/TCAuctionLotDialog.lua")
    return world
end

test("a streamed-in machine's chosen options, in the manager's order, without colours or single options", function()
    local world = setup()
    world.objects[7] = { configurations = { motor = 2, wheel = 1, baseColor = 2, fillUnit = 1 } }
    local configurations = TCAuctionLotDialog.getConfigurations("tractor.xml", 7)
    assertEquals(#configurations, 2)
    assertEquals(configurations[1].title, "Engine")
    assertEquals(configurations[1].value, "180 hp")
    assertEquals(configurations[2].title, "Tyres")
    assertEquals(configurations[2].value, "Narrow")
end)

test("nothing until the machine's streamed in", function()
    setup()
    assertEquals(#TCAuctionLotDialog.getConfigurations("tractor.xml", 7), 0)
    assertEquals(#TCAuctionLotDialog.getConfigurations("tractor.xml", nil), 0)
end)

test("a deleted machine shows nothing", function()
    local world = setup()
    world.objects[7] = { isDeleted = true, configurations = { motor = 2 } }
    assertEquals(#TCAuctionLotDialog.getConfigurations("tractor.xml", 7), 0)
end)

test("the shop's overwritten title is used", function()
    local world = setup()
    world.objects[9] = { configurations = { wheel = 2 } }
    local configurations = TCAuctionLotDialog.getConfigurations("plough.xml", 9)
    assertEquals(#configurations, 1)
    assertEquals(configurations[1].title, "Support wheel")
    assertEquals(configurations[1].value, "Fitted")
end)

test("a lot's streamed in only once its attachment is too", function()
    local world = setup()
    world.objects[7] = { configurations = {} }
    assertTrue(TCAuctionLotDialog.isLotStreamed({ vehicleId = 7 }))
    assertTrue(not TCAuctionLotDialog.isLotStreamed({ vehicleId = 7, attachmentId = 9 }))
    world.objects[9] = { configurations = {} }
    assertTrue(TCAuctionLotDialog.isLotStreamed({ vehicleId = 7, attachmentId = 9 }))
end)
