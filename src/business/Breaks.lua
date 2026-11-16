-- Worker breaks (131). Field staff take three breaks in the working day
-- (097): BREAKS, each with a window its start must fall in. A break is
-- taken the first time in its window the worker is available
-- (TheContractorWorkingHours.isAvailable: idle and at work, workshop staff
-- included), and always runs its full length. Out on a job, in its
-- cooldown or driving until the window closes, they miss it. Breaks go in
-- order: a later one never starts while an earlier one is still to come.
-- Office staff (057, 090) take none.
--
-- The staffBreaks setting turns the short breaks, or all of them, off
-- (isEnabled). A break that's off is skipped, so the next one can start, and
-- when its window closes it's OFF: never missed, so no knock. Turned back on
-- mid-day, any whose window is still open can be taken.
--
-- A worker on a break is still IDLE, but WorkingHours.getState says
-- ON_BREAK until breakUntil, so they aren't on site: not offered for jobs
-- or driving, off the standing spots, and unavailable to ADS's workshop,
-- which holds a running order needing their trade until they're back
-- (ADS_OwnWorkshop's ownWorkshopStaff progress rule).
--
-- At END_HOUR each worker's day is judged: a missed short break (either or
-- both) is MORALE.short, a missed lunch MORALE.lunch, added together. A
-- break whose window closed while they were away (sick, on holiday,
-- training) or before they were hired is excused, not missed.
--
-- State on the worker: breakUntil (absolute game minutes; streamed and
-- saved, TCWorkerBreakEvent when one starts, the end worked out from the
-- time on every machine), and server-only breakDay (the monotonic day the
-- record is for), breakResults ({ [key] = RESULT }) and breakJudgedDay.
-- Saved through WorkingHours.writeXML/readXML.

TheContractorBreaks = {}
TheContractorBreaks_mt = Class(TheContractorBreaks)

local MINUTES_PER_DAY = 24 * 60

-- from/to: the earliest and latest start, in minutes of the day. group: the
-- morale knock it counts towards when missed.
TheContractorBreaks.BREAKS = {
    { key = "morning", minutes = 15, from = 10 * 60, to = 11 * 60 + 45, group = "short" },
    { key = "lunch", minutes = 30, from = 12 * 60, to = 15 * 60, group = "lunch" },
    { key = "afternoon", minutes = 15, from = 15 * 60, to = 17 * 60 + 30, group = "short" },
}

-- Each group's knock, once however many of its breaks were missed.
TheContractorBreaks.MORALE = {
    short = -2,
    lunch = -5,
}

TheContractorBreaks.RESULT = {
    TAKEN = "taken",
    MISSED = "missed",
    EXCUSED = "excused",
    OFF = "off",
}

-- Whether the staffBreaks setting lets staff take this break.
function TheContractorBreaks.isEnabled(definition)
    local tc = g_currentMission.TheContractor
    local settings = tc ~= nil and tc.Settings or nil
    if settings == nil then
        return true
    end
    local mode = settings:get("staffBreaks")
    local MODES = TheContractorSettings.STAFF_BREAKS
    if mode == MODES.NONE then
        return false
    end
    return mode ~= MODES.LUNCH_ONLY or definition.group == "lunch"
end

function TheContractorBreaks.new()
    local self = {}
    setmetatable(self, TheContractorBreaks_mt)
    -- Server: the last game minute looked at. Live only.
    self.lastMinutes = nil
    return self
end

function TheContractorBreaks.getDefinition(key)
    for _, definition in ipairs(TheContractorBreaks.BREAKS) do
        if definition.key == key then
            return definition
        end
    end
    return nil
end

-- The day's record (server) ---------------------------------------------------------

-- Starts the worker's record for `day` if it's for another one. Breaks whose
-- window has already closed are excused: they weren't here for them (a new
-- hire, or a save from before 131).
function TheContractorBreaks.startDay(worker, day, minuteOfDay)
    if worker.breakDay == day then
        worker.breakResults = worker.breakResults or {}
        return
    end
    worker.breakDay = day
    worker.breakResults = {}
    for _, definition in ipairs(TheContractorBreaks.BREAKS) do
        if minuteOfDay > definition.to then
            worker.breakResults[definition.key] = TheContractorBreaks.RESULT.EXCUSED
        end
    end
end

-- A break whose window has closed without it being taken.
local function closeBreak(worker, definition)
    local RESULT = TheContractorBreaks.RESULT
    if not TheContractorBreaks.isEnabled(definition) then
        worker.breakResults[definition.key] = RESULT.OFF
        return
    end
    worker.breakResults[definition.key] = TheContractorWorkingHours.isAway(worker) and RESULT.EXCUSED or RESULT.MISSED
end

-- The next break still to come today (in order, skipping any that are
-- off), or nil.
function TheContractorBreaks.getNextBreak(worker)
    for _, definition in ipairs(TheContractorBreaks.BREAKS) do
        if (worker.breakResults == nil or worker.breakResults[definition.key] == nil) and
            TheContractorBreaks.isEnabled(definition) then
            return definition
        end
    end
    return nil
end

-- The morale knock for a day's results: each group with a missed break
-- counts once.
function TheContractorBreaks.getMoraleDelta(results)
    local missedGroups = {}
    for _, definition in ipairs(TheContractorBreaks.BREAKS) do
        if results ~= nil and results[definition.key] == TheContractorBreaks.RESULT.MISSED then
            missedGroups[definition.group] = true
        end
    end
    local delta = 0
    for group in pairs(missedGroups) do
        delta = delta + TheContractorBreaks.MORALE[group]
    end
    return delta
end

-- Taking a break (server) -------------------------------------------------------------

local function refreshWorkshop(farmId)
    if TCADSWorkshop ~= nil and TCADSWorkshop.refresh ~= nil then
        TCADSWorkshop.refresh(farmId)
    end
end

function TheContractorBreaks:startBreak(worker, definition, now)
    worker.breakResults[definition.key] = TheContractorBreaks.RESULT.TAKEN
    TheContractorBreaks.applyBreak(worker, now + definition.minutes)
    if g_server ~= nil then
        g_server:broadcastEvent(TCWorkerBreakEvent.new(worker.farmId, worker.id, worker.breakUntil))
    end
    TCLog.info("TheContractor: farm %d worker %d (%s) on their %s break until %s", worker.farmId, worker.id,
        worker.name, definition.key, TheContractorWorkingHours.formatTime(worker.breakUntil))
    refreshWorkshop(worker.farmId)
end

-- One worker at `now`: ends a break that's over, closes windows that have
-- passed, and starts the next break if it's due and they're free.
function TheContractorBreaks:updateWorker(worker, now)
    local minuteOfDay = now % MINUTES_PER_DAY
    TheContractorBreaks.startDay(worker, math.floor(now / MINUTES_PER_DAY), minuteOfDay)

    if worker.breakUntil ~= nil then
        if now < worker.breakUntil then
            return
        end
        worker.breakUntil = nil
        TCLog.info("TheContractor: farm %d worker %d (%s) back from their break", worker.farmId, worker.id,
            worker.name)
        refreshWorkshop(worker.farmId)
    end

    for _, definition in ipairs(TheContractorBreaks.BREAKS) do
        if worker.breakResults[definition.key] == nil then
            if minuteOfDay < definition.from then
                return
            end
            -- One that's off is skipped, so the next isn't held back by it.
            if minuteOfDay > definition.to then
                closeBreak(worker, definition)
            elseif TheContractorBreaks.isEnabled(definition) then
                if TheContractorWorkingHours.isAvailable(worker, now) then
                    self:startBreak(worker, definition, now)
                end
                return
            end
        end
    end
end

-- The end of `day`'s working hours: every worker whose record is for that
-- day has what's left closed and takes the knock for what they missed.
function TheContractorBreaks:judgeDay(farmId, day)
    local byDelta = {}
    for _, worker in ipairs(g_currentMission.TheContractor.Staff:getRoster(farmId)) do
        if worker.breakDay == day and worker.breakJudgedDay ~= day then
            worker.breakJudgedDay = day
            for _, definition in ipairs(TheContractorBreaks.BREAKS) do
                if worker.breakResults[definition.key] == nil then
                    closeBreak(worker, definition)
                end
            end
            local delta = TheContractorBreaks.getMoraleDelta(worker.breakResults)
            if delta < 0 then
                byDelta[delta] = byDelta[delta] or {}
                table.insert(byDelta[delta], worker)
                TCLog.info("TheContractor: farm %d worker %d (%s) missed breaks today: %d morale", farmId,
                    worker.id, worker.name, delta)
            end
        end
    end
    local morale = g_currentMission.TheContractor.Morale
    for delta, workers in pairs(byDelta) do
        morale:adjust(farmId, workers, delta)
    end
end

-- Server, every frame (from TheContractor:update).
function TheContractorBreaks:update(dt)
    if not g_currentMission:getIsServer() or g_currentMission.environment == nil then
        return
    end
    local now = TheContractorWorkingHours.getNow()
    if self.lastMinutes == nil or now < self.lastMinutes then
        self.lastMinutes = now
    elseif now == self.lastMinutes then
        return
    end

    local staff = g_currentMission.TheContractor.Staff
    -- The end of the working day since we last looked: judged before a new
    -- day's record replaces it.
    local endMinute = TheContractorWorkingHours.END_HOUR * 60
    local dayEnd = math.floor(now / MINUTES_PER_DAY) * MINUTES_PER_DAY + endMinute
    if dayEnd > now then
        dayEnd = dayEnd - MINUTES_PER_DAY
    end
    local judgeDay = nil
    if dayEnd > self.lastMinutes then
        judgeDay = math.floor(dayEnd / MINUTES_PER_DAY)
    end
    self.lastMinutes = now

    for farmId in pairs(staff.workersByFarm) do
        if judgeDay ~= nil then
            self:judgeDay(farmId, judgeDay)
        end
        for _, worker in ipairs(staff:getRoster(farmId)) do
            self:updateWorker(worker, now)
        end
    end
end

-- Every machine: the break the server started.
function TheContractorBreaks.applyBreak(worker, breakUntil)
    worker.breakUntil = breakUntil
    local tc = g_currentMission.TheContractor
    local menu = tc ~= nil and tc.MenuContractor or nil
    if menu ~= nil and menu.onOfficeChanged ~= nil then
        menu:onOfficeChanged()
    end
end

-- Every machine: of these idle workers, the one on a break who's back
-- soonest, or nil if none is (the driver picker's "all on a break").
function TheContractorBreaks.getFirstBack(workers, now)
    local first = nil
    for _, worker in ipairs(workers) do
        if TheContractorWorkingHours.getState(worker, now) == TheContractorWorkingHours.STATE.ON_BREAK and
            (first == nil or worker.breakUntil < first.breakUntil) then
            first = worker
        end
    end
    return first
end

-- Console --------------------------------------------------------------------------

-- ", breaks: morning taken, lunch -, afternoon -" (results are server-only, so
-- a client sees only the break they're on).
function TheContractorBreaks.describe(worker, now)
    local parts = {}
    if worker.breakResults ~= nil and worker.breakDay == math.floor(now / MINUTES_PER_DAY) then
        for _, definition in ipairs(TheContractorBreaks.BREAKS) do
            table.insert(parts, definition.key .. " " .. (worker.breakResults[definition.key] or "-"))
        end
    end
    local text = #parts > 0 and (", breaks: " .. table.concat(parts, ", ")) or ""
    if TheContractorWorkingHours.isOnBreak(worker, now) then
        text = text .. ", on break until " .. TheContractorWorkingHours.formatTime(worker.breakUntil)
    end
    return text
end

function TheContractorBreaks.registerConsoleCommands()
    TCConsole.register("worker", "break", {
        args = "<worker>",
        description = "Send a worker on their next break of the day now, whatever the time",
        run = function(farmId, args)
            local worker = TCConsole.findWorker(farmId, args[1])
            if worker == nil then
                return false
            end
            local breaks = g_currentMission.TheContractor.Breaks
            local now = TheContractorWorkingHours.getNow()
            breaks:updateWorker(worker, now)
            local definition = TheContractorBreaks.getNextBreak(worker)
            if definition == nil then
                return string.format("%s has no breaks left today", worker.name)
            end
            if not TheContractorWorkingHours.isAvailable(worker, now) then
                return string.format("%s isn't free for a break (busy, away, at home or on one)", worker.name)
            end
            breaks:startBreak(worker, definition, now)
            return string.format("%s is on their %s break until %s", worker.name, definition.key,
                TheContractorWorkingHours.formatTime(worker.breakUntil))
        end,
    })
end
