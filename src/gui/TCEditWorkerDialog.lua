-- Edit worker dialog (066): rename a hired worker, change their gender and
-- re-roll their look, with the look previewed live. Opened from the Staff
-- tab's Edit button. Same MessageDialog shape as TCAdvertisingDialog.
--
-- Everything is a local draft until Save, which sends TCEditWorkerEvent;
-- Back throws it away. Looks are rolled here, on whichever machine has the
-- menu open (TCWorkerAppearance.roll only needs the wardrobe), and checked
-- again by the server. Changing gender rolls a look for it (the base model
-- depends on gender) but never touches the name - that's the player's call.
--
-- Gamepad: left/right on the gender option, the button bar for the rest.
-- The preview is a TCWorkerPortrait on the dialog's own Render element.
-- The Staff tab's portrait scene sits in the same spot in the world, so
-- the menu hides its own while this is open (MenuContractor:onClickEditWorker).

TCEditWorkerDialog = {}
local TCEditWorkerDialog_mt = Class(TCEditWorkerDialog, MessageDialog)

TCEditWorkerDialog.GENDERS = { TCWorkerAppearance.GENDER.MALE, TCWorkerAppearance.GENDER.FEMALE }

function TCEditWorkerDialog.register()
    local dialog = TCEditWorkerDialog.new()
    g_gui:loadGui(TheContractor.dir .. "src/gui/TCEditWorkerDialog.xml", "TCEditWorkerDialog", dialog)
    TCEditWorkerDialog.INSTANCE = dialog
end

-- onClosed(target) runs when the dialog closes, saved or not.
function TCEditWorkerDialog.show(worker, onClosed, target)
    local dialog = TCEditWorkerDialog.INSTANCE
    if dialog == nil then
        return
    end

    dialog.farmId = worker.farmId
    dialog.workerId = worker.id
    dialog.onClosed = onClosed
    dialog.onClosedTarget = target
    -- The draft. Never `self.name`: that's the GUI's own name for the
    -- dialog, and close() closes by it. appearance is only ever replaced,
    -- never changed in place, so sharing the worker's table is safe.
    dialog.workerName = worker.name
    dialog.gender = worker.gender
    dialog.appearance = worker.appearance
    dialog.isChanged = false
    g_gui:showDialog("TCEditWorkerDialog")
end

function TCEditWorkerDialog.new(target, customMt)
    local self = MessageDialog.new(target, customMt or TCEditWorkerDialog_mt)

    self.farmId = nil
    self.workerId = nil
    self.onClosed = nil
    self.onClosedTarget = nil
    self.workerName = nil
    self.gender = nil
    self.appearance = nil
    self.isChanged = false
    self.portrait = nil
    -- Stand-in ids for previews, counting down from -1 so they never meet
    -- a real worker's. A new one per roll makes the portrait load it.
    self.nextPreviewId = -1

    return self
end

function TCEditWorkerDialog:onGuiSetupFinished()
    TCEditWorkerDialog:superClass().onGuiSetupFinished(self)

    self.portraitRender = self:getDescendantById("portraitRender")
    self.nameText = self:getDescendantById("nameText")
    self.genderOption = self:getDescendantById("genderOption")
    self.saveButton = self:getDescendantById("saveButton")
end

function TCEditWorkerDialog:onOpen()
    TCEditWorkerDialog:superClass().onOpen(self)

    if self.portrait == nil then
        self.portrait = TCWorkerPortrait.new(self.portraitRender)
    end

    local genderTexts = {}
    local genderState = 1
    for i, gender in ipairs(TCEditWorkerDialog.GENDERS) do
        table.insert(genderTexts, g_i18n:getText("tc_editWorker_gender_" .. gender))
        if gender == self.gender then
            genderState = i
        end
    end
    self.genderOption:setTexts(genderTexts)
    self.genderOption:setState(genderState)

    -- The worker's own look first: same id as the Staff tab's portrait, but
    -- this is a separate TCWorkerPortrait, so it loads it.
    self.portrait:setWorker({ id = self.workerId, name = self.workerName, appearance = self.appearance })
    self:refresh()

    FocusManager:setFocus(self.genderOption)
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

function TCEditWorkerDialog:refresh()
    self.nameText:setText(self.workerName)
    -- Nothing to save without a look: one that's invalid can't be sent.
    self.saveButton:setDisabled(not self.isChanged or self.appearance == nil)
end

-- A new look for the draft's gender. Keeps the old one if none could be
-- made; returns whether it rolled.
function TCEditWorkerDialog:rollLook()
    local appearance = TCWorkerAppearance.roll(self.gender)
    if appearance == nil then
        return false
    end

    self.appearance = appearance
    self.isChanged = true
    self.portrait:setWorker({ id = self.nextPreviewId, name = self.workerName, appearance = appearance })
    self.nextPreviewId = self.nextPreviewId - 1
    return true
end

function TCEditWorkerDialog:onClickGender(state)
    local gender = TCEditWorkerDialog.GENDERS[state]
    if gender == nil or gender == self.gender then
        return
    end

    self.gender = gender
    self.isChanged = true
    if not self:rollLook() then
        -- The old look is the other gender's: don't let that be saved.
        self.appearance = nil
        self.portrait:setWorker(nil)
    end
    self:refresh()
end

function TCEditWorkerDialog:onClickRoll()
    self:rollLook()
    self:refresh()
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
        self.gender, self.appearance))
    self:close()
    return false
end

function TCEditWorkerDialog:onClickBack()
    self:close()
    return false
end
