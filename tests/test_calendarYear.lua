-- Display years: the game's year runs March to February, so January and
-- February carry the previous currentYear. Dates show them as the next
-- year, as FS25_RedTape's getActualYear does.

local function setup()
    local world = stubs.install()
    for month = 1, 12 do
        world.texts["ui_month" .. month] = "Month " .. month
    end
    Environment = { PERIODS_IN_YEAR = 12 }
    g_currentMission.environment = {
        currentYear = 1,
        currentPeriod = 1,
        currentDayInPeriod = 1,
        daysPerPeriod = 1,
        plannedDaysPerPeriod = 1,
        currentMonotonicDay = 1,
    }
    world:load("src/util/TCCalendar.lua")
    return world
end

test("March to December keep the game year, January and February show the next", function()
    setup()
    assertEquals(TCCalendar.getDisplayYear(1, 1), 1, "March")
    assertEquals(TCCalendar.getDisplayYear(1, 10), 1, "December")
    assertEquals(TCCalendar.getDisplayYear(1, 11), 2, "January")
    assertEquals(TCCalendar.getDisplayYear(1, 12), 2, "February")
    assertEquals(TCCalendar.getDisplayYear(2, 1), 2, "the next March")
end)

test("period indexes give the same display year", function()
    setup()
    assertEquals(TCCalendar.getDisplayYearOfPeriodIndex(10), 1, "December, year 1")
    assertEquals(TCCalendar.getDisplayYearOfPeriodIndex(11), 2, "January, year 1")
    assertEquals(TCCalendar.getDisplayYearOfPeriodIndex(13), 2, "March, year 2")
    assertEquals(TCCalendar.getDisplayYearOfPeriodIndex(24), 3, "February, year 2")
end)

test("formatted dates use the display year", function()
    setup()
    assertEquals(TCCalendar.formatPeriodIndex(11), "Month 1, Year 2")
    assertEquals(TCCalendar.formatYear(1, 12), "Year 2")
end)

test("a range from December into January spans two years", function()
    setup()
    -- One day per period, starting in March: day 10 is December, day 11 January.
    assertEquals(TCCalendar.formatDayRange(10, 11), "Month 12, Year 1 - Month 1, Year 2")
    assertEquals(TCCalendar.formatDayRange(11, 13), "Month 1 - Month 3, Year 2")
end)

test("the Finances year's totals run January to December", function()
    local world = setup()
    FinanceStats = { statNames = {}, statNameToIndex = {} }
    MoneyType = { LAST_ID = 0, register = function(name) return name end }
    TCFinanceYearStatsEvent = { new = function() return {} end }
    g_server = { broadcastEvent = function() end }
    TheContractor = { SaveKey = "TheContractor" }
    world:load("src/business/Finances.lua")
    local finances = TheContractorFinances.new()
    local environment = g_currentMission.environment

    environment.currentPeriod = 10 -- December, year 1
    finances:recordWages(1, 100)
    assertEquals(finances:getYearStats(1).year, 1)
    assertEquals(finances:getYearStats(1).wages, 100)

    environment.currentPeriod = 11 -- January: a new calendar year
    assertEquals(finances:getYearStats(1).year, 2)
    assertEquals(finances:getYearStats(1).wages, 0, "reset in January")
    finances:recordWages(1, 50)

    environment.currentYear = 2
    environment.currentPeriod = 1 -- March: the game's new year, same calendar year
    assertEquals(finances:getYearStats(1).year, 2)
    assertEquals(finances:getYearStats(1).wages, 50, "not reset in March")
end)
