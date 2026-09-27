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
-- Positional args, in this order, so 030 (age + potential ceiling) and 031
-- (sickness propensity) can each append one more hidden stat to the end of
-- this list without disturbing existing callers — see those tickets' notes
-- on this ticket. Neither is built yet; there is nothing to append today.
function TheContractorWorker.new(id, farmId, name, workSpeed, tierCapability, hireCost)
    local self = {}
    setmetatable(self, TheContractorWorker_mt)

    self.id = id
    self.farmId = farmId
    self.name = name
    self.workSpeed = workSpeed
    -- { small = 1-10, medium = 1-10, large = 1-10 }, keys absent for tiers
    -- this worker isn't certified on.
    self.tierCapability = tierCapability or {}
    self.hireCost = hireCost

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
