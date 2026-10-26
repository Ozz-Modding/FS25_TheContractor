-- Staff morale and bonuses (056). Every hired worker has a morale of 0-100,
-- starting at TheContractorWorker.MORALE_START when they're hired. The
-- Staff tab shows it as a band (happy / content / unsettled / unhappy).
--
-- How it moves:
-- - Bumps, straight away: a bonus lifts it (more for a bigger one), and a
--   declined training request (054), a colleague being let go, or no
--   harvest bonus knocks it down.
-- - Drift, each month: it moves DRIFT_SHARE of the way toward a target set
--   by last month's workload. Sat idle most of the month is TARGET_IDLE, a
--   steady month TARGET_STEADY, and out on work nearly every day
--   TARGET_OVERWORKED. So a bonus, or a knock, wears off over a few months.
--   058: pay moves the target too. Paid below what they expect lowers it,
--   paid above raises it a little (TheContractorPayReviews.
--   getMoraleTargetShift).
--
-- What it does:
-- - Below QUIT_MORALE a worker may quit at the month roll. They hand in a
--   month's notice and leave like a retiring worker (Staff:announceLeaving).
--   A bonus while they're working their notice doesn't change their mind.
-- - Below RETIREMENT_LOW_MORALE, 039's birthday retirement roll is more
--   likely, up to RETIREMENT_MAX_MULTIPLIER at 0.
-- - Below QUALITY_HIGH_MORALE, job quality (029, 080) drops a little, by
--   QUALITY_LOW_PENALTY at QUALITY_LOW_MORALE, and more below that, up to
--   QUALITY_MAX_PENALTY at 0. The lowest morale on the crew counts.
-- - From GROWTH_HIGH_MORALE, growth rolls (030) are GROWTH_MULTIPLIER as
--   likely.
--
-- Bonuses are pay, so they're charged under MoneyType.TC_WAGES and count
-- toward the Finances tab's wages. At the start of HARVEST_BONUS_PERIOD
-- (August) every farm with staff gets an inbox message (050) asking about a
-- harvest bonus for everyone. Any roster worker can also be given a one-off
-- bonus from the Staff tab (TCGiveBonusEvent).
--
-- Morale and hiredPeriod live on the workers and are saved and streamed
-- with them (Staff.lua), so this subsystem's own save/sync methods are
-- stubs.

TheContractorMorale = {}
TheContractorMorale_mt = Class(TheContractorMorale)

TheContractorMorale.MIN = 0
TheContractorMorale.MAX = 100

-- Bands, lowest morale in each: happy, content, unsettled; below that unhappy.
TheContractorMorale.HAPPY_MIN = 75
TheContractorMorale.CONTENT_MIN = 50
TheContractorMorale.UNSETTLED_MIN = 30

TheContractorMorale.BAND_TONES = {
    happy = "good",
    content = "info",
    unsettled = "warn",
    unhappy = "bad",
}

-- Monthly drift: this share of the gap to the target closes each month.
TheContractorMorale.DRIFT_SHARE = 1 / 3
-- Targets by the share of last month's counted days out on work (busy /
-- (busy + idle) - days off sick, on holiday or training don't count):
-- TARGET_IDLE at 0, rising to TARGET_STEADY at IDLE_RATIO, flat to
-- BUSY_RATIO, then falling to TARGET_OVERWORKED at 1. A month with no
-- counted days is steady.
TheContractorMorale.TARGET_IDLE = 55
TheContractorMorale.TARGET_STEADY = 70
TheContractorMorale.TARGET_OVERWORKED = 60
TheContractorMorale.IDLE_RATIO = 0.3
TheContractorMorale.BUSY_RATIO = 0.8

-- Bumps.
TheContractorMorale.DECLINED_REQUEST = -8
TheContractorMorale.COLLEAGUE_RELEASED = -5
TheContractorMorale.NO_HARVEST_BONUS = -5
-- 089: a holiday request approved, or refused - by the refusal's number
-- this year (the last entry for any after), worse when it was ignored.
TheContractorMorale.HOLIDAY_APPROVED = 3
TheContractorMorale.HOLIDAY_DECLINED = { -5, -8 }
TheContractorMorale.HOLIDAY_IGNORED = { -8, -12 }
-- A bonus of `amount` lifts morale by BONUS_MORALE_PER_STEP x (amount /
-- BONUS_STEP) ^ BONUS_EXPONENT, rounded: 250 = +8, 500 = +13, 750 = +17,
-- 1,000 = +21. Doubling the money doesn't double the effect.
TheContractorMorale.BONUS_STEP = 250
TheContractorMorale.BONUS_MORALE_PER_STEP = 8
TheContractorMorale.BONUS_EXPONENT = 0.7

-- One-off bonuses from the Staff tab, and the harvest bonus's two sizes
-- (each, per worker). These are the base amounts: they're what's picked,
-- sent and judged for morale. What's charged and shown is getBonusCost.
TheContractorMorale.BONUS_AMOUNTS = { 250, 500, 1000 }
TheContractorMorale.HARVEST_SMALL = 250
TheContractorMorale.HARVEST_GENEROUS = 750
-- August (period 1 is March).
TheContractorMorale.HARVEST_BONUS_PERIOD = 6

-- Quitting: 0 at QUIT_MORALE, rising to QUIT_MAX_CHANCE a month at 0.
TheContractorMorale.QUIT_MORALE = 30
TheContractorMorale.QUIT_MAX_CHANCE = 0.25
TheContractorMorale.QUIT_NOTICE_MONTHS = 1

-- Effects.
TheContractorMorale.RETIREMENT_LOW_MORALE = 50
TheContractorMorale.RETIREMENT_MAX_MULTIPLIER = 2
TheContractorMorale.QUALITY_HIGH_MORALE = 70
TheContractorMorale.QUALITY_LOW_MORALE = 30
TheContractorMorale.QUALITY_LOW_PENALTY = 0.04
TheContractorMorale.QUALITY_MAX_PENALTY = 0.1
TheContractorMorale.GROWTH_HIGH_MORALE = 80
TheContractorMorale.GROWTH_MULTIPLIER = 1.2

TheContractorMorale.MESSAGE_KIND = "staffBonus"
TheContractorMorale.ACTION = {
    SMALL = "small",
    GENEROUS = "generous",
    NONE = "none",
}

-- What TCWorkerMoraleChangedEvent tells the farm about.
TheContractorMorale.NOTIFY = {
    NONE = 0,
    BONUS = 1,
    HARVEST_BONUS = 2,
    NO_HARVEST_BONUS = 3,
}

function TheContractorMorale.new()
    local self = {}
    setmetatable(self, TheContractorMorale_mt)
    return self
end

-- Every machine, at load, once the Inbox exists.
function TheContractorMorale:register(inbox)
    inbox:registerMessageKind(TheContractorMorale.MESSAGE_KIND, {
        onAction = function(farmId, message, actionKey)
            self:onHarvestBonusAnswered(farmId, actionKey)
        end,
        -- Not answering is the same as saying no.
        onExpire = function(farmId, message)
            self:onHarvestBonusAnswered(farmId, TheContractorMorale.ACTION.NONE)
        end,
        chipKey = "tc_inbox_chipStaff",
        chipTone = "info",
    })
end

-- Query API (every machine) ---------------------------------------------------

function TheContractorMorale.clamp(morale)
    return math.max(TheContractorMorale.MIN, math.min(TheContractorMorale.MAX, morale))
end

function TheContractorMorale.getBand(morale)
    if morale >= TheContractorMorale.HAPPY_MIN then
        return "happy"
    elseif morale >= TheContractorMorale.CONTENT_MIN then
        return "content"
    elseif morale >= TheContractorMorale.UNSETTLED_MIN then
        return "unsettled"
    end
    return "unhappy"
end

-- The Staff tab's chip: its text and tone.
function TheContractorMorale.getChip(morale)
    local band = TheContractorMorale.getBand(morale)
    return g_i18n:getText("tc_morale_band_" .. band), TheContractorMorale.BAND_TONES[band]
end

function TheContractorMorale.getBonusMorale(amount)
    local steps = amount / TheContractorMorale.BONUS_STEP
    return math.floor(TheContractorMorale.BONUS_MORALE_PER_STEP * steps ^ TheContractorMorale.BONUS_EXPONENT + 0.5)
end

function TheContractorMorale.isBonusAmount(amount)
    for _, allowed in ipairs(TheContractorMorale.BONUS_AMOUNTS) do
        if allowed == amount then
            return true
        end
    end
    return false
end

-- What a base bonus amount costs, at FS25_EconomyScale's price level
-- (TCEconomyScale). Morale still follows the base amount, so a cheaper
-- economy doesn't make bonuses count for less.
function TheContractorMorale.getBonusCost(amount)
    return TCEconomyScale.scale(amount)
end

-- Whether the farm can pay a base bonus amount (getBonusCost).
function TheContractorMorale.canAfford(farmId, amount)
    local farm = g_farmManager:getFarmById(farmId)
    return farm ~= nil and farm:getBalance() >= TheContractorMorale.getBonusCost(amount)
end

-- Effects (server) --------------------------------------------------------------

-- 039's birthday roll is multiplied by this: 1 from RETIREMENT_LOW_MORALE
-- up, rising to RETIREMENT_MAX_MULTIPLIER at 0.
function TheContractorMorale.getRetirementMultiplier(worker)
    local low = TheContractorMorale.RETIREMENT_LOW_MORALE
    if worker.morale >= low then
        return 1
    end
    return 1 + (TheContractorMorale.RETIREMENT_MAX_MULTIPLIER - 1) * (low - worker.morale) / low
end

-- 030's growth chance is multiplied by this.
function TheContractorMorale.getGrowthMultiplier(worker)
    if worker.morale >= TheContractorMorale.GROWTH_HIGH_MORALE then
        return TheContractorMorale.GROWTH_MULTIPLIER
    end
    return 1
end

-- 029's quality score is multiplied by this (080), for the lowest morale on
-- the job's crew (operator, and hauler on a haulage job). 1 for a
-- player-driven job.
function TheContractorMorale.getJobQualityMultiplier(job)
    local staff = g_currentMission.TheContractor.Staff
    local lowest
    local function consider(workerId)
        local worker = workerId ~= nil and staff:getWorker(job.farmId, workerId) or nil
        if worker ~= nil and (lowest == nil or worker.morale < lowest) then
            lowest = worker.morale
        end
    end
    consider(job.assignedWorkerId)
    consider(job.haulerWorkerId)

    if lowest == nil then
        return 1
    end
    return TheContractorMorale.getQualityMultiplierFor(lowest)
end

-- 1 from QUALITY_HIGH_MORALE, down to 1 - QUALITY_LOW_PENALTY at
-- QUALITY_LOW_MORALE, then down to 1 - QUALITY_MAX_PENALTY at 0.
function TheContractorMorale.getQualityMultiplierFor(morale)
    local high, low = TheContractorMorale.QUALITY_HIGH_MORALE, TheContractorMorale.QUALITY_LOW_MORALE
    local lowPenalty, maxPenalty = TheContractorMorale.QUALITY_LOW_PENALTY, TheContractorMorale.QUALITY_MAX_PENALTY
    if morale >= high then
        return 1
    elseif morale >= low then
        return 1 - lowPenalty * (high - morale) / (high - low)
    end
    return 1 - lowPenalty - (maxPenalty - lowPenalty) * (low - math.max(0, morale)) / low
end

-- The month's drift target: the workload's (getWorkloadTarget), moved by
-- their pay against what they expect (058).
function TheContractorMorale.getTarget(worker)
    return TheContractorMorale.clamp(TheContractorMorale.getWorkloadTarget(worker) +
        TheContractorPayReviews.getMoraleTargetShift(worker))
end

-- From busyDays/idleDays (see the TARGET_* tunables).
function TheContractorMorale.getWorkloadTarget(worker)
    local counted = worker.busyDays + worker.idleDays
    local steady = TheContractorMorale.TARGET_STEADY
    if counted == 0 then
        return steady
    end

    local ratio = worker.busyDays / counted
    if ratio < TheContractorMorale.IDLE_RATIO then
        local idle = TheContractorMorale.TARGET_IDLE
        return idle + (steady - idle) * ratio / TheContractorMorale.IDLE_RATIO
    elseif ratio > TheContractorMorale.BUSY_RATIO then
        local overworked = TheContractorMorale.TARGET_OVERWORKED
        return steady + (overworked - steady) * (ratio - TheContractorMorale.BUSY_RATIO) /
            (1 - TheContractorMorale.BUSY_RATIO)
    end
    return steady
end

function TheContractorMorale.getQuitChance(morale)
    local quitMorale = TheContractorMorale.QUIT_MORALE
    if morale >= quitMorale then
        return 0
    end
    return TheContractorMorale.QUIT_MAX_CHANCE * (quitMorale - morale) / quitMorale
end

-- Changing morale (server-authoritative) --------------------------------------

-- Adds delta to each worker's morale and tells everyone in one broadcast.
-- notify and amount are only for the notification.
function TheContractorMorale:adjust(farmId, workers, delta, notify, amount)
    if not g_currentMission:getIsServer() or #workers == 0 then
        return
    end

    for _, worker in ipairs(workers) do
        local old = worker.morale
        worker.morale = TheContractorMorale.clamp(worker.morale + delta)
        TCLog.info("TheContractor: farm %d worker %d (%s) morale %.1f -> %.1f (%+d)", farmId, worker.id,
            worker.name, old, worker.morale, delta)
    end

    self:sendMoraleChanged(farmId, workers, notify, amount)
end

-- 054: a training request turned down or left to expire.
function TheContractorMorale:onRequestDeclined(worker)
    self:adjust(worker.farmId, { worker }, TheContractorMorale.DECLINED_REQUEST)
end

-- 089.
function TheContractorMorale:onHolidayApproved(worker)
    self:adjust(worker.farmId, { worker }, TheContractorMorale.HOLIDAY_APPROVED)
end

-- refusalCount: this one's number this year (1 for the first).
function TheContractorMorale.getHolidayRefusedDelta(refusalCount, isIgnored)
    local deltas = isIgnored and TheContractorMorale.HOLIDAY_IGNORED or TheContractorMorale.HOLIDAY_DECLINED
    return deltas[math.max(1, math.min(refusalCount, #deltas))]
end

function TheContractorMorale:onHolidayRefused(worker, refusalCount, isIgnored)
    self:adjust(worker.farmId, { worker }, TheContractorMorale.getHolidayRefusedDelta(refusalCount, isIgnored))
end

-- A colleague was let go (Staff:releaseWorker - not a retirement or a quit):
-- everyone left on the roster takes a knock.
function TheContractorMorale:onColleagueReleased(farmId)
    self:adjust(farmId, g_currentMission.TheContractor.Staff:getRoster(farmId),
        TheContractorMorale.COLLEAGUE_RELEASED)
end

-- Daily tick (server-only, from Staff:onDayChanged) ------------------------------

-- Counts today towards the month's workload. Runs after sickness, holidays
-- and training, so today's status is settled. Also gives a worker from a
-- save made before 056 their hire date: the day it's first seen.
function TheContractorMorale:onDayChanged()
    if not g_currentMission:getIsServer() then
        return
    end

    local STATUS = TheContractorWorker.STATUS
    local periodIndex = TCCalendar.getPeriodIndex()

    for farmId, farmWorkers in pairs(g_currentMission.TheContractor.Staff.workersByFarm) do
        local datedWorkers = {}
        for _, worker in pairs(farmWorkers) do
            local status = worker.status
            if status == STATUS.ASSIGNED or status == STATUS.COOLDOWN or status == STATUS.DRIVING then
                worker.busyDays = worker.busyDays + 1
            elseif status == STATUS.IDLE then
                worker.idleDays = worker.idleDays + 1
            end

            if worker.hiredPeriod == nil then
                worker.hiredPeriod = periodIndex
                table.insert(datedWorkers, worker)
            end
        end

        if #datedWorkers > 0 then
            self:sendMoraleChanged(farmId, datedWorkers)
        end
    end
end

-- Period tick (server-only, from Staff:onPeriodChanged) ---------------------------

-- Quit rolls on the morale the month ended with, then the drift toward last
-- month's target, then (in August) the harvest bonus prompt. Rolling before
-- the drift matters: the drift pulls a low morale back up by a third, so
-- after it almost nobody would still be under QUIT_MORALE.
function TheContractorMorale:onPeriodChanged()
    if not g_currentMission:getIsServer() then
        return
    end

    local staff = g_currentMission.TheContractor.Staff
    local quitters = {}

    for farmId, farmWorkers in pairs(staff.workersByFarm) do
        local workers = {}
        for _, worker in pairs(farmWorkers) do
            if not worker:isLeaving() and math.random() < TheContractorMorale.getQuitChance(worker.morale) then
                table.insert(quitters, worker)
            end

            local target = TheContractorMorale.getTarget(worker)
            local old = worker.morale
            worker.morale = TheContractorMorale.clamp(old + (target - old) * TheContractorMorale.DRIFT_SHARE)
            TCLog.info("TheContractor: farm %d worker %d (%s) morale %.1f -> %.1f (target %.1f, %d busy / %d idle days)",
                farmId, worker.id, worker.name, old, worker.morale, target, worker.busyDays, worker.idleDays)
            worker.busyDays = 0
            worker.idleDays = 0
            table.insert(workers, worker)
        end
        self:sendMoraleChanged(farmId, workers)
    end

    for _, worker in ipairs(quitters) do
        staff:announceLeaving(worker.farmId, worker.id, TheContractorMorale.QUIT_NOTICE_MONTHS, true)
    end

    if g_currentMission.environment.currentPeriod == TheContractorMorale.HARVEST_BONUS_PERIOD then
        for farmId in pairs(staff.workersByFarm) do
            self:postHarvestBonus(farmId)
        end
    end
end

-- Harvest bonus (server) ---------------------------------------------------------

-- Also the tcWorker harvestBonus console command's way in. Nothing for a
-- farm with no staff, or one already being asked.
function TheContractorMorale:postHarvestBonus(farmId)
    local count = #g_currentMission.TheContractor.Staff:getRoster(farmId)
    if count == 0 or self:findHarvestMessage(farmId) ~= nil then
        return false
    end

    local small = TheContractorMorale.getBonusCost(TheContractorMorale.HARVEST_SMALL)
    local generous = TheContractorMorale.getBonusCost(TheContractorMorale.HARVEST_GENEROUS)
    TCLog.info("TheContractor: farm %d asked about a harvest bonus (%d staff)", farmId, count)

    g_currentMission.TheContractor.Inbox:postMessage(farmId, TheContractorMorale.MESSAGE_KIND,
        "tc_morale_harvestTitle", "tc_morale_harvestBody",
        { "$money_" .. small, "$money_" .. generous, count, "$money_" .. small * count, "$money_" .. generous * count },
        {
            { key = TheContractorMorale.ACTION.SMALL, textKey = "tc_morale_harvestSmallButton" },
            { key = TheContractorMorale.ACTION.GENEROUS, textKey = "tc_morale_harvestGenerousButton" },
            { key = TheContractorMorale.ACTION.NONE, textKey = "tc_morale_harvestNoneButton" },
        },
        {}, g_currentMission.environment.daysPerPeriod)
    return true
end

function TheContractorMorale:findHarvestMessage(farmId)
    for _, message in ipairs(g_currentMission.TheContractor.Inbox:getMessages(farmId)) do
        if message.kind == TheContractorMorale.MESSAGE_KIND then
            return message
        end
    end
    return nil
end

-- Pays everyone on the roster now (whoever was hired since the message came
-- too), even into the red - the player chose it, and the message gave the
-- total. "None" or no answer knocks everyone's morale.
function TheContractorMorale:onHarvestBonusAnswered(farmId, actionKey)
    local workers = g_currentMission.TheContractor.Staff:getRoster(farmId)
    if #workers == 0 then
        return
    end

    local each = 0
    if actionKey == TheContractorMorale.ACTION.SMALL then
        each = TheContractorMorale.HARVEST_SMALL
    elseif actionKey == TheContractorMorale.ACTION.GENEROUS then
        each = TheContractorMorale.HARVEST_GENEROUS
    end

    if each == 0 then
        TCLog.info("TheContractor: farm %d gave no harvest bonus", farmId)
        self:adjust(farmId, workers, TheContractorMorale.NO_HARVEST_BONUS, TheContractorMorale.NOTIFY.NO_HARVEST_BONUS)
        return
    end

    local cost = TheContractorMorale.getBonusCost(each)
    local total = cost * #workers
    g_currentMission:addMoney(-total, farmId, MoneyType.TC_WAGES, true, true)
    g_currentMission.TheContractor.Finances:recordWages(farmId, total)
    TCLog.info("TheContractor: farm %d paid a harvest bonus of %.0f each (%.0f)", farmId, cost, total)

    self:adjust(farmId, workers, TheContractorMorale.getBonusMorale(each), TheContractorMorale.NOTIFY.HARVEST_BONUS,
        cost)
end

-- One-off bonus (server) ---------------------------------------------------------

-- TCGiveBonusEvent's server side. Re-checks the worker, the amount and the
-- balance; charges it and lifts their morale. Returns true if paid.
function TheContractorMorale:requestBonus(farmId, workerId, amount)
    if not g_currentMission:getIsServer() then
        return false
    end

    local worker = g_currentMission.TheContractor.Staff:getWorker(farmId, workerId)
    if worker == nil or not TheContractorMorale.isBonusAmount(amount) or
            not TheContractorMorale.canAfford(farmId, amount) then
        return false
    end

    local cost = TheContractorMorale.getBonusCost(amount)
    g_currentMission:addMoney(-cost, farmId, MoneyType.TC_WAGES, true, true)
    g_currentMission.TheContractor.Finances:recordWages(farmId, cost)
    TCLog.info("TheContractor: farm %d gave worker %d (%s) a bonus of %.0f", farmId, workerId, worker.name, cost)

    self:adjust(farmId, { worker }, TheContractorMorale.getBonusMorale(amount), TheContractorMorale.NOTIFY.BONUS,
        cost)
    return true
end

-- Sync --------------------------------------------------------------------------

-- Broadcasts the workers' morale and hire dates, after showing the host's
-- own notification (the broadcast doesn't loop back to it).
function TheContractorMorale:sendMoraleChanged(farmId, workers, notify, amount)
    notify = notify or TheContractorMorale.NOTIFY.NONE
    amount = amount or 0
    TCWorkerMoraleChangedEvent.showNotification(farmId, workers, notify, amount)

    if g_server ~= nil then
        g_server:broadcastEvent(TCWorkerMoraleChangedEvent.new(farmId, workers, notify, amount))
    end
end

-- The visible state, shared by the worker stream (Staff.writeWorker) and
-- TCWorkerMoraleChangedEvent. hiredPeriod 0 = none (period indexes start
-- at 1).
function TheContractorMorale.writeState(streamId, worker)
    streamWriteFloat32(streamId, worker.morale)
    streamWriteInt32(streamId, worker.hiredPeriod or 0)
end

function TheContractorMorale.readState(streamId)
    local morale = streamReadFloat32(streamId)
    local hiredPeriod = streamReadInt32(streamId)
    return morale, hiredPeriod > 0 and hiredPeriod or nil
end

-- Worker XML (Staff.writeWorkerXML/readWorkerXML). A candidate has no
-- hiredPeriod and nothing counted.
function TheContractorMorale.writeXML(xmlFile, key, worker)
    setXMLFloat(xmlFile, key .. "#morale", worker.morale)
    if worker.hiredPeriod ~= nil then
        setXMLInt(xmlFile, key .. "#hiredPeriod", worker.hiredPeriod)
    end
    if worker.busyDays > 0 then
        setXMLInt(xmlFile, key .. "#busyDays", worker.busyDays)
    end
    if worker.idleDays > 0 then
        setXMLInt(xmlFile, key .. "#idleDays", worker.idleDays)
    end
end

function TheContractorMorale.readXML(xmlFile, key, worker)
    worker.morale = TheContractorMorale.clamp(getXMLFloat(xmlFile, key .. "#morale") or
        TheContractorWorker.MORALE_START)
    worker.hiredPeriod = getXMLInt(xmlFile, key .. "#hiredPeriod")
    worker.busyDays = getXMLInt(xmlFile, key .. "#busyDays") or 0
    worker.idleDays = getXMLInt(xmlFile, key .. "#idleDays") or 0
end

-- Persistence (nothing of its own - see the header) ---------------------------------

function TheContractorMorale:loadFromXMLFile(xmlFile)
end

function TheContractorMorale:saveToXmlFile(xmlFile)
end

function TheContractorMorale:writeInitialClientState(streamId, connection)
end

function TheContractorMorale:readInitialClientState(streamId, connection)
end

-- Console commands (tcWorker - see TCConsole) ------------------------------------------

function TheContractorMorale.registerConsoleCommands()
    TCConsole.register("worker", "morale", {
        args = "<worker> [value]",
        description = "Show a worker's morale and this month's workload, or set their morale (0-100)",
        run = function(farmId, args)
            local worker, problem = TCConsole.findWorker(farmId, args[1])
            if worker == nil then
                return problem or false
            end

            if args[2] ~= nil then
                local value = tonumber(args[2])
                if value == nil or value < TheContractorMorale.MIN or value > TheContractorMorale.MAX then
                    return false
                end
                g_currentMission.TheContractor.Morale:adjust(farmId, { worker }, value - worker.morale)
            end

            return string.format("%s: morale %.1f (%s), %d busy / %d idle days this month (target %.1f, pay %+.1f), quit chance %.0f%%",
                worker.name, worker.morale, TheContractorMorale.getBand(worker.morale), worker.busyDays,
                worker.idleDays, TheContractorMorale.getTarget(worker),
                TheContractorPayReviews.getMoraleTargetShift(worker),
                TheContractorMorale.getQuitChance(worker.morale) * 100)
        end,
    })

    TCConsole.register("worker", "quit", {
        args = "<worker> [noticeMonths=1, 0=now]",
        description = "Make a worker quit, as if their morale had run out",
        run = function(farmId, args)
            local worker, problem = TCConsole.findWorker(farmId, args[1])
            if worker == nil then
                return problem or false
            end
            local noticeMonths = TCConsole.toCount(args[2], TheContractorMorale.QUIT_NOTICE_MONTHS)
            if noticeMonths == nil then
                return false
            end
            if worker:isLeaving() then
                return string.format("%s is already leaving (%s)", worker.name,
                    TCCalendar.formatPeriodIndex(worker.leavesAtPeriod))
            end

            g_currentMission.TheContractor.Staff:announceLeaving(farmId, worker.id, noticeMonths, true)
            return string.format("%s handed in their notice (%d month(s))", worker.name, noticeMonths)
        end,
    })

    TCConsole.register("worker", "harvestBonus", {
        description = "Post the harvest bonus question to your inbox now",
        run = function(farmId, args)
            if g_currentMission.TheContractor.Morale:postHarvestBonus(farmId) then
                return "Harvest bonus question posted to your inbox"
            end
            return "Nothing posted: you have no staff, or the question is already in your inbox"
        end,
    })
end
