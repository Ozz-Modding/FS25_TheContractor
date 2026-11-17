-- Advertising purchase dialog (027): one modal replacing 012's three
-- per-level bottom-bar buttons. Two MultiTextOptions (ad level, duration in
-- periods) plus live cost / effectiveness / status lines, and a Buy button
-- that's disabled while the chosen combination can't be bought (tier locked
-- or not affordable). Campaigns stack: a running one can be extended, and
-- a new one runs alongside the others. Shape follows FS25_RealisticLivestock's
-- RLFilterConditionDialog: a MessageDialog subclass loaded once via
-- g_gui:loadGui, opened through a static show(), elements resolved by id in
-- onGuiSetupFinished. Opened from MenuContractor's Overview tab via the
-- bottom-bar Buy Advertising button, so the gamepad path is just
-- up/down between the two selectors, left/right to change them, and the
-- dialog's own accept/back buttons.

TCAdvertisingDialog = {}
local TCAdvertisingDialog_mt = Class(TCAdvertisingDialog, MessageDialog)

function TCAdvertisingDialog.register()
    local dialog = TCAdvertisingDialog.new()
    g_gui:loadGui(TheContractor.dir .. "src/gui/TCAdvertisingDialog.xml", "TCAdvertisingDialog", dialog)
    TCAdvertisingDialog.INSTANCE = dialog
end

-- callback(target) runs after a purchase request has been sent, so the
-- caller can refresh whatever it shows.
function TCAdvertisingDialog.show(farmId, callback, target)
    local dialog = TCAdvertisingDialog.INSTANCE
    if dialog == nil then
        return
    end

    dialog.farmId = farmId
    dialog.callback = callback
    dialog.callbackTarget = target
    g_gui:showDialog("TCAdvertisingDialog")
end

function TCAdvertisingDialog.new(target, customMt)
    local self = MessageDialog.new(target, customMt or TCAdvertisingDialog_mt)

    self.farmId = nil
    self.callback = nil
    self.callbackTarget = nil
    self.levelIndex = 1
    self.durationIndex = 1

    return self
end

function TCAdvertisingDialog:onGuiSetupFinished()
    TCAdvertisingDialog:superClass().onGuiSetupFinished(self)

    self.levelOption = self:getDescendantById("levelOption")
    self.durationOption = self:getDescendantById("durationOption")
    self.costText = self:getDescendantById("costText")
    self.effectText = self:getDescendantById("effectText")
    self.statusText = self:getDescendantById("statusText")
    self.buyButton = self:getDescendantById("buyButton")
end

function TCAdvertisingDialog:onOpen()
    TCAdvertisingDialog:superClass().onOpen(self)

    local advertising = g_currentMission.TheContractor.Advertising

    -- Default to the biggest level the farm has unlocked that isn't
    -- already running, or the biggest unlocked if they all are. Running
    -- ones say so in the picker (buying one extends it).
    self.levelIndex = 1
    local biggestUnlocked = 1
    local levelTexts = {}
    for i, levelDef in ipairs(TheContractorAdvertising.LEVELS) do
        local name = g_i18n:getText("tc_advertising_" .. levelDef.key)
        if advertising:isUnlocked(self.farmId, levelDef.key) then
            biggestUnlocked = i
            if advertising:isRunning(self.farmId, levelDef.key) then
                table.insert(levelTexts, string.format(g_i18n:getText("tc_advertising_dialog_levelRunning"), name))
            else
                table.insert(levelTexts, name)
                self.levelIndex = i
            end
        else
            table.insert(levelTexts, string.format(g_i18n:getText("tc_advertising_dialog_levelLocked"), name))
        end
    end
    if advertising:isRunning(self.farmId, TheContractorAdvertising.LEVELS[self.levelIndex].key) then
        self.levelIndex = biggestUnlocked
    end
    self.levelOption:setTexts(levelTexts)
    self.levelOption:setState(self.levelIndex)

    self.durationIndex = 1
    local durationTexts = {}
    for _, durationPeriods in ipairs(TheContractorAdvertising.DURATION_PERIODS) do
        table.insert(durationTexts, TCAdvertisingDialog.formatDuration(durationPeriods))
    end
    self.durationOption:setTexts(durationTexts)
    self.durationOption:setState(self.durationIndex)

    self:refresh()

    FocusManager:setFocus(self.levelOption)
end

function TCAdvertisingDialog.formatDuration(durationPeriods)
    if durationPeriods == 1 then
        return g_i18n:getText("tc_advertising_dialog_durationOne")
    end
    return string.format(g_i18n:getText("tc_advertising_dialog_durationMany"), durationPeriods)
end

-- A running campaign's time left (TheContractorAdvertising:
-- getMonthsRemaining), also used by the Overview tab.
function TCAdvertisingDialog.formatMonthsLeft(months)
    if months <= 0 then
        return g_i18n:getText("tc_advertising_endsThisMonth")
    elseif months == 1 then
        return g_i18n:getText("tc_advertising_monthLeft")
    end
    return string.format(g_i18n:getText("tc_advertising_monthsLeft"), months)
end

-- How long a new campaign would run: the months paid for, after the rest of
-- this month if it's underway (TheContractorAdvertising:
-- getExpiryAfterPurchase).
function TCAdvertisingDialog.formatRunsFor(durationPeriods)
    local duration = TCAdvertisingDialog.formatDuration(durationPeriods)
    if TheContractorAdvertising.isMonthUnderway() then
        return string.format(g_i18n:getText("tc_advertising_dialog_runsForAfterThisMonth"), duration)
    end
    return string.format(g_i18n:getText("tc_advertising_dialog_runsFor"), duration)
end

function TCAdvertisingDialog:getSelection()
    local levelDef = TheContractorAdvertising.LEVELS[self.levelIndex]
    local durationPeriods = TheContractorAdvertising.DURATION_PERIODS[self.durationIndex]
    return levelDef, durationPeriods
end

function TCAdvertisingDialog:onClickLevel(state)
    self.levelIndex = state
    self:refresh()
end

function TCAdvertisingDialog:onClickDuration(state)
    self.durationIndex = state
    self:refresh()
end

-- The other running campaigns' names, "Local Newspaper and Online Ads", or
-- nil if there are none.
function TCAdvertisingDialog.getOtherCampaignNames(advertising, farmId, levelKey)
    local names = {}
    for _, campaign in ipairs(advertising:getCampaigns(farmId)) do
        if campaign.levelKey ~= levelKey then
            table.insert(names, g_i18n:getText("tc_advertising_" .. campaign.levelKey))
        end
    end
    if #names == 0 then
        return nil
    elseif #names == 1 then
        return names[1]
    end
    local last = table.remove(names)
    return string.format(g_i18n:getText("tc_advertising_dialog_namesAnd"), table.concat(names, ", "), last)
end

-- Live cost preview, how well the campaign would work, and a status line
-- explaining what buying would do (or why it can't be bought).
function TCAdvertisingDialog:refresh()
    local advertising = g_currentMission.TheContractor.Advertising
    local farmId = self.farmId
    local levelDef, durationPeriods = self:getSelection()
    local cost = TheContractorAdvertising.getCost(levelDef.key, durationPeriods)

    self.costText:setText(string.format(g_i18n:getText("tc_advertising_dialog_cost"),
        g_i18n:formatMoney(TheContractorAdvertising.getCostPerPeriod(levelDef), 0, true, true), g_i18n:formatMoney(cost, 0, true, true)))

    -- Stacked campaigns can reach the most offers adverts can bring, past
    -- which a new one adds less, or nothing.
    local addedShare = advertising:getAddedShare(farmId, levelDef.key)
    if addedShare <= 0.005 then
        self.effectText:setText(g_i18n:getText("tc_advertising_dialog_effectNone"))
    elseif addedShare < 0.995 then
        self.effectText:setText(string.format(g_i18n:getText("tc_advertising_dialog_effectPart"),
            math.floor(addedShare * 100 + 0.5)))
    else
        self.effectText:setText(string.format(g_i18n:getText("tc_advertising_dialog_effect"),
            math.floor(advertising:getEffectiveness(farmId) * 100 + 0.5)))
    end

    local duration = TCAdvertisingDialog.formatDuration(durationPeriods)
    local otherNames = TCAdvertisingDialog.getOtherCampaignNames(advertising, farmId, levelDef.key)

    local status
    if not advertising:isUnlocked(farmId, levelDef.key) then
        status = string.format(g_i18n:getText("tc_advertising_dialog_locked"),
            g_i18n:getText("tc_reputationTier_" .. levelDef.requiredTier))
    elseif not advertising:canAfford(farmId, levelDef.key, durationPeriods) then
        status = g_i18n:getText("tc_advertising_dialog_cannotAfford")
    elseif advertising:isRunning(farmId, levelDef.key) then
        local newExpiry = advertising:getExpiryAfterPurchase(farmId, levelDef.key, durationPeriods)
        status = string.format(g_i18n:getText("tc_advertising_dialog_extends"),
            TCAdvertisingDialog.formatMonthsLeft(advertising:getMonthsRemaining(farmId, levelDef.key)), duration,
            TCAdvertisingDialog.formatMonthsLeft(TheContractorAdvertising.getMonthsUntil(newExpiry)))
    else
        status = TCAdvertisingDialog.formatRunsFor(durationPeriods)
        if otherNames ~= nil then
            status = status .. " " .. string.format(g_i18n:getText("tc_advertising_dialog_alongside"), otherNames)
        end
    end
    self.statusText:setText(status)

    self.buyButton:setDisabled(not advertising:canPurchase(farmId, levelDef.key, durationPeriods))
end

function TCAdvertisingDialog:onClickOk()
    local levelDef, durationPeriods = self:getSelection()
    if not g_currentMission.TheContractor.Advertising:canPurchase(self.farmId, levelDef.key, durationPeriods) then
        return true
    end

    g_client:getServerConnection():sendEvent(TCPurchaseAdvertisingEvent.new(self.farmId, levelDef.key,
        durationPeriods))

    self:close()
    if self.callback ~= nil then
        self.callback(self.callbackTarget)
    end
    return false
end

function TCAdvertisingDialog:onClickBack()
    self:close()
    return false
end
