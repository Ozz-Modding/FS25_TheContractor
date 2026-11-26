-- The dates past days fell on.
--
-- Days are monotonic, and TCCalendar dates them from today's calendar. That
-- holds from today on, but not for a day before the days per month last
-- changed: worked back at today's value, a job finished in May can read as
-- March. So the server keeps a short history of the calendar: an anchor (a
-- monotonic day, its period index, day in period and days per period)
-- whenever today's date isn't the one the last anchor predicts, which is
-- only when the days per month change (taken up at a season's start, or as
-- a save loads). A day before today is dated from the last anchor at or
-- before it (TCCalendar.getDayInfo).
--
-- Saved, sent to joining clients and broadcast as it grows
-- (TCCalendarHistoryEvent). A save from before this has no history: its
-- first anchor is today's calendar at the first update, and days before
-- that are dated back from it, as they always were.

TCCalendarHistory = {}

TCCalendarHistory.FIELDS = { "day", "periodIndex", "dayInPeriod", "daysPerPeriod" }

-- Oldest first, one per day at most.
TCCalendarHistory.anchors = {}
TCCalendarHistory.needsCheck = false

-- loadMap, before the save's loaded.
function TCCalendarHistory.install()
    TCCalendarHistory.anchors = {}
    TCCalendarHistory.needsCheck = true
    if g_currentMission:getIsServer() then
        -- Vanilla takes up a new days per month before it publishes either.
        g_messageCenter:subscribe(MessageType.DAY_CHANGED, TCCalendarHistory.record, TCCalendarHistory)
        g_messageCenter:subscribe(MessageType.PERIOD_LENGTH_CHANGED, TCCalendarHistory.record, TCCalendarHistory)
    end
end

function TCCalendarHistory.uninstall()
    if g_messageCenter ~= nil then
        g_messageCenter:unsubscribeAll(TCCalendarHistory)
    end
end

-- An anchor is a calendar model (TCCalendar.getModel's shape) running at
-- one days per month throughout.
local function makeAnchor(day, periodIndex, dayInPeriod, daysPerPeriod)
    return {
        day = day,
        periodIndex = periodIndex,
        dayInPeriod = dayInPeriod,
        daysPerPeriod = daysPerPeriod,
        plannedDaysPerPeriod = daysPerPeriod,
    }
end

-- Server, every frame: the first update after a load anchors the calendar
-- the save came back with.
function TCCalendarHistory.update()
    if not TCCalendarHistory.needsCheck then
        return
    end
    TCCalendarHistory.needsCheck = false
    TCCalendarHistory.record()
end

-- Server: anchors today if its date isn't the one the history predicts.
function TCCalendarHistory.record()
    if not g_currentMission:getIsServer() then
        return
    end
    local live = TCCalendar.getModel()
    local anchor = makeAnchor(live.day, live.periodIndex, live.dayInPeriod, live.daysPerPeriod)
    if not TCCalendarHistory.add(anchor) then
        return
    end
    TCLog.info("TheContractor: calendar history: day %d is period %d day %d at %d day(s) a month", anchor.day,
        anchor.periodIndex, anchor.dayInPeriod, anchor.daysPerPeriod)
    if g_server ~= nil then
        g_server:broadcastEvent(TCCalendarHistoryEvent.new(anchor))
    end
end

-- Every machine: adds an anchor unless the history already dates its day
-- that way (or it's older than the last). A second one the same day
-- replaces the first. Whether it was added.
function TCCalendarHistory.add(anchor)
    local anchors = TCCalendarHistory.anchors
    local last = anchors[#anchors]
    if last ~= nil then
        if anchor.day < last.day then
            return false
        end
        local periodIndex, dayInPeriod, daysPerPeriod = TCCalendar.getDayInfo(anchor.day, last)
        if periodIndex == anchor.periodIndex and dayInPeriod == anchor.dayInPeriod and
            daysPerPeriod == anchor.daysPerPeriod then
            return false
        end
        if last.day == anchor.day then
            table.remove(anchors)
        end
    end
    table.insert(anchors, anchor)
    return true
end

-- The calendar model a past day is dated by: the last anchor at or before
-- it, or the first for a day before any. Nil with no history.
function TCCalendarHistory.getModelOn(day)
    local anchors = TCCalendarHistory.anchors
    for i = #anchors, 1, -1 do
        if anchors[i].day <= day then
            return anchors[i]
        end
    end
    return anchors[1]
end

local function isValid(anchor)
    return anchor.day ~= nil and anchor.periodIndex ~= nil and anchor.dayInPeriod ~= nil and
        anchor.daysPerPeriod ~= nil and anchor.daysPerPeriod >= 1 and anchor.dayInPeriod >= 1
end

local function setAnchors(list)
    table.sort(list, function(a, b)
        return a.day < b.day
    end)
    TCCalendarHistory.anchors = {}
    for _, anchor in ipairs(list) do
        TCCalendarHistory.add(anchor)
    end
end

-- Save --------------------------------------------------------------------------

function TCCalendarHistory.loadFromXMLFile(xmlFile)
    local list = {}
    local i = 0
    while true do
        local key = string.format("%s.calendarHistory.anchor(%d)", TheContractor.SaveKey, i)
        if not hasXMLProperty(xmlFile, key) then
            break
        end
        local anchor = makeAnchor(getXMLInt(xmlFile, key .. "#day"), getXMLInt(xmlFile, key .. "#periodIndex"),
            getXMLInt(xmlFile, key .. "#dayInPeriod"), getXMLInt(xmlFile, key .. "#daysPerPeriod"))
        if isValid(anchor) then
            table.insert(list, anchor)
        else
            TCLog.xmlWarning(xmlFile, "TheContractor: skipping a calendar history anchor with missing values (%s)", key)
        end
        i = i + 1
    end
    setAnchors(list)
end

function TCCalendarHistory.saveToXmlFile(xmlFile)
    for i, anchor in ipairs(TCCalendarHistory.anchors) do
        local key = string.format("%s.calendarHistory.anchor(%d)", TheContractor.SaveKey, i - 1)
        for _, field in ipairs(TCCalendarHistory.FIELDS) do
            setXMLInt(xmlFile, key .. "#" .. field, anchor[field])
        end
    end
end

-- Stream --------------------------------------------------------------------------

function TCCalendarHistory.writeAnchor(streamId, anchor)
    for _, field in ipairs(TCCalendarHistory.FIELDS) do
        streamWriteInt32(streamId, anchor[field])
    end
end

function TCCalendarHistory.readAnchor(streamId)
    return makeAnchor(streamReadInt32(streamId), streamReadInt32(streamId), streamReadInt32(streamId),
        streamReadInt32(streamId))
end

function TCCalendarHistory.writeInitialClientState(streamId, connection)
    streamWriteInt32(streamId, #TCCalendarHistory.anchors)
    for _, anchor in ipairs(TCCalendarHistory.anchors) do
        TCCalendarHistory.writeAnchor(streamId, anchor)
    end
end

function TCCalendarHistory.readInitialClientState(streamId, connection)
    local list = {}
    for _ = 1, streamReadInt32(streamId) do
        table.insert(list, TCCalendarHistory.readAnchor(streamId))
    end
    setAnchors(list)
end
