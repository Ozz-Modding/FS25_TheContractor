-- Showing parking slots (086): slots show in the construction menu, and
-- everywhere else only while this machine's showParkingSlots setting is
-- on. That setting is a local item: kept in modSettings, never saved in the
-- savegame or streamed, and flipped by TC_TOGGLE_PARKING_SLOTS. Standing
-- spots still only show in the construction menu.

local world

local function setup()
    world = stubs.install()
    -- Vanilla keys Settings reads at load.
    world.texts.ui_on = "On"
    world.texts.ui_off = "Off"

    -- The legacy XML API on top of the stub's plain tables, by filename.
    world.files = {}
    fileExists = function(filename) return world.files[filename] ~= nil end
    createXMLFile = function(_, filename) return { filename = filename } end
    loadXMLFile = function(_, filename) return world.files[filename] end
    saveXMLFile = function(xmlFile) world.files[xmlFile.filename] = xmlFile end
    delete = function() end
    g_currentModSettingsDirectory = "modSettings/FS25_TheContractor/"

    GuiTopDownCursor = { getHitPlaceable = function() return nil end }
    CollisionFlag = { VEHICLE = 1, PLAYER = 2, DYNAMIC_OBJECT = 4, TREE = 8, STATIC_OBJECT = 16, BUILDING = 32 }
    FSBaseMission.INGAME_NOTIFICATION_INFO = "info"
    InputAction = { TC_TOGGLE_PARKING_SLOTS = "TC_TOGGLE_PARKING_SLOTS" }
    world.actionEvents = {}
    g_inputBinding = {
        registerActionEvent = function(_, action, target, callback)
            table.insert(world.actionEvents, { action = action, target = target, callback = callback })
            return true, #world.actionEvents
        end,
        setActionEventTextVisibility = function() end,
    }
    PlayerInputComponent = { registerGlobalPlayerActionEvents = function() end }
    TCSettingsMenu = { refreshControls = function() world.menuRefreshed = true end }

    world:load("src/placeables/PlaceableTCParkingSlot.lua")
    world:load("src/placeables/PlaceableTCStandingSpot.lua")
    world:load("src/util/TCParking.lua")
    world:load("src/business/Settings.lua")
    TheContractor = { SaveKey = "TheContractor" }

    g_currentMission.TheContractor.Settings = TheContractorSettings.new()
    g_currentMission.placeableSystem = { placeables = {} }
end

-- A slot or spot whose visuals node records its visibility.
local function addPlaceable(key)
    local placeable = { visuals = { visible = nil } }
    placeable[key] = { visualsNode = placeable.visuals }
    table.insert(g_currentMission.placeableSystem.placeables, placeable)
    return placeable
end

local function install()
    entityExists = function() return true end
    setVisibility = function(node, isVisible) node.visible = isVisible end
end

test("slots are hidden outside the construction menu by default", function()
    setup()
    install()
    local slot = addPlaceable(PlaceableTCParkingSlot.KEY)
    assertEquals(false, g_currentMission.TheContractor.Settings:get("showParkingSlots"))
    TCParking.updateVisuals()
    assertEquals(false, slot.visuals.visible)
end)

test("the setting shows slots everywhere, but not standing spots", function()
    setup()
    install()
    local slot = addPlaceable(PlaceableTCParkingSlot.KEY)
    local spot = addPlaceable(PlaceableTCStandingSpot.KEY)
    g_currentMission.TheContractor.Settings:setLocal("showParkingSlots", true)
    assertEquals(true, slot.visuals.visible, "shown as soon as it's set")
    assertEquals(false, spot.visuals.visible)

    -- Opening and closing the construction menu leaves the slot showing.
    TCParking.isConstructionScreenOpen = true
    TCParking.updateVisuals()
    assertEquals(true, spot.visuals.visible, "spots show in the menu")
    TCParking.isConstructionScreenOpen = false
    TCParking.updateVisuals()
    assertEquals(true, slot.visuals.visible)
    assertEquals(false, spot.visuals.visible)
end)

test("the setting is this machine's own: kept in modSettings, not the savegame or the stream", function()
    setup()
    local settings = g_currentMission.TheContractor.Settings
    settings:setLocal("showParkingSlots", true)

    local file = world.files["modSettings/FS25_TheContractor/localSettings.xml"]
    assertTrue(file ~= nil, "local file written")
    assertEquals(true, file["TheContractorLocal.showParkingSlots#value"])

    local savegame = {}
    settings:saveToXmlFile(savegame)
    for key in pairs(savegame) do
        assertTrue(not key:find("showParkingSlots"), "not in the savegame: " .. key)
    end
    local stream = world:newStream()
    TheContractorSettings.writeValues(stream, settings:copyValues())
    assertEquals(#TheContractorSettings.ITEMS, #stream.values, "only server settings streamed")

    -- A fresh load on this machine picks it back up.
    local loaded = TheContractorSettings.new()
    loaded:loadLocalFile()
    assertEquals(true, loaded:get("showParkingSlots"))
end)

test("the key toggles the setting, refreshes the menu and says so", function()
    setup()
    install()
    local slot = addPlaceable(PlaceableTCParkingSlot.KEY)

    -- The player's global action events include the toggle.
    PlayerInputComponent.registerGlobalPlayerActionEvents({})
    assertEquals(1, #world.actionEvents)
    local event = world.actionEvents[1]
    assertEquals("TC_TOGGLE_PARKING_SLOTS", event.action)

    event.callback(event.target)
    assertEquals(true, g_currentMission.TheContractor.Settings:get("showParkingSlots"))
    assertEquals(true, slot.visuals.visible)
    assertTrue(world.menuRefreshed, "settings page control updated")
    assertEquals("Parking slots shown", world.notifications[1].text)

    event.callback(event.target)
    assertEquals(false, slot.visuals.visible)
    assertEquals("Parking slots hidden", world.notifications[2].text)
end)
