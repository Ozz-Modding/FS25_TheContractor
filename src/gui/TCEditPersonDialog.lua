-- Edit person dialog (066, 111): rename a person and change their look,
-- with the look previewed live. Opened from the People tab: a hired worker
-- or office member (066, 090), or a farmer or the local official (111).
-- Same MessageDialog shape as TCAdvertisingDialog.
--
-- Everything is a local draft until Save, which sends the kind's event
-- (TCEditWorkerEvent for staff, TCEditPersonEvent for the farmers and the
-- official); Back throws it away. The look is edited in the vanilla
-- wardrobe (077, TCWardrobe): the dialog closes while it's open and the
-- menu reopens it with the draft when the wardrobe's done
-- (MenuContractor:reopenEditPerson). Gender isn't picked here: it's the
-- gender of the body chosen in the wardrobe. The server checks the look
-- again.
--
-- Gamepad: the button bar for everything.
-- The preview is a TCWorkerPortrait on the dialog's own Render element.
-- The People tab's portrait scene sits in the same spot in the world, so
-- the menu hides its own while this is open (MenuContractor:openEditPerson).

TCEditPersonDialog = {}
local TCEditPersonDialog_mt = Class(TCEditPersonDialog, MessageDialog)

-- Who's being edited: a worker or office member of the player's farm, or
-- one of the people every farm shares (a farmer or the official).
TCEditPersonDialog.KIND = {
    WORKER = "worker",
    FARMER = "farmer",
}

function TCEditPersonDialog.register()
    local dialog = TCEditPersonDialog.new()
    g_gui:loadGui(TheContractor.dir .. "src/gui/TCEditPersonDialog.xml", "TCEditPersonDialog", dialog)
    TCEditPersonDialog.INSTANCE = dialog
end

-- person: a worker (kind WORKER) or a TheContractorFarmers person (kind
-- FARMER). onClosed(target) runs when the dialog closes, saved or not
-- (including when it closes for the wardrobe). draft, if given, is the
-- unsaved edit to carry on with: { personName, appearance, isChanged }.
function TCEditPersonDialog.show(person, kind, onClosed, target, draft)
    local dialog = TCEditPersonDialog.INSTANCE
    if dialog == nil then
        return
    end

    dialog.kind = kind
    dialog.farmId = person.farmId
    dialog.personId = person.id
    dialog.originalGender = person.gender
    dialog.titleKey = "tc_editWorker_title"
    if kind == TCEditPersonDialog.KIND.FARMER then
        dialog.farmId = g_currentMission:getFarmId()
        dialog.titleKey = person.isOfficial and "tc_editPerson_titleOfficial" or "tc_editPerson_titleFarmer"
    end
    dialog.onClosed = onClosed
    dialog.onClosedTarget = target
    -- The draft. Never `self.name`: that's the GUI's own name for the
    -- dialog, and close() closes by it. appearance is only ever replaced,
    -- never changed in place, so sharing the person's table is safe.
    if draft ~= nil then
        dialog.personName = draft.personName
        dialog.appearance = draft.appearance
        dialog.isChanged = draft.isChanged
    else
        dialog.personName = person.name
        dialog.appearance = person.appearance
        dialog.isChanged = false
    end
    g_gui:showDialog("TCEditPersonDialog")
end

function TCEditPersonDialog.new(target, customMt)
    local self = MessageDialog.new(target, customMt or TCEditPersonDialog_mt)

    self.kind = nil
    self.titleKey = nil
    self.farmId = nil
    self.personId = nil
    self.originalGender = nil
    self.onClosed = nil
    self.onClosedTarget = nil
    self.personName = nil
    self.appearance = nil
    self.isChanged = false
    self.portrait = nil
    -- Stand-in ids for previews, counting down from -1 so they never meet
    -- a real person's. A new one per look makes the portrait load it.
    self.nextPreviewId = -1

    return self
end

function TCEditPersonDialog:onGuiSetupFinished()
    TCEditPersonDialog:superClass().onGuiSetupFinished(self)

    self.titleText = self:getDescendantById("dialogTitleElement")
    self.portraitRender = self:getDescendantById("portraitRender")
    self.nameText = self:getDescendantById("nameText")
    self.genderText = self:getDescendantById("genderText")
    self.saveButton = self:getDescendantById("saveButton")
    self.wardrobeButton = self:getDescendantById("wardrobeButton")
    self.wardrobeSeparator = self:getDescendantById("wardrobeSeparator")
end

function TCEditPersonDialog:onOpen()
    TCEditPersonDialog:superClass().onOpen(self)

    if self.portrait == nil then
        self.portrait = TCWorkerPortrait.new(self.portraitRender)
    end

    -- No wardrobe on this platform: renaming is all that's left.
    local hasWardrobe = TCWardrobe.isAvailable()
    self.wardrobeButton:setVisible(hasWardrobe)
    self.wardrobeSeparator:setVisible(hasWardrobe)

    self.titleText:setText(g_i18n:getText(self.titleKey))

    -- A draft's look is a stand-in, so a look from the wardrobe always
    -- loads. The person's own id may be the People tab portrait's, but this
    -- is a separate TCWorkerPortrait, so it loads it.
    local previewId = self.personId
    if self.isChanged then
        previewId = self.nextPreviewId
        self.nextPreviewId = self.nextPreviewId - 1
    end
    self.portrait:setWorker({ id = previewId, name = self.personName, appearance = self.appearance })
    self:refresh()
end

function TCEditPersonDialog:onClose()
    TCEditPersonDialog:superClass().onClose(self)

    if self.portrait ~= nil then
        self.portrait:destroy()
    end

    local onClosed, target = self.onClosed, self.onClosedTarget
    self.onClosed = nil
    self.onClosedTarget = nil
    self.appearance = nil
    if onClosed ~= nil then
        onClosed(target)
    end
end

function TCEditPersonDialog:update(dt)
    TCEditPersonDialog:superClass().update(self, dt)

    if self.portrait ~= nil then
        self.portrait:update(dt)
    end
end

function TCEditPersonDialog:getGender()
    return TCWorkerAppearance.getGender(self.appearance, self.originalGender)
end

function TCEditPersonDialog:refresh()
    self.nameText:setText(self.personName)
    self.genderText:setText(g_i18n:getText("tc_editWorker_gender_" .. self:getGender()))
    self.saveButton:setDisabled(not self.isChanged or self.appearance == nil)
end

-- 077: the dialog closes while the wardrobe's open (changeScreen closes
-- every dialog), so the draft goes with it and comes back through the menu.
function TCEditPersonDialog:onClickWardrobe()
    local menu = g_currentMission.TheContractor.MenuContractor
    local kind, personId = self.kind, self.personId
    local draft = { personName = self.personName, appearance = self.appearance, isChanged = self.isChanged }

    TCWardrobe.open(draft.appearance, function(data)
        local isRefused = TCWorkerAppearance.toPlayerStyle(data) == nil
        if not isRefused and not TCWorkerAppearance.isSameLook(data, draft.appearance) then
            draft.appearance = data
            draft.isChanged = true
        end
        menu:reopenEditPerson(kind, personId, draft)
        if isRefused then
            InfoDialog.show(g_i18n:getText("tc_editWorker_lookRefused"))
        end
    end)
    return false
end

function TCEditPersonDialog:onClickRename()
    TextInputDialog.show(function(target, text, clickOk)
        if not clickOk then
            return
        end

        local name = TheContractorStaff.cleanName(text)
        if name == nil then
            InfoDialog.show(string.format(g_i18n:getText("tc_editWorker_invalidName"),
                TheContractorStaff.NAME_MAX_LENGTH))
            return
        end
        if name ~= target.personName then
            target.personName = name
            target.isChanged = true
        end
        target:refresh()
    end, self, self.personName, g_i18n:getText("tc_editWorker_renamePrompt"), g_i18n:getText("tc_editWorker_renamePrompt"),
        TheContractorStaff.NAME_MAX_LENGTH, g_i18n:getText("tc_editWorker_rename"))
    return false
end

function TCEditPersonDialog:onClickOk()
    if not self.isChanged or self.appearance == nil then
        return true
    end

    local event
    if self.kind == TCEditPersonDialog.KIND.FARMER then
        event = TCEditPersonEvent.new(self.farmId, self.personId, self.personName, self:getGender(), self.appearance)
    else
        event = TCEditWorkerEvent.new(self.farmId, self.personId, self.personName, self:getGender(), self.appearance)
    end
    g_client:getServerConnection():sendEvent(event)
    self:close()
    return false
end

function TCEditPersonDialog:onClickBack()
    self:close()
    return false
end
