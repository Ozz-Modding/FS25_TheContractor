-- A public day out on a farmer's field (163): the part of 137's machinery
-- auction that isn't about lots, pulled out so other kinds of day (165's
-- agricultural show) share it. A kind is a subclass (Auctions, OpenDay)
-- that sets its own settings (below) and fills in the hooks; this holds
-- the day's life:
--
--   The schedule (server): on the first day of each month, a roll
--     (getChanceAfter): none for MIN_GAP_MONTHS after the kind's last one
--     ended, then a chance that grows each month. A hit announces one
--     LEAD_MONTHS ahead (in months, so it scales with days per period) on a
--     day in one of EVENT_PERIODS (the game's seasonal periods). A kind
--     with no ANNOUNCE_CHANCE_BASE never rolls (the console's only). Never
--     while any kind has one (tc.PublicEvents: one at a time, whatever the
--     kind, from announcement to clear-up).
--   The site (server) is chosen at the announcement: a field nobody's farm
--     owns, held by a farmer (110, the host), with no live job, by the
--     kind's pickSite. From the announcement it's protected (Jobs:
--     isFieldProtected, through tc.PublicEvents).
--   Changing hands (server, hourly and when farmland's bought): the field
--     bought or gone to another farmer cancels it, with a message to every
--     company farm. A retirement hands it to the successor (Farmers:
--     replacePersonReferences, through tc.PublicEvents).
--   The days (getEventStateFor, pure): announced; signs up SIGNS_MONTHS
--     before (136's signs, with the kind's face); set out at midnight
--     starting the day (the kind's onStateEntered: the auction's lots, an
--     open day's bare ground); on from START_HOUR; after from END_HOUR,
--     for AFTER_DAYS more days; over at the next midnight: the site
--     cleared (and its ground put back, 143), the signs down, the crowd
--     down, the field released and the messages gone. A state skipped
--     over (a long sleep) does nothing it would only undo.
--   Players (every machine): a map marker at the field from the
--     announcement, for every farm, with a Visit to the entrance. Company
--     farms get the inbox (a kind with TEXTS): the announcement, a reminder
--     a week before (REMINDER_MONTHS, scaled) and one on the morning, each
--     from the host (fromFarmer, named live) with Show on map (client only).
--   The crowd (134, 140), on a machine with a client, while it's on the
--     field: on the site's walkways, dressed from the site's scene (135's
--     AuctionSite holds the one site, whatever the kind).
--
-- Saved in TheContractor.xml (each kind under its SAVE_KEY), in the initial
-- client state, and sent to every machine with the kind's sync event.
-- Nothing is kept by farm.
--
-- A kind sets, on its own class:
--   KIND (its inbox kind and its signs' face), TC_KEY (its field on
--   g_currentMission.TheContractor), NAME/TITLE (the console's words),
--   SAVE_KEY/SAVE_EVENT_KEY, PAYLOAD_ID (its messages' payload key for the
--   event's id), TEXTS (nil: no inbox), MAP_NAME_KEY, START_HOUR,
--   END_HOUR, AFTER_DAYS, SIGNS_MONTHS, REMINDER_MONTHS, LEAD_MONTHS,
--   EVENT_PERIODS, MIN_GAP_MONTHS, ANNOUNCE_CHANCE_BASE/STEP, TOP_PICKS.
-- and the hooks below that it needs.

TheContractorEventDay = {}
local TheContractorEventDay_mt = Class(TheContractorEventDay)

TheContractorEventDay.SHOW_ON_MAP_ACTION = { key = "showOnMap", textKey = "tc_auction_showOnMap" }
TheContractorEventDay.MAX_SEARCH_DAYS = 2000
TheContractorEventDay.TOP_PICKS = 3

TheContractorEventDay.STATE = {
    ANNOUNCED = "announced",
    SIGNS_UP = "signsUp",
    SET_OUT = "setOut",
    ON = "on",
    AFTER = "after",
    OVER = "over",
}
local STATE = TheContractorEventDay.STATE
TheContractorEventDay.STATE_ORDER = { STATE.ANNOUNCED, STATE.SIGNS_UP, STATE.SET_OUT, STATE.ON, STATE.AFTER,
    STATE.OVER }
-- A save from before 163 called the auction's on and after states these.
TheContractorEventDay.LEGACY_STATES = { onSale = STATE.ON, collection = STATE.AFTER }
local STATE_INDEX = {}
for index, state in ipairs(TheContractorEventDay.STATE_ORDER) do
    STATE_INDEX[state] = index
end

-- A kind's new() calls this with its own metatable.
function TheContractorEventDay.new(mt)
    local self = setmetatable({}, mt or TheContractorEventDay_mt)
    -- Every machine, as the server sent it: the event, or nil. { id,
    -- fieldId, hostFarmerId, announcedDay, signsDay, reminderDay (nil for
    -- none), day, state, entrance = { x, z } or nil }, plus anything the
    -- kind keeps on the server only.
    self.event = nil
    -- Server: the next id, and the month (absolute period index) the last
    -- one ended or was called off (nil: none yet on this save).
    self.nextId = 1
    self.lastEndedPeriodIndex = nil
    -- Every machine with a map: the site's marker, rebuilt on the next
    -- update after the event changes; and the field this machine put a
    -- crowd on.
    self.marker = nil
    self.isDirty = false
    self.crowdFieldId = nil
    return self
end

-- Every machine, at load, before the save loads: the kind's messages (a
-- kind with TEXTS).
function TheContractorEventDay:register(inbox)
    if self.TEXTS == nil or inbox == nil then
        return
    end
    local tcKey = self.TC_KEY
    inbox:registerMessageKind(self.KIND, {
        category = "job",
        fromFarmer = true,
        getArgs = function(message)
            return TheContractorEventDay.getMessageArgs(message)
        end,
        onClientAction = function(message, actionKey)
            if actionKey ~= TheContractorEventDay.SHOW_ON_MAP_ACTION.key then
                return false
            end
            local kind = g_currentMission.TheContractor[tcKey]
            if kind ~= nil then
                kind:showOnMap()
            end
            return true
        end,
    })
end

-- Queries (every machine) ----------------------------------------------------------------

function TheContractorEventDay:getEvent()
    return self.event
end

function TheContractorEventDay:isFieldInUse(fieldId)
    return fieldId ~= nil and self.event ~= nil and self.event.fieldId == fieldId
end

function TheContractorEventDay.getStateIndex(state)
    return STATE_INDEX[state] or 0
end

-- Whether the site's set out and the crowd's up.
function TheContractorEventDay.isOnTheField(state)
    local index = STATE_INDEX[state] or 0
    return index >= STATE_INDEX[STATE.SET_OUT] and index < STATE_INDEX[STATE.OVER]
end

-- A message's args (client): the host's name as it is now, the field's
-- name, then the date as posted.
function TheContractorEventDay.getMessageArgs(message)
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
function TheContractorEventDay.periodAfter(period, months)
    return (period - 1 + months) % Environment.PERIODS_IN_YEAR + 1
end

-- The leads (months ahead, from lead[1] to lead[2]) from this period whose
-- month is one of periods.
function TheContractorEventDay.getEventLeadChoices(period, lead, periods)
    local leads = {}
    for months = lead[1], lead[2] do
        if periods[TheContractorEventDay.periodAfter(period, months)] then
            table.insert(leads, months)
        end
    end
    return leads
end

-- The state an event should be in on a day at an hour (monotonic day,
-- 0-23): on from startHour, after from endHour, for afterDays more days.
function TheContractorEventDay.getEventStateFor(event, today, hour, startHour, endHour, afterDays)
    if today > event.day + afterDays then
        return STATE.OVER
    elseif today > event.day then
        return STATE.AFTER
    end
    if today == event.day then
        if hour < startHour then
            return STATE.SET_OUT
        elseif hour < endHour then
            return STATE.ON
        end
        return STATE.AFTER
    end
    if today >= event.signsDay then
        return STATE.SIGNS_UP
    end
    return STATE.ANNOUNCED
end

-- An event's days, from its announcement and day and that month's days per
-- period: signs signsMonths before (never before the announcement), the
-- reminder reminderMonths before (none if that's not after the
-- announcement, or would be the day itself).
function TheContractorEventDay.planEventDays(announcedDay, day, daysPerPeriod, signsMonths, reminderMonths)
    local signsDay = math.max(announcedDay, day - math.floor(signsMonths * daysPerPeriod + 0.5))
    local reminderDay = day - math.max(1, math.floor(reminderMonths * daysPerPeriod + 0.5))
    if reminderDay <= announcedDay then
        reminderDay = nil
    end
    return signsDay, reminderDay
end

-- The chance of an announcement this month, months after the last ended:
-- none for minGap months, then base, growing by step a month.
function TheContractorEventDay.getChanceAfter(monthsSince, minGap, base, step)
    if monthsSince < minGap then
        return 0
    end
    return math.min(1, base + step * (monthsSince - minGap))
end

local function getToday()
    return g_currentMission.environment.currentMonotonicDay
end

local function getHour()
    return g_currentMission.environment.currentHour or 0
end

-- A day in a month (an absolute period index) ahead, at random, or nil if
-- it's further off than MAX_SEARCH_DAYS.
function TheContractorEventDay.findDayIn(periodIndex, random)
    local today = getToday()
    for offset = 1, TheContractorEventDay.MAX_SEARCH_DAYS do
        local index, _, daysPerPeriod = TCCalendar.getDayInfo(today + offset)
        if index == periodIndex then
            return today + offset + math.min(daysPerPeriod - 1, math.floor(random() * daysPerPeriod))
        elseif index > periodIndex then
            return nil
        end
    end
    return nil
end

-- 161: an announced event's day moved from one calendar to the other (to
-- the start of its share of the month), or nil if it stays: none
-- announced, set out already, or the day's today or gone.
function TheContractorEventDay.getMovedDay(event, fromModel, toModel, today)
    if event == nil or event.day <= today or
            TheContractorEventDay.getStateIndex(event.state) >= STATE_INDEX[STATE.SET_OUT] then
        return nil
    end
    local day = TCCalendar.remapDay(event.day, fromModel, toModel, false)
    return day ~= event.day and day or nil
end

-- The kind's own, on its settings.
function TheContractorEventDay:getKindStateFor(event, today, hour)
    return TheContractorEventDay.getEventStateFor(event, today, hour, self.START_HOUR, self.END_HOUR,
        self.AFTER_DAYS or 0)
end

function TheContractorEventDay:planDaysFor(announcedDay, day, daysPerPeriod)
    return TheContractorEventDay.planEventDays(announcedDay, day, daysPerPeriod, self.SIGNS_MONTHS,
        self.REMINDER_MONTHS)
end

-- Hooks (a kind fills in what it needs) ---------------------------------------------------

-- Server: just announced (its messages and marker sent).
function TheContractorEventDay:onAnnounced(event)
end

-- Server: each day and hour while there's one, after it's been brought up
-- to date.
function TheContractorEventDay:onNewDay(event)
end

function TheContractorEventDay:onNewHour(event)
end

-- Server: a state reached other than signs up and over (which this does).
-- passing: days were skipped right past it, so nothing's to be put out.
function TheContractorEventDay:onStateEntered(event, state, passing)
end

-- Server: its day's moved (the calendar, or the console's day now).
function TheContractorEventDay:onDayMoved(event)
end

-- Server: it's over, before the site's cleared.
function TheContractorEventDay:onFinish(event)
end

-- Server: called off, before the site's cleared, then after the farms are
-- told.
function TheContractorEventDay:onCancel(event)
end

function TheContractorEventDay:onCancelled(event)
end

-- How many people come (the crowd, 134).
function TheContractorEventDay:getCrowdPeople(scene)
    return TCAuctionCrowd.DEFAULT_PEOPLE
end

-- The map marker's name.
function TheContractorEventDay:getMapName()
    return g_i18n:getText(self.MAP_NAME_KEY)
end

-- The console's line on its day and hours.
function TheContractorEventDay:describeDay(event)
    return string.format("the day %s (from %02d:00 to %02d:00)", TCCalendar.formatDay(event.day), self.START_HOUR,
        self.END_HOUR)
end

-- Server: anything the kind saves beside the event, and reads back.
function TheContractorEventDay:saveEventExtra(xmlFile, key, event)
end

function TheContractorEventDay:loadEventExtra(xmlFile, key, event)
end

-- Server: the event to every client.
function TheContractorEventDay:newSyncEvent(event)
    return TCEventDayEvent.new(self.KIND, event)
end

-- Server ----------------------------------------------------------------------------------

function TheContractorEventDay:startListening()
    if not g_currentMission:getIsServer() then
        return
    end
    g_messageCenter:subscribe(MessageType.DAY_CHANGED, self.onDayChanged, self)
    g_messageCenter:subscribe(MessageType.HOUR_CHANGED, self.onHourChanged, self)
    g_messageCenter:subscribe(MessageType.FARMLAND_OWNER_CHANGED, self.onFarmlandOwnerChanged, self)
end

function TheContractorEventDay:stopListening()
    if g_messageCenter ~= nil then
        g_messageCenter:unsubscribeAll(self)
    end
end

-- Another kind's event, if there's one: none's announced while it is.
function TheContractorEventDay:getOtherEvent()
    local publicEvents = g_currentMission.TheContractor.PublicEvents
    if publicEvents == nil then
        return nil, nil
    end
    return publicEvents:getOtherEvent(self)
end

-- 161, every machine (TCCalendarChange, through tc.PublicEvents): the day
-- moved to the same date. Each machine moves the date in its own copies of
-- the kind's messages; the server moves the event's days (signs and
-- reminder planned again round the new day, any already been left as they
-- were) and tells the clients.
function TheContractorEventDay:remapDates(fromModel, toModel)
    local event = self.event
    local today = getToday()
    local day = TheContractorEventDay.getMovedDay(event, fromModel, toModel, today)
    if day == nil then
        return
    end

    local inbox = g_currentMission.TheContractor.Inbox
    for _, message in pairs(inbox ~= nil and inbox.messagesById or {}) do
        if message.kind == self.KIND and message.payload ~= nil and
                message.payload[self.PAYLOAD_ID] == event.id and message.args ~= nil then
            message.args[1] = string.format("$days_%d_%d", day, day)
        end
    end

    if not g_currentMission:getIsServer() then
        return
    end
    local _, _, daysPerPeriod = TCCalendar.getDayInfo(day, toModel)
    local signsDay, reminderDay = self:planDaysFor(event.announcedDay, day, daysPerPeriod)
    if event.signsDay <= today then
        signsDay = event.signsDay
    end
    if event.reminderDay ~= nil and event.reminderDay <= today then
        reminderDay = event.reminderDay
    elseif reminderDay ~= nil and reminderDay <= today then
        reminderDay = nil
    end
    TCLog.info("TheContractor: %s %d moved with the calendar: day %d (was %d), signs day %d", self.NAME, event.id,
        day, event.day, signsDay)
    event.day = day
    event.signsDay = signsDay
    event.reminderDay = reminderDay
    self:advance(today, getHour())
    self:sync()
    self:onDayMoved(event)
end

function TheContractorEventDay:onDayChanged()
    if self.event ~= nil then
        if not self:checkField() then
            return
        end
        self:advance(getToday(), 0)
        self:postDayMessages(getToday())
        if self.event ~= nil then
            self:onNewDay(self.event)
        end
    elseif g_currentMission.environment.currentDayInPeriod == 1 then
        self:rollAnnouncement(math.random)
    end
end

function TheContractorEventDay:onHourChanged()
    if self.event ~= nil and self:checkField() then
        self:advance(getToday(), getHour())
        if self.event ~= nil then
            self:onNewHour(self.event)
        end
    end
end

function TheContractorEventDay:onFarmlandOwnerChanged(farmlandId, farmId, loadFromSavegame)
    if self.event ~= nil and not loadFromSavegame then
        self:checkField()
    end
end

-- Server: the month's roll. Returns the event announced, or nil.
function TheContractorEventDay:rollAnnouncement(random)
    if self.event ~= nil or self.ANNOUNCE_CHANCE_BASE == nil or self:getOtherEvent() ~= nil then
        return nil
    end
    local periodIndex = TCCalendar.getPeriodIndex()
    -- A save's first: counted as if one had ended just long enough ago.
    if self.lastEndedPeriodIndex == nil then
        self.lastEndedPeriodIndex = periodIndex - self.MIN_GAP_MONTHS
    end
    local leads = TheContractorEventDay.getEventLeadChoices(g_currentMission.environment.currentPeriod,
        self.LEAD_MONTHS, self.EVENT_PERIODS)
    if #leads == 0 then
        return nil
    end
    local chance = TheContractorEventDay.getChanceAfter(periodIndex - self.lastEndedPeriodIndex, self.MIN_GAP_MONTHS,
        self.ANNOUNCE_CHANCE_BASE, self.ANNOUNCE_CHANCE_STEP)
    if random() >= chance then
        return nil
    end
    local lead = leads[math.min(#leads, math.floor(random() * #leads) + 1)]
    local day = TheContractorEventDay.findDayIn(TCCalendar.getPeriodIndex() + lead, random)
    if day == nil then
        return nil
    end
    return self:announce(nil, day, random)
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
TheContractorEventDay.getHolder = getHolder

-- Server: the site for a new event: { fieldId, hostId, entrance }, or nil
-- with no field that qualifies. By 135's ranking of the fields that could
-- hold a sale, picked at random among the best TOP_PICKS that a farmer
-- holds.
function TheContractorEventDay:pickSite(random)
    local site = g_currentMission.TheContractor.AuctionSite
    local ranked = site:getCandidates(TheContractorAuctionSite.PREFERRED_LOTS)
    local picks = {}
    for _, candidate in ipairs(ranked) do
        if #candidate.problems == 0 then
            local holder = getHolder(g_fieldManager:getFieldById(candidate.fieldId))
            if holder ~= nil then
                table.insert(picks, { fieldId = candidate.fieldId, hostId = holder.id, entrance = candidate.entrance })
                if #picks >= self.TOP_PICKS then
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
function TheContractorEventDay:getFieldSite(fieldId)
    local field = g_fieldManager:getFieldById(fieldId)
    if field == nil then
        return nil, string.format("No field %d.", fieldId)
    end
    local refusal = TheContractorAuctionSite.getFieldRefusal(field)
    if refusal ~= nil then
        return nil, string.format("Field %d can't hold the %s: %s.", fieldId, self.NAME, refusal)
    end
    local holder = getHolder(field)
    if holder == nil then
        return nil, string.format("Field %d can't hold the %s: no farmer holds it.", fieldId, self.NAME)
    end
    local entrance = TCAuctionLayout.findEntrance(TCAuctionCrowd.getFieldPolygon(field),
        TheContractorFallenTree.sampleRoads(), TCAuctionLayout.RULES.entranceReach)
    return { fieldId = fieldId, hostId = holder.id, entrance = entrance }
end

-- Server: announces one for a day ahead, on a site (or one picked).
-- Returns the event, or nil and why not.
function TheContractorEventDay:announce(site, day, random)
    if self.event ~= nil then
        return nil, string.format("There's %s already.", self:getArticleName())
    end
    local otherKind = self:getOtherEvent()
    if otherKind ~= nil then
        return nil, string.format("There's %s announced: one at a time.", otherKind:getArticleName())
    end
    site = site or self:pickSite(random or math.random)
    if site == nil then
        TCLog.info("TheContractor: no field can hold the %s, none announced", self.NAME)
        return nil, string.format("No field can hold the %s.", self.NAME)
    end
    local today = getToday()
    local signsDay, reminderDay = self:planDaysFor(today, day, TCCalendar.getDaysPerPeriodOn(day))
    local event = {
        id = self.nextId,
        fieldId = site.fieldId,
        hostFarmerId = site.hostId,
        announcedDay = today,
        signsDay = signsDay,
        reminderDay = reminderDay,
        day = day,
        state = STATE.ANNOUNCED,
        entrance = site.entrance ~= nil and { x = site.entrance.x, z = site.entrance.z } or nil,
    }
    self.nextId = self.nextId + 1
    self.event = event
    TCLog.info("TheContractor: %s %d announced on field %d (host %d) for day %d, signs day %d", self.NAME, event.id,
        event.fieldId, event.hostFarmerId, day, signsDay)
    self:postMessages("announced", true)
    -- The signs may be due already (a short lead).
    self:advance(today, getHour())
    self:sync()
    if self.event == event then
        self:onAnnounced(event)
    end
    return event
end

-- "an auction", "an open day": the console's.
function TheContractorEventDay:getArticleName()
    local first = string.sub(self.NAME, 1, 1)
    local article = string.find("aeiou", first, 1, true) ~= nil and "an" or "a"
    return article .. " " .. self.NAME
end

-- Server: posts one of the kind's messages to every company farm, replacing
-- its earlier ones. withMap: a Show on map action. Nothing for a kind
-- without TEXTS.
function TheContractorEventDay:postMessages(textKey, withMap)
    local texts = self.TEXTS ~= nil and self.TEXTS[textKey] or nil
    if texts == nil then
        return
    end
    local tc = g_currentMission.TheContractor
    local event = self.event
    self:removeMessages(event.id)
    local actions = { TheContractorInbox.DISMISS_ACTION }
    if withMap then
        actions = { TheContractorEventDay.SHOW_ON_MAP_ACTION, TheContractorInbox.DISMISS_ACTION }
    end
    for _, farmId in ipairs(tc.RandomEvents:getCompanyFarmIds()) do
        tc.Inbox:postMessage(farmId, self.KIND, texts.title, texts.body,
            { string.format("$days_%d_%d", event.day, event.day) }, actions,
            { [self.PAYLOAD_ID] = event.id, farmerId = event.hostFarmerId, fieldId = event.fieldId })
    end
end

-- Server: every message about an event goes.
function TheContractorEventDay:removeMessages(eventId)
    local inbox = g_currentMission.TheContractor.Inbox
    if self.TEXTS == nil or inbox == nil then
        return
    end
    local ids = {}
    for id, message in pairs(inbox.messagesById) do
        if message.kind == self.KIND and message.payload[self.PAYLOAD_ID] == eventId then
            table.insert(ids, id)
        end
    end
    table.sort(ids)
    for _, id in ipairs(ids) do
        inbox:removeMessage(id)
    end
end

-- Server, each day: the reminder a week before, and one on the morning.
function TheContractorEventDay:postDayMessages(today)
    local event = self.event
    if event == nil then
        return
    end
    if today == event.day then
        self:postMessages("today", true)
    elseif event.reminderDay ~= nil and today == event.reminderDay then
        self:postMessages("reminder", true)
    end
end

-- Server: whether the field's still the host's. If not, it's cancelled
-- (and false returned).
function TheContractorEventDay:checkField()
    local event = self.event
    -- Until a load's farmers are set up (TheContractor:resolveSavedVehicles),
    -- nobody holds anything yet.
    if not g_currentMission.TheContractor.hasResolvedSavedVehicles then
        return true
    end
    local field = g_fieldManager:getFieldById(event.fieldId)
    local holder = field ~= nil and field:getOwner() == FarmlandManager.NO_OWNER_FARM_ID and getHolder(field) or nil
    if holder ~= nil and holder.id == event.hostFarmerId then
        return true
    end
    TCLog.info("TheContractor: %s %d's field %d has changed hands, cancelled", self.NAME, event.id, event.fieldId)
    self:cancel(true)
    return false
end

-- Server: brings the event up to the day and hour, a state at a time.
function TheContractorEventDay:advance(today, hour)
    local event = self.event
    if event == nil then
        return
    end
    local target = self:getKindStateFor(event, today, hour)
    local targetIndex = STATE_INDEX[target]
    local changed = false
    while self.event == event and STATE_INDEX[event.state] < targetIndex do
        local nextState = TheContractorEventDay.STATE_ORDER[STATE_INDEX[event.state] + 1]
        event.state = nextState
        changed = true
        self:enterState(event, nextState, target)
    end
    if changed and self.event == event then
        self:sync()
    end
end

-- Server: what happens as an event reaches a state. With the target past
-- it (days skipped), nothing's put out only to be taken away.
function TheContractorEventDay:enterState(event, state, target)
    local tc = g_currentMission.TheContractor
    local passing = target == STATE.OVER
    TCLog.info("TheContractor: %s %d now %s", self.NAME, event.id, state)
    if state == STATE.SIGNS_UP then
        if not passing then
            local period = select(1, TCCalendar.getDayInfo(event.day))
            period = (period - 1) % Environment.PERIODS_IN_YEAR + 1
            tc.AuctionSigns:place(TCCalendar.getMonth(period), self.KIND)
        end
    elseif state == STATE.OVER then
        self:finish()
    else
        self:onStateEntered(event, state, passing)
    end
end

-- Server: takes everything away: the site (its ground put back), the
-- signs, the messages; the field's released.
function TheContractorEventDay:clearAway()
    local tc = g_currentMission.TheContractor
    local event = self.event
    local site = tc.AuctionSite
    if site.site ~= nil and site.site.fieldId == event.fieldId then
        site:clear()
    end
    local signs = tc.AuctionSigns
    if (signs.month ~= 0 or #signs.signs > 0) and (signs.face == nil or signs.face == self.KIND) then
        signs:clear()
    end
    self:removeMessages(event.id)
end

-- Server: it's over.
function TheContractorEventDay:finish()
    local event = self.event
    self:onFinish(event)
    self:clearAway()
    self.event = nil
    -- The wait's from its month (an after day can run into the next).
    self.lastEndedPeriodIndex = math.min(TCCalendar.getPeriodIndex(), (TCCalendar.getDayInfo(event.day)))
    TCLog.info("TheContractor: %s %d over, field %d released", self.NAME, event.id, event.fieldId)
    self:sync()
end

-- Server: called off. tellFarms: a message to every company farm.
function TheContractorEventDay:cancel(tellFarms)
    local event = self.event
    if event == nil then
        return false
    end
    self:onCancel(event)
    self:clearAway()
    if tellFarms then
        self:postMessages("cancelled", false)
    end
    self:onCancelled(event)
    self.event = nil
    self.lastEndedPeriodIndex = TCCalendar.getPeriodIndex()
    TCLog.info("TheContractor: %s %d cancelled", self.NAME, event.id)
    self:sync()
    return true
end

-- Server: the event to this machine and every client.
function TheContractorEventDay:sync()
    self:applySync(self.event)
    if g_server ~= nil then
        g_server:broadcastEvent(self:newSyncEvent(self.event))
    end
end

-- Server (the console's): the day's today, set out now.
function TheContractorEventDay:moveToToday()
    local event = self.event
    local today = getToday()
    event.day = today
    event.signsDay = math.min(event.signsDay, today)
    event.reminderDay = nil
    self:advance(today, getHour())
    if self.event ~= event then
        return
    end
    self:postMessages("today", true)
    self:sync()
    self:onDayMoved(event)
end

-- Every machine ------------------------------------------------------------------------------

-- The event as the server sent it, or nil.
function TheContractorEventDay:applySync(event)
    self.event = event
    self.isDirty = true
end

function TheContractorEventDay:update(dt)
    if self.isDirty then
        self.isDirty = false
        self:refreshMarker()
        self:refreshCrowd()
    elseif self.crowdWalkways ~= nil or (self.event ~= nil and TheContractorEventDay.isOnTheField(self.event.state)) then
        -- The walkways come with the site's own event, which may land after
        -- ours: catch them up (cheap when nothing's changed).
        self:refreshCrowd()
    end
end

-- The site's map marker, on a machine with a map: there from the
-- announcement until it's over.
function TheContractorEventDay:refreshMarker()
    self:removeMarker()
    local event = self.event
    if event == nil or g_currentMission.hud == nil or PlaceableHotspot == nil or
            g_currentMission.addMapHotspot == nil then
        return
    end
    local field = g_fieldManager:getFieldById(event.fieldId)
    if field == nil then
        return
    end
    local hotspot = PlaceableHotspot.new()
    hotspot:setName(self:getMapName())
    hotspot:createIcon()
    hotspot:setPlaceableType(PlaceableHotspot.TYPE.EXCLAMATION_MARK)
    local x, z = field:getIndicatorPosition()
    hotspot:setWorldPosition(x, z)
    local entrance = event.entrance
    if entrance ~= nil then
        hotspot:setTeleportWorldPosition(entrance.x,
            getTerrainHeightAtWorldPos(g_terrainNode, entrance.x, 0, entrance.z), entrance.z)
    end
    g_currentMission:addMapHotspot(hotspot)
    self.marker = hotspot
end

function TheContractorEventDay:removeMarker()
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
function TheContractorEventDay.sameWalkways(a, b)
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

-- The site's walkways (135, synced), if it's on the event's field.
function TheContractorEventDay:getWalkways()
    local site = g_currentMission.TheContractor.AuctionSite
    if site == nil or self.event == nil or site.fieldId ~= self.event.fieldId then
        return {}
    end
    return site:getWalkways()
end

-- 140: the site's scene, if it's on the event's field.
function TheContractorEventDay:getScene()
    local site = g_currentMission.TheContractor.AuctionSite
    if site == nil or self.event == nil or site.fieldId ~= self.event.fieldId then
        return nil
    end
    return site:getScene()
end

-- The crowd (134), on a machine with a client, while it's on the field:
-- on the site's walkways, dressed from its scene (140), coming and going
-- through the day (TCAuctionCrowd.getShare), as many as the kind says
-- (getCrowdPeople). None until the walkways have come; put up again if the
-- scene changes (its seed: a client's copy is new with every whole-site
-- event).
function TheContractorEventDay:refreshCrowd()
    local event = self.event
    local walkways = self:getWalkways()
    local scene = self:getScene()
    local seed = scene ~= nil and scene.seed or nil
    local wanted = event ~= nil and TheContractorEventDay.isOnTheField(event.state) and #walkways > 0 and
        TCAuctionCrowd.getUnavailableReason() == nil
    if wanted and TheContractorEventDay.sameWalkways(self.crowdWalkways, walkways) and self.crowdSeed == seed then
        -- Up already, or tried on these and it couldn't be.
        return
    end
    if not wanted and self.crowdWalkways == nil then
        return
    end
    self:stopCrowd()
    if wanted then
        local people = scene ~= nil and self:getCrowdPeople(scene) or TCAuctionCrowd.DEFAULT_PEOPLE
        TCAuctionCrowd.startOnWalkways(event.fieldId, walkways, people, { scene = scene, useHours = true })
        self.crowdWalkways = walkways
        self.crowdSeed = seed
        if TCAuctionCrowd.active ~= nil then
            self.crowdFieldId = event.fieldId
        end
    end
end

function TheContractorEventDay:stopCrowd()
    local active = TCAuctionCrowd.active
    if self.crowdFieldId ~= nil and active ~= nil and active.fieldId == self.crowdFieldId then
        TCAuctionCrowd.stop()
    end
    self.crowdFieldId = nil
    self.crowdWalkways = nil
    self.crowdSeed = nil
end

-- Client: the in-game map, on the site's marker (the inbox's Show on map).
function TheContractorEventDay:showOnMap()
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

function TheContractorEventDay:delete()
    self:removeMarker()
    self:stopCrowd()
end

-- Streams (the kinds' sync events and the initial client state) -----------------------------

function TheContractorEventDay.writeEvent(streamId, event)
    if not streamWriteBool(streamId, event ~= nil) then
        return
    end
    streamWriteInt32(streamId, event.id)
    streamWriteInt32(streamId, event.fieldId)
    streamWriteInt32(streamId, event.hostFarmerId)
    streamWriteInt32(streamId, event.announcedDay)
    streamWriteInt32(streamId, event.signsDay)
    streamWriteInt32(streamId, event.reminderDay or -1)
    streamWriteInt32(streamId, event.day)
    streamWriteUInt8(streamId, TheContractorEventDay.getStateIndex(event.state))
    if streamWriteBool(streamId, event.entrance ~= nil) then
        streamWriteFloat32(streamId, event.entrance.x)
        streamWriteFloat32(streamId, event.entrance.z)
    end
end

-- Returns the event, or nil.
function TheContractorEventDay.readEvent(streamId)
    if not streamReadBool(streamId) then
        return nil
    end
    local event = {
        id = streamReadInt32(streamId),
        fieldId = streamReadInt32(streamId),
        hostFarmerId = streamReadInt32(streamId),
        announcedDay = streamReadInt32(streamId),
        signsDay = streamReadInt32(streamId),
        reminderDay = streamReadInt32(streamId),
        day = streamReadInt32(streamId),
    }
    if event.reminderDay < 0 then
        event.reminderDay = nil
    end
    event.state = TheContractorEventDay.STATE_ORDER[streamReadUInt8(streamId)] or STATE.ANNOUNCED
    if streamReadBool(streamId) then
        event.entrance = { x = streamReadFloat32(streamId), z = streamReadFloat32(streamId) }
    end
    return event
end

function TheContractorEventDay:writeInitialClientState(streamId, connection)
    TheContractorEventDay.writeEvent(streamId, self.event)
end

function TheContractorEventDay:readInitialClientState(streamId, connection)
    self:applySync(TheContractorEventDay.readEvent(streamId))
end

-- Persistence ---------------------------------------------------------------------------------

function TheContractorEventDay:saveToXmlFile(xmlFile)
    if not g_currentMission:getIsServer() then
        return
    end
    local key = TheContractor.SaveKey .. "." .. self.SAVE_KEY
    setXMLInt(xmlFile, key .. "#nextId", self.nextId)
    if self.lastEndedPeriodIndex ~= nil then
        setXMLInt(xmlFile, key .. "#lastEndedPeriodIndex", self.lastEndedPeriodIndex)
    end
    local event = self.event
    if event == nil then
        return
    end
    local eventKey = key .. "." .. self.SAVE_EVENT_KEY
    setXMLInt(xmlFile, eventKey .. "#id", event.id)
    setXMLInt(xmlFile, eventKey .. "#fieldId", event.fieldId)
    setXMLInt(xmlFile, eventKey .. "#hostFarmerId", event.hostFarmerId)
    setXMLInt(xmlFile, eventKey .. "#announcedDay", event.announcedDay)
    setXMLInt(xmlFile, eventKey .. "#signsDay", event.signsDay)
    if event.reminderDay ~= nil then
        setXMLInt(xmlFile, eventKey .. "#reminderDay", event.reminderDay)
    end
    setXMLInt(xmlFile, eventKey .. "#day", event.day)
    setXMLString(xmlFile, eventKey .. "#state", event.state)
    if event.entrance ~= nil then
        setXMLFloat(xmlFile, eventKey .. "#entranceX", event.entrance.x)
        setXMLFloat(xmlFile, eventKey .. "#entranceZ", event.entrance.z)
    end
    self:saveEventExtra(xmlFile, eventKey, event)
end

function TheContractorEventDay:loadFromXMLFile(xmlFile)
    if not g_currentMission:getIsServer() then
        return
    end
    local key = TheContractor.SaveKey .. "." .. self.SAVE_KEY
    self.nextId = getXMLInt(xmlFile, key .. "#nextId") or 1
    self.lastEndedPeriodIndex = getXMLInt(xmlFile, key .. "#lastEndedPeriodIndex")
    local eventKey = key .. "." .. self.SAVE_EVENT_KEY
    local id = getXMLInt(xmlFile, eventKey .. "#id")
    if id == nil then
        return
    end
    local state = getXMLString(xmlFile, eventKey .. "#state")
    local event = {
        id = id,
        fieldId = getXMLInt(xmlFile, eventKey .. "#fieldId"),
        hostFarmerId = getXMLInt(xmlFile, eventKey .. "#hostFarmerId"),
        announcedDay = getXMLInt(xmlFile, eventKey .. "#announcedDay"),
        signsDay = getXMLInt(xmlFile, eventKey .. "#signsDay"),
        reminderDay = getXMLInt(xmlFile, eventKey .. "#reminderDay"),
        -- An auction saved before 163 kept its saleDay.
        day = getXMLInt(xmlFile, eventKey .. "#day") or getXMLInt(xmlFile, eventKey .. "#saleDay"),
        state = TheContractorEventDay.LEGACY_STATES[state] or state,
    }
    local entranceX = getXMLFloat(xmlFile, eventKey .. "#entranceX")
    if entranceX ~= nil then
        event.entrance = { x = entranceX, z = getXMLFloat(xmlFile, eventKey .. "#entranceZ") }
    end
    if event.fieldId == nil or event.hostFarmerId == nil or event.day == nil or
            STATE_INDEX[event.state] == nil or event.state == STATE.OVER then
        TCLog.xmlWarning(xmlFile, "TheContractor: skipping %s %d", self.NAME, id)
        return
    end
    event.announcedDay = event.announcedDay or event.day
    event.signsDay = event.signsDay or event.day
    self:loadEventExtra(xmlFile, eventKey, event)
    self.nextId = math.max(self.nextId, id + 1)
    self:applySync(event)
end

-- Console ---------------------------------------------------------------------------------------

function TheContractorEventDay:describe()
    local event = self.event
    if event == nil then
        return string.format("There's no %s announced.", self.NAME)
    end
    local farmers = g_currentMission.TheContractor.Farmers
    local host = farmers ~= nil and farmers:getPerson(event.hostFarmerId) or nil
    local lines = {
        string.format("%s %d on field %d, held by %s: %s.", self.TITLE, event.id, event.fieldId,
            host ~= nil and host.name or ("farmer " .. event.hostFarmerId), event.state),
        string.format("  Announced %s; signs up %s; reminder %s; %s.",
            TCCalendar.formatDay(event.announcedDay), TCCalendar.formatDay(event.signsDay),
            event.reminderDay ~= nil and TCCalendar.formatDay(event.reminderDay) or "none", self:describeDay(event)),
    }
    if event.entrance ~= nil then
        table.insert(lines, string.format("  Entrance at %.0f, %.0f.", event.entrance.x, event.entrance.z))
    end
    -- 136's roadside signs, where they are (world x, z), once they're up.
    local signs = g_currentMission.TheContractor.AuctionSigns
    if signs ~= nil and #signs.signs > 0 then
        table.insert(lines, signs:describe())
    elseif event.state == STATE.ANNOUNCED then
        table.insert(lines, "  No signs up yet: they go up on the signs day.")
    end
    return table.concat(lines, "\n")
end

-- The console's start: on a field (nil: one picked), in days (nil: a lead
-- of LEAD_MONTHS). Returns the text to print.
function TheContractorEventDay:consoleStart(fieldId, days)
    if self.event ~= nil then
        return string.format("There's %s already: cancel it first.", self:getArticleName())
    end
    local site = nil
    if fieldId ~= nil then
        local reason
        site, reason = self:getFieldSite(fieldId)
        if site == nil then
            return reason
        end
    end
    local day
    if days ~= nil then
        day = getToday() + days
    else
        local lead = self.LEAD_MONTHS
        local months = lead[1] + math.floor(math.random() * (lead[2] - lead[1] + 1))
        day = TheContractorEventDay.findDayIn(TCCalendar.getPeriodIndex() + months, math.random)
        if day == nil then
            return "No day could be found that far ahead."
        end
    end
    local event, reason = self:announce(site, day, math.random)
    if event == nil then
        return reason
    end
    return self:describe()
end
