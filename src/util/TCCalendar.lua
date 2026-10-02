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

-- Same period->month mapping (period 1 == March) as MenuContractor's
-- periodToMonth.
local function getMonthName(periodIndex)
    local period = (periodIndex - 1) % Environment.PERIODS_IN_YEAR + 1
    local month = (period + 1) % 12 + 1
    return g_i18n:getText("ui_month" .. month)
end

local function formatYear(periodIndex)
    return string.format(g_i18n:getText("tc_calendar_yearLabel"), TCCalendar.getYearOfPeriodIndex(periodIndex))
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

-- How many days from today the next season starts (1 = tomorrow).
function TCCalendar.getDaysUntilNextSeason()
    local environment = g_currentMission.environment
    local dayInSeason = ((environment.currentPeriod - 1) % 3) * environment.daysPerPeriod +
        environment.currentDayInPeriod
    return environment.daysPerPeriod * 3 - dayInSeason + 1
end

-- For a monotonic day from today on: its period index, its day in that
-- period, and the days per period in force on it. Days before today are
-- worked out at today's days per period, which is wrong for anything before
-- the last change - don't rely on them.
function TCCalendar.getDayInfo(monotonicDay)
    local environment = g_currentMission.environment
    local offset = monotonicDay - environment.currentMonotonicDay
    local untilNextSeason = TCCalendar.getDaysUntilNextSeason()

    if offset < untilNextSeason then
        local daysPerPeriod = environment.daysPerPeriod
        local dayIndex = environment.currentDayInPeriod - 1 + offset
        local periodOffset = math.floor(dayIndex / daysPerPeriod)
        return TCCalendar.getPeriodIndex() + periodOffset, dayIndex - periodOffset * daysPerPeriod + 1, daysPerPeriod
    end

    local daysPerPeriod = environment.plannedDaysPerPeriod
    local nextSeasonPeriodIndex = TCCalendar.getPeriodIndex() - (environment.currentPeriod - 1) % 3 + 3
    local dayIndex = offset - untilNextSeason
    local periodOffset = math.floor(dayIndex / daysPerPeriod)
    return nextSeasonPeriodIndex + periodOffset, dayIndex - periodOffset * daysPerPeriod + 1, daysPerPeriod
end

function TCCalendar.getDaysPerPeriodOn(monotonicDay)
    local _, _, daysPerPeriod = TCCalendar.getDayInfo(monotonicDay)
    return daysPerPeriod
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
    if TCCalendar.getYearOfPeriodIndex(firstIndex) == TCCalendar.getYearOfPeriodIndex(lastIndex) then
        return string.format("%s - %s, %s", first, last, formatYear(lastIndex))
    end
    return string.format("%s, %s - %s, %s", first, formatYear(firstIndex), last, formatYear(lastIndex))
end
