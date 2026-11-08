-- Botched jobs and compensation claims (052). Now and then a hired worker
-- botches a job - spray drift onto the next crop, the wrong rate, ruts and
-- compaction - and the customer claims for the damage. Rolled once per
-- worker when the job completes (server, from Jobs:completeJob): the player
-- driving it themselves never botches, nor do the job types in
-- EXEMPT_JOB_TYPES. The chance comes from the worker's cleanliness (045, as
-- carelessness) and how far their operation skill falls short of the job's
-- requirement (044):
--
--   BASE_CHANCE + CARELESS_CHANCE * (10 - cleanliness) / 9
--               + CHANCE_PER_SKILL_POINT * operation gap
--
-- so a good worker almost never does, a careless and under-qualified one
-- about one job in 20. At most one claim per job.
--
-- The claim (field ha * CLAIM_PER_HA * 0.5-1.5, written at 1x UK and scaled
-- by TheContractorSettings:scaleCost, as is EXCESS) arrives CLAIM_DELAY_MIN-MAX days later as an inbox message
-- (050) and an Overview notice (038), with a reputation hit. Until then
-- it's a pending claim: server-only, saved, never streamed.
--
-- Public liability insurance is an optional overhead (051) registered here.
-- Cover is judged when the job's done, as real occurrence-based policies
-- are: insured, the farm pays EXCESS and the claim goes on its claims
-- history; uninsured, it pays the lot (even into the red). The premium is
-- PL_BASE + PL_PER_WORKER per hired worker, plus CLAIMS_LOADING per claim
-- in the last CLAIMS_WINDOW_PERIODS. The history is synced to clients,
-- since they price the policy for the Finances tab.

TheContractorClaims = {}
TheContractorClaims_mt = Class(TheContractorClaims)

TheContractorClaims.BASE_CHANCE = 0.005
TheContractorClaims.CARELESS_CHANCE = 0.015
TheContractorClaims.CHANCE_PER_SKILL_POINT = 0.005

-- Job types that can't damage the customer's crop or land.
TheContractorClaims.EXEMPT_JOB_TYPES = {
    stonePick = true,
    tedder = true,
}

-- Roughly a season's lost crop per hectare.
TheContractorClaims.CLAIM_PER_HA = 1000
TheContractorClaims.CLAIM_MIN_FACTOR = 0.5
TheContractorClaims.CLAIM_MAX_FACTOR = 1.5

-- Days between the job and the claim arriving.
TheContractorClaims.CLAIM_DELAY_MIN = 2
TheContractorClaims.CLAIM_DELAY_MAX = 7

TheContractorClaims.EXCESS = 500

-- Reputation lost, as a share of what the job earned (like a missed job,
-- 026), never less than the minimum. Insured or not.
TheContractorClaims.REPUTATION_PENALTY_MULTIPLIER = 1.5
TheContractorClaims.MIN_REPUTATION_PENALTY = 10

-- Public liability insurance (£5m cover).
TheContractorClaims.OVERHEAD_KEY = "publicLiability"
TheContractorClaims.PL_BASE = 800
TheContractorClaims.PL_PER_WORKER = 60
TheContractorClaims.CLAIMS_LOADING = 0.35
TheContractorClaims.CLAIMS_WINDOW_PERIODS = 36

TheContractorClaims.MESSAGE_KIND = "claim"
TheContractorClaims.NOTICE_MONTHS = 1

-- What went wrong, by job type: tc_claims_cause_<key>, one picked at random.
TheContractorClaims.CAUSES = {
    harvest = { "ruts", "boundary" },
    cultivate = { "ruts", "compaction" },
    plow = { "ruts", "compaction" },
    sow = { "rate", "compaction" },
    mow = { "boundary", "ruts" },
    bale = { "ruts", "boundary" },
    fertilize = { "rate", "scorch" },
    lime = { "rate", "ruts" },
    herbicide = { "drift", "rate" },
    weed = { "cropDamage" },
    hoe = { "cropDamage" },
}
TheContractorClaims.DEFAULT_CAUSES = { "ruts" }

table.insert(FinanceStats.statNames, "tcClaims")
FinanceStats.statNameToIndex["tcClaims"] = #FinanceStats.statNames

function TheContractorClaims.new()
    local self = {}
    setmetatable(self, TheContractorClaims_mt)

    -- pendingClaims[i] = { farmId, jobId, jobType, typeLabel, fieldId,
    -- workerName, cause, amount, insured, reputationPenalty, notifyDay } -
    -- server-only. typeLabel is the job's getTypeLabel(), what the message
    -- calls it ("plant" for a planted crop's sow job).
    self.pendingClaims = {}

    -- historyByFarm[farmId] = { { periodIndex, amount }, ... } - insured
    -- claims, for the premium loading. Synced to clients.
    self.historyByFarm = {}

    -- tcFinance botch: the next eligible worker botches. Server-only, not saved.
    self.forceBotch = nil

    MoneyType.TC_CLAIMS = MoneyType.register("tcClaims", "tc_moneyType_claims")
    MoneyType.LAST_ID = MoneyType.LAST_ID + 1

    return self
end

-- Every machine, at load, once Overheads and the Inbox exist.
function TheContractorClaims:register(overheads, inbox)
    overheads:registerOverhead({
        key = TheContractorClaims.OVERHEAD_KEY,
        l10nKey = "tc_overhead_publicLiability",
        mandatory = false,
        annualCost = function(farmId)
            return self:getPremium(farmId)
        end,
        getRenewalLoading = function(farmId)
            local count = self:getRecentClaimCount(farmId)
            return count, math.floor(count * TheContractorClaims.CLAIMS_LOADING * 100 + 0.5)
        end,
        descriptionAmounts = { TheContractorClaims.EXCESS, TheContractorClaims.PL_BASE,
            TheContractorClaims.PL_PER_WORKER },
    })

    inbox:registerMessageKind(TheContractorClaims.MESSAGE_KIND, {
        category = "claim",
        chipTone = "bad",
    })
end

-- Premium and history ---------------------------------------------------------

-- Insured claims in the last CLAIMS_WINDOW_PERIODS, this period included.
function TheContractorClaims:getRecentClaimCount(farmId)
    local firstPeriod = TCCalendar.getPeriodIndex() - TheContractorClaims.CLAIMS_WINDOW_PERIODS + 1
    local count = 0
    for _, claim in ipairs(self.historyByFarm[farmId] or {}) do
        if claim.periodIndex >= firstPeriod then
            count = count + 1
        end
    end
    return count
end

-- Public liability's yearly price right now (1x UK - Overheads scales it).
function TheContractorClaims:getPremium(farmId)
    local headcount = #g_currentMission.TheContractor.Staff:getRoster(farmId)
    local base = TheContractorClaims.PL_BASE + TheContractorClaims.PL_PER_WORKER * headcount
    return base * (1 + TheContractorClaims.CLAIMS_LOADING * self:getRecentClaimCount(farmId))
end

function TheContractorClaims:isInsured(farmId)
    return g_currentMission.TheContractor.Overheads:isActive(farmId, TheContractorClaims.OVERHEAD_KEY)
end

function TheContractorClaims:applyClaimRecorded(farmId, claim)
    if self.historyByFarm[farmId] == nil then
        self.historyByFarm[farmId] = {}
    end
    table.insert(self.historyByFarm[farmId], claim)
end

-- The botch roll (server-only) -------------------------------------------------

function TheContractorClaims.getBotchChance(worker, operationGap)
    local minC, maxC = TheContractorWorker.MIN_CLEANLINESS, TheContractorWorker.MAX_CLEANLINESS
    local carelessness = (maxC - math.max(minC, math.min(maxC, worker.cleanliness))) / (maxC - minC)
    return TheContractorClaims.BASE_CHANCE + TheContractorClaims.CARELESS_CHANCE * carelessness +
        TheContractorClaims.CHANCE_PER_SKILL_POINT * operationGap
end

-- From Jobs:completeJob, while the workers are still on the job.
function TheContractorClaims:rollForJob(job)
    if not g_currentMission:getIsServer() or TheContractorClaims.EXEMPT_JOB_TYPES[job.jobType] then
        return
    end

    local tc = g_currentMission.TheContractor
    for _, member in ipairs(TCJobConsequences.getCrew(job)) do
        local worker = tc.Staff:getWorker(job.farmId, member.workerId)
        if worker ~= nil then
            local ratings = tc.Allocation:getWorkerJobRatings(worker, job, member.equipmentIds, member.isHauler)
            local operationGap = ratings.operationRating ~= nil and
                math.max(0, job.requiredSkillLevel - ratings.operationRating) or 0
            local chance = TheContractorClaims.getBotchChance(worker, operationGap)
            local roll = math.random()

            local forced = self.forceBotch ~= nil
            TCLog.info("TheContractor: farm %d job %d worker %d (%s) botch roll %.3f vs %.3f (cleanliness %d, gap %d)%s",
                job.farmId, job.id, worker.id, worker.name, roll, chance, worker.cleanliness, operationGap,
                forced and " - forced" or "")

            if forced or roll < chance then
                local delayDays = forced and self.forceBotch.delayDays or nil
                self.forceBotch = nil
                self:createPendingClaim(job, worker, delayDays)
                return
            end
        end
    end
end

function TheContractorClaims:createPendingClaim(job, worker, delayDays)
    local field = g_fieldManager:getFieldById(job.fieldId)
    local areaHa = field ~= nil and field:getAreaHa() or 1
    local factor = TheContractorClaims.CLAIM_MIN_FACTOR +
        math.random() * (TheContractorClaims.CLAIM_MAX_FACTOR - TheContractorClaims.CLAIM_MIN_FACTOR)
    local causes = TheContractorClaims.CAUSES[job.jobType] or TheContractorClaims.DEFAULT_CAUSES

    delayDays = delayDays or math.random(TheContractorClaims.CLAIM_DELAY_MIN, TheContractorClaims.CLAIM_DELAY_MAX)

    local claim = {
        farmId = job.farmId,
        jobId = job.id,
        jobType = job.jobType,
        typeLabel = job:getTypeLabel(),
        fieldId = job.fieldId,
        workerName = worker.name,
        cause = causes[math.random(#causes)],
        amount = g_currentMission.TheContractor.Settings:scaleCost(areaHa * TheContractorClaims.CLAIM_PER_HA * factor),
        insured = self:isInsured(job.farmId),
        reputationPenalty = math.floor(math.max(TheContractorClaims.MIN_REPUTATION_PENALTY,
            TheContractorJobs.getBaseReputationReward(job) * TheContractorClaims.REPUTATION_PENALTY_MULTIPLIER)),
        notifyDay = g_currentMission.environment.currentMonotonicDay + math.max(0, delayDays),
    }
    table.insert(self.pendingClaims, claim)

    TCLog.info("TheContractor: farm %d job %d botched by %s (%s): claim of %.0f arrives day %d (%s)",
        claim.farmId, claim.jobId, claim.workerName, claim.cause, claim.amount, claim.notifyDay,
        claim.insured and "insured" or "uninsured")
end

-- Claims arriving (server-only) ---------------------------------------------------

function TheContractorClaims:startDailyTick()
    if not g_currentMission:getIsServer() then
        return
    end
    g_messageCenter:subscribe(MessageType.DAY_CHANGED, self.onDayChanged, self)
end

function TheContractorClaims:stopDailyTick()
    g_messageCenter:unsubscribe(MessageType.DAY_CHANGED, self)
end

function TheContractorClaims:onDayChanged()
    local today = g_currentMission.environment.currentMonotonicDay
    local remaining = {}
    for _, claim in ipairs(self.pendingClaims) do
        if claim.notifyDay <= today then
            self:deliverClaim(claim)
        else
            table.insert(remaining, claim)
        end
    end
    self.pendingClaims = remaining
end

-- Charges a liability claim of amount (already scaled) to the farm: the
-- excess if insured, which also puts the claim on its history for the
-- premium loading, else the lot (even into the red). Returns what the farm
-- paid. Server-only; also used by 079's road accidents.
function TheContractorClaims:chargeClaim(farmId, amount, insured)
    local excess = g_currentMission.TheContractor.Settings:scaleCost(TheContractorClaims.EXCESS)
    local paid = insured and math.min(amount, excess) or amount
    g_currentMission:addMoney(-paid, farmId, MoneyType.TC_CLAIMS, true, true)
    g_currentMission.TheContractor.Finances:recordClaims(farmId, paid)

    if insured then
        local record = { periodIndex = TCCalendar.getPeriodIndex(), amount = amount }
        self:applyClaimRecorded(farmId, record)
        if g_server ~= nil then
            g_server:broadcastEvent(TCClaimRecordedEvent.new(farmId, record))
        end
    end
    return paid
end

-- Whether a botch claim from this job is still on its way (081 skips
-- a job that has one).
function TheContractorClaims:hasPendingClaimForJob(jobId)
    for _, claim in ipairs(self.pendingClaims) do
        if claim.jobId == jobId then
            return true
        end
    end
    return false
end

-- A claim that isn't the job's botch (079's accidents, 081's drift) on the
-- job's logbook entry (060), off its margin. The entry keeps one claim, so
-- one already there gets this one added to it: amounts and reputation
-- summed, its cause kept, insured only if both were. Server-only.
function TheContractorClaims:addToJobLog(farmId, jobId, claim)
    local logbook = g_currentMission.TheContractor.Logbook
    local entry = logbook:getJobEntry(farmId, jobId)
    if entry ~= nil and entry.claim ~= nil then
        claim = { cause = entry.claim.cause, amount = entry.claim.amount + claim.amount,
            paid = entry.claim.paid + claim.paid, insured = entry.claim.insured and claim.insured,
            reputationPenalty = (entry.claim.reputationPenalty or 0) + claim.reputationPenalty }
    end
    logbook:recordClaim(farmId, jobId, claim)
end

function TheContractorClaims:deliverClaim(claim)
    local tc = g_currentMission.TheContractor
    if g_farmManager:getFarmById(claim.farmId) == nil then
        return
    end

    local paid = self:chargeClaim(claim.farmId, claim.amount, claim.insured)

    tc.Reputation:addReputation(claim.farmId, -claim.reputationPenalty)

    -- 060: on the job's logbook entry, off its margin.
    tc.Logbook:recordClaim(claim.farmId, claim.jobId, { cause = claim.cause, amount = claim.amount, paid = paid,
        insured = claim.insured, reputationPenalty = claim.reputationPenalty })

    local args = {
        claim.fieldId,
        claim.workerName,
        "$l10n_tc_claims_cause_" .. claim.cause,
        "$l10n_tc_jobType_" .. (claim.typeLabel or claim.jobType),
        "$money_" .. claim.amount,
        "$money_" .. paid,
    }
    tc.Inbox:postMessage(claim.farmId, TheContractorClaims.MESSAGE_KIND, "tc_claims_title",
        claim.insured and "tc_claims_bodyInsured" or "tc_claims_bodyUninsured", args, nil,
        { jobId = claim.jobId, amount = claim.amount, paid = paid })

    tc.Notices:publish(claim.farmId, string.format(
        g_i18n:getText(claim.insured and "tc_claims_noticeInsured" or "tc_claims_noticeUninsured"),
        claim.fieldId, g_i18n:formatMoney(paid, 0, true, true)), TheContractorClaims.NOTICE_MONTHS)

    TCLog.info("TheContractor: farm %d claim for job %d delivered: %.0f claimed, %.0f paid (%s), -%d reputation",
        claim.farmId, claim.jobId, claim.amount, paid, claim.insured and "insured" or "uninsured",
        claim.reputationPenalty)
end

-- Wire serialization ----------------------------------------------------------------

function TheContractorClaims.writeRecord(streamId, record)
    streamWriteInt32(streamId, record.periodIndex)
    streamWriteFloat32(streamId, record.amount)
end

function TheContractorClaims.readRecord(streamId)
    return { periodIndex = streamReadInt32(streamId), amount = streamReadFloat32(streamId) }
end

-- Persistence -------------------------------------------------------------------------

-- A farm deleted in multiplayer (TCFarmDeletion), on every machine.
function TheContractorClaims:forgetFarm(farmId)
    self.historyByFarm[farmId] = nil
    local kept = {}
    for _, claim in ipairs(self.pendingClaims) do
        if claim.farmId ~= farmId then
            table.insert(kept, claim)
        end
    end
    self.pendingClaims = kept
end

function TheContractorClaims:loadFromXMLFile(xmlFile)
    if not g_currentMission:getIsServer() then return end

    self.pendingClaims = {}
    self.historyByFarm = {}

    local rootKey = string.format("%s.claims", TheContractor.SaveKey)

    local index = 0
    while true do
        local key = string.format("%s.pending(%d)", rootKey, index)
        if not hasXMLProperty(xmlFile, key) then
            break
        end
        table.insert(self.pendingClaims, {
            farmId = getXMLInt(xmlFile, key .. "#farmId"),
            jobId = Utils.getNoNil(getXMLInt(xmlFile, key .. "#jobId"), 0),
            jobType = Utils.getNoNil(getXMLString(xmlFile, key .. "#jobType"), "cultivate"),
            typeLabel = getXMLString(xmlFile, key .. "#typeLabel"),
            fieldId = Utils.getNoNil(getXMLInt(xmlFile, key .. "#fieldId"), 0),
            workerName = Utils.getNoNil(getXMLString(xmlFile, key .. "#workerName"), "?"),
            cause = Utils.getNoNil(getXMLString(xmlFile, key .. "#cause"), "ruts"),
            amount = Utils.getNoNil(getXMLFloat(xmlFile, key .. "#amount"), 0),
            insured = Utils.getNoNil(getXMLBool(xmlFile, key .. "#insured"), false),
            reputationPenalty = Utils.getNoNil(getXMLInt(xmlFile, key .. "#reputationPenalty"),
                TheContractorClaims.MIN_REPUTATION_PENALTY),
            notifyDay = Utils.getNoNil(getXMLInt(xmlFile, key .. "#notifyDay"), 0),
        })
        index = index + 1
    end

    index = 0
    while true do
        local key = string.format("%s.claim(%d)", rootKey, index)
        if not hasXMLProperty(xmlFile, key) then
            break
        end
        local farmId = getXMLInt(xmlFile, key .. "#farmId")
        if farmId ~= nil then
            self:applyClaimRecorded(farmId, {
                periodIndex = Utils.getNoNil(getXMLInt(xmlFile, key .. "#periodIndex"), 0),
                amount = Utils.getNoNil(getXMLFloat(xmlFile, key .. "#amount"), 0),
            })
        end
        index = index + 1
    end
end

-- Claims older than the loading window are dropped: nothing reads them.
function TheContractorClaims:saveToXmlFile(xmlFile)
    if not g_currentMission:getIsServer() then return end

    local rootKey = string.format("%s.claims", TheContractor.SaveKey)

    for i, claim in ipairs(self.pendingClaims) do
        local key = string.format("%s.pending(%d)", rootKey, i - 1)
        setXMLInt(xmlFile, key .. "#farmId", claim.farmId)
        setXMLInt(xmlFile, key .. "#jobId", claim.jobId)
        setXMLString(xmlFile, key .. "#jobType", claim.jobType)
        if claim.typeLabel ~= nil then
            setXMLString(xmlFile, key .. "#typeLabel", claim.typeLabel)
        end
        setXMLInt(xmlFile, key .. "#fieldId", claim.fieldId)
        setXMLString(xmlFile, key .. "#workerName", claim.workerName)
        setXMLString(xmlFile, key .. "#cause", claim.cause)
        setXMLFloat(xmlFile, key .. "#amount", claim.amount)
        setXMLBool(xmlFile, key .. "#insured", claim.insured)
        setXMLInt(xmlFile, key .. "#reputationPenalty", claim.reputationPenalty)
        setXMLInt(xmlFile, key .. "#notifyDay", claim.notifyDay)
    end

    local firstPeriod = TCCalendar.getPeriodIndex() - TheContractorClaims.CLAIMS_WINDOW_PERIODS + 1
    local index = 0
    for farmId, history in pairs(self.historyByFarm) do
        for _, record in ipairs(history) do
            if record.periodIndex >= firstPeriod then
                local key = string.format("%s.claim(%d)", rootKey, index)
                setXMLInt(xmlFile, key .. "#farmId", farmId)
                setXMLInt(xmlFile, key .. "#periodIndex", record.periodIndex)
                setXMLFloat(xmlFile, key .. "#amount", record.amount)
                index = index + 1
            end
        end
    end
end

-- The history only - pending claims stay on the server.
function TheContractorClaims:writeInitialClientState(streamId, connection)
    local entries = {}
    for farmId, history in pairs(self.historyByFarm) do
        for _, record in ipairs(history) do
            table.insert(entries, { farmId = farmId, record = record })
        end
    end

    streamWriteInt32(streamId, #entries)
    for _, entry in ipairs(entries) do
        streamWriteInt32(streamId, entry.farmId)
        TheContractorClaims.writeRecord(streamId, entry.record)
    end
end

function TheContractorClaims:readInitialClientState(streamId, connection)
    local count = streamReadInt32(streamId)
    for _ = 1, count do
        local farmId = streamReadInt32(streamId)
        self:applyClaimRecorded(farmId, TheContractorClaims.readRecord(streamId))
    end
end

-- Console commands (tcFinance - see TCConsole) -----------------------------------------

function TheContractorClaims.registerConsoleCommands()
    -- Server-only, since pending claims never reach clients.
    TCConsole.register("finance", "claims", {
        description = "Claims still to arrive, your claims in the last 3 years and the premium",
        run = function(farmId, args)
            local claims = g_currentMission.TheContractor.Claims
            local lines = { string.format("Pending claims (today is day %d)%s:",
                g_currentMission.environment.currentMonotonicDay, claims.forceBotch ~= nil and ", next botch forced" or "") }
            for _, claim in ipairs(claims.pendingClaims) do
                table.insert(lines, string.format("  farm %d job %d (%s, field %d) by %s, %s: %.0f, arrives day %d, %s, -%d reputation",
                    claim.farmId, claim.jobId, claim.jobType, claim.fieldId, claim.workerName, claim.cause, claim.amount,
                    claim.notifyDay, claim.insured and "insured" or "uninsured", claim.reputationPenalty))
            end

            table.insert(lines, string.format("Farm %d: %d claim(s) in the last 3 years, public liability %.0f a year%s",
                farmId, claims:getRecentClaimCount(farmId), claims:getPremium(farmId),
                claims:isInsured(farmId) and " (insured)" or " (not insured)"))
            for _, record in ipairs(claims.historyByFarm[farmId] or {}) do
                table.insert(lines, string.format("  %s: %.0f", TCCalendar.formatPeriodIndex(record.periodIndex),
                    record.amount))
            end
            return table.concat(lines, "\n")
        end,
    })

    -- The flag is server-only and transient.
    TCConsole.register("finance", "botch", {
        args = "[daysUntilClaim=2-7]",
        description = "The next worker to finish a job that can cause a claim botches it",
        run = function(farmId, args)
            local days = TCConsole.toCount(args[1], nil)
            if args[1] ~= nil and days == nil then
                return false
            end

            g_currentMission.TheContractor.Claims.forceBotch = { delayDays = days }
            return string.format("The next worker to finish a job that can cause a claim will botch it (claim arrives %s)",
                days ~= nil and string.format("in %d day(s)", days) or "in 2-7 days")
        end,
    })
end
