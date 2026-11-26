-- 185: with the mod in, no AI helper ever buys anything as it works: the
-- game's helper-buys settings are switched off at mission start, refused
-- whoever tries to switch them back on, and greyed out on the settings
-- page. A slurry or manure source that's one of the farm's own loading
-- stations isn't buying, and stays.

local function setup(missionInfo)
    local world = stubs.install()
    world.settingsEvents = 0
    -- Vanilla's setters, as FSBaseMission has them: set and tell everyone
    -- (SavegameSettingsEvent) only on a change.
    local function setter(field)
        return function(mission, value, noEventSend)
            if value ~= mission.missionInfo[field] then
                mission.missionInfo[field] = value
                if not noEventSend then
                    world.settingsEvents = world.settingsEvents + 1
                end
            end
        end
    end
    FSBaseMission.setHelperBuyFuel = setter("helperBuyFuel")
    FSBaseMission.setHelperBuySeeds = setter("helperBuySeeds")
    FSBaseMission.setHelperBuyFertilizer = setter("helperBuyFertilizer")
    FSBaseMission.setHelperSlurrySource = setter("helperSlurrySource")
    FSBaseMission.setHelperManureSource = setter("helperManureSource")
    InGameMenuSettingsFrame = { updateGameSettings = function() end }
    g_inGameMenu = nil

    g_currentMission.missionInfo = missionInfo
    setmetatable(g_currentMission, { __index = FSBaseMission })
    world:load("src/util/TCNoHelperBuying.lua")
    return world
end

local function everythingOn()
    return { helperBuyFuel = true, helperBuySeeds = true, helperBuyFertilizer = true,
        helperSlurrySource = 2, helperManureSource = 2 }
end

test("a save with the helper buying is switched off at mission start, and clients are told", function()
    local world = setup(everythingOn())

    TCNoHelperBuying.apply()

    local missionInfo = g_currentMission.missionInfo
    assertEquals(missionInfo.helperBuyFuel, false)
    assertEquals(missionInfo.helperBuySeeds, false)
    assertEquals(missionInfo.helperBuyFertilizer, false)
    assertEquals(missionInfo.helperSlurrySource, TCNoHelperBuying.SOURCE_NONE)
    assertEquals(missionInfo.helperManureSource, TCNoHelperBuying.SOURCE_NONE)
    assertTrue(world.settingsEvents > 0, "sent")
end)

test("only the server switches them off", function()
    setup(everythingOn())
    g_currentMission.getIsServer = function() return false end

    TCNoHelperBuying.apply()

    assertEquals(g_currentMission.missionInfo.helperBuyFertilizer, true, "the server's word comes by event")
end)

test("switching one back on is refused, from the menu or an event", function()
    local world = setup({ helperBuyFuel = false, helperBuySeeds = false, helperBuyFertilizer = false,
        helperSlurrySource = 1, helperManureSource = 1 })

    g_currentMission:setHelperBuyFertilizer(true)
    g_currentMission:setHelperBuySeeds(true, true)
    g_currentMission:setHelperBuyFuel(true)
    g_currentMission:setHelperSlurrySource(TCNoHelperBuying.SOURCE_BUY)
    g_currentMission:setHelperManureSource(TCNoHelperBuying.SOURCE_BUY, true)

    local missionInfo = g_currentMission.missionInfo
    assertEquals(missionInfo.helperBuyFertilizer, false)
    assertEquals(missionInfo.helperBuySeeds, false)
    assertEquals(missionInfo.helperBuyFuel, false)
    assertEquals(missionInfo.helperSlurrySource, TCNoHelperBuying.SOURCE_NONE)
    assertEquals(missionInfo.helperManureSource, TCNoHelperBuying.SOURCE_NONE)
    assertEquals(world.settingsEvents, 0, "nothing changed, nothing sent")
end)

test("the farm's own loading station stays a helper's source", function()
    setup(everythingOn())
    local station = 3

    g_currentMission:setHelperSlurrySource(station)
    g_currentMission:setHelperManureSource(station + 1)

    assertEquals(g_currentMission.missionInfo.helperSlurrySource, station)
    assertEquals(g_currentMission.missionInfo.helperManureSource, station + 1)
end)

test("an open settings page is put back to the source really set", function()
    setup({ helperSlurrySource = 1, helperManureSource = 1 })
    local shown = {}
    local function option(name)
        return { setState = function(_, state) shown[name] = state end }
    end
    g_inGameMenu = { pageSettings = { multiHelperRefillSlurry = option("slurry"),
        multiHelperRefillManure = option("manure") } }

    g_currentMission:setHelperSlurrySource(TCNoHelperBuying.SOURCE_BUY)
    g_currentMission:setHelperManureSource(TCNoHelperBuying.SOURCE_BUY)

    assertEquals(shown.slurry, TCNoHelperBuying.SOURCE_NONE)
    assertEquals(shown.manure, TCNoHelperBuying.SOURCE_NONE)
end)

test("the settings page greys out the three buy switches", function()
    setup(everythingOn())
    local disabled = {}
    local frame = {}
    for _, name in ipairs({ "checkHelperRefillFuel", "checkHelperRefillSeed", "checkHelperRefillFertilizer" }) do
        frame[name] = { setDisabled = function(_, isDisabled) disabled[name] = isDisabled end }
    end

    InGameMenuSettingsFrame.updateGameSettings(frame)

    assertEquals(disabled.checkHelperRefillFuel, true)
    assertEquals(disabled.checkHelperRefillSeed, true)
    assertEquals(disabled.checkHelperRefillFertilizer, true)
end)
