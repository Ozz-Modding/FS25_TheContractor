-- Certification and training (054). Some work needs a certificate: in the
-- UK anyone applying professional pesticides needs PA1 (the theory) and PA2
-- (boom sprayer), so a herbicide job can only go to a worker holding the
-- "spraying" certificate (JobGeneration's JOB_TYPES `certification`,
-- checked by Allocation). The player driving it themselves is assumed
-- certified. Certificates are a set on the worker, so later ones (chainsaw,
-- telehandler) are just another CERTIFICATIONS entry.
--
-- Getting certified: a worker is ready once their skill for it (cropCare)
-- is at least readySkill. The business books them on a course - from the
-- Staff tab, or by answering the worker's own request in the inbox - and
-- pays for it up front under MoneyType.TC_TRAINING, 25% off for trade
-- association members (053). The course is courseDays days in a row, then
-- an assessment day ASSESSMENT_GAP_MIN-MAX days after it. The worker is
-- STATUS.TRAINING on those days and can't be allocated. They pass with a
-- chance that climbs with the skill; a fail leaves them with the course
-- done (retakeCerts), so the next booking is just another assessment day
-- at the cheaper retake price.
--
-- Dates are monotonic days, booked BOOKING_LEAD_DAYS ahead and after any
-- holiday they've already booked (and holidays aren't booked while
-- training is). A worker due in who's still out on a job, driving, off sick
-- or on holiday misses the day: they go as soon as they're set idle that
-- day (Staff:setWorkerStatus), otherwise the rest of the schedule slides
-- back a day at a time until they're free - training never pulls anyone off
-- a job.
--
-- Requests: each period, every ready, uncertified hired worker with
-- nothing booked has REQUEST_CHANCE of asking for it, as an inbox message
-- (050) that expires after a period. Turning it down or letting it expire
-- adds to their declinedRequests and knocks their morale (056).
--
-- Everything lives on the workers and is saved and streamed with them
-- (Staff.lua), so this subsystem's own save/sync methods are stubs.

TheContractorTraining = {}
TheContractorTraining_mt = Class(TheContractorTraining)

-- skill: the operation skill (044) that makes a worker ready and drives
-- the pass chance. Costs are 1x UK: the spraying course is PA1 (200) plus
-- PA2 (450) including the assessment; a retake is the PA2 part only.
TheContractorTraining.CERTIFICATIONS = {
    spraying = {
        skill = "cropCare",
        readySkill = 4,
        courseCost = 650,
        retakeCost = 450,
        courseDays = 2,
    },
}
-- Display order.
TheContractorTraining.CERTIFICATION_KEYS = { "spraying" }

-- Days between the course's last day and the assessment.
TheContractorTraining.ASSESSMENT_GAP_MIN = 2
TheContractorTraining.ASSESSMENT_GAP_MAX = 5
-- The first day booked is at least this many days from today.
TheContractorTraining.BOOKING_LEAD_DAYS = 2

-- Pass chance: PASS_CHANCE_MIN at readySkill, PASS_CHANCE_MAX at the top skill.
TheContractorTraining.PASS_CHANCE_MIN = 0.7
TheContractorTraining.PASS_CHANCE_MAX = 0.98

-- Per period, per ready and uncertified hired worker.
TheContractorTraining.REQUEST_CHANCE = 0.2

-- Saves from before 054: hired workers this good get the certificate free.
TheContractorTraining.GRANDFATHER_SKILL = 6
-- New candidates: 0 below CANDIDATE_MIN_SKILL, then rising linearly to
-- CANDIDATE_MAX_CHANCE at the top skill (10% at 4, 70% at 10).
TheContractorTraining.CANDIDATE_MIN_SKILL = 4
TheContractorTraining.CANDIDATE_MAX_CHANCE = 0.7

TheContractorTraining.MESSAGE_KIND = "training"
TheContractorTraining.MESSAGE_TYPE = {
    REQUEST = "request",
    RETAKE = "retake",
}
TheContractorTraining.ACTION = {
    BOOK = "book",
    NOT_NOW = "notNow",
}

-- What TCWorkerTrainingChangedEvent tells the farm about.
TheContractorTraining.NOTIFY = {
    NONE = 0,
    BOOKED = 1,
    PASSED = 2,
    FAILED = 3,
    CANNOT_AFFORD = 4,
}

-- Why a worker can't be booked (tc_training_problem_<value>).
TheContractorTraining.PROBLEM = {
    CERTIFIED = "certified",
    BOOKED = "booked",
    NOT_READY = "notReady",
    CANNOT_AFFORD = "cannotAfford",
}

table.insert(FinanceStats.statNames, "tcTraining")
FinanceStats.statNameToIndex["tcTraining"] = #FinanceStats.statNames

function TheContractorTraining.new()
    local self = {}
    setmetatable(self, TheContractorTraining_mt)

    MoneyType.TC_TRAINING = MoneyType.register("tcTraining", "tc_moneyType_training")
    MoneyType.LAST_ID = MoneyType.LAST_ID + 1

    return self
end

-- Every machine, at load, once the Inbox exists.
function TheContractorTraining:register(inbox)
    inbox:registerMessageKind(TheContractorTraining.MESSAGE_KIND, {
        onAction = function(farmId, message, actionKey)
            self:onMessageAnswered(farmId, message, actionKey)
        end,
        onExpire = function(farmId, message)
            self:onMessageExpired(farmId, message)
        end,
        chipKey = "tc_inbox_chipTraining",
        chipTone = "info",
    })
end

-- Query API (every machine) ---------------------------------------------------

function TheContractorTraining.getDefinition(cert)
    return TheContractorTraining.CERTIFICATIONS[cert]
end

function TheContractorTraining.isReady(worker, cert)
    local definition = TheContractorTraining.getDefinition(cert)
    return definition ~= nil and worker:getSkill(definition.skill) >= definition.readySkill
end

function TheContractorTraining.isRetake(worker, cert)
    return worker.retakeCerts[cert] == true
end

-- What booking the worker's next step costs the farm: the course, or the
-- retake after a failed assessment, less any association discount (053).
function TheContractorTraining.getPrice(farmId, worker, cert)
    local definition = TheContractorTraining.getDefinition(cert)
    local base = TheContractorTraining.isRetake(worker, cert) and definition.retakeCost or definition.courseCost
    return base * (1 - g_currentMission.TheContractor.Association:getCertificationDiscount(farmId))
end

-- Prices aren't always whole (487.50 for members), so show pence then.
function TheContractorTraining.formatPrice(amount)
    local precision = math.abs(amount - math.floor(amount)) > 0.001 and 2 or 0
    return g_i18n:formatMoney(amount, precision, true, true)
end

-- nil if the worker could be booked now (money aside), else a PROBLEM.
function TheContractorTraining.getBookingProblem(worker, cert)
    if worker:hasCertification(cert) then
        return TheContractorTraining.PROBLEM.CERTIFIED
    end
    if worker:hasTrainingBooked() then
        return TheContractorTraining.PROBLEM.BOOKED
    end
    if not TheContractorTraining.isReady(worker, cert) then
        return TheContractorTraining.PROBLEM.NOT_READY
    end
    return nil
end

function TheContractorTraining.canAfford(farmId, amount)
    local farm = g_farmManager:getFarmById(farmId)
    return farm ~= nil and farm:getBalance() >= amount
end

-- 0-1, from PASS_CHANCE_MIN at readySkill up to PASS_CHANCE_MAX at the top.
function TheContractorTraining.getPassChance(worker, cert)
    local definition = TheContractorTraining.getDefinition(cert)
    local span = TheContractorWorker.MAX_SKILL - definition.readySkill
    local t = math.max(0, math.min(1, (worker:getSkill(definition.skill) - definition.readySkill) / span))
    return TheContractorTraining.PASS_CHANCE_MIN +
        t * (TheContractorTraining.PASS_CHANCE_MAX - TheContractorTraining.PASS_CHANCE_MIN)
end

-- The first day a booking made today would start: BOOKING_LEAD_DAYS from
-- now, or the day after a holiday they've booked if that's later. Every
-- machine works it out the same way, so the confirm dialog can show it.
function TheContractorTraining.getFirstBookableDay(worker)
    local firstDay = g_currentMission.environment.currentMonotonicDay + TheContractorTraining.BOOKING_LEAD_DAYS
    if worker:hasHolidayBooked() then
        firstDay = math.max(firstDay, worker:getHolidayEndDay() + 1)
    end
    return firstDay
end

-- The course's dates, as text: "June 10-11, Year 2". nil for a retake
-- (no course) or nothing booked.
function TheContractorTraining.formatCourseDates(worker)
    if worker.trainingCert == nil or worker.courseDaysLeft <= 0 then
        return nil
    end
    return TCCalendar.formatDayRange(worker.trainingDay, worker.trainingDay + worker.courseDaysLeft - 1)
end

function TheContractorTraining.getCertName(cert)
    return g_i18n:getText("tc_cert_" .. cert)
end

-- Certificates at creation (server) ---------------------------------------------

-- A new candidate (Staff:addCandidateToPool) may already hold certificates.
function TheContractorTraining.rollCandidateCertifications(worker)
    for _, cert in ipairs(TheContractorTraining.CERTIFICATION_KEYS) do
        local definition = TheContractorTraining.getDefinition(cert)
        local skill = worker:getSkill(definition.skill)
        local minSkill = TheContractorTraining.CANDIDATE_MIN_SKILL
        if skill >= minSkill then
            local t = (skill - minSkill + 1) / (TheContractorWorker.MAX_SKILL - minSkill + 1)
            if math.random() < TheContractorTraining.CANDIDATE_MAX_CHANCE * t then
                worker.certifications[cert] = true
            end
        end
    end
end

-- A worker from a save made before 054 (Staff:loadFromXMLFile): a skilled
-- hired worker gets the certificate free, so herbicide work they were
-- already doing doesn't stop; a candidate is rolled like a new one.
function TheContractorTraining.grandfather(worker)
    if worker.farmId == nil then
        TheContractorTraining.rollCandidateCertifications(worker)
        return
    end

    for _, cert in ipairs(TheContractorTraining.CERTIFICATION_KEYS) do
        local definition = TheContractorTraining.getDefinition(cert)
        if worker:getSkill(definition.skill) >= TheContractorTraining.GRANDFATHER_SKILL then
            worker.certifications[cert] = true
            Logging.info("TheContractor: farm %d worker %d (%s) given the %s certificate (from before 054)",
                worker.farmId, worker.id, worker.name, cert)
        end
    end
end

-- Booking (server-authoritative) ---------------------------------------------------

-- TCBookTrainingEvent's server side, and the inbox's "Book it". Re-checks
-- everything, charges the price and books the next step. Returns true, or
-- false and a PROBLEM.
function TheContractorTraining:requestBooking(farmId, workerId, cert)
    if not g_currentMission:getIsServer() then
        return false, nil
    end

    local worker = g_currentMission.TheContractor.Staff:getWorker(farmId, workerId)
    if worker == nil or TheContractorTraining.getDefinition(cert) == nil then
        return false, nil
    end

    local problem = TheContractorTraining.getBookingProblem(worker, cert)
    if problem ~= nil then
        return false, problem
    end

    local price = TheContractorTraining.getPrice(farmId, worker, cert)
    if not TheContractorTraining.canAfford(farmId, price) then
        self:sendTrainingChanged(worker, TheContractorTraining.NOTIFY.CANNOT_AFFORD, cert, price)
        return false, TheContractorTraining.PROBLEM.CANNOT_AFFORD
    end

    g_currentMission:addMoney(-price, farmId, MoneyType.TC_TRAINING, true, true)
    g_currentMission.TheContractor.Finances:recordTraining(farmId, price)

    self:bookTraining(worker, cert, TheContractorTraining.getFirstBookableDay(worker))
    return true
end

-- Books the next step from firstDay - the course and then the assessment,
-- or for a retake just the assessment - and tells everyone. Charges
-- nothing and checks nothing, so it's also the tcWorker train console
-- command's way in.
function TheContractorTraining:bookTraining(worker, cert, firstDay)
    local definition = TheContractorTraining.getDefinition(cert)

    worker.trainingCert = cert
    if TheContractorTraining.isRetake(worker, cert) then
        worker.courseDaysLeft = 0
        worker.trainingDay = nil
        worker.assessmentDay = firstDay
    else
        worker.courseDaysLeft = definition.courseDays
        worker.trainingDay = firstDay
        worker.assessmentDay = firstDay + definition.courseDays - 1 +
            math.random(TheContractorTraining.ASSESSMENT_GAP_MIN, TheContractorTraining.ASSESSMENT_GAP_MAX)
    end

    Logging.info("TheContractor: farm %d worker %d (%s) booked for %s training: %d course day(s) from day %s, assessment day %d",
        worker.farmId, worker.id, worker.name, cert, worker.courseDaysLeft, tostring(worker.trainingDay),
        worker.assessmentDay)

    -- Any request still waiting in the inbox has been answered.
    self:removeMessagesFor(worker.farmId, worker.id)

    self:sendTrainingChanged(worker, TheContractorTraining.NOTIFY.BOOKED, cert, 0)

    -- Booked for today (console command): in they go, if they're free.
    if worker:getTrainingDueDay() == g_currentMission.environment.currentMonotonicDay and worker:isIdle() then
        g_currentMission.TheContractor.Staff:setWorkerStatus(worker.farmId, worker.id,
            TheContractorWorker.STATUS.TRAINING)
    end
end

-- Daily tick (server-only, from Staff:onDayChanged) ------------------------------

function TheContractorTraining:onDayChanged()
    if not g_currentMission:getIsServer() then
        return
    end

    local staff = g_currentMission.TheContractor.Staff
    local today = g_currentMission.environment.currentMonotonicDay

    for _, farmWorkers in pairs(staff.workersByFarm) do
        -- Collected first: setting a worker idle can retire them, which
        -- takes them off the roster mid-loop.
        local workers = {}
        for _, worker in pairs(farmWorkers) do
            if worker:hasTrainingBooked() or worker.status == TheContractorWorker.STATUS.TRAINING then
                table.insert(workers, worker)
            end
        end

        for _, worker in ipairs(workers) do
            self:updateWorker(worker, today)
        end
    end
end

-- Counts yesterday's attendance, slides a missed day, then puts the worker
-- in or out of training for today.
function TheContractorTraining:updateWorker(worker, today)
    local changed = false

    if worker.status == TheContractorWorker.STATUS.TRAINING and worker:hasTrainingBooked() then
        if worker.courseDaysLeft > 0 then
            -- The course runs on consecutive days.
            worker.courseDaysLeft = worker.courseDaysLeft - 1
            worker.trainingDay = worker.courseDaysLeft > 0 and today or nil
            changed = true
        else
            self:resolveAssessment(worker)
        end
    end

    if worker:hasTrainingBooked() then
        local dueDay = worker:getTrainingDueDay()
        if dueDay < today then
            -- They were busy all day: the rest of the schedule moves back.
            local shift = today - dueDay
            if worker.courseDaysLeft > 0 then
                worker.trainingDay = worker.trainingDay + shift
            end
            worker.assessmentDay = worker.assessmentDay + shift
            changed = true
            Logging.info("TheContractor: farm %d worker %d (%s) missed a training day (%s), moved back %d day(s)",
                worker.farmId, worker.id, worker.name, worker.status, shift)
        end
    end

    if changed then
        self:sendTrainingChanged(worker, TheContractorTraining.NOTIFY.NONE)
    end

    local staff = g_currentMission.TheContractor.Staff
    if worker:hasTrainingBooked() and worker:getTrainingDueDay() == today then
        if worker:isIdle() then
            staff:setWorkerStatus(worker.farmId, worker.id, TheContractorWorker.STATUS.TRAINING)
        end
    elseif worker.status == TheContractorWorker.STATUS.TRAINING then
        staff:setWorkerStatus(worker.farmId, worker.id, TheContractorWorker.STATUS.IDLE)
    end
end

-- For Staff:setWorkerStatus: a worker set idle on a day they're due in
-- goes to training instead.
function TheContractorTraining.isDueToday(worker)
    return worker:hasTrainingBooked() and
        worker:getTrainingDueDay() == g_currentMission.environment.currentMonotonicDay
end

-- They sat the assessment yesterday: pass or fail, and the booking's done.
function TheContractorTraining:resolveAssessment(worker)
    local cert = worker.trainingCert
    local chance = TheContractorTraining.getPassChance(worker, cert)
    local passed = math.random() < chance
    if worker.forcedAssessmentResult ~= nil then
        passed = worker.forcedAssessmentResult == "pass"
        worker.forcedAssessmentResult = nil
    end

    worker.trainingCert = nil
    worker.courseDaysLeft = 0
    worker.trainingDay = nil
    worker.assessmentDay = nil

    Logging.info("TheContractor: farm %d worker %d (%s) %s the %s assessment (chance %.2f)", worker.farmId,
        worker.id, worker.name, passed and "passed" or "failed", cert, chance)

    if passed then
        worker.certifications[cert] = true
        worker.retakeCerts[cert] = nil
        self:sendTrainingChanged(worker, TheContractorTraining.NOTIFY.PASSED, cert, 0)
        return
    end

    worker.retakeCerts[cert] = true
    self:sendTrainingChanged(worker, TheContractorTraining.NOTIFY.FAILED, cert, 0)

    -- The retake can be booked straight from the inbox.
    local price = TheContractorTraining.getPrice(worker.farmId, worker, cert)
    g_currentMission.TheContractor.Inbox:postMessage(worker.farmId, TheContractorTraining.MESSAGE_KIND,
        "tc_training_failedTitle", "tc_training_failedBody",
        { worker.name, "$l10n_tc_cert_" .. cert, "$money_" .. price },
        {
            { key = TheContractorTraining.ACTION.BOOK, textKey = "tc_training_bookRetakeButton" },
            { key = TheContractorTraining.ACTION.NOT_NOW, textKey = "tc_training_notNowButton" },
        },
        { workerId = worker.id, cert = cert, type = TheContractorTraining.MESSAGE_TYPE.RETAKE },
        g_currentMission.environment.daysPerPeriod)
end

-- Requests (server-only, from Staff:onPeriodChanged) ----------------------------

function TheContractorTraining:onPeriodChanged()
    if not g_currentMission:getIsServer() then
        return
    end

    local staff = g_currentMission.TheContractor.Staff
    for farmId, farmWorkers in pairs(staff.workersByFarm) do
        for _, worker in pairs(farmWorkers) do
            for _, cert in ipairs(TheContractorTraining.CERTIFICATION_KEYS) do
                if self:canRequest(worker, cert) and math.random() < TheContractorTraining.REQUEST_CHANCE then
                    self:postRequest(farmId, worker, cert)
                end
            end
        end
    end
end

-- Ready, uncertified, nothing booked, not leaving, and not already asking.
function TheContractorTraining:canRequest(worker, cert)
    return TheContractorTraining.getBookingProblem(worker, cert) == nil and not worker:isLeaving() and
        self:findMessage(worker.farmId, worker.id) == nil
end

-- Also the tcWorker askTraining console command's way in.
function TheContractorTraining:postRequest(farmId, worker, cert)
    local definition = TheContractorTraining.getDefinition(cert)
    local price = TheContractorTraining.getPrice(farmId, worker, cert)
    local isRetake = TheContractorTraining.isRetake(worker, cert)

    Logging.info("TheContractor: farm %d worker %d (%s) asked for %s training", farmId, worker.id, worker.name, cert)

    g_currentMission.TheContractor.Inbox:postMessage(farmId, TheContractorTraining.MESSAGE_KIND,
        "tc_training_requestTitle", isRetake and "tc_training_requestBodyRetake" or "tc_training_requestBody",
        { worker.name, "$l10n_tc_cert_" .. cert, "$money_" .. price, definition.courseDays },
        {
            { key = TheContractorTraining.ACTION.BOOK, textKey = "tc_training_bookItButton" },
            { key = TheContractorTraining.ACTION.NOT_NOW, textKey = "tc_training_notNowButton" },
        },
        { workerId = worker.id, cert = cert, type = TheContractorTraining.MESSAGE_TYPE.REQUEST },
        g_currentMission.environment.daysPerPeriod)
end

-- The worker's training message in the farm's inbox, if there is one.
function TheContractorTraining:findMessage(farmId, workerId)
    for _, message in ipairs(g_currentMission.TheContractor.Inbox:getMessages(farmId)) do
        if message.kind == TheContractorTraining.MESSAGE_KIND and message.payload.workerId == workerId then
            return message
        end
    end
    return nil
end

-- Once they're booked, or gone from the roster.
function TheContractorTraining:removeMessagesFor(farmId, workerId)
    local inbox = g_currentMission.TheContractor.Inbox
    for _, message in ipairs(inbox:getMessages(farmId)) do
        if message.kind == TheContractorTraining.MESSAGE_KIND and message.payload.workerId == workerId then
            inbox:removeMessage(message.id)
        end
    end
end

function TheContractorTraining:onMessageAnswered(farmId, message, actionKey)
    local worker = g_currentMission.TheContractor.Staff:getWorker(farmId, message.payload.workerId)
    if worker == nil then
        return
    end

    if actionKey == TheContractorTraining.ACTION.BOOK then
        self:requestBooking(farmId, worker.id, message.payload.cert)
    elseif actionKey == TheContractorTraining.ACTION.NOT_NOW then
        self:recordDecline(worker, message)
    end
end

function TheContractorTraining:onMessageExpired(farmId, message)
    local worker = g_currentMission.TheContractor.Staff:getWorker(farmId, message.payload.workerId)
    if worker ~= nil then
        self:recordDecline(worker, message)
    end
end

-- Only the worker's own requests count - not passing on a retake offer.
function TheContractorTraining:recordDecline(worker, message)
    if message.payload.type ~= TheContractorTraining.MESSAGE_TYPE.REQUEST then
        return
    end

    worker.declinedRequests = worker.declinedRequests + 1
    Logging.info("TheContractor: farm %d worker %d (%s) training request declined (%d so far)", worker.farmId,
        worker.id, worker.name, worker.declinedRequests)
    self:sendTrainingChanged(worker, TheContractorTraining.NOTIFY.NONE)

    -- 056: it's a knock to their morale.
    g_currentMission.TheContractor.Morale:onRequestDeclined(worker)
end

-- Sync --------------------------------------------------------------------------

-- Broadcasts the worker's whole training state, after showing the host's
-- own notification (the broadcast doesn't loop back to it). cert and amount
-- are only for the notification.
function TheContractorTraining:sendTrainingChanged(worker, notify, cert, amount)
    cert = cert or ""
    amount = amount or 0
    TCWorkerTrainingChangedEvent.showNotification(worker, notify, cert, amount)

    if g_server ~= nil then
        g_server:broadcastEvent(TCWorkerTrainingChangedEvent.new(worker, notify, cert, amount))
    end
end

-- The visible state, shared by the worker stream (Staff.writeWorker) and
-- TCWorkerTrainingChangedEvent. Days 0 = none (monotonic days start at 1).

local function writeSet(streamId, set)
    local keys = {}
    for key in pairs(set) do
        table.insert(keys, key)
    end
    table.sort(keys)
    streamWriteUInt8(streamId, #keys)
    for _, key in ipairs(keys) do
        streamWriteString(streamId, key)
    end
end

local function readSet(streamId)
    local set = {}
    for _ = 1, streamReadUInt8(streamId) do
        set[streamReadString(streamId)] = true
    end
    return set
end

function TheContractorTraining.writeState(streamId, worker)
    writeSet(streamId, worker.certifications)
    writeSet(streamId, worker.retakeCerts)
    streamWriteString(streamId, worker.trainingCert or "")
    streamWriteUInt8(streamId, worker.courseDaysLeft)
    streamWriteInt32(streamId, worker.trainingDay or 0)
    streamWriteInt32(streamId, worker.assessmentDay or 0)
    streamWriteInt32(streamId, worker.declinedRequests)
end

function TheContractorTraining.readState(streamId)
    local state = {
        certifications = readSet(streamId),
        retakeCerts = readSet(streamId),
        trainingCert = streamReadString(streamId),
        courseDaysLeft = streamReadUInt8(streamId),
        trainingDay = streamReadInt32(streamId),
        assessmentDay = streamReadInt32(streamId),
        declinedRequests = streamReadInt32(streamId),
    }
    if state.trainingCert == "" then
        state.trainingCert = nil
    end
    if state.trainingDay == 0 then
        state.trainingDay = nil
    end
    if state.assessmentDay == 0 then
        state.assessmentDay = nil
    end
    return state
end

function TheContractorTraining.applyState(worker, state)
    worker.certifications = state.certifications
    worker.retakeCerts = state.retakeCerts
    worker.trainingCert = state.trainingCert
    worker.courseDaysLeft = state.courseDaysLeft
    worker.trainingDay = state.trainingDay
    worker.assessmentDay = state.assessmentDay
    worker.declinedRequests = state.declinedRequests
end

-- Worker XML (Staff.writeWorkerXML/readWorkerXML). Sets are space-separated
-- keys, left out when empty.

local function setToString(set)
    local keys = {}
    for key in pairs(set) do
        table.insert(keys, key)
    end
    table.sort(keys)
    return table.concat(keys, " ")
end

local function stringToSet(text)
    local set = {}
    for key in string.gmatch(text or "", "%S+") do
        if TheContractorTraining.CERTIFICATIONS[key] ~= nil then
            set[key] = true
        end
    end
    return set
end

function TheContractorTraining.writeXML(xmlFile, key, worker)
    local certifications = setToString(worker.certifications)
    if certifications ~= "" then
        setXMLString(xmlFile, key .. "#certifications", certifications)
    end
    local retakeCerts = setToString(worker.retakeCerts)
    if retakeCerts ~= "" then
        setXMLString(xmlFile, key .. "#retakeCerts", retakeCerts)
    end
    if worker:hasTrainingBooked() then
        setXMLString(xmlFile, key .. "#trainingCert", worker.trainingCert)
        setXMLInt(xmlFile, key .. "#courseDaysLeft", worker.courseDaysLeft)
        if worker.trainingDay ~= nil then
            setXMLInt(xmlFile, key .. "#trainingDay", worker.trainingDay)
        end
        setXMLInt(xmlFile, key .. "#assessmentDay", worker.assessmentDay)
    end
    if worker.declinedRequests > 0 then
        setXMLInt(xmlFile, key .. "#declinedRequests", worker.declinedRequests)
    end
end

function TheContractorTraining.readXML(xmlFile, key, worker)
    worker.certifications = stringToSet(getXMLString(xmlFile, key .. "#certifications"))
    worker.retakeCerts = stringToSet(getXMLString(xmlFile, key .. "#retakeCerts"))
    worker.declinedRequests = getXMLInt(xmlFile, key .. "#declinedRequests") or 0

    local cert = getXMLString(xmlFile, key .. "#trainingCert")
    local courseDaysLeft = getXMLInt(xmlFile, key .. "#courseDaysLeft") or 0
    local trainingDay = getXMLInt(xmlFile, key .. "#trainingDay")
    local assessmentDay = getXMLInt(xmlFile, key .. "#assessmentDay")
    if cert ~= nil and TheContractorTraining.CERTIFICATIONS[cert] ~= nil and assessmentDay ~= nil and
            (courseDaysLeft == 0 or trainingDay ~= nil) then
        worker.trainingCert = cert
        worker.courseDaysLeft = courseDaysLeft
        worker.trainingDay = courseDaysLeft > 0 and trainingDay or nil
        worker.assessmentDay = assessmentDay
    end
end

-- Persistence (nothing of its own - see the header) ---------------------------------

function TheContractorTraining:loadFromXMLFile(xmlFile)
end

function TheContractorTraining:saveToXmlFile(xmlFile)
end

function TheContractorTraining:writeInitialClientState(streamId, connection)
end

function TheContractorTraining:readInitialClientState(streamId, connection)
end

-- Console commands (tcWorker - see TCConsole) ------------------------------------------
-- They work on the spraying certificate, the only one so far.

function TheContractorTraining.registerConsoleCommands()
    TCConsole.register("worker", "train", {
        args = "<worker> [daysFromNow=0] [pass|fail]",
        description = "Book spraying training for free, skipping the readiness check",
        run = function(farmId, args)
            local worker, problem = TCConsole.findWorker(farmId, args[1])
            if worker == nil then
                return problem or false
            end
            local daysFromNow = TCConsole.toCount(args[2], 0)
            local result = args[3] ~= nil and string.lower(args[3]) or nil
            if daysFromNow == nil or (result ~= nil and result ~= "pass" and result ~= "fail") then
                return false
            end

            local cert = "spraying"
            if worker:hasCertification(cert) then
                return string.format("%s is already certified (tcWorker certify %d off to take it away)", worker.name,
                    worker.id)
            end
            if worker:hasTrainingBooked() then
                return string.format("%s already has training booked", worker.name)
            end

            worker.forcedAssessmentResult = result
            g_currentMission.TheContractor.Training:bookTraining(worker, cert,
                g_currentMission.environment.currentMonotonicDay + daysFromNow)

            local courseDates = TheContractorTraining.formatCourseDates(worker)
            return string.format("%s booked: %s, assessment %s%s", worker.name,
                courseDates ~= nil and ("course " .. courseDates) or "retake, no course",
                TCCalendar.formatDay(worker.assessmentDay), result ~= nil and (", will " .. result) or "")
        end,
    })

    TCConsole.register("worker", "askTraining", {
        args = "<worker>",
        description = "Make a worker ask for spraying training through the inbox now",
        run = function(farmId, args)
            local worker, problem = TCConsole.findWorker(farmId, args[1])
            if worker == nil then
                return problem or false
            end

            local training = g_currentMission.TheContractor.Training
            local cert = "spraying"
            local bookingProblem = TheContractorTraining.getBookingProblem(worker, cert)
            if bookingProblem ~= nil then
                return string.format("%s can't ask: %s", worker.name, bookingProblem)
            end
            if training:findMessage(worker.farmId, worker.id) ~= nil then
                return string.format("%s already has a training message in the inbox", worker.name)
            end

            training:postRequest(worker.farmId, worker, cert)
            return string.format("%s asked for spraying training", worker.name)
        end,
    })

    TCConsole.register("worker", "certify", {
        args = "<worker> [on|off]",
        description = "Give a worker the spraying certificate, or take it away",
        run = function(farmId, args)
            local worker, problem = TCConsole.findWorker(farmId, args[1])
            if worker == nil then
                return problem or false
            end
            local state = args[2] ~= nil and string.lower(args[2]) or "on"
            if state ~= "on" and state ~= "off" then
                return false
            end

            local certified = state == "on"
            worker.certifications.spraying = certified or nil
            if certified then
                worker.retakeCerts.spraying = nil
            end
            g_currentMission.TheContractor.Training:sendTrainingChanged(worker, TheContractorTraining.NOTIFY.NONE)
            return string.format("%s is %s certified for spraying", worker.name, certified and "now" or "no longer")
        end,
    })
end
