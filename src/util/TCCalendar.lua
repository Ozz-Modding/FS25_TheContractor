-- Absolute "period index" - months since the start of the save, counting
-- from 1 in year 1's first period - for anything that needs to say "N
-- months from now" across a year boundary (038's notice expiry, 039's
-- retirement date). Environment derives currentYear and currentPeriod from
-- the same day counter and both are already up to date by the time
-- PERIOD_CHANGED fires, so the index steps by exactly one per period
-- change. Always >= 1, so 0 is free as a "none" sentinel on the wire.

TCCalendar = {}

function TCCalendar.getPeriodIndex()
    local environment = g_currentMission.environment
    return (environment.currentYear - 1) * Environment.PERIODS_IN_YEAR + environment.currentPeriod
end

-- e.g. "September, Year 3". Same period->month mapping (period 1 ==
-- March) as MenuContractor's periodToMonth.
function TCCalendar.formatPeriodIndex(periodIndex)
    local period = (periodIndex - 1) % Environment.PERIODS_IN_YEAR + 1
    local year = math.floor((periodIndex - 1) / Environment.PERIODS_IN_YEAR) + 1
    local month = (period + 1) % 12 + 1
    return string.format("%s, %s", g_i18n:getText("ui_month" .. month),
        string.format(g_i18n:getText("tc_calendar_yearLabel"), year))
end
