-- Machinery auctions (137): now and then a farmer holds an auction of used
-- machinery on one of their fields. Since 163 an auction is one kind of
-- public day out (TheContractorEventDay has the day's life: the schedule,
-- the site's protection, the announcement, signs, marker, messages, crowd,
-- save and sync); this is what's the auction's own:
--
--   The schedule's numbers: about one a year (MIN_GAP_MONTHS, then a chance
--     growing each month), announced 2 to 4 months ahead (LEAD_MONTHS), in
--     spring or autumn (SALE_PERIODS), never winter or summer.
--   The site (135's rules, AuctionSite:getCandidates): a field nobody's
--     farm owns (grass, bare or harvested, 143), held by a farmer, with no
--     live job and room for the sale.
--   Set out (the sale day's midnight): the lots (AuctionSite:start, with
--     its grass cut or put down, 143), the crowd and the site's dressing
--     (140). On sale (viewing and bidding) from SALE_HOUR until the last lot
--     closes at SALE_END_HOUR (139's AuctionSale settles each lot at its
--     time); collection from then until midnight (COLLECTION_DAYS); over
--     then: won lots left on the field delivered (139), anything else
--     still standing deleted.
--   Hanging off it: viewing (138), bidding (139), the attend job (141,
--     TCAuctionAttendance) and the lot inspections (152).
--
-- Saved in TheContractor.xml (.auctions), in the initial client state, and
-- sent to every machine with TCAuctionEvent. The lots and signs are 135's
-- and 136's to save. Nothing is kept by farm.

TheContractorAuctions = {}
local TheContractorAuctions_mt = Class(TheContractorAuctions, TheContractorEventDay)

TheContractorAuctions.KIND = "auction"
TheContractorAuctions.TC_KEY = "Auctions"
TheContractorAuctions.NAME = "auction"
TheContractorAuctions.TITLE = "Auction"
TheContractorAuctions.SAVE_KEY = "auctions"
TheContractorAuctions.SAVE_EVENT_KEY = "auction"
TheContractorAuctions.PAYLOAD_ID = "auctionId"
TheContractorAuctions.MAP_NAME_KEY = "tc_auction_mapName"
TheContractorAuctions.SHOW_ON_MAP_ACTION = TheContractorEventDay.SHOW_ON_MAP_ACTION

-- The chance of an announcement in a month that can have one: none for
-- MIN_GAP_MONTHS after the last auction ended (or was called off), then
-- ANNOUNCE_CHANCE_BASE, growing by ANNOUNCE_CHANCE_STEP each month after.
-- That comes to about 1.1 a year: one in most years, two in about one in
-- six, none in about one in twenty, usually 11 months or so between sales
-- (tests/test_auctions.lua simulates it).
TheContractorAuctions.MIN_GAP_MONTHS = 3
TheContractorAuctions.ANNOUNCE_CHANCE_BASE = 0.05
TheContractorAuctions.ANNOUNCE_CHANCE_STEP = 0.05
-- Months ahead a sale's announced.
TheContractorAuctions.LEAD_MONTHS = { 2, 4 }
-- The seasonal periods a sale can be in (period 1 is the first of spring):
-- spring and autumn, as UK farm sales are.
TheContractorAuctions.SALE_PERIODS = { [1] = true, [2] = true, [3] = true, [7] = true, [8] = true, [9] = true }
TheContractorAuctions.EVENT_PERIODS = TheContractorAuctions.SALE_PERIODS
-- Signs go up this many months before the sale (at the announcement if
-- it's nearer); the reminder this many.
TheContractorAuctions.SIGNS_MONTHS = 3
TheContractorAuctions.REMINDER_MONTHS = 0.25
-- The sale day's hours (139): viewing and bidding from SALE_HOUR, until the
-- last lot closes (AuctionSite.CLOSE_HOURS); collection from then.
TheContractorAuctions.VIEWING_HOUR = 8
TheContractorAuctions.SALE_HOUR = 8
TheContractorAuctions.SALE_END_HOUR = 18
-- Days after the sale day that collection runs to the end of: none (the
-- user's call), so it ends at the sale day's midnight, when a won lot still
-- on the field is delivered (AuctionSale).
TheContractorAuctions.COLLECTION_DAYS = 0
TheContractorAuctions.START_HOUR = TheContractorAuctions.SALE_HOUR
TheContractorAuctions.END_HOUR = TheContractorAuctions.SALE_END_HOUR
TheContractorAuctions.AFTER_DAYS = TheContractorAuctions.COLLECTION_DAYS
-- The site's picked at random among this many of the best fields.
TheContractorAuctions.TOP_PICKS = 3

-- The event day's states, by the auction's names for them.
TheContractorAuctions.STATE = {
    ANNOUNCED = TheContractorEventDay.STATE.ANNOUNCED,
    SIGNS_UP = TheContractorEventDay.STATE.SIGNS_UP,
    SET_OUT = TheContractorEventDay.STATE.SET_OUT,
    ON_SALE = TheContractorEventDay.STATE.ON,
    COLLECTION = TheContractorEventDay.STATE.AFTER,
    OVER = TheContractorEventDay.STATE.OVER,
}
TheContractorAuctions.STATE_ORDER = TheContractorEventDay.STATE_ORDER
local STATE = TheContractorAuctions.STATE

-- The message texts, by what they say. Each body names the host first,
-- then the field and the date.
TheContractorAuctions.TEXTS = {
    announced = { title = "tc_auction_announced_title", body = "tc_auction_announced_body" },
    reminder = { title = "tc_auction_reminder_title", body = "tc_auction_reminder_body" },
    today = { title = "tc_auction_today_title", body = "tc_auction_today_body" },
    cancelled = { title = "tc_auction_cancelled_title", body = "tc_auction_cancelled_body" },
}

function TheContractorAuctions.new()
    -- The server's auction also has inspectionsOffered (152: the farmers
    -- have asked for lot inspections), saved but never sent.
    return TheContractorEventDay.new(TheContractorAuctions_mt)
end

function TheContractorAuctions:getAuction()
    return self.event
end

-- The schedule (pure), on the auction's numbers ------------------------------------------------

function TheContractorAuctions.getLeadChoices(period)
    return TheContractorEventDay.getEventLeadChoices(period, TheContractorAuctions.LEAD_MONTHS,
        TheContractorAuctions.SALE_PERIODS)
end

function TheContractorAuctions.getStateFor(auction, today, hour)
    return TheContractorEventDay.getEventStateFor(auction, today, hour, TheContractorAuctions.SALE_HOUR,
        TheContractorAuctions.SALE_END_HOUR, TheContractorAuctions.COLLECTION_DAYS)
end

function TheContractorAuctions.planDays(announcedDay, saleDay, daysPerPeriod)
    return TheContractorEventDay.planEventDays(announcedDay, saleDay, daysPerPeriod,
        TheContractorAuctions.SIGNS_MONTHS, TheContractorAuctions.REMINDER_MONTHS)
end

function TheContractorAuctions.getAnnounceChance(monthsSince)
    local A = TheContractorAuctions
    return TheContractorEventDay.getChanceAfter(monthsSince, A.MIN_GAP_MONTHS, A.ANNOUNCE_CHANCE_BASE,
        A.ANNOUNCE_CHANCE_STEP)
end

function TheContractorAuctions.getMovedSaleDay(auction, fromModel, toModel, today)
    return TheContractorEventDay.getMovedDay(auction, fromModel, toModel, today)
end

function TheContractorAuctions.findSaleDay(periodIndex, random)
    return TheContractorEventDay.findDayIn(periodIndex, random)
end

-- The event day's hooks ------------------------------------------------------------------------

-- 141: the attend jobs, if the sale's this month.
function TheContractorAuctions:onAnnounced(auction)
    TCAuctionAttendance.createDueJobs(auction)
end

function TheContractorAuctions:onNewDay(auction)
    self:catchUpSale()
    -- 141: the sale's month has come.
    if self.event ~= nil then
        TCAuctionAttendance.createDueJobs(self.event)
    end
end

function TheContractorAuctions:onNewHour(auction)
    self:catchUpSale()
    -- 141: who's turned up.
    if self.event ~= nil then
        TCAuctionAttendance.checkAttendance(self.event)
    end
    -- 152: farmers asking for lots to be inspected, and lots gone.
    if self.event ~= nil then
        TCLotInspections.onHour(self.event, g_currentMission.environment.currentMonotonicDay,
            g_currentMission.environment.currentHour or 0)
    end
end

function TheContractorAuctions:onStateEntered(auction, state, passing)
    local tc = g_currentMission.TheContractor
    if state == STATE.SET_OUT then
        if not passing then
            tc.AuctionSite:start(auction.fieldId, nil, auction.id)
            if tc.AuctionSite.site == nil or tc.AuctionSite.site.fieldId ~= auction.fieldId then
                TCLog.warning("TheContractor: auction %d's lots couldn't be set out on field %d", auction.id,
                    auction.fieldId)
            end
        end
    elseif state == STATE.COLLECTION then
        -- 139: every lot's closed by now.
        if tc.AuctionSale ~= nil then
            tc.AuctionSale:closeDue(true)
        end
    end
end

-- 141: the attend jobs made again for the new day.
function TheContractorAuctions:onDayMoved(auction)
    TCAuctionAttendance.removeJobs(auction.id)
    TCAuctionAttendance.createDueJobs(auction)
end

-- 139: the last lots settled, won lots left on the field delivered.
function TheContractorAuctions:onFinish(auction)
    local sale = g_currentMission.TheContractor.AuctionSale
    if sale ~= nil then
        sale:finish(auction.id)
    end
end

-- 139: no more lots sold, but anything already won is delivered.
function TheContractorAuctions:onCancel(auction)
    local sale = g_currentMission.TheContractor.AuctionSale
    if sale ~= nil then
        sale:finish(auction.id, true)
    end
end

-- 141: nothing to go to now. 152: nor to inspect.
function TheContractorAuctions:onCancelled(auction)
    TCAuctionAttendance.removeJobs(auction.id)
    TCLotInspections.endAll(auction.id)
end

-- As big as the sale: from the scene's last lot number.
function TheContractorAuctions:getCrowdPeople(scene)
    local lotCount = 0
    for _, row in ipairs(scene.rows or {}) do
        lotCount = math.max(lotCount, row.lotTo)
    end
    return TCAuctionCrowd.getAuctionPeople(lotCount)
end

function TheContractorAuctions:describeDay(auction)
    return string.format("sale %s (viewing and bidding from %02d:00, lots closing from %02d:00)",
        TCCalendar.formatDay(auction.day), TheContractorAuctions.SALE_HOUR, TheContractorAuctionSite.CLOSE_HOURS[1])
end

function TheContractorAuctions:saveEventExtra(xmlFile, key, auction)
    if auction.inspectionsOffered then
        setXMLBool(xmlFile, key .. "#inspectionsOffered", true)
    end
end

function TheContractorAuctions:loadEventExtra(xmlFile, key, auction)
    -- 152, server only.
    auction.inspectionsOffered = getXMLBool(xmlFile, key .. "#inspectionsOffered") == true or nil
end

function TheContractorAuctions:newSyncEvent(auction)
    return TCAuctionEvent.new(auction)
end

-- Server (139): lots past their closing time settled, and after the sale
-- day the local buyers' lots taken away. Both do nothing twice, so they're
-- run on every hour and day (a sleep, a load).
function TheContractorAuctions:catchUpSale()
    local auction = self.event
    local tc = g_currentMission.TheContractor
    if auction == nil or not TheContractorEventDay.isOnTheField(auction.state) then
        return
    end
    if tc.AuctionSale ~= nil then
        tc.AuctionSale:closeDue()
    end
    local site = tc.AuctionSite
    if g_currentMission.environment.currentMonotonicDay > auction.day and site.site ~= nil and
            site.site.fieldId == auction.fieldId then
        site:removeUnsold()
    end
end

-- Console ---------------------------------------------------------------------------------------

function TheContractorAuctions:describe()
    if self.event == nil then
        return "There's no auction announced. 'tcAuction start' announces one."
    end
    return TheContractorEventDay.describe(self)
end

-- tcDebug auctionDay: the sale's today, the lots out now.
function TheContractorAuctions:consoleSaleDay()
    local auction = self.event
    if auction == nil then
        return "There's no auction announced."
    end
    if auction.day ~= g_currentMission.environment.currentMonotonicDay then
        self:moveToToday()
        -- 152: the farmers ask again once the new day's lots are out.
        TCLotInspections.endAll(auction.id)
        auction.inspectionsOffered = nil
    end
    return self:describe()
end

function TheContractorAuctions.registerConsoleCommands()
    TCConsole.registerHint("lot", "a lot's number (tcDebug auctionLots)")

    TCConsole.register("auction", "status", {
        description = "The auction, if there's one: its field, host, state, days and signs",
        run = function()
            return g_currentMission.TheContractor.Auctions:describe()
        end,
    })

    -- "auto" picks the field by 135's rules, so days can still be given.
    TCConsole.register("auction", "start", {
        args = "[fieldId|auto] [days]",
        description = "Announce an auction now: on a field or one picked for you, its sale in days or 2 to 4 months",
        hints = { fieldId = "a field's number (tcAuction fields lists those that can hold a sale)" },
        run = function(_, args)
            local isAuto = args[1] ~= nil and string.lower(args[1]) == "auto"
            local fieldId = args[1] ~= nil and not isAuto and tonumber(args[1]) or nil
            local days = args[2] ~= nil and tonumber(args[2]) or nil
            if (args[1] ~= nil and not isAuto and fieldId == nil) or
                    (args[2] ~= nil and (days == nil or days < 1)) or args[3] ~= nil then
                return false
            end
            return g_currentMission.TheContractor.Auctions:consoleStart(fieldId,
                days ~= nil and math.floor(days) or nil)
        end,
    })

    TCConsole.register("auction", "cancel", {
        description = "Call the auction off: lots already won are delivered, the rest cleared away",
        run = function()
            if not g_currentMission.TheContractor.Auctions:cancel(true) then
                return "There's no auction announced."
            end
            return "Auction cancelled: everything's cleared away and every company told."
        end,
    })

    -- 135's candidates, for tcAuction start's fieldId.
    TCConsole.register("auction", "fields", {
        description = "The fields that could hold an auction, best first",
        run = function()
            return g_currentMission.TheContractor.AuctionSite:getListText(TheContractorAuctionSite.PREFERRED_LOTS)
        end,
    })

    TCConsole.register("debug", "auctionDay", {
        description = "Make today the auction's sale day: lots out now, bidding from 08:00",
        run = function()
            return g_currentMission.TheContractor.Auctions:consoleSaleDay()
        end,
    })

    -- 139: the lots, their bids and (a tuning aid) the room's.
    TCConsole.register("debug", "auctionLots", {
        description = "Every lot out: guide, closing time, the room's hidden bid, result and every farm's bid",
        run = function()
            return g_currentMission.TheContractor.AuctionSale:describeLots()
        end,
    })

    TCConsole.register("debug", "auctionBid", {
        args = "<lot> <amount|guide|off>",
        description = "Leave a bid on a lot for your farm, as the lot's card does, or withdraw it",
        run = function(farmId, args)
            local lotNumber = tonumber(args[1] or "")
            local value = args[2] ~= nil and string.lower(args[2]) or nil
            if lotNumber == nil or value == nil or args[3] ~= nil then
                return false
            end
            return g_currentMission.TheContractor.AuctionSale:consoleBid(farmId, math.floor(lotNumber), value)
        end,
    })

    TCConsole.register("debug", "auctionClose", {
        args = "[lot|all]",
        description = "Close the next open lot now, that lot, or every one, and settle it",
        run = function(_, args)
            local which = args[1] ~= nil and string.lower(args[1]) or nil
            if args[2] ~= nil or (which ~= nil and which ~= "all" and tonumber(which) == nil) then
                return false
            end
            return g_currentMission.TheContractor.AuctionSale:consoleClose(which)
        end,
    })
end
