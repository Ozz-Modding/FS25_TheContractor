-- Price negotiation resolution (014) — a hidden per-job "eagerness" value
-- (Job.lua's job.eagerness) rather than a fixed number of exchange rounds
-- decides whether a counter offer is accepted, rejected outright, or
-- countered back. Kept in its own file, mirroring how Advertising.lua
-- isolates 012's interest formula, so 026's balance pass has one place to
-- retune the math without touching the state-machine/event plumbing in
-- Jobs.lua that drives it.
--
-- Stateless: every function here takes the job (and a proposed price) and
-- returns an outcome, it doesn't mutate anything or know about persistence/
-- networking. TheContractorJobs:proposeCounterOffer (Jobs.lua) owns applying
-- the result, transitioning state, and broadcasting.

TheContractorNegotiation = {}

-- Hard safety cap on rounds (Q12) — enforced regardless of eagerness, so the
-- negotiation always terminates even if the eagerness math never bottoms
-- out. "Configurable constant" per the ticket's acceptance criteria.
TheContractorNegotiation.MAX_ROUNDS = 5

-- Placeholder eagerness tuning — exact formula deferred to 026. 0-100 scale;
-- starts at full trust (round 1 gets the farm's full reputation-scaled
-- tolerance, see below) and degrades by a fixed amount every round
-- regardless of outcome, so later counters get squeezed harder.
TheContractorNegotiation.INITIAL_EAGERNESS = 100
TheContractorNegotiation.EAGERNESS_DEGRADE_PER_ROUND = 15

-- Placeholder tolerance-band math: at full eagerness the NPC will accept a
-- counter up to this percentage above the current price; below that band
-- they counter back partway, more than double it and they walk away
-- outright. The ceiling itself is reputation-scaled (a brand new, no-
-- reputation company gets far less room to push price up than an
-- established one — same MIN/MAX/cap-score shape as JobGeneration's own
-- reputation price scaling, for consistency) rather than a flat 0.5 for
-- every farm regardless of standing. 026 owns the real curve.
TheContractorNegotiation.MIN_TOLERANCE_PERCENT = 0.06
TheContractorNegotiation.MAX_TOLERANCE_PERCENT = 0.5
TheContractorNegotiation.REPUTATION_TOLERANCE_CAP_SCORE = 5000

TheContractorNegotiation.OUTCOME = {
    ACCEPTED = "accepted",
    REJECTED = "rejected",
    COUNTERED = "countered",
}

-- Resolves a single round of negotiation against the job's current price and
-- eagerness. Does not mutate the job or degrade eagerness — see
-- TheContractorJobs:proposeCounterOffer for that. Returns outcome, resultPrice
-- (the price to accept at, or the NPC's counter — irrelevant on reject).
function TheContractorNegotiation.resolveCounterOffer(job, counterPrice)
    local basePrice = job.price
    local percentIncrease = (counterPrice - basePrice) / basePrice

    -- Asking for the same or less than the current price is always taken.
    if percentIncrease <= 0 then
        return TheContractorNegotiation.OUTCOME.ACCEPTED, counterPrice
    end

    local reputationScore = g_currentMission.TheContractor.Reputation:getReputationScore(job.farmId)
    local reputationRatio = math.min(reputationScore / TheContractorNegotiation.REPUTATION_TOLERANCE_CAP_SCORE, 1)
    local maxTolerance = TheContractorNegotiation.MIN_TOLERANCE_PERCENT +
        reputationRatio * (TheContractorNegotiation.MAX_TOLERANCE_PERCENT - TheContractorNegotiation.MIN_TOLERANCE_PERCENT)

    local tolerance = maxTolerance * (job.eagerness / 100)

    if percentIncrease <= tolerance then
        return TheContractorNegotiation.OUTCOME.ACCEPTED, counterPrice
    end

    if percentIncrease > tolerance * 2 then
        return TheContractorNegotiation.OUTCOME.REJECTED, basePrice
    end

    local counterBack = basePrice + (counterPrice - basePrice) * 0.5
    return TheContractorNegotiation.OUTCOME.COUNTERED, counterBack
end

function TheContractorNegotiation.degradeEagerness(job)
    job.eagerness = math.max(0, job.eagerness - TheContractorNegotiation.EAGERNESS_DEGRADE_PER_ROUND)
end
