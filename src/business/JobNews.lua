-- Job news (074): random events (068) that happen as a job ends, rolled by
-- the framework's job events (chancePerJob) when one completes, and only
-- after good work (MIN_JOB_QUALITY). Each is its own event type with its own
-- odds and cooldown, and posts a good news inbox message (073's kind):
--
--   kettle      the farmer brings the job's workers tea and bacon butties:
--               a morale bump for each of them
--   paidEarly   a delighted customer pays the job's invoice on the spot
--               (only while it's outstanding, so never with the
--               lateInvoices setting off - it was paid already)
--   stepsUp     something clicks for a less experienced worker on the job:
--               one point on their weakest rating for it (if it's
--               STEPS_UP_MAX_RATING or under), outside their growth
--               potential, and a morale bump
--
-- No state of its own. Incident data is { jobId } (plus invoiceId or
-- workerId/stat); the one stage runs as the incident opens, with the job
-- still to hand. A new job event is another registerEventType with
-- chancePerJob here, or in its own file if it has mechanics of its own.

TheContractorJobNews = {}
TheContractorJobNews_mt = Class(TheContractorJobNews)

-- Quality score (0-100) a job needs for any of these.
TheContractorJobNews.MIN_JOB_QUALITY = 85

TheContractorJobNews.KETTLE = "kettle"
TheContractorJobNews.KETTLE_CHANCE = 0.05
TheContractorJobNews.KETTLE_COOLDOWN_PERIODS = 2
TheContractorJobNews.KETTLE_MORALE = 5

TheContractorJobNews.PAID_EARLY = "paidEarly"
TheContractorJobNews.PAID_EARLY_CHANCE = 0.04
TheContractorJobNews.PAID_EARLY_COOLDOWN_PERIODS = 3

TheContractorJobNews.STEPS_UP = "stepsUp"
TheContractorJobNews.STEPS_UP_CHANCE = 0.04
TheContractorJobNews.STEPS_UP_COOLDOWN_PERIODS = 3
TheContractorJobNews.STEPS_UP_MAX_RATING = 5
TheContractorJobNews.STEPS_UP_MORALE = 4

function TheContractorJobNews.new()
    local self = {}
    setmetatable(self, TheContractorJobNews_mt)
    return self
end

-- Every machine, at load, before the save loads (068). Its messages use
-- GoodNews's inbox kind, registered there.
function TheContractorJobNews:register(randomEvents)
    randomEvents:registerEventType(TheContractorJobNews.KETTLE, {
        l10nKey = "tc_jobNews_kettle_eventName",
        chancePerJob = TheContractorJobNews.KETTLE_CHANCE,
        minJobQuality = TheContractorJobNews.MIN_JOB_QUALITY,
        cooldownPeriods = TheContractorJobNews.KETTLE_COOLDOWN_PERIODS,
        canTrigger = function(farmId, job)
            return self:checkKettle(job)
        end,
        stages = {
            { key = "announce", run = function(incident)
                return self:onKettle(incident)
            end },
        },
    })

    randomEvents:registerEventType(TheContractorJobNews.PAID_EARLY, {
        l10nKey = "tc_jobNews_paidEarly_eventName",
        chancePerJob = TheContractorJobNews.PAID_EARLY_CHANCE,
        minJobQuality = TheContractorJobNews.MIN_JOB_QUALITY,
        cooldownPeriods = TheContractorJobNews.PAID_EARLY_COOLDOWN_PERIODS,
        canTrigger = function(farmId, job)
            return self:checkPaidEarly(job)
        end,
        stages = {
            { key = "announce", run = function(incident)
                return self:onPaidEarly(incident)
            end },
        },
    })

    randomEvents:registerEventType(TheContractorJobNews.STEPS_UP, {
        l10nKey = "tc_jobNews_stepsUp_eventName",
        chancePerJob = TheContractorJobNews.STEPS_UP_CHANCE,
        minJobQuality = TheContractorJobNews.MIN_JOB_QUALITY,
        cooldownPeriods = TheContractorJobNews.STEPS_UP_COOLDOWN_PERIODS,
        canTrigger = function(farmId, job)
            return self:checkStepsUp(job)
        end,
        stages = {
            { key = "announce", run = function(incident)
                return self:onStepsUp(incident)
            end },
        },
    })
end

local function getJob(incident)
    return g_currentMission.TheContractor.Jobs:getJob(incident.farmId, incident.data.jobId)
end

local function postMessage(incident, key, bodyKey, args)
    local prefix = "tc_jobNews_" .. key
    g_currentMission.TheContractor.Inbox:postMessage(incident.farmId, TheContractorGoodNews.MESSAGE_KIND,
        prefix .. "_title", bodyKey or (prefix .. "_body"), args, nil, { incidentId = incident.id })
end

-- The job's hired workers still on the roster (operator first). None for a
-- player-driven job.
function TheContractorJobNews.getWorkers(job)
    local staff = g_currentMission.TheContractor.Staff
    local workers = {}
    for _, workerId in ipairs(job:getWorkerIds()) do
        local worker = staff:getWorker(job.farmId, workerId)
        if worker ~= nil then
            table.insert(workers, worker)
        end
    end
    return workers
end

-- The kettle --------------------------------------------------------------------

function TheContractorJobNews:checkKettle(job)
    if #TheContractorJobNews.getWorkers(job) == 0 then
        return nil
    end
    return { jobId = job.id }
end

function TheContractorJobNews:onKettle(incident)
    local job = getJob(incident)
    local workers = job ~= nil and TheContractorJobNews.getWorkers(job) or {}
    if #workers == 0 then
        return TheContractorRandomEvents.DONE
    end

    g_currentMission.TheContractor.Morale:adjust(incident.farmId, workers, TheContractorJobNews.KETTLE_MORALE)

    if #workers == 1 then
        postMessage(incident, TheContractorJobNews.KETTLE, "tc_jobNews_kettle_bodyOne", { workers[1].name, job.fieldId })
    else
        postMessage(incident, TheContractorJobNews.KETTLE, "tc_jobNews_kettle_bodyTwo",
            { workers[1].name, workers[2].name, job.fieldId })
    end
    TCLog.info("TheContractor: farm %d incident %d: the kettle's on at job %d, %d worker(s) +%d morale",
        incident.farmId, incident.id, job.id, #workers, TheContractorJobNews.KETTLE_MORALE)
    return TheContractorRandomEvents.DONE
end

-- Paid before you've asked --------------------------------------------------------

-- The job's invoice, while it's still outstanding (not due yet).
function TheContractorJobNews.getOutstandingInvoice(farmId, jobId)
    local invoice = g_currentMission.TheContractor.Finances:getInvoiceForJob(farmId, jobId)
    if invoice == nil or invoice.status ~= TheContractorFinances.STATUS.OUTSTANDING then
        return nil
    end
    return invoice
end

function TheContractorJobNews:checkPaidEarly(job)
    local invoice = TheContractorJobNews.getOutstandingInvoice(job.farmId, job.id)
    if invoice == nil then
        return nil
    end
    return { jobId = job.id, invoiceId = invoice.id }
end

function TheContractorJobNews:onPaidEarly(incident)
    local invoice = TheContractorJobNews.getOutstandingInvoice(incident.farmId, incident.data.jobId)
    local job = getJob(incident)
    if invoice == nil or job == nil then
        return TheContractorRandomEvents.DONE
    end

    -- Paid whatever the hidden roll had in store for it (late, or never).
    g_currentMission.TheContractor.Finances:payInvoice(invoice)
    postMessage(incident, TheContractorJobNews.PAID_EARLY, nil, { job.fieldId, "$money_" .. invoice.amount })
    TCLog.info("TheContractor: farm %d incident %d: invoice %d for job %d paid early", incident.farmId,
        incident.id, invoice.id, job.id)
    return TheContractorRandomEvents.DONE
end

-- A worker steps up ---------------------------------------------------------------

-- A worker's weakest rating for their part of the job (the tractor tier
-- they drove or the operation skill it used), and which stat it is - nil if
-- neither applies. An uncertified tier doesn't count: there's nothing to
-- raise.
function TheContractorJobNews.getWeakestStat(worker, job, equipmentIds, isHauler)
    local ratings = g_currentMission.TheContractor.Allocation:getWorkerJobRatings(worker, job, equipmentIds,
        isHauler)
    local rating, stat = nil, nil
    if ratings.tractorRating ~= nil then
        rating, stat = ratings.tractorRating, ratings.tractorTier
    end
    if ratings.operationRating ~= nil and (rating == nil or ratings.operationRating < rating) then
        rating, stat = ratings.operationRating, ratings.operationSkill
    end
    return rating, stat
end

-- The least experienced worker on the job with a weakest rating of
-- STEPS_UP_MAX_RATING or under (the operator on a tie), with that stat.
function TheContractorJobNews.pickSteppingUp(job)
    local staff = g_currentMission.TheContractor.Staff
    local roles = {
        { workerId = job.assignedWorkerId, equipmentIds = job.assignedEquipmentIds, isHauler = false },
        { workerId = job.haulerWorkerId, equipmentIds = job.haulageEquipmentIds, isHauler = true },
    }
    local bestWorker, bestStat, bestRating = nil, nil, nil
    for _, role in ipairs(roles) do
        local worker = role.workerId ~= nil and staff:getWorker(job.farmId, role.workerId) or nil
        if worker ~= nil then
            local rating, stat = TheContractorJobNews.getWeakestStat(worker, job, role.equipmentIds or {},
                role.isHauler)
            if rating ~= nil and rating <= TheContractorJobNews.STEPS_UP_MAX_RATING and
                    (bestRating == nil or rating < bestRating) then
                bestWorker, bestStat, bestRating = worker, stat, rating
            end
        end
    end
    return bestWorker, bestStat
end

function TheContractorJobNews:checkStepsUp(job)
    local worker, stat = TheContractorJobNews.pickSteppingUp(job)
    if worker == nil then
        return nil
    end
    return { jobId = job.id, workerId = worker.id, stat = stat }
end

function TheContractorJobNews:onStepsUp(incident)
    local tc = g_currentMission.TheContractor
    local job = getJob(incident)
    local worker = tc.Staff:getWorker(incident.farmId, incident.data.workerId)
    if job == nil or worker == nil then
        return TheContractorRandomEvents.DONE
    end

    local value = tc.Staff:boostWorker(incident.farmId, worker.id, incident.data.stat, job.id)
    if value == nil then
        return TheContractorRandomEvents.DONE
    end
    tc.Morale:adjust(incident.farmId, { worker }, TheContractorJobNews.STEPS_UP_MORALE)

    postMessage(incident, TheContractorJobNews.STEPS_UP, nil,
        { worker.name, job.fieldId, "$l10n_tc_growth_stat_" .. incident.data.stat, value })
    TCLog.info("TheContractor: farm %d incident %d: worker %d (%s) stepped up on job %d, %s now %d",
        incident.farmId, incident.id, worker.id, worker.name, job.id, incident.data.stat, value)
    return TheContractorRandomEvents.DONE
end
