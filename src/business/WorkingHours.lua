-- Working hours (097). Field staff work START_HOUR to END_HOUR (game time).
-- Outside those hours an idle worker is at home: they aren't offered for a
-- job or as a staff driver (037), aren't on a standing spot (065), and the
-- ADS workshop (091) sees them as unavailable. The office staff (090) are
-- at home then too. FS25_AdvancedDamageSystem's own workshop runs round
-- the clock with our staff, so these are its hours as well.
--
-- Anyone still working when the day ends carries on: a crew out on a job
-- (travelling or working, not on hold for supplies), in its cooldown (023),
-- or driving for the player (037) is paid overtime for every minute outside
-- working hours until they're done.
--
-- The player can also keep someone on (Manage worker):
--   Stay late   while they're at work (or still working after hours): on
--               duty until a time the player picks, up to 08:00.
--   Call back   once they've gone home: in CALL_BACK_MINUTES after the call,
--               then on duty until the time picked.
--   Send home   ends either straight away.
-- A worker on duty counts as at work, and is paid overtime for every
-- minute of it outside working hours, used or not (from the request, so a
-- call back is paid from the call). One who's still on a job when it ends
-- finishes the job.
--
-- Overtime is OVERTIME_RATE times their hourly pay: this month's pay
-- (TheContractorStaff.scalePay) over the month's working hours (days per
-- period x HOURS_PER_DAY), so it costs the same share of pay whatever days
-- per period is set to. It builds up on the worker (overtimeMinutes,
-- overtimeOwed) and is paid with the month's salaries (Staff:paySalaries),
-- or when they leave.
--
-- State, all on the worker, saved and streamed with them: dutyFrom (pay
-- from), dutyArrive (on site from) and dutyUntil, in absolute game minutes
-- (getNow), nil when they've nothing booked; overtimeMinutes and
-- overtimeOwed for the month so far. Duty changes go through
-- TCWorkerDutyEvent. The server sends the overtime figures to clients
-- every game hour (TCWorkerOvertimeEvent). Whether someone's at home is
-- worked out from the time on every machine, so nothing is sent for that.
--
-- 131: a worker on a break (Breaks.lua) is ON_BREAK until breakUntil: not
-- on site, so not available for anything. breakUntil is streamed and saved
-- with the worker here; the day's record of breaks (server-only) is saved
-- here too.

TheContractorWorkingHours = {}
TheContractorWorkingHours_mt = Class(TheContractorWorkingHours)

TheContractorWorkingHours.START_HOUR = 8
TheContractorWorkingHours.END_HOUR = 18
TheContractorWorkingHours.HOURS_PER_DAY = TheContractorWorkingHours.END_HOUR - TheContractorWorkingHours.START_HOUR
TheContractorWorkingHours.OVERTIME_RATE = 1.5
-- In-game minutes from a call back to the worker being there.
TheContractorWorkingHours.CALL_BACK_MINUTES = 25

-- The times offered for Stay late / Call back: the first MAX_OPTIONS of
-- these hours at least MIN_DUTY_MINUTES after the end of the day (or the
-- worker turning up), and never past the next START_HOUR.
TheContractorWorkingHours.UNTIL_HOURS = { 20, 22, 0, 2, 4, 6, 8 }
TheContractorWorkingHours.MAX_OPTIONS = 3
TheContractorWorkingHours.MIN_DUTY_MINUTES = 60

local MINUTES_PER_DAY = 24 * 60

TheContractorWorkingHours.STATE = {
    AT_WORK = "atWork",
    AT_HOME = "atHome",
    COMING_IN = "comingIn",
    STAYING = "staying",
    -- 131.
    ON_BREAK = "onBreak",
}

TheContractorWorkingHours.ACTION = {
    STAY = "stay",
    CALL = "call",
    HOME = "home",
}

-- Why a duty request is refused (getDutyProblem).
TheContractorWorkingHours.PROBLEM = {
    NO_WORKER = "noWorker",
    AWAY = "away",
    NOT_AT_HOME = "notAtHome",
    AT_HOME = "atHome",
    NO_DUTY = "noDuty",
    BAD_TIME = "badTime",
    UNKNOWN_ACTION = "unknownAction",
}

function TheContractorWorkingHours.new()
    local self = {}
    setmetatable(self, TheContractorWorkingHours_mt)

    -- Server: the last game minute overtime was counted up to, and the
    -- hour the figures were last sent. Live only: counting starts afresh
    -- from the time a save loads.
    self.lastMinutes = nil
    self.lastSyncHour = nil
    -- workerId -> overtimeMinutes clients last heard.
    self.syncedMinutes = {}

    return self
end

-- Time (every machine) ------------------------------------------------------------

-- Absolute game minutes, whole.
function TheContractorWorkingHours.getNow()
    local environment = g_currentMission.environment
    return math.floor(environment.currentMonotonicDay * MINUTES_PER_DAY + (environment.dayTime or 0) / 60000)
end

local function getMinuteOfDay(minutes)
    return minutes % MINUTES_PER_DAY
end

local function getDayStart(minutes)
    return minutes - getMinuteOfDay(minutes)
end

function TheContractorWorkingHours.isWorkingTime(minutes)
    local minute = getMinuteOfDay(minutes)
    return minute >= TheContractorWorkingHours.START_HOUR * 60 and minute < TheContractorWorkingHours.END_HOUR * 60
end

-- Minutes of [fromMinutes, toMinutes) that fall outside working hours.
function TheContractorWorkingHours.getOutOfHoursMinutes(fromMinutes, toMinutes)
    if toMinutes <= fromMinutes then
        return 0
    end
    local startMinute = TheContractorWorkingHours.START_HOUR * 60
    local endMinute = TheContractorWorkingHours.END_HOUR * 60
    local total = toMinutes - fromMinutes
    local inHours = 0
    local day = getDayStart(fromMinutes)
    while day < toMinutes do
        local overlap = math.min(toMinutes, day + endMinute) - math.max(fromMinutes, day + startMinute)
        if overlap > 0 then
            inHours = inHours + overlap
        end
        day = day + MINUTES_PER_DAY
    end
    return total - inHours
end

-- The first time at or after `minutes` that the clock reads `hour`:00.
local function getNextAt(minutes, hour)
    local at = getDayStart(minutes) + hour * 60
    if at < minutes then
        at = at + MINUTES_PER_DAY
    end
    return at
end

-- The next start of the working day after `minutes` (tomorrow's, during
-- working hours).
function TheContractorWorkingHours.getNextMorning(minutes)
    return getNextAt(minutes + 1, TheContractorWorkingHours.START_HOUR)
end

-- "22:00".
function TheContractorWorkingHours.formatTime(minutes)
    local minute = getMinuteOfDay(math.floor(minutes))
    return string.format("%02d:%02d", math.floor(minute / 60), minute % 60)
end

-- A worker's day (every machine) --------------------------------------------------

function TheContractorWorkingHours.hasDuty(worker, now)
    return worker.dutyUntil ~= nil and now < worker.dutyUntil
end

-- 131: on a break (Breaks.lua) until breakUntil.
function TheContractorWorkingHours.isOnBreak(worker, now)
    return worker.breakUntil ~= nil and now < worker.breakUntil
end

-- Where they are as far as the hours go. Only means anything while they're
-- idle: a worker on a job is on it, whatever the time.
function TheContractorWorkingHours.getState(worker, now)
    local STATE = TheContractorWorkingHours.STATE
    local hasDuty = TheContractorWorkingHours.hasDuty(worker, now)
    if hasDuty and worker.dutyArrive ~= nil and now < worker.dutyArrive then
        return STATE.COMING_IN
    end
    if TheContractorWorkingHours.isWorkingTime(now) then
        if TheContractorWorkingHours.isOnBreak(worker, now) then
            return STATE.ON_BREAK
        end
        return STATE.AT_WORK
    end
    if hasDuty then
        return STATE.STAYING
    end
    return STATE.AT_HOME
end

-- There to be given something to do (or to stand about) now.
function TheContractorWorkingHours.isOnSite(worker, now)
    local state = TheContractorWorkingHours.getState(worker, now or TheContractorWorkingHours.getNow())
    return state == TheContractorWorkingHours.STATE.AT_WORK or state == TheContractorWorkingHours.STATE.STAYING
end

-- Idle and there: what allocation (018) and the staff driver picker (037)
-- take.
function TheContractorWorkingHours.isAvailable(worker, now)
    return worker:isIdle() and TheContractorWorkingHours.isOnSite(worker, now)
end

-- The status the Staff tab shows: an idle worker's place in the day, else
-- their status.
function TheContractorWorkingHours.getDisplayStatus(worker, now)
    if not worker:isIdle() then
        return worker.status
    end
    local STATE = TheContractorWorkingHours.STATE
    local state = TheContractorWorkingHours.getState(worker, now or TheContractorWorkingHours.getNow())
    -- Still idle to us (allocation takes them as ever), but busy in ADS's
    -- workshop.
    if (state == STATE.AT_WORK or state == STATE.STAYING) and TCADSWorkshop.isWorking(worker) then
        return "inWorkshop"
    end
    if state == STATE.AT_HOME then
        return "atHome"
    elseif state == STATE.COMING_IN then
        return "comingIn"
    elseif state == STATE.STAYING then
        return "stayingLate"
    elseif state == STATE.ON_BREAK then
        return "onBreak"
    end
    return worker.status
end

-- 178: what the Staff tab says about an idle worker's booked hours: the
-- l10n key and its times, or nil. Called back and not in yet: when they'll
-- be in and until when. Kept on (staying late, or asked to before the day
-- ends): until when.
function TheContractorWorkingHours.getDutyNote(worker, now)
    now = now or TheContractorWorkingHours.getNow()
    if not worker:isIdle() or not TheContractorWorkingHours.hasDuty(worker, now) then
        return nil
    end
    if worker.dutyArrive ~= nil and now < worker.dutyArrive then
        return "tc_staff_detailComingIn", { worker.dutyArrive, worker.dutyUntil }
    end
    return "tc_staff_detailOnUntil", { worker.dutyUntil }
end

-- Office staff (090): in the office during working hours, else at home.
function TheContractorWorkingHours.isOfficeOpen(now)
    return TheContractorWorkingHours.isWorkingTime(now or TheContractorWorkingHours.getNow())
end

-- Overtime pay for an hour, at this month's pay and days per period.
function TheContractorWorkingHours.getHourlyRate(worker)
    local daysPerPeriod = math.max(1, g_currentMission.environment.daysPerPeriod or 1)
    return TheContractorStaff.scalePay(worker.salary) / (daysPerPeriod * TheContractorWorkingHours.HOURS_PER_DAY) *
        TheContractorWorkingHours.OVERTIME_RATE
end

-- Overtime for staying on from now until `untilMinutes`.
function TheContractorWorkingHours.getDutyCost(worker, now, untilMinutes)
    return TheContractorWorkingHours.getOutOfHoursMinutes(now, untilMinutes) / 60 *
        TheContractorWorkingHours.getHourlyRate(worker)
end

-- Sick, on holiday or training (170: or at the show).
function TheContractorWorkingHours.isAway(worker)
    local STATUS = TheContractorWorker.STATUS
    return worker.status == STATUS.SICK or worker.status == STATUS.HOLIDAY or worker.status == STATUS.TRAINING or
        worker.status == STATUS.SHOW
end
local isAway = TheContractorWorkingHours.isAway

-- Which way they'd be kept on: Call back if they've gone home, else Stay
-- late. nil while they're away (sick, on holiday or training).
function TheContractorWorkingHours.getDutyAction(worker, now)
    if isAway(worker) then
        return nil
    end
    if worker:isIdle() and TheContractorWorkingHours.getState(worker, now) == TheContractorWorkingHours.STATE.AT_HOME then
        return TheContractorWorkingHours.ACTION.CALL
    end
    return TheContractorWorkingHours.ACTION.STAY
end

-- The earliest a duty can run to, and the latest (the next morning).
local function getDutyBounds(worker, action, now)
    local base = now
    if TheContractorWorkingHours.isWorkingTime(now) then
        base = getDayStart(now) + TheContractorWorkingHours.END_HOUR * 60
    elseif action == TheContractorWorkingHours.ACTION.CALL then
        base = now + TheContractorWorkingHours.CALL_BACK_MINUTES
    end
    return base, TheContractorWorkingHours.getNextMorning(now)
end

-- The times offered for the worker's duty action, earliest first (absolute
-- minutes). Empty when there's nothing worth offering (it's nearly
-- morning).
function TheContractorWorkingHours.getUntilOptions(worker, now)
    local action = TheContractorWorkingHours.getDutyAction(worker, now)
    if action == nil then
        return {}
    end
    local base, latest = getDutyBounds(worker, action, now)
    local earliest = base + TheContractorWorkingHours.MIN_DUTY_MINUTES
    local times = {}
    for _, hour in ipairs(TheContractorWorkingHours.UNTIL_HOURS) do
        local at = getNextAt(earliest, hour)
        if at <= latest then
            table.insert(times, at)
        end
    end
    table.sort(times)
    local options = {}
    for _, at in ipairs(times) do
        if #options < TheContractorWorkingHours.MAX_OPTIONS and options[#options] ~= at then
            table.insert(options, at)
        end
    end
    return options
end

-- Why `action` can't be done for `worker` (untilMinutes for stay/call), or
-- nil. Same on every machine.
function TheContractorWorkingHours.getDutyProblem(worker, action, untilMinutes, now)
    local ACTION, PROBLEM = TheContractorWorkingHours.ACTION, TheContractorWorkingHours.PROBLEM
    if worker == nil then
        return PROBLEM.NO_WORKER
    end
    if action == ACTION.HOME then
        if not TheContractorWorkingHours.hasDuty(worker, now) then
            return PROBLEM.NO_DUTY
        end
        return nil
    end
    if action ~= ACTION.STAY and action ~= ACTION.CALL then
        return PROBLEM.UNKNOWN_ACTION
    end
    local expected = TheContractorWorkingHours.getDutyAction(worker, now)
    if expected == nil then
        return PROBLEM.AWAY
    end
    if action ~= expected then
        return action == ACTION.CALL and PROBLEM.NOT_AT_HOME or PROBLEM.AT_HOME
    end
    local base, latest = getDutyBounds(worker, action, now)
    if untilMinutes == nil or untilMinutes <= base or untilMinutes > latest then
        return PROBLEM.BAD_TIME
    end
    return nil
end

-- Every machine: a worker's duty as the server set it (nil = none).
function TheContractorWorkingHours.applyDuty(worker, dutyFrom, dutyArrive, dutyUntil)
    worker.dutyFrom = dutyFrom
    worker.dutyArrive = dutyArrive
    worker.dutyUntil = dutyUntil

    local tc = g_currentMission.TheContractor
    local menu = tc ~= nil and tc.MenuContractor or nil
    if menu ~= nil and menu.onOfficeChanged ~= nil then
        menu:onOfficeChanged()
    end
end

function TheContractorWorkingHours.applyOvertime(worker, overtimeMinutes, overtimeOwed)
    worker.overtimeMinutes = overtimeMinutes
    worker.overtimeOwed = overtimeOwed
end

-- Duty requests (server) -----------------------------------------------------------

-- From TCWorkerDutyEvent (and the console). Returns nil, or the problem.
function TheContractorWorkingHours:requestDuty(farmId, workerId, action, untilMinutes)
    if not g_currentMission:getIsServer() then
        return nil
    end
    local worker = g_currentMission.TheContractor.Staff:getWorker(farmId, workerId)
    local now = TheContractorWorkingHours.getNow()
    local problem = TheContractorWorkingHours.getDutyProblem(worker, action, untilMinutes, now)
    if problem ~= nil then
        TCLog.info("TheContractor: farm %d worker %d duty %s refused: %s", farmId, workerId, tostring(action), problem)
        return problem
    end

    -- Counted up to now first, so a duty ended now isn't paid on.
    self:update(0)

    local dutyFrom, dutyArrive, dutyUntil = nil, nil, nil
    if action ~= TheContractorWorkingHours.ACTION.HOME then
        dutyFrom = now
        dutyArrive = action == TheContractorWorkingHours.ACTION.CALL and
            now + TheContractorWorkingHours.CALL_BACK_MINUTES or now
        dutyUntil = untilMinutes
    end
    TheContractorWorkingHours.applyDuty(worker, dutyFrom, dutyArrive, dutyUntil)
    if g_server ~= nil then
        g_server:broadcastEvent(TCWorkerDutyEvent.new(farmId, workerId, action, dutyFrom, dutyArrive, dutyUntil))
    end
    TCLog.info("TheContractor: farm %d worker %d (%s) %s%s", farmId, workerId, worker.name, action,
        dutyUntil ~= nil and " until " .. TheContractorWorkingHours.formatTime(dutyUntil) or "")

    if TCADSWorkshop ~= nil and TCADSWorkshop.refresh ~= nil then
        TCADSWorkshop.refresh(farmId)
    end
    return nil
end

-- Overtime (server) ----------------------------------------------------------------

-- Out on a job (travelling or working), in its cooldown, or driving for the
-- player: still at it, whatever the time.
function TheContractorWorkingHours.isWorking(worker)
    local STATUS = TheContractorWorker.STATUS
    if worker.status == STATUS.COOLDOWN or worker.status == STATUS.DRIVING then
        return true
    end
    if worker.status ~= STATUS.ASSIGNED then
        return false
    end
    local tc = g_currentMission.TheContractor
    for _, job in ipairs(tc.Jobs:getAllJobs(worker.farmId)) do
        if (job.assignedWorkerId == worker.id or job.haulerWorkerId == worker.id) and
                (job.state == TheContractorJob.STATE.ALLOCATED or job.state == TheContractorJob.STATE.IN_PROGRESS) then
            return tc.Dispatch:isJobActive(job)
        end
    end
    return false
end

-- Overtime minutes `worker` earned in [fromMinutes, toMinutes).
function TheContractorWorkingHours.getEarnedMinutes(worker, fromMinutes, toMinutes)
    if TheContractorWorkingHours.isWorking(worker) then
        return TheContractorWorkingHours.getOutOfHoursMinutes(fromMinutes, toMinutes)
    end
    if worker.dutyUntil == nil or worker.dutyFrom == nil then
        return 0
    end
    return TheContractorWorkingHours.getOutOfHoursMinutes(math.max(fromMinutes, worker.dutyFrom),
        math.min(toMinutes, worker.dutyUntil))
end

-- Server, every frame (from TheContractor:update): counts overtime up to
-- now, and sends the figures on the hour.
function TheContractorWorkingHours:update(dt)
    if not g_currentMission:getIsServer() or g_currentMission.environment == nil then
        return
    end
    local now = TheContractorWorkingHours.getNow()
    if self.lastMinutes == nil or now < self.lastMinutes then
        self.lastMinutes = now
    end
    if now > self.lastMinutes then
        self:countOvertime(self.lastMinutes, now)
        self.lastMinutes = now
    end

    local hour = math.floor(now / 60)
    if self.lastSyncHour ~= hour then
        self.lastSyncHour = hour
        self:syncOvertime()
    end
end

function TheContractorWorkingHours:countOvertime(fromMinutes, toMinutes)
    if TheContractorWorkingHours.getOutOfHoursMinutes(fromMinutes, toMinutes) == 0 then
        return
    end
    local staff = g_currentMission.TheContractor.Staff
    for farmId in pairs(staff.workersByFarm) do
        for _, worker in ipairs(staff:getRoster(farmId)) do
            local minutes = TheContractorWorkingHours.getEarnedMinutes(worker, fromMinutes, toMinutes)
            if minutes > 0 then
                worker.overtimeMinutes = (worker.overtimeMinutes or 0) + minutes
                worker.overtimeOwed = (worker.overtimeOwed or 0) +
                    minutes / 60 * TheContractorWorkingHours.getHourlyRate(worker)
            end
        end
    end
end

-- Sends clients the overtime figures that have changed since they last
-- heard.
function TheContractorWorkingHours:syncOvertime(onlyFarmId)
    local staff = g_currentMission.TheContractor.Staff
    for farmId in pairs(staff.workersByFarm) do
        if onlyFarmId == nil or farmId == onlyFarmId then
            local entries = {}
            for _, worker in ipairs(staff:getRoster(farmId)) do
                local minutes = worker.overtimeMinutes or 0
                if (self.syncedMinutes[worker.id] or 0) ~= minutes then
                    self.syncedMinutes[worker.id] = minutes
                    table.insert(entries, { workerId = worker.id, minutes = minutes, owed = worker.overtimeOwed or 0 })
                end
            end
            if #entries > 0 and g_server ~= nil then
                g_server:broadcastEvent(TCWorkerOvertimeEvent.new(farmId, entries))
            end
        end
    end
end

-- The farm's overtime owed so far this month.
function TheContractorWorkingHours.getOwed(farmId)
    local total = 0
    for _, worker in ipairs(g_currentMission.TheContractor.Staff:getRoster(farmId)) do
        total = total + (worker.overtimeOwed or 0)
    end
    return total
end

-- From Staff:paySalaries: the farm's overtime, in whole money, cleared for
-- the new month.
function TheContractorWorkingHours:takeOvertime(farmId)
    self:update(0)
    local total = 0
    for _, worker in ipairs(g_currentMission.TheContractor.Staff:getRoster(farmId)) do
        total = total + (worker.overtimeOwed or 0)
        worker.overtimeOwed = 0
        worker.overtimeMinutes = 0
    end
    self:syncOvertime(farmId)
    return math.floor(total + 0.5)
end

-- From Staff:releaseWorker/retireWorker, before they go: their overtime so
-- far, paid now.
function TheContractorWorkingHours:payLeaver(farmId, worker)
    self:update(0)
    local owed = math.floor((worker.overtimeOwed or 0) + 0.5)
    worker.overtimeOwed = 0
    worker.overtimeMinutes = 0
    self.syncedMinutes[worker.id] = nil
    if owed > 0 then
        g_currentMission:addMoney(-owed, farmId, MoneyType.TC_WAGES, true, true)
        g_currentMission.TheContractor.Finances:recordWages(farmId, owed)
        TCLog.info("TheContractor: farm %d paid worker %d (%s) %d in overtime as they left", farmId, worker.id,
            worker.name, owed)
    end
end

-- Saving and streaming (with the worker) -------------------------------------------

function TheContractorWorkingHours.writeState(streamId, worker)
    streamWriteBool(streamId, worker.dutyUntil ~= nil)
    if worker.dutyUntil ~= nil then
        streamWriteInt32(streamId, worker.dutyFrom or worker.dutyUntil)
        streamWriteInt32(streamId, worker.dutyArrive or worker.dutyUntil)
        streamWriteInt32(streamId, worker.dutyUntil)
    end
    streamWriteInt32(streamId, worker.overtimeMinutes or 0)
    streamWriteFloat32(streamId, worker.overtimeOwed or 0)
    -- 131.
    streamWriteBool(streamId, worker.breakUntil ~= nil)
    if worker.breakUntil ~= nil then
        streamWriteInt32(streamId, worker.breakUntil)
    end
end

-- Returns dutyFrom, dutyArrive, dutyUntil, overtimeMinutes, overtimeOwed,
-- breakUntil.
function TheContractorWorkingHours.readState(streamId)
    local dutyFrom, dutyArrive, dutyUntil
    if streamReadBool(streamId) then
        dutyFrom = streamReadInt32(streamId)
        dutyArrive = streamReadInt32(streamId)
        dutyUntil = streamReadInt32(streamId)
    end
    local overtimeMinutes = streamReadInt32(streamId)
    local overtimeOwed = streamReadFloat32(streamId)
    local breakUntil
    if streamReadBool(streamId) then
        breakUntil = streamReadInt32(streamId)
    end
    return dutyFrom, dutyArrive, dutyUntil, overtimeMinutes, overtimeOwed, breakUntil
end

function TheContractorWorkingHours.writeXML(xmlFile, key, worker)
    if worker.dutyUntil ~= nil then
        setXMLInt(xmlFile, key .. "#dutyFrom", worker.dutyFrom or worker.dutyUntil)
        setXMLInt(xmlFile, key .. "#dutyArrive", worker.dutyArrive or worker.dutyUntil)
        setXMLInt(xmlFile, key .. "#dutyUntil", worker.dutyUntil)
    end
    if (worker.overtimeMinutes or 0) > 0 then
        setXMLInt(xmlFile, key .. "#overtimeMinutes", worker.overtimeMinutes)
        setXMLFloat(xmlFile, key .. "#overtimeOwed", worker.overtimeOwed or 0)
    end
    -- 131: the break they're on, and the day's record (Breaks.lua).
    if worker.breakUntil ~= nil then
        setXMLInt(xmlFile, key .. "#breakUntil", worker.breakUntil)
    end
    if worker.breakDay ~= nil then
        setXMLInt(xmlFile, key .. ".breaks#day", worker.breakDay)
        if worker.breakJudgedDay ~= nil then
            setXMLInt(xmlFile, key .. ".breaks#judgedDay", worker.breakJudgedDay)
        end
        for breakKey, result in pairs(worker.breakResults or {}) do
            setXMLString(xmlFile, key .. ".breaks#" .. breakKey, result)
        end
    end
end

function TheContractorWorkingHours.readXML(xmlFile, key, worker)
    worker.dutyUntil = getXMLInt(xmlFile, key .. "#dutyUntil")
    if worker.dutyUntil ~= nil then
        worker.dutyFrom = getXMLInt(xmlFile, key .. "#dutyFrom") or worker.dutyUntil
        worker.dutyArrive = getXMLInt(xmlFile, key .. "#dutyArrive") or worker.dutyFrom
    end
    worker.overtimeMinutes = getXMLInt(xmlFile, key .. "#overtimeMinutes") or 0
    worker.overtimeOwed = getXMLFloat(xmlFile, key .. "#overtimeOwed") or 0
    -- 131.
    worker.breakUntil = getXMLInt(xmlFile, key .. "#breakUntil")
    worker.breakDay = getXMLInt(xmlFile, key .. ".breaks#day")
    worker.breakJudgedDay = getXMLInt(xmlFile, key .. ".breaks#judgedDay")
    worker.breakResults = {}
    if worker.breakDay ~= nil and TheContractorBreaks ~= nil then
        for _, definition in ipairs(TheContractorBreaks.BREAKS) do
            worker.breakResults[definition.key] = getXMLString(xmlFile, key .. ".breaks#" .. definition.key)
        end
    end
end

-- Console ---------------------------------------------------------------------------

function TheContractorWorkingHours.describeWorker(worker, now)
    local state = TheContractorWorkingHours.getDisplayStatus(worker, now)
    local duty = ""
    if TheContractorWorkingHours.hasDuty(worker, now) then
        duty = string.format(", on duty until %s", TheContractorWorkingHours.formatTime(worker.dutyUntil))
        if worker.dutyArrive ~= nil and now < worker.dutyArrive then
            duty = duty .. string.format(" (in at %s)", TheContractorWorkingHours.formatTime(worker.dutyArrive))
        end
    end
    local breaks = ""
    if TheContractorBreaks ~= nil then
        breaks = TheContractorBreaks.describe(worker, now)
    end
    return string.format("#%d %s - %s%s, overtime %d min this month (%.0f owed), %.2f an hour%s", worker.id, worker.name,
        state, duty, worker.overtimeMinutes or 0, worker.overtimeOwed or 0, TheContractorWorkingHours.getHourlyRate(worker),
        breaks)
end

function TheContractorWorkingHours.registerConsoleCommands()
    TCConsole.register("worker", "hours", {
        description = "Working hours: who's at work, at home or on duty, and each worker's overtime this month",
        serverOnly = false,
        run = function(farmId)
            local now = TheContractorWorkingHours.getNow()
            local lines = { string.format("Farm %d, %s: working hours %02d:00-%02d:00, %s", farmId,
                TheContractorWorkingHours.formatTime(now), TheContractorWorkingHours.START_HOUR,
                TheContractorWorkingHours.END_HOUR,
                TheContractorWorkingHours.isWorkingTime(now) and "at work" or "outside them") }
            local roster = g_currentMission.TheContractor.Staff:getRoster(farmId)
            table.sort(roster, function(a, b) return a.id < b.id end)
            for _, worker in ipairs(roster) do
                table.insert(lines, TheContractorWorkingHours.describeWorker(worker, now))
            end
            return table.concat(lines, "\n")
        end,
    })

    TCConsole.register("worker", "duty", {
        args = "<worker> <hour|home>",
        description = "Keep a worker on until an hour (stay late, or call back if they've gone home), or send them home",
        run = function(farmId, args)
            local worker = TCConsole.findWorker(farmId, args[1])
            if worker == nil or args[2] == nil then
                return false
            end
            local hours = g_currentMission.TheContractor.WorkingHours
            local now = TheContractorWorkingHours.getNow()
            local action, untilMinutes
            if string.lower(args[2]) == "home" then
                action = TheContractorWorkingHours.ACTION.HOME
            else
                local hour = tonumber(args[2])
                if hour == nil or hour < 0 or hour > 24 or hour ~= math.floor(hour) then
                    return false
                end
                action = TheContractorWorkingHours.getDutyAction(worker, now)
                if action ~= nil then
                    local base = getDutyBounds(worker, action, now)
                    untilMinutes = getNextAt(base + 1, hour % 24)
                end
            end
            local problem = action == nil and TheContractorWorkingHours.PROBLEM.AWAY or
                hours:requestDuty(farmId, worker.id, action, untilMinutes)
            if problem ~= nil then
                return string.format("%s can't: %s", worker.name, problem)
            end
            return TheContractorWorkingHours.describeWorker(worker, now)
        end,
    })
end
