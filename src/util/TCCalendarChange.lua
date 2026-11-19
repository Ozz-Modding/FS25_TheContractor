-- Booked days across a days-per-month change (160, 161).
--
-- Everything we book ahead is a monotonic day, worked out from the calendar
-- as it stood (TCCalendar: the rest of this season at today's days per
-- period, later seasons at the planned value). When that changes - the
-- player plans another value, or the game takes up a planned one other
-- than at a season's start (vanilla does as a save loads, unless it's
-- spring, and after a jump in days) - the same day number falls on another
-- date. What was agreed is the date, not the count of days: a job due in
-- October, an invoice due in June, an auction in April.
--
-- The server keeps the calendar our days were worked out under (model,
-- saved) and checks it on a planned change, on vanilla's
-- PERIOD_LENGTH_CHANGED and once at the first update after a load. When
-- it's changed, every subsystem in SUBSYSTEMS moves its booked days to the
-- same dates (remapDates(fromModel, toModel), with TCCalendar.remapDay) on
-- every machine: the server does it and sends both calendars in
-- TCCalendarChangedEvent, so each client moves its own copies the same way
-- without reading a calendar its settings event may not have reached yet.
-- Anything only the server holds, it moves alone; anything it then has to
-- tell clients about (an auction's new days) it sends after that event.
--
-- Anything new that books a day the player sees as a date (or a wait in
-- months) adds a remapDates to its subsystem and its key to SUBSYSTEMS.
-- Counts of days (sick days, a course's days, a claim's few days' delay)
-- don't move.

TCCalendarChange = {}

TCCalendarChange.SUBSYSTEMS = { "Jobs", "Inbox", "Finances", "RandomEvents", "RepairContracts", "PublicEvents" }

TCCalendarChange.FIELDS = { "day", "periodIndex", "dayInPeriod", "daysPerPeriod", "plannedDaysPerPeriod" }

-- Server: the calendar our booked days were worked out under; nil until
-- the first update's check on a save from before it.
TCCalendarChange.model = nil
TCCalendarChange.needsCheck = false

-- loadMap, before the save's loaded.
function TCCalendarChange.install()
    TCCalendarChange.model = nil
    TCCalendarChange.needsCheck = true
    if g_currentMission:getIsServer() then
        g_messageCenter:subscribe(MessageType.PERIOD_LENGTH_CHANGED, TCCalendarChange.check, TCCalendarChange)
    end
end

function TCCalendarChange.uninstall()
    if g_messageCenter ~= nil then
        g_messageCenter:unsubscribeAll(TCCalendarChange)
    end
end

-- Server, every frame: the first update after a load checks the calendar.
-- A save from before 160 has no calendar to check against, so its jobs get
-- 160's repair instead (Jobs:repairLegacyDates).
function TCCalendarChange.update()
    if not TCCalendarChange.needsCheck or not g_currentMission:getIsServer() then
        return
    end
    TCCalendarChange.needsCheck = false
    local tc = g_currentMission.TheContractor
    if TCCalendarChange.model == nil and tc ~= nil and tc.Jobs ~= nil then
        tc.Jobs:repairLegacyDates()
    end
    TCCalendarChange.check()
end

-- Server: compares the calendar with the one our days were worked out
-- under and, if it's changed, moves them.
function TCCalendarChange.check()
    if not g_currentMission:getIsServer() then
        return
    end
    local live = TCCalendar.getModel()
    local previous = TCCalendarChange.model
    TCCalendarChange.model = live
    if previous == nil or TCCalendar.isSameCalendar(previous, live) then
        return
    end

    TCLog.info("TheContractor: calendar changed (%d day(s) a month now, %d planned; was %d, %d planned) - " ..
        "moving booked dates", live.daysPerPeriod, live.plannedDaysPerPeriod, previous.daysPerPeriod,
        previous.plannedDaysPerPeriod)
    -- First, so a client has moved its copies before anything the server
    -- sends as it moves its own.
    if g_server ~= nil then
        g_server:broadcastEvent(TCCalendarChangedEvent.new(previous, live))
    end
    TCCalendarChange.apply(previous, live)
end

-- Every machine: each subsystem moves its booked days.
function TCCalendarChange.apply(fromModel, toModel)
    local tc = g_currentMission.TheContractor
    if tc == nil then
        return
    end
    for _, key in ipairs(TCCalendarChange.SUBSYSTEMS) do
        local subsystem = tc[key]
        if subsystem ~= nil and subsystem.remapDates ~= nil then
            subsystem:remapDates(fromModel, toModel)
        end
    end
end

-- Save --------------------------------------------------------------------------

function TCCalendarChange.loadFromXMLFile(xmlFile)
    local key = TheContractor.SaveKey .. ".calendar"
    local model = {}
    for _, field in ipairs(TCCalendarChange.FIELDS) do
        model[field] = getXMLInt(xmlFile, key .. "#" .. field)
        if model[field] == nil then
            return
        end
    end
    if model.daysPerPeriod >= 1 and model.plannedDaysPerPeriod >= 1 then
        TCCalendarChange.model = model
    end
end

function TCCalendarChange.saveToXmlFile(xmlFile)
    local model = TCCalendarChange.model
    if model == nil then
        return
    end
    local key = TheContractor.SaveKey .. ".calendar"
    for _, field in ipairs(TCCalendarChange.FIELDS) do
        setXMLInt(xmlFile, key .. "#" .. field, model[field])
    end
end

-- Stream (TCCalendarChangedEvent) --------------------------------------------------

function TCCalendarChange.writeModel(streamId, model)
    for _, field in ipairs(TCCalendarChange.FIELDS) do
        streamWriteInt32(streamId, model[field])
    end
end

function TCCalendarChange.readModel(streamId)
    local model = {}
    for _, field in ipairs(TCCalendarChange.FIELDS) do
        model[field] = streamReadInt32(streamId)
    end
    return model
end

-- A planned change. Hooked at module scope, guarded so it can't stack (as
-- 040's Holidays does). setPlannedDaysPerPeriod runs on every machine (the
-- settings event applies it on each); only the server acts.
if Environment ~= nil and Environment.setPlannedDaysPerPeriod ~= nil and
        not Environment.tcCalendarChangeHookInstalled then
    Environment.setPlannedDaysPerPeriod = Utils.appendedFunction(Environment.setPlannedDaysPerPeriod, function()
        if g_currentMission ~= nil and g_currentMission.TheContractor ~= nil then
            TCCalendarChange.check()
        end
    end)
    Environment.tcCalendarChangeHookInstalled = true
end
