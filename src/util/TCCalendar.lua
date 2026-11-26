-- Absolute "period index" - months since the start of the save, counting
-- from 1 in year 1's first period - for anything that needs to say "N
-- months from now" across a year boundary (038's notice expiry, 039's
-- retirement date). The second half of the file maps 040's day-based dates
-- (holidays) onto months, allowing for the days-per-period setting.
-- Environment derives currentYear and currentPeriod from
-- the same day counter and both are already up to date by the time
-- PERIOD_CHANGED fires, so the index steps by exactly one per period
-- change. Always >= 1, so 0 is free as a "none" sentinel on the wire.

TCCalendar = {}

function TCCalendar.getPeriodIndex()
    local environment = g_currentMission.environment
    return (environment.currentYear - 1) * Environment.PERIODS_IN_YEAR + environment.currentPeriod
end

function TCCalendar.getYearOfPeriodIndex(periodIndex)
    return math.floor((periodIndex - 1) / Environment.PERIODS_IN_YEAR) + 1
end

-- Whether the map is in the southern hemisphere (a negative latitude), as
-- vanilla's I18N:formatPeriod decides it.
function TCCalendar.isSouthern()
    local environment = g_currentMission ~= nil and g_currentMission.environment or nil
    return environment ~= nil and environment.daylight ~= nil and environment.daylight.latitude ~= nil and
        environment.daylight.latitude < 0
end

-- The month (1 to 12) a seasonal period (1 to 12) is called, as vanilla's
-- I18N:formatPeriod works it out: periods are seasons (period 1 is the
-- first month of spring), so period 1 is March, or September on a southern
-- map. isSouthern defaults to the current map's.
function TCCalendar.getMonth(period, isSouthern)
    if isSouthern == nil then
        isSouthern = TCCalendar.isSouthern()
    end
    local month = period + 2 + (isSouthern and 6 or 0)
    return (month - 1) % 12 + 1
end

-- The year to show for a date. The game's year starts at period 1 (March,
-- or September on a southern map), so the months from January up to that
-- start still carry the previous currentYear. Players read "January, Year 1"
-- as coming before March, Year 1, so those months are shown as the next
-- year, as FS25_RedTape's getActualYear does. Only for display: anything
-- that counts or compares game years (year-to-date stats, holiday
-- allowance) keeps currentYear.
function TCCalendar.getDisplayYear(year, period)
    local isSouthern = TCCalendar.isSouthern()
    if TCCalendar.getMonth(period, isSouthern) < TCCalendar.getMonth(1, isSouthern) then
        return year + 1
    end
    return year
end

function TCCalendar.getDisplayYearOfPeriodIndex(periodIndex)
    local period = (periodIndex - 1) % Environment.PERIODS_IN_YEAR + 1
    return TCCalendar.getDisplayYear(TCCalendar.getYearOfPeriodIndex(periodIndex), period)
end

-- e.g. "Year 3", for a game year and period.
function TCCalendar.formatYear(year, period)
    return string.format(g_i18n:getText("tc_calendar_yearLabel"), TCCalendar.getDisplayYear(year, period))
end

-- The month's text key, for a period index. The key on its own is for text
-- rendered elsewhere (051's inbox message args).
function TCCalendar.getMonthTextKey(periodIndex)
    local period = (periodIndex - 1) % Environment.PERIODS_IN_YEAR + 1
    return "ui_month" .. TCCalendar.getMonth(period)
end

local function getMonthName(periodIndex)
    return g_i18n:getText(TCCalendar.getMonthTextKey(periodIndex))
end

local function formatYear(periodIndex)
    return string.format(g_i18n:getText("tc_calendar_yearLabel"), TCCalendar.getDisplayYearOfPeriodIndex(periodIndex))
end

-- e.g. "September" (049's forecast rows).
function TCCalendar.formatMonth(periodIndex)
    return getMonthName(periodIndex)
end

-- e.g. "September, Year 3".
function TCCalendar.formatPeriodIndex(periodIndex)
    return string.format("%s, %s", getMonthName(periodIndex), formatYear(periodIndex))
end

-- Days per period (040) --------------------------------------------------
-- Environment keeps two values: daysPerPeriod (in force now) and
-- plannedDaysPerPeriod (what the player last picked in the settings). The
-- planned value only takes over at the start of the next season, when
-- Environment also rescales currentDay. currentMonotonicDay is never
-- rescaled - it goes up by exactly one a day - so anything booked by date
-- (040's holidays) uses it as its day number, and these helpers work out
-- which month and day a monotonic day falls on: days before the next season
-- starts use daysPerPeriod, days from then on use plannedDaysPerPeriod (the
-- only future value that can be known).
--
-- Vanilla's Environment:getPeriodFromDay/getDayInPeriodFromDay/
-- getSeasonAtDay use today's days per period for every day, so they're wrong
-- for any day after a planned change (160): use getPeriodFromDay,
-- getDayInPeriodFromDay and getSeasonAtDay below for any day but today.
--
-- Every helper below works on a calendar "model" (getModel): today's
-- monotonic day, period index and day in it, and both days-per-period
-- values. The model defaults to the live environment. A saved or older one
-- is how 160's remapDay moves a booked day when the calendar changes.

-- The live calendar, as a model.
function TCCalendar.getModel()
    local environment = g_currentMission.environment
    return {
        day = environment.currentMonotonicDay,
        periodIndex = TCCalendar.getPeriodIndex(),
        dayInPeriod = environment.currentDayInPeriod,
        daysPerPeriod = environment.daysPerPeriod,
        plannedDaysPerPeriod = environment.plannedDaysPerPeriod or environment.daysPerPeriod,
    }
end

local function getPeriodOfIndex(periodIndex)
    return (periodIndex - 1) % Environment.PERIODS_IN_YEAR + 1
end

-- How many days from the model's today the next season starts (1 =
-- tomorrow).
function TCCalendar.getDaysUntilNextSeason(model)
    model = model or TCCalendar.getModel()
    local dayInSeason = ((getPeriodOfIndex(model.periodIndex) - 1) % 3) * model.daysPerPeriod + model.dayInPeriod
    return model.daysPerPeriod * 3 - dayInSeason + 1
end

local function getNextSeasonPeriodIndex(model)
    return model.periodIndex - (getPeriodOfIndex(model.periodIndex) - 1) % 3 + 3
end

-- The days per period a period index runs at: today's up to the next
-- season, the planned value from then on.
function TCCalendar.getDaysPerPeriodOfPeriodIndex(periodIndex, model)
    model = model or TCCalendar.getModel()
    if periodIndex < getNextSeasonPeriodIndex(model) then
        return model.daysPerPeriod
    end
    return model.plannedDaysPerPeriod
end

-- For a monotonic day: its period index, its day in that period, and the
-- days per period in force on it. With the live calendar (no model), a day
-- before today is dated by TCCalendarHistory, so a change of days per month
-- since doesn't move it. With a model given, a day before the model's today
-- is worked back at its days per period.
function TCCalendar.getDayInfo(monotonicDay, model)
    if model == nil then
        model = TCCalendar.getModel()
        if monotonicDay < model.day and TCCalendarHistory ~= nil then
            model = TCCalendarHistory.getModelOn(monotonicDay) or model
        end
    end
    local offset = monotonicDay - model.day
    local untilNextSeason = TCCalendar.getDaysUntilNextSeason(model)

    if offset < untilNextSeason then
        local daysPerPeriod = model.daysPerPeriod
        local dayIndex = model.dayInPeriod - 1 + offset
        local periodOffset = math.floor(dayIndex / daysPerPeriod)
        return model.periodIndex + periodOffset, dayIndex - periodOffset * daysPerPeriod + 1, daysPerPeriod
    end

    local daysPerPeriod = model.plannedDaysPerPeriod
    local dayIndex = offset - untilNextSeason
    local periodOffset = math.floor(dayIndex / daysPerPeriod)
    return getNextSeasonPeriodIndex(model) + periodOffset, dayIndex - periodOffset * daysPerPeriod + 1, daysPerPeriod
end

-- getDayInfo the other way round: the monotonic day a period index's day
-- falls on (clamped into the period). Before today for a day already gone.
function TCCalendar.getMonotonicDay(periodIndex, dayInPeriod, model)
    model = model or TCCalendar.getModel()
    local nextSeasonPeriodIndex = getNextSeasonPeriodIndex(model)
    if periodIndex < nextSeasonPeriodIndex then
        local day = math.max(1, math.min(dayInPeriod, model.daysPerPeriod))
        return model.day + (periodIndex - model.periodIndex) * model.daysPerPeriod + day - model.dayInPeriod
    end
    local day = math.max(1, math.min(dayInPeriod, model.plannedDaysPerPeriod))
    return model.day + TCCalendar.getDaysUntilNextSeason(model) +
        (periodIndex - nextSeasonPeriodIndex) * model.plannedDaysPerPeriod + day - 1
end

-- The period (1 to 12) a monotonic day falls in.
function TCCalendar.getPeriodFromDay(monotonicDay)
    return getPeriodOfIndex((TCCalendar.getDayInfo(monotonicDay)))
end

function TCCalendar.getDayInPeriodFromDay(monotonicDay)
    local _, dayInPeriod = TCCalendar.getDayInfo(monotonicDay)
    return dayInPeriod
end

-- The season a monotonic day falls in (Season.SPRING for periods 1 to 3,
-- and so on), as vanilla's getSeasonAtDay.
function TCCalendar.getSeasonAtDay(monotonicDay)
    local seasons = { Season.SPRING, Season.SUMMER, Season.AUTUMN, Season.WINTER }
    return seasons[math.floor((TCCalendar.getPeriodFromDay(monotonicDay) - 1) / 3) + 1]
end

-- The next monotonic day the calendar reads period/dayInPeriod, today
-- included, within the coming year.
function TCCalendar.getNextOccurrenceDay(period, dayInPeriod, model)
    model = model or TCCalendar.getModel()
    local periodIndex = model.periodIndex + (period - getPeriodOfIndex(model.periodIndex)) % Environment.PERIODS_IN_YEAR
    local day = TCCalendar.getMonotonicDay(periodIndex, dayInPeriod, model)
    if day < model.day then
        day = TCCalendar.getMonotonicDay(periodIndex + Environment.PERIODS_IN_YEAR, dayInPeriod, model)
    end
    return day
end

-- 161: the day `months` months after a day, by the calendar (so a planned
-- change is allowed for, and a day gone is dated as it was): whole months
-- land on the same share of the month (the 2nd of 4 becomes the 1st of 2),
-- and a fraction of a month is that share of the month landed in, rounded.
-- Never before `day`.
function TCCalendar.addMonths(day, months, model)
    local periodIndex, dayInPeriod, daysPerPeriod = TCCalendar.getDayInfo(day, model)
    model = model or TCCalendar.getModel()
    local whole = math.floor(months)
    local targetIndex = periodIndex + whole
    local targetDaysPerPeriod = TCCalendar.getDaysPerPeriodOfPeriodIndex(targetIndex, model)
    local targetDay = math.floor((dayInPeriod - 1) * targetDaysPerPeriod / daysPerPeriod) + 1
    local result = TCCalendar.getMonotonicDay(targetIndex, targetDay, model) +
        math.floor((months - whole) * targetDaysPerPeriod + 0.5)
    return math.max(day, result)
end

-- 160: a day booked under one calendar (fromModel) moved to the same date
-- under another (toModel, default the live one), after the days per period
-- changed or was planned to. Its day in the month keeps its share of the
-- month: a deadline (isEnd) the end of that share, so it's never cut short
-- (Oct 1 of 1 becomes Oct 2 of 2), anything else the start of it. A day
-- before today stays as it is, and nothing moves to before today.
function TCCalendar.remapDay(day, fromModel, toModel, isEnd)
    toModel = toModel or TCCalendar.getModel()
    if day == nil or day < toModel.day or day < fromModel.day then
        return day
    end

    local periodIndex, dayInPeriod, daysPerPeriod = TCCalendar.getDayInfo(day, fromModel)
    local newDaysPerPeriod = TCCalendar.getDaysPerPeriodOfPeriodIndex(periodIndex, toModel)
    local newDayInPeriod = dayInPeriod
    if newDaysPerPeriod ~= daysPerPeriod then
        if isEnd then
            newDayInPeriod = math.ceil(dayInPeriod * newDaysPerPeriod / daysPerPeriod)
        else
            newDayInPeriod = math.floor((dayInPeriod - 1) * newDaysPerPeriod / daysPerPeriod) + 1
        end
    end
    return math.max(toModel.day, TCCalendar.getMonotonicDay(periodIndex, newDayInPeriod, toModel))
end

-- How many months from one day to another, by their dates: whole months
-- plus the share of a month between their days (June 10 to August 24 at 28
-- days a month is 2.5).
function TCCalendar.getMonthsBetween(fromDay, toDay)
    local fromIndex, fromDayInPeriod, fromDaysPerPeriod = TCCalendar.getDayInfo(fromDay)
    local toIndex, toDayInPeriod, toDaysPerPeriod = TCCalendar.getDayInfo(toDay)
    return (toIndex + (toDayInPeriod - 1) / toDaysPerPeriod) - (fromIndex + (fromDayInPeriod - 1) / fromDaysPerPeriod)
end

function TCCalendar.getDaysPerPeriodOn(monotonicDay)
    local _, _, daysPerPeriod = TCCalendar.getDayInfo(monotonicDay)
    return daysPerPeriod
end

-- 160: whether two models put every day from the later one's today on the
-- same date, so nothing booked needs moving.
function TCCalendar.isSameCalendar(a, b)
    local from = a.day <= b.day and a or b
    local to = from == a and b or a
    local fromIndex, fromDay, fromDaysPerPeriod = TCCalendar.getDayInfo(to.day, from)
    if fromIndex ~= to.periodIndex or fromDay ~= to.dayInPeriod or fromDaysPerPeriod ~= to.daysPerPeriod then
        return false
    end
    -- After this season both run at a single value.
    local afterSeason = to.day + TCCalendar.getDaysUntilNextSeason(to)
    local _, _, laterDaysPerPeriod = TCCalendar.getDayInfo(afterSeason, from)
    return laterDaysPerPeriod == to.plannedDaysPerPeriod
end

-- The monotonic day the current year ends on. A year always ends at the end
-- of a season, so every season after this one runs at the planned days per
-- period.
function TCCalendar.getLastDayOfYear()
    local environment = g_currentMission.environment
    local seasonsLeft = math.floor((Environment.PERIODS_IN_YEAR - environment.currentPeriod) / 3)
    return environment.currentMonotonicDay + TCCalendar.getDaysUntilNextSeason() - 1 +
        seasonsLeft * 3 * environment.plannedDaysPerPeriod
end

-- "June 10" - or just "June" at one day per period, where the day number
-- says nothing.
local function formatMonthDay(periodIndex, dayInPeriod, daysPerPeriod)
    if daysPerPeriod <= 1 then
        return getMonthName(periodIndex)
    end
    return string.format("%s %d", getMonthName(periodIndex), dayInPeriod)
end

-- e.g. "June 10, Year 2".
function TCCalendar.formatDay(monotonicDay)
    local periodIndex, dayInPeriod, daysPerPeriod = TCCalendar.getDayInfo(monotonicDay)
    return string.format("%s, %s", formatMonthDay(periodIndex, dayInPeriod, daysPerPeriod), formatYear(periodIndex))
end

-- e.g. "June 10" - formatDay without the year, for a list column (049).
function TCCalendar.formatDayShort(monotonicDay)
    return formatMonthDay(TCCalendar.getDayInfo(monotonicDay))
end

-- e.g. "June 10-14, Year 2", "June 30 - July 2, Year 2", or one day as
-- formatDay.
function TCCalendar.formatDayRange(firstDay, lastDay)
    if lastDay <= firstDay then
        return TCCalendar.formatDay(firstDay)
    end

    local firstIndex, firstDayInPeriod, firstDaysPerPeriod = TCCalendar.getDayInfo(firstDay)
    local lastIndex, lastDayInPeriod, lastDaysPerPeriod = TCCalendar.getDayInfo(lastDay)

    if firstIndex == lastIndex and firstDaysPerPeriod > 1 then
        return string.format("%s %d-%d, %s", getMonthName(firstIndex), firstDayInPeriod, lastDayInPeriod,
            formatYear(firstIndex))
    end

    local first = formatMonthDay(firstIndex, firstDayInPeriod, firstDaysPerPeriod)
    local last = formatMonthDay(lastIndex, lastDayInPeriod, lastDaysPerPeriod)
    if TCCalendar.getDisplayYearOfPeriodIndex(firstIndex) == TCCalendar.getDisplayYearOfPeriodIndex(lastIndex) then
        return string.format("%s - %s, %s", first, last, formatYear(lastIndex))
    end
    return string.format("%s, %s - %s, %s", first, formatYear(firstIndex), last, formatYear(lastIndex))
end
