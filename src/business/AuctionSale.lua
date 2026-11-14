-- Auction bids and the sale (139): a timed sale, not a ring. A farm views a
-- lot (138's card), judges a bid from its guide price and leaves it on the
-- lot; each lot's bidding closes at its own time between 17:00 and 18:00
-- (AuctionSite.getCloseMinute), and the server settles it then.
--
--   Bids (server): one per farm per lot, at least MIN_BID_RATIO of the
--     guide, raised, lowered or withdrawn until the lot closes
--     (TCAuctionBidEvent: the client asks, the server checks and applies).
--     Sealed: the winner pays what they bid. By farm, not company: anyone
--     can bid. A farm's bids go to that farm's players only
--     (TCAuctionBidsEvent, broadcastEventToFarm), again when a player joins
--     or changes farm.
--   The room (server only): each lot has one hidden local bid, from a roll
--     made when the lots are rolled (AuctionSite's localRoll, saved, never
--     streamed) through WIN_CURVE's inverse, so a bid of the guide price
--     beats it about 85% of the time, more over it, less under.
--   The close (server): every game minute, and on a day or hour change (a
--     sleep, a load), each lot past its closing time is settled. The highest
--     farm bid above the local bid wins and pays its bid; two the same, the
--     earlier. Money's checked then: a farm that can't pay its bid loses
--     the lot to the next and pays UNPAID_FEE (scaleCost). Nobody above the
--     local bid: a local buyer has it. No buyer's premium (the user's call):
--     the winner pays exactly what they bid.
--   The winner pays through addMoney (tcAuctionPurchase), the lot becomes
--     theirs (setOwnerFarmId), unlocked and out of the site's lot list, and
--     with a company gets an inbox message (Show on map, client only).
--     Every bidder's players get a notification. Everyone sees only that the
--     lot's sold (AuctionSite's public result), never to whom or for what.
--   After the sale (Auctions' collection, 18:00 to midnight): at midnight
--     the auction's over and everything left goes, but a lot a farm won and
--     left on the field is delivered, free (the user's calls): straight into
--     a free parking slot of the farm's (TCParking.findSpot), else to the
--     shop (findShopSpot, vanilla's reset places), else into 062's parking
--     queue to wait (whose message offers Send to shop).
--
-- Bids are kept by farm (forgetFarm, TCFarmDeletion), and only for the
-- current auction: they go when it's over or called off.

TheContractorAuctionSale = {}
TheContractorAuctionSale_mt = Class(TheContractorAuctionSale)

-- The lowest bid, as a share of the guide price.
TheContractorAuctionSale.MIN_BID_RATIO = 0.7
-- The chance a bid beats the room, by bid / guide (piecewise linear,
-- first guesses to tune). The first point is the room's floor: no local
-- bid is lower.
TheContractorAuctionSale.WIN_CURVE = {
    { 0.60, 0.00 },
    { 0.70, 0.02 },
    { 0.80, 0.15 },
    { 0.90, 0.45 },
    { 1.00, 0.85 },
    { 1.05, 0.95 },
    { 1.10, 0.99 },
    { 1.15, 1.00 },
}
-- A fixed business cost at UK rates, through Settings:scaleCost: for a won
-- lot that couldn't be paid for.
TheContractorAuctionSale.UNPAID_FEE = 250

TheContractorAuctionSale.MESSAGE_KIND = "auctionWon"

-- What became of a farm's bid.
TheContractorAuctionSale.OUTCOME = {
    WON = "won",
    LOST = "lost",
    UNPAID = "unpaid",
    DELIVERED = "delivered",
}
-- Where a delivered lot went (its notification), as the outcome sent.
TheContractorAuctionSale.DELIVERED_TO = {
    PARKING = "delivered",
    SHOP = "deliveredShop",
    WAITING = "deliveredWaiting",
}
local OUTCOME = TheContractorAuctionSale.OUTCOME

-- A lot as a farm sees it (the card's and catalogue's chip).
TheContractorAuctionSale.DISPLAY = {
    OPEN = "open",
    YOUR_BID = "yourBid",
    CLOSED = "closed",
    SOLD = "sold",
    WON = "won",
    OUTBID = "outbid",
    UNPAID = "unpaid",
}
local DISPLAY = TheContractorAuctionSale.DISPLAY

TheContractorAuctionSale.REFUSAL = {
    NO_SALE = "tc_auctionBid_refusedNoSale",
    NO_LOT = "tc_auctionBid_refusedNoLot",
    CLOSED = "tc_auctionBid_refusedClosed",
    BELOW_MINIMUM = "tc_auctionBid_refusedMinimum",
    NO_BID = "tc_auctionBid_refusedNoBid",
}
local REFUSAL = TheContractorAuctionSale.REFUSAL

table.insert(FinanceStats.statNames, "tcAuctionPurchase")
FinanceStats.statNameToIndex["tcAuctionPurchase"] = #FinanceStats.statNames

function TheContractorAuctionSale.new()
    local self = setmetatable({}, TheContractorAuctionSale_mt)

    MoneyType.TC_AUCTION_PURCHASE = MoneyType.register("tcAuctionPurchase", "tc_moneyType_auctionPurchase")
    MoneyType.LAST_ID = MoneyType.LAST_ID + 1

    -- lotNumber -> farmId -> { amount, order, outcome, paid, fee }. The
    -- server holds every farm's; a client only its own farm's (and any it
    -- was on before).
    self.bids = {}
    -- Server: ties go to the earlier bid.
    self.nextOrder = 1
    -- Client: a bid this player asked for, to say why if it was refused.
    self.pendingLotNumber = nil
    return self
end

-- Every machine, at load, before the save loads.
function TheContractorAuctionSale:register(inbox)
    inbox:registerMessageKind(TheContractorAuctionSale.MESSAGE_KIND, {
        category = "job",
        onClientAction = function(message, actionKey)
            if actionKey ~= TheContractorAuctions.SHOW_ON_MAP_ACTION.key then
                return false
            end
            local auctions = g_currentMission.TheContractor.Auctions
            if auctions ~= nil then
                auctions:showOnMap()
            end
            return true
        end,
    })
end

function TheContractorAuctionSale:startListening()
    if not g_currentMission:getIsServer() then
        return
    end
    g_messageCenter:subscribe(MessageType.MINUTE_CHANGED, self.onMinuteChanged, self)
    g_messageCenter:subscribe(MessageType.PLAYER_FARM_CHANGED, self.onPlayerFarmChanged, self)
end

function TheContractorAuctionSale:stopListening()
    if g_messageCenter ~= nil then
        g_messageCenter:unsubscribeAll(self)
    end
end

-- The room (pure) ------------------------------------------------------------------------

-- The chance a bid of this share of the guide beats the room.
function TheContractorAuctionSale.getWinChance(ratio)
    local curve = TheContractorAuctionSale.WIN_CURVE
    if ratio <= curve[1][1] then
        return curve[1][2]
    end
    for i = 2, #curve do
        local a, b = curve[i - 1], curve[i]
        if ratio <= b[1] then
            return a[2] + (b[2] - a[2]) * (ratio - a[1]) / (b[1] - a[1])
        end
    end
    return curve[#curve][2]
end

-- The curve's inverse: the room's bid, as a share of the guide, for a
-- uniform roll (0 to 1). A bid beats it with getWinChance's chance.
function TheContractorAuctionSale.getLocalBidRatio(roll)
    local curve = TheContractorAuctionSale.WIN_CURVE
    roll = math.max(0, math.min(1, roll))
    for i = 2, #curve do
        local a, b = curve[i - 1], curve[i]
        if roll <= b[2] and b[2] > a[2] then
            return a[1] + (b[1] - a[1]) * (roll - a[2]) / (b[2] - a[2])
        end
    end
    return curve[#curve][1]
end

-- Server: a lot's hidden local bid. Never streamed or shown.
function TheContractorAuctionSale.getLocalBid(lot)
    return (lot.guidePrice or 0) * TheContractorAuctionSale.getLocalBidRatio(lot.localRoll or 0.5)
end

function TheContractorAuctionSale.getMinimumBid(guidePrice)
    return math.ceil((guidePrice or 0) * TheContractorAuctionSale.MIN_BID_RATIO)
end

-- The card's bid picker runs from the minimum to this share of the guide,
-- a percent at a time. Past 1.15 the curve's certain, so a little over
-- that is as high as anyone needs.
TheContractorAuctionSale.MAX_BID_RATIO = 1.3

-- The bids the card offers (pure): { { amount, percent } }, the minimum
-- first, then each whole percent of the guide up to MAX_BID_RATIO, rounded
-- to a round figure for the guide's size (100s for a six-figure guide) and
-- never under the minimum or twice the same.
function TheContractorAuctionSale.getBidSteps(guidePrice)
    local S = TheContractorAuctionSale
    local minimum = S.getMinimumBid(guidePrice)
    local unit = 1
    if guidePrice >= 1000 then
        unit = 10 ^ (math.floor(math.log10(guidePrice)) - 3)
    end
    local steps = { { amount = minimum, percent = math.floor(S.MIN_BID_RATIO * 100 + 0.5) } }
    for percent = math.floor(S.MIN_BID_RATIO * 100 + 0.5) + 1, math.floor(S.MAX_BID_RATIO * 100 + 0.5) do
        local amount = math.floor(guidePrice * percent / 100 / unit + 0.5) * unit
        if amount > steps[#steps].amount then
            table.insert(steps, { amount = amount, percent = percent })
        end
    end
    return steps
end

-- The step nearest an amount (the farm's bid, or the guide).
function TheContractorAuctionSale.getNearestStep(steps, amount)
    local best, bestGap = 1, math.huge
    for i, step in ipairs(steps) do
        local gap = math.abs(step.amount - amount)
        if gap < bestGap then
            best, bestGap = i, gap
        end
    end
    return best
end

-- Settling a lot (pure). bids: { { farmId, amount, order } }; canPay(farmId,
-- amount) says whether the farm can pay that bid. Returns
-- the winner's farm id (nil: a local buyer), what they bid, and the farms
-- that would have won but couldn't pay, in order.
function TheContractorAuctionSale.settle(bids, localBid, canPay)
    local sorted = {}
    for _, bid in ipairs(bids) do
        table.insert(sorted, bid)
    end
    table.sort(sorted, function(a, b)
        if a.amount ~= b.amount then
            return a.amount > b.amount
        end
        return a.order < b.order
    end)
    local unpaid = {}
    for _, bid in ipairs(sorted) do
        if bid.amount <= localBid then
            break
        end
        if canPay(bid.farmId, bid.amount) then
            return bid.farmId, bid.amount, unpaid
        end
        table.insert(unpaid, bid.farmId)
    end
    return nil, nil, unpaid
end

-- Bids (every machine) --------------------------------------------------------------------

function TheContractorAuctionSale:getFarmBid(lotNumber, farmId)
    local lotBids = self.bids[lotNumber]
    return lotBids ~= nil and lotBids[farmId] or nil
end

-- lotNumber -> the farm's bid.
function TheContractorAuctionSale:getFarmBids(farmId)
    local result = {}
    for lotNumber, lotBids in pairs(self.bids) do
        if lotBids[farmId] ~= nil then
            result[lotNumber] = lotBids[farmId]
        end
    end
    return result
end

-- What the farm's open bids come to (the card warns when it's more than
-- the farm has).
function TheContractorAuctionSale:getOpenBidsTotal(farmId)
    local total = 0
    for _, bid in pairs(self:getFarmBids(farmId)) do
        if bid.outcome == nil then
            total = total + bid.amount
        end
    end
    return total
end

-- How a farm sees a lot (DISPLAY), from its synced result, its closing
-- time and the farm's own bid.
function TheContractorAuctionSale:getDisplayState(lot, farmId)
    local site = g_currentMission.TheContractor.AuctionSite
    local bid = self:getFarmBid(lot.number, farmId)
    if bid ~= nil and bid.outcome == OUTCOME.WON or bid ~= nil and bid.outcome == OUTCOME.DELIVERED then
        return DISPLAY.WON
    elseif bid ~= nil and bid.outcome == OUTCOME.UNPAID then
        return DISPLAY.UNPAID
    elseif bid ~= nil and bid.outcome == OUTCOME.LOST then
        return DISPLAY.OUTBID
    end
    if (lot.result or TheContractorAuctionSite.RESULT.OPEN) ~= TheContractorAuctionSite.RESULT.OPEN then
        return DISPLAY.SOLD
    end
    if site:getLotStateNow(lot) ~= TheContractorAuctionSite.LOT_STATE.OPEN then
        return DISPLAY.CLOSED
    end
    return bid ~= nil and DISPLAY.YOUR_BID or DISPLAY.OPEN
end

-- Why a farm can't leave this bid (amount 0 withdraws), as an l10n key, or
-- nil. lot: the public lot (nil if there's none of that number).
function TheContractorAuctionSale:getBidProblem(farmId, lot, amount)
    local site = g_currentMission.TheContractor.AuctionSite
    if site == nil or site:getSaleDay() == nil then
        return REFUSAL.NO_SALE
    end
    if lot == nil or (lot.result or 0) ~= TheContractorAuctionSite.RESULT.OPEN then
        return lot == nil and REFUSAL.NO_LOT or REFUSAL.CLOSED
    end
    if site:getLotStateNow(lot) ~= TheContractorAuctionSite.LOT_STATE.OPEN then
        return REFUSAL.CLOSED
    end
    if amount <= 0 then
        return self:getFarmBid(lot.number, farmId) == nil and REFUSAL.NO_BID or nil
    end
    if amount < TheContractorAuctionSale.getMinimumBid(lot.guidePrice) then
        return REFUSAL.BELOW_MINIMUM
    end
    return nil
end

-- Client: asks the server for a bid (0 withdraws). The answer comes back as
-- the farm's bids (TCAuctionBidsEvent); a refusal's shown then.
function TheContractorAuctionSale:requestBid(lotNumber, amount)
    self.pendingLotNumber = lotNumber
    g_client:getServerConnection():sendEvent(TCAuctionBidEvent.new(g_currentMission:getFarmId(), lotNumber,
        math.floor(amount)))
end

-- Server: leaves, changes or withdraws a farm's bid. Returns the refusal's
-- key, or nil. The farm's players are sent its bids either way.
function TheContractorAuctionSale:placeBid(farmId, lotNumber, amount)
    local site = g_currentMission.TheContractor.AuctionSite
    amount = math.floor(amount or 0)
    local problem = self:getBidProblem(farmId, site:getLot(lotNumber), amount)
    if problem == nil then
        self.bids[lotNumber] = self.bids[lotNumber] or {}
        if amount <= 0 then
            self.bids[lotNumber][farmId] = nil
        else
            local bid = self.bids[lotNumber][farmId]
            -- A changed amount is a new bid, for ties.
            if bid == nil or bid.amount ~= amount then
                self.bids[lotNumber][farmId] = { amount = amount, order = self.nextOrder }
                self.nextOrder = self.nextOrder + 1
            end
        end
        TCLog.info("TheContractor: farm %d bid %d on lot %d", farmId, amount, lotNumber)
        -- 141: a bid means they came.
        if amount > 0 then
            TCAuctionAttendance.markAttended(farmId)
        end
    end
    self:sendFarmBids(farmId, nil, problem ~= nil and { lotNumber = lotNumber, key = problem } or nil)
    return problem
end

-- Server: the farm's bids to its players, with what's become of any just
-- settled (outcomes: { { lotNumber, outcome, amount, fee } }) and a refused
-- request. The host's own player is told directly (a broadcast doesn't
-- come back to it).
function TheContractorAuctionSale:sendFarmBids(farmId, outcomes, refusal)
    local event = TCAuctionBidsEvent.new(farmId, self:getFarmBids(farmId), outcomes, refusal)
    if g_currentMission.broadcastEventToFarm ~= nil and g_server ~= nil then
        g_currentMission:broadcastEventToFarm(event, farmId)
    end
    if g_currentMission:getFarmId() == farmId then
        self:showNotices(farmId, outcomes, refusal)
    end
end

-- Every machine: a farm's bids as the server sent them.
function TheContractorAuctionSale:applyFarmBids(farmId, farmBids)
    for _, lotBids in pairs(self.bids) do
        lotBids[farmId] = nil
    end
    for lotNumber, bid in pairs(farmBids) do
        self.bids[lotNumber] = self.bids[lotNumber] or {}
        self.bids[lotNumber][farmId] = bid
    end
end

-- Client: the notifications for this farm's players, and a refusal for the
-- player who asked.
function TheContractorAuctionSale:showNotices(farmId, outcomes, refusal)
    if g_currentMission.addIngameNotification == nil or g_currentMission:getFarmId() ~= farmId then
        return
    end
    local site = g_currentMission.TheContractor.AuctionSite
    for _, outcome in ipairs(outcomes or {}) do
        local lot = site:getLot(outcome.lotNumber)
        local name = lot ~= nil and TheContractorAuctionSite.getLotName(lot) or ""
        local money = function(amount)
            return g_i18n:formatMoney(amount or 0, 0, true, true)
        end
        if outcome.outcome == OUTCOME.WON then
            g_currentMission:addIngameNotification(FSBaseMission.INGAME_NOTIFICATION_OK,
                string.format(g_i18n:getText("tc_auctionSale_wonNotice"), outcome.lotNumber, name, money(outcome.amount)))
        elseif outcome.outcome == OUTCOME.LOST then
            g_currentMission:addIngameNotification(FSBaseMission.INGAME_NOTIFICATION_INFO,
                string.format(g_i18n:getText("tc_auctionSale_lostNotice"), outcome.lotNumber))
        elseif outcome.outcome == OUTCOME.UNPAID then
            g_currentMission:addIngameNotification(FSBaseMission.INGAME_NOTIFICATION_CRITICAL,
                string.format(g_i18n:getText("tc_auctionSale_unpaidNotice"), outcome.lotNumber, money(outcome.fee)))
        elseif outcome.outcome == TheContractorAuctionSale.DELIVERED_TO.PARKING then
            g_currentMission:addIngameNotification(FSBaseMission.INGAME_NOTIFICATION_OK,
                string.format(g_i18n:getText("tc_auctionSale_deliveredNotice"), outcome.lotNumber, name))
        elseif outcome.outcome == TheContractorAuctionSale.DELIVERED_TO.SHOP then
            g_currentMission:addIngameNotification(FSBaseMission.INGAME_NOTIFICATION_OK,
                string.format(g_i18n:getText("tc_auctionSale_deliveredShopNotice"), outcome.lotNumber, name))
        elseif outcome.outcome == TheContractorAuctionSale.DELIVERED_TO.WAITING then
            g_currentMission:addIngameNotification(FSBaseMission.INGAME_NOTIFICATION_INFO,
                string.format(g_i18n:getText("tc_auctionSale_deliveredWaitingNotice"), outcome.lotNumber, name))
        end
    end
    if refusal ~= nil and refusal.lotNumber == self.pendingLotNumber and g_client ~= nil then
        self.pendingLotNumber = nil
        g_currentMission:addIngameNotification(FSBaseMission.INGAME_NOTIFICATION_CRITICAL,
            g_i18n:getText(refusal.key))
    end
end

-- Server: a player joining a farm gets that farm's bids.
function TheContractorAuctionSale:onPlayerFarmChanged(player)
    local farmId = player ~= nil and player.farmId or nil
    if farmId ~= nil and farmId ~= FarmManager.SPECTATOR_FARM_ID then
        self:sendFarmBids(farmId)
    end
end

-- The close (server) ------------------------------------------------------------------------

function TheContractorAuctionSale:onMinuteChanged()
    self:closeDue()
end

-- The auction's site, if its lots are out: the site subsystem and its lots.
local function getSaleSite()
    local site = g_currentMission.TheContractor.AuctionSite
    if site == nil or site.site == nil or site:getSaleDay() == nil then
        return nil
    end
    return site
end

local function isOpen(lot)
    return lot.failed == nil and lot.soldTo == nil and lot.vehicleId ~= nil
end

-- Server: every lot past its closing time settled (all of them with
-- everyLot, when the sale's skipped past or ends).
function TheContractorAuctionSale:closeDue(everyLot)
    if not g_currentMission:getIsServer() then
        return
    end
    local site = getSaleSite()
    if site == nil then
        return
    end
    for _, lot in ipairs(site.site.lots) do
        if isOpen(lot) and (everyLot or
                site:getLotStateNow(lot) ~= TheContractorAuctionSite.LOT_STATE.OPEN) then
            self:closeLot(lot)
        end
    end
end

-- Server: whether a farm can pay a bid now.
local function canPay(farmId, amount)
    local farm = g_farmManager:getFarmById(farmId)
    return farm ~= nil and farm:getBalance() >= amount
end

-- Server: settles one lot (the site's own lot).
function TheContractorAuctionSale:closeLot(lot)
    local tc = g_currentMission.TheContractor
    -- 152: the lot's inspection is done or too late, before it can change
    -- hands.
    local auction = tc.Auctions ~= nil and tc.Auctions:getAuction() or nil
    if auction ~= nil then
        TCLotInspections.onLotClosed(auction.id, lot.number)
    end
    local entries = {}
    for farmId, bid in pairs(self.bids[lot.number] or {}) do
        table.insert(entries, { farmId = farmId, amount = bid.amount, order = bid.order })
    end
    local winner, price, unpaid = TheContractorAuctionSale.settle(entries,
        TheContractorAuctionSale.getLocalBid(lot), canPay)

    local outcomes = {}
    for _, farmId in ipairs(unpaid) do
        local fee = tc.Settings:scaleCost(TheContractorAuctionSale.UNPAID_FEE)
        g_currentMission:addMoney(-fee, farmId, MoneyType.TC_AUCTION_PURCHASE, true, true)
        local bid = self.bids[lot.number][farmId]
        bid.outcome, bid.fee = OUTCOME.UNPAID, fee
        outcomes[farmId] = { lotNumber = lot.number, outcome = OUTCOME.UNPAID, amount = bid.amount, fee = fee }
    end

    if winner ~= nil then
        g_currentMission:addMoney(-price, winner, MoneyType.TC_AUCTION_PURCHASE, true, true)
        local bid = self.bids[lot.number][winner]
        bid.outcome, bid.paid = OUTCOME.WON, price
        outcomes[winner] = { lotNumber = lot.number, outcome = OUTCOME.WON, amount = price }
        lot.soldTo, lot.salePrice = winner, price
        TheContractorAuctionSale.handOver(lot, winner)
        self:postWonMessage(lot, winner, price)
        -- 141: and so does a win.
        TCAuctionAttendance.markAttended(winner)
    else
        lot.soldTo = 0
    end

    for farmId, bid in pairs(self.bids[lot.number] or {}) do
        if bid.outcome == nil then
            bid.outcome = OUTCOME.LOST
            outcomes[farmId] = { lotNumber = lot.number, outcome = OUTCOME.LOST, amount = bid.amount }
        end
    end

    TCLog.info("TheContractor: auction lot %d closed: %s (local bid %.0f, %d farm bid(s))", lot.number,
        winner ~= nil and string.format("farm %d at %d", winner, price) or "a local buyer",
        TheContractorAuctionSale.getLocalBid(lot), #entries)
    tc.AuctionSite:syncLot(lot)
    for farmId, outcome in pairs(outcomes) do
        self:sendFarmBids(farmId, { outcome })
    end
end

-- Server: the lot's machines are the farm's now. They come off the lock
-- with the lot's result (AuctionSite's public lot).
function TheContractorAuctionSale.handOver(lot, farmId)
    for _, vehicleId in ipairs({ lot.vehicleId, lot.attachmentId or false }) do
        local vehicle = vehicleId and NetworkUtil.getObject(vehicleId) or nil
        if vehicle ~= nil and not vehicle.isDeleted then
            vehicle:setOwnerFarmId(farmId)
        end
    end
end

-- Server: a company winner's inbox message, there if they weren't watching.
function TheContractorAuctionSale:postWonMessage(lot, farmId, price)
    local tc = g_currentMission.TheContractor
    local auctions = tc.Auctions
    local auction = auctions ~= nil and auctions:getAuction() or nil
    if tc.Company == nil or not tc.Company:hasCompany(farmId) or auction == nil then
        return
    end
    tc.Inbox:postMessage(farmId, TheContractorAuctionSale.MESSAGE_KIND, "tc_auctionSale_wonTitle",
        "tc_auctionSale_wonBody",
        { tostring(lot.number), TheContractorFarmerFleet.getModelName(lot.xmlFilename), "$money_" .. price },
        { TheContractorAuctions.SHOW_ON_MAP_ACTION, TheContractorInbox.DISMISS_ACTION },
        { auctionId = auction.id, lotNumber = lot.number })
end

-- After the sale (server) ---------------------------------------------------------------------

-- Server, as the auction ends (every lot settled first) or is called off
-- (none sold that wasn't already): any lot a farm won and left on the field
-- is delivered to its yard, free. Then the bids and the won messages go.
function TheContractorAuctionSale:finish(auctionId, isCancelled)
    if not g_currentMission:getIsServer() then
        return
    end
    if not isCancelled then
        self:closeDue(true)
    end
    self:deliverWon()
    self:removeMessages(auctionId)
    self:clear()
end

-- Whether a point's on the site's field.
local function isOnField(fieldId, x, z)
    local field = g_fieldManager:getFieldById(fieldId)
    local polygon = field ~= nil and TCAuctionCrowd.getFieldPolygon(field) or nil
    return polygon ~= nil and #polygon >= 3 and TCAuctionCrowd.pointInPolygon(x, z, polygon)
end

function TheContractorAuctionSale:deliverWon()
    local site = g_currentMission.TheContractor.AuctionSite
    if site == nil or site.site == nil then
        return
    end
    local tc = g_currentMission.TheContractor
    for _, lot in ipairs(site.site.lots) do
        local vehicle = lot.soldTo ~= nil and lot.soldTo > 0 and lot.vehicleId ~= nil and
            NetworkUtil.getObject(lot.vehicleId) or nil
        if vehicle ~= nil and not vehicle.isDeleted and vehicle.rootNode ~= nil and
                vehicle:getOwnerFarmId() == lot.soldTo and
                not (vehicle.getIsControlled ~= nil and vehicle:getIsControlled()) then
            local x, _, z = getWorldTranslation(vehicle.rootNode)
            if isOnField(site.site.fieldId, x, z) then
                local ids = { lot.vehicleId }
                if lot.attachmentId ~= nil and NetworkUtil.getObject(lot.attachmentId) ~= nil then
                    table.insert(ids, lot.attachmentId)
                end
                local where = TheContractorAuctionSale.deliver(lot.soldTo, ids)
                local bid = self:getFarmBid(lot.number, lot.soldTo)
                if bid ~= nil then
                    bid.outcome = OUTCOME.DELIVERED
                end
                TCLog.info("TheContractor: auction lot %d left on the field, delivered to farm %d (%s)", lot.number,
                    lot.soldTo, where)
                self:sendFarmBids(lot.soldTo, { { lotNumber = lot.number, outcome = where } })
            end
        end
    end
end

-- Server: a won lot's machines (and header) off the field: each into a free
-- parking slot of the farm's, else to the shop; anything that fits neither
-- waits in the parking queue. Returns where they went (DELIVERED_TO: the
-- worst of them).
function TheContractorAuctionSale.deliver(farmId, vehicleIds)
    local T = TheContractorAuctionSale.DELIVERED_TO
    local tc = g_currentMission.TheContractor
    TCJobSiteSetup.unhitchVehicles(vehicleIds)
    local where = T.PARKING
    local waiting = {}
    for _, vehicleId in ipairs(vehicleIds) do
        local vehicle = NetworkUtil.getObject(vehicleId)
        if vehicle ~= nil and not vehicle.isDeleted then
            local x, y, z, rotY = TCParking.findSpot(vehicle, farmId)
            if x == nil then
                x, y, z, rotY = TCParking.findShopSpot(vehicle)
                if x ~= nil and where == T.PARKING then
                    where = T.SHOP
                end
            end
            if x ~= nil then
                TCParking.placeVehicle(vehicle, x, y, z, rotY)
            else
                table.insert(waiting, vehicleId)
            end
        end
    end
    if #waiting > 0 then
        tc.Parking:returnVehicles(farmId, waiting)
        where = T.WAITING
    end
    return where
end

function TheContractorAuctionSale:removeMessages(auctionId)
    local inbox = g_currentMission.TheContractor.Inbox
    local ids = {}
    for id, message in pairs(inbox.messagesById) do
        if message.kind == TheContractorAuctionSale.MESSAGE_KIND and
                (auctionId == nil or message.payload.auctionId == auctionId) then
            table.insert(ids, id)
        end
    end
    table.sort(ids)
    for _, id in ipairs(ids) do
        inbox:removeMessage(id)
    end
end

-- Server: no auction, no bids; every farm's players told.
function TheContractorAuctionSale:clear()
    local farmIds = {}
    for _, lotBids in pairs(self.bids) do
        for farmId in pairs(lotBids) do
            farmIds[farmId] = true
        end
    end
    self.bids = {}
    for farmId in pairs(farmIds) do
        self:sendFarmBids(farmId)
    end
end

-- Every machine: a deleted farm's bids go.
function TheContractorAuctionSale:forgetFarm(farmId)
    for _, lotBids in pairs(self.bids) do
        lotBids[farmId] = nil
    end
end

-- Persistence ---------------------------------------------------------------------------------

function TheContractorAuctionSale:saveToXmlFile(xmlFile)
    if not g_currentMission:getIsServer() then
        return
    end
    local key = TheContractor.SaveKey .. ".auctionSale"
    setXMLInt(xmlFile, key .. "#nextOrder", self.nextOrder)
    local lotNumbers = {}
    for lotNumber in pairs(self.bids) do
        table.insert(lotNumbers, lotNumber)
    end
    table.sort(lotNumbers)
    local index = 0
    for _, lotNumber in ipairs(lotNumbers) do
        local farmIds = {}
        for farmId in pairs(self.bids[lotNumber]) do
            table.insert(farmIds, farmId)
        end
        table.sort(farmIds)
        for _, farmId in ipairs(farmIds) do
            local bid = self.bids[lotNumber][farmId]
            local bidKey = string.format("%s.bid(%d)", key, index)
            setXMLInt(xmlFile, bidKey .. "#lot", lotNumber)
            setXMLInt(xmlFile, bidKey .. "#farmId", farmId)
            setXMLInt(xmlFile, bidKey .. "#amount", bid.amount)
            setXMLInt(xmlFile, bidKey .. "#order", bid.order or 0)
            if bid.outcome ~= nil then
                setXMLString(xmlFile, bidKey .. "#outcome", bid.outcome)
            end
            if bid.paid ~= nil then
                setXMLInt(xmlFile, bidKey .. "#paid", bid.paid)
            end
            if bid.fee ~= nil then
                setXMLInt(xmlFile, bidKey .. "#fee", bid.fee)
            end
            index = index + 1
        end
    end
end

function TheContractorAuctionSale:loadFromXMLFile(xmlFile)
    if not g_currentMission:getIsServer() then
        return
    end
    local key = TheContractor.SaveKey .. ".auctionSale"
    self.nextOrder = getXMLInt(xmlFile, key .. "#nextOrder") or 1
    local i = 0
    while true do
        local bidKey = string.format("%s.bid(%d)", key, i)
        if not hasXMLProperty(xmlFile, bidKey) then
            break
        end
        local lotNumber = getXMLInt(xmlFile, bidKey .. "#lot")
        local farmId = getXMLInt(xmlFile, bidKey .. "#farmId")
        local amount = getXMLInt(xmlFile, bidKey .. "#amount")
        if lotNumber ~= nil and farmId ~= nil and amount ~= nil then
            self.bids[lotNumber] = self.bids[lotNumber] or {}
            self.bids[lotNumber][farmId] = {
                amount = amount,
                order = getXMLInt(xmlFile, bidKey .. "#order") or 0,
                outcome = getXMLString(xmlFile, bidKey .. "#outcome"),
                paid = getXMLInt(xmlFile, bidKey .. "#paid"),
                fee = getXMLInt(xmlFile, bidKey .. "#fee"),
            }
        else
            TCLog.xmlWarning(xmlFile, "TheContractor: skipping auction bid %s", bidKey)
        end
        i = i + 1
    end
end

-- A joining player gets their farm's bids (and again on changing farm).
function TheContractorAuctionSale:writeInitialClientState(streamId, connection)
    local farmId = 0
    local userManager = g_currentMission.userManager
    local user = userManager ~= nil and connection ~= nil and userManager:getUserByConnection(connection) or nil
    local farm = user ~= nil and g_farmManager:getFarmByUserId(user:getId()) or nil
    if farm ~= nil and farm.farmId ~= FarmManager.SPECTATOR_FARM_ID then
        farmId = farm.farmId
    end
    streamWriteInt32(streamId, farmId)
    TCAuctionBidsEvent.writeBids(streamId, farmId ~= 0 and self:getFarmBids(farmId) or {})
end

function TheContractorAuctionSale:readInitialClientState(streamId, connection)
    local farmId = streamReadInt32(streamId)
    local farmBids = TCAuctionBidsEvent.readBids(streamId)
    if farmId ~= 0 then
        self:applyFarmBids(farmId, farmBids)
    end
end

-- Console ---------------------------------------------------------------------------------------

local function formatMoney(amount)
    return g_i18n:formatMoney(amount or 0, 0, true, true)
end

-- tcDebug auctionLots: every lot with its guide, closing time, the
-- farms' bids and result, and (an admin's tuning aid) its local bid.
function TheContractorAuctionSale:describeLots()
    local site = g_currentMission.TheContractor.AuctionSite
    if site == nil or site.site == nil then
        return "There are no auction lots out."
    end
    local lines = { string.format("Auction lots on field %d (minimum bid %d%% of the guide):",
        site.site.fieldId, TheContractorAuctionSale.MIN_BID_RATIO * 100) }
    for _, lot in ipairs(site.site.lots) do
        if lot.failed == nil and lot.guidePrice ~= nil then
            local bids = {}
            local farmIds = {}
            for farmId in pairs(self.bids[lot.number] or {}) do
                table.insert(farmIds, farmId)
            end
            table.sort(farmIds)
            for _, farmId in ipairs(farmIds) do
                local bid = self.bids[lot.number][farmId]
                table.insert(bids, string.format("farm %d %s%s", farmId, formatMoney(bid.amount),
                    bid.outcome ~= nil and (" " .. bid.outcome) or ""))
            end
            local result = lot.soldTo == nil and "open" or
                (lot.soldTo == 0 and "local buyer" or string.format("farm %d", lot.soldTo))
            table.insert(lines, string.format("  lot %d %s: guide %s, closes %s, local bid %s, %s; bids: %s",
                lot.number, TheContractorFarmerFleet.getModelName(lot.xmlFilename), formatMoney(lot.guidePrice),
                TheContractorAuctionSite.formatCloseTime(lot.closeMinute or 0),
                formatMoney(TheContractorAuctionSale.getLocalBid(lot)), result,
                #bids > 0 and table.concat(bids, ", ") or "none"))
        end
    end
    return table.concat(lines, "\n")
end

-- tcDebug auctionBid <lot> <amount|guide|off>.
function TheContractorAuctionSale:consoleBid(farmId, lotNumber, value)
    local site = g_currentMission.TheContractor.AuctionSite
    local lot = site:getLot(lotNumber)
    local amount
    if value == "off" then
        amount = 0
    elseif value == "guide" then
        amount = lot ~= nil and math.ceil(lot.guidePrice) or 0
    else
        amount = tonumber(value)
        if amount == nil then
            return false
        end
    end
    local problem = self:placeBid(farmId, lotNumber, amount)
    if problem ~= nil then
        return string.format("Refused: %s", g_i18n:getText(problem))
    end
    if amount <= 0 then
        return string.format("Farm %d's bid on lot %d withdrawn.", farmId, lotNumber)
    end
    return string.format("Farm %d bid %s on lot %d (guide %s).", farmId, formatMoney(amount), lotNumber,
        formatMoney(lot.guidePrice))
end

-- tcDebug auctionClose [lot|all]: the next open lot, that one, or every one.
function TheContractorAuctionSale:consoleClose(which)
    local site = getSaleSite()
    if site == nil then
        return "There's no sale on: the lots aren't out for an auction."
    end
    local closed = {}
    for _, lot in ipairs(site.site.lots) do
        if isOpen(lot) and (which == "all" or which == nil or tonumber(which) == lot.number) then
            self:closeLot(lot)
            table.insert(closed, tostring(lot.number))
            if which == nil then
                break
            end
        end
    end
    if #closed == 0 then
        return "No open lot to close."
    end
    return string.format("Closed lot(s) %s.\n%s", table.concat(closed, ", "), self:describeLots())
end
