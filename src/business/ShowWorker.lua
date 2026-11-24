-- A worker entered in the ploughing match (170). A company can enter one of
-- its workers to plough the farm's one plot (169) for it. The pure half is
-- TCShowWorker.
--
-- Entering: in the Show tab while the show's entries are open (165), one
--   worker a farm (TCShowWorker.getEntryProblem: free on the day, enough
--   tillage, the kit's tractor size). Withdrawn by the player while entries
--   are open. Sent as TCShowEntryEvent; every machine gets the entries
--   (TCShowWorkerEvent).
-- Booked for the day: on the show's day the worker's at the show
--   (TheContractorWorker.STATUS.SHOW), so they're not offered for anything,
--   as on a holiday (040). One out on a job goes as soon as they're back
--   (Staff:setWorkerStatus, isDueToday). Back to idle at midnight after.
-- Withdrawn on its own (withdrawEntry), with an inbox message: the worker
--   falls sick (or is hurt) and won't be back by the day, is away on it
--   (holiday or training), leaves (onWorkerGone, from the roster's leave
--   path), or isn't there by the end of the match. checkEntries runs every
--   day and hour while the show's on. On the day, the worker's plot goes to
--   a farmer (PloughingMatch:onWorkerWithdrawn).
-- The run: PloughingMatch reserves the entered farm's plot for the worker at
--   the set-out, and once they're at the show and the match is on, rolls
--   their score here (rollRun: tillage, tractor experience, morale, form;
--   never the ground) and paints the plot in runs as the farmers' are. The
--   farm gets the prize and reputation as if its player had ploughed.
-- Afterwards (onResults): a placing lifts the worker's morale (Morale:
--   adjust), a win most. A poor run costs nothing.
--
-- Every machine: the show the entries are for and the entries ({ farmId,
-- workerId, name }), kept until the next show's announced so the Show tab
-- can show them. The score is server-only until the results (it's the
-- match's run). Saved in TheContractor.xml (.showWorker), in the initial
-- client state; entries hold farms (forgetFarm) and workers (onWorkerGone).
-- Nothing's a date. Tested in tests/test_showWorker.lua.

TheContractorShowWorker = {}
TheContractorShowWorker_mt = Class(TheContractorShowWorker)

TheContractorShowWorker.KEY = "ploughingWorker"
TheContractorShowWorker.SAVE_KEY = "showWorker"

local WITHDRAW = TCShowWorker.WITHDRAW

function TheContractorShowWorker.new()
    local self = setmetatable({}, TheContractorShowWorker_mt)
    -- Every machine, as the server sent it.
    self.showId = nil
    self.entries = {}
    -- Server: the rolls (the tests swap it).
    self.random = math.random
    return self
end

-- Every machine, at load: a show competition that takes entries (so
-- entries close and "entries close soon" goes out for it) and places
-- nobody itself: the ploughing match does.
function TheContractorShowWorker:register(show)
    show:registerCompetition(TheContractorShowWorker.KEY, {
        titleKey = TheContractorPloughingMatch.TITLE_KEY,
        takesEntries = true,
        onAnnounced = function(event)
            self:reset(event.id)
        end,
        onNewDay = function(event)
            self:checkEntries(event)
        end,
        onHour = function(event)
            self:checkEntries(event)
        end,
        onResults = function(event)
            self:rewardPlacings(event)
        end,
        onFinished = function()
            self:releaseAll()
        end,
        onCancelled = function()
            -- Dropped first, so nobody set idle is sent back to the show.
            local entries = self.entries
            self:reset(nil)
            self:releaseAll(entries)
        end,
    })
end

-- Queries (every machine) ------------------------------------------------------------------

local function getTC()
    return g_currentMission ~= nil and g_currentMission.TheContractor or nil
end

local function getShowEvent()
    local tc = getTC()
    return tc ~= nil and tc.Show ~= nil and tc.Show:getEvent() or nil
end

local function getToday()
    return g_currentMission.environment.currentMonotonicDay
end

-- A farm's entry, or nil.
function TheContractorShowWorker:getEntry(farmId)
    for _, entry in ipairs(self.entries) do
        if entry.farmId == farmId then
            return entry
        end
    end
    return nil
end

function TheContractorShowWorker:getEntries()
    return self.entries
end

-- The entry's worker (on the farm's roster), or nil.
function TheContractorShowWorker.getWorker(entry)
    local tc = getTC()
    return entry ~= nil and tc.Staff ~= nil and tc.Staff:getWorker(entry.farmId, entry.workerId) or nil
end

-- A farm's worker on a plot, by name: from the roster, else as entered.
function TheContractorShowWorker:getWorkerName(farmId, workerId)
    local tc = getTC()
    local worker = tc.Staff ~= nil and tc.Staff:getWorker(farmId, workerId) or nil
    if worker ~= nil then
        return worker.name
    end
    local entry = self:getEntry(farmId)
    return entry ~= nil and entry.workerId == workerId and entry.name or nil
end

-- Whether a worker's on holiday or training on a day.
local function isAwayOn(worker, day)
    if worker.isHolidayOn ~= nil and worker:isHolidayOn(day) then
        return true
    end
    return TheContractorHolidays ~= nil and TheContractorHolidays.isTrainingOn ~= nil and
        TheContractorHolidays.isTrainingOn(worker, day)
end

-- Why a farm can't enter a worker, or nil (every machine: the menu asks
-- before sending, the server again). Off sick now counts as not free:
-- clients can't know for how long.
function TheContractorShowWorker:getEntryProblem(farmId, workerId)
    local tc = getTC()
    local event = getShowEvent()
    local worker = tc.Staff ~= nil and tc.Staff:getWorker(farmId, workerId) or nil
    return TCShowWorker.getEntryProblem({
        hasShow = event ~= nil,
        isOpen = event ~= nil and TheContractorShow.isEntryOpen(event, getToday()),
        hasCompany = tc.Company ~= nil and tc.Company:hasCompany(farmId),
        hasEntry = self.showId ~= nil and event ~= nil and self.showId == event.id and self:getEntry(farmId) ~= nil,
        worker = worker,
        isLeaving = worker ~= nil and worker:isLeaving(),
        isSick = worker ~= nil and (worker.status == TheContractorWorker.STATUS.SICK or
            (worker.pendingSickDays or 0) > 0),
        isAway = worker ~= nil and event ~= nil and isAwayOn(worker, event.day),
    })
end

-- Whether an entered worker's due at the show now: the day, before the
-- results (Staff:setWorkerStatus sends one back from a job there).
function TheContractorShowWorker:isDueToday(worker)
    local event = getShowEvent()
    if worker == nil or event == nil or self.showId ~= event.id or event.day ~= getToday() or event.resultsGiven then
        return false
    end
    local entry = self:getEntry(worker.farmId)
    return entry ~= nil and entry.workerId == worker.id
end

-- Whether a farm's entered worker is at the show now.
function TheContractorShowWorker:isAtShow(farmId)
    local worker = TheContractorShowWorker.getWorker(self:getEntry(farmId))
    return worker ~= nil and worker.status == TheContractorWorker.STATUS.SHOW
end

-- Entering (server) -----------------------------------------------------------------------------

-- Server: the entries start again (a new show, or none).
function TheContractorShowWorker:reset(showId)
    self.showId = showId
    self.entries = {}
    self:sync()
end

-- Server (TCShowEntryEvent): a farm enters a worker. Returns the entry, or
-- nil and the problem.
function TheContractorShowWorker:enter(farmId, workerId)
    local problem = self:getEntryProblem(farmId, workerId)
    if problem ~= nil then
        TCLog.info("TheContractor: farm %d's worker %s not entered in the ploughing: %s", farmId, tostring(workerId),
            problem)
        return nil, problem
    end
    local event = getShowEvent()
    if self.showId ~= event.id then
        self:reset(event.id)
    end
    local worker = getTC().Staff:getWorker(farmId, workerId)
    local entry = { farmId = farmId, workerId = workerId, name = worker.name }
    table.insert(self.entries, entry)
    TCLog.info("TheContractor: farm %d entered worker %d (%s) in show %d's ploughing match", farmId, workerId,
        worker.name, event.id)
    self:sync()
    return entry
end

-- Server (TCShowEntryEvent): a farm withdraws its worker while entries are
-- open. Returns nil, or the problem.
function TheContractorShowWorker:withdraw(farmId)
    local event = getShowEvent()
    if event == nil or not TheContractorShow.isEntryOpen(event, getToday()) then
        return TCShowWorker.PROBLEM.closed
    end
    if not self:removeEntry(farmId) then
        return TCShowWorker.PROBLEM.notEntered
    end
    TCLog.info("TheContractor: farm %d withdrew its worker from the ploughing match", farmId)
    self:sync()
    return nil
end

function TheContractorShowWorker:removeEntry(farmId)
    for i, entry in ipairs(self.entries) do
        if entry.farmId == farmId then
            table.remove(self.entries, i)
            return true
        end
    end
    return false
end

-- Server: an entry withdrawn for a reason (TCShowWorker.WITHDRAW): the
-- worker back to idle if they were at the show, the farm told, and on the
-- day the plot goes to a farmer.
function TheContractorShowWorker:withdrawEntry(farmId, reason)
    local entry = self:getEntry(farmId)
    if entry == nil then
        return false
    end
    local tc = getTC()
    local event = getShowEvent()
    self:removeEntry(farmId)
    local worker = TheContractorShowWorker.getWorker(entry)
    if worker ~= nil and worker.status == TheContractorWorker.STATUS.SHOW then
        tc.Staff:setWorkerStatus(farmId, worker.id, TheContractorWorker.STATUS.IDLE)
    end
    local hadPlot = tc.PloughingMatch ~= nil and tc.PloughingMatch:onWorkerWithdrawn(farmId, entry.workerId)
    TCLog.info("TheContractor: farm %d's worker %d (%s) withdrawn from the ploughing match: %s", farmId,
        entry.workerId, entry.name, reason)
    if event ~= nil and tc.Inbox ~= nil then
        tc.Inbox:postMessage(farmId, TheContractorShow.KIND, "tc_showWorker_withdrawnTitle",
            hadPlot and "tc_showWorker_withdrawnBodyPlot" or "tc_showWorker_withdrawnBody",
            { string.format("$days_%d_%d", event.day, event.day), entry.name, "$l10n_" .. reason },
            { TheContractorInbox.DISMISS_ACTION },
            { entryShowId = event.id, farmerId = event.hostFarmerId, fieldId = event.ploughFieldId or event.fieldId })
    end
    self:sync()
    return true
end

-- The day (server) ------------------------------------------------------------------------------

-- Why an entered worker can't make the day now, or nil.
function TheContractorShowWorker.getWithdrawReason(worker, event, today)
    if worker == nil then
        return WITHDRAW.gone
    end
    if worker.status == TheContractorWorker.STATUS.SHOW then
        return nil
    end
    if worker.status == TheContractorWorker.STATUS.SICK and
            TCShowWorker.isSickOn(today, event.day, worker.sickDaysRemaining, 0) then
        return WITHDRAW.sick
    end
    if (worker.pendingSickDays or 0) > 0 and TCShowWorker.isSickOn(today, event.day, 0, worker.pendingSickDays) then
        return WITHDRAW.sick
    end
    if isAwayOn(worker, event.day) then
        return WITHDRAW.away
    end
    return nil
end

-- Server, every day and hour until the results (and at the set-out, from
-- the match): any entered worker who can't make it is withdrawn, and on the
-- day an idle one goes to the show.
function TheContractorShowWorker:checkEntries(event)
    if not g_currentMission:getIsServer() then
        return
    end
    event = event or getShowEvent()
    if event == nil or self.showId ~= event.id or event.resultsGiven then
        self:releaseStray()
        return
    end
    local today = getToday()
    local tc = getTC()
    local entries = {}
    for i, entry in ipairs(self.entries) do
        entries[i] = entry
    end
    for _, entry in ipairs(entries) do
        local worker = TheContractorShowWorker.getWorker(entry)
        local reason = TheContractorShowWorker.getWithdrawReason(worker, event, today)
        if reason ~= nil then
            self:withdrawEntry(entry.farmId, reason)
        elseif today == event.day and worker:isIdle() then
            TCLog.info("TheContractor: farm %d worker %d (%s) at the show for the ploughing match", worker.farmId,
                worker.id, worker.name)
            tc.Staff:setWorkerStatus(worker.farmId, worker.id, TheContractorWorker.STATUS.SHOW)
        end
    end
    self:releaseStray()
end

-- Server: anyone at the show who shouldn't be (a save from a show that's
-- gone, an entry that's been dropped) back to idle. 172: not one there for
-- the staff's day off.
function TheContractorShowWorker:releaseStray()
    local tc = getTC()
    if tc.Staff == nil then
        return
    end
    local dayOff = tc.ShowDayOff
    for farmId, farmWorkers in pairs(tc.Staff.workersByFarm or {}) do
        local stray = {}
        for _, worker in pairs(farmWorkers) do
            if worker.status == TheContractorWorker.STATUS.SHOW and not self:isDueToday(worker) and
                    not (dayOff ~= nil and dayOff:isDueToday(worker)) then
                table.insert(stray, worker)
            end
        end
        for _, worker in ipairs(stray) do
            tc.Staff:setWorkerStatus(farmId, worker.id, TheContractorWorker.STATUS.IDLE)
        end
    end
end

-- Server, at midnight after (or the show's called off): everyone at the
-- show back to idle. entries: the entries' (default this show's). 172: not
-- one there for the staff's day off.
function TheContractorShowWorker:releaseAll(entries)
    local tc = getTC()
    local dayOff = tc.ShowDayOff
    for _, entry in ipairs(entries or self.entries) do
        local worker = TheContractorShowWorker.getWorker(entry)
        if worker ~= nil and worker.status == TheContractorWorker.STATUS.SHOW and
                not (dayOff ~= nil and dayOff:isDueToday(worker)) then
            tc.Staff:setWorkerStatus(entry.farmId, worker.id, TheContractorWorker.STATUS.IDLE)
        end
    end
end

-- Server (the roster's leave path: Staff:retireWorker/releaseWorker): a
-- worker who's gone is withdrawn, if their entry's still to run.
function TheContractorShowWorker:onWorkerGone(farmId, workerId)
    local entry = self:getEntry(farmId)
    local event = getShowEvent()
    if entry == nil or entry.workerId ~= workerId or event == nil or event.id ~= self.showId or event.resultsGiven then
        return
    end
    self:withdrawEntry(farmId, WITHDRAW.gone)
end

-- Server (PloughingMatch, once the worker's at the show and the match is
-- on): their score and minutes, rolled now and kept hidden until the
-- results. nil if they're not on the roster.
function TheContractorShowWorker:rollRun(farmId)
    local worker = TheContractorShowWorker.getWorker(self:getEntry(farmId))
    if worker == nil then
        return nil
    end
    local tillage = worker:getSkill("tillage")
    local tractor = worker:getTierCapability(TCShowWorker.KIT_TIER) or 1
    local moraleFactor = 1
    if TheContractorMorale ~= nil and TheContractorMorale.getQualityMultiplierFor ~= nil and worker.morale ~= nil then
        moraleFactor = TheContractorMorale.getQualityMultiplierFor(worker.morale)
    end
    local total = TCShowWorker.rollScore(tillage, tractor, moraleFactor, self.random)
    local minutes = TCShowWorker.rollMinutes(tillage, tractor, self.random)
    TCLog.info("TheContractor: farm %d worker %d (%s) ploughs: tillage %d, tractor %d, morale x%.2f: %.1f in %d min",
        farmId, worker.id, worker.name, tillage, tractor, moraleFactor, total, minutes)
    return total, minutes
end

-- Server, after the results: each entered worker who's placed gets a lift.
function TheContractorShowWorker:rewardPlacings(event)
    local tc = getTC()
    local match = tc.PloughingMatch
    if match == nil or tc.Morale == nil or self.showId ~= event.id then
        return
    end
    for _, entry in ipairs(self.entries) do
        local plot = match:getFarmPlot(entry.farmId)
        local worker = TheContractorShowWorker.getWorker(entry)
        local boost = 0
        if plot ~= nil and plot.workerId == entry.workerId and plot.card ~= nil then
            boost = TCShowWorker.getMoraleBoost(plot.card.placing)
        end
        if worker ~= nil and boost > 0 then
            tc.Morale:adjust(entry.farmId, { worker }, boost)
        end
    end
end

-- Farms --------------------------------------------------------------------------------------------

-- Every machine (TCFarmDeletion): a deleted farm's entry goes.
function TheContractorShowWorker:forgetFarm(farmId)
    self:removeEntry(farmId)
end

-- Sync ---------------------------------------------------------------------------------------------

function TheContractorShowWorker:sync()
    if g_server ~= nil then
        g_server:broadcastEvent(TCShowWorkerEvent.new(self))
    end
end

function TheContractorShowWorker.writeState(streamId, state)
    streamWriteInt32(streamId, state.showId or -1)
    streamWriteUInt8(streamId, #state.entries)
    for _, entry in ipairs(state.entries) do
        streamWriteInt32(streamId, entry.farmId)
        streamWriteInt32(streamId, entry.workerId)
        streamWriteString(streamId, entry.name or "")
    end
end

function TheContractorShowWorker.readState(streamId)
    local state = { entries = {} }
    local showId = streamReadInt32(streamId)
    state.showId = showId >= 0 and showId or nil
    for _ = 1, streamReadUInt8(streamId) do
        table.insert(state.entries, { farmId = streamReadInt32(streamId), workerId = streamReadInt32(streamId),
            name = streamReadString(streamId) })
    end
    return state
end

-- A client: the entries as the server sent them.
function TheContractorShowWorker:applyState(state)
    self.showId = state.showId
    self.entries = state.entries
end

function TheContractorShowWorker:writeInitialClientState(streamId, connection)
    TheContractorShowWorker.writeState(streamId, self)
end

function TheContractorShowWorker:readInitialClientState(streamId, connection)
    self:applyState(TheContractorShowWorker.readState(streamId))
end

-- Persistence (server) -------------------------------------------------------------------------------

function TheContractorShowWorker:saveToXmlFile(xmlFile)
    if not g_currentMission:getIsServer() then
        return
    end
    local key = TheContractor.SaveKey .. "." .. TheContractorShowWorker.SAVE_KEY
    if self.showId ~= nil then
        setXMLInt(xmlFile, key .. "#showId", self.showId)
    end
    for i, entry in ipairs(self.entries) do
        local entryKey = string.format("%s.entry(%d)", key, i - 1)
        setXMLInt(xmlFile, entryKey .. "#farmId", entry.farmId)
        setXMLInt(xmlFile, entryKey .. "#workerId", entry.workerId)
        setXMLString(xmlFile, entryKey .. "#name", entry.name or "")
    end
end

function TheContractorShowWorker:loadFromXMLFile(xmlFile)
    if not g_currentMission:getIsServer() then
        return
    end
    local key = TheContractor.SaveKey .. "." .. TheContractorShowWorker.SAVE_KEY
    self.showId = getXMLInt(xmlFile, key .. "#showId")
    self.entries = {}
    local i = 0
    while hasXMLProperty(xmlFile, string.format("%s.entry(%d)", key, i)) do
        local entryKey = string.format("%s.entry(%d)", key, i)
        local farmId = getXMLInt(xmlFile, entryKey .. "#farmId")
        local workerId = getXMLInt(xmlFile, entryKey .. "#workerId")
        if farmId ~= nil and workerId ~= nil then
            table.insert(self.entries, { farmId = farmId, workerId = workerId,
                name = getXMLString(xmlFile, entryKey .. "#name") or "" })
        end
        i = i + 1
    end
end

-- Console ----------------------------------------------------------------------------------------------

-- tcDebug showWorker: a worker entered whatever the date (entries closed,
-- the day itself), for testing on the day 'tcDebug showDay' makes.
function TheContractorShowWorker:consoleEnter(farmId, worker)
    local event = getShowEvent()
    if event == nil then
        return "There's no show announced: 'tcShow start' announces one."
    end
    if self.showId ~= event.id then
        self:reset(event.id)
    end
    self:removeEntry(farmId)
    table.insert(self.entries, { farmId = farmId, workerId = worker.id, name = worker.name })
    self:sync()
    local tc = getTC()
    if tc.PloughingMatch ~= nil then
        tc.PloughingMatch:reserveWorkerPlots()
    end
    self:checkEntries(event)
    return string.format("%s is entered in show %d's ploughing match for farm %d%s.", worker.name, event.id, farmId,
        self:isAtShow(farmId) and ", and at the show now" or "")
end

function TheContractorShowWorker.registerConsoleCommands()
    TCConsole.register("debug", "showWorker", {
        args = "<worker>",
        description = "Enter a worker in the show's ploughing match now, entries closed or not (on the day: at the show at once)",
        run = function(farmId, args)
            if args[1] == nil or args[2] ~= nil then
                return false
            end
            local worker, problem = TCConsole.findWorker(farmId, args[1])
            if worker == nil then
                return problem or false
            end
            return g_currentMission.TheContractor.ShowWorker:consoleEnter(farmId, worker)
        end,
    })
end
