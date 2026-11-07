-- Machinery auctions (137): now and then a farmer holds an auction of used
-- machinery on one of their grass fields. This is the auction's skeleton:
-- its schedule, its site, the announcement, signs and map marker, and the
-- lots set out and cleared away. Viewing (138), bidding (139), the crowd's
-- atmosphere (140) and the attend job (141) hang off it.
--
-- One auction is for everyone on the server, so it isn't a random event
-- (068's are per farm): it's this server-wide subsystem, like Farmers. At
-- most one is announced or running at a time.
--
--   The schedule (server): on the first day of each month, a roll
--     (getAnnounceChance): none for MIN_GAP_MONTHS after the last auction
--     ended, then a chance that grows each month it's been, so there's about
--     one a year and now and then two. A hit announces one 2 to 4 months ahead (LEAD_MONTHS,
--     in months so it scales with days per period), on a day in a sale
--     month: spring or autumn (SALE_PERIODS, the game's seasonal periods,
--     so a southern map's spring too), never winter or summer. A month with
--     no lead landing in a sale month doesn't roll.
--   The site (server) is chosen at the announcement by 135's rules
--     (AuctionSite:getCandidates): a grass field nobody's farm owns, held by
--     a farmer (110, the host), with no live job of any kind and room for
--     the sale, picked at random among the best (TOP_PICKS). No field, no
--     auction. Refusing any live job (not just one whose dates reach the
--     sale) is what keeps the sale day clear: from the announcement the
--     field's protected (Jobs:isFieldProtected, on every machine from the
--     synced field), so 034's freeze, job generation and the random events
--     leave it be, and nothing on it can run into the sale.
--   Changing hands (server, hourly and when farmland's bought): if a farm
--     buys the field or it goes to another farmer (128), the auction's
--     cancelled, with a message to every company farm. A retirement hands
--     it to the successor (Farmers:replacePersonReferences), and the
--     auction goes on.
--   The days (server, getStateFor, pure): announced; signs up 3 months
--     before, or at the announcement if it's nearer than that (136's place,
--     the sale's month); at midnight starting the sale
--     day the lots are set out (135's start: the grass cut, the lots
--     spawned), and every machine with a client puts the crowd up (134);
--     on sale (viewing and bidding) from SALE_HOUR until the last lot
--     closes at SALE_END_HOUR (139's AuctionSale settles each lot at its
--     time); collection from then until midnight (COLLECTION_DAYS); over
--     then: won lots left on the field delivered (139), anything else
--     still standing deleted, the signs down, the crowd down, the field released
--     and the auction's messages gone. A state skipped over (a long sleep)
--     does nothing it would only undo.
--   Players (every machine): a map marker at the field from the
--     announcement, for every farm, company or not, with a Visit to the
--     entrance. Company farms get the inbox: the announcement, a reminder a
--     week before (REMINDER_MONTHS, scaled) and one on the morning, each
--     from the host (fromFarmer, named live) with Show on map (client only).
--
-- Saved in TheContractor.xml, in the initial client state, and sent to
-- every machine with TCAuctionEvent. The lots and signs are 135's and 136's
-- to save. Nothing is kept by farm, so there's nothing to forget when a
-- farm is deleted.

TheContractorAuctions = {}
local TheContractorAuctions_mt = Class(TheContractorAuctions)

TheContractorAuctions.KIND = "auction"
TheContractorAuctions.SHOW_ON_MAP_ACTION = { key = "showOnMap", textKey = "tc_auction_showOnMap" }

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
-- The site's picked at random among this many of the best fields.
TheContractorAuctions.TOP_PICKS = 3
-- The most days a sale day is looked for ahead.
TheContractorAuctions.MAX_SEARCH_DAYS = 2000

TheContractorAuctions.STATE = {
    ANNOUNCED = "announced",
    SIGNS_UP = "signsUp",
    SET_OUT = "setOut",
    ON_SALE = "onSale",
    COLLECTION = "collection",
    OVER = "over",
}
local STATE = TheContractorAuctions.STATE
TheContractorAuctions.STATE_ORDER = { STATE.ANNOUNCED, STATE.SIGNS_UP, STATE.SET_OUT, STATE.ON_SALE,
    STATE.COLLECTION, STATE.OVER }
local STATE_INDEX = {}
for index, state in ipairs(TheContractorAuctions.STATE_ORDER) do
    STATE_INDEX[state] = index
end

-- The message texts, by what they say. Each body names the host first,
-- then the field and the date.
TheContractorAuctions.TEXTS = {
    announced = { title = "tc_auction_announced_title", body = "tc_auction_announced_body" },
    reminder = { title = "tc_auction_reminder_title", body = "tc_auction_reminder_body" },
    today = { title = "tc_auction_today_title", body = "tc_auction_today_body" },
    cancelled = { title = "tc_auction_cancelled_title", body = "tc_auction_cancelled_body" },
}

function TheContractorAuctions.new()
    local self = setmetatable({}, TheContractorAuctions_mt)
    -- Every machine, as the server sent it: the auction, or nil. { id,
    -- fieldId, hostFarmerId, announcedDay, signsDay, reminderDay (nil for
    -- none), saleDay, state, entrance = { x, z } or nil }.
    self.auction = nil
    -- Server: the next auction's id, and the month (absolute period index)
    -- the last one ended or was called off (nil: none yet on this save).
    self.nextId = 1
    self.lastEndedPeriodIndex = nil
    -- Every machine with a map: the site's marker, rebuilt on the next
    -- update after the auction changes; and the field this machine put a
    -- crowd on.
    self.marker = nil
    self.isDirty = false
    self.crowdFieldId = nil
    return self
end

-- Every machine, at load, before the save loads.
function TheContractorAuctions:register(inbox)
    inbox:registerMessageKind(TheContractorAuctions.KIND, {
        category = "job",
        fromFarmer = true,
        getArgs = function(message)
            return TheContractorAuctions.getMessageArgs(message)
        end,
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

-- Queries (every machine) ----------------------------------------------------------------

function TheContractorAuctions:getAuction()
    return self.auction
end

function TheContractorAuctions:isFieldInUse(fieldId)
    return fieldId ~= nil and self.auction ~= nil and self.auction.fieldId == fieldId
end

function TheContractorAuctions.getStateIndex(state)
    return STATE_INDEX[state] or 0
end

-- Whether the lots are out and the crowd's up.
function TheContractorAuctions.isOnTheField(state)
    local index = STATE_INDEX[state] or 0
    return index >= STATE_INDEX[STATE.SET_OUT] and index < STATE_INDEX[STATE.OVER]
end

-- A message's args (client): the host's name as it is now, the field's
-- name, then the date as posted.
function TheContractorAuctions.getMessageArgs(message)
    local farmers = g_currentMission.TheContractor.Farmers
    local host = farmers ~= nil and farmers:getPerson(message.payload.farmerId) or nil
    local field = g_fieldManager ~= nil and g_fieldManager:getFieldById(message.payload.fieldId) or nil
    return {
        host ~= nil and host.name or g_i18n:getText("tc_inbox_customerUnknown"),
        field ~= nil and field:getName() or tostring(message.payload.fieldId),
        message.args[1] or "",
    }
end

-- The schedule (pure) ---------------------------------------------------------------------

-- The seasonal period (1 to 12) a number of months on from this one.
function TheContractorAuctions.periodAfter(period, months)
    return (period - 1 + months) % Environment.PERIODS_IN_YEAR + 1
end

-- The leads (months ahead) from this period whose month can hold a sale.
function TheContractorAuctions.getLeadChoices(period)
    local leads = {}
    local lead = TheContractorAuctions.LEAD_MONTHS
    for months = lead[1], lead[2] do
        if TheContractorAuctions.SALE_PERIODS[TheContractorAuctions.periodAfter(period, months)] then
            table.insert(leads, months)
        end
    end
    return leads
end

-- The month (1 to 12) a seasonal period is, as vanilla's I18N:formatPeriod
-- works it out: period 1 is March, six months on for a southern map.
function TheContractorAuctions.getMonth(period, isSouthern)
    local month = period + 2 + (isSouthern and 6 or 0)
    return (month - 1) % 12 + 1
end

-- The state an auction should be in on a day at an hour (monotonic day,
-- 0-23).
function TheContractorAuctions.getStateFor(auction, today, hour)
    if today > auction.saleDay + TheContractorAuctions.COLLECTION_DAYS then
        return STATE.OVER
    elseif today > auction.saleDay then
        return STATE.COLLECTION
    end
    if today == auction.saleDay then
        if hour < TheContractorAuctions.SALE_HOUR then
            return STATE.SET_OUT
        elseif hour < TheContractorAuctions.SALE_END_HOUR then
            return STATE.ON_SALE
        end
        return STATE.COLLECTION
    end
    if today >= auction.signsDay then
        return STATE.SIGNS_UP
    end
    return STATE.ANNOUNCED
end

-- An auction's days, from its announcement and sale day and the sale
-- month's days per period: signs SIGNS_MONTHS before (never before the
-- announcement), the reminder a week before (none if that's not after the
-- announcement or is the sale day).
function TheContractorAuctions.planDays(announcedDay, saleDay, daysPerPeriod)
    local signsDay = math.max(announcedDay,
        saleDay - math.floor(TheContractorAuctions.SIGNS_MONTHS * daysPerPeriod + 0.5))
    local reminderDay = saleDay - math.max(1, math.floor(TheContractorAuctions.REMINDER_MONTHS * daysPerPeriod + 0.5))
    if reminderDay <= announcedDay then
        reminderDay = nil
    end
    return signsDay, reminderDay
end

-- Server ----------------------------------------------------------------------------------

function TheContractorAuctions:startListening()
    if not g_currentMission:getIsServer() then
        return
    end
    g_messageCenter:subscribe(MessageType.DAY_CHANGED, self.onDayChanged, self)
    g_messageCenter:subscribe(MessageType.HOUR_CHANGED, self.onHourChanged, self)
    g_messageCenter:subscribe(MessageType.FARMLAND_OWNER_CHANGED, self.onFarmlandOwnerChanged, self)
end

function TheContractorAuctions:stopListening()
    if g_messageCenter ~= nil then
        g_messageCenter:unsubscribeAll(self)
    end
end

local function getToday()
    return g_currentMission.environment.currentMonotonicDay
end

local function getHour()
    return g_currentMission.environment.currentHour or 0
end

function TheContractorAuctions:onDayChanged()
    if self.auction ~= nil then
        if not self:checkField() then
            return
        end
        self:advance(getToday(), 0)
        self:postDayMessages(getToday())
        self:catchUpSale()
    elseif g_currentMission.environment.currentDayInPeriod == 1 then
        self:rollAnnouncement(math.random)
    end
end

function TheContractorAuctions:onHourChanged()
    if self.auction ~= nil and self:checkField() then
        self:advance(getToday(), getHour())
        self:catchUpSale()
    end
end

-- Server (139): lots past their closing time settled, and after the sale
-- day the local buyers' lots taken away. Both do nothing twice, so they're
-- run on every hour and day (a sleep, a load).
function TheContractorAuctions:catchUpSale()
    local auction = self.auction
    local tc = g_currentMission.TheContractor
    if auction == nil or not TheContractorAuctions.isOnTheField(auction.state) then
        return
    end
    if tc.AuctionSale ~= nil then
        tc.AuctionSale:closeDue()
    end
    local site = tc.AuctionSite
    if getToday() > auction.saleDay and site.site ~= nil and site.site.fieldId == auction.fieldId then
        site:removeUnsold()
    end
end

function TheContractorAuctions:onFarmlandOwnerChanged(farmlandId, farmId, loadFromSavegame)
    if self.auction ~= nil and not loadFromSavegame then
        self:checkField()
    end
end

-- The chance of an announcement this month, months after the last auction
-- ended (pure).
function TheContractorAuctions.getAnnounceChance(monthsSince)
    local A = TheContractorAuctions
    if monthsSince < A.MIN_GAP_MONTHS then
        return 0
    end
    return math.min(1, A.ANNOUNCE_CHANCE_BASE + A.ANNOUNCE_CHANCE_STEP * (monthsSince - A.MIN_GAP_MONTHS))
end

-- Server: the month's roll. Returns the auction announced, or nil.
function TheContractorAuctions:rollAnnouncement(random)
    if self.auction ~= nil then
        return nil
    end
    local periodIndex = TCCalendar.getPeriodIndex()
    -- A save's first: counted as if one had ended just long enough ago.
    if self.lastEndedPeriodIndex == nil then
        self.lastEndedPeriodIndex = periodIndex - TheContractorAuctions.MIN_GAP_MONTHS
    end
    local leads = TheContractorAuctions.getLeadChoices(g_currentMission.environment.currentPeriod)
    if #leads == 0 then
        return nil
    end
    if random() >= TheContractorAuctions.getAnnounceChance(periodIndex - self.lastEndedPeriodIndex) then
        return nil
    end
    local lead = leads[math.min(#leads, math.floor(random() * #leads) + 1)]
    local saleDay = TheContractorAuctions.findSaleDay(TCCalendar.getPeriodIndex() + lead, random)
    if saleDay == nil then
        return nil
    end
    local auction = self:announce(nil, saleDay, random)
    return auction
end

-- A day in a month (an absolute period index) ahead, at random, or nil if
-- it's further off than MAX_SEARCH_DAYS.
function TheContractorAuctions.findSaleDay(periodIndex, random)
    local today = getToday()
    for offset = 1, TheContractorAuctions.MAX_SEARCH_DAYS do
        local index, _, daysPerPeriod = TCCalendar.getDayInfo(today + offset)
        if index == periodIndex then
            return today + offset + math.min(daysPerPeriod - 1, math.floor(random() * daysPerPeriod))
        elseif index > periodIndex then
            return nil
        end
    end
    return nil
end

-- The farmer holding a field's farmland, or nil.
local function getHolder(field)
    local farmers = g_currentMission.TheContractor.Farmers
    local farmland = field ~= nil and field.getFarmland ~= nil and field:getFarmland() or nil
    if farmers == nil or farmland == nil then
        return nil
    end
    return farmers:getHolder(farmland:getId())
end

-- Server: the site for a new auction, by 135's rules: { fieldId, hostId,
-- entrance }, or nil with no field that qualifies.
function TheContractorAuctions:pickSite(random)
    local site = g_currentMission.TheContractor.AuctionSite
    local ranked = site:getCandidates(TheContractorAuctionSite.PREFERRED_LOTS)
    local picks = {}
    for _, candidate in ipairs(ranked) do
        if #candidate.problems == 0 then
            local holder = getHolder(g_fieldManager:getFieldById(candidate.fieldId))
            if holder ~= nil then
                table.insert(picks, { fieldId = candidate.fieldId, hostId = holder.id, entrance = candidate.entrance })
                if #picks >= TheContractorAuctions.TOP_PICKS then
                    break
                end
            end
        end
    end
    if #picks == 0 then
        return nil
    end
    return picks[math.min(#picks, math.floor(random() * #picks) + 1)]
end

-- Server: a given field as a site (the console's), or nil and why not.
function TheContractorAuctions.getFieldSite(fieldId)
    local field = g_fieldManager:getFieldById(fieldId)
    if field == nil then
        return nil, string.format("No field %d.", fieldId)
    end
    local refusal = TheContractorAuctionSite.getFieldRefusal(field)
    if refusal ~= nil then
        return nil, string.format("Field %d can't hold an auction: %s.", fieldId, refusal)
    end
    local holder = getHolder(field)
    if holder == nil then
        return nil, string.format("Field %d can't hold an auction: no farmer holds it.", fieldId)
    end
    local entrance = TCAuctionLayout.findEntrance(TCAuctionCrowd.getFieldPolygon(field),
        TheContractorFallenTree.sampleRoads(), TCAuctionLayout.RULES.entranceReach)
    return { fieldId = fieldId, hostId = holder.id, entrance = entrance }
end

-- Server: announces an auction for a day ahead, on a site (or one picked
-- by 135's rules). Returns the auction, or nil and why not.
function TheContractorAuctions:announce(site, saleDay, random)
    if self.auction ~= nil then
        return nil, "There's an auction already."
    end
    site = site or self:pickSite(random or math.random)
    if site == nil then
        TCLog.info("TheContractor: no field can hold an auction, none announced")
        return nil, "No field can hold an auction."
    end
    local today = getToday()
    local signsDay, reminderDay = TheContractorAuctions.planDays(today, saleDay,
        TCCalendar.getDaysPerPeriodOn(saleDay))
    local auction = {
        id = self.nextId,
        fieldId = site.fieldId,
        hostFarmerId = site.hostId,
        announcedDay = today,
        signsDay = signsDay,
        reminderDay = reminderDay,
        saleDay = saleDay,
        state = STATE.ANNOUNCED,
        entrance = site.entrance ~= nil and { x = site.entrance.x, z = site.entrance.z } or nil,
    }
    self.nextId = self.nextId + 1
    self.auction = auction
    TCLog.info("TheContractor: auction %d announced on field %d (host %d) for day %d, signs day %d", auction.id,
        auction.fieldId, auction.hostFarmerId, saleDay, signsDay)
    self:postMessages("announced", true)
    -- The signs may be due already (a short lead).
    self:advance(today, getHour())
    self:sync()
    return auction
end

-- Server: posts one of the auction's messages to every company farm,
-- replacing the auction's earlier ones there. withMap: a Show on map action.
function TheContractorAuctions:postMessages(textKey, withMap)
    local tc = g_currentMission.TheContractor
    local auction = self.auction
    local texts = TheContractorAuctions.TEXTS[textKey]
    self:removeMessages(auction.id)
    local actions = { TheContractorInbox.DISMISS_ACTION }
    if withMap then
        actions = { TheContractorAuctions.SHOW_ON_MAP_ACTION, TheContractorInbox.DISMISS_ACTION }
    end
    for _, farmId in ipairs(tc.RandomEvents:getCompanyFarmIds()) do
        tc.Inbox:postMessage(farmId, TheContractorAuctions.KIND, texts.title, texts.body,
            { string.format("$days_%d_%d", auction.saleDay, auction.saleDay) }, actions,
            { auctionId = auction.id, farmerId = auction.hostFarmerId, fieldId = auction.fieldId })
    end
end

-- Server: every message about an auction goes.
function TheContractorAuctions:removeMessages(auctionId)
    local inbox = g_currentMission.TheContractor.Inbox
    local ids = {}
    for id, message in pairs(inbox.messagesById) do
        if message.kind == TheContractorAuctions.KIND and message.payload.auctionId == auctionId then
            table.insert(ids, id)
        end
    end
    table.sort(ids)
    for _, id in ipairs(ids) do
        inbox:removeMessage(id)
    end
end

-- Server, each day: the reminder a week before, and one on the morning.
function TheContractorAuctions:postDayMessages(today)
    local auction = self.auction
    if auction == nil then
        return
    end
    if today == auction.saleDay then
        self:postMessages("today", true)
    elseif auction.reminderDay ~= nil and today == auction.reminderDay then
        self:postMessages("reminder", true)
    end
end

-- Server: whether the field's still the host's to hold the sale on. If
-- not, the auction's cancelled (and false returned).
function TheContractorAuctions:checkField()
    local auction = self.auction
    -- Until a load's farmers are set up (TheContractor:resolveSavedVehicles),
    -- nobody holds anything yet.
    if not g_currentMission.TheContractor.hasResolvedSavedVehicles then
        return true
    end
    local field = g_fieldManager:getFieldById(auction.fieldId)
    local holder = field ~= nil and field:getOwner() == FarmlandManager.NO_OWNER_FARM_ID and getHolder(field) or nil
    if holder ~= nil and holder.id == auction.hostFarmerId then
        return true
    end
    TCLog.info("TheContractor: auction %d's field %d has changed hands, cancelled", auction.id, auction.fieldId)
    self:cancel(true)
    return false
end

-- Server: brings the auction up to the day and hour, a state at a time.
function TheContractorAuctions:advance(today, hour)
    local auction = self.auction
    if auction == nil then
        return
    end
    local target = TheContractorAuctions.getStateFor(auction, today, hour)
    local targetIndex = STATE_INDEX[target]
    local changed = false
    while self.auction == auction and STATE_INDEX[auction.state] < targetIndex do
        local nextState = TheContractorAuctions.STATE_ORDER[STATE_INDEX[auction.state] + 1]
        auction.state = nextState
        changed = true
        self:enterState(auction, nextState, target)
    end
    if changed and self.auction == auction then
        self:sync()
    end
end

-- Server: what happens as an auction reaches a state. With the target past
-- it (days skipped), nothing's put out only to be taken away.
function TheContractorAuctions:enterState(auction, state, target)
    local tc = g_currentMission.TheContractor
    local passing = target == STATE.OVER
    TCLog.info("TheContractor: auction %d now %s", auction.id, state)
    if state == STATE.SIGNS_UP then
        if not passing then
            local period = select(1, TCCalendar.getDayInfo(auction.saleDay))
            period = (period - 1) % Environment.PERIODS_IN_YEAR + 1
            tc.AuctionSigns:place(TheContractorAuctions.getMonth(period, TheContractorAuctions.isSouthern()))
        end
    elseif state == STATE.SET_OUT then
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
    elseif state == STATE.OVER then
        self:finish()
    end
end

function TheContractorAuctions.isSouthern()
    local environment = g_currentMission.environment
    return environment ~= nil and environment.daylight ~= nil and environment.daylight.latitude ~= nil and
        environment.daylight.latitude < 0
end

-- Server: takes everything away: the lots still standing, the signs, the
-- messages; the field's released.
function TheContractorAuctions:clearAway()
    local tc = g_currentMission.TheContractor
    local auction = self.auction
    local site = tc.AuctionSite
    if site.site ~= nil and site.site.fieldId == auction.fieldId then
        site:clear()
    end
    if tc.AuctionSigns.month ~= 0 or #tc.AuctionSigns.signs > 0 then
        tc.AuctionSigns:clear()
    end
    self:removeMessages(auction.id)
end

-- Server: the auction's over.
function TheContractorAuctions:finish()
    local auction = self.auction
    -- 139: the last lots settled, won lots left on the field delivered.
    local sale = g_currentMission.TheContractor.AuctionSale
    if sale ~= nil then
        sale:finish(auction.id)
    end
    self:clearAway()
    self.auction = nil
    -- The wait's from the sale's month (139's collection day can run into
    -- the next).
    self.lastEndedPeriodIndex = math.min(TCCalendar.getPeriodIndex(), (TCCalendar.getDayInfo(auction.saleDay)))
    TCLog.info("TheContractor: auction %d over, field %d released", auction.id, auction.fieldId)
    self:sync()
end

-- Server: the auction's called off. tellFarms: a message to every company
-- farm.
function TheContractorAuctions:cancel(tellFarms)
    local auction = self.auction
    if auction == nil then
        return false
    end
    -- 139: no more lots sold, but anything already won is delivered.
    local sale = g_currentMission.TheContractor.AuctionSale
    if sale ~= nil then
        sale:finish(auction.id, true)
    end
    self:clearAway()
    if tellFarms then
        self:postMessages("cancelled", false)
    end
    self.auction = nil
    self.lastEndedPeriodIndex = TCCalendar.getPeriodIndex()
    TCLog.info("TheContractor: auction %d cancelled", auction.id)
    self:sync()
    return true
end

-- Server: the auction to this machine and every client.
function TheContractorAuctions:sync()
    self:applySync(self.auction)
    if g_server ~= nil then
        g_server:broadcastEvent(TCAuctionEvent.new(self.auction))
    end
end

-- Every machine ------------------------------------------------------------------------------

-- The auction as the server sent it (TCAuctionEvent), or nil.
function TheContractorAuctions:applySync(auction)
    self.auction = auction
    self.isDirty = true
end

function TheContractorAuctions:update(dt)
    if self.isDirty then
        self.isDirty = false
        self:refreshMarker()
        self:refreshCrowd()
    elseif self.crowdWalkways ~= nil or (self.auction ~= nil and TheContractorAuctions.isOnTheField(self.auction.state)) then
        -- The walkways come with the site's own event, which may land after
        -- ours: catch them up (cheap when nothing's changed).
        self:refreshCrowd()
    end
end

-- The site's map marker, on a machine with a map: there from the
-- announcement until it's over.
function TheContractorAuctions:refreshMarker()
    self:removeMarker()
    local auction = self.auction
    if auction == nil or g_currentMission.hud == nil or PlaceableHotspot == nil or
            g_currentMission.addMapHotspot == nil then
        return
    end
    local field = g_fieldManager:getFieldById(auction.fieldId)
    if field == nil then
        return
    end
    local hotspot = PlaceableHotspot.new()
    hotspot:setName(g_i18n:getText("tc_auction_mapName"))
    hotspot:createIcon()
    hotspot:setPlaceableType(PlaceableHotspot.TYPE.EXCLAMATION_MARK)
    local x, z = field:getIndicatorPosition()
    hotspot:setWorldPosition(x, z)
    local entrance = auction.entrance
    if entrance ~= nil then
        hotspot:setTeleportWorldPosition(entrance.x,
            getTerrainHeightAtWorldPos(g_terrainNode, entrance.x, 0, entrance.z), entrance.z)
    end
    g_currentMission:addMapHotspot(hotspot)
    self.marker = hotspot
end

function TheContractorAuctions:removeMarker()
    if self.marker == nil then
        return
    end
    if g_currentMission ~= nil and g_currentMission.removeMapHotspot ~= nil and g_currentMission.hud ~= nil then
        g_currentMission:removeMapHotspot(self.marker)
    end
    self.marker:delete()
    self.marker = nil
end

-- Whether two lists of walkways are the same (a client gets a fresh copy
-- with every lot that comes out).
function TheContractorAuctions.sameWalkways(a, b)
    if a == b then
        return true
    end
    if a == nil or b == nil or #a ~= #b then
        return false
    end
    for i, walkway in ipairs(a) do
        local other = b[i]
        for _, key in ipairs({ "x1", "z1", "x2", "z2", "halfWidth" }) do
            if math.abs(walkway[key] - other[key]) > 0.001 then
                return false
            end
        end
    end
    return true
end

-- The site's walkways (135, synced), if its lots are on the auction's field.
function TheContractorAuctions:getWalkways()
    local site = g_currentMission.TheContractor.AuctionSite
    if site == nil or self.auction == nil or site.fieldId ~= self.auction.fieldId then
        return {}
    end
    return site:getWalkways()
end

-- The crowd (134), on a machine with a client, while the lots are out: on
-- the site's walkways, down the aisles, never among the lots. None until
-- the walkways have come.
function TheContractorAuctions:refreshCrowd()
    local auction = self.auction
    local walkways = self:getWalkways()
    local wanted = auction ~= nil and TheContractorAuctions.isOnTheField(auction.state) and #walkways > 0 and
        TCAuctionCrowd.getUnavailableReason() == nil
    if wanted and TheContractorAuctions.sameWalkways(self.crowdWalkways, walkways) then
        -- Up already, or tried on these and it couldn't be.
        return
    end
    if not wanted and self.crowdWalkways == nil then
        return
    end
    self:stopCrowd()
    if wanted then
        TCAuctionCrowd.startOnWalkways(auction.fieldId, walkways, TCAuctionCrowd.DEFAULT_PEOPLE)
        self.crowdWalkways = walkways
        if TCAuctionCrowd.active ~= nil then
            self.crowdFieldId = auction.fieldId
        end
    end
end

function TheContractorAuctions:stopCrowd()
    local active = TCAuctionCrowd.active
    if self.crowdFieldId ~= nil and active ~= nil and active.fieldId == self.crowdFieldId then
        TCAuctionCrowd.stop()
    end
    self.crowdFieldId = nil
    self.crowdWalkways = nil
end

-- Client: the in-game map, on the site's marker (the inbox's Show on map).
function TheContractorAuctions:showOnMap()
    local menu = g_inGameMenu
    if self.marker == nil or menu == nil or menu.openMapOverview == nil then
        return
    end
    menu:openMapOverview()
    local page = menu.pageMapOverview
    if page ~= nil and page.showMapHotspot ~= nil then
        page:showMapHotspot(self.marker)
    end
end

function TheContractorAuctions:delete()
    self:removeMarker()
    self:stopCrowd()
end

-- Persistence ---------------------------------------------------------------------------------

function TheContractorAuctions:saveToXmlFile(xmlFile)
    if not g_currentMission:getIsServer() then
        return
    end
    local key = TheContractor.SaveKey .. ".auctions"
    setXMLInt(xmlFile, key .. "#nextId", self.nextId)
    if self.lastEndedPeriodIndex ~= nil then
        setXMLInt(xmlFile, key .. "#lastEndedPeriodIndex", self.lastEndedPeriodIndex)
    end
    local auction = self.auction
    if auction == nil then
        return
    end
    local auctionKey = key .. ".auction"
    setXMLInt(xmlFile, auctionKey .. "#id", auction.id)
    setXMLInt(xmlFile, auctionKey .. "#fieldId", auction.fieldId)
    setXMLInt(xmlFile, auctionKey .. "#hostFarmerId", auction.hostFarmerId)
    setXMLInt(xmlFile, auctionKey .. "#announcedDay", auction.announcedDay)
    setXMLInt(xmlFile, auctionKey .. "#signsDay", auction.signsDay)
    if auction.reminderDay ~= nil then
        setXMLInt(xmlFile, auctionKey .. "#reminderDay", auction.reminderDay)
    end
    setXMLInt(xmlFile, auctionKey .. "#saleDay", auction.saleDay)
    setXMLString(xmlFile, auctionKey .. "#state", auction.state)
    if auction.entrance ~= nil then
        setXMLFloat(xmlFile, auctionKey .. "#entranceX", auction.entrance.x)
        setXMLFloat(xmlFile, auctionKey .. "#entranceZ", auction.entrance.z)
    end
end

function TheContractorAuctions:loadFromXMLFile(xmlFile)
    if not g_currentMission:getIsServer() then
        return
    end
    local key = TheContractor.SaveKey .. ".auctions"
    self.nextId = getXMLInt(xmlFile, key .. "#nextId") or 1
    self.lastEndedPeriodIndex = getXMLInt(xmlFile, key .. "#lastEndedPeriodIndex")
    local auctionKey = key .. ".auction"
    local id = getXMLInt(xmlFile, auctionKey .. "#id")
    if id == nil then
        return
    end
    local auction = {
        id = id,
        fieldId = getXMLInt(xmlFile, auctionKey .. "#fieldId"),
        hostFarmerId = getXMLInt(xmlFile, auctionKey .. "#hostFarmerId"),
        announcedDay = getXMLInt(xmlFile, auctionKey .. "#announcedDay"),
        signsDay = getXMLInt(xmlFile, auctionKey .. "#signsDay"),
        reminderDay = getXMLInt(xmlFile, auctionKey .. "#reminderDay"),
        saleDay = getXMLInt(xmlFile, auctionKey .. "#saleDay"),
        state = getXMLString(xmlFile, auctionKey .. "#state"),
    }
    local entranceX = getXMLFloat(xmlFile, auctionKey .. "#entranceX")
    if entranceX ~= nil then
        auction.entrance = { x = entranceX, z = getXMLFloat(xmlFile, auctionKey .. "#entranceZ") }
    end
    if auction.fieldId == nil or auction.hostFarmerId == nil or auction.saleDay == nil or
            STATE_INDEX[auction.state] == nil or auction.state == STATE.OVER then
        TCLog.xmlWarning(xmlFile, "TheContractor: skipping auction %d", id)
        return
    end
    auction.announcedDay = auction.announcedDay or auction.saleDay
    auction.signsDay = auction.signsDay or auction.saleDay
    self.nextId = math.max(self.nextId, id + 1)
    self:applySync(auction)
end

function TheContractorAuctions:writeInitialClientState(streamId, connection)
    TCAuctionEvent.writeAuction(streamId, self.auction)
end

function TheContractorAuctions:readInitialClientState(streamId, connection)
    self:applySync(TCAuctionEvent.readAuction(streamId))
end

-- Console ---------------------------------------------------------------------------------------

function TheContractorAuctions:describe()
    local auction = self.auction
    if auction == nil then
        return "There's no auction announced. 'tcCompany auction start' announces one."
    end
    local farmers = g_currentMission.TheContractor.Farmers
    local host = farmers ~= nil and farmers:getPerson(auction.hostFarmerId) or nil
    local lines = {
        string.format("Auction %d on field %d, held by %s: %s.", auction.id, auction.fieldId,
            host ~= nil and host.name or ("farmer " .. auction.hostFarmerId), auction.state),
        string.format("  Announced %s; signs up %s; reminder %s; sale %s (viewing and bidding from %02d:00, lots closing from %02d:00).",
            TCCalendar.formatDay(auction.announcedDay), TCCalendar.formatDay(auction.signsDay),
            auction.reminderDay ~= nil and TCCalendar.formatDay(auction.reminderDay) or "none",
            TCCalendar.formatDay(auction.saleDay), TheContractorAuctions.SALE_HOUR,
            TheContractorAuctionSite.CLOSE_HOURS[1]),
    }
    if auction.entrance ~= nil then
        table.insert(lines, string.format("  Entrance at %.0f, %.0f.", auction.entrance.x, auction.entrance.z))
    end
    return table.concat(lines, "\n")
end

-- tcCompany auction start [fieldId] [days].
function TheContractorAuctions:consoleStart(fieldId, days)
    if self.auction ~= nil then
        return "There's an auction already: 'tcCompany auction cancel' first."
    end
    local site = nil
    if fieldId ~= nil then
        local reason
        site, reason = TheContractorAuctions.getFieldSite(fieldId)
        if site == nil then
            return reason
        end
    end
    local saleDay
    if days ~= nil then
        saleDay = getToday() + days
    else
        local lead = TheContractorAuctions.LEAD_MONTHS
        local months = lead[1] + math.floor(math.random() * (lead[2] - lead[1] + 1))
        saleDay = TheContractorAuctions.findSaleDay(TCCalendar.getPeriodIndex() + months, math.random)
        if saleDay == nil then
            return "No sale day could be found that far ahead."
        end
    end
    local auction, reason = self:announce(site, saleDay, math.random)
    if auction == nil then
        return reason
    end
    return self:describe()
end

-- tcCompany auction day: the sale's today, the lots out now.
function TheContractorAuctions:consoleSaleDay()
    local auction = self.auction
    if auction == nil then
        return "There's no auction announced."
    end
    local today = getToday()
    if auction.saleDay ~= today then
        auction.saleDay = today
        auction.signsDay = math.min(auction.signsDay, today)
        auction.reminderDay = nil
        self:advance(today, getHour())
        self:postMessages("today", true)
        self:sync()
    end
    return self:describe()
end

function TheContractorAuctions.registerConsoleCommands()
    TCConsole.register("company", "auction", {
        args = "[start [fieldId|auto] [days]|day|cancel|lots|bid <lot> <amount|guide|off>|close [lot|all]]",
        description = "The machinery auction: show it, announce one, jump to its sale day, cancel it; its lots, bids and closing",
        run = function(farmId, args)
            local auctions = g_currentMission.TheContractor.Auctions
            local sub = args[1] ~= nil and string.lower(args[1]) or nil
            if sub == nil then
                return auctions:describe()
            elseif sub == "start" then
                -- "auto" picks the field by 135's rules, so days can still be given.
                local isAuto = args[2] ~= nil and string.lower(args[2]) == "auto"
                local fieldId = args[2] ~= nil and not isAuto and tonumber(args[2]) or nil
                local days = args[3] ~= nil and tonumber(args[3]) or nil
                if (args[2] ~= nil and not isAuto and fieldId == nil) or
                        (args[3] ~= nil and (days == nil or days < 1)) or args[4] ~= nil then
                    return false
                end
                return auctions:consoleStart(fieldId, days ~= nil and math.floor(days) or nil)
            elseif sub == "day" and args[2] == nil then
                return auctions:consoleSaleDay()
            elseif sub == "cancel" and args[2] == nil then
                if not auctions:cancel(true) then
                    return "There's no auction announced."
                end
                return "Auction cancelled: everything's cleared away and every company told."
            elseif sub == "lots" and args[2] == nil then
                -- 139: the lots, their bids and (a tuning aid) the room's.
                return g_currentMission.TheContractor.AuctionSale:describeLots()
            elseif sub == "bid" then
                local lotNumber = tonumber(args[2] or "")
                local value = args[3] ~= nil and string.lower(args[3]) or nil
                if lotNumber == nil or value == nil or args[4] ~= nil then
                    return false
                end
                return g_currentMission.TheContractor.AuctionSale:consoleBid(farmId, math.floor(lotNumber), value)
            elseif sub == "close" and args[3] == nil then
                local which = args[2] ~= nil and string.lower(args[2]) or nil
                if which ~= nil and which ~= "all" and tonumber(which) == nil then
                    return false
                end
                return g_currentMission.TheContractor.AuctionSale:consoleClose(which)
            end
            return false
        end,
    })
end
