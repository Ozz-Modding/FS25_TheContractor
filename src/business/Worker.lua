-- Single hired-staff entity (016). Skill is modeled as independent axes
-- rather than one collapsed number (Q8/Q13/Q14): workSpeed is a flat 1-10
-- scalar affecting time-to-complete, tierCapability is *tractor experience*
-- per size class (009's small/medium/large tractor split - it's about the
-- tractor driven, not the size of the job) so a worker can specialize (great
-- on small tractors, mediocre on large), and skills (044) rate the kind of
-- work itself - harvesting, baling, tillage, ... (see SKILLS). Only hired
-- workers carry these stats at all — the player, operating personally, is
-- implicitly max-capable/unrestricted (Q13), so there is no equivalent
-- Worker for "the player."
--
-- tierCapability follows the same "presence IS the fact" convention as
-- Company.lua's companyNames: a tier key absent from the table means "not
-- certified" on that tractor size, not a separate boolean/sentinel string.
-- skills is the opposite: every worker has every key, 1-10 - a low rating
-- never stops a worker being allocated, it just costs reward/quality.

TheContractorWorker = {}
TheContractorWorker_mt = Class(TheContractorWorker)

TheContractorWorker.STATUS = {
    IDLE = "idle",
    ASSIGNED = "assigned",
    COOLDOWN = "cooldown",
    -- 031: off sick for a few days - can't be allocated until they're back.
    SICK = "sick",
    -- 037: driving a vehicle under AutoDrive/Courseplay (see Drivers.lua) -
    -- can't be allocated or released until the vehicle stops.
    DRIVING = "driving",
    -- 040: on a booked holiday - can't be allocated until they're back.
    HOLIDAY = "holiday",
    -- 054: on a training course or sitting its assessment (Training.lua).
    TRAINING = "training",
    -- 170: at the county show for the day, ploughing in the match for the
    -- farm (ShowWorker.lua) - can't be allocated until they're back.
    SHOW = "atShow",
}

TheContractorWorker.TIERS = { "small", "medium", "large" }

-- 044: operation skills, in display order. Which one a job uses is decided
-- by TheContractorJobGeneration.getOperationSkill (the hauler on a haulage
-- job always uses haulage).
TheContractorWorker.SKILLS = { "harvesting", "baling", "grassland", "tillage", "seeding", "planting", "cropCare",
    "haulage" }
TheContractorWorker.IS_SKILL = {}
for _, skill in ipairs(TheContractorWorker.SKILLS) do
    TheContractorWorker.IS_SKILL[skill] = true
end
TheContractorWorker.MIN_SKILL = 1
TheContractorWorker.MAX_SKILL = 10

-- 045: cleanliness, a fixed 1-10 trait (never grows, not paid for) - how
-- much extra dirt they bring equipment back with, whether they wash it
-- before it's back in the yard and how quickly. See TCJobConsequences.
TheContractorWorker.MIN_CLEANLINESS = 1
TheContractorWorker.MAX_CLEANLINESS = 10

-- 056: morale on hire (and for a worker from a save made before 056).
TheContractorWorker.MORALE_START = 70

TheContractorWorker.MIN_WORK_SPEED = 1
TheContractorWorker.MAX_WORK_SPEED = 10

-- A player driving personally is implicitly max-capable (Q13) - there's no
-- Worker to read a workSpeed from for a self-driven job, so anything scaled
-- by work speed treats "no worker" as the best possible one.
TheContractorWorker.PLAYER_WORK_SPEED = TheContractorWorker.MAX_WORK_SPEED

-- Linear by work speed between slowestValue (speed 1) and fastestValue
-- (speed 10). worker may be nil (player-driven, see PLAYER_WORK_SPEED).
-- Shared by the speed-scaled wait factors (Dispatch's transport wait,
-- Cooldown's post-job gap) so they all use the same curve.
function TheContractorWorker.scaleBySpeed(worker, slowestValue, fastestValue)
    local workSpeed = worker ~= nil and worker.workSpeed or TheContractorWorker.PLAYER_WORK_SPEED
    local minSpeed, maxSpeed = TheContractorWorker.MIN_WORK_SPEED, TheContractorWorker.MAX_WORK_SPEED
    local t = (math.max(minSpeed, math.min(maxSpeed, workSpeed)) - minSpeed) / (maxSpeed - minSpeed)
    return slowestValue + t * (fastestValue - slowestValue)
end

-- farmId is nil while a worker is sitting unhired in TheContractorStaff's
-- shared candidate pool (see Staff.lua) — it's only set once a farm actually
-- hires them, at which point they move into that farm's roster.
--
-- Positional args, in this order - new hidden stats get appended to the end
-- so existing callers aren't disturbed (030 appended age/growthPotential/
-- birthPeriod, 031 sicknessPropensity, 044 skills, 045 cleanliness).
function TheContractorWorker.new(id, farmId, name, workSpeed, tierCapability, salary, age, growthPotential,
                                 birthPeriod, sicknessPropensity, skills, cleanliness)
    local self = {}
    setmetatable(self, TheContractorWorker_mt)

    self.id = id
    self.farmId = farmId
    self.name = name
    self.workSpeed = workSpeed
    -- { small = 1-10, medium = 1-10, large = 1-10 }, keys absent for tiers
    -- this worker isn't certified on.
    self.tierCapability = tierCapability or {}
    -- 044: { harvesting = 1-10, baling = 1-10, ... }, every SKILLS key.
    self.skills = skills or {}
    -- 045: visible, so it's sent to clients.
    self.cleanliness = cleanliness or TheContractorWorker.MIN_CLEANLINESS
    -- 036: per period. A candidate's is their market value
    -- (TheContractorStaff.getSalary); 058: a hired worker's is fixed at what
    -- they were hired for and only moves with an agreed rise.
    -- expectedSalary is what they think they should be paid, rolled at their
    -- pay reviews (PayReviews.lua) - visible, so it's sent to clients.
    -- lastReviewPeriod, the TCCalendar period index of their last review
    -- (nil for none yet), is server-only.
    self.salary = salary
    self.expectedSalary = salary
    self.lastReviewPeriod = nil

    -- 030: age is visible (the player's only hint at how much a worker can
    -- still improve); growthPotential is the hidden number of stat points
    -- they have left to gain from completed jobs, rolled from age at
    -- creation (see TheContractorStaff.rollGrowthPotential). Server-only -
    -- never sent to clients, so it stays 0 there.
    self.age = age
    self.growthPotential = growthPotential or 0
    -- The period (1-12) they turn a year older in - see
    -- TheContractorStaff:onPeriodChanged. Server-only, like growthPotential.
    self.birthPeriod = birthPeriod

    -- 031: hidden 0-1 chance-of-falling-sick factor (see
    -- TheContractorStaff:updateSickness), how many more days a sick worker
    -- is off for, and the days off still to come for one who fell ill while
    -- out on a job (starts when they're back). All server-only, like
    -- growthPotential - clients just see the SICK status.
    self.sicknessPropensity = sicknessPropensity or 0
    self.sickDaysRemaining = 0
    self.pendingSickDays = 0
    -- 104: that sickness is a workplace injury.
    self.isInjured = false

    -- Driven by 018 (allocation) / 023 (buffer/cooldown) — just a field here.
    self.status = TheContractorWorker.STATUS.IDLE

    -- 037: network object id of the root vehicle they're DRIVING, set on
    -- every machine by TheContractorDrivers' binding apply/clear - nil
    -- otherwise.
    self.drivingVehicleId = nil

    -- 039: the TCCalendar period index they leave at the start of, once
    -- they've handed in their notice - nil otherwise. That's retiring, or
    -- (056) quitting when isQuitting is set. Both visible, so they're sent
    -- to clients. leavingNoticeId is the Overview notice (038) announcing
    -- it, taken down when they leave - server-only.
    self.leavesAtPeriod = nil
    self.isQuitting = false
    self.leavingNoticeId = nil

    -- 056: morale, 0-100 (see Morale.lua), set to MORALE_START when they're
    -- hired, and the TCCalendar period index they were hired in (for notice
    -- and redundancy pay). Both visible, so they're sent to clients - nil
    -- hiredPeriod is a pool candidate, or a worker from a save made before
    -- 056 until the next day change fills it in. busyDays/idleDays count
    -- this month's days out on work and sat idle, for the monthly morale
    -- drift - server-only.
    self.morale = TheContractorWorker.MORALE_START
    self.hiredPeriod = nil
    self.busyDays = 0
    self.idleDays = 0
    -- 118: their hidden temperament (TheContractorMorale.rollTemperament,
    -- rolled when they join the pool; 0 until then and on clients) and the
    -- months left of a rough patch (0 = none). Both server-only, saved.
    self.temperament = 0
    self.roughPatchPeriods = 0

    -- 040: holiday allowance left this year, as a fraction of a period (1 =
    -- a whole month, i.e. daysPerPeriod days - see Holidays.lua), and the
    -- one booked holiday, if any: holidayStartDay (a monotonic day) and
    -- holidayDays. All three are visible, so they're sent to clients.
    -- holidayYear (the year the allowance is for - nil until it's first
    -- granted) and holidayDaysPerPeriod (the days per period the booking
    -- was made at) are server-only.
    self.holidayAllowance = 0
    self.holidayYear = nil
    self.holidayStartDay = nil
    self.holidayDays = 0
    self.holidayDaysPerPeriod = nil
    -- 089: holiday requests refused (declined or left to expire) this
    -- year, reset with the allowance. Server-only.
    self.holidayDeclines = 0

    -- 041: "male"/"female" (their first name matches it) and their look in
    -- the cab, rolled once at creation - appearance data, see
    -- TCWorkerAppearance. Both visible, so they're sent to clients.
    -- playerStyle is the PlayerStyle built from it, cached per machine.
    self.gender = TCWorkerAppearance.GENDER.MALE
    self.appearance = nil
    self.playerStyle = nil

    -- 054: certificates held, a set ({ spraying = true }) - see Training.lua.
    -- The one booked course, if any: trainingCert is what it's for,
    -- courseDaysLeft the course days still to attend (0 for a retake, which
    -- is just the assessment), trainingDay the next course day and
    -- assessmentDay the assessment (monotonic days). retakeCerts is the set
    -- of certificates whose course they've done but whose assessment they
    -- failed, so the next booking is a cheaper retake. declinedRequests is
    -- how many of their training requests the player turned down or let
    -- expire (for 056's morale). All visible, so they're sent to clients.
    -- forcedAssessmentResult ("pass"/"fail", tcWorker train) is server-only
    -- and never saved.
    self.certifications = {}
    self.trainingCert = nil
    self.courseDaysLeft = 0
    self.trainingDay = nil
    self.assessmentDay = nil
    self.retakeCerts = {}
    self.declinedRequests = 0
    self.forcedAssessmentResult = nil

    -- 091: ADS workshop skills ({ mechanic = 1-3, ... }, at most two) and
    -- the role they're ticked into, if any (see Workshop.lua). Both
    -- visible, so they're sent to clients.
    self.adsSkills = {}
    self.workshopRole = nil

    return self
end

function TheContractorWorker:hasCertification(cert)
    return self.certifications[cert] == true
end

function TheContractorWorker:hasTrainingBooked()
    return self.trainingCert ~= nil
end

-- 054: the monotonic day they're next due in for training - the next
-- course day, or the assessment once the course is done. nil if nothing's
-- booked.
function TheContractorWorker:getTrainingDueDay()
    if self.trainingCert == nil then
        return nil
    end
    if self.courseDaysLeft > 0 then
        return self.trainingDay
    end
    return self.assessmentDay
end

function TheContractorWorker:hasHolidayBooked()
    return self.holidayStartDay ~= nil
end

-- The monotonic day their booked holiday ends on (inclusive).
function TheContractorWorker:getHolidayEndDay()
    return self.holidayStartDay + self.holidayDays - 1
end

function TheContractorWorker:isHolidayOn(monotonicDay)
    return self.holidayStartDay ~= nil and monotonicDay >= self.holidayStartDay and
        monotonicDay <= self:getHolidayEndDay()
end

-- Handed in their notice: retiring (039) or quitting (056).
function TheContractorWorker:isLeaving()
    return self.leavesAtPeriod ~= nil
end

-- Past their leaving date but still here: they were out on a job (or
-- driving) when it came, and leave the moment they're set idle.
function TheContractorWorker:isLeaveDue()
    return self.leavesAtPeriod ~= nil and self.leavesAtPeriod <= TCCalendar.getPeriodIndex()
end

-- nil tier means the job doesn't require a tractor at all (e.g. a job whose
-- equipment doesn't carry a size tier per 009) — every worker can do that.
function TheContractorWorker:isCapableOfTier(tier)
    if tier == nil then
        return true
    end

    return self.tierCapability[tier] ~= nil
end

-- Returns the 1-10 rating for that tier, or nil if not certified.
function TheContractorWorker:getTierCapability(tier)
    return self.tierCapability[tier]
end

-- 044: the 1-10 rating for an operation skill (MIN_SKILL if somehow unset).
function TheContractorWorker:getSkill(skill)
    return self.skills[skill] or TheContractorWorker.MIN_SKILL
end

-- 044: their skills, best first (ties in SKILLS order) - { {skill, rating}, ... }.
function TheContractorWorker:getSkillsByRating()
    local sorted = {}
    for i, skill in ipairs(TheContractorWorker.SKILLS) do
        table.insert(sorted, { skill = skill, rating = self:getSkill(skill), order = i })
    end
    table.sort(sorted, function(a, b)
        if a.rating ~= b.rating then
            return a.rating > b.rating
        end
        return a.order < b.order
    end)
    return sorted
end

function TheContractorWorker:isIdle()
    return self.status == TheContractorWorker.STATUS.IDLE
end

-- Growth (030) reads/writes one stat by name: "workSpeed", a tier key
-- ("small"/"medium"/"large") or a skill key (044). A tier stat is nil while
-- uncertified.
function TheContractorWorker:getStat(stat)
    if stat == "workSpeed" then
        return self.workSpeed
    elseif TheContractorWorker.IS_SKILL[stat] then
        return self.skills[stat]
    end
    return self.tierCapability[stat]
end

function TheContractorWorker:setStat(stat, value)
    if stat == "workSpeed" then
        self.workSpeed = value
    elseif TheContractorWorker.IS_SKILL[stat] then
        self.skills[stat] = value
    else
        self.tierCapability[stat] = value
    end
end
