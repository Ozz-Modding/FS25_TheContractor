-- Editing a worker's look in the vanilla wardrobe (077). TCEditWorkerDialog's
-- Wardrobe button opens WardrobeScreen on the worker's look, and the
-- wardrobe's Back hands the confirmed look back instead of putting it on
-- the player.
--
-- WardrobeScreen only touches the local player in two places: onOpen copies
-- g_localPlayer's style into currentPlayerStyle/temporaryPlayerStyle (every
-- page works on those two), and onButtonBack gives currentPlayerStyle to
-- g_localPlayer:setStyleAsync, whose callback saves it to the game settings
-- and exits. Neither can be hooked on the class: loadGui copies onOpen and
-- onClose into the screen element, and TabbedMenu captures onButtonBack in
-- a closure that every way back (button, Esc, gamepad) shares. So:
-- - the worker's style is swapped in right after changeScreen, which runs
--   onOpen synchronously;
-- - for the session, the local player's setStyleAsync is shadowed by an
--   instance field that takes the look while the wardrobe is the current
--   GUI, and is the real function for anything else;
-- - the Character page's Change Name button (it renames the player) is
--   taken off its bar;
-- - the screen element's onCloseCallback is wrapped so a session can't
--   outlive the screen, however it closes.
--
-- Client-side and local only: the look comes back as appearance data in the
-- dialog's draft, and Save sends it through 066's TCEditWorkerEvent.

TCWardrobe = {}

TCWardrobe.GUI_NAME = "WardrobeScreen"

-- The open session: { onConfirmed(data), player, hadOwnSetStyle,
-- ownSetStyle, nicknameButton, nicknameButtonIndex }.
TCWardrobe.session = nil

local function getScreen()
    if WardrobeScreen == nil or g_gui == nil or g_gui.screenControllers == nil then
        return nil
    end
    return g_gui.screenControllers[WardrobeScreen]
end

-- Whether this platform has the wardrobe (not mobile) and it's loaded.
function TCWardrobe.isAvailable()
    return Platform ~= nil and Platform.hasWardrobe == true and getScreen() ~= nil
end

local function onScreenClosed()
    TCWardrobe.endSession()
end

-- loadMap: no session carried over, and the close hook on the screen
-- element (guarded so it can't stack across loads).
function TCWardrobe.install()
    TCWardrobe.endSession()

    local element = g_gui ~= nil and WardrobeScreen ~= nil and g_gui.screens[WardrobeScreen] or nil
    if element == nil then
        return
    end
    if element.tcOriginalOnCloseCallback == nil then
        element.tcOriginalOnCloseCallback = element.onCloseCallback or false
    end
    local original = element.tcOriginalOnCloseCallback or nil
    element.onCloseCallback = function(...)
        if original ~= nil then
            original(...)
        end
        onScreenClosed()
    end
end

local function hideNicknameButton(session, screen)
    local page = screen.pageCharacter
    if page == nil or page.menuButtonInfo == nil or page.nicknameButtonInfo == nil then
        return
    end
    for index, info in ipairs(page.menuButtonInfo) do
        if info == page.nicknameButtonInfo then
            table.remove(page.menuButtonInfo, index)
            session.nicknameButton = info
            session.nicknameButtonIndex = index
            return
        end
    end
end

local function restoreNicknameButton(session, screen)
    local page = screen ~= nil and screen.pageCharacter or nil
    if session.nicknameButton == nil or page == nil or page.menuButtonInfo == nil then
        return
    end
    local index = math.min(session.nicknameButtonIndex, #page.menuButtonInfo + 1)
    table.insert(page.menuButtonInfo, index, session.nicknameButton)
end

local function shadowSetStyle(session, player)
    session.player = player
    session.hadOwnSetStyle = rawget(player, "setStyleAsync") ~= nil
    session.ownSetStyle = rawget(player, "setStyleAsync")
    local realSetStyle = player.setStyleAsync
    player.setStyleAsync = function(target, style, ...)
        if TCWardrobe.session == session and g_gui.currentGuiName == TCWardrobe.GUI_NAME then
            TCWardrobe.confirm(style)
            return
        end
        return realSetStyle(target, style, ...)
    end
end

local function restoreSetStyle(session)
    if session.player == nil then
        return
    end
    if session.hadOwnSetStyle then
        session.player.setStyleAsync = session.ownSetStyle
    else
        session.player.setStyleAsync = nil
    end
end

-- Opens the wardrobe on `appearance`. onConfirmed(data) gets the look the
-- player confirmed, as appearance data, once the wardrobe has closed (it's
-- free to open other GUIs). Returns false if it couldn't open.
function TCWardrobe.open(appearance, onConfirmed)
    local screen = getScreen()
    local style = TCWorkerAppearance.toPlayerStyle(appearance)
    if not TCWardrobe.isAvailable() or style == nil or g_localPlayer == nil then
        return false
    end

    TCWardrobe.endSession()
    local session = { onConfirmed = onConfirmed }
    TCWardrobe.session = session
    hideNicknameButton(session, screen)
    shadowSetStyle(session, g_localPlayer)

    g_gui:changeScreen(nil, WardrobeScreen)
    if g_gui.currentGuiName ~= TCWardrobe.GUI_NAME or screen.currentPlayerStyle == nil then
        TCWardrobe.endSession()
        return false
    end

    -- onOpen has just loaded the player's own look into both: the worker's
    -- replaces it before the first update builds the preview.
    screen.currentPlayerStyle:copyFrom(style)
    screen.temporaryPlayerStyle:copyFrom(style)
    screen:updatePagePlayerStyle()
    screen.isCharacterDirty = true
    if screen.updateBrandIcon ~= nil then
        screen:updateBrandIcon()
    end
    return true
end

-- The wardrobe's Back, in place of putting the look on the player.
function TCWardrobe.confirm(style)
    local session = TCWardrobe.session
    if session == nil then
        return
    end

    local data = TCWorkerAppearance.toData(style)
    TCWardrobe.endSession()

    -- What exitMenu does first: out of the colour picker, if it's open.
    local screen = getScreen()
    if screen ~= nil and screen.popToRoot ~= nil then
        screen:popToRoot()
    end
    session.onConfirmed(data)
    -- onConfirmed normally opens the menu, which closes the wardrobe. If it
    -- didn't, leave the way vanilla would.
    if screen ~= nil and g_gui.currentGuiName == TCWardrobe.GUI_NAME then
        screen:exitMenu()
    end
end

-- Puts everything back. Safe to call with no session open.
function TCWardrobe.endSession()
    local session = TCWardrobe.session
    if session == nil then
        return
    end
    TCWardrobe.session = nil
    restoreSetStyle(session)
    restoreNicknameButton(session, getScreen())
end
