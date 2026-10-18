-- Editing a worker's look in the vanilla wardrobe (077): gender from the
-- chosen model, comparing looks, and TCWardrobe's session - the worker's
-- style swapped into the screen, the wardrobe's Back taken off the player,
-- Change Name hidden, and everything put back however the screen closes.

local function look(model, hair)
    return { model = model, configs = { hairStyle = { name = hair, color = 1 } } }
end

local function setup()
    local world = stubs.install()
    Enterable = {}
    world:load("src/util/TCWorkerAppearance.lua")
    world:load("src/gui/TCWardrobe.lua")

    PlayerSystem = {
        PLAYER_STYLES = {
            { filename = "male.xml", gender = "male", style = { isConfigurationLoaded = true } },
            { filename = "female.xml", gender = "female", style = { isConfigurationLoaded = true } },
            { filename = "odd.xml", gender = "other", style = { isConfigurationLoaded = true } },
        },
        PLAYER_STYLES_BY_FILENAME = {},
    }
    for _, entry in ipairs(PlayerSystem.PLAYER_STYLES) do
        PlayerSystem.PLAYER_STYLES_BY_FILENAME[entry.filename] = entry
    end

    -- Building a PlayerStyle is the engine's business: here a "style" is
    -- just the data it came from, and toData hands it back.
    TCWorkerAppearance.toPlayerStyle = function(data)
        if data == nil or data.isBroken then
            return nil
        end
        return { data = data }
    end
    TCWorkerAppearance.toData = function(style)
        return style.data
    end

    local function newStyle()
        return {
            copyFrom = function(self, other)
                self.data = other.data
            end,
        }
    end

    -- The wardrobe screen, as far as TCWardrobe uses it. Opening it loads
    -- the player's own look, like WardrobeScreen:onOpen.
    WardrobeScreen = {}
    Platform = { hasWardrobe = true }
    local nicknameButton = { text = "Change Name" }
    local screen = {
        pageUpdates = 0,
        poppedToRoot = 0,
        exited = 0,
        pageCharacter = {
            nicknameButtonInfo = nicknameButton,
            menuButtonInfo = { { text = "Back" }, { text = "Select" }, nicknameButton },
        },
        updatePagePlayerStyle = function(self)
            self.pageUpdates = self.pageUpdates + 1
        end,
        popToRoot = function(self)
            self.poppedToRoot = self.poppedToRoot + 1
        end,
        exitMenu = function(self)
            self.exited = self.exited + 1
            g_gui:changeScreen(nil, nil)
        end,
    }
    world.screen = screen
    world.nicknameButton = nicknameButton

    world.playerStyleSets = {}
    world.playerLook = look("male.xml", "player")
    local Player = {}
    Player.setStyleAsync = function(_, style)
        table.insert(world.playerStyleSets, style)
    end
    g_localPlayer = setmetatable({}, { __index = Player })

    local element = { name = "WardrobeScreen" }
    world.closes = 0
    element.onCloseCallback = function()
        world.closes = world.closes + 1
    end
    g_gui = {
        currentGuiName = "InGameMenu",
        screenControllers = { [WardrobeScreen] = screen },
        screens = { [WardrobeScreen] = element },
        changeScreen = function(self, _, screenClass)
            if self.currentGuiName == "WardrobeScreen" then
                element.onCloseCallback(element)
            end
            if screenClass == WardrobeScreen then
                self.currentGuiName = "WardrobeScreen"
                screen.currentPlayerStyle = newStyle()
                screen.temporaryPlayerStyle = newStyle()
                screen.currentPlayerStyle.data = world.playerLook
                screen.temporaryPlayerStyle.data = world.playerLook
            else
                self.currentGuiName = ""
            end
        end,
        -- What the menu's reopen does: opening another GUI closes this one.
        showGui = function(self, name)
            self:changeScreen(nil, nil)
            self.currentGuiName = name
        end,
    }

    TCWardrobe.install()
    return world
end

-- The wardrobe's Back: what WardrobeScreen:onButtonBack calls.
local function pressBack(world, data)
    g_localPlayer:setStyleAsync({ data = data }, false, function() end, false)
end

test("a look's gender is its model's, else the fallback", function()
    setup()
    assertEquals(TCWorkerAppearance.getGender(look("female.xml"), "male"), "female")
    assertEquals(TCWorkerAppearance.getGender(look("male.xml"), "female"), "male")
    assertEquals(TCWorkerAppearance.getGender(look("gone.xml"), "female"), "female", "model not installed")
    assertEquals(TCWorkerAppearance.getGender(look("odd.xml"), "male"), "male", "not one of our genders")
    assertEquals(TCWorkerAppearance.getGender(nil, "male"), "male")
end)

test("looks compare by model, item and colour", function()
    setup()
    assertTrue(TCWorkerAppearance.isSameLook(look("male.xml", "short"), look("male.xml", "short")))
    assertTrue(not TCWorkerAppearance.isSameLook(look("male.xml", "short"), look("female.xml", "short")))
    assertTrue(not TCWorkerAppearance.isSameLook(look("male.xml", "short"), look("male.xml", "long")))
    local recoloured = look("male.xml", "short")
    recoloured.configs.hairStyle.color = 3
    assertTrue(not TCWorkerAppearance.isSameLook(look("male.xml", "short"), recoloured))
    local noHair = { model = "male.xml", configs = {} }
    assertTrue(not TCWorkerAppearance.isSameLook(look("male.xml", "short"), noHair), "a slot missing on one side")
    assertTrue(TCWorkerAppearance.isSameLook(nil, nil))
    assertTrue(not TCWorkerAppearance.isSameLook(nil, look("male.xml")))
end)

test("the wardrobe opens on the worker's look, not the player's", function()
    local world = setup()
    local workerLook = look("female.xml", "bob")
    assertTrue(TCWardrobe.open(workerLook, function() end))

    assertEquals(g_gui.currentGuiName, "WardrobeScreen")
    assertEquals(world.screen.currentPlayerStyle.data, workerLook)
    assertEquals(world.screen.temporaryPlayerStyle.data, workerLook)
    assertEquals(world.screen.pageUpdates, 1, "pages told about the new style")
    assertTrue(world.screen.isCharacterDirty, "preview rebuilt")
end)

test("Back hands the look back and leaves the player's alone", function()
    local world = setup()
    local confirmed = nil
    TCWardrobe.open(look("female.xml", "bob"), function(data)
        confirmed = data
        g_gui:showGui("InGameMenu")
    end)

    local edited = look("male.xml", "mohawk")
    pressBack(world, edited)

    assertEquals(confirmed, edited)
    assertEquals(#world.playerStyleSets, 0, "player's look not set")
    assertEquals(world.screen.poppedToRoot, 1, "out of the colour picker first")
    assertEquals(world.screen.exited, 0, "the menu's reopen closed it")
    assertEquals(g_gui.currentGuiName, "InGameMenu")
    assertEquals(TCWardrobe.session, nil)
    assertEquals(rawget(g_localPlayer, "setStyleAsync"), nil, "player's own function back")
end)

test("if nothing else opens, Back leaves the wardrobe the vanilla way", function()
    local world = setup()
    TCWardrobe.open(look("female.xml", "bob"), function() end)
    pressBack(world, look("male.xml", "mohawk"))
    assertEquals(world.screen.exited, 1)
    assertEquals(g_gui.currentGuiName, "")
end)

test("the player's own wardrobe is untouched outside a session", function()
    local world = setup()
    pressBack(world, look("male.xml", "own"))
    assertEquals(#world.playerStyleSets, 1)

    -- A session's shadow passes through when the wardrobe isn't showing.
    TCWardrobe.open(look("female.xml", "bob"), function()
        error("not confirmed from outside the wardrobe")
    end)
    g_gui.currentGuiName = "InGameMenu"
    pressBack(world, look("male.xml", "other"))
    assertEquals(#world.playerStyleSets, 2)
end)

test("Change Name is hidden for a worker and back afterwards", function()
    local world = setup()
    local buttons = world.screen.pageCharacter.menuButtonInfo
    TCWardrobe.open(look("female.xml", "bob"), function() end)
    assertEquals(#buttons, 2)
    for _, info in ipairs(buttons) do
        assertTrue(info ~= world.nicknameButton, "nickname button still on the bar")
    end

    pressBack(world, look("male.xml", "mohawk"))
    assertEquals(#buttons, 3)
    assertEquals(buttons[3], world.nicknameButton)
end)

test("closing the wardrobe any other way ends the session", function()
    local world = setup()
    local confirmed = false
    TCWardrobe.open(look("female.xml", "bob"), function()
        confirmed = true
    end)

    g_gui:changeScreen(nil, nil)

    assertEquals(world.closes, 1, "vanilla's own close still runs")
    assertEquals(TCWardrobe.session, nil)
    assertEquals(#world.screen.pageCharacter.menuButtonInfo, 3)
    assertEquals(rawget(g_localPlayer, "setStyleAsync"), nil)
    assertTrue(not confirmed)

    -- The player's wardrobe afterwards sets the player's look.
    g_gui:changeScreen(nil, WardrobeScreen)
    pressBack(world, look("male.xml", "own"))
    assertEquals(#world.playerStyleSets, 1)
end)

test("installing twice doesn't stack the close hook", function()
    local world = setup()
    TCWardrobe.install()
    TCWardrobe.open(look("female.xml", "bob"), function() end)
    g_gui:changeScreen(nil, nil)
    assertEquals(world.closes, 1)
end)

test("no wardrobe, or a look that won't build, doesn't open", function()
    local world = setup()
    local broken = look("male.xml")
    broken.isBroken = true
    assertTrue(not TCWardrobe.open(broken, function() end))
    assertEquals(g_gui.currentGuiName, "InGameMenu")

    Platform.hasWardrobe = false
    assertTrue(not TCWardrobe.isAvailable())
    assertTrue(not TCWardrobe.open(look("male.xml"), function() end))
    assertEquals(TCWardrobe.session, nil)
    assertEquals(#world.screen.pageCharacter.menuButtonInfo, 3)
end)
