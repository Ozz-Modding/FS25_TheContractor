-- The agricultural show (165): once a year a farmer hosts the county show,
-- livestock classes on a grass showground and a ploughing match on stubble
-- next door, all on one day. A kind of public day out on 163's base
-- (TheContractorEventDay has the day's life: the schedule's roll, the
-- site's protection, the announcement, signs, marker, messages, crowd, save
-- and sync); this is what's the show's own:
--
--   The schedule's numbers: every year, in late summer after the main
--     harvest (EVENT_PERIODS), announced 2 to 3 months ahead (LEAD_MONTHS),
--     always if it can be (ANNOUNCE_CHANCE_BASE 1, MIN_GAP_MONTHS keeps it
--     to one a year). The months it's announced in are held for it
--     (HOLDS_PERIODS, tc.PublicEvents): while it's due, no auction is
--     announced then, so an autumn sale can't take the show's year. One
--     public day out at a time, as 163 has it.
--   The site (164's TheContractorShowSite): one farmer's field split into a
--     showground and ploughing ground, or two fields side by side, picked
--     at the announcement and kept there (setPlan). Both fields are
--     protected (isFieldInUse); either changing hands calls it off. The
--     host is the showground field's farmer.
--   Entries close ENTRY_CLOSE_MONTHS before the day (a week, scaled with
--     the month, entriesCloseDay), for the competitions that take them
--     (registerCompetition): 167's livestock classes (ShowLivestock), and
--     170's worker in the ploughing. Players can always plough themselves
--     on the day without entering (169's PloughingMatch).
--   Set out (midnight before): the site's dressed (164: the showground
--     grass, the plots stubble (182), snapshots kept), and the
--     showground laid out as an open site on its rectangle (163's
--     AuctionSite:startOpen, the ground left to 164) with the show's
--     dressing (TCShowScene: ring, pens, stands, trailer lines; the shared
--     car park, food and toilets; the show's gate sign) and the crowd's
--     lanes round them.
--   The day (TIMETABLE): gates at 08:00, judging 10:00, the ploughing
--     11:00-15:00, results at 16:00 (giveResults: each competition's
--     placings, prize money, reputation and the host's opinion, by inbox
--     and a notice), gates shut 18:00. Over at midnight: the site put back
--     to its snapshots, the dressing and signs down, the field released.
--   The attend job (141's, attendShow): every company farm's in the show's
--     month, done by being on the site in its hours.
--   Results stay on the show until the next one's (self.results), so the
--     Show tab can show last year's.
--
-- Saved in TheContractor.xml (.shows), in the initial client state, and
-- sent to every machine with TCShowEvent. The results hold farms (forgetFarm)
-- and farmers (replacePerson).

TheContractorShow = {}
TheContractorShow_mt = Class(TheContractorShow, TheContractorEventDay)

TheContractorShow.KIND = "show"
TheContractorShow.TC_KEY = "Show"
TheContractorShow.NAME = "show"
TheContractorShow.TITLE = "Show"
TheContractorShow.SAVE_KEY = "shows"
TheContractorShow.SAVE_EVENT_KEY = "show"
TheContractorShow.PAYLOAD_ID = "showId"
TheContractorShow.MAP_NAME_KEY = "tc_show_mapName"
TheContractorShow.ATTEND_JOB_TYPE = "attendShow"

-- Every year: one roll a month, certain once it's been MIN_GAP_MONTHS
-- since the last.
TheContractorShow.MIN_GAP_MONTHS = 6
TheContractorShow.ANNOUNCE_CHANCE_BASE = 1
TheContractorShow.ANNOUNCE_CHANCE_STEP = 0
-- Late summer (period 6), after the main harvest.
TheContractorShow.EVENT_PERIODS = { [6] = true }
TheContractorShow.LEAD_MONTHS = { 2, 3 }
-- The months it's announced in (late spring and early summer), held from
-- other kinds while it's due.
TheContractorShow.HOLDS_PERIODS = { [3] = true, [4] = true }
-- Signs a month before; the reminder a week before (when entries close).
TheContractorShow.SIGNS_MONTHS = 1
TheContractorShow.REMINDER_MONTHS = 0.25
TheContractorShow.ENTRY_CLOSE_MONTHS = 0.25
-- "Entries close soon", for a show taking entries: a fortnight before.
TheContractorShow.ENTRY_REMINDER_MONTHS = 0.5
TheContractorShow.START_HOUR = 8
TheContractorShow.END_HOUR = 18
TheContractorShow.AFTER_DAYS = 0
TheContractorShow.JUDGING_HOUR = 10
TheContractorShow.RESULTS_HOUR = 16

-- The day (game time). toHour: it runs until then.
TheContractorShow.TIMETABLE = {
    { key = "gatesOpen", hour = 8 },
    { key = "judging", hour = 10 },
    { key = "ploughing", hour = 11, toHour = 15 },
    { key = "results", hour = 16 },
    { key = "gatesClose", hour = 18 },
}

-- Prize money by placing, at real UK show rates (pounds): a competition's
-- own prize, if it gives one, comes first. Charged through Settings:
-- scaleCost and EconomyScale.
TheContractorShow.PRIZES = { 50, 30, 20 }
-- Reputation by placing, in jobs' worth (GoodNews.getReputationReward), and
-- the host's opinion of the farm (113).
TheContractorShow.PLACING_REPUTATION = { 3, 2, 1 }
TheContractorShow.HOST_OPINION = { 4, 3, 2 }
TheContractorShow.RELATIONSHIP_REASON = "showPlacing"
-- How long the results notice stays (months).
TheContractorShow.NOTICE_MONTHS = 1

TheContractorShow.STATE = TheContractorEventDay.STATE
TheContractorShow.STATE_ORDER = TheContractorEventDay.STATE_ORDER
local STATE = TheContractorEventDay.STATE

-- The message texts, by what they say. Each body names the host first,
-- then the field and the date.
TheContractorShow.TEXTS = {
    announced = { title = "tc_show_announced_title", body = "tc_show_announced_body" },
    entriesClosing = { title = "tc_show_entriesClosing_title", body = "tc_show_entriesClosing_body" },
    reminder = { title = "tc_show_reminder_title", body = "tc_show_reminder_body" },
    today = { title = "tc_show_today_title", body = "tc_show_today_body" },
    results = { title = "tc_show_results_title", body = "tc_show_results_body" },
    cancelled = { title = "tc_show_cancelled_title", body = "tc_show_cancelled_body" },
}

table.insert(FinanceStats.statNames, "tcShowPrizes")
FinanceStats.statNameToIndex["tcShowPrizes"] = #FinanceStats.statNames

function TheContractorShow.new()
    local self = TheContractorEventDay.new(TheContractorShow_mt)
    MoneyType.TC_SHOW_PRIZES = MoneyType.register("tcShowPrizes", "tc_moneyType_showPrizes")
    MoneyType.LAST_ID = MoneyType.LAST_ID + 1
    -- The event also has (every machine) ploughFieldId, entriesCloseDay,
    -- entryReminderDay (nil for none) and resultsGiven.
    -- Every machine: the last show's results, kept until the next one's: {
    --   showId, day, fieldId, hostFarmerId,
    --   placings = { { titleKey, titleArg (167: the competition's own
    --     title for it, "" for none), placing, farmId (0: a farmer's),
    --     farmerId (0: none), entrant (a name), prize (unscaled), paid } },
    -- } or nil.
    self.results = nil
    -- Every machine, at load (167, 169, 170): the day's competitions, in
    -- order (see registerCompetition). Only the server runs them.
    self.competitions = {}
    return self
end

-- Every machine, at load: a competition held on the show day. def: {
--   titleKey      its name's l10n key
--   takesEntries  entries close a week before
--   getPlacings(event) returning { { placing (1-4; 4 is highly
--     commended), farmId (a player's, or nil), farmerId (a farmer's entry,
--     or nil), entrant (a plain name), prize (optional, unscaled pounds),
--     titleArg (optional, 167: a class within it, named by getTitle),
--     reputation, opinion (optional: jobs' worth and the host's opinion,
--     instead of PLACING_REPUTATION and HOST_OPINION) } }
--   getTitle(titleArg)  optional, every machine: a placing's title
--   (server, each optional) onAnnounced(event), onNewDay(event),
--     onHour(event, hour) on the day, onSetOut(event) at midnight before,
--     getPens(event) just before (182: the pens it needs, or nil),
--     onAttended(event, farmId) as a farm's attend job's done (171),
--     onResults(event) once the results are given (169: the lent kit
--     taken away), onFinished(event) at midnight after, before the site's
--     put back, onCancelled(event), replacePerson(oldId, newId) returning a
--     count
-- }.
function TheContractorShow:registerCompetition(key, def)
    local competition = {}
    for name, value in pairs(def) do
        competition[name] = value
    end
    competition.key = key
    competition.takesEntries = def.takesEntries == true
    table.insert(self.competitions, competition)
end

-- Server: each competition's hook, if it has one.
function TheContractorShow:callCompetitions(hook, ...)
    for _, competition in ipairs(self.competitions) do
        if competition[hook] ~= nil then
            competition[hook](...)
        end
    end
end

-- A placing's title on this machine: its competition's own for its
-- titleArg (167's classes), else its titleKey's text.
function TheContractorShow:getPlacingTitle(placing)
    if placing.titleArg ~= nil and placing.titleArg ~= "" then
        for _, competition in ipairs(self.competitions) do
            if competition.titleKey == placing.titleKey and competition.getTitle ~= nil then
                return competition.getTitle(placing.titleArg)
            end
        end
    end
    return placing.titleKey ~= nil and placing.titleKey ~= "" and g_i18n:getText(placing.titleKey) or "-"
end

function TheContractorShow:takesEntries()
    for _, competition in ipairs(self.competitions) do
        if competition.takesEntries then
            return true
        end
    end
    return false
end

-- Queries (every machine) ----------------------------------------------------------------

-- Both fields: the showground's and (when it's another) the ploughing
-- ground's.
function TheContractorShow:isFieldInUse(fieldId)
    local event = self.event
    return fieldId ~= nil and event ~= nil and (event.fieldId == fieldId or event.ploughFieldId == fieldId)
end

-- The fields the site's on (attendance, 141).
function TheContractorShow:getSiteFieldIds(event)
    event = event or self.event
    if event == nil then
        return {}
    end
    if event.ploughFieldId ~= nil and event.ploughFieldId ~= event.fieldId then
        return { event.fieldId, event.ploughFieldId }
    end
    return { event.fieldId }
end

function TheContractorShow:getResults()
    return self.results
end

-- Whether entries are still open on a day (pure).
function TheContractorShow.isEntryOpen(event, today)
    return event ~= nil and event.entriesCloseDay ~= nil and today < event.entriesCloseDay
end

-- The entry days for a show day (pure): entries close closeMonths before
-- (at least a day), the "closing soon" reminder reminderMonths before
-- (none if that's not after the announcement or not before the close).
function TheContractorShow.planEntryDays(announcedDay, day, daysPerPeriod, closeMonths, reminderMonths)
    local closeDay = day - math.max(1, math.floor(closeMonths * daysPerPeriod + 0.5))
    local reminderDay = day - math.max(1, math.floor(reminderMonths * daysPerPeriod + 0.5))
    if reminderDay <= announcedDay or reminderDay >= closeDay then
        reminderDay = nil
    end
    return closeDay, reminderDay
end

-- Whether the Show tab's up (pure): in the month of the show announced
-- (periodIndex: today's, absolute), or the month of the last results.
-- eventPeriodIndex/resultsPeriodIndex: nil for none.
function TheContractorShow.isShowMonth(periodIndex, eventPeriodIndex, resultsPeriodIndex)
    return periodIndex == eventPeriodIndex or periodIndex == resultsPeriodIndex
end

-- Every machine: whether the Show tab's up now.
function TheContractorShow:isTabShown()
    local periodIndex = TCCalendar.getDayInfo(g_currentMission.environment.currentMonotonicDay)
    local eventPeriod = self.event ~= nil and (TCCalendar.getDayInfo(self.event.day)) or nil
    local resultsPeriod = self.results ~= nil and (TCCalendar.getDayInfo(self.results.day)) or nil
    return TheContractorShow.isShowMonth(periodIndex, eventPeriod, resultsPeriod)
end

-- The timetable's state at an hour of the show day (pure): for each
-- entry, "done", "now" or "next" (on another day: all "next", or all
-- "done" after it).
function TheContractorShow.getTimetableStates(timetable, today, day, hour)
    local states = {}
    for i, entry in ipairs(timetable) do
        local state = "next"
        if today > day then
            state = "done"
        elseif today == day then
            local nextEntry = timetable[i + 1]
            local ends = entry.toHour or (nextEntry ~= nil and nextEntry.hour) or 24
            if hour >= ends then
                state = "done"
            elseif hour >= entry.hour then
                state = "now"
            end
        end
        states[i] = state
    end
    return states
end

-- The placings' totals for a farm (pure): how many and the prize money
-- paid.
function TheContractorShow.getFarmTotals(results, farmId)
    local count, paid = 0, 0
    for _, placing in ipairs(results ~= nil and results.placings or {}) do
        if placing.farmId == farmId then
            count = count + 1
            paid = paid + (placing.paid or 0)
        end
    end
    return count, paid
end

-- Picking the site (server) --------------------------------------------------------------

-- 164's best site, or nil: { fieldId, ploughFieldId, hostId, entrance, plan }.
function TheContractorShow:pickSite(random)
    local showSite = g_currentMission.TheContractor.ShowSite
    local candidate = showSite ~= nil and showSite:pickBest() or nil
    if candidate == nil then
        return nil
    end
    return TheContractorShow.siteFromCandidate(candidate)
end

function TheContractorShow.siteFromCandidate(candidate)
    local plan = candidate.plan
    if plan == nil then
        return nil
    end
    local holder = TheContractorEventDay.getHolder(g_fieldManager:getFieldById(plan.showFieldId))
    if holder == nil then
        return nil
    end
    return { fieldId = plan.showFieldId, ploughFieldId = plan.ploughFieldId, hostId = holder.id,
        entrance = plan.entrance, plan = plan }
end

-- The console's: a site on one field (164's split), or nil and why not.
function TheContractorShow:getFieldSite(fieldId)
    local showSite = g_currentMission.TheContractor.ShowSite
    local candidate, reason = showSite:planOn(fieldId)
    if candidate == nil then
        return nil, reason
    end
    if candidate.plan == nil then
        return nil, string.format("Field %d is too small for the show (a showground %d x %d m and at least %d plots).",
            fieldId, TCShowSite.RULES.showgroundLength, TCShowSite.RULES.showgroundWidth, TCShowSite.RULES.minPlots)
    end
    local site = TheContractorShow.siteFromCandidate(candidate)
    if site == nil then
        return nil, string.format("Field %d can't hold the show: no farmer holds it.", fieldId)
    end
    return site
end

-- Hooks ------------------------------------------------------------------------------------

function TheContractorShow:initEvent(event, site)
    event.ploughFieldId = site.ploughFieldId or event.fieldId
    event.resultsGiven = false
    self:planEntries(event)
    if site.plan ~= nil then
        g_currentMission.TheContractor.ShowSite:setPlan(site.plan)
    end
end

-- The entry days, from the show's day (kept if they've passed).
function TheContractorShow:planEntries(event)
    local today = g_currentMission.environment.currentMonotonicDay
    local closeDay, reminderDay = TheContractorShow.planEntryDays(event.announcedDay, event.day,
        TCCalendar.getDaysPerPeriodOn(event.day), TheContractorShow.ENTRY_CLOSE_MONTHS,
        TheContractorShow.ENTRY_REMINDER_MONTHS)
    if event.entriesCloseDay ~= nil and event.entriesCloseDay <= today then
        closeDay = event.entriesCloseDay
    end
    if event.entryReminderDay ~= nil and event.entryReminderDay <= today then
        reminderDay = event.entryReminderDay
    elseif reminderDay ~= nil and reminderDay <= today then
        reminderDay = nil
    end
    event.entriesCloseDay = closeDay
    event.entryReminderDay = reminderDay
end

function TheContractorShow:onAnnounced(event)
    TCAuctionAttendance.createDueJobs(event, self)
    self:callCompetitions("onAnnounced", event)
end

function TheContractorShow:onNewDay(event)
    local today = g_currentMission.environment.currentMonotonicDay
    -- Only with something to enter.
    if event.entryReminderDay ~= nil and today == event.entryReminderDay and self:takesEntries() then
        self:postMessages("entriesClosing", true)
    end
    TCAuctionAttendance.createDueJobs(event, self)
    self:callCompetitions("onNewDay", event)
end

-- 171, server (TCAuctionAttendance.markAttended): a farm's attend job's
-- just been done.
function TheContractorShow:onAttended(farmId, event)
    self:callCompetitions("onAttended", event, farmId)
end

function TheContractorShow:onNewHour(event)
    TCAuctionAttendance.checkAttendance(event, self)
    local env = g_currentMission.environment
    if self.event == event and env.currentMonotonicDay == event.day then
        self:callCompetitions("onHour", event, env.currentHour or 0)
    end
    if self.event == event and env.currentMonotonicDay == event.day and (env.currentHour or 0) >= TheContractorShow.RESULTS_HOUR then
        self:giveResults(event)
    end
end

-- Midnight before: the site dressed and laid out. After 16:00 (a jump past
-- it): the results.
function TheContractorShow:onStateEntered(event, state, passing)
    if state == STATE.SET_OUT and not passing then
        self:setOut(event)
    elseif state == STATE.AFTER then
        self:giveResults(event)
    end
end

function TheContractorShow:onDayMoved(event)
    self:planEntries(event)
    self:sync()
    TCAuctionAttendance.removeJobs(event.id, self)
    TCAuctionAttendance.createDueJobs(event, self)
end

function TheContractorShow:onFinish(event)
    self:giveResults(event)
    self:callCompetitions("onFinished", event)
    self:clearSite()
end

function TheContractorShow:onCancel(event)
    self:clearSite()
end

function TheContractorShow:onCancelled(event)
    TCAuctionAttendance.removeJobs(event.id, self)
    self:callCompetitions("onCancelled", event)
end

-- A big day: as many as a large sale.
function TheContractorShow:getCrowdPeople(scene)
    return TCAuctionCrowd.getAuctionPeople(TheContractorAuctionSite.PREFERRED_LOTS)
end

function TheContractorShow:describeDay(event)
    local parts = {}
    for _, entry in ipairs(TheContractorShow.TIMETABLE) do
        if entry.toHour ~= nil then
            table.insert(parts, string.format("%s %02d:00-%02d:00", entry.key, entry.hour, entry.toHour))
        else
            table.insert(parts, string.format("%s %02d:00", entry.key, entry.hour))
        end
    end
    return string.format("the day %s (%s); entries close %s", TCCalendar.formatDay(event.day),
        table.concat(parts, ", "), event.entriesCloseDay ~= nil and TCCalendar.formatDay(event.entriesCloseDay) or "-")
end

-- Server: the field's still the host's, and the ploughing ground's (when
-- it's another field) still nobody's farm's. If not, it's called off.
function TheContractorShow:checkField()
    if not TheContractorEventDay.checkField(self) then
        return false
    end
    local event = self.event
    if event == nil or event.ploughFieldId == nil or event.ploughFieldId == event.fieldId or
            not g_currentMission.TheContractor.hasResolvedSavedVehicles then
        return true
    end
    local field = g_fieldManager:getFieldById(event.ploughFieldId)
    if field ~= nil and field:getOwner() == FarmlandManager.NO_OWNER_FARM_ID and
            TheContractorEventDay.getHolder(field) ~= nil then
        return true
    end
    TCLog.info("TheContractor: show %d's ploughing field %d has changed hands, cancelled", event.id,
        event.ploughFieldId)
    self:cancel(true)
    return false
end

-- The day (server) ---------------------------------------------------------------------------

-- Midnight before: 164 dresses the ground, then the showground's laid out
-- on its rectangle with the show's dressing.
function TheContractorShow:setOut(event)
    local tc = g_currentMission.TheContractor
    local showSite = tc.ShowSite
    if showSite.site == nil then
        -- A plan lost (a save from a spike's console): planned again on the
        -- same fields.
        local plough = event.ploughFieldId ~= event.fieldId and event.ploughFieldId or nil
        local candidate = showSite:planOn(event.fieldId, plough, event.id)
        if candidate ~= nil and candidate.plan ~= nil then
            showSite:setPlan(candidate.plan)
        end
    end
    local plan = showSite.site ~= nil and showSite.site.plan or nil
    if plan == nil then
        TCLog.warning("TheContractor: show %d has no site plan for field %d, laid out as an open site", event.id,
            event.fieldId)
        tc.AuctionSite:startOpen(event.fieldId, self.KIND, event.id, { pens = self:getPens(event) })
        self:callCompetitions("onSetOut", event)
        return
    end
    if not showSite.site.dressed then
        TCLog.info("TheContractor: %s", showSite:dress())
    end
    tc.AuctionSite:startOpen(event.fieldId, self.KIND, event.id, {
        rect = plan.showRect,
        entrance = plan.entrance,
        keepGround = true,
        getWalkways = TCShowScene.getWalkways,
        -- 169: the ploughing match's plots, marked out from the scene.
        plots = plan.plots,
        -- 182: the livestock's pens, one an animal.
        pens = self:getPens(event),
    })
    if tc.AuctionSite.site == nil or tc.AuctionSite.site.fieldId ~= event.fieldId then
        TCLog.warning("TheContractor: show %d's showground couldn't be set out on field %d", event.id, event.fieldId)
    else
        -- 182: bare ground under the pens, for their straw.
        local rows = showSite:paintPenGround(tc.AuctionSite:getScene())
        TCLog.info("TheContractor: show %d's pens' ground bared (%d rows)", event.id, rows)
    end
    self:callCompetitions("onSetOut", event)
end

-- 182: the pens the competitions need (the most any asks for), or nil.
function TheContractorShow:getPens(event)
    local pens = nil
    for _, competition in ipairs(self.competitions) do
        local count = competition.getPens ~= nil and competition.getPens(event) or nil
        if count ~= nil and (pens == nil or count > pens) then
            pens = count
        end
    end
    return pens
end

-- The site put back as it was and dropped (midnight after, or called off).
function TheContractorShow:clearSite()
    local showSite = g_currentMission.TheContractor.ShowSite
    if showSite ~= nil and showSite.site ~= nil then
        TCLog.info("TheContractor: %s", showSite:clear())
    end
end

-- The prize for a placing (unscaled), as charged (scaled).
function TheContractorShow.getPrize(placing, prize)
    return prize or TheContractorShow.PRIZES[placing] or 0
end

function TheContractorShow.scalePrize(amount)
    local settings = g_currentMission.TheContractor.Settings
    if settings ~= nil then
        amount = settings:scaleCost(amount)
    end
    return TCEconomyScale.scale(amount)
end

-- Server, at 16:00 (or the first time after): each competition's
-- placings, paid and rewarded, kept as the show's results, and every
-- company farm told. Once a show.
function TheContractorShow:giveResults(event)
    if event == nil or event.resultsGiven then
        return
    end
    event.resultsGiven = true
    local tc = g_currentMission.TheContractor
    local results = { showId = event.id, day = event.day, fieldId = event.fieldId, hostFarmerId = event.hostFarmerId,
        placings = {} }
    for _, competition in ipairs(self.competitions) do
        local placings = competition.getPlacings ~= nil and competition.getPlacings(event) or {}
        for _, entry in ipairs(TheContractorShow.sortPlacings(placings)) do
            local placing = math.max(1, math.floor(entry.placing or 1))
            local record = {
                titleKey = competition.titleKey,
                titleArg = entry.titleArg or "",
                placing = placing,
                farmId = entry.farmId or 0,
                farmerId = entry.farmerId or 0,
                entrant = entry.entrant or "",
                prize = TheContractorShow.getPrize(placing, entry.prize),
                paid = 0,
            }
            if record.farmId > 0 then
                record.paid = self:rewardPlacing(record, event, entry.reputation, entry.opinion)
            end
            table.insert(results.placings, record)
        end
    end
    self.results = results
    TCLog.info("TheContractor: show %d results: %d placing(s)", event.id, #results.placings)
    if #results.placings > 0 then
        self:postResults(results)
    end
    self:callCompetitions("onResults", event)
    self:sync()
end

-- A competition's placings in the order they're kept (pure): grouped by
-- titleArg in the order each first appears, then by placing, ties in the
-- order given.
function TheContractorShow.sortPlacings(placings)
    local groupOrder, groups = {}, 0
    local items = {}
    for i, entry in ipairs(placings) do
        local group = entry.titleArg or ""
        if groupOrder[group] == nil then
            groups = groups + 1
            groupOrder[group] = groups
        end
        items[i] = { entry = entry, group = groupOrder[group], index = i }
    end
    table.sort(items, function(a, b)
        if a.group ~= b.group then
            return a.group < b.group
        end
        local placingA, placingB = a.entry.placing or 99, b.entry.placing or 99
        if placingA ~= placingB then
            return placingA < placingB
        end
        return a.index < b.index
    end)
    local sorted = {}
    for i, item in ipairs(items) do
        sorted[i] = item.entry
    end
    return sorted
end

-- Server: a farm's placing paid (prize money), its reputation and the
-- host's opinion raised. reputation, opinion: the competition's own for
-- it, or nil for the placing's. Returns what was paid.
function TheContractorShow:rewardPlacing(record, event, reputation, opinion)
    local tc = g_currentMission.TheContractor
    local farmId = record.farmId
    local amount = TheContractorShow.scalePrize(record.prize)
    if amount > 0 then
        g_currentMission:addMoney(amount, farmId, MoneyType.TC_SHOW_PRIZES, true, true)
    end
    local jobs = reputation or TheContractorShow.PLACING_REPUTATION[record.placing] or 0
    if jobs > 0 and tc.Reputation ~= nil then
        tc.Reputation:addReputation(farmId, TheContractorGoodNews.getReputationReward(farmId, jobs))
    end
    opinion = opinion or TheContractorShow.HOST_OPINION[record.placing] or 0
    if opinion > 0 and tc.Relationships ~= nil then
        tc.Relationships:adjust(farmId, event.hostFarmerId, opinion, TheContractorShow.RELATIONSHIP_REASON)
    end
    TCLog.info("TheContractor: farm %d placed %d in %s %s (%s), paid %d", farmId, record.placing, record.titleKey,
        record.titleArg or "", record.entrant, amount)
    return amount
end

-- The l10n key naming a placing in full: 1st, 2nd, 3rd, then highly
-- commended.
function TheContractorShow.getPlacingNameKey(placing)
    return "tc_show_placingName" .. math.max(1, math.min(4, placing or 4))
end

-- Server: the results message to every company farm (each with its own
-- placings and prize money), and a rosette notice for each placing a farm
-- won (167). Its payload names the show as resultsShowId, not PAYLOAD_ID,
-- so it outlasts the show's other messages (gone when it's over).
function TheContractorShow:postResults(results)
    local tc = g_currentMission.TheContractor
    local texts = TheContractorShow.TEXTS.results
    for _, farmId in ipairs(tc.RandomEvents:getCompanyFarmIds()) do
        local count, paid = TheContractorShow.getFarmTotals(results, farmId)
        tc.Inbox:postMessage(farmId, self.KIND, texts.title, texts.body,
            { string.format("$days_%d_%d", results.day, results.day), tostring(count), "$money_" .. paid },
            { TheContractorInbox.DISMISS_ACTION },
            { resultsShowId = results.showId, farmerId = results.hostFarmerId, fieldId = results.fieldId })
        if count > 0 and tc.Notices ~= nil then
            for _, placing in ipairs(results.placings) do
                if placing.farmId == farmId then
                    tc.Notices:publish(farmId, string.format(g_i18n:getText("tc_show_rosetteNotice"),
                        g_i18n:getText(TheContractorShow.getPlacingNameKey(placing.placing)),
                        self:getPlacingTitle(placing)), TheContractorShow.NOTICE_MONTHS)
                end
            end
        end
    end
end

-- Farms and farmers -------------------------------------------------------------------------

-- Every machine (TCFarmDeletion): a deleted farm's placings go.
function TheContractorShow:forgetFarm(farmId)
    local results = self.results
    if results == nil then
        return
    end
    for i = #results.placings, 1, -1 do
        if results.placings[i].farmId == farmId then
            table.remove(results.placings, i)
        end
    end
end

-- Every machine (128, through tc.PublicEvents): a retired farmer's host
-- and placings are their successor's. Returns how many.
function TheContractorShow:replacePerson(oldId, newId)
    local results = self.results or { placings = {} }
    local count = 0
    if results.hostFarmerId == oldId then
        results.hostFarmerId = newId
        count = count + 1
    end
    for _, placing in ipairs(results.placings) do
        if placing.farmerId == oldId then
            placing.farmerId = newId
            count = count + 1
        end
    end
    -- 167: a competition's own (its farmers' entries).
    for _, competition in ipairs(self.competitions) do
        if competition.replacePerson ~= nil then
            count = count + (competition.replacePerson(oldId, newId) or 0)
        end
    end
    return count
end

-- Sync ----------------------------------------------------------------------------------------

function TheContractorShow:newSyncEvent(event)
    return TCShowEvent.new(event, self.results)
end

-- Every machine: the show and the results as the server sent them.
function TheContractorShow:applyShowSync(event, results)
    self.results = results
    self:applySync(event)
end

function TheContractorShow.writeShowExtra(streamId, event)
    if event == nil then
        return
    end
    streamWriteInt32(streamId, event.ploughFieldId or event.fieldId)
    streamWriteInt32(streamId, event.entriesCloseDay or -1)
    streamWriteInt32(streamId, event.entryReminderDay or -1)
    streamWriteBool(streamId, event.resultsGiven == true)
end

function TheContractorShow.readShowExtra(streamId, event)
    if event == nil then
        return
    end
    event.ploughFieldId = streamReadInt32(streamId)
    local closeDay = streamReadInt32(streamId)
    local reminderDay = streamReadInt32(streamId)
    event.entriesCloseDay = closeDay >= 0 and closeDay or nil
    event.entryReminderDay = reminderDay >= 0 and reminderDay or nil
    event.resultsGiven = streamReadBool(streamId)
end

function TheContractorShow.writeResults(streamId, results)
    if not streamWriteBool(streamId, results ~= nil) then
        return
    end
    streamWriteInt32(streamId, results.showId)
    streamWriteInt32(streamId, results.day)
    streamWriteInt32(streamId, results.fieldId)
    streamWriteInt32(streamId, results.hostFarmerId)
    streamWriteUInt16(streamId, #results.placings)
    for _, placing in ipairs(results.placings) do
        streamWriteString(streamId, placing.titleKey or "")
        streamWriteString(streamId, placing.titleArg or "")
        streamWriteUInt8(streamId, placing.placing)
        streamWriteInt32(streamId, placing.farmId)
        streamWriteInt32(streamId, placing.farmerId)
        streamWriteString(streamId, placing.entrant or "")
        streamWriteInt32(streamId, placing.prize or 0)
        streamWriteInt32(streamId, placing.paid or 0)
    end
end

function TheContractorShow.readResults(streamId)
    if not streamReadBool(streamId) then
        return nil
    end
    local results = {
        showId = streamReadInt32(streamId),
        day = streamReadInt32(streamId),
        fieldId = streamReadInt32(streamId),
        hostFarmerId = streamReadInt32(streamId),
        placings = {},
    }
    local count = streamReadUInt16(streamId)
    for _ = 1, count do
        table.insert(results.placings, {
            titleKey = streamReadString(streamId),
            titleArg = streamReadString(streamId),
            placing = streamReadUInt8(streamId),
            farmId = streamReadInt32(streamId),
            farmerId = streamReadInt32(streamId),
            entrant = streamReadString(streamId),
            prize = streamReadInt32(streamId),
            paid = streamReadInt32(streamId),
        })
    end
    return results
end

function TheContractorShow:writeInitialClientState(streamId, connection)
    TCShowEvent.writeShow(streamId, self.event, self.results)
end

function TheContractorShow:readInitialClientState(streamId, connection)
    local event, results = TCShowEvent.readShow(streamId)
    self:applyShowSync(event, results)
end

-- Persistence -----------------------------------------------------------------------------------

function TheContractorShow:saveEventExtra(xmlFile, key, event)
    setXMLInt(xmlFile, key .. "#ploughFieldId", event.ploughFieldId or event.fieldId)
    if event.entriesCloseDay ~= nil then
        setXMLInt(xmlFile, key .. "#entriesCloseDay", event.entriesCloseDay)
    end
    if event.entryReminderDay ~= nil then
        setXMLInt(xmlFile, key .. "#entryReminderDay", event.entryReminderDay)
    end
    setXMLBool(xmlFile, key .. "#resultsGiven", event.resultsGiven == true)
end

function TheContractorShow:loadEventExtra(xmlFile, key, event)
    event.ploughFieldId = getXMLInt(xmlFile, key .. "#ploughFieldId") or event.fieldId
    event.entriesCloseDay = getXMLInt(xmlFile, key .. "#entriesCloseDay")
    event.entryReminderDay = getXMLInt(xmlFile, key .. "#entryReminderDay")
    event.resultsGiven = getXMLBool(xmlFile, key .. "#resultsGiven") == true
end

function TheContractorShow:saveToXmlFile(xmlFile)
    TheContractorEventDay.saveToXmlFile(self, xmlFile)
    local results = self.results
    if not g_currentMission:getIsServer() or results == nil then
        return
    end
    local key = TheContractor.SaveKey .. "." .. self.SAVE_KEY .. ".results"
    setXMLInt(xmlFile, key .. "#showId", results.showId)
    setXMLInt(xmlFile, key .. "#day", results.day)
    setXMLInt(xmlFile, key .. "#fieldId", results.fieldId)
    setXMLInt(xmlFile, key .. "#hostFarmerId", results.hostFarmerId)
    for i, placing in ipairs(results.placings) do
        local placingKey = string.format("%s.placing(%d)", key, i - 1)
        setXMLString(xmlFile, placingKey .. "#titleKey", placing.titleKey or "")
        if placing.titleArg ~= nil and placing.titleArg ~= "" then
            setXMLString(xmlFile, placingKey .. "#titleArg", placing.titleArg)
        end
        setXMLInt(xmlFile, placingKey .. "#placing", placing.placing)
        setXMLInt(xmlFile, placingKey .. "#farmId", placing.farmId)
        setXMLInt(xmlFile, placingKey .. "#farmerId", placing.farmerId)
        setXMLString(xmlFile, placingKey .. "#entrant", placing.entrant or "")
        setXMLInt(xmlFile, placingKey .. "#prize", placing.prize or 0)
        setXMLInt(xmlFile, placingKey .. "#paid", placing.paid or 0)
    end
end

function TheContractorShow:loadFromXMLFile(xmlFile)
    TheContractorEventDay.loadFromXMLFile(self, xmlFile)
    if not g_currentMission:getIsServer() then
        return
    end
    local key = TheContractor.SaveKey .. "." .. self.SAVE_KEY .. ".results"
    local showId = getXMLInt(xmlFile, key .. "#showId")
    if showId == nil then
        return
    end
    local results = {
        showId = showId,
        day = getXMLInt(xmlFile, key .. "#day") or 0,
        fieldId = getXMLInt(xmlFile, key .. "#fieldId") or 0,
        hostFarmerId = getXMLInt(xmlFile, key .. "#hostFarmerId") or 0,
        placings = {},
    }
    local i = 0
    while hasXMLProperty(xmlFile, string.format("%s.placing(%d)", key, i)) do
        local placingKey = string.format("%s.placing(%d)", key, i)
        table.insert(results.placings, {
            titleKey = getXMLString(xmlFile, placingKey .. "#titleKey") or "",
            titleArg = getXMLString(xmlFile, placingKey .. "#titleArg") or "",
            placing = getXMLInt(xmlFile, placingKey .. "#placing") or 1,
            farmId = getXMLInt(xmlFile, placingKey .. "#farmId") or 0,
            farmerId = getXMLInt(xmlFile, placingKey .. "#farmerId") or 0,
            entrant = getXMLString(xmlFile, placingKey .. "#entrant") or "",
            prize = getXMLInt(xmlFile, placingKey .. "#prize") or 0,
            paid = getXMLInt(xmlFile, placingKey .. "#paid") or 0,
        })
        i = i + 1
    end
    self.results = results
end

-- Console ---------------------------------------------------------------------------------------

function TheContractorShow:describe()
    if self.event == nil then
        local lines = { "There's no show announced. 'tcShow start' announces one." }
        if self.results ~= nil then
            table.insert(lines, string.format("  Last show %d's results (%s): %d placing(s).", self.results.showId,
                TCCalendar.formatDay(self.results.day), #self.results.placings))
        end
        return table.concat(lines, "\n")
    end
    local lines = { TheContractorEventDay.describe(self) }
    local event = self.event
    if event.ploughFieldId ~= nil and event.ploughFieldId ~= event.fieldId then
        table.insert(lines, string.format("  Ploughing match on field %d.", event.ploughFieldId))
    end
    return table.concat(lines, "\n")
end

-- tcDebug showDay: the show's today, set out now.
function TheContractorShow:consoleShowDay()
    local event = self.event
    if event == nil then
        return "There's no show announced."
    end
    if event.day ~= g_currentMission.environment.currentMonotonicDay then
        self:moveToToday()
    end
    return self:describe()
end

function TheContractorShow.registerConsoleCommands()
    TCConsole.register("show", "status", {
        description = "The show, if there's one: its fields, host, state, days and signs; or the last results",
        run = function()
            return g_currentMission.TheContractor.Show:describe()
        end,
    })

    TCConsole.register("show", "start", {
        args = "[fieldId|auto] [days]",
        description = "Announce the show now: on a field or the best site, its day in days or 2 to 3 months",
        hints = { fieldId = "a field's number (tcShow fields lists those that can hold the show)" },
        run = function(_, args)
            local isAuto = args[1] ~= nil and string.lower(args[1]) == "auto"
            local fieldId = args[1] ~= nil and not isAuto and tonumber(args[1]) or nil
            local days = args[2] ~= nil and tonumber(args[2]) or nil
            if (args[1] ~= nil and not isAuto and fieldId == nil) or
                    (args[2] ~= nil and (days == nil or days < 1)) or args[3] ~= nil then
                return false
            end
            return g_currentMission.TheContractor.Show:consoleStart(fieldId ~= nil and math.floor(fieldId) or nil,
                days ~= nil and math.floor(days) or nil)
        end,
    })

    TCConsole.register("show", "cancel", {
        description = "Call the show off: its site put back and every company told",
        run = function()
            if not g_currentMission.TheContractor.Show:cancel(true) then
                return "There's no show announced."
            end
            return "Show cancelled: its site's put back, everything's cleared away and every company told."
        end,
    })

    TCConsole.register("show", "fields", {
        description = "The fields (or pairs side by side) that could hold the show, best first",
        run = function()
            return g_currentMission.TheContractor.ShowSite:getListText()
        end,
    })

    TCConsole.register("debug", "showDay", {
        description = "Make today the show's day: the site dressed and laid out now, gates from 08:00",
        run = function()
            return g_currentMission.TheContractor.Show:consoleShowDay()
        end,
    })
end
