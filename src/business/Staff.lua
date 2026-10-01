-- Shared candidate pool + per-farm worker rosters (016).
--
-- Deliberate exception to this codebase's usual "state is farm-scoped"
-- convention (see CLAUDE.md): the candidate pool is global, not keyed by
-- farmId, by explicit design decision — candidates are meant to be a
-- contested shared resource. New candidates trickle in and randomly leave
-- the pool over time, independent of any player action (a daily tick, same
-- shape as Advertising's/Jobs' own daily ticks), and any farm can hire any
-- candidate currently in the pool. In multiplayer this means farms can race
-- to hire the same top talent — first hire request the server processes for
-- a given candidate wins, the rest see that candidate simply vanish from the
-- pool (same "no browsable-pool-was-in-scope" note from this ticket's first
-- pass no longer applies; see its Outcome for the full history).
--
-- Once hired, a worker leaves the pool (farmId goes from nil to the hiring
-- farm's id) and moves into that farm's own roster — the roster itself
-- *is* farm-scoped, same as everything else in this mod.
--
-- Salary (036, replacing 026's one-off hire fee) is charged per period, on
-- PERIOD_CHANGED, for every hired worker whatever their status: about one
-- small job's pay for an average worker (~4k), up to 7k for the best
-- possible one. The first period is paid up front at hire, so hiring just
-- after a period change and releasing just before the next isn't free. No
-- refund on release, no proration. Pool sizing and the daily add/remove odds
-- were reviewed in 026 and kept.

TheContractorStaff = {}
TheContractorStaff_mt = Class(TheContractorStaff)

TheContractorStaff.BASE_SALARY = 1500
TheContractorStaff.SALARY_PER_WORK_SPEED = 250
TheContractorStaff.SALARY_PER_TIER_POINT = 100

-- Independent per-tier roll: each tier has this chance of the worker being
-- certified on it at all (a random 1-10 rating), otherwise "not certified"
-- (the key stays absent from tierCapability, per Worker.lua's convention).
TheContractorStaff.TIER_CERTIFICATION_CHANCE = 0.65

-- Pool lifecycle: seeded up to INITIAL_POOL_SIZE candidates on first ever
-- load (or if an existing save's pool is found empty, e.g. upgrading a save
-- from before this existed — see ensureInitialPool). Each day thereafter,
-- every candidate currently in the pool independently has a
-- POOL_DAILY_REMOVE_CHANCE chance to leave (poached elsewhere/lost
-- interest), and if the pool is under POOL_MAX_SIZE there's a
-- POOL_DAILY_ADD_CHANCE chance a new candidate appears.
TheContractorStaff.INITIAL_POOL_SIZE = 4
TheContractorStaff.POOL_MAX_SIZE = 8
TheContractorStaff.POOL_DAILY_ADD_CHANCE = 0.5
TheContractorStaff.POOL_DAILY_REMOVE_CHANCE = 0.15

-- Age and growth (030). Every worker gets a visible age and a hidden pool of
-- growthPotential points, rolled together at creation: the younger the
-- worker, the bigger the pool can be (MAX_GROWTH_POTENTIAL at MIN_AGE,
-- nothing from GROWTH_POTENTIAL_ZERO_AGE on), times a random
-- GROWTH_POTENTIAL_MIN_ROLL-1 so two workers of the same age still differ.
-- Salary ignores both - pay follows current ability (user's call).
TheContractorStaff.MIN_AGE = 18
TheContractorStaff.MAX_AGE = 60
TheContractorStaff.MAX_GROWTH_POTENTIAL = 12
TheContractorStaff.GROWTH_POTENTIAL_ZERO_AGE = 55
TheContractorStaff.GROWTH_POTENTIAL_MIN_ROLL = 0.4

-- Each completed job gives every worker on it one growth roll:
-- GROWTH_BASE_CHANCE x the job's quality (029, 0-1) x how much the job
-- stretched them. At or under the job's requiredSkillLevel on the tier they
-- drove is a stretch; more than GROWTH_EASY_MARGIN above it is easy work.
-- A successful roll spends one growthPotential point on one stat, picked by
-- GROWTH_WEIGHTS among those that can still move: +1 workSpeed, +1 on the
-- tier driven, or - once that tier is at CERTIFY_THRESHOLD - a new
-- certification on the next tier up, starting at CERTIFY_START_RATING.
-- About 3 in 10 good jobs grow a worker, so a young worker's full pool
-- takes around 40 jobs to use up.
TheContractorStaff.GROWTH_BASE_CHANCE = 0.3
TheContractorStaff.GROWTH_STRETCH_MULTIPLIER = 1.5
TheContractorStaff.GROWTH_EASY_MULTIPLIER = 0.5
TheContractorStaff.GROWTH_EASY_MARGIN = 2
TheContractorStaff.CERTIFY_THRESHOLD = 7
TheContractorStaff.CERTIFY_START_RATING = 2
TheContractorStaff.GROWTH_WEIGHTS = {
    tier = 0.5,
    workSpeed = 0.3,
    certify = 0.2,
}

-- Sickness (031). Every worker gets a hidden 0-1 sicknessPropensity at
-- creation, rolled as random()^2 so most are fairly healthy and a few are
-- sickly. At the start of each day, every hired worker who isn't already
-- off sick has SICK_MAX_DAILY_CHANCE x propensity chance to fall sick,
-- tuned so the sickliest fifth average one bout every 7 days. A bout is 1
-- day, with SICK_EXTRA_DAY_CHANCE of each further day up to SICK_MAX_DAYS
-- (so 80% one day, 16% two, ~4% three or more). A worker who's out on a job
-- or in its cooldown when they fall ill finishes it first and goes off sick
-- once they're back (pendingSickDays) - sickness never pulls anyone off a
-- job or causes a missed one (024) by itself.
TheContractorStaff.SICK_MAX_DAILY_CHANCE = 0.21
TheContractorStaff.SICK_EXTRA_DAY_CHANCE = 0.2
TheContractorStaff.SICK_MAX_DAYS = 5

TheContractorStaff.FIRST_NAMES = {
    "James", "Mary", "John", "Sarah", "Robert", "Emma", "Michael", "Olivia",
    "David", "Sophie", "Daniel", "Grace", "Thomas", "Amy", "Peter", "Laura",
}
TheContractorStaff.LAST_NAMES = {
    "Smith", "Jones", "Taylor", "Brown", "Wilson", "Evans", "Walker", "White",
    "Roberts", "Green", "Hall", "Wood", "Baker", "Clarke", "Turner", "Hughes",
}

-- tcHiring is unused since 036 (salaries replaced the hire fee) but stays
-- registered: old saves' finance history may reference it, and dropping it
-- would shift every later stat's index.
table.insert(FinanceStats.statNames, "tcHiring")
FinanceStats.statNameToIndex["tcHiring"] = #FinanceStats.statNames
table.insert(FinanceStats.statNames, "tcWages")
FinanceStats.statNameToIndex["tcWages"] = #FinanceStats.statNames

function TheContractorStaff.new()
    local self = {}
    setmetatable(self, TheContractorStaff_mt)

    -- workersByFarm[farmId][workerId] = TheContractorWorker (hired, farmId set)
    self.workersByFarm = {}
    -- candidatePool[id] = TheContractorWorker (unhired, farmId nil). Global,
    -- not farm-scoped — see file header.
    self.candidatePool = {}
    -- Single counter shared by both spaces: a candidate keeps its id when it
    -- gets hired and moves into a farm's roster, so there's only ever one id
    -- space to track, not two.
    self.nextWorkerId = 1

    MoneyType.TC_HIRING = MoneyType.register("tcHiring", "tc_moneyType_hiring")
    MoneyType.LAST_ID = MoneyType.LAST_ID + 1
    MoneyType.TC_WAGES = MoneyType.register("tcWages", "tc_moneyType_wages")
    MoneyType.LAST_ID = MoneyType.LAST_ID + 1

    return self
end

-- Query API -------------------------------------------------------------

function TheContractorStaff:getWorker(farmId, workerId)
    local farmWorkers = self.workersByFarm[farmId]
    if farmWorkers == nil then
        return nil
    end
    return farmWorkers[workerId]
end

function TheContractorStaff:getRoster(farmId)
    local result = {}
    local farmWorkers = self.workersByFarm[farmId]
    if farmWorkers ~= nil then
        for _, worker in pairs(farmWorkers) do
            table.insert(result, worker)
        end
    end
    return result
end

-- The farm's salary bill per period (036): every hired worker, whatever
-- their status.
function TheContractorStaff:getTotalSalary(farmId)
    local total = 0
    for _, worker in ipairs(self:getRoster(farmId)) do
        total = total + worker.salary
    end
    return total
end

function TheContractorStaff:getIdleWorkers(farmId)
    local result = {}
    for _, worker in ipairs(self:getRoster(farmId)) do
        if worker:isIdle() then
            table.insert(result, worker)
        end
    end
    return result
end

-- tier is "small"/"medium"/"large" (009), or nil for jobs whose equipment
-- carries no size tier at all (every worker qualifies then).
function TheContractorStaff:getWorkersCapableOfTier(farmId, tier)
    local result = {}
    for _, worker in ipairs(self:getRoster(farmId)) do
        if worker:isCapableOfTier(tier) then
            table.insert(result, worker)
        end
    end
    return result
end

-- The pool any farm can currently hire from (017's Staff UI browse list).
function TheContractorStaff:getCandidatePool()
    local result = {}
    for _, candidate in pairs(self.candidatePool) do
        table.insert(result, candidate)
    end
    return result
end

function TheContractorStaff:getCandidate(candidateId)
    return self.candidatePool[candidateId]
end

-- Stat rolling ------------------------------------------------------------

function TheContractorStaff.rollWorkSpeed()
    return math.random(1, 10)
end

function TheContractorStaff.rollTierCapability()
    local tierCapability = {}
    for _, tier in ipairs(TheContractorWorker.TIERS) do
        if math.random() < TheContractorStaff.TIER_CERTIFICATION_CHANCE then
            tierCapability[tier] = math.random(1, 10)
        end
    end
    return tierCapability
end

function TheContractorStaff.rollAge()
    return math.random(TheContractorStaff.MIN_AGE, TheContractorStaff.MAX_AGE)
end

function TheContractorStaff.rollBirthPeriod()
    return math.random(1, Environment.PERIODS_IN_YEAR)
end

function TheContractorStaff.rollGrowthPotential(age)
    local zeroAge, minAge = TheContractorStaff.GROWTH_POTENTIAL_ZERO_AGE, TheContractorStaff.MIN_AGE
    local ageFactor = math.max(0, math.min(1, (zeroAge - age) / (zeroAge - minAge)))
    local minRoll = TheContractorStaff.GROWTH_POTENTIAL_MIN_ROLL
    local roll = minRoll + (1 - minRoll) * math.random()
    return math.floor(TheContractorStaff.MAX_GROWTH_POTENTIAL * ageFactor * roll + 0.5)
end

function TheContractorStaff.rollSicknessPropensity()
    return math.random() ^ 2
end

-- Per period (036). Always derived from current stats: recomputed on load
-- and whenever a worker grows (applyWorkerGrowth), so a better worker costs
-- more.
function TheContractorStaff.getSalary(workSpeed, tierCapability)
    local salary = TheContractorStaff.BASE_SALARY + workSpeed * TheContractorStaff.SALARY_PER_WORK_SPEED

    for _, tier in ipairs(TheContractorWorker.TIERS) do
        local rating = tierCapability[tier]
        if rating ~= nil then
            salary = salary + rating * TheContractorStaff.SALARY_PER_TIER_POINT
        end
    end

    return salary
end

function TheContractorStaff.generateName()
    local firstName = TheContractorStaff.FIRST_NAMES[math.random(#TheContractorStaff.FIRST_NAMES)]
    local lastName = TheContractorStaff.LAST_NAMES[math.random(#TheContractorStaff.LAST_NAMES)]
    return firstName .. " " .. lastName
end

function TheContractorStaff.formatTierCapability(tierCapability)
    local parts = {}
    for _, tier in ipairs(TheContractorWorker.TIERS) do
        local rating = tierCapability[tier]
        table.insert(parts, tier .. "=" .. (rating ~= nil and tostring(rating) or "none"))
    end
    return table.concat(parts, ", ")
end

-- Candidate pool lifecycle (server-authoritative) ------------------------

-- Rolls a brand new candidate and adds it to the pool, applying locally and
-- broadcasting to all clients (see file header — every client needs to see
-- the same shared pool, not just the farm that happens to be looking at it).
-- No-ops (returns nil) if the pool is already at POOL_MAX_SIZE.
function TheContractorStaff:addCandidateToPool()
    if not g_currentMission:getIsServer() then
        return nil
    end

    local poolCount = 0
    for _ in pairs(self.candidatePool) do
        poolCount = poolCount + 1
    end
    if poolCount >= TheContractorStaff.POOL_MAX_SIZE then
        return nil
    end

    local id = self.nextWorkerId
    self.nextWorkerId = self.nextWorkerId + 1

    local workSpeed = TheContractorStaff.rollWorkSpeed()
    local tierCapability = TheContractorStaff.rollTierCapability()
    local salary = TheContractorStaff.getSalary(workSpeed, tierCapability)
    local name = TheContractorStaff.generateName()
    local age = TheContractorStaff.rollAge()
    local growthPotential = TheContractorStaff.rollGrowthPotential(age)
    local birthPeriod = TheContractorStaff.rollBirthPeriod()
    local sicknessPropensity = TheContractorStaff.rollSicknessPropensity()

    local candidate = TheContractorWorker.new(id, nil, name, workSpeed, tierCapability, salary, age,
        growthPotential, birthPeriod, sicknessPropensity)
    self:applyCandidateAdded(candidate)

    if g_server ~= nil then
        g_server:broadcastEvent(TCStaffCandidateAddedEvent.new(candidate))
    end

    Logging.info("TheContractor: staff pool gained candidate %d (%s, age %d, speed %d, potential %d, salary %.0f)",
        candidate.id, candidate.name, candidate.age, candidate.workSpeed, candidate.growthPotential,
        candidate.salary)

    return candidate
end

-- The actual state flip, run on whichever machine (server, or a client
-- receiving TCStaffCandidateAddedEvent/initial client state) is applying it.
function TheContractorStaff:applyCandidateAdded(candidate)
    self.candidatePool[candidate.id] = candidate

    if candidate.id >= self.nextWorkerId then
        self.nextWorkerId = candidate.id + 1
    end
end

-- Removes a candidate from the pool without hiring them (poached elsewhere/
-- lost interest, per the daily tick) and broadcasts the removal. A no-op if
-- the candidate is already gone (e.g. another farm just hired them).
function TheContractorStaff:removeCandidateFromPool(candidateId)
    if not g_currentMission:getIsServer() then
        return
    end

    if self.candidatePool[candidateId] == nil then
        return
    end

    self:applyCandidateRemoved(candidateId)

    if g_server ~= nil then
        g_server:broadcastEvent(TCStaffCandidateRemovedEvent.new(candidateId))
    end
end

function TheContractorStaff:applyCandidateRemoved(candidateId)
    self.candidatePool[candidateId] = nil
end

-- Server-only daily tick (same shape as Advertising's/Jobs' own daily
-- ticks): rolls departure for every candidate currently in the pool, then
-- maybe adds one new candidate if there's room. Order matters only in that a
-- candidate could depart and be replaced within the same day — that's fine,
-- there's no reason a leaver and a newcomer can't both happen on the same
-- day.
function TheContractorStaff:startDailyTick()
    if not g_currentMission:getIsServer() then
        return
    end

    g_messageCenter:subscribe(MessageType.DAY_CHANGED, self.onDayChanged, self)
    g_messageCenter:subscribe(MessageType.PERIOD_CHANGED, self.onPeriodChanged, self)
end

function TheContractorStaff:stopDailyTick()
    g_messageCenter:unsubscribe(MessageType.DAY_CHANGED, self)
    g_messageCenter:unsubscribe(MessageType.PERIOD_CHANGED, self)
end

function TheContractorStaff:onDayChanged()
    local departingIds = {}
    for id in pairs(self.candidatePool) do
        if math.random() < TheContractorStaff.POOL_DAILY_REMOVE_CHANCE then
            table.insert(departingIds, id)
        end
    end
    for _, id in ipairs(departingIds) do
        self:removeCandidateFromPool(id)
    end

    if math.random() < TheContractorStaff.POOL_DAILY_ADD_CHANCE then
        self:addCandidateToPool()
    end

    self:updateSickness()
end

-- Sickness (031, server-only, from the daily tick): sick workers count down
-- a day and come back idle when it runs out, then every other hired worker
-- rolls to fall sick (see the SICK_* tunables). Idle ones go off sick
-- straight away; busy ones get pendingSickDays, applied in setWorkerStatus
-- when they're next set idle. toRoll is gathered before anyone recovers, so
-- someone who only just got better doesn't roll the same day, and anyone
-- with sickness already pending doesn't roll again.
function TheContractorStaff:updateSickness()
    local sickStatus = TheContractorWorker.STATUS.SICK

    for farmId, farmWorkers in pairs(self.workersByFarm) do
        local toRecover, toRoll = {}, {}
        for workerId, worker in pairs(farmWorkers) do
            if worker.status == sickStatus then
                worker.sickDaysRemaining = worker.sickDaysRemaining - 1
                if worker.sickDaysRemaining <= 0 then
                    table.insert(toRecover, workerId)
                end
            elseif worker.pendingSickDays == 0 then
                table.insert(toRoll, worker)
            end
        end

        for _, workerId in ipairs(toRecover) do
            self:setWorkerStatus(farmId, workerId, TheContractorWorker.STATUS.IDLE)
        end

        for _, worker in ipairs(toRoll) do
            if math.random() < TheContractorStaff.SICK_MAX_DAILY_CHANCE * worker.sicknessPropensity then
                local days = TheContractorStaff.rollSickDays()

                if worker:isIdle() then
                    Logging.info("TheContractor: farm %d worker %d (%s) off sick for %d day(s)", farmId, worker.id,
                        worker.name, days)
                    worker.sickDaysRemaining = days
                    self:setWorkerStatus(farmId, worker.id, sickStatus)
                else
                    Logging.info("TheContractor: farm %d worker %d (%s) fell ill on a job, off sick for %d day(s) once back",
                        farmId, worker.id, worker.name, days)
                    worker.pendingSickDays = days
                end
            end
        end
    end
end

-- 1 day, plus SICK_EXTRA_DAY_CHANCE of each further day up to SICK_MAX_DAYS.
function TheContractorStaff.rollSickDays()
    local days = 1
    while days < TheContractorStaff.SICK_MAX_DAYS and math.random() < TheContractorStaff.SICK_EXTRA_DAY_CHANCE do
        days = days + 1
    end
    return days
end

function TheContractorStaff:onPeriodChanged()
    self:paySalaries()
    self:ageWorkers()
end

-- Salaries (036, server-only, from the period tick): one charge per farm for
-- its whole roster. Charged even if the farm can't afford it - it just goes
-- negative, like any vanilla expense. Money syncs through vanilla, so no
-- event of our own.
function TheContractorStaff:paySalaries()
    for farmId in pairs(self.workersByFarm) do
        local total = self:getTotalSalary(farmId)
        if total > 0 and g_farmManager:getFarmById(farmId) ~= nil then
            g_currentMission:addMoney(-total, farmId, MoneyType.TC_WAGES, true, true)
            Logging.info("TheContractor: farm %d paid %.0f in staff salaries", farmId, total)
        end
    end
end

-- Birthdays (030 follow-up): everyone whose birthPeriod is the period just
-- starting - pool candidates and hired workers alike - turns a year older.
-- growthPotential is left alone; it's rolled from age once, at creation.
-- One broadcast for the whole batch.
function TheContractorStaff:ageWorkers()
    local period = g_currentMission.environment.currentPeriod
    local aged = {}

    local function ageIfBirthday(worker)
        if worker.birthPeriod == period then
            worker.age = worker.age + 1
            table.insert(aged, { id = worker.id, age = worker.age })
        end
    end

    for _, candidate in pairs(self.candidatePool) do
        ageIfBirthday(candidate)
    end
    for _, farmWorkers in pairs(self.workersByFarm) do
        for _, worker in pairs(farmWorkers) do
            ageIfBirthday(worker)
        end
    end

    if #aged == 0 then
        return
    end

    Logging.info("TheContractor: %d staff/candidates had a birthday in period %d", #aged, period)

    if g_server ~= nil then
        g_server:broadcastEvent(TCWorkersAgedEvent.new(aged))
    end
end

-- Worker ids are unique across the pool and every roster (one shared
-- nextWorkerId), so an id alone finds them wherever they are.
function TheContractorStaff:findWorkerById(workerId)
    local candidate = self.candidatePool[workerId]
    if candidate ~= nil then
        return candidate
    end
    for _, farmWorkers in pairs(self.workersByFarm) do
        if farmWorkers[workerId] ~= nil then
            return farmWorkers[workerId]
        end
    end
    return nil
end

-- Run on clients receiving TCWorkersAgedEvent (the server already applied
-- it in onPeriodChanged).
function TheContractorStaff:applyWorkerAged(workerId, age)
    local worker = self:findWorkerById(workerId)
    if worker ~= nil then
        worker.age = age
    end
end

-- Called once from TheContractor:loadMap, after persisted state has been
-- loaded — covers both a brand new save (empty pool, .new()'s default) and
-- an existing save from before the candidate pool existed (also an empty
-- pool, since loadFromXMLFile finds no <pool> entries to populate it with).
-- Tops the pool up to INITIAL_POOL_SIZE rather than leaving it to the daily
-- tick to slowly fill in on its own.
function TheContractorStaff:ensureInitialPool()
    if not g_currentMission:getIsServer() then
        return
    end

    local poolCount = 0
    for _ in pairs(self.candidatePool) do
        poolCount = poolCount + 1
    end

    while poolCount < TheContractorStaff.INITIAL_POOL_SIZE do
        if self:addCandidateToPool() == nil then
            break
        end
        poolCount = poolCount + 1
    end
end

-- Hiring (server-authoritative) -------------------------------------------

-- Hiring pays the first period's salary up front (036), so that's what has
-- to be affordable.
function TheContractorStaff:canAffordHire(farmId, salary)
    local farm = g_farmManager:getFarmById(farmId)
    if farm == nil then
        return false
    end

    return farm:getBalance() >= salary
end

-- Hires a candidate currently in the pool for farmId: checks the candidate
-- is still there (the MP race — first request the server processes wins,
-- see file header) and the farm can afford their first period's salary
-- (036), charges it, moves
-- them out of the pool and into the farm's roster, then broadcasts the
-- result. Only the server may hire — see TCHireWorkerEvent for the client-
-- request side. Returns the hired TheContractorWorker, or nil if the
-- candidate was already gone or the farm couldn't afford them.
function TheContractorStaff:hireWorker(farmId, candidateId)
    if not g_currentMission:getIsServer() then
        return nil
    end

    local candidate = self.candidatePool[candidateId]
    if candidate == nil then
        return nil
    end

    if not self:canAffordHire(farmId, candidate.salary) then
        return nil
    end

    g_currentMission:addMoney(-candidate.salary, farmId, MoneyType.TC_WAGES, true, true)

    candidate.farmId = farmId
    self:applyWorkerHired(candidate)

    if g_server ~= nil then
        g_server:broadcastEvent(TCWorkerHiredEvent.new(candidate))
    end

    return candidate
end

-- The actual state flip (pool -> roster), run on whichever machine (server,
-- or a client receiving TCWorkerHiredEvent) is applying the hire.
function TheContractorStaff:applyWorkerHired(worker)
    self.candidatePool[worker.id] = nil
    self:registerWorker(worker)
end

-- Registers an already-constructed, already-hired worker (farmId set) —
-- used by applyWorkerHired and by initial-client-state replay.
function TheContractorStaff:registerWorker(worker)
    self.workersByFarm[worker.farmId] = self.workersByFarm[worker.farmId] or {}
    self.workersByFarm[worker.farmId][worker.id] = worker

    if worker.id >= self.nextWorkerId then
        self.nextWorkerId = worker.id + 1
    end

    Logging.info("TheContractor: farm %d hired worker %d (%s, speed %d, salary %.0f)", worker.farmId, worker.id,
        worker.name, worker.workSpeed, worker.salary)
end

-- Releasing (server-authoritative) ----------------------------------------

-- Fires a hired worker from farmId's roster (017's Staff UI roster
-- management action) — no refund, and no move back into the candidate pool
-- (a released worker is just gone, not recycled). Returns true if a worker
-- was actually removed. Unlike hiring there's no race to arbitrate: only the
-- owning farm can ever reference a workerId that's in its own roster, so no
-- re-check-then-act window exists for another farm to interfere with.
function TheContractorStaff:releaseWorker(farmId, workerId)
    if not g_currentMission:getIsServer() then
        return false
    end

    local farmWorkers = self.workersByFarm[farmId]
    if farmWorkers == nil or farmWorkers[workerId] == nil then
        return false
    end

    local worker = farmWorkers[workerId]
    self:applyWorkerReleased(farmId, workerId)

    if g_server ~= nil then
        g_server:broadcastEvent(TCWorkerReleasedEvent.new(farmId, workerId))
    end

    Logging.info("TheContractor: farm %d released worker %d (%s)", farmId, workerId, worker.name)

    return true
end

-- The actual state flip, run on whichever machine (server, or a client
-- receiving TCWorkerReleasedEvent) is applying it.
function TheContractorStaff:applyWorkerReleased(farmId, workerId)
    local farmWorkers = self.workersByFarm[farmId]
    if farmWorkers == nil then
        return
    end

    farmWorkers[workerId] = nil
end

-- Worker status (server-authoritative) -------------------------------------

-- Flips a hired worker's status (idle/assigned/cooldown/sick) and broadcasts it —
-- first driven by allocation (018, idle -> assigned on a successful
-- allocateJob), later tickets (022/023) will flip it back on
-- completion/cooldown. Broadcasts just the changed field
-- (TCWorkerStatusChangedEvent) rather than a full worker snapshot, since
-- status is the only thing this ever moves on its own.
function TheContractorStaff:setWorkerStatus(farmId, workerId, status)
    if not g_currentMission:getIsServer() then
        return
    end

    -- 031: someone who fell ill while out on a job goes off sick, not idle,
    -- when they get back.
    local worker = self:getWorker(farmId, workerId)
    if worker ~= nil and status == TheContractorWorker.STATUS.IDLE and worker.pendingSickDays > 0 then
        Logging.info("TheContractor: farm %d worker %d (%s) back from their job, now off sick for %d day(s)", farmId,
            workerId, worker.name, worker.pendingSickDays)
        worker.sickDaysRemaining = worker.pendingSickDays
        worker.pendingSickDays = 0
        status = TheContractorWorker.STATUS.SICK
    end

    local oldStatus = self:applyWorkerStatusChanged(farmId, workerId, status)

    -- The host's own notification - the broadcast below doesn't loop back
    -- to it (see src/events/README.md).
    TCWorkerStatusChangedEvent.showNotification(self:getWorker(farmId, workerId), oldStatus, status)

    if g_server ~= nil then
        g_server:broadcastEvent(TCWorkerStatusChangedEvent.new(farmId, workerId, status))
    end
end

-- The actual field flip, run on whichever machine (server, or a client
-- receiving TCWorkerStatusChangedEvent) is applying it. Returns the status
-- the worker had before (nil if there's no such worker).
function TheContractorStaff:applyWorkerStatusChanged(farmId, workerId, status)
    local worker = self:getWorker(farmId, workerId)
    if worker == nil then
        return nil
    end

    local oldStatus = worker.status
    worker.status = status
    return oldStatus
end

-- Growth (030, server-authoritative) ----------------------------------------

-- Called from TheContractorJobs:completeJob once the job's qualityScore is
-- set. Each hired worker on the job (operator, and hauler on a haulage job,
-- 035) gets one growth roll against the tier of the equipment they drove.
-- A player-driven job has no worker, so nothing grows.
function TheContractorStaff:applyGrowthFromJob(job)
    if not g_currentMission:getIsServer() then
        return
    end

    if job.assignedWorkerId ~= nil then
        self:rollWorkerGrowth(job, job.assignedWorkerId, job.assignedEquipmentIds)
    end
    if job.haulerWorkerId ~= nil then
        self:rollWorkerGrowth(job, job.haulerWorkerId, job.haulageEquipmentIds)
    end
end

function TheContractorStaff:rollWorkerGrowth(job, workerId, equipmentIds)
    local worker = self:getWorker(job.farmId, workerId)
    if worker == nil or worker.growthPotential <= 0 then
        return
    end

    local tier = g_currentMission.TheContractor.Allocation:getRequiredTier(equipmentIds)
    local rating = tier ~= nil and worker:getTierCapability(tier) or nil

    local stretch = 1
    if rating ~= nil then
        if rating <= job.requiredSkillLevel then
            stretch = TheContractorStaff.GROWTH_STRETCH_MULTIPLIER
        elseif rating > job.requiredSkillLevel + TheContractorStaff.GROWTH_EASY_MARGIN then
            stretch = TheContractorStaff.GROWTH_EASY_MULTIPLIER
        end
    end

    local quality = (job.qualityScore or 100) / 100
    if math.random() >= TheContractorStaff.GROWTH_BASE_CHANCE * stretch * quality then
        return
    end

    local stat, value = TheContractorStaff.pickGrowth(worker, tier, rating)
    if stat == nil then
        -- Nothing left that can move (everything maxed); the leftover
        -- potential just goes unused.
        return
    end

    local oldValue = worker:getStat(stat)
    worker.growthPotential = worker.growthPotential - 1
    self:applyWorkerGrowth(job.farmId, workerId, stat, value)

    Logging.info("TheContractor: farm %d worker %d (%s) grew %s %s -> %d, %d potential left", job.farmId,
        workerId, worker.name, stat, tostring(oldValue), value, worker.growthPotential)

    -- The host's own notification - the broadcast below doesn't loop back
    -- to it (see src/events/README.md).
    TCWorkerGrewEvent.showNotification(worker, stat, oldValue, value)

    if g_server ~= nil then
        g_server:broadcastEvent(TCWorkerGrewEvent.new(job.farmId, workerId, stat, value))
    end
end

-- Weighted pick (GROWTH_WEIGHTS) among the growths still possible for this
-- worker after a job on `tier` (nil if the equipment had no tier). Returns
-- stat, newValue - or nil if none are possible.
function TheContractorStaff.pickGrowth(worker, tier, rating)
    local weights = TheContractorStaff.GROWTH_WEIGHTS
    local options = {}

    if worker.workSpeed < TheContractorWorker.MAX_WORK_SPEED then
        table.insert(options, { stat = "workSpeed", value = worker.workSpeed + 1, weight = weights.workSpeed })
    end

    if rating ~= nil then
        if rating < TheContractorWorker.MAX_WORK_SPEED then
            table.insert(options, { stat = tier, value = rating + 1, weight = weights.tier })
        end

        local nextTier = TheContractorStaff.getNextTier(tier)
        if rating >= TheContractorStaff.CERTIFY_THRESHOLD and nextTier ~= nil and
                not worker:isCapableOfTier(nextTier) then
            table.insert(options, { stat = nextTier, value = TheContractorStaff.CERTIFY_START_RATING,
                weight = weights.certify })
        end
    end

    local totalWeight = 0
    for _, option in ipairs(options) do
        totalWeight = totalWeight + option.weight
    end
    if totalWeight <= 0 then
        return nil
    end

    local roll = math.random() * totalWeight
    for _, option in ipairs(options) do
        roll = roll - option.weight
        if roll < 0 then
            return option.stat, option.value
        end
    end
    local last = options[#options]
    return last.stat, last.value
end

-- small -> medium -> large -> nil.
function TheContractorStaff.getNextTier(tier)
    local tiers = TheContractorWorker.TIERS
    for i, t in ipairs(tiers) do
        if t == tier then
            return tiers[i + 1]
        end
    end
    return nil
end

-- The actual stat change, run on whichever machine (server, or a client
-- receiving TCWorkerGrewEvent) is applying it. growthPotential is only
-- tracked on the server, so it isn't touched here. Salary follows the new
-- stats (036); every machine recomputes it the same way.
function TheContractorStaff:applyWorkerGrowth(farmId, workerId, stat, value)
    local worker = self:getWorker(farmId, workerId)
    if worker == nil then
        return
    end

    worker:setStat(stat, value)
    worker.salary = TheContractorStaff.getSalary(worker.workSpeed, worker.tierCapability)
end

-- Wire serialization, shared by the pool/hire events and initial client
-- state. Self-contained (carries its own farmId) so callers don't need to
-- track it separately. farmId 0 is used as the "no farm" sentinel for a
-- pool candidate — streamWriteInt32 can't write nil, and 0 is never a real
-- company-owning farm id (see main.lua's own farmId == 0 checks).

function TheContractorStaff.writeWorker(streamId, worker)
    streamWriteInt32(streamId, worker.farmId or 0)
    streamWriteInt32(streamId, worker.id)
    streamWriteString(streamId, worker.name)
    streamWriteInt32(streamId, worker.workSpeed)
    streamWriteFloat32(streamId, worker.salary)
    streamWriteString(streamId, worker.status)
    -- 030: age only - growthPotential stays server-side (it's hidden), as
    -- do 031's sicknessPropensity/sickDaysRemaining/pendingSickDays.
    streamWriteInt32(streamId, worker.age)

    for _, tier in ipairs(TheContractorWorker.TIERS) do
        local rating = worker.tierCapability[tier]
        streamWriteBool(streamId, rating ~= nil)
        if rating ~= nil then
            streamWriteInt32(streamId, rating)
        end
    end
end

function TheContractorStaff.readWorker(streamId)
    local farmId = streamReadInt32(streamId)
    if farmId == 0 then
        farmId = nil
    end
    local id = streamReadInt32(streamId)
    local name = streamReadString(streamId)
    local workSpeed = streamReadInt32(streamId)
    local salary = streamReadFloat32(streamId)
    local status = streamReadString(streamId)
    local age = streamReadInt32(streamId)

    local tierCapability = {}
    for _, tier in ipairs(TheContractorWorker.TIERS) do
        if streamReadBool(streamId) then
            tierCapability[tier] = streamReadInt32(streamId)
        end
    end

    local worker = TheContractorWorker.new(id, farmId, name, workSpeed, tierCapability, salary, age)
    worker.status = status

    return worker
end

-- Persistence -------------------------------------------------------------

function TheContractorStaff.writeWorkerXML(xmlFile, key, worker)
    setXMLInt(xmlFile, key .. "#id", worker.id)
    setXMLString(xmlFile, key .. "#name", worker.name)
    setXMLInt(xmlFile, key .. "#workSpeed", worker.workSpeed)
    -- Informational only: readWorkerXML recomputes it from the stats.
    setXMLFloat(xmlFile, key .. "#salary", worker.salary)
    setXMLString(xmlFile, key .. "#status", worker.status)
    setXMLInt(xmlFile, key .. "#age", worker.age)
    setXMLInt(xmlFile, key .. "#growthPotential", worker.growthPotential)
    setXMLInt(xmlFile, key .. "#birthPeriod", worker.birthPeriod)
    setXMLFloat(xmlFile, key .. "#sicknessPropensity", worker.sicknessPropensity)
    if worker.status == TheContractorWorker.STATUS.SICK then
        setXMLInt(xmlFile, key .. "#sickDaysRemaining", worker.sickDaysRemaining)
    end
    if worker.pendingSickDays > 0 then
        setXMLInt(xmlFile, key .. "#pendingSickDays", worker.pendingSickDays)
    end

    for _, tier in ipairs(TheContractorWorker.TIERS) do
        local rating = worker.tierCapability[tier]
        if rating ~= nil then
            setXMLInt(xmlFile, key .. "#tier" .. tier, rating)
        end
    end
end

-- farmId is passed in explicitly (nil for a pool candidate) rather than read
-- from the XML node, since farm ownership is expressed structurally there
-- (which section the node lives under), not as its own attribute.
function TheContractorStaff.readWorkerXML(xmlFile, key, farmId)
    local id = getXMLInt(xmlFile, key .. "#id")
    local name = getXMLString(xmlFile, key .. "#name")
    local workSpeed = getXMLInt(xmlFile, key .. "#workSpeed")

    local tierCapability = {}
    for _, tier in ipairs(TheContractorWorker.TIERS) do
        tierCapability[tier] = getXMLInt(xmlFile, key .. "#tier" .. tier)
    end

    -- Always recomputed (036), so a pre-036 save's #hireCost is simply
    -- ignored and a retuned formula applies to existing workers too.
    local salary = TheContractorStaff.getSalary(workSpeed, tierCapability)

    -- A worker saved before 030 has neither: roll them now, as if they'd
    -- just joined the pool.
    local age = getXMLInt(xmlFile, key .. "#age")
    local growthPotential = getXMLInt(xmlFile, key .. "#growthPotential")
    if age == nil then
        age = TheContractorStaff.rollAge()
        growthPotential = TheContractorStaff.rollGrowthPotential(age)
    end
    local birthPeriod = getXMLInt(xmlFile, key .. "#birthPeriod") or TheContractorStaff.rollBirthPeriod()
    -- Likewise a worker saved before 031.
    local sicknessPropensity = getXMLFloat(xmlFile, key .. "#sicknessPropensity") or
        TheContractorStaff.rollSicknessPropensity()

    local worker = TheContractorWorker.new(id, farmId, name, workSpeed, tierCapability, salary, age,
        growthPotential, birthPeriod, sicknessPropensity)
    worker.status = Utils.getNoNil(getXMLString(xmlFile, key .. "#status"), worker.status)
    if worker.status == TheContractorWorker.STATUS.SICK then
        worker.sickDaysRemaining = math.max(1, getXMLInt(xmlFile, key .. "#sickDaysRemaining") or 1)
    end
    worker.pendingSickDays = getXMLInt(xmlFile, key .. "#pendingSickDays") or 0

    return worker
end

function TheContractorStaff:loadFromXMLFile(xmlFile)
    if not g_currentMission:getIsServer() then return end

    self.workersByFarm = {}
    self.candidatePool = {}
    self.nextWorkerId = 1

    local rootKey = string.format("%s.staff", TheContractor.SaveKey)
    self.nextWorkerId = Utils.getNoNil(getXMLInt(xmlFile, rootKey .. "#nextWorkerId"), 1)

    local poolIndex = 0
    while true do
        local candidateKey = string.format("%s.pool.candidate(%d)", rootKey, poolIndex)
        if not hasXMLProperty(xmlFile, candidateKey) then
            break
        end

        local candidate = TheContractorStaff.readWorkerXML(xmlFile, candidateKey, nil)
        self.candidatePool[candidate.id] = candidate

        if candidate.id >= self.nextWorkerId then
            self.nextWorkerId = candidate.id + 1
        end

        poolIndex = poolIndex + 1
    end

    local farmIndex = 0
    while true do
        local farmKey = string.format("%s.farm(%d)", rootKey, farmIndex)
        if not hasXMLProperty(xmlFile, farmKey) then
            break
        end

        local farmId = getXMLInt(xmlFile, farmKey .. "#farmId")

        local workerIndex = 0
        while true do
            local workerKey = string.format("%s.worker(%d)", farmKey, workerIndex)
            if not hasXMLProperty(xmlFile, workerKey) then
                break
            end

            local worker = TheContractorStaff.readWorkerXML(xmlFile, workerKey, farmId)

            self.workersByFarm[farmId] = self.workersByFarm[farmId] or {}
            self.workersByFarm[farmId][worker.id] = worker

            if worker.id >= self.nextWorkerId then
                self.nextWorkerId = worker.id + 1
            end

            workerIndex = workerIndex + 1
        end

        farmIndex = farmIndex + 1
    end
end

function TheContractorStaff:saveToXmlFile(xmlFile)
    if not g_currentMission:getIsServer() then return end

    local rootKey = string.format("%s.staff", TheContractor.SaveKey)
    setXMLInt(xmlFile, rootKey .. "#nextWorkerId", self.nextWorkerId)

    local poolIndex = 0
    for _, candidate in pairs(self.candidatePool) do
        local candidateKey = string.format("%s.pool.candidate(%d)", rootKey, poolIndex)
        TheContractorStaff.writeWorkerXML(xmlFile, candidateKey, candidate)
        poolIndex = poolIndex + 1
    end

    local farmIndex = 0
    for farmId, farmWorkers in pairs(self.workersByFarm) do
        local farmKey = string.format("%s.farm(%d)", rootKey, farmIndex)
        setXMLInt(xmlFile, farmKey .. "#farmId", farmId)

        local workerIndex = 0
        for _, worker in pairs(farmWorkers) do
            local workerKey = string.format("%s.worker(%d)", farmKey, workerIndex)
            TheContractorStaff.writeWorkerXML(xmlFile, workerKey, worker)
            workerIndex = workerIndex + 1
        end

        farmIndex = farmIndex + 1
    end
end

function TheContractorStaff:writeInitialClientState(streamId, connection)
    local candidates = self:getCandidatePool()
    streamWriteInt32(streamId, #candidates)
    for _, candidate in ipairs(candidates) do
        TheContractorStaff.writeWorker(streamId, candidate)
    end

    local allWorkers = {}
    for farmId, farmWorkers in pairs(self.workersByFarm) do
        for _, worker in pairs(farmWorkers) do
            table.insert(allWorkers, worker)
        end
    end

    streamWriteInt32(streamId, #allWorkers)
    for _, worker in ipairs(allWorkers) do
        TheContractorStaff.writeWorker(streamId, worker)
    end
end

function TheContractorStaff:readInitialClientState(streamId, connection)
    local candidateCount = streamReadInt32(streamId)
    for _ = 1, candidateCount do
        self:applyCandidateAdded(TheContractorStaff.readWorker(streamId))
    end

    local workerCount = streamReadInt32(streamId)
    for _ = 1, workerCount do
        self:registerWorker(TheContractorStaff.readWorker(streamId))
    end
end
