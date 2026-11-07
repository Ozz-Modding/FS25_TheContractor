-- An auction lot's card (138), opened from the "View lot" prompt
-- (TCAuctionLotActivatable). The lot's number, store image and name, its
-- hours and age; the guide price, large, since it's what a bid is judged
-- from; when bidding on it closes;
-- the farm's own bid; and after the close, what became of it. Its shop
-- specifications (power, top speed, tank, working width, ...) come from
-- vanilla's own shop display (ShopController:makeDisplayItem, as UEY's
-- barter dialog and the garage show them), less condition (never on a lot's
-- card, 099) and the hours and age the card shows already. Everything
-- comes from the site's synced lots (TheContractorAuctionSite:getLot) and
-- the farm's own bids (TheContractorAuctionSale), the same the menu's
-- catalogue shows, so the two always agree. Never anything ADS knows (099),
-- another farm's bid or the room's.
--
-- 139: Bid / Change bid and Withdraw bid in the bar while the lot's open.
-- The bid's picked on the card, left and right through the guide's
-- percentages (AuctionSale.getBidSteps: no typing, the same on a gamepad),
-- and sent (AuctionSale:requestBid); the card shows it once the server's
-- answer lands. It warns, but never
-- stops, when the farm's open bids come to more than it has.
--
-- Re-read every REFRESH_MS while open, so the state turns to closed at the
-- lot's time; closes itself if the lot goes (the site's cleared).

TCAuctionLotDialog = {}
local TCAuctionLotDialog_mt = Class(TCAuctionLotDialog, MessageDialog)

TCAuctionLotDialog.REFRESH_MS = 1000

-- Defined before any function that uses it: a local declared further down
-- is a nil global to the functions above it.
local function formatMoney(amount)
    return g_i18n:formatMoney(amount or 0, 0, true, true)
end

function TCAuctionLotDialog.register()
    local dialog = TCAuctionLotDialog.new()
    g_gui:loadGui(TheContractor.dir .. "src/gui/TCAuctionLotDialog.xml", "TCAuctionLotDialog", dialog)
    TCAuctionLotDialog.INSTANCE = dialog
end

function TCAuctionLotDialog.show(lotNumber)
    local dialog = TCAuctionLotDialog.INSTANCE
    if dialog == nil then
        return
    end
    dialog.lotNumber = lotNumber
    dialog.vehicleId = nil
    g_gui:showDialog("TCAuctionLotDialog")
end

function TCAuctionLotDialog.new(target, customMt)
    local self = MessageDialog.new(target, customMt or TCAuctionLotDialog_mt)
    self.lotNumber = nil
    -- The lot's vehicle when it opened: a lot of the same number at another
    -- auction isn't this one.
    self.vehicleId = nil
    self.refreshMs = 0
    return self
end

function TCAuctionLotDialog:onGuiSetupFinished()
    TCAuctionLotDialog:superClass().onGuiSetupFinished(self)

    for _, id in ipairs({ "dialogTitleElement", "lotImage", "nameText", "hoursText", "ageText", "stateChip",
            "stateChipText", "guideText", "closesText", "yourBidText", "noteText", "buttonBox",
            "bidButton", "bidSeparator", "withdrawButton", "withdrawSeparator", "specsLayout", "specTemplate",
            "bidRow", "bidOption" }) do
        self[id] = self:getDescendantById(id)
    end
    self.specElements = {}
end

-- The shop's spec types the card leaves out: condition (vanilla's, or ADS's
-- once ADS has a lot: never shown, 099), and the hours and age it shows in
-- its own rows.
TCAuctionLotDialog.HIDDEN_SPECS = { "wearable", "operatingTime", "age" }

-- A lot's specifications as the shop shows them: { { profile, value } }, its
-- machine's own configurations when it's streamed in, the store's default
-- ones until then. Empty without the shop's display (nil-checked).
function TCAuctionLotDialog.getSpecs(lot)
    local storeItem = g_storeManager:getItemByXMLFilename(lot.xmlFilename)
    if storeItem == nil or g_shopController == nil or g_shopController.makeDisplayItem == nil then
        return {}
    end
    local vehicle = lot.vehicleId ~= nil and NetworkUtil.getObject(lot.vehicleId) or nil
    if vehicle ~= nil and (vehicle.isDeleted or vehicle.configurations == nil) then
        vehicle = nil
    end
    local displayItem = g_shopController:makeDisplayItem(storeItem, vehicle,
        vehicle ~= nil and vehicle.configurations or nil)
    if displayItem == nil or displayItem.attributeIconProfiles == nil then
        return {}
    end
    local hidden = {}
    for _, name in ipairs(TCAuctionLotDialog.HIDDEN_SPECS) do
        local specType = g_storeManager.getSpecTypeByName ~= nil and g_storeManager:getSpecTypeByName(name) or nil
        if specType ~= nil and specType.profile ~= nil then
            hidden[specType.profile] = true
        end
    end
    local specs = {}
    for i, profile in ipairs(displayItem.attributeIconProfiles) do
        local value = displayItem.attributeValues[i]
        if not hidden[profile] and value ~= nil then
            table.insert(specs, { profile = profile, value = value })
        end
    end
    return specs
end

-- The specifications strip, once per lot (UEY's BarterDialog way: the
-- template cloned per spec, sized to its text).
function TCAuctionLotDialog:showSpecs(lot)
    for _, element in ipairs(self.specElements) do
        element:delete()
    end
    self.specElements = {}
    if self.specsLayout == nil or self.specTemplate == nil then
        return
    end
    for _, spec in ipairs(TCAuctionLotDialog.getSpecs(lot)) do
        local element = self.specTemplate:clone(self.specsLayout)
        table.insert(self.specElements, element)
        local icon = element:getDescendantByName("icon")
        if icon ~= nil then
            icon:applyProfile(spec.profile)
        end
        local text = element:getDescendantByName("text")
        if text ~= nil then
            text:setText(spec.value)
        end
        element:setVisible(true)
        if icon ~= nil and text ~= nil then
            element:setSize(text.size[1] + icon.size[1] + 0.0025, text.size[2])
        end
    end
    self.specsLayout:invalidateLayout()
end

function TCAuctionLotDialog:onOpen()
    TCAuctionLotDialog:superClass().onOpen(self)
    self.refreshMs = 0
    self.specsShownFor = nil
    self.bidStepsFor = nil
    self:refresh()
end

-- The picker's bids for a lot, set at the farm's bid (or the guide) when
-- the lot's opened; after that it stays where the player leaves it.
function TCAuctionLotDialog:updateBidSteps(lot, farmId)
    local key = lot.number .. ":" .. tostring(lot.vehicleId)
    if self.bidStepsFor == key then
        return
    end
    self.bidStepsFor = key
    self.bidSteps = TheContractorAuctionSale.getBidSteps(lot.guidePrice)
    local texts = {}
    for i, step in ipairs(self.bidSteps) do
        texts[i] = string.format(g_i18n:getText("tc_auctionLot_bidStep"), formatMoney(step.amount), step.percent)
    end
    self.bidOption:setTexts(texts)
    local bid = g_currentMission.TheContractor.AuctionSale:getFarmBid(lot.number, farmId)
    self.bidOption:setState(TheContractorAuctionSale.getNearestStep(self.bidSteps,
        bid ~= nil and bid.amount or lot.guidePrice))
end

function TCAuctionLotDialog:update(dt)
    TCAuctionLotDialog:superClass().update(self, dt)
    self.refreshMs = self.refreshMs + dt
    if self.refreshMs >= TCAuctionLotDialog.REFRESH_MS then
        self.refreshMs = 0
        self:refresh()
    end
end

function TCAuctionLotDialog:getLot()
    local tc = g_currentMission.TheContractor
    local site = tc ~= nil and tc.AuctionSite or nil
    local lot = site ~= nil and self.lotNumber ~= nil and site:getLot(self.lotNumber) or nil
    if lot == nil or (self.vehicleId ~= nil and lot.vehicleId ~= self.vehicleId) then
        return nil
    end
    return lot
end

-- The tone of each display state's chip (AuctionSale.DISPLAY), on the card
-- and in the catalogue.
TCAuctionLotDialog.STATE_TONES = {
    open = "good",
    yourBid = "info",
    closed = "neutral",
    sold = "neutral",
    won = "good",
    outbid = "warn",
    unpaid = "bad",
}

-- The farm's view of a lot: its display state, the chip's text and tone.
function TCAuctionLotDialog.getState(lot, farmId)
    local state = g_currentMission.TheContractor.AuctionSale:getDisplayState(lot, farmId)
    return state, g_i18n:getText("tc_auctionLot_state_" .. state), TCAuctionLotDialog.STATE_TONES[state] or "neutral"
end

-- The farm's own bid, or that it has none.
function TCAuctionLotDialog.getYourBidText(lot, farmId)
    local bid = g_currentMission.TheContractor.AuctionSale:getFarmBid(lot.number, farmId)
    if bid == nil then
        return g_i18n:getText("tc_auctionLot_noBid")
    end
    return string.format(g_i18n:getText("tc_auctionLot_yourBid"), formatMoney(bid.amount))
end

-- Under the bid: after the close, what became of it; before, a warning when
-- the farm's open bids come to more than it has. nil for nothing to say.
function TCAuctionLotDialog.getNoteText(lot, farmId, state)
    local sale = g_currentMission.TheContractor.AuctionSale
    local D = TheContractorAuctionSale.DISPLAY
    local bid = sale:getFarmBid(lot.number, farmId)
    if state == D.WON then
        return string.format(g_i18n:getText("tc_auctionLot_noteWon"), formatMoney(bid ~= nil and bid.paid or 0))
    elseif state == D.OUTBID then
        return g_i18n:getText("tc_auctionLot_noteOutbid")
    elseif state == D.UNPAID then
        return string.format(g_i18n:getText("tc_auctionLot_noteUnpaid"), formatMoney(bid ~= nil and bid.fee or 0))
    elseif state == D.SOLD then
        return g_i18n:getText("tc_auctionLot_noteSold")
    elseif state == D.CLOSED then
        return g_i18n:getText("tc_auctionLot_noteClosed")
    end
    local farm = g_farmManager:getFarmById(farmId)
    local total = sale:getOpenBidsTotal(farmId)
    if farm ~= nil and total > farm:getBalance() then
        return string.format(g_i18n:getText("tc_auctionLot_noteOverBalance"), formatMoney(total),
            formatMoney(farm:getBalance()))
    end
    return nil
end

function TCAuctionLotDialog:refresh()
    local lot = self:getLot()
    if lot == nil then
        self:close()
        return
    end
    self.vehicleId = lot.vehicleId
    local farmId = g_currentMission:getFarmId()
    -- Once per lot opened (and again once its machine's streamed in, for
    -- its own configurations).
    local specsKey = lot.number .. ":" .. tostring(lot.vehicleId ~= nil and NetworkUtil.getObject(lot.vehicleId) ~= nil)
    if self.specsShownFor ~= specsKey then
        self.specsShownFor = specsKey
        self:showSpecs(lot)
    end

    self.dialogTitleElement:setText(string.format(g_i18n:getText("tc_auctionLot_title"), lot.number))
    local storeItem = g_storeManager:getItemByXMLFilename(lot.xmlFilename)
    local hasImage = storeItem ~= nil and storeItem.imageFilename ~= nil
    self.lotImage:setVisible(hasImage)
    -- Set once per lot, not on every refresh.
    if hasImage and self.shownImage ~= storeItem.imageFilename then
        self.shownImage = storeItem.imageFilename
        self.lotImage:setImageFilename(storeItem.imageFilename)
        self.lotImage:setImageUVs(nil, unpack(Overlay.DEFAULT_UVS))
    end
    self.nameText:setText(TheContractorAuctionSite.getLotName(lot))
    self.hoursText:setText(TCAuctionLotDialog.formatHours(lot.hours))
    self.ageText:setText(TCAuctionLotDialog.formatAge(lot.ageMonths))
    self.guideText:setText(formatMoney(lot.guidePrice))
    self.closesText:setText(string.format(g_i18n:getText("tc_auctionLot_closes"),
        TheContractorAuctionSite.formatCloseTime(lot.closeMinute)))
    self.yourBidText:setText(TCAuctionLotDialog.getYourBidText(lot, farmId))

    local state, chipText, tone = TCAuctionLotDialog.getState(lot, farmId)
    self.stateChip:setVisible(true)
    self.stateChipText:setVisible(true)
    self.stateChip.color = MenuContractor.CHIP_COLORS[tone]
    self.stateChipText:setText(chipText)
    self.noteText:setText(TCAuctionLotDialog.getNoteText(lot, farmId, state) or "")

    -- Bidding's open: the picker, Bid (or Change bid), and Withdraw once
    -- there's a bid.
    local D = TheContractorAuctionSale.DISPLAY
    local isOpen = state == D.OPEN or state == D.YOUR_BID
    local hasBid = state == D.YOUR_BID
    self:updateBidSteps(lot, farmId)
    self.bidRow:setVisible(isOpen)
    self.bidButton:setText(g_i18n:getText(hasBid and "tc_auctionLot_changeBidButton" or "tc_auctionLot_bidButton"))
    if self.bidButton:getIsVisible() ~= isOpen or self.withdrawButton:getIsVisible() ~= hasBid then
        self.bidButton:setVisible(isOpen)
        self.bidSeparator:setVisible(isOpen)
        self.withdrawButton:setVisible(hasBid)
        self.withdrawSeparator:setVisible(hasBid)
        self.buttonBox:invalidateLayout()
    end
end

-- "12.4 h", as the card and the catalogue show a lot's hours.
function TCAuctionLotDialog.formatHours(hours)
    return string.format(g_i18n:getText("tc_auctionLot_hoursValue"), g_i18n:formatNumber(hours, 1))
end

-- "1 month", "14 months".
function TCAuctionLotDialog.formatAge(ageMonths)
    if ageMonths == 1 then
        return g_i18n:getText("tc_auctionLot_ageOne")
    end
    return string.format(g_i18n:getText("tc_auctionLot_ageMany"), ageMonths)
end

-- Bid / Change bid: the picker's amount, unless it's the bid already left.
function TCAuctionLotDialog:onClickBid()
    local lot = self:getLot()
    if lot == nil or not self.bidButton:getIsVisible() or self.bidSteps == nil then
        return false
    end
    local step = self.bidSteps[self.bidOption:getState()]
    local sale = g_currentMission.TheContractor.AuctionSale
    local bid = sale:getFarmBid(lot.number, g_currentMission:getFarmId())
    if step ~= nil and (bid == nil or bid.amount ~= step.amount) then
        sale:requestBid(lot.number, step.amount)
    end
    return false
end

function TCAuctionLotDialog:onClickWithdraw()
    local lot = self:getLot()
    if lot == nil or not self.withdrawButton:getIsVisible() then
        return false
    end
    local lotNumber = lot.number
    YesNoDialog.show(function(_, yes)
        if yes then
            g_currentMission.TheContractor.AuctionSale:requestBid(lotNumber, 0)
        end
    end, self, string.format(g_i18n:getText("tc_auctionLot_withdrawConfirm"), lotNumber))
    return false
end

function TCAuctionLotDialog:onClickBack()
    self:close()
    return false
end
