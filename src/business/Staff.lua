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
-- PERIOD_CHANGED, for every hired worker whatever their status. 047
-- re-baselined it to real UK monthly pay (a period is a month): ~2.1k for
-- the weakest possible worker (about the National Living Wage full time),
-- ~3k for an average one (~36k a year), up to ~4.55k for the best, with
-- the gap widened by paying ratings on a curve (SALARY_RATING_EXPONENT). The
-- first period is paid up front at hire, so hiring just
-- after a period change and releasing just before the next isn't free. No
-- refund on release, no proration. Pool sizing and the daily add/remove odds
-- were reviewed in 026 and kept. 058: those figures are a worker's market
-- value (getSalary). A hired worker's pay is fixed at what they were hired
-- for and only moves with an agreed rise - see PayReviews.lua. All of these
-- are full-month figures, paid less in short months (SHORT_MONTH_PAY).

TheContractorStaff = {}
TheContractorStaff_mt = Class(TheContractorStaff)

TheContractorStaff.BASE_SALARY = 1950

-- Short months: a month of fewer days is fewer working days, so pay
-- (salaries, the administrator, notice and redundancy) is scaled by the
-- save's days per period, read live at every charge and display so changing
-- the setting takes effect at once. SHORT_MONTH_PAY at 1 day, rising evenly
-- to full pay at FULL_PAY_DAYS and over. Stored salaries (worker.salary,
-- expectedSalary, market value) stay full-month figures; scalePay turns
-- them into what's paid.
TheContractorStaff.SHORT_MONTH_PAY = 0.6
TheContractorStaff.FULL_PAY_DAYS = 5

-- Workplace pension (051): auto-enrolment's employer minimum, a share of
-- the salary bill, paid with each salary run under TC_WAGES.
TheContractorStaff.PENSION_RATE = 0.03
-- Each rating is paid as rating ^ SALARY_RATING_EXPONENT x its weight, so
-- the top of the scale costs far more per point than the bottom: a 10 is
-- paid 4x a 5, not 2x. Simulated over the candidate rolls: ~2.1k for the
-- weakest, ~2.55k at the 10th percentile, ~3.05k median, ~3.65k at the 90th
-- and ~4.55k for the best possible worker.
TheContractorStaff.SALARY_RATING_EXPONENT = 2
TheContractorStaff.SALARY_PER_WORK_SPEED = 8
TheContractorStaff.SALARY_PER_TIER_POINT = 4
-- 044: only a worker's SALARIED_SKILL_COUNT best operation skills are paid
-- for - you pay for their specialisms, not for being average at everything.
TheContractorStaff.SALARY_PER_SKILL_POINT = 4.5
TheContractorStaff.SALARIED_SKILL_COUNT = 2

-- Tractor experience is a ladder (small -> medium -> large), rolled the way
-- growth would have built it (see rollTierCapability): the worker's biggest
-- size comes from TOP_TIER_WEIGHTS (no tier: not certified on any, the keys
-- stay absent from tierCapability per Worker.lua's convention), and every
-- size below it is at CERTIFY_THRESHOLD or more.
TheContractorStaff.TOP_TIER_WEIGHTS = {
    { tier = nil, weight = 0.05 },
    { tier = "small", weight = 0.25 },
    { tier = "medium", weight = 0.35 },
    { tier = "large", weight = 0.35 },
}

-- 044: operation skills. Every skill gets a SKILL_BASE_MIN-SKILL_BASE_MAX
-- base roll, then SPECIALISMS_MIN-SPECIALISMS_MAX of them, picked at random,
-- are re-rolled as specialisms (SPECIALISM_MIN-SPECIALISM_MAX), so each
-- worker has something they're clearly good at.
TheContractorStaff.SKILL_BASE_MIN = 1
TheContractorStaff.SKILL_BASE_MAX = 4
TheContractorStaff.SPECIALISM_MIN = 5
TheContractorStaff.SPECIALISM_MAX = 10
TheContractorStaff.SPECIALISMS_MIN = 1
TheContractorStaff.SPECIALISMS_MAX = 2

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
-- Market value ignores both - it follows current ability (user's call).
TheContractorStaff.MIN_AGE = 18
TheContractorStaff.MAX_AGE = 60
TheContractorStaff.MAX_GROWTH_POTENTIAL = 12
TheContractorStaff.GROWTH_POTENTIAL_ZERO_AGE = 55
TheContractorStaff.GROWTH_POTENTIAL_MIN_ROLL = 0.4

-- Each completed job gives every worker on it one growth roll:
-- GROWTH_BASE_CHANCE x the job's quality (029, getGrowthQualityMultiplier)
-- x how much the job stretched them. At or under the job's requiredSkillLevel on their weaker
-- rating for the job (tractor or operation skill, 044) is a stretch; more
-- than GROWTH_EASY_MARGIN above it is easy work. A successful roll spends
-- one growthPotential point on one stat, picked by GROWTH_WEIGHTS among
-- those that can still move: +1 workSpeed, +1 on the operation skill used
-- (044) or +1 on the tractor tier driven. A tier reaching CERTIFY_THRESHOLD
-- also certifies the worker on the next tier up, starting at
-- CERTIFY_START_RATING, as part of the same growth (it's the same kind of
-- machine, only bigger). certify is only for a worker rolled before that
-- rule, already past the threshold with nothing above it.
-- The stat is picked first, and the roll's chance is then multiplied by
-- GROWTH_LEVEL_MULTIPLIERS for that stat's current value (capped at
-- GROWTH_MAX_CHANCE), so the basics come quickly and the top of the scale
-- is slow: on a stretching job, a skill at 1-2 moves up in ~3 jobs, one at
-- 5 in ~5-6, one at 8 in ~12 and one at 9 in ~18 (several times that on
-- easy work). Growing a stat that's still under GROWTH_FREE_BELOW doesn't
-- spend growthPotential, so even an older worker with none left picks the
-- basics up.
TheContractorStaff.GROWTH_BASE_CHANCE = 0.3
TheContractorStaff.GROWTH_MAX_CHANCE = 0.9
-- Indexed by the stat's current value (growing from 1 is [1]). A new
-- certification (certify) has no current value and uses 1.
TheContractorStaff.GROWTH_LEVEL_MULTIPLIERS = { 3, 2.5, 1.8, 1.3, 1, 0.8, 0.6, 0.45, 0.3 }
TheContractorStaff.GROWTH_FREE_BELOW = 3
TheContractorStaff.GROWTH_QUALITY_REFERENCE = 0.85
TheContractorStaff.GROWTH_QUALITY_MAX = 1.15
TheContractorStaff.GROWTH_STRETCH_MULTIPLIER = 1.5
TheContractorStaff.GROWTH_EASY_MULTIPLIER = 0.5
TheContractorStaff.GROWTH_EASY_MARGIN = 2
TheContractorStaff.CERTIFY_THRESHOLD = 7
TheContractorStaff.CERTIFY_START_RATING = 2
TheContractorStaff.GROWTH_WEIGHTS = {
    skill = 0.35,
    tier = 0.3,
    workSpeed = 0.2,
    certify = 0.15,
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
-- job or causes a missed one (024) by itself. 055: a health and safety
-- programme lowers the daily chance and shortens bouts
-- (TheContractorHealthSafety), and without one a worker falling sick can
-- bring a workplace inspection.
TheContractorStaff.SICK_MAX_DAILY_CHANCE = 0.21
TheContractorStaff.SICK_EXTRA_DAY_CHANCE = 0.2
TheContractorStaff.SICK_MAX_DAYS = 5

-- Retirement (039). On each birthday from RETIREMENT_MIN_AGE, a hired worker
-- who hasn't already handed in their notice rolls to retire: the chance
-- climbs from RETIREMENT_MIN_CHANCE at RETIREMENT_MIN_AGE to certain at
-- RETIREMENT_CERTAIN_AGE, along a cubic so most of it comes late. Simulated,
-- that's ~2% retired by 51, ~17% by 55, ~71% by 60 and ~97% by 63; the median
-- worker goes at 59. A successful roll gives RETIREMENT_NOTICE_MONTHS of
-- notice: they keep working until the start of that period, then leave the
-- roster (or, if they're out on a job then, as soon as they're back - see
-- setWorkerStatus). Pool candidates never retire; they don't stay long
-- enough. 056: a worker who quits from low morale (Morale.lua) leaves the
-- same way, after a month's notice; low morale also makes the birthday roll
-- more likely.
TheContractorStaff.RETIREMENT_MIN_AGE = 50
TheContractorStaff.RETIREMENT_CERTAIN_AGE = 65
TheContractorStaff.RETIREMENT_MIN_CHANCE = 0.02
TheContractorStaff.RETIREMENT_CURVE_EXPONENT = 3
TheContractorStaff.RETIREMENT_NOTICE_MONTHS = 6

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

-- 090: a fresh id from the worker counter. Office staff take theirs from
-- it too, so no id is ever both a worker's and an office member's.
function TheContractorStaff:takeWorkerId()
    local id = self.nextWorkerId
    self.nextWorkerId = self.nextWorkerId + 1
    return id
end

-- A loaded id that's already in use: the counter moves past it.
function TheContractorStaff:reserveWorkerId(id)
    if id >= self.nextWorkerId then
        self.nextWorkerId = id + 1
    end
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

-- The share of a full month's pay a month of daysPerPeriod days pays (see
-- SHORT_MONTH_PAY).
function TheContractorStaff.getPayFactor(daysPerPeriod)
    daysPerPeriod = daysPerPeriod or g_currentMission.environment.daysPerPeriod
    local minPay, fullDays = TheContractorStaff.SHORT_MONTH_PAY, TheContractorStaff.FULL_PAY_DAYS
    local progress = math.max(0, math.min(1, (daysPerPeriod - 1) / (fullDays - 1)))
    return minPay + (1 - minPay) * progress
end

-- A full-month amount as it's paid this month, in whole money, at
-- FS25_EconomyScale's price level (TCEconomyScale). Salaries are stored
-- unscaled, so changing that mod's setting moves them straight away.
function TheContractorStaff.scalePay(amount)
    return math.floor(amount * TheContractorStaff.getPayFactor() * TCEconomyScale.getFactor() + 0.5)
end

-- The farm's salary bill per period (036): every hired worker, whatever
-- their status, at this month's pay (scalePay).
function TheContractorStaff:getTotalSalary(farmId)
    local total = 0
    for _, worker in ipairs(self:getRoster(farmId)) do
        total = total + worker.salary
    end
    return TheContractorStaff.scalePay(total)
end

-- Everyone paid in the salary run: the roster plus the office staff (057,
-- 090), who aren't on it.
function TheContractorStaff:getPayroll(farmId)
    return self:getTotalSalary(farmId) + g_currentMission.TheContractor.Office:getSalary(farmId)
end

-- Employees, for employer's liability (051): the roster plus the office
-- staff (057, 090).
function TheContractorStaff:getHeadcount(farmId)
    return #self:getRoster(farmId) + g_currentMission.TheContractor.Office:getHeadcount(farmId)
end

-- The employer's pension contribution on the payroll (051).
function TheContractorStaff:getPensionCost(farmId)
    return self:getPayroll(farmId) * TheContractorStaff.PENSION_RATE
end

-- What each salary run actually costs: salaries plus pension.
function TheContractorStaff:getWageBill(farmId)
    return self:getPayroll(farmId) + self:getPensionCost(farmId)
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

-- 097: idle and at work (not gone home): who can be given a job or a
-- vehicle to drive.
function TheContractorStaff:getAvailableWorkers(farmId)
    local result = {}
    local now = TheContractorWorkingHours.getNow()
    for _, worker in ipairs(self:getRoster(farmId)) do
        if TheContractorWorkingHours.isAvailable(worker, now) then
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

local function rollTopTier()
    local totalWeight = 0
    for _, entry in ipairs(TheContractorStaff.TOP_TIER_WEIGHTS) do
        totalWeight = totalWeight + entry.weight
    end
    local roll = math.random() * totalWeight
    for _, entry in ipairs(TheContractorStaff.TOP_TIER_WEIGHTS) do
        roll = roll - entry.weight
        if roll < 0 then
            return entry.tier
        end
    end
    return nil
end

-- See TOP_TIER_WEIGHTS. Sizes below the top one are CERTIFY_THRESHOLD-10
-- (reaching the threshold is what qualified them for the next). The top
-- one is no better than the size below it, and under the threshold unless
-- it's the biggest there is - reaching it would have qualified them for the
-- next size up.
function TheContractorStaff.rollTierCapability()
    local tierCapability = {}
    local topTier = rollTopTier()
    if topTier == nil then
        return tierCapability
    end

    local threshold, maxRating = TheContractorStaff.CERTIFY_THRESHOLD, TheContractorWorker.MAX_SKILL
    local below = nil
    for _, tier in ipairs(TheContractorWorker.TIERS) do
        if tier == topTier then
            local cap = below or maxRating
            if TheContractorStaff.getNextTier(tier) ~= nil then
                cap = math.min(cap, threshold - 1)
            end
            tierCapability[tier] = math.random(1, cap)
            break
        end
        tierCapability[tier] = math.random(threshold, maxRating)
        below = tierCapability[tier]
    end
    return tierCapability
end

-- 044: see SKILL_BASE_MIN/SPECIALISM_MIN above.
function TheContractorStaff.rollSkills()
    local skills = {}
    for _, skill in ipairs(TheContractorWorker.SKILLS) do
        skills[skill] = math.random(TheContractorStaff.SKILL_BASE_MIN, TheContractorStaff.SKILL_BASE_MAX)
    end

    local remaining = table.clone(TheContractorWorker.SKILLS)
    local specialisms = math.random(TheContractorStaff.SPECIALISMS_MIN, TheContractorStaff.SPECIALISMS_MAX)
    for _ = 1, specialisms do
        local skill = table.remove(remaining, math.random(#remaining))
        skills[skill] = math.random(TheContractorStaff.SPECIALISM_MIN, TheContractorStaff.SPECIALISM_MAX)
    end
    return skills
end

-- 045: uniform - a trait, not a skill.
function TheContractorStaff.rollCleanliness()
    return math.random(TheContractorWorker.MIN_CLEANLINESS, TheContractorWorker.MAX_CLEANLINESS)
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

-- Per period (036): the market value for these stats, what a candidate asks
-- for. 058: a hired worker's pay starts here and stays put when they grow -
-- growth raises their market value (TheContractorPayReviews.getMarketValue)
-- instead.
function TheContractorStaff.getSalary(workSpeed, tierCapability, skills, adsSkills)
    local exponent = TheContractorStaff.SALARY_RATING_EXPONENT
    local salary = TheContractorStaff.BASE_SALARY + workSpeed ^ exponent * TheContractorStaff.SALARY_PER_WORK_SPEED

    for _, tier in ipairs(TheContractorWorker.TIERS) do
        local rating = tierCapability[tier]
        if rating ~= nil then
            salary = salary + rating ^ exponent * TheContractorStaff.SALARY_PER_TIER_POINT
        end
    end

    -- 044: the best SALARIED_SKILL_COUNT operation skills only.
    local ratings = {}
    for _, skill in ipairs(TheContractorWorker.SKILLS) do
        table.insert(ratings, (skills or {})[skill] or TheContractorWorker.MIN_SKILL)
    end
    table.sort(ratings, function(a, b) return a > b end)
    for i = 1, math.min(TheContractorStaff.SALARIED_SKILL_COUNT, #ratings) do
        salary = salary + ratings[i] ^ exponent * TheContractorStaff.SALARY_PER_SKILL_POINT
    end

    -- 091: ADS workshop skills. A skilled worker is worth more whether or
    -- not the workshop is using them right now.
    if adsSkills ~= nil then
        salary = salary + TheContractorWorkshop.getSalaryPremium(adsSkills)
    end

    return math.floor(salary + 0.5)
end

-- A new name in the nameStyle setting's style (TCNames). Server only, as
-- with everything else rolled for a candidate.
function TheContractorStaff.generateName(gender)
    local tc = g_currentMission.TheContractor
    local styleKey = tc ~= nil and tc.Settings ~= nil and tc.Settings:getNameStyle() or TCNames.DEFAULT_STYLE
    return TCNames.generate(gender, styleKey)
end

-- A worker saved before 041 has a name but no gender: go by their first
-- name, or roll one if it's not in any style.
function TheContractorStaff.guessGender(name)
    local firstName = string.match(name or "", "^(%S+)")
    return TCNames.findGender(firstName) or TCWorkerAppearance.rollGender()
end

function TheContractorStaff.formatTierCapability(tierCapability)
    local parts = {}
    for _, tier in ipairs(TheContractorWorker.TIERS) do
        local rating = tierCapability[tier]
        table.insert(parts, tier .. "=" .. (rating ~= nil and tostring(rating) or "none"))
    end
    return table.concat(parts, ", ")
end

-- 044, console/log only: "harvesting=3, baling=8, ...".
function TheContractorStaff.formatSkills(skills)
    local parts = {}
    for _, skill in ipairs(TheContractorWorker.SKILLS) do
        table.insert(parts, skill .. "=" .. tostring(skills[skill]))
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

    local id = self:takeWorkerId()

    local workSpeed = TheContractorStaff.rollWorkSpeed()
    local tierCapability = TheContractorStaff.rollTierCapability()
    local skills = TheContractorStaff.rollSkills()
    -- 091: only while ADS takes our staff, where they're worth something.
    local adsSkills = TCADSWorkshop.isActive() and TheContractorWorkshop.rollSkills() or {}
    local salary = TheContractorStaff.getSalary(workSpeed, tierCapability, skills, adsSkills)
    local gender = TCWorkerAppearance.rollGender()
    local name = TheContractorStaff.generateName(gender)
    local age = TheContractorStaff.rollAge()
    local growthPotential = TheContractorStaff.rollGrowthPotential(age)
    local birthPeriod = TheContractorStaff.rollBirthPeriod()
    local sicknessPropensity = TheContractorStaff.rollSicknessPropensity()
    local cleanliness = TheContractorStaff.rollCleanliness()

    local candidate = TheContractorWorker.new(id, nil, name, workSpeed, tierCapability, salary, age,
        growthPotential, birthPeriod, sicknessPropensity, skills, cleanliness)
    candidate.gender = gender
    candidate.appearance = TCWorkerAppearance.roll(gender)
    candidate.adsSkills = adsSkills
    -- 118: hidden, server-only.
    candidate.temperament = TheContractorMorale.rollTemperament()
    -- 054: some arrive already certified.
    TheContractorTraining.rollCandidateCertifications(candidate)
    self:applyCandidateAdded(candidate)

    if g_server ~= nil then
        g_server:broadcastEvent(TCStaffCandidateAddedEvent.new(candidate))
    end

    TCLog.info("TheContractor: staff pool gained candidate %d (%s, age %d, speed %d, potential %d, salary %.0f)",
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

    -- 040: holidays start, end and get booked after sickness, so a worker
    -- who's just recovered can go straight onto a holiday.
    g_currentMission.TheContractor.Holidays:onDayChanged()

    -- 054: training last, so anyone off sick or on holiday today is
    -- already marked as such, and misses their training day.
    g_currentMission.TheContractor.Training:onDayChanged()
    -- 090: office staff's courses.
    g_currentMission.TheContractor.Office:onDayChanged()

    -- 056: then today counts toward the month's workload, with every
    -- status settled.
    g_currentMission.TheContractor.Morale:onDayChanged()
end

-- Sickness (031, server-only, from the daily tick): sick workers count down
-- a day and come back idle when it runs out, then every other hired worker
-- rolls to fall sick (see the SICK_* tunables). Idle ones go off sick
-- straight away; busy ones get pendingSickDays, applied in setWorkerStatus
-- when they're next set idle. toRoll is gathered before anyone recovers, so
-- someone who only just got better doesn't roll the same day, and anyone
-- with sickness already pending doesn't roll again. Neither does anyone on
-- holiday (040).
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
            elseif worker.pendingSickDays == 0 and worker.status ~= TheContractorWorker.STATUS.HOLIDAY then
                table.insert(toRoll, worker)
            end
        end

        for _, workerId in ipairs(toRecover) do
            self:setWorkerStatus(farmId, workerId, TheContractorWorker.STATUS.IDLE)
        end

        local chance = TheContractorStaff.SICK_MAX_DAILY_CHANCE *
            g_currentMission.TheContractor.HealthSafety:getSicknessMultiplier(farmId)
        for _, worker in ipairs(toRoll) do
            if math.random() < chance * worker.sicknessPropensity then
                self:makeWorkerSick(farmId, worker)
            end
        end
    end
end

-- A worker falls sick (server-only): off sick now if idle, else once
-- they're back. Also used by tcWorker sick, whose forceInspection makes 055's
-- inspection certain if the farm has no H&S programme, and by 104's
-- workplace injuries, whose days are set by the injury rather than rolled
-- and whose isInjury changes the notification ("hurt at work", not "called
-- in sick").
function TheContractorStaff:makeWorkerSick(farmId, worker, forceInspection, days, isInjury)
    days = days or
        TheContractorStaff.rollSickDays(g_currentMission.TheContractor.HealthSafety:getExtraDayChance(farmId))
    worker.isInjured = isInjury == true

    if worker:isIdle() then
        TCLog.info("TheContractor: farm %d worker %d (%s) off sick for %d day(s)", farmId, worker.id,
            worker.name, days)
        worker.sickDaysRemaining = days
        self:setWorkerStatus(farmId, worker.id, TheContractorWorker.STATUS.SICK)
    else
        TCLog.info("TheContractor: farm %d worker %d (%s) fell ill on a job, off sick for %d day(s) once back",
            farmId, worker.id, worker.name, days)
        worker.pendingSickDays = days
    end

    g_currentMission.TheContractor.HealthSafety:onWorkerFellSick(farmId, worker, forceInspection)
end

-- 1 day, plus extraDayChance (SICK_EXTRA_DAY_CHANCE, lower with 055's H&S
-- programme) of each further day up to SICK_MAX_DAYS.
function TheContractorStaff.rollSickDays(extraDayChance)
    extraDayChance = extraDayChance or TheContractorStaff.SICK_EXTRA_DAY_CHANCE
    local days = 1
    while days < TheContractorStaff.SICK_MAX_DAYS and math.random() < extraDayChance do
        days = days + 1
    end
    return days
end

-- Leavers go first, so nobody is paid for a period they've already
-- retired (or quit) at the start of.
function TheContractorStaff:onPeriodChanged()
    self:retireDueWorkers()
    self:paySalaries()
    self:ageWorkers()
    -- 056: morale drifts, the unhappy may quit, and in August everyone asks
    -- about a harvest bonus. After the birthday roll, so a worker who's
    -- just decided to retire doesn't quit as well.
    g_currentMission.TheContractor.Morale:onPeriodChanged()
    -- 058: anniversary pay reviews, after the drift (which ran on last
    -- month's pay) and the quit rolls, so nobody leaving asks.
    g_currentMission.TheContractor.PayReviews:onPeriodChanged()
    -- 054: ready workers may ask for training.
    g_currentMission.TheContractor.Training:onPeriodChanged()
end

-- Salaries (036, server-only, from the period tick): one charge per farm for
-- its whole roster and office staff (057, 090), plus the workplace
-- pension on top (051). Charged even if the farm can't afford it - it just
-- goes negative, like any vanilla expense. Money syncs through vanilla, so
-- no event of our own.
function TheContractorStaff:paySalaries()
    local farmIds = {}
    for farmId in pairs(self.workersByFarm) do
        farmIds[farmId] = true
    end
    for _, farmId in ipairs(g_currentMission.TheContractor.Office:getFarmIds()) do
        farmIds[farmId] = true
    end

    for farmId in pairs(farmIds) do
        local salary = self:getPayroll(farmId)
        -- 097: and last month's overtime.
        local overtime = g_currentMission.TheContractor.WorkingHours:takeOvertime(farmId)
        local pension = self:getWageBill(farmId) - salary
        local total = salary + pension + overtime
        if total > 0 and g_farmManager:getFarmById(farmId) ~= nil then
            g_currentMission:addMoney(-total, farmId, MoneyType.TC_WAGES, true, true)
            g_currentMission.TheContractor.Finances:recordWages(farmId, total)
            TCLog.info("TheContractor: farm %d paid %.0f in staff salaries, %.0f in overtime and %.0f in pension contributions",
                farmId, salary, overtime, pension)
        end
    end
end

-- Birthdays (030 follow-up): everyone whose birthPeriod is the period just
-- starting - pool candidates and hired workers alike - turns a year older.
-- growthPotential is left alone; it's rolled from age once, at creation.
-- One broadcast for the whole batch. Hired workers then roll to retire
-- (039), more likely when their morale is low (056).
function TheContractorStaff:ageWorkers()
    local period = g_currentMission.environment.currentPeriod
    local aged = {}
    local hiredBirthdays = {}

    local function ageIfBirthday(worker)
        if worker.birthPeriod == period then
            worker.age = worker.age + 1
            table.insert(aged, { id = worker.id, age = worker.age })
            return true
        end
        return false
    end

    for _, candidate in pairs(self.candidatePool) do
        ageIfBirthday(candidate)
    end
    for _, farmWorkers in pairs(self.workersByFarm) do
        for _, worker in pairs(farmWorkers) do
            if ageIfBirthday(worker) then
                table.insert(hiredBirthdays, worker)
            end
        end
    end

    if #aged == 0 then
        return
    end

    TCLog.info("TheContractor: %d staff/candidates had a birthday in period %d", #aged, period)

    if g_server ~= nil then
        g_server:broadcastEvent(TCWorkersAgedEvent.new(aged))
    end

    for _, worker in ipairs(hiredBirthdays) do
        local chance = TheContractorStaff.getRetirementChance(worker.age) *
            TheContractorMorale.getRetirementMultiplier(worker)
        if not worker:isLeaving() and math.random() < chance then
            self:announceLeaving(worker.farmId, worker.id, TheContractorStaff.RETIREMENT_NOTICE_MONTHS, false)
        end
    end
end

-- Retirement (039, server-authoritative) ----------------------------------

-- The birthday roll's chance at `age` - see the RETIREMENT_* tunables.
function TheContractorStaff.getRetirementChance(age)
    local minAge, certainAge = TheContractorStaff.RETIREMENT_MIN_AGE, TheContractorStaff.RETIREMENT_CERTAIN_AGE
    if age < minAge then
        return 0
    end

    local t = math.min(1, (age - minAge) / (certainAge - minAge))
    local minChance = TheContractorStaff.RETIREMENT_MIN_CHANCE
    return minChance + (1 - minChance) * t ^ TheContractorStaff.RETIREMENT_CURVE_EXPONENT
end

-- The worker hands in their notice: they leave at the start of the period
-- noticeMonths from now (0 = due now, for the tcWorker retire/quit console
-- commands) - retiring, or quitting (056) if isQuitting. The farm gets a
-- notification and an Overview notice (038), which stays up until they
-- actually leave.
function TheContractorStaff:announceLeaving(farmId, workerId, noticeMonths, isQuitting)
    if not g_currentMission:getIsServer() then
        return
    end

    local worker = self:getWorker(farmId, workerId)
    if worker == nil or worker:isLeaving() then
        return
    end

    local leavesAtPeriod = TCCalendar.getPeriodIndex() + noticeMonths
    self:applyLeavingAnnounced(farmId, workerId, leavesAtPeriod, isQuitting)

    worker.leavingNoticeId = g_currentMission.TheContractor.Notices:publish(farmId,
        string.format(g_i18n:getText(isQuitting and "tc_morale_quitNotice" or "tc_retirement_notice"), worker.name,
            TCCalendar.formatPeriodIndex(leavesAtPeriod)))

    TCLog.info("TheContractor: farm %d worker %d (%s, age %d, morale %.1f) %s at period %d", farmId, workerId,
        worker.name, worker.age, worker.morale, isQuitting and "quits" or "retires", leavesAtPeriod)

    -- The host's own notification - the broadcast below doesn't loop back
    -- to it (see src/events/README.md).
    TCWorkerRetirementAnnouncedEvent.showNotification(worker)

    if g_server ~= nil then
        g_server:broadcastEvent(TCWorkerRetirementAnnouncedEvent.new(farmId, workerId, leavesAtPeriod, isQuitting))
    end

    -- Already due (noticeMonths 0) and free to go.
    if TheContractorStaff.canLeaveNow(worker) then
        self:retireDueWorkers()
    end
end

function TheContractorStaff:applyLeavingAnnounced(farmId, workerId, leavesAtPeriod, isQuitting)
    local worker = self:getWorker(farmId, workerId)
    if worker ~= nil then
        worker.leavesAtPeriod = leavesAtPeriod
        worker.isQuitting = isQuitting
    end
end

-- Idle, off sick, on holiday (040) or training (054) - not out on a job or
-- driving.
function TheContractorStaff.canLeaveNow(worker)
    local status = worker.status
    return status == TheContractorWorker.STATUS.IDLE or status == TheContractorWorker.STATUS.SICK or
        status == TheContractorWorker.STATUS.HOLIDAY or status == TheContractorWorker.STATUS.TRAINING
end

-- From the period tick: everyone past their date who's idle, off sick or on
-- holiday leaves now. Anyone out on a job or driving goes once they're set
-- idle (setWorkerStatus).
function TheContractorStaff:retireDueWorkers()
    local due = {}
    for farmId, farmWorkers in pairs(self.workersByFarm) do
        for workerId, worker in pairs(farmWorkers) do
            if worker:isLeaveDue() and TheContractorStaff.canLeaveNow(worker) then
                table.insert(due, { farmId = farmId, workerId = workerId })
            end
        end
    end

    for _, entry in ipairs(due) do
        self:retireWorker(entry.farmId, entry.workerId)
    end
end

-- Leaves the roster like a released worker, and takes their notice down.
-- Also how a worker who's quit (056) goes: no notice or redundancy pay, and
-- no knock to anyone else's morale.
function TheContractorStaff:retireWorker(farmId, workerId)
    if not g_currentMission:getIsServer() then
        return
    end

    local worker = self:getWorker(farmId, workerId)
    if worker == nil then
        return
    end

    g_currentMission.TheContractor.Notices:remove(worker.leavingNoticeId)
    -- 097: any overtime they've done this month.
    g_currentMission.TheContractor.WorkingHours:payLeaver(farmId, worker)

    TCLog.info("TheContractor: farm %d worker %d (%s) %s at %d", farmId, workerId, worker.name,
        worker.isQuitting and "quit" or "retired", worker.age)

    -- The host's own notification, while the worker's still on the roster.
    TCWorkerRetiredEvent.showNotification(worker)
    self:applyWorkerReleased(farmId, workerId)

    if g_server ~= nil then
        g_server:broadcastEvent(TCWorkerRetiredEvent.new(farmId, workerId))
    end

    -- 040: any holiday they'd booked comes off the Overview.
    g_currentMission.TheContractor.Holidays:refreshNotices(farmId)
    -- 089: and any holiday request leaves the inbox.
    g_currentMission.TheContractor.Holidays:removeMessagesFor(farmId, workerId)
    -- 054: and any training message about them leaves the inbox.
    g_currentMission.TheContractor.Training:removeMessagesFor(farmId, workerId)
    -- 058: and any pay review.
    g_currentMission.TheContractor.PayReviews:removeMessagesFor(farmId, workerId)
    -- 083: and any rival's offer.
    g_currentMission.TheContractor.Poaching:onWorkerGone(farmId, workerId)
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

    local firstPay = TheContractorStaff.scalePay(candidate.salary)
    if not self:canAffordHire(farmId, firstPay) then
        return nil
    end

    g_currentMission:addMoney(-firstPay, farmId, MoneyType.TC_WAGES, true, true)
    g_currentMission.TheContractor.Finances:recordWages(farmId, firstPay)

    candidate.farmId = farmId
    -- 040: before the broadcast, so the allowance goes out with them.
    TheContractorHolidays.grantInitialAllowance(candidate)
    -- 056: likewise their starting morale and hire date.
    candidate.morale = TheContractorWorker.MORALE_START
    candidate.hiredPeriod = TCCalendar.getPeriodIndex()
    candidate.busyDays = 0
    candidate.idleDays = 0
    -- 058: paid what they asked for, and happy with it.
    candidate.expectedSalary = candidate.salary
    candidate.lastReviewPeriod = nil
    self:applyWorkerHired(candidate)

    if g_server ~= nil then
        g_server:broadcastEvent(TCWorkerHiredEvent.new(candidate))
    end

    -- 051: employing anyone needs employer's liability insurance.
    g_currentMission.TheContractor.Overheads:ensureRequired(farmId)

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

    TCLog.info("TheContractor: farm %d hired worker %d (%s, speed %d, salary %.0f)", worker.farmId, worker.id,
        worker.name, worker.workSpeed, worker.salary)
end

-- Releasing (server-authoritative) ----------------------------------------

-- Letting someone go (056) costs UK statutory pay, at 1x UK like the
-- salaries:
-- - Notice pay, paid in lieu as a lump sum: a week's pay per full year of
--   service, NOTICE_MIN_WEEKS-NOTICE_MAX_WEEKS.
-- - Redundancy pay from REDUNDANCY_MIN_YEARS of service: for each full year
--   (the most recent REDUNDANCY_MAX_YEARS), half a week's pay for a year
--   worked under REDUNDANCY_YOUNG_AGE, one week up to REDUNDANCY_OLDER_AGE,
--   one and a half from then on. A week's pay is capped at
--   REDUNDANCY_WEEKLY_PAY_CAP (the statutory cap, 2025) for this part only.
-- A worker who's already leaving (retiring or quitting) is paid only for
-- the notice they have left, and no redundancy.
TheContractorStaff.WEEKS_PER_YEAR = 52
TheContractorStaff.NOTICE_MIN_WEEKS = 1
TheContractorStaff.NOTICE_MAX_WEEKS = 12
TheContractorStaff.REDUNDANCY_MIN_YEARS = 2
TheContractorStaff.REDUNDANCY_MAX_YEARS = 20
TheContractorStaff.REDUNDANCY_YOUNG_AGE = 22
TheContractorStaff.REDUNDANCY_OLDER_AGE = 41
TheContractorStaff.REDUNDANCY_WEEKLY_PAY_CAP = 719

-- Full years since they were hired (0 until an old save's worker gets a
-- hire date - see TheContractorMorale:onDayChanged).
function TheContractorStaff.getYearsOfService(worker)
    if worker.hiredPeriod == nil then
        return 0
    end
    return math.max(0, math.floor((TCCalendar.getPeriodIndex() - worker.hiredPeriod) / Environment.PERIODS_IN_YEAR))
end

-- From this month's pay (scalePay), unrounded.
function TheContractorStaff.getWeeklyPay(worker)
    return worker.salary * TheContractorStaff.getPayFactor() * TCEconomyScale.getFactor() *
        Environment.PERIODS_IN_YEAR / TheContractorStaff.WEEKS_PER_YEAR
end

-- What releasing the worker today costs. Every machine works it out the
-- same way, so the confirm dialog shows what the server will charge.
-- Returns { years, noticeWeeks, noticePay, redundancyWeeks, redundancyPay,
-- total }, pay in whole money.
function TheContractorStaff.getReleaseCost(worker)
    local years = TheContractorStaff.getYearsOfService(worker)
    local weeklyPay = TheContractorStaff.getWeeklyPay(worker)
    local noticeWeeks = math.max(TheContractorStaff.NOTICE_MIN_WEEKS, math.min(TheContractorStaff.NOTICE_MAX_WEEKS,
        years))
    local redundancyWeeks = 0

    if worker:isLeaving() then
        local monthsLeft = math.max(0, worker.leavesAtPeriod - TCCalendar.getPeriodIndex())
        noticeWeeks = math.min(noticeWeeks,
            monthsLeft * TheContractorStaff.WEEKS_PER_YEAR / Environment.PERIODS_IN_YEAR)
    elseif years >= TheContractorStaff.REDUNDANCY_MIN_YEARS then
        for i = 1, math.min(years, TheContractorStaff.REDUNDANCY_MAX_YEARS) do
            local ageThatYear = worker.age - i
            if ageThatYear < TheContractorStaff.REDUNDANCY_YOUNG_AGE then
                redundancyWeeks = redundancyWeeks + 0.5
            elseif ageThatYear < TheContractorStaff.REDUNDANCY_OLDER_AGE then
                redundancyWeeks = redundancyWeeks + 1
            else
                redundancyWeeks = redundancyWeeks + 1.5
            end
        end
    end

    local noticePay = math.floor(noticeWeeks * weeklyPay + 0.5)
    local redundancyPay = math.floor(redundancyWeeks *
        math.min(weeklyPay, TheContractorStaff.REDUNDANCY_WEEKLY_PAY_CAP) + 0.5)
    return {
        years = years,
        noticeWeeks = noticeWeeks,
        noticePay = noticePay,
        redundancyWeeks = redundancyWeeks,
        redundancyPay = redundancyPay,
        total = noticePay + redundancyPay,
    }
end

-- Fires a hired worker from farmId's roster (017's Staff UI roster
-- management action) — no move back into the candidate pool (a released
-- worker is just gone, not recycled). 056: charges notice and redundancy
-- pay (getReleaseCost) under TC_WAGES, even into the red, since it's owed,
-- and everyone left on the roster takes a morale knock. Returns true if a
-- worker was actually removed. Unlike hiring there's no race to arbitrate:
-- only the owning farm can ever reference a workerId that's in its own
-- roster, so no re-check-then-act window exists for another farm to
-- interfere with.
function TheContractorStaff:releaseWorker(farmId, workerId)
    if not g_currentMission:getIsServer() then
        return false
    end

    local farmWorkers = self.workersByFarm[farmId]
    if farmWorkers == nil or farmWorkers[workerId] == nil then
        return false
    end

    local worker = farmWorkers[workerId]

    -- 037: their vehicle has to stop first (see TheContractorDrivers).
    if worker.status == TheContractorWorker.STATUS.DRIVING then
        return false
    end

    -- 056: what they're owed.
    local cost = TheContractorStaff.getReleaseCost(worker)
    if cost.total > 0 then
        g_currentMission:addMoney(-cost.total, farmId, MoneyType.TC_WAGES, true, true)
        g_currentMission.TheContractor.Finances:recordWages(farmId, cost.total)
    end

    -- 039: their retirement (or 056 quitting) notice goes with them.
    g_currentMission.TheContractor.Notices:remove(worker.leavingNoticeId)
    -- 097: any overtime they've done this month.
    g_currentMission.TheContractor.WorkingHours:payLeaver(farmId, worker)

    self:applyWorkerReleased(farmId, workerId)

    if g_server ~= nil then
        g_server:broadcastEvent(TCWorkerReleasedEvent.new(farmId, workerId))
    end

    -- 040: any holiday they'd booked comes off the Overview.
    g_currentMission.TheContractor.Holidays:refreshNotices(farmId)
    -- 089: and any holiday request leaves the inbox.
    g_currentMission.TheContractor.Holidays:removeMessagesFor(farmId, workerId)
    -- 054: and any training message about them leaves the inbox.
    g_currentMission.TheContractor.Training:removeMessagesFor(farmId, workerId)
    -- 058: and any pay review.
    g_currentMission.TheContractor.PayReviews:removeMessagesFor(farmId, workerId)
    -- 083: and any rival's offer.
    g_currentMission.TheContractor.Poaching:onWorkerGone(farmId, workerId)

    TCLog.info("TheContractor: farm %d released worker %d (%s) after %d year(s): %.1f weeks' notice pay (%.0f), %.1f weeks' redundancy pay (%.0f)",
        farmId, workerId, worker.name, cost.years, cost.noticeWeeks, cost.noticePay, cost.redundancyWeeks,
        cost.redundancyPay)

    -- 056: the rest of the staff don't like seeing it.
    g_currentMission.TheContractor.Morale:onColleagueReleased(farmId)

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

-- Flips a hired worker's status (idle/assigned/cooldown/sick/driving/holiday/training) and broadcasts it —
-- first driven by allocation (018, idle -> assigned on a successful
-- allocateJob), later tickets (022/023) will flip it back on
-- completion/cooldown. Broadcasts just the changed field
-- (TCWorkerStatusChangedEvent) rather than a full worker snapshot, since
-- status is the only thing this ever moves on its own.
function TheContractorStaff:setWorkerStatus(farmId, workerId, status)
    if not g_currentMission:getIsServer() then
        return
    end

    -- 039: someone whose retirement date came while they were out on a job
    -- (or driving) leaves the moment they're back, rather than going idle.
    local worker = self:getWorker(farmId, workerId)
    if worker ~= nil and status == TheContractorWorker.STATUS.IDLE and worker:isLeaveDue() then
        self:retireWorker(farmId, workerId)
        return
    end

    -- 040: someone back from a job (or driving) during their booked holiday
    -- goes straight on it, for whatever's left. The holiday takes over from
    -- any sickness they picked up on the job.
    if worker ~= nil and status == TheContractorWorker.STATUS.IDLE and
            worker:isHolidayOn(g_currentMission.environment.currentMonotonicDay) then
        TCLog.info("TheContractor: farm %d worker %d (%s) back during their holiday, now on holiday", farmId,
            workerId, worker.name)
        worker.pendingSickDays = 0
        status = TheContractorWorker.STATUS.HOLIDAY
    end

    -- 031: someone who fell ill while out on a job goes off sick, not idle,
    -- when they get back.
    if worker ~= nil and status == TheContractorWorker.STATUS.IDLE and worker.pendingSickDays > 0 then
        TCLog.info("TheContractor: farm %d worker %d (%s) back from their job, now off sick for %d day(s)", farmId,
            workerId, worker.name, worker.pendingSickDays)
        worker.sickDaysRemaining = worker.pendingSickDays
        worker.pendingSickDays = 0
        status = TheContractorWorker.STATUS.SICK
    end

    -- 054: someone back on a day they're due in for training goes straight
    -- there. Sickness comes first: they miss the day, and it slides.
    if worker ~= nil and status == TheContractorWorker.STATUS.IDLE and TheContractorTraining.isDueToday(worker) then
        TCLog.info("TheContractor: farm %d worker %d (%s) back on a training day, now training", farmId, workerId,
            worker.name)
        status = TheContractorWorker.STATUS.TRAINING
    end

    local oldStatus = self:applyWorkerStatusChanged(farmId, workerId, status)

    -- The host's own notification - the broadcast below doesn't loop back
    -- to it (see src/events/README.md).
    -- Going off sick: how long for, and whether it's an injury (104), for
    -- the notification. Clients don't hold either.
    local sickDays, isInjury = 0, false
    if worker ~= nil and status == TheContractorWorker.STATUS.SICK then
        sickDays, isInjury = worker.sickDaysRemaining, worker.isInjured
    end
    TCWorkerStatusChangedEvent.showNotification(self:getWorker(farmId, workerId), oldStatus, status, sickDays,
        isInjury)

    if g_server ~= nil then
        g_server:broadcastEvent(TCWorkerStatusChangedEvent.new(farmId, workerId, status, sickDays, isInjury))
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
-- 035) gets one growth roll against their ratings for it (044: the tractor
-- tier they drove and the operation skill the job used). A player-driven
-- job has no worker, so nothing grows.
function TheContractorStaff:applyGrowthFromJob(job)
    if not g_currentMission:getIsServer() then
        return
    end

    if job.assignedWorkerId ~= nil then
        self:rollWorkerGrowth(job, job.assignedWorkerId, job.assignedEquipmentIds, false)
    end
    if job.haulerWorkerId ~= nil then
        self:rollWorkerGrowth(job, job.haulerWorkerId, job.haulageEquipmentIds, true)
    end
end

function TheContractorStaff:rollWorkerGrowth(job, workerId, equipmentIds, isHauler)
    local worker = self:getWorker(job.farmId, workerId)
    if worker == nil then
        return
    end

    local ratings = g_currentMission.TheContractor.Allocation:getWorkerJobRatings(worker, job, equipmentIds,
        isHauler)
    local rating = TheContractorAllocation.getWeakestRating(ratings)

    local stretch = 1
    if rating ~= nil then
        if rating <= job.requiredSkillLevel then
            stretch = TheContractorStaff.GROWTH_STRETCH_MULTIPLIER
        elseif rating > job.requiredSkillLevel + TheContractorStaff.GROWTH_EASY_MARGIN then
            stretch = TheContractorStaff.GROWTH_EASY_MULTIPLIER
        end
    end

    local quality = TheContractorStaff.getGrowthQualityMultiplier(job.qualityScore)
    -- 056: happy staff learn a little faster.
    local morale = TheContractorMorale.getGrowthMultiplier(worker)
    self:growWorker(job.farmId, workerId, ratings.tractorTier, ratings.operationSkill,
        TheContractorStaff.GROWTH_BASE_CHANCE * stretch * quality * morale)
end

-- The job's quality score (029) as a growth multiplier (080): against
-- GROWTH_QUALITY_REFERENCE, an ordinary qualified crew's score, so a job
-- like that grows workers at the base rate, capped at GROWTH_QUALITY_MAX.
function TheContractorStaff.getGrowthQualityMultiplier(qualityScore)
    return math.min(TheContractorStaff.GROWTH_QUALITY_MAX,
        (qualityScore or 100) / 100 / TheContractorStaff.GROWTH_QUALITY_REFERENCE)
end

-- A growth roll, wherever it came from (a completed job above, or driving
-- under AutoDrive/Courseplay - 037's TheContractorDrivers): picks a stat
-- with pickGrowth for `tier` (nil if the equipment had no tier) and
-- operation `skill` (044, nil if the work didn't map to one), then rolls
-- `chance` x that stat's GROWTH_LEVEL_MULTIPLIERS (no `chance`: it grows).
-- A success spends one growthPotential point (none under
-- GROWTH_FREE_BELOW) and tells everyone. With no potential left, only the
-- free stats can be picked.
function TheContractorStaff:growWorker(farmId, workerId, tier, skill, chance)
    local worker = self:getWorker(farmId, workerId)
    if worker == nil then
        return
    end

    local freeOnly = worker.growthPotential <= 0
    local rating = tier ~= nil and worker:getTierCapability(tier) or nil
    local stat, value = TheContractorStaff.pickGrowth(worker, tier, rating, skill, freeOnly)
    if stat == nil then
        -- Nothing left that can move (everything maxed, or no potential
        -- and nothing basic left); any leftover potential goes unused.
        return
    end

    local oldValue = worker:getStat(stat)
    if chance ~= nil and math.random() >= TheContractorStaff.getGrowthChance(chance, oldValue) then
        return
    end

    if not TheContractorStaff.isFreeGrowth(oldValue) then
        worker.growthPotential = worker.growthPotential - 1
    end
    self:raiseWorkerStat(farmId, worker, stat, value)
end

-- A growth roll's chance for a stat currently at `currentValue` (nil for a
-- new certification).
function TheContractorStaff.getGrowthChance(chance, currentValue)
    local multipliers = TheContractorStaff.GROWTH_LEVEL_MULTIPLIERS
    local multiplier = currentValue ~= nil and multipliers[math.max(1, math.min(#multipliers, currentValue))] or 1
    return math.min(TheContractorStaff.GROWTH_MAX_CHANCE, chance * multiplier)
end

-- Growing from `currentValue` costs no growthPotential (a new
-- certification always costs one).
function TheContractorStaff.isFreeGrowth(currentValue)
    return currentValue ~= nil and currentValue < TheContractorStaff.GROWTH_FREE_BELOW
end

-- 074: one point on a stat (a tier rating or operation skill) that doesn't
-- come out of growthPotential - a worker stepping up. Returns the new value,
-- or nil if the stat's already at its maximum.
function TheContractorStaff:boostWorker(farmId, workerId, stat)
    local worker = self:getWorker(farmId, workerId)
    local oldValue = worker ~= nil and worker:getStat(stat) or nil
    if oldValue == nil or oldValue >= TheContractorWorker.MAX_SKILL then
        return nil
    end
    self:raiseWorkerStat(farmId, worker, stat, oldValue + 1)
    return oldValue + 1
end

-- Sets a grown stat and tells everyone. A tier reaching the threshold
-- qualifies them on the next one up too, for the same point (see
-- GROWTH_WEIGHTS above).
function TheContractorStaff:raiseWorkerStat(farmId, worker, stat, value)
    self:announceGrowth(farmId, worker, stat, value)

    local nextTier = TheContractorStaff.getNextTier(stat)
    if nextTier ~= nil and value >= TheContractorStaff.CERTIFY_THRESHOLD and not worker:isCapableOfTier(nextTier) then
        self:announceGrowth(farmId, worker, nextTier, TheContractorStaff.CERTIFY_START_RATING)
    end
end

-- Applies one stat change on the server and tells everyone.
function TheContractorStaff:announceGrowth(farmId, worker, stat, value)
    local oldValue = worker:getStat(stat)
    self:applyWorkerGrowth(farmId, worker.id, stat, value)

    TCLog.info("TheContractor: farm %d worker %d (%s) grew %s %s -> %d, %d potential left", farmId,
        worker.id, worker.name, stat, tostring(oldValue), value, worker.growthPotential)

    -- The host's own notification - the broadcast below doesn't loop back
    -- to it (see src/events/README.md).
    TCWorkerGrewEvent.showNotification(worker, stat, oldValue, value)

    if g_server ~= nil then
        g_server:broadcastEvent(TCWorkerGrewEvent.new(farmId, worker.id, stat, value))
    end
end

-- Weighted pick (GROWTH_WEIGHTS) among the growths still possible for this
-- worker after a job on `tier` (nil if the equipment had no tier) using
-- operation `skill` (nil if none). `freeOnly`: only stats that would grow
-- for free (isFreeGrowth). Returns stat, newValue - or nil if none are
-- possible.
function TheContractorStaff.pickGrowth(worker, tier, rating, skill, freeOnly)
    local weights = TheContractorStaff.GROWTH_WEIGHTS
    local options = {}

    if worker.workSpeed < TheContractorWorker.MAX_WORK_SPEED then
        table.insert(options, { stat = "workSpeed", value = worker.workSpeed + 1, weight = weights.workSpeed })
    end

    if skill ~= nil and worker:getSkill(skill) < TheContractorWorker.MAX_SKILL then
        table.insert(options, { stat = skill, value = worker:getSkill(skill) + 1, weight = weights.skill })
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

    if freeOnly then
        local free = {}
        for _, option in ipairs(options) do
            if TheContractorStaff.isFreeGrowth(worker:getStat(option.stat)) then
                table.insert(free, option)
            end
        end
        options = free
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
-- tracked on the server, so it isn't touched here. 058: pay stays put -
-- the new stats only raise their market value, worked out live.
function TheContractorStaff:applyWorkerGrowth(farmId, workerId, stat, value)
    local worker = self:getWorker(farmId, workerId)
    if worker == nil then
        return
    end

    worker:setStat(stat, value)
end

-- Editing (066) ------------------------------------------------------------
-- The player can rename a hired worker, change their gender and re-roll
-- their look (TCEditPersonDialog, or tcWorker rename). Cosmetic and free.
-- Changing gender never touches the name.

-- Characters, like the Create Company prompt.
TheContractorStaff.NAME_MAX_LENGTH = 30

-- The name trimmed, or nil if that leaves nothing or it's too long.
function TheContractorStaff.cleanName(name)
    if name == nil then
        return nil
    end
    name = string.match(name, "^%s*(.-)%s*$")
    local length = utf8Strlen ~= nil and utf8Strlen(name) or string.len(name)
    if length == 0 or length > TheContractorStaff.NAME_MAX_LENGTH then
        return nil
    end
    return name
end

-- Why an edit can't be applied, or nil. For the log and the console.
function TheContractorStaff.getEditProblem(name, gender, appearance)
    if TheContractorStaff.cleanName(name) == nil then
        return string.format("the name must be 1-%d characters", TheContractorStaff.NAME_MAX_LENGTH)
    end
    if gender ~= TCWorkerAppearance.GENDER.MALE and gender ~= TCWorkerAppearance.GENDER.FEMALE then
        return "unknown gender " .. tostring(gender)
    end
    if not TCWorkerAppearance.isValidLook(appearance, gender) then
        return "that look can't be built for a " .. gender .. " worker"
    end
    return nil
end

-- 090: a hired worker, or one of the farm's office staff (they're edited
-- the same way, through the same events), or nil.
function TheContractorStaff:getEditablePerson(farmId, workerId)
    local worker = self:getWorker(farmId, workerId)
    if worker ~= nil then
        return worker, false
    end
    local office = g_currentMission.TheContractor.Office
    if office ~= nil then
        local member = office:getMemberById(farmId, workerId)
        if member ~= nil then
            return member, true
        end
    end
    return nil, false
end

-- Server. Returns nil once applied, or why it wasn't.
function TheContractorStaff:editWorker(farmId, workerId, name, gender, appearance)
    local worker = self:getEditablePerson(farmId, workerId)
    if worker == nil then
        return string.format("farm %d has no worker %d", farmId, workerId)
    end
    local problem = TheContractorStaff.getEditProblem(name, gender, appearance)
    if problem ~= nil then
        TCLog.warning("TheContractor: edit of worker %d (%s) refused: %s", workerId, worker.name, problem)
        return problem
    end

    name = TheContractorStaff.cleanName(name)
    TCLog.info("TheContractor: farm %d worker %d edited: %s -> %s, %s -> %s", farmId, workerId, worker.name, name,
        worker.gender, gender)
    self:applyWorkerEdited(farmId, workerId, name, gender, appearance)

    if g_server ~= nil then
        g_server:broadcastEvent(TCWorkerEditedEvent.new(farmId, workerId, name, gender, appearance))
    end
    return nil
end

-- At mission start (FSBaseMission.onStartMission), once every mod's loadMap
-- has run. Wardrobe mods (FS25_WardrobeClothingAddon_BMP) add their clothes
-- to the player models in their own loadMap, and ours runs before theirs, so
-- a look built while the save loads can't find those items: it quietly
-- falls back to the model's defaults, or fails and is rerolled for good.
-- So nothing is built until now. Any style built early goes, and on the
-- server a worker with no look (a save from before 041) or one that can't
-- be rebuilt any more (its model or mod has gone) gets a new one.
function TheContractorStaff:restoreLooks()
    local isServer = g_currentMission:getIsServer()
    local function restore(worker)
        worker.playerStyle = nil
        if isServer and TCWorkerAppearance.needsReroll(worker) then
            worker.appearance = TCWorkerAppearance.roll(worker.gender)
            worker.playerStyle = nil
        end
    end

    for _, candidate in pairs(self.candidatePool) do
        restore(candidate)
    end
    for _, farmWorkers in pairs(self.workersByFarm) do
        for _, worker in pairs(farmWorkers) do
            restore(worker)
        end
    end
    -- 090: office staff have looks too.
    local office = g_currentMission.TheContractor ~= nil and g_currentMission.TheContractor.Office or nil
    if office ~= nil then
        for _, members in pairs(office.membersByFarm) do
            for _, member in pairs(members) do
                restore(member)
            end
        end
    end
end

-- Every machine. The cached PlayerStyle goes, so the next look-up builds
-- the new one; the portrait and standing spot reload theirs. A worker in a
-- cab keeps the old look until their next trip.
function TheContractorStaff:applyWorkerEdited(farmId, workerId, name, gender, appearance)
    local worker, isOffice = self:getEditablePerson(farmId, workerId)
    if worker == nil then
        return
    end

    if isOffice then
        g_currentMission.TheContractor.Office:applyEdited(worker, name, gender, appearance)
    else
        worker.name = name
        worker.gender = gender
        worker.appearance = appearance
        worker.playerStyle = nil
    end

    TCIdleStaff.reloadLook(worker)
    local menu = g_currentMission.TheContractor.MenuContractor
    if menu ~= nil then
        menu:onWorkerEdited(workerId)
    end
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
    -- 039: 0 = not leaving (period indexes start at 1). 056: or quitting.
    streamWriteInt32(streamId, worker.leavesAtPeriod or 0)
    streamWriteBool(streamId, worker.isQuitting)
    -- 040: holidayStartDay 0 = nothing booked (monotonic days start at 1).
    -- holidayYear/holidayDaysPerPeriod stay server-side.
    streamWriteFloat32(streamId, worker.holidayAllowance)
    streamWriteInt32(streamId, worker.holidayStartDay or 0)
    streamWriteInt32(streamId, worker.holidayDays)
    -- 041: every machine builds the cab look itself (TCWorkerAppearance).
    streamWriteString(streamId, worker.gender)
    TCWorkerAppearance.writeStream(streamId, worker.appearance)

    for _, tier in ipairs(TheContractorWorker.TIERS) do
        local rating = worker.tierCapability[tier]
        streamWriteBool(streamId, rating ~= nil)
        if rating ~= nil then
            streamWriteInt32(streamId, rating)
        end
    end

    -- 044: every worker has every skill.
    for _, skill in ipairs(TheContractorWorker.SKILLS) do
        streamWriteUInt8(streamId, worker:getSkill(skill))
    end
    -- 045.
    streamWriteUInt8(streamId, worker.cleanliness)
    -- 054.
    TheContractorTraining.writeState(streamId, worker)
    -- 056.
    TheContractorMorale.writeState(streamId, worker)
    -- 058.
    TheContractorPayReviews.writeState(streamId, worker)
    -- 091.
    TheContractorWorkshop.writeState(streamId, worker)
    -- 097.
    TheContractorWorkingHours.writeState(streamId, worker)
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
    local leavesAtPeriod = streamReadInt32(streamId)
    local isQuitting = streamReadBool(streamId)
    local holidayAllowance = streamReadFloat32(streamId)
    local holidayStartDay = streamReadInt32(streamId)
    local holidayDays = streamReadInt32(streamId)
    local gender = streamReadString(streamId)
    local appearance = TCWorkerAppearance.readStream(streamId)

    local tierCapability = {}
    for _, tier in ipairs(TheContractorWorker.TIERS) do
        if streamReadBool(streamId) then
            tierCapability[tier] = streamReadInt32(streamId)
        end
    end

    local skills = {}
    for _, skill in ipairs(TheContractorWorker.SKILLS) do
        skills[skill] = streamReadUInt8(streamId)
    end
    local cleanliness = streamReadUInt8(streamId)
    local trainingState = TheContractorTraining.readState(streamId)
    local morale, hiredPeriod = TheContractorMorale.readState(streamId)
    local expectedSalary = TheContractorPayReviews.readState(streamId)
    local adsSkills, workshopRole = TheContractorWorkshop.readState(streamId)
    local dutyFrom, dutyArrive, dutyUntil, overtimeMinutes, overtimeOwed = TheContractorWorkingHours.readState(streamId)

    local worker = TheContractorWorker.new(id, farmId, name, workSpeed, tierCapability, salary, age, nil, nil, nil,
        skills, cleanliness)
    worker.status = status
    worker.gender = gender
    worker.appearance = appearance
    if leavesAtPeriod > 0 then
        worker.leavesAtPeriod = leavesAtPeriod
    end
    worker.isQuitting = isQuitting
    worker.morale = morale
    worker.hiredPeriod = hiredPeriod
    worker.expectedSalary = expectedSalary
    worker.adsSkills = adsSkills
    worker.workshopRole = workshopRole
    worker.dutyFrom, worker.dutyArrive, worker.dutyUntil = dutyFrom, dutyArrive, dutyUntil
    worker.overtimeMinutes, worker.overtimeOwed = overtimeMinutes, overtimeOwed
    TheContractorHolidays.applyHolidayChanged(worker, holidayAllowance,
        holidayStartDay > 0 and holidayStartDay or nil, holidayDays)
    TheContractorTraining.applyState(worker, trainingState)

    return worker
end

-- Persistence -------------------------------------------------------------

function TheContractorStaff.writeWorkerXML(xmlFile, key, worker)
    setXMLInt(xmlFile, key .. "#id", worker.id)
    setXMLString(xmlFile, key .. "#name", worker.name)
    setXMLInt(xmlFile, key .. "#workSpeed", worker.workSpeed)
    -- 058: a hired worker's pay. A candidate's is recomputed on load.
    setXMLFloat(xmlFile, key .. "#salary", worker.salary)
    setXMLString(xmlFile, key .. "#status", worker.status)
    setXMLInt(xmlFile, key .. "#age", worker.age)
    setXMLInt(xmlFile, key .. "#growthPotential", worker.growthPotential)
    setXMLInt(xmlFile, key .. "#birthPeriod", worker.birthPeriod)
    setXMLFloat(xmlFile, key .. "#sicknessPropensity", worker.sicknessPropensity)
    setXMLString(xmlFile, key .. "#gender", worker.gender)
    TCWorkerAppearance.writeXML(xmlFile, key .. ".appearance", worker.appearance)
    if worker.status == TheContractorWorker.STATUS.SICK then
        setXMLInt(xmlFile, key .. "#sickDaysRemaining", worker.sickDaysRemaining)
    end
    if worker.pendingSickDays > 0 then
        setXMLInt(xmlFile, key .. "#pendingSickDays", worker.pendingSickDays)
    end
    if worker.isInjured and (worker.status == TheContractorWorker.STATUS.SICK or worker.pendingSickDays > 0) then
        setXMLBool(xmlFile, key .. "#injured", true)
    end
    if worker.leavesAtPeriod ~= nil then
        setXMLInt(xmlFile, key .. "#leavesAtPeriod", worker.leavesAtPeriod)
        if worker.isQuitting then
            setXMLBool(xmlFile, key .. "#isQuitting", true)
        end
    end
    if worker.leavingNoticeId ~= nil then
        setXMLInt(xmlFile, key .. "#leavingNoticeId", worker.leavingNoticeId)
    end
    -- 040: hired workers only - a candidate has no allowance yet.
    if worker.holidayYear ~= nil then
        setXMLFloat(xmlFile, key .. "#holidayAllowance", worker.holidayAllowance)
        setXMLInt(xmlFile, key .. "#holidayYear", worker.holidayYear)
    end
    if worker:hasHolidayBooked() then
        setXMLInt(xmlFile, key .. "#holidayStartDay", worker.holidayStartDay)
        setXMLInt(xmlFile, key .. "#holidayDays", worker.holidayDays)
        setXMLInt(xmlFile, key .. "#holidayDaysPerPeriod", worker.holidayDaysPerPeriod)
    end
    -- 089.
    if worker.holidayDeclines > 0 then
        setXMLInt(xmlFile, key .. "#holidayDeclines", worker.holidayDeclines)
    end

    for _, tier in ipairs(TheContractorWorker.TIERS) do
        local rating = worker.tierCapability[tier]
        if rating ~= nil then
            setXMLInt(xmlFile, key .. "#tier" .. tier, rating)
        end
    end

    for _, skill in ipairs(TheContractorWorker.SKILLS) do
        setXMLInt(xmlFile, key .. "#skill_" .. skill, worker:getSkill(skill))
    end
    setXMLInt(xmlFile, key .. "#cleanliness", worker.cleanliness)
    -- 054.
    TheContractorTraining.writeXML(xmlFile, key, worker)
    -- 056.
    TheContractorMorale.writeXML(xmlFile, key, worker)
    -- 058.
    TheContractorPayReviews.writeXML(xmlFile, key, worker)
    -- 091.
    TheContractorWorkshop.writeXML(xmlFile, key, worker)
    -- 097.
    TheContractorWorkingHours.writeXML(xmlFile, key, worker)
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

    -- 044: a worker saved before 044 has no skills - roll them now, as if
    -- they'd just joined the pool (and a skill added later gets a base roll).
    local skills = {}
    local hasSkills = false
    for _, skill in ipairs(TheContractorWorker.SKILLS) do
        skills[skill] = getXMLInt(xmlFile, key .. "#skill_" .. skill)
        hasSkills = hasSkills or skills[skill] ~= nil
    end
    if not hasSkills then
        skills = TheContractorStaff.rollSkills()
    end
    for _, skill in ipairs(TheContractorWorker.SKILLS) do
        if skills[skill] == nil then
            skills[skill] = math.random(TheContractorStaff.SKILL_BASE_MIN, TheContractorStaff.SKILL_BASE_MAX)
        end
        skills[skill] = math.max(TheContractorWorker.MIN_SKILL, math.min(TheContractorWorker.MAX_SKILL, skills[skill]))
    end

    -- 045: likewise a worker saved before 045.
    local cleanliness = getXMLInt(xmlFile, key .. "#cleanliness") or TheContractorStaff.rollCleanliness()
    cleanliness = math.max(TheContractorWorker.MIN_CLEANLINESS,
        math.min(TheContractorWorker.MAX_CLEANLINESS, cleanliness))

    -- A candidate's is always recomputed (036), so a retuned formula
    -- applies to the pool too. 058: a hired worker's is their saved pay (a
    -- pre-036 save's #hireCost is simply ignored). Saves from before 058
    -- are migrated in loadFromXMLFile.
    -- 091: before the salary, which counts them.
    local adsSkills = TheContractorWorkshop.readSkillsXML(xmlFile, key)
    local salary = TheContractorStaff.getSalary(workSpeed, tierCapability, skills, adsSkills)
    if farmId ~= nil then
        salary = getXMLFloat(xmlFile, key .. "#salary") or salary
    end

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
        growthPotential, birthPeriod, sicknessPropensity, skills, cleanliness)
    worker.status = Utils.getNoNil(getXMLString(xmlFile, key .. "#status"), worker.status)
    worker.adsSkills = adsSkills
    if farmId ~= nil then
        worker.workshopRole = TheContractorWorkshop.readRoleXML(xmlFile, key, adsSkills)
    end
    -- 041: a worker saved before 041 gets a gender from their name. Whether
    -- their look still builds is left to restoreLooks, at mission start.
    worker.gender = getXMLString(xmlFile, key .. "#gender") or TheContractorStaff.guessGender(name)
    worker.appearance = TCWorkerAppearance.readXML(xmlFile, key .. ".appearance")
    if worker.status == TheContractorWorker.STATUS.SICK then
        worker.sickDaysRemaining = math.max(1, getXMLInt(xmlFile, key .. "#sickDaysRemaining") or 1)
    end
    worker.pendingSickDays = getXMLInt(xmlFile, key .. "#pendingSickDays") or 0
    worker.isInjured = getXMLBool(xmlFile, key .. "#injured") or false
    -- 056 renamed these from retiresAtPeriod/retirementNoticeId.
    worker.leavesAtPeriod = getXMLInt(xmlFile, key .. "#leavesAtPeriod") or
        getXMLInt(xmlFile, key .. "#retiresAtPeriod")
    worker.isQuitting = worker.leavesAtPeriod ~= nil and (getXMLBool(xmlFile, key .. "#isQuitting") or false)
    worker.leavingNoticeId = getXMLInt(xmlFile, key .. "#leavingNoticeId") or
        getXMLInt(xmlFile, key .. "#retirementNoticeId")
    -- 040: a worker from a save made before 040 has no holidayYear, and
    -- gets their allowance at the next day change (Holidays:onDayChanged).
    worker.holidayYear = getXMLInt(xmlFile, key .. "#holidayYear")
    worker.holidayAllowance = getXMLFloat(xmlFile, key .. "#holidayAllowance") or 0
    local holidayStartDay = getXMLInt(xmlFile, key .. "#holidayStartDay")
    local holidayDays = getXMLInt(xmlFile, key .. "#holidayDays")
    local holidayDaysPerPeriod = getXMLInt(xmlFile, key .. "#holidayDaysPerPeriod")
    if holidayStartDay ~= nil and holidayDays ~= nil and holidayDays > 0 and holidayDaysPerPeriod ~= nil then
        worker.holidayStartDay = holidayStartDay
        worker.holidayDays = holidayDays
        worker.holidayDaysPerPeriod = holidayDaysPerPeriod
    end
    -- 089.
    worker.holidayDeclines = getXMLInt(xmlFile, key .. "#holidayDeclines") or 0
    -- 054.
    TheContractorTraining.readXML(xmlFile, key, worker)
    -- 056: a worker from a save made before 056 starts at MORALE_START and
    -- gets their hire date at the next day change (Morale:onDayChanged).
    TheContractorMorale.readXML(xmlFile, key, worker)
    -- 058.
    TheContractorPayReviews.readXML(xmlFile, key, worker)
    -- 097.
    TheContractorWorkingHours.readXML(xmlFile, key, worker)

    return worker
end

function TheContractorStaff:loadFromXMLFile(xmlFile)
    if not g_currentMission:getIsServer() then return end

    self.workersByFarm = {}
    self.candidatePool = {}
    self.nextWorkerId = 1

    local rootKey = string.format("%s.staff", TheContractor.SaveKey)
    self.nextWorkerId = Utils.getNoNil(getXMLInt(xmlFile, rootKey .. "#nextWorkerId"), 1)

    -- 054: a save from before certificates existed has no marker. Its
    -- workers are grandfathered once (TheContractorTraining.grandfather).
    local isPreCertification = getXMLInt(xmlFile, rootKey .. "#certificationVersion") == nil
    -- 058: likewise from before pay was fixed at hire. Its workers are paid
    -- their market value once (TheContractorPayReviews.migrate).
    local isPrePayReviews = getXMLInt(xmlFile, rootKey .. "#payVersion") == nil

    local poolIndex = 0
    while true do
        local candidateKey = string.format("%s.pool.candidate(%d)", rootKey, poolIndex)
        if not hasXMLProperty(xmlFile, candidateKey) then
            break
        end

        local candidate = TheContractorStaff.readWorkerXML(xmlFile, candidateKey, nil)
        if isPreCertification then
            TheContractorTraining.grandfather(candidate)
        end
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
            if isPreCertification then
                TheContractorTraining.grandfather(worker)
            end
            if isPrePayReviews then
                TheContractorPayReviews.migrate(worker)
            end

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
    setXMLInt(xmlFile, rootKey .. "#certificationVersion", 1)
    setXMLInt(xmlFile, rootKey .. "#payVersion", 1)

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

-- Console commands (tcWorker - see TCConsole) ------------------------------------------

function TheContractorStaff.registerConsoleCommands()
    -- The ids the other worker commands take - the Staff tab doesn't show
    -- them. Read-only, so it works on any machine.
    TCConsole.register("worker", "list", {
        description = "Your hired workers: id, status, age, morale, crop care, spraying, holiday, leaving",
        serverOnly = false,
        run = function(farmId, args)
            local roster = g_currentMission.TheContractor.Staff:getRoster(farmId)
            if #roster == 0 then
                return string.format("Farm %d has no hired workers.", farmId)
            end
            table.sort(roster, function(a, b)
                return a.id < b.id
            end)

            local cert = "spraying"
            local lines = { string.format("Farm %d workers (today is day %d):", farmId,
                g_currentMission.environment.currentMonotonicDay) }
            for _, worker in ipairs(roster) do
                local spraying
                if worker:hasCertification(cert) then
                    spraying = "certified"
                elseif worker.trainingCert == cert then
                    spraying = string.format("booked (%d course day(s) left%s, assessment day %d)",
                        worker.courseDaysLeft, worker.trainingDay ~= nil and (", next day " .. worker.trainingDay) or "",
                        worker.assessmentDay)
                elseif TheContractorTraining.isRetake(worker, cert) then
                    spraying = "failed, retake due"
                else
                    spraying = TheContractorTraining.isReady(worker, cert) and "not certified, ready" or
                        "not certified, not ready"
                end

                local extras = {}
                if worker.declinedRequests > 0 then
                    table.insert(extras, string.format("%d declined request(s)", worker.declinedRequests))
                end
                if worker:hasHolidayBooked() then
                    table.insert(extras, string.format("holiday days %d-%d", worker.holidayStartDay,
                        worker:getHolidayEndDay()))
                end
                -- 089.
                local holidayRequest = TheContractorHolidays.findRequest(farmId, worker.id)
                if holidayRequest ~= nil then
                    table.insert(extras, string.format("holiday asked for days %d-%d", holidayRequest.payload.startDay,
                        TheContractorHolidays.getRequestEndDay(holidayRequest)))
                end
                if worker.holidayDeclines > 0 then
                    table.insert(extras, string.format("%d holiday refusal(s) this year", worker.holidayDeclines))
                end
                if worker:isLeaving() then
                    table.insert(extras, (worker.isQuitting and "quitting " or "retiring ") ..
                        TCCalendar.formatPeriodIndex(worker.leavesAtPeriod))
                end

                table.insert(lines, string.format("#%d %s - %s, age %d, morale %.0f (%s), crop care %d, spraying: %s%s",
                    worker.id, worker.name, worker.status, worker.age, worker.morale,
                    TheContractorMorale.getBand(worker.morale), worker:getSkill("cropCare"), spraying,
                    #extras > 0 and ("; " .. table.concat(extras, "; ")) or ""))
            end
            return table.concat(lines, "\n")
        end,
    })

    TCConsole.register("worker", "pool", {
        description = "Candidates you can hire: id, speed, salary, tractors, skills",
        serverOnly = false,
        run = function(farmId, args)
            local pool = g_currentMission.TheContractor.Staff:getCandidatePool()
            if #pool == 0 then
                return "Staff pool is empty."
            end
            table.sort(pool, function(a, b)
                return a.id < b.id
            end)

            local lines = {}
            for _, candidate in ipairs(pool) do
                table.insert(lines, string.format("#%d %s - speed %d, salary %.0f, tractors: %s, skills: %s",
                    candidate.id, candidate.name, candidate.workSpeed, candidate.salary,
                    TheContractorStaff.formatTierCapability(candidate.tierCapability),
                    TheContractorStaff.formatSkills(candidate.skills)))
            end
            return table.concat(lines, "\n")
        end,
    })

    TCConsole.register("worker", "hire", {
        args = "<candidate>",
        description = "Hire a candidate from the pool (id or name, see tcWorker pool)",
        run = function(farmId, args)
            local candidate, problem = TCConsole.findPerson(g_currentMission.TheContractor.Staff:getCandidatePool(),
                args[1], "candidate")
            if candidate == nil then
                return problem or false
            end

            g_client:getServerConnection():sendEvent(TCHireWorkerEvent.new(farmId, candidate.id))
            return string.format("Hiring %s (#%d) for farm %d", candidate.name, candidate.id, farmId)
        end,
    })

    TCConsole.register("worker", "retire", {
        args = "<worker> [noticeMonths=6, 0=now]",
        description = "Make a worker hand in their retirement notice",
        run = function(farmId, args)
            local worker, problem = TCConsole.findWorker(farmId, args[1])
            if worker == nil then
                return problem or false
            end
            local noticeMonths = TCConsole.toCount(args[2], TheContractorStaff.RETIREMENT_NOTICE_MONTHS)
            if noticeMonths == nil then
                return false
            end
            if worker:isLeaving() then
                return string.format("%s is already leaving (%s)", worker.name,
                    TCCalendar.formatPeriodIndex(worker.leavesAtPeriod))
            end

            g_currentMission.TheContractor.Staff:announceLeaving(farmId, worker.id, noticeMonths, false)
            return string.format("%s handed in their notice (%d month(s))", worker.name, noticeMonths)
        end,
    })

    -- 066: the Staff tab's Edit, name only. Everything after the worker is
    -- the new name, so it can have spaces.
    TCConsole.register("worker", "rename", {
        args = "<worker> <new name>",
        description = "Rename a hired worker (look and gender are on the Staff tab's Edit)",
        run = function(farmId, args)
            local worker, problem = TCConsole.findWorker(farmId, args[1])
            if worker == nil then
                return problem or false
            end
            local words = {}
            for i = 2, #args do
                table.insert(words, args[i])
            end
            if #words == 0 then
                return false
            end

            local oldName = worker.name
            problem = g_currentMission.TheContractor.Staff:editWorker(farmId, worker.id, table.concat(words, " "),
                worker.gender, worker.appearance)
            if problem ~= nil then
                return "Error: " .. problem
            end
            return string.format("%s (#%d) is now %s", oldName, worker.id, worker.name)
        end,
    })

    -- 055: through the normal path, so the H&S programme's shorter spells
    -- and the no-programme inspection roll both apply.
    TCConsole.register("worker", "sick", {
        args = "<worker> [inspect]",
        description = "Make a worker fall sick now; inspect forces an H&S inspection if you have no programme",
        run = function(farmId, args)
            local worker, problem = TCConsole.findWorker(farmId, args[1])
            if worker == nil then
                return problem or false
            end
            if args[2] ~= nil and string.lower(args[2]) ~= "inspect" then
                return false
            end
            if worker.status == TheContractorWorker.STATUS.SICK or worker.pendingSickDays > 0 then
                return string.format("%s is already sick", worker.name)
            end
            if worker.status == TheContractorWorker.STATUS.HOLIDAY then
                return string.format("%s is on holiday", worker.name)
            end

            local tc = g_currentMission.TheContractor
            tc.Staff:makeWorkerSick(farmId, worker, args[2] ~= nil)

            local days = worker.pendingSickDays > 0 and worker.pendingSickDays or worker.sickDaysRemaining
            return string.format("%s is off sick for %d day(s)%s (H&S programme %s)", worker.name, days,
                worker.pendingSickDays > 0 and " once back from their job" or "",
                tc.HealthSafety:isActive(farmId) and "active" or "not active - see the log for the inspection roll")
        end,
    })
end
