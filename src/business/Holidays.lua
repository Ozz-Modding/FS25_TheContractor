-- Holidays (040). Every hired worker gets one month's holiday a year: a
-- whole period, so daysPerPeriod days. That's 1 day at one day per period
-- and 5 at five. The allowance is kept as a fraction of a period, not
-- days, so it survives the player changing the setting: a worker who's used
-- 2 of their 5 days has 0.6 left, which is 3 days at five per period, 6 at
-- ten, and rounds to 1 at one.
--
-- Workers book their own holidays at least MIN_NOTICE_DAYS ahead, from the
-- server's daily tick (Staff:onDayChanged calls onDayChanged here). A
-- worker has at most one booking at a time. Each booking takes between half
-- and all of what's left, so a year's allowance usually goes in one or two
-- bookings. Every worker books independently, so there's no limit on how
-- many are off at once - by chance, several sometimes are. Bookings stay
-- inside the current year: the allowance resets at
-- the start of each year, and whatever's unused is lost. A worker who's
-- running out of year books all they have left straight away, rather than
-- rolling for it.
--
-- Dates are monotonic days (see TCCalendar). A booking never spans a
-- change of days per period: days from the next season start on are worked
-- out at the planned days per period, and a booking that would cross into a
-- season with a different value is cut short at the change. If the player
-- changes the setting after a booking is made (setPlannedDaysPerPeriod,
-- hooked below), a booking that hasn't started is cancelled and its
-- allowance refunded - the worker rebooks with fresh notice. One that's
-- already running is cut short at the change and the unused days refunded.
--
-- On a holiday day an idle or sick worker goes on holiday (STATUS.HOLIDAY).
-- One who's out on a job or driving finishes first and goes on holiday as
-- soon as they're back, for whatever's left of it (Staff:setWorkerStatus) -
-- a holiday never pulls anyone off a job, same as sickness (031).
--
-- The Overview's notices board (038) gets one notice per run of days with
-- the same workers off, e.g. "June 10-12, Year 2: 2 workers on holiday
-- (Amy Hall, John Smith)", rebuilt whenever bookings change and every day.
-- This subsystem only saves which notices are its own; the bookings live on
-- the workers and are saved with them (Staff.lua).

TheContractorHolidays = {}
TheContractorHolidays_mt = Class(TheContractorHolidays)

TheContractorHolidays.MIN_NOTICE_DAYS = 3
-- The start is picked up to this many periods past the minimum notice.
TheContractorHolidays.MAX_EXTRA_NOTICE_PERIODS = 1
-- The daily chance to book is about this many bookings spread over a year.
TheContractorHolidays.BOOKINGS_PER_YEAR = 2

-- What TCWorkerHolidayChangedEvent tells the farm about.
TheContractorHolidays.NOTIFY = {
    NONE = 0,
    BOOKED = 1,
    CANCELLED = 2,
}

function TheContractorHolidays.new()
    local self = {}
    setmetatable(self, TheContractorHolidays_mt)

    -- noticeIdsByFarm[farmId] = { noticeId, ... } - this subsystem's own
    -- notices on the board (038), in the order they were published.
    self.noticeIdsByFarm = {}

    return self
end

-- Allowance ---------------------------------------------------------------

-- A whole period a year, or for a worker first getting it partway through
-- a year, the share of the year that's left (including the current
-- period).
function TheContractorHolidays.getInitialAllowance()
    local periodsLeft = Environment.PERIODS_IN_YEAR - g_currentMission.environment.currentPeriod + 1
    return periodsLeft / Environment.PERIODS_IN_YEAR
end

-- Whole days the allowance is worth at daysPerPeriod.
function TheContractorHolidays.getAllowanceDays(allowance, daysPerPeriod)
    return math.floor(allowance * daysPerPeriod + 0.5)
end

-- Called by Staff:hireWorker before the hire is broadcast, so the
-- allowance goes out with the worker.
function TheContractorHolidays.grantInitialAllowance(worker)
    worker.holidayAllowance = TheContractorHolidays.getInitialAllowance()
    worker.holidayYear = g_currentMission.environment.currentYear
end

-- Daily tick (server-only, from Staff:onDayChanged) --------------------------

function TheContractorHolidays:onDayChanged()
    if not g_currentMission:getIsServer() then
        return
    end

    local staff = g_currentMission.TheContractor.Staff
    local today = g_currentMission.environment.currentMonotonicDay
    local currentYear = g_currentMission.environment.currentYear

    for farmId, farmWorkers in pairs(staff.workersByFarm) do
        -- Collected first: status changes below can retire a worker, which
        -- takes them off the roster mid-loop.
        local workers = {}
        for _, worker in pairs(farmWorkers) do
            table.insert(workers, worker)
        end

        for _, worker in ipairs(workers) do
            if worker.holidayYear == nil then
                -- From a save made before 040.
                TheContractorHolidays.grantInitialAllowance(worker)
                self:sendHolidayChanged(worker, TheContractorHolidays.NOTIFY.NONE)
            elseif worker.holidayYear ~= currentYear then
                worker.holidayAllowance = 1
                worker.holidayYear = currentYear
                self:sendHolidayChanged(worker, TheContractorHolidays.NOTIFY.NONE)
            end

            self:reconcileBooking(worker)

            if worker:hasHolidayBooked() and worker:getHolidayEndDay() < today then
                self:endHoliday(worker)
            elseif worker:isHolidayOn(today) then
                self:startHoliday(worker)
            end
        end

        for _, worker in ipairs(workers) do
            if staff:getWorker(farmId, worker.id) ~= nil then
                self:tryBookHoliday(worker)
            end
        end

        self:refreshNotices(farmId)
    end
end

-- The booking's over: back to idle if they're on holiday. setWorkerStatus
-- takes care of anyone due to retire.
function TheContractorHolidays:endHoliday(worker)
    worker.holidayStartDay = nil
    worker.holidayDays = 0
    worker.holidayDaysPerPeriod = nil
    self:sendHolidayChanged(worker, TheContractorHolidays.NOTIFY.NONE)

    if worker.status == TheContractorWorker.STATUS.HOLIDAY then
        Logging.info("TheContractor: farm %d worker %d (%s) back from holiday", worker.farmId, worker.id, worker.name)
        g_currentMission.TheContractor.Staff:setWorkerStatus(worker.farmId, worker.id, TheContractorWorker.STATUS.IDLE)
    end
end

-- An idle worker goes now, and so does a sick one - the holiday takes over
-- from the sickness. Anyone busy goes when they're set idle.
function TheContractorHolidays:startHoliday(worker)
    local status = worker.status
    if status ~= TheContractorWorker.STATUS.IDLE and status ~= TheContractorWorker.STATUS.SICK then
        return
    end

    Logging.info("TheContractor: farm %d worker %d (%s) on holiday until day %d", worker.farmId, worker.id,
        worker.name, worker:getHolidayEndDay())
    worker.sickDaysRemaining = 0
    worker.pendingSickDays = 0
    g_currentMission.TheContractor.Staff:setWorkerStatus(worker.farmId, worker.id, TheContractorWorker.STATUS.HOLIDAY)
end

-- Booking -------------------------------------------------------------------

-- Rolls for a worker with no booking to book one, and books it. Retiring
-- workers don't book; neither does anyone whose allowance is worth less
-- than a day.
function TheContractorHolidays:tryBookHoliday(worker)
    if worker:hasHolidayBooked() or worker:isRetiring() then
        return
    end

    local environment = g_currentMission.environment
    local earliestDay = environment.currentMonotonicDay + TheContractorHolidays.MIN_NOTICE_DAYS
    local lastDay = TCCalendar.getLastDayOfYear()
    local window = lastDay - earliestDay + 1
    if window < 1 then
        return
    end

    local earliestDaysPerPeriod = TCCalendar.getDaysPerPeriodOn(earliestDay)
    local earliestAllowanceDays = TheContractorHolidays.getAllowanceDays(worker.holidayAllowance,
        earliestDaysPerPeriod)
    if earliestAllowanceDays < 1 then
        return
    end

    -- Running out of year: book now while the allowance still fits.
    local mustBook = window <= earliestAllowanceDays + earliestDaysPerPeriod
    local dailyChance = TheContractorHolidays.BOOKINGS_PER_YEAR /
        (Environment.PERIODS_IN_YEAR * environment.daysPerPeriod)
    if not mustBook and math.random() >= dailyChance then
        return
    end

    local maxExtra = math.min(earliestDaysPerPeriod * TheContractorHolidays.MAX_EXTRA_NOTICE_PERIODS,
        window - earliestAllowanceDays)
    local startDay = earliestDay + (maxExtra > 0 and math.random(0, maxExtra) or 0)

    -- Out of time for a second booking: take the lot.
    local days = TheContractorHolidays.pickDays(worker, startDay, mustBook)
    if days == nil then
        return
    end

    self:bookHoliday(worker, startDay, days)
end

-- How many days a booking from startDay should be: half to all of what the
-- allowance is worth then (all of it if takeAll), kept inside this year and
-- short of any change of days per period. nil if that's under a day.
function TheContractorHolidays.pickDays(worker, startDay, takeAll)
    local daysPerPeriod = TCCalendar.getDaysPerPeriodOn(startDay)
    local allowanceDays = TheContractorHolidays.getAllowanceDays(worker.holidayAllowance, daysPerPeriod)
    if allowanceDays < 1 then
        return nil
    end

    local days = allowanceDays
    if allowanceDays > 2 and not takeAll then
        days = math.random(math.ceil(allowanceDays / 2), allowanceDays)
    end

    days = math.min(days, TCCalendar.getLastDayOfYear() - startDay + 1)
    for offset = 1, days - 1 do
        if TCCalendar.getDaysPerPeriodOn(startDay + offset) ~= daysPerPeriod then
            days = offset
            break
        end
    end
    if days < 1 then
        return nil
    end
    return days
end

-- Books it, spends the allowance and tells everyone. Also the tcBookHoliday
-- console command's way in, so it doesn't check notice or allowance itself.
function TheContractorHolidays:bookHoliday(worker, startDay, days)
    local daysPerPeriod = TCCalendar.getDaysPerPeriodOn(startDay)

    worker.holidayStartDay = startDay
    worker.holidayDays = days
    worker.holidayDaysPerPeriod = daysPerPeriod
    worker.holidayAllowance = math.max(0, worker.holidayAllowance - days / daysPerPeriod)

    Logging.info("TheContractor: farm %d worker %d (%s) booked %d day(s) holiday from day %d (%.2f periods left)",
        worker.farmId, worker.id, worker.name, days, startDay, worker.holidayAllowance)

    self:sendHolidayChanged(worker, TheContractorHolidays.NOTIFY.BOOKED)
    self:refreshNotices(worker.farmId)

    -- Booked for today (console command): off they go.
    if worker:isHolidayOn(g_currentMission.environment.currentMonotonicDay) then
        self:startHoliday(worker)
    end
end

-- Days per period changes (server-only) ---------------------------------------

-- Whether a booking still matches the days per period on every one of its
-- days, and if not, cancels or shortens it. Run every day and whenever the
-- player changes the setting.
function TheContractorHolidays:reconcileBooking(worker)
    if not worker:hasHolidayBooked() then
        return
    end

    local today = g_currentMission.environment.currentMonotonicDay
    local firstChangedDay = nil
    for day = math.max(today, worker.holidayStartDay), worker:getHolidayEndDay() do
        if TCCalendar.getDaysPerPeriodOn(day) ~= worker.holidayDaysPerPeriod then
            firstChangedDay = day
            break
        end
    end
    if firstChangedDay == nil then
        return
    end

    local started = worker.holidayStartDay < today or worker.status == TheContractorWorker.STATUS.HOLIDAY
    local oldDays = worker.holidayDays

    if not started then
        worker.holidayAllowance = worker.holidayAllowance + oldDays / worker.holidayDaysPerPeriod
        worker.holidayStartDay = nil
        worker.holidayDays = 0
        worker.holidayDaysPerPeriod = nil

        Logging.info("TheContractor: farm %d worker %d (%s) holiday cancelled - days per period changed",
            worker.farmId, worker.id, worker.name)
        self:sendHolidayChanged(worker, TheContractorHolidays.NOTIFY.CANCELLED)
        return
    end

    -- Ends the day before the change. If that's already past (the change
    -- happened at today's day change), endHoliday picks it up.
    local newEndDay = math.max(firstChangedDay, today) - 1
    worker.holidayDays = newEndDay - worker.holidayStartDay + 1
    worker.holidayAllowance = worker.holidayAllowance + (oldDays - worker.holidayDays) / worker.holidayDaysPerPeriod

    Logging.info("TheContractor: farm %d worker %d (%s) holiday cut to %d day(s) - days per period changed",
        worker.farmId, worker.id, worker.name, worker.holidayDays)
    self:sendHolidayChanged(worker, TheContractorHolidays.NOTIFY.NONE)
end

function TheContractorHolidays:onPlannedDaysPerPeriodChanged()
    if not g_currentMission:getIsServer() then
        return
    end

    local staff = g_currentMission.TheContractor.Staff
    for farmId, farmWorkers in pairs(staff.workersByFarm) do
        for _, worker in pairs(farmWorkers) do
            self:reconcileBooking(worker)
        end
        self:refreshNotices(farmId)
    end
end

-- Hooked at module scope, guarded so it can't stack. setPlannedDaysPerPeriod
-- runs on every machine (the settings event applies it on each); only the
-- server acts on it.
if not Environment.tcHolidayHookInstalled then
    Environment.setPlannedDaysPerPeriod = Utils.appendedFunction(Environment.setPlannedDaysPerPeriod, function()
        local tc = g_currentMission ~= nil and g_currentMission.TheContractor or nil
        if tc ~= nil and tc.Holidays ~= nil then
            tc.Holidays:onPlannedDaysPerPeriodChanged()
        end
    end)
    Environment.tcHolidayHookInstalled = true
end

-- Sync ----------------------------------------------------------------------

-- Broadcasts the worker's whole holiday state, after showing the host's own
-- notification (the broadcast doesn't loop back to it).
function TheContractorHolidays:sendHolidayChanged(worker, notify)
    TCWorkerHolidayChangedEvent.showNotification(worker, notify)

    if g_server ~= nil then
        g_server:broadcastEvent(TCWorkerHolidayChangedEvent.new(worker, notify))
    end
end

-- Run on clients receiving TCWorkerHolidayChangedEvent.
function TheContractorHolidays.applyHolidayChanged(worker, allowance, startDay, days)
    worker.holidayAllowance = allowance
    worker.holidayStartDay = startDay
    worker.holidayDays = days
end

-- Overview notices (server-only) ----------------------------------------------

-- Who's off on each day from today on, split into runs of days with the
-- same people off - one notice text per run, earliest first.
function TheContractorHolidays:getNoticeTexts(farmId)
    local staff = g_currentMission.TheContractor.Staff
    local today = g_currentMission.environment.currentMonotonicDay

    local booked = {}
    local lastDay = today - 1
    for _, worker in ipairs(staff:getRoster(farmId)) do
        if worker:hasHolidayBooked() and worker:getHolidayEndDay() >= today then
            table.insert(booked, worker)
            lastDay = math.max(lastDay, worker:getHolidayEndDay())
        end
    end
    table.sort(booked, function(a, b)
        return a.name < b.name
    end)

    local texts = {}
    local runStart, runNames = nil, nil
    local function closeRun(runEnd)
        if runStart == nil then
            return
        end
        local dates = TCCalendar.formatDayRange(runStart, runEnd)
        if #runNames == 1 then
            table.insert(texts, string.format(g_i18n:getText("tc_holiday_noticeOne"), dates, runNames[1]))
        else
            table.insert(texts, string.format(g_i18n:getText("tc_holiday_noticeMany"), dates, #runNames,
                table.concat(runNames, ", ")))
        end
        runStart, runNames = nil, nil
    end

    for day = today, lastDay do
        local names = {}
        for _, worker in ipairs(booked) do
            if worker:isHolidayOn(day) then
                table.insert(names, worker.name)
            end
        end

        local key = table.concat(names, "|")
        if runStart ~= nil and key ~= table.concat(runNames, "|") then
            closeRun(day - 1)
        end
        if runStart == nil and #names > 0 then
            runStart, runNames = day, names
        end
    end
    closeRun(lastDay)

    return texts
end

-- Republishes the farm's holiday notices if they've changed. Published
-- latest first, because the board shows the newest notice at the top.
function TheContractorHolidays:refreshNotices(farmId)
    if not g_currentMission:getIsServer() then
        return
    end

    local notices = g_currentMission.TheContractor.Notices
    local texts = self:getNoticeTexts(farmId)
    local oldIds = self.noticeIdsByFarm[farmId] or {}

    local unchanged = #oldIds == #texts
    for i, noticeId in ipairs(oldIds) do
        local notice = notices:getNotice(noticeId)
        if notice == nil or notice.text ~= texts[#texts - i + 1] then
            unchanged = false
            break
        end
    end
    if unchanged then
        return
    end

    for _, noticeId in ipairs(oldIds) do
        notices:remove(noticeId)
    end

    local newIds = {}
    for i = #texts, 1, -1 do
        table.insert(newIds, notices:publish(farmId, texts[i]))
    end
    self.noticeIdsByFarm[farmId] = newIds
end

-- Persistence ---------------------------------------------------------------
-- Just which notices are ours; the bookings are saved with the workers.
-- Loaded after Notices, so ids that are no longer on the board are dropped.

function TheContractorHolidays:loadFromXMLFile(xmlFile)
    if not g_currentMission:getIsServer() then return end

    self.noticeIdsByFarm = {}
    local notices = g_currentMission.TheContractor.Notices

    local rootKey = string.format("%s.holidays", TheContractor.SaveKey)
    local farmIndex = 0
    while true do
        local farmKey = string.format("%s.farm(%d)", rootKey, farmIndex)
        if not hasXMLProperty(xmlFile, farmKey) then
            break
        end

        local farmId = getXMLInt(xmlFile, farmKey .. "#farmId")
        local ids = {}
        local noticeIndex = 0
        while true do
            local noticeKey = string.format("%s.notice(%d)", farmKey, noticeIndex)
            if not hasXMLProperty(xmlFile, noticeKey) then
                break
            end
            local noticeId = getXMLInt(xmlFile, noticeKey .. "#id")
            if noticeId ~= nil and notices:getNotice(noticeId) ~= nil then
                table.insert(ids, noticeId)
            end
            noticeIndex = noticeIndex + 1
        end
        self.noticeIdsByFarm[farmId] = ids

        farmIndex = farmIndex + 1
    end
end

function TheContractorHolidays:saveToXmlFile(xmlFile)
    if not g_currentMission:getIsServer() then return end

    local rootKey = string.format("%s.holidays", TheContractor.SaveKey)
    local farmIndex = 0
    for farmId, ids in pairs(self.noticeIdsByFarm) do
        local farmKey = string.format("%s.farm(%d)", rootKey, farmIndex)
        setXMLInt(xmlFile, farmKey .. "#farmId", farmId)
        for noticeIndex, noticeId in ipairs(ids) do
            setXMLInt(xmlFile, string.format("%s.notice(%d)#id", farmKey, noticeIndex - 1), noticeId)
        end
        farmIndex = farmIndex + 1
    end
end

-- Nothing to send: the bookings go with the workers (Staff) and the notices
-- with the board (Notices).
function TheContractorHolidays:writeInitialClientState(streamId, connection)
end

function TheContractorHolidays:readInitialClientState(streamId, connection)
end
