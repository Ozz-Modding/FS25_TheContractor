-- Edit worker dialog (066): rename a hired worker and change their look,
-- with the look previewed live. Opened from the Staff tab's Edit button.
-- Same MessageDialog shape as TCAdvertisingDialog.
--
-- Everything is a local draft until Save, which sends TCEditWorkerEvent;
-- Back throws it away. The look is edited in the vanilla wardrobe (077,
-- TCWardrobe): the dialog closes while it's open and the menu reopens it
-- with the draft when the wardrobe's done (MenuContractor:reopenEditWorker).
-- Gender isn't picked here: it's the gender of the body chosen in the
-- wardrobe. The server checks the look again.
--
-- Gamepad: the button bar for everything.
-- The preview is a TCWorkerPortrait on the dialog's own Render element.
-- The Staff tab's portrait scene sits in the same spot in the world, so
-- the menu hides its own while this is open (MenuContractor:openEditWorker).

TCEditWorkerDialog = {}
local TCEditWorkerDialog_mt = Class(TCEditWorkerDialog, MessageDialog)

function TCEditWorkerDialog.register()
    local dialog = TCEditWorkerDialog.new()
    g_gui:loadGui(TheContractor.dir .. "src/gui/TCEditWorkerDialog.xml", "TCEditWorkerDialog", dialog)
    TCEditWorkerDialog.INSTANCE = dialog
end

-- onClosed(target) runs when the dialog closes, saved or not (including
-- when it closes for the wardrobe). draft, if given, is the unsaved edit to
-- carry on with: { workerName, appearance, isChanged }.
function TCEditWorkerDialog.show(worker, onClosed, target, draft)
    local dialog = TCEditWorkerDialog.INSTANCE
    if dialog == nil then
        return
    end

    dialog.farmId = worker.farmId
    dialog.workerId = worker.id
    dialog.originalGender = worker.gender
    dialog.onClosed = onClosed
    dialog.onClosedTarget = target
    -- The draft. Never `self.name`: that's the GUI's own name for the
    -- dialog, and close() closes by it. appearance is only ever replaced,
    -- never changed in place, so sharing the worker's table is safe.
    if draft ~= nil then
        dialog.workerName = draft.workerName
        dialog.appearance = draft.appearance
        dialog.isChanged = draft.isChanged
    else
        dialog.workerName = worker.name
        dialog.appearance = worker.appearance
        dialog.isChanged = false
    end
    g_gui:showDialog("TCEditWorkerDialog")
end

function TCEditWorkerDialog.new(target, customMt)
    local self = MessageDialog.new(target, customMt or TCEditWorkerDialog_mt)

    self.farmId = nil
    self.workerId = nil
    self.originalGender = nil
    self.onClosed = nil
    self.onClosedTarget = nil
    self.workerName = nil
    self.appearance = nil
    self.isChanged = false
    self.portrait = nil
    -- Stand-in ids for previews, counting down from -1 so they never meet
    -- a real worker's. A new one per look makes the portrait load it.
    self.nextPreviewId = -1

    return self
end

function TCEditWorkerDialog:onGuiSetupFinished()
    TCEditWorkerDialog:superClass().onGuiSetupFinished(self)

    self.portraitRender = self:getDescendantById("portraitRender")
    self.nameText = self:getDescendantById("nameText")
    self.genderText = self:getDescendantById("genderText")
    self.saveButton = self:getDescendantById("saveButton")
    self.wardrobeButton = self:getDescendantById("wardrobeButton")
    self.wardrobeSeparator = self:getDescendantById("wardrobeSeparator")
end

function TCEditWorkerDialog:onOpen()
    TCEditWorkerDialog:superClass().onOpen(self)

    if self.portrait == nil then
        self.portrait = TCWorkerPortrait.new(self.portraitRender)
    end

    -- No wardrobe on this platform: renaming is all that's left.
    local hasWardrobe = TCWardrobe.isAvailable()
    self.wardrobeButton:setVisible(hasWardrobe)
    self.wardrobeSeparator:setVisible(hasWardrobe)

    -- A draft's look is a stand-in, so a look from the wardrobe always
    -- loads. The worker's own look is the Staff tab portrait's id, but this
    -- is a separate TCWorkerPortrait, so it loads it.
    local previewId = self.workerId
    if self.isChanged then
        previewId = self.nextPreviewId
        self.nextPreviewId = self.nextPreviewId - 1
    end
    self.portrait:setWorker({ id = previewId, name = self.workerName, appearance = self.appearance })
    self:refresh()
end

function TCEditWorkerDialog:onClose()
    TCEditWorkerDialog:superClass().onClose(self)

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

function TCEditWorkerDialog:update(dt)
    TCEditWorkerDialog:superClass().update(self, dt)

    if self.portrait ~= nil then
        self.portrait:update(dt)
    end
end

function TCEditWorkerDialog:getGender()
    return TCWorkerAppearance.getGender(self.appearance, self.originalGender)
end

function TCEditWorkerDialog:refresh()
    self.nameText:setText(self.workerName)
    self.genderText:setText(g_i18n:getText("tc_editWorker_gender_" .. self:getGender()))
    self.saveButton:setDisabled(not self.isChanged or self.appearance == nil)
end

-- 077: the dialog closes while the wardrobe's open (changeScreen closes
-- every dialog), so the draft goes with it and comes back through the menu.
function TCEditWorkerDialog:onClickWardrobe()
    local menu = g_currentMission.TheContractor.MenuContractor
    local workerId = self.workerId
    local draft = { workerName = self.workerName, appearance = self.appearance, isChanged = self.isChanged }

    TCWardrobe.open(draft.appearance, function(data)
        local isRefused = TCWorkerAppearance.toPlayerStyle(data) == nil
        if not isRefused and not TCWorkerAppearance.isSameLook(data, draft.appearance) then
            draft.appearance = data
            draft.isChanged = true
        end
        menu:reopenEditWorker(workerId, draft)
        if isRefused then
            InfoDialog.show(g_i18n:getText("tc_editWorker_lookRefused"))
        end
    end)
    return false
end

function TCEditWorkerDialog:onClickRename()
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
        if name ~= target.workerName then
            target.workerName = name
            target.isChanged = true
        end
        target:refresh()
    end, self, self.workerName, g_i18n:getText("tc_editWorker_renamePrompt"), g_i18n:getText("tc_editWorker_renamePrompt"),
        TheContractorStaff.NAME_MAX_LENGTH, g_i18n:getText("tc_editWorker_rename"))
    return false
end

function TCEditWorkerDialog:onClickOk()
    if not self.isChanged or self.appearance == nil then
        return true
    end

    g_client:getServerConnection():sendEvent(TCEditWorkerEvent.new(self.farmId, self.workerId, self.workerName,
        self:getGender(), self.appearance))
    self:close()
    return false
end

function TCEditWorkerDialog:onClickBack()
    self:close()
    return false
end
