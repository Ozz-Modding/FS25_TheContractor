-- The staff's day off for the show (172). A few weeks before the county
-- show (165), each company farm with staff is asked by inbox whether to
-- give everyone the day off. The pure half is TCShowDayOff.
--
-- The ask: TCShowDayOff.getAskDay, worked out from the show's day each day
--   (so it moves when the day does, 161), to every company farm with
--   anyone employed (Staff:getHeadcount: workers or office staff), with
--   Yes / No. A farm that takes on its first staff after the ask day is
--   asked then. It expires on the show's day (the day before is the last
--   to answer); an ignored ask is a No.
-- Yes: everyone's morale up a little (Morale:adjust). On the day every
--   worker who'd otherwise work is at the show (TheContractorWorker.STATUS
--   .SHOW, 170's status), paid as normal: not offered for anything, so
--   nothing can be allocated to them. One out on a job goes when they're
--   back (Staff:setWorkerStatus, isDueToday). Anyone sick, on holiday or
--   training stays so; a worker entered in the ploughing (170) goes
--   anyway. The office staff are off too (TheContractorOffice.getStatus),
--   and there's no office work that day (Office:isAdministratorAtWork).
--   Back at midnight after.
-- No: a small knock for everyone, smaller than a refused holiday (089).
-- On the showground: the staff at the show stand in the crowd as
--   themselves (TCShowStandsWorld, TCShowDayOff.assignPlaces), worked out
--   from synced state on every machine.
--
-- Every machine: the show it's for and each farm's answer (asked, yes or
-- no), kept until the next show's announced so the Show tab can say. Sent
-- with TCShowDayOffEvent, saved in TheContractor.xml (.showDayOff), in the
-- initial client state; answers hold farms (forgetFarm). Nothing's a date
-- of its own: the ask's day comes from the show's. Tested in
-- tests/test_showDayOff.lua.

TheContractorShowDayOff = {}
TheContractorShowDayOff_mt = Class(TheContractorShowDayOff)

TheContractorShowDayOff.KEY = "staffDayOff"
TheContractorShowDayOff.SAVE_KEY = "showDayOff"
TheContractorShowDayOff.MESSAGE_KIND = "showDayOff"

TheContractorShowDayOff.ACTION = {
    YES = { key = "yes", textKey = "tc_showDayOff_yes" },
    NO = { key = "no", textKey = "tc_showDayOff_no" },
}

local ANSWER = TCShowDayOff.ANSWER

function TheContractorShowDayOff.new()
    local self = setmetatable({}, TheContractorShowDayOff_mt)
    -- Every machine, as the server sent it.
    self.showId = nil
    self.answers = {}
    return self
end

-- Every machine, at load: a show competition that places nobody (for its
-- hooks), and the ask's message kind.
function TheContractorShowDayOff:register(show, inbox)
    show:registerCompetition(TheContractorShowDayOff.KEY, {
        onAnnounced = function(event)
            self:reset(event.id)
        end,
        onNewDay = function(event)
            self:onNewDay(event)
        end,
        onHour = function(event)
            self:checkStaff(event)
        end,
        onFinished = function()
            self:releaseStray()
            self:refreshWorkshops()
        end,
        onCancelled = function(event)
            self:onCancelled(event)
        end,
    })
    if inbox ~= nil then
        inbox:registerMessageKind(TheContractorShowDayOff.MESSAGE_KIND, {
            category = "staff",
            getArgs = function(message)
                return TheContractorShowDayOff.getMessageArgs(message)
            end,
            onAction = function(farmId, message, actionKey)
                self:answer(farmId, actionKey == TheContractorShowDayOff.ACTION.YES.key,
                    message.payload.dayOffShowId)
            end,
            onExpire = function(farmId, message)
                self:answer(farmId, false, message.payload.dayOffShowId)
            end,
        })
    end
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

-- The ask's args, the show's day as it is now (it may have moved).
function TheContractorShowDayOff.getMessageArgs(message)
    local event = getShowEvent()
    if event ~= nil and message.payload ~= nil and message.payload.dayOffShowId == event.id then
        return { string.format("$days_%d_%d", event.day, event.day) }
    end
    return message.args
end

-- A farm's answer for the show (or the last one, until the next's
-- announced): TCShowDayOff.ANSWER, or nil if it wasn't asked.
function TheContractorShowDayOff:getAnswer(farmId)
    return self.answers[farmId]
end

-- The day the ask goes out for a show.
function TheContractorShowDayOff.getAskDay(event)
    return TCShowDayOff.getAskDay(event.day, TCCalendar.getDaysPerPeriodOn(event.day))
end

-- Whether a farm's staff have today off for the show.
function TheContractorShowDayOff:isOffToday(farmId)
    local event = getShowEvent()
    return event ~= nil and self.showId == event.id and event.day == getToday() and
        self.answers[farmId] == ANSWER.YES
end

-- Whether a worker's due at the show now for the day off: their farm's
-- given it, and they're not on holiday or due in for training (both come
-- first). Staff:setWorkerStatus sends one back from a job there.
function TheContractorShowDayOff:isDueToday(worker)
    if worker == nil or not self:isOffToday(worker.farmId) then
        return false
    end
    if worker.isHolidayOn ~= nil and worker:isHolidayOn(getToday()) then
        return false
    end
    if TheContractorTraining ~= nil and TheContractorTraining.isDueToday ~= nil and
            TheContractorTraining.isDueToday(worker) then
        return false
    end
    return true
end

-- Whether a worker at the show has the day off (not 170's ploughing
-- entrant, who's at their plot): who TCShowStandsWorld puts in the crowd.
function TheContractorShowDayOff:isInCrowd(worker)
    if worker == nil or worker.status ~= TheContractorWorker.STATUS.SHOW or not self:isOffToday(worker.farmId) then
        return false
    end
    local showWorker = getTC().ShowWorker
    local entry = showWorker ~= nil and showWorker:getEntry(worker.farmId) or nil
    return entry == nil or entry.workerId ~= worker.id
end

-- The staff in the crowd now: { { id, farmId, person (the worker or office
-- member, for their look) } }, sorted by id.
function TheContractorShowDayOff:getCrowdStaff()
    local tc = getTC()
    local staff = {}
    if tc == nil or tc.Staff == nil then
        return staff
    end
    for farmId, answer in pairs(self.answers) do
        if answer == ANSWER.YES and self:isOffToday(farmId) then
            for _, worker in ipairs(tc.Staff:getRoster(farmId)) do
                if self:isInCrowd(worker) then
                    table.insert(staff, { id = worker.id, farmId = farmId, person = worker })
                end
            end
            for _, member in ipairs(tc.Office ~= nil and tc.Office:getMembers(farmId) or {}) do
                if TheContractorOffice.getStatus(member) == TheContractorOffice.STATUS.SHOW then
                    table.insert(staff, { id = member.id, farmId = farmId, person = member })
                end
            end
        end
    end
    table.sort(staff, function(a, b)
        return a.id < b.id
    end)
    return staff
end

-- Where the staff in the crowd stand now (every machine, from the synced
-- scene): the places the farmers (farmerPlaces, 171's personId -> spot)
-- left, then the ring's spectator spots. A list of { id, person, place =
-- { x, z, yaw, isCrowdSpot } }, by id; anyone past the places there are is
-- left off. Empty without a showground.
function TheContractorShowDayOff:getCrowdPlacesNow(farmerPlaces)
    local tc = getTC()
    local event = getShowEvent()
    local scene = tc ~= nil and tc.ShowStands ~= nil and tc.ShowStands:getScene() or nil
    if event == nil or scene == nil then
        return {}
    end
    local staff = self:getCrowdStaff()
    if #staff == 0 then
        return {}
    end
    -- The layout's worked out once a scene.
    if self.layoutScene ~= scene then
        self.layoutScene = scene
        self.layout = TCShowScene.layOut(scene)
    end
    local ids = {}
    for i, entry in ipairs(staff) do
        ids[i] = entry.id
    end
    local places = TCShowDayOff.assignPlaces(event.id, TheContractorShowStands.getSlotNow(), ids,
        TCShowDayOff.getFreePlaces(self.layout, farmerPlaces))
    local result = {}
    for _, entry in ipairs(staff) do
        if places[entry.id] ~= nil then
            table.insert(result, { id = entry.id, person = entry.person, place = places[entry.id] })
        end
    end
    return result
end

-- The ask (server) -----------------------------------------------------------------------------

-- Server: the answers start again (a new show, or none).
function TheContractorShowDayOff:reset(showId)
    self.showId = showId
    self.answers = {}
    self:sync()
end

-- Server, each day the show's on the calendar: the asks out from their
-- day; on the day, any not answered are a No and the staff go.
function TheContractorShowDayOff:onNewDay(event)
    if not g_currentMission:getIsServer() or event == nil then
        return
    end
    if self.showId ~= event.id then
        self:reset(event.id)
    end
    local today = getToday()
    if today >= event.day then
        self:closeAsks(event)
        if today == event.day then
            self:checkStaff(event)
            self:refreshWorkshops()
        end
        return
    end
    if TCShowDayOff.isAskDue(today, TheContractorShowDayOff.getAskDay(event), event.day) then
        self:postAsks(event)
    end
end

-- Server: the ask to every company farm with staff not asked yet. Returns
-- how many were asked.
function TheContractorShowDayOff:postAsks(event)
    local tc = getTC()
    local today = getToday()
    local count = 0
    for _, farmId in ipairs(tc.RandomEvents:getCompanyFarmIds()) do
        if self.answers[farmId] == nil and tc.Staff:getHeadcount(farmId) > 0 then
            self:postAsk(farmId, event, today)
            count = count + 1
        end
    end
    if count > 0 then
        self:sync()
    end
    return count
end

function TheContractorShowDayOff:postAsk(farmId, event, today)
    local tc = getTC()
    local ACTION = TheContractorShowDayOff.ACTION
    self.answers[farmId] = ANSWER.ASKED
    tc.Inbox:postMessage(farmId, TheContractorShowDayOff.MESSAGE_KIND, "tc_showDayOff_askTitle",
        "tc_showDayOff_askBody", { string.format("$days_%d_%d", event.day, event.day) }, { ACTION.YES, ACTION.NO },
        { dayOffShowId = event.id }, math.max(1, event.day - today))
    TCLog.info("TheContractor: farm %d asked whether its staff have show %d's day off", farmId, event.id)
end

-- Server (the ask's Yes or No, or it expiring): the farm's answer, and
-- everyone's morale. Returns whether it was taken.
function TheContractorShowDayOff:answer(farmId, isYes, showId)
    if showId ~= self.showId or self.answers[farmId] ~= ANSWER.ASKED then
        return false
    end
    local tc = getTC()
    self.answers[farmId] = isYes and ANSWER.YES or ANSWER.NO
    local roster = tc.Staff ~= nil and tc.Staff:getRoster(farmId) or {}
    if tc.Morale ~= nil and #roster > 0 then
        tc.Morale:adjust(farmId, roster, TCShowDayOff.getMoraleDelta(isYes))
    end
    TCLog.info("TheContractor: farm %d %s its staff show %d's day off", farmId, isYes and "gave" or "didn't give",
        showId)
    self:sync()
    -- On the day already (the console's): they go now.
    local event = getShowEvent()
    if isYes and event ~= nil and event.id == showId and event.day == getToday() then
        self:checkStaff(event)
        self:refreshWorkshops()
    end
    return true
end

-- Server: every ask for the show still out is a No, and goes.
function TheContractorShowDayOff:closeAsks(event)
    local tc = getTC()
    local farmIds = {}
    for farmId, answer in pairs(self.answers) do
        if answer == ANSWER.ASKED then
            table.insert(farmIds, farmId)
        end
    end
    table.sort(farmIds)
    for _, farmId in ipairs(farmIds) do
        self:answer(farmId, false, event.id)
    end
    self:removeMessages(event.id)
end

-- Server: the ask's messages for a show go.
function TheContractorShowDayOff:removeMessages(showId)
    local inbox = getTC().Inbox
    if inbox == nil then
        return
    end
    local ids = {}
    for id, message in pairs(inbox.messagesById) do
        if message.kind == TheContractorShowDayOff.MESSAGE_KIND and message.payload.dayOffShowId == showId then
            table.insert(ids, id)
        end
    end
    table.sort(ids)
    for _, id in ipairs(ids) do
        inbox:removeMessage(id)
    end
end

-- The day (server) -------------------------------------------------------------------------------

-- Server, at the day's start and every hour of it: each worker due at the
-- show who's idle goes. Off the day, anyone at the show who shouldn't be
-- is back.
function TheContractorShowDayOff:checkStaff(event)
    if not g_currentMission:getIsServer() then
        return
    end
    event = event or getShowEvent()
    if event == nil or self.showId ~= event.id or event.day ~= getToday() then
        self:releaseStray()
        return
    end
    local tc = getTC()
    for farmId, answer in pairs(self.answers) do
        if answer == ANSWER.YES then
            local going = {}
            for _, worker in ipairs(tc.Staff:getRoster(farmId)) do
                if worker:isIdle() and self:isDueToday(worker) then
                    table.insert(going, worker)
                end
            end
            table.sort(going, function(a, b)
                return a.id < b.id
            end)
            for _, worker in ipairs(going) do
                TCLog.info("TheContractor: farm %d worker %d (%s) has the day off at the show", farmId, worker.id,
                    worker.name)
                tc.Staff:setWorkerStatus(farmId, worker.id, TheContractorWorker.STATUS.SHOW)
            end
        end
    end
end

-- Server: anyone at the show who's due there for neither the day off nor
-- 170's ploughing back to idle (midnight after, a show called off, a save
-- from a show that's gone).
function TheContractorShowDayOff:releaseStray()
    local tc = getTC()
    if tc == nil or tc.Staff == nil then
        return
    end
    local showWorker = tc.ShowWorker
    for farmId, farmWorkers in pairs(tc.Staff.workersByFarm or {}) do
        local stray = {}
        for _, worker in pairs(farmWorkers) do
            if worker.status == TheContractorWorker.STATUS.SHOW and not self:isDueToday(worker) and
                    not (showWorker ~= nil and showWorker:isDueToday(worker)) then
                table.insert(stray, worker)
            end
        end
        table.sort(stray, function(a, b)
            return a.id < b.id
        end)
        for _, worker in ipairs(stray) do
            tc.Staff:setWorkerStatus(farmId, worker.id, TheContractorWorker.STATUS.IDLE)
        end
    end
end

-- Server: ADS's workshop sees the office staff off, or back (097's
-- refresh), for each farm that gave the day.
function TheContractorShowDayOff:refreshWorkshops()
    if TCADSWorkshop == nil or TCADSWorkshop.refresh == nil then
        return
    end
    for farmId, answer in pairs(self.answers) do
        if answer == ANSWER.YES then
            TCADSWorkshop.refresh(farmId)
        end
    end
end

-- Server: the show's called off. The asks go and nobody's off; the answers
-- given (and their morale) stand.
function TheContractorShowDayOff:onCancelled(event)
    self:removeMessages(event.id)
    self:reset(nil)
    self:releaseStray()
    self:refreshWorkshops()
end

-- Farms --------------------------------------------------------------------------------------------

-- Every machine (TCFarmDeletion): a deleted farm's answer goes.
function TheContractorShowDayOff:forgetFarm(farmId)
    self.answers[farmId] = nil
end

-- Sync ---------------------------------------------------------------------------------------------

function TheContractorShowDayOff:sync()
    if g_server ~= nil then
        g_server:broadcastEvent(TCShowDayOffEvent.new(self))
    end
end

function TheContractorShowDayOff.writeState(streamId, state)
    streamWriteInt32(streamId, state.showId or -1)
    local farmIds = {}
    for farmId in pairs(state.answers) do
        table.insert(farmIds, farmId)
    end
    table.sort(farmIds)
    streamWriteUInt8(streamId, #farmIds)
    for _, farmId in ipairs(farmIds) do
        streamWriteInt32(streamId, farmId)
        streamWriteUInt8(streamId, state.answers[farmId])
    end
end

function TheContractorShowDayOff.readState(streamId)
    local state = { answers = {} }
    local showId = streamReadInt32(streamId)
    state.showId = showId >= 0 and showId or nil
    for _ = 1, streamReadUInt8(streamId) do
        local farmId = streamReadInt32(streamId)
        state.answers[farmId] = streamReadUInt8(streamId)
    end
    return state
end

-- A client: the answers as the server sent them.
function TheContractorShowDayOff:applyState(state)
    self.showId = state.showId
    self.answers = state.answers
end

function TheContractorShowDayOff:writeInitialClientState(streamId, connection)
    TheContractorShowDayOff.writeState(streamId, self)
end

function TheContractorShowDayOff:readInitialClientState(streamId, connection)
    self:applyState(TheContractorShowDayOff.readState(streamId))
end

-- Persistence (server) -------------------------------------------------------------------------------

function TheContractorShowDayOff:saveToXmlFile(xmlFile)
    if not g_currentMission:getIsServer() then
        return
    end
    local key = TheContractor.SaveKey .. "." .. TheContractorShowDayOff.SAVE_KEY
    if self.showId ~= nil then
        setXMLInt(xmlFile, key .. "#showId", self.showId)
    end
    local farmIds = {}
    for farmId in pairs(self.answers) do
        table.insert(farmIds, farmId)
    end
    table.sort(farmIds)
    for i, farmId in ipairs(farmIds) do
        local farmKey = string.format("%s.farm(%d)", key, i - 1)
        setXMLInt(xmlFile, farmKey .. "#farmId", farmId)
        setXMLInt(xmlFile, farmKey .. "#answer", self.answers[farmId])
    end
end

function TheContractorShowDayOff:loadFromXMLFile(xmlFile)
    if not g_currentMission:getIsServer() then
        return
    end
    local key = TheContractor.SaveKey .. "." .. TheContractorShowDayOff.SAVE_KEY
    self.showId = getXMLInt(xmlFile, key .. "#showId")
    self.answers = {}
    local i = 0
    while hasXMLProperty(xmlFile, string.format("%s.farm(%d)", key, i)) do
        local farmKey = string.format("%s.farm(%d)", key, i)
        local farmId = getXMLInt(xmlFile, farmKey .. "#farmId")
        local answer = getXMLInt(xmlFile, farmKey .. "#answer")
        if farmId ~= nil and (answer == ANSWER.ASKED or answer == ANSWER.YES or answer == ANSWER.NO) then
            self.answers[farmId] = answer
        end
        i = i + 1
    end
end

-- Console ----------------------------------------------------------------------------------------------

local ANSWER_NAMES = { [ANSWER.ASKED] = "asked, no answer yet", [ANSWER.YES] = "yes", [ANSWER.NO] = "no" }

-- tcDebug showDayOff: the farm asked now whatever the date, or its answer
-- given (yes or no: asked first if it hasn't been).
function TheContractorShowDayOff:consoleAsk(farmId, answerName)
    local event = getShowEvent()
    if event == nil then
        return "There's no show announced: 'tcShow start' announces one."
    end
    local tc = getTC()
    if not tc.Company:hasCompany(farmId) then
        return string.format("Farm %d has no company to ask.", farmId)
    end
    if self.showId ~= event.id then
        self:reset(event.id)
    end
    local answer = self.answers[farmId]
    if answer ~= nil and answer ~= ANSWER.ASKED then
        return string.format("Farm %d has answered for show %d already: %s.", farmId, event.id, ANSWER_NAMES[answer])
    end
    if answer == nil then
        self:postAsk(farmId, event, getToday())
        self:sync()
    end
    if answerName == nil then
        return string.format("Farm %d is asked about show %d's day off (%s): answer in the Inbox.", farmId, event.id,
            TCCalendar.formatDay(event.day))
    end
    self:answer(farmId, answerName == "yes", event.id)
    for id, message in pairs(tc.Inbox.messagesById) do
        if message.farmId == farmId and message.kind == TheContractorShowDayOff.MESSAGE_KIND and
                message.payload.dayOffShowId == event.id then
            tc.Inbox:removeMessage(id)
        end
    end
    return string.format("Farm %d's answer for show %d's day off: %s.", farmId, event.id, answerName)
end

function TheContractorShowDayOff.registerConsoleCommands()
    TCConsole.register("debug", "showDayOff", {
        args = "[yes|no]",
        description = "Ask your farm about the show's staff day off now, whatever the date, or answer it",
        run = function(farmId, args)
            local answerName = args[1] ~= nil and string.lower(args[1]) or nil
            if args[2] ~= nil or (answerName ~= nil and answerName ~= "yes" and answerName ~= "no") then
                return false
            end
            return g_currentMission.TheContractor.ShowDayOff:consoleAsk(farmId, answerName)
        end,
    })
end
