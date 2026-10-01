-- Single hired-staff entity (016). Skill is modeled as two independent axes
-- rather than one collapsed number (Q8/Q13/Q14): workSpeed is a flat 1-10
-- scalar affecting time-to-complete, while tierCapability is a *per-size-class*
-- rating (009's small/medium/large split) so a worker can specialize (great on
-- small tractors, mediocre on large) instead of being forced onto one linear
-- score. Only hired workers carry these stats at all — the player, operating
-- personally, is implicitly max-capable/unrestricted (Q13), so there is no
-- equivalent Worker for "the player."
--
-- tierCapability follows the same "presence IS the fact" convention as
-- Company.lua's companyNames: a tier key absent from the table means "not
-- certified" for that tier, not a separate boolean/sentinel string.

TheContractorWorker = {}
TheContractorWorker_mt = Class(TheContractorWorker)

TheContractorWorker.STATUS = {
    IDLE = "idle",
    ASSIGNED = "assigned",
    COOLDOWN = "cooldown",
    -- 031: off sick for a few days - can't be allocated until they're back.
    SICK = "sick",
}

TheContractorWorker.TIERS = { "small", "medium", "large" }

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
-- birthPeriod, 031 sicknessPropensity).
function TheContractorWorker.new(id, farmId, name, workSpeed, tierCapability, salary, age, growthPotential,
                                 birthPeriod, sicknessPropensity)
    local self = {}
    setmetatable(self, TheContractorWorker_mt)

    self.id = id
    self.farmId = farmId
    self.name = name
    self.workSpeed = workSpeed
    -- { small = 1-10, medium = 1-10, large = 1-10 }, keys absent for tiers
    -- this worker isn't certified on.
    self.tierCapability = tierCapability or {}
    -- 036: per period, derived from the stats (TheContractorStaff.getSalary).
    self.salary = salary

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

    -- Driven by 018 (allocation) / 023 (buffer/cooldown) — just a field here.
    self.status = TheContractorWorker.STATUS.IDLE

    return self
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

function TheContractorWorker:isIdle()
    return self.status == TheContractorWorker.STATUS.IDLE
end

-- Growth (030) reads/writes one stat by name: "workSpeed" or a tier key
-- ("small"/"medium"/"large"). A tier stat is nil while uncertified.
function TheContractorWorker:getStat(stat)
    if stat == "workSpeed" then
        return self.workSpeed
    end
    return self.tierCapability[stat]
end

function TheContractorWorker:setStat(stat, value)
    if stat == "workSpeed" then
        self.workSpeed = value
    else
        self.tierCapability[stat] = value
    end
end
