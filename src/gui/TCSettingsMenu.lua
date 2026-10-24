-- Puts TheContractorSettings (048) into the vanilla in-game Settings page
-- under a "The Contractor" header. Adapted from FS25_RedTape's
-- RedTapeSettings.lua (RedTape.injectMenu).
--
-- Controls are cloned from vanilla ones (a multi option from the voice
-- volume row, a header from the page's existing section headers). inject()
-- runs every loadMap: it takes down anything it added last time first,
-- since the settings page can outlive a savegame.

TCSettingsMenu = {}

-- id -> the cloned MultiTextOption (or BinaryOption) for that setting.
TCSettingsMenu.controls = {}

-- Callback target for the cloned controls. Its name has to match the
-- settings page's, or the focus manager ignores the controls as belonging
-- to another screen.
TCSettingsControls = {}

function TCSettingsControls.onMenuOptionChanged(self, state, menuOption)
    local id = menuOption.id
    local definition = TheContractorSettings.DEFINITIONS[id]
    if definition == nil or definition.values[state] == nil then
        return
    end

    local settings = g_currentMission.TheContractor.Settings
    if TheContractorSettings.isLocalItem(id) then
        -- 086: this machine's own, never sent.
        settings:setLocal(id, definition.values[state])
        return
    end
    settings:set(id, definition.values[state])
    g_client:getServerConnection():sendEvent(TCSettingsEvent.new())
end

-- clone() copies focus ids, which have to be unique.
local function updateFocusIds(element)
    if element == nil then
        return
    end
    element.focusId = FocusManager:serveAutoFocusId()
    for _, child in pairs(element.elements) do
        updateFocusIds(child)
    end
end

function TCSettingsMenu.getSettingsPage()
    local inGameMenu = g_gui.screenControllers[InGameMenu]
    return inGameMenu ~= nil and inGameMenu.pageSettings or nil
end

function TCSettingsMenu.inject()
    local settingsPage = TCSettingsMenu.getSettingsPage()
    if settingsPage == nil then
        Logging.warning("TheContractor: settings page not found, settings not added to the menu")
        return
    end

    TCSettingsMenu.removeInjected(settingsPage)
    TCSettingsMenu.controls = {}
    settingsPage.tcInjectedElements = {}

    TCSettingsControls.name = settingsPage.name

    TCSettingsMenu.addSectionHeader(settingsPage, g_i18n:getText("tc_settings_header"))
    for _, id in ipairs(TheContractorSettings.ITEMS) do
        TCSettingsMenu.addOption(settingsPage, id)
    end
    for _, id in ipairs(TheContractorSettings.LOCAL_ITEMS) do
        TCSettingsMenu.addOption(settingsPage, id)
    end
    settingsPage.gameSettingsLayout:invalidateLayout()

    TCSettingsMenu.installHooks()
end

-- Takes down the header and option rows a previous inject() added.
function TCSettingsMenu.removeInjected(settingsPage)
    for _, element in ipairs(settingsPage.tcInjectedElements or {}) do
        if element.parent ~= nil then
            element.parent:removeElement(element)
        end
        element:delete()
    end
    settingsPage.tcInjectedElements = nil
end

function TCSettingsMenu.addSectionHeader(settingsPage, text)
    local layout = settingsPage.gameSettingsLayout
    local header = nil
    for _, element in ipairs(layout.elements) do
        if element.name == "sectionHeader" then
            header = element:clone(layout)
            break
        end
    end
    if header == nil then
        header = TextElement.new()
        header:applyProfile("fs25_settingsSectionHeader", true)
        header.name = "sectionHeader"
        layout:addElement(header)
    end

    header:setText(text)
    header.focusId = FocusManager:serveAutoFocusId()
    table.insert(settingsPage.tcInjectedElements, header)
    -- Handed to the focus manager with the options, or up/down can't skip
    -- over it.
    TCSettingsMenu.controls.tcSectionHeader = header
end

function TCSettingsMenu.addOption(settingsPage, id)
    local definition = TheContractorSettings.DEFINITIONS[id]
    -- A setting that only means something with another mod (adsMargin).
    if definition.isShown ~= nil and not definition.isShown() then
        return
    end
    local isBinary = #definition.values == 2
    local originalBox = isBinary and settingsPage.checkWoodHarvesterAutoCutBox or settingsPage.multiVolumeVoiceBox

    local box = originalBox:clone(settingsPage.gameSettingsLayout)
    box.id = id .. "Box"

    local option = box.elements[1]
    option.id = id
    option.target = TCSettingsControls
    option:setCallback("onClickCallback", "onMenuOptionChanged")
    option:setDisabled(false)

    option.elements[1]:setText(g_i18n:getText("tc_toolTip_" .. id))
    box.elements[2]:setText(g_i18n:getText("tc_setting_" .. id))

    local texts = {}
    if definition.stringKeys ~= nil then
        for i, key in ipairs(definition.stringKeys) do
            texts[i] = g_i18n:getText(key)
        end
    else
        texts = { table.unpack(definition.strings) }
    end
    option:setTexts(texts)
    option:setState(TheContractorSettings.getValueIndex(id, g_currentMission.TheContractor.Settings:get(id)))

    updateFocusIds(box)
    table.insert(settingsPage.tcInjectedElements, box)
    TCSettingsMenu.controls[id] = option
end

-- Shows each control's current value, and disables it for anyone but the
-- host or an admin (local items, 086, stay open to everyone).
function TCSettingsMenu.refreshControls()
    if g_currentMission == nil or g_currentMission.TheContractor == nil then
        return
    end

    local settings = g_currentMission.TheContractor.Settings
    local canChange = TheContractorSettings.getCanLocalPlayerChange()
    for _, id in ipairs(TheContractorSettings.ITEMS) do
        local option = TCSettingsMenu.controls[id]
        if option ~= nil then
            option:setState(TheContractorSettings.getValueIndex(id, settings:get(id)))
            option:setDisabled(not canChange)
        end
    end
    for _, id in ipairs(TheContractorSettings.LOCAL_ITEMS) do
        local option = TCSettingsMenu.controls[id]
        if option ~= nil then
            option:setState(TheContractorSettings.getValueIndex(id, settings:get(id)))
            option:setDisabled(false)
        end
    end
end

-- Focus registration has to wait until the settings page is shown (earlier
-- seems to fail, per RedTape).
function TCSettingsMenu.onFocusSetGui(gui)
    if gui ~= "ingameMenuSettings" then
        return
    end

    for _, control in pairs(TCSettingsMenu.controls) do
        if not control.focusId or not FocusManager.currentFocusData.idToElementMapping[control.focusId] then
            if not FocusManager:loadElementFromCustomValues(control, nil, nil, false, false) then
                Logging.warning("TheContractor: could not register settings control %s with the focus manager",
                    tostring(control.id or control.name or control.focusId))
            end
        end
    end
    -- Re-run layout so the focus manager works out up/down links again.
    local settingsPage = TCSettingsMenu.getSettingsPage()
    if settingsPage ~= nil then
        settingsPage.gameSettingsLayout:invalidateLayout()
    end
end

function TCSettingsMenu.installHooks()
    if not InGameMenuSettingsFrame.tcSettingsHookInstalled then
        InGameMenuSettingsFrame.onFrameOpen = Utils.appendedFunction(InGameMenuSettingsFrame.onFrameOpen, function()
            TCSettingsMenu.refreshControls()
        end)
        InGameMenuSettingsFrame.tcSettingsHookInstalled = true
    end

    if not FocusManager.tcSettingsHookInstalled then
        FocusManager.setGui = Utils.appendedFunction(FocusManager.setGui, function(_, gui)
            TCSettingsMenu.onFocusSetGui(gui)
        end)
        FocusManager.tcSettingsHookInstalled = true
    end
end
