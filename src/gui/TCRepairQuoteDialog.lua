-- 102: the Negotiate dialog for an inspected ADS repair contract. One
-- MultiTextOption picks the margin (0 to MARGIN_MAX in MARGIN_STEP steps,
-- starting at the benchmark setting, with every step that comes to
-- MIN_PRICE folded into one "Minimum charge": getQuoteOptions), and the
-- rows follow it live: the cheapest fix's parts and wages, the price, what
-- the farm's own cheapest plan costs it (ADS's checkFarmTools, with
-- anything it can't do subcontracted at the dealer's price) and so the
-- estimated profit, and how the customer will see it. Issue quote hands it
-- to the server (TCRepairQuoteEvent); the customer answers once. Same
-- MessageDialog shape as TCAdvertisingDialog, opened from the Inbox's
-- Negotiate button, laid out with the menu's panel kit.

TCRepairQuoteDialog = {}
local TCRepairQuoteDialog_mt = Class(TCRepairQuoteDialog, MessageDialog)

-- Chips in the Missing kit row; any more upgrades share the last as "+N".
TCRepairQuoteDialog.KIT_CHIPS = 4

function TCRepairQuoteDialog.register()
    local dialog = TCRepairQuoteDialog.new()
    g_gui:loadGui(TheContractor.dir .. "src/gui/TCRepairQuoteDialog.xml", "TCRepairQuoteDialog", dialog)
    TCRepairQuoteDialog.INSTANCE = dialog
end

-- callback(target, jobId, margin) runs once the quote's been sent.
function TCRepairQuoteDialog.show(farmId, jobId, callback, target)
    local dialog = TCRepairQuoteDialog.INSTANCE
    if dialog == nil then
        return
    end

    dialog.farmId = farmId
    dialog.jobId = jobId
    dialog.callback = callback
    dialog.callbackTarget = target
    g_gui:showDialog("TCRepairQuoteDialog")
end

function TCRepairQuoteDialog.new(target, customMt)
    local self = MessageDialog.new(target, customMt or TCRepairQuoteDialog_mt)

    self.farmId = nil
    self.jobId = nil
    self.callback = nil
    self.callbackTarget = nil
    self.options = {}
    self.optionIndex = 1

    return self
end

function TCRepairQuoteDialog:onGuiSetupFinished()
    TCRepairQuoteDialog:superClass().onGuiSetupFinished(self)

    self.titleText = self:getDescendantById("dialogTitleElement")
    self.marginOption = self:getDescendantById("marginOption")
    self.partsText = self:getDescendantById("partsText")
    self.wagesText = self:getDescendantById("wagesText")
    self.costText = self:getDescendantById("costText")
    self.kitNoteText = self:getDescendantById("kitNoteText")
    self.kitChips = {}
    for i = 1, TCRepairQuoteDialog.KIT_CHIPS do
        self.kitChips[i] = { chip = self:getDescendantById("kitChip" .. i),
            chipText = self:getDescendantById("kitChipText" .. i) }
    end
    self.sendButton = self:getDescendantById("sendButton")
    -- The quote rows: a value and a chip each.
    self.rows = {}
    for _, name in ipairs({ "price", "plan", "profit", "reaction" }) do
        self.rows[name] = {
            text = self:getDescendantById(name .. "Text"),
            chip = self:getDescendantById(name .. "Chip"),
            chipText = self:getDescendantById(name .. "ChipText"),
        }
    end
end

function TCRepairQuoteDialog:getJob()
    return g_currentMission.TheContractor.Jobs:getJob(self.farmId, self.jobId)
end

-- The option nearest the benchmark (options are { margin, isMinimum }).
function TCRepairQuoteDialog.getStartIndex(options, benchmark)
    local bestIndex, bestGap = 1, nil
    for i, option in ipairs(options) do
        local gap = math.abs(option.margin - benchmark)
        if bestGap == nil or gap < bestGap - 1e-6 then
            bestIndex, bestGap = i, gap
        end
    end
    return bestIndex
end

function TCRepairQuoteDialog:onOpen()
    TCRepairQuoteDialog:superClass().onOpen(self)

    local job = self:getJob()
    local baseCost = job ~= nil and TheContractorRepairContracts.getJobBaseCost(job) or 0
    self.options = TheContractorRepairContracts.getQuoteOptions(baseCost)
    local texts = {}
    for _, option in ipairs(self.options) do
        if option.isMinimum then
            table.insert(texts, g_i18n:getText("tc_repairQuote_minimumCharge"))
        else
            table.insert(texts, string.format("%d%%", math.floor(option.margin * 100 + 0.5)))
        end
    end
    self.marginOption:setTexts(texts)
    local benchmark = job ~= nil and TheContractorRepairContracts.getJobBenchmark(job) or 0
    self.optionIndex = TCRepairQuoteDialog.getStartIndex(self.options, benchmark)
    self.marginOption:setState(self.optionIndex)

    if job ~= nil then
        self.titleText:setText(string.format(g_i18n:getText("tc_repairQuote_title"), job.workshop.vehicleName or "?"))
    end
    self:refresh()

    FocusManager:setFocus(self.marginOption)
end

function TCRepairQuoteDialog:onClickMargin(state)
    self.optionIndex = state
    self:refresh()
end

function TCRepairQuoteDialog:getMargin()
    local option = self.options[self.optionIndex]
    return option ~= nil and option.margin or 0
end

local function money(amount)
    return g_i18n:formatMoney(amount, 0, true, true)
end

-- A quote row's value and chip (the menu's chip tones; no chip for nil).
function TCRepairQuoteDialog:setRow(name, text, chipText, tone)
    local row = self.rows[name]
    row.text:setText(text or "")
    local hasChip = chipText ~= nil and chipText ~= ""
    row.chip:setVisible(hasChip)
    row.chipText:setVisible(hasChip)
    if hasChip then
        row.chip.color = MenuContractor.CHIP_COLORS[tone] or MenuContractor.CHIP_COLORS.neutral
        row.chipText:setText(chipText)
    end
end

local REACTION_TONES = { minimum = "good", fair = "good", steep = "warn", ripOff = "bad" }

-- Every row, worked out afresh: the job's synced cost and margins, and
-- ADS's live view of what the farm can do.
function TCRepairQuoteDialog:refresh()
    local job = self:getJob()
    local isReady = job ~= nil and TheContractorRepairContracts.isReadyToQuote(job)
    self.sendButton:setDisabled(not isReady)
    if job == nil then
        return
    end

    local margin = self:getMargin()
    local factor = TCEconomyScale.getFactor()
    local workshop = job.workshop
    local cheapestParts = (workshop.baseParts or workshop.partsCost or 0) * factor
    local wages = (workshop.baseLabour or 0) * factor
    local hours = workshop.laborHours or 0
    self.partsText:setText(money(cheapestParts))
    if hours > 0 then
        self.wagesText:setText(string.format(g_i18n:getText("tc_repairQuote_wagesValue"), money(wages), hours,
            money(wages / hours)))
    else
        self.wagesText:setText(money(wages))
    end
    self.costText:setText(money(TheContractorRepairContracts.getJobBaseCost(job) * factor))

    local price = TheContractorRepairContracts.getPriceForMargin(job, margin)
    local isMinimum = TheContractorRepairContracts.isJobMinimumCharge(job, margin)
    self:setRow("price", money(price), isMinimum and g_i18n:getText("tc_repairQuote_minimumCharge") or nil, "info")

    local vehicle = TheContractorRepairContracts.getVehicle(job)
    local farmPlan = vehicle ~= nil and TCADSRepairContracts.getFarmPlan(vehicle, job.farmId) or nil
    local plan = farmPlan ~= nil and farmPlan.plan or nil
    if plan ~= nil then
        local planText = string.format(g_i18n:getText("tc_repairQuote_planValue"), money(plan.partsCost))
        if plan.subcontractCost > 0 then
            self:setRow("plan", planText .. " " .. string.format(g_i18n:getText("tc_repairQuote_planSubcontract"),
                money(plan.subcontractCost)), g_i18n:getText("tc_repair_chipSubcontract"), "warn")
        elseif plan.partsCost > cheapestParts + 0.5 then
            self:setRow("plan", planText, g_i18n:getText("tc_repair_chipReplacing"), "warn")
        else
            self:setRow("plan", planText)
        end
        local profit = price - plan.partsCost - plan.subcontractCost
        self:setRow("profit", string.format(g_i18n:getText("tc_repairQuote_profitValue"), money(profit)),
            g_i18n:getText(profit < 0 and "tc_repair_chipLoss" or "tc_repair_chipProfit"), profit < 0 and "bad" or "good")
    else
        self:setRow("plan", g_i18n:getText("tc_repairQuote_planUnknown"), g_i18n:getText("tc_repair_chipUnknown"), "neutral")
        self:setRow("profit", "")
    end

    local reaction = TheContractorRepairContracts.getJobReaction(job, margin)
    self:setRow("reaction", string.format(g_i18n:getText("tc_repairQuote_reactionValue"),
            math.floor(TheContractorRepairContracts.getJobBenchmark(job) * 100 + 0.5)),
        g_i18n:getText("tc_repairQuote_reaction_" .. reaction), REACTION_TONES[reaction])

    self:refreshMissingKit(job)
end

-- The Missing kit row: a red chip per upgrade the farm lacks and a note on
-- what going without means, or a single green "None".
function TCRepairQuoteDialog:refreshMissingKit(job)
    local kit = TheContractorRepairContracts.getMissingKit(job)
    local names, tone = { g_i18n:getText("tc_repairQuote_kitNone") }, "good"
    if kit ~= nil and #kit.names > 0 then
        names, tone = kit.names, "bad"
    end
    local count = #names
    for i, slot in ipairs(self.kitChips) do
        local text = names[i]
        if i == #self.kitChips and count > i then
            text = string.format("+%d", count - i + 1)
        end
        slot.chip:setVisible(text ~= nil)
        slot.chipText:setVisible(text ~= nil)
        if text ~= nil then
            slot.chip.color = MenuContractor.CHIP_COLORS[tone]
            slot.chipText:setText(text)
        end
    end
    self.kitNoteText:setText(kit ~= nil and g_i18n:getText(kit.noteKey) or "")
end

function TCRepairQuoteDialog:onClickOk()
    local job = self:getJob()
    if job == nil or not TheContractorRepairContracts.isReadyToQuote(job) then
        return true
    end
    local margin = self:getMargin()
    g_client:getServerConnection():sendEvent(TCRepairQuoteEvent.new(self.farmId, self.jobId, margin))

    self:close()
    if self.callback ~= nil then
        self.callback(self.callbackTarget, self.jobId, margin)
    end
    return false
end

function TCRepairQuoteDialog:onClickBack()
    self:close()
    return false
end
