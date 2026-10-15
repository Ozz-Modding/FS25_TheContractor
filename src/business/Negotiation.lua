-- Price negotiation resolution (014) — a hidden per-job "eagerness" value
-- (Job.lua's job.eagerness) rather than a fixed number of exchange rounds
-- decides whether a counter offer is accepted, rejected outright, or
-- countered back. Kept in its own file, mirroring how Advertising.lua
-- isolates 012's interest formula, so the balance math (026) lives in one
-- place, apart from the state-machine/event plumbing in Jobs.lua that
-- drives it.
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

-- Eagerness (026), 0-100 scale. Each offer starts somewhere between MIN and
-- MAX_INITIAL_EAGERNESS (some clients are keener than others), then loses
-- BASE_EAGERNESS_DEGRADE after the first round, EAGERNESS_DEGRADE_STEP
-- more after each round after that (15, 20, 25, 30...) — haggling wears
-- thin faster the longer it goes on. Roughly four rounds from a keen start
-- before they walk away, so MAX_ROUNDS rarely has to step in.
TheContractorNegotiation.MIN_INITIAL_EAGERNESS = 70
TheContractorNegotiation.MAX_INITIAL_EAGERNESS = 100
TheContractorNegotiation.BASE_EAGERNESS_DEGRADE = 15
TheContractorNegotiation.EAGERNESS_DEGRADE_STEP = 5

-- How far above the *original* offer (job:getOfferedPrice()) the client will go
-- (026). maxTolerance runs linearly on Reputation:getStanding from MIN
-- (a brand new company: +5%) to MAX (a prestigious one: +25%), scaled by
-- eagerness/100 into this round's tolerance. Then, against the original
-- offer:
--   up to +tolerance                        accepted
--   past +tolerance * WALKAWAY_MULTIPLIER   they walk away
--   in between                              they counter at +tolerance
-- Measured from the original offer rather than the current price so
-- repeated counters can't ratchet the price up round after round — the
-- ceiling only ever shrinks as eagerness drops, so the best counter is the
-- first one.
TheContractorNegotiation.MIN_TOLERANCE_PERCENT = 0.05
TheContractorNegotiation.MAX_TOLERANCE_PERCENT = 0.25
TheContractorNegotiation.WALKAWAY_MULTIPLIER = 2

TheContractorNegotiation.OUTCOME = {
    ACCEPTED = "accepted",
    REJECTED = "rejected",
    COUNTERED = "countered",
}

function TheContractorNegotiation.rollInitialEagerness()
    return math.random(TheContractorNegotiation.MIN_INITIAL_EAGERNESS, TheContractorNegotiation.MAX_INITIAL_EAGERNESS)
end

-- This round's tolerance, as a fraction of the original offer.
function TheContractorNegotiation.getTolerance(job)
    local standing = g_currentMission.TheContractor.Reputation:getStanding(job.farmId)
    local maxTolerance = TheContractorNegotiation.MIN_TOLERANCE_PERCENT +
        standing * (TheContractorNegotiation.MAX_TOLERANCE_PERCENT - TheContractorNegotiation.MIN_TOLERANCE_PERCENT)
    return maxTolerance * (job.eagerness / 100)
end

-- Resolves a single round of negotiation against the job's original offer
-- and current eagerness. Does not mutate the job or degrade eagerness — see
-- TheContractorJobs:proposeCounterOffer for that. Returns outcome,
-- resultPrice (the price to accept at, or the client's counter — irrelevant
-- on reject). The counter never drops below the current price: once
-- they've offered a figure they stand by it, even after eagerness shrinks
-- their ceiling below it.
function TheContractorNegotiation.resolveCounterOffer(job, counterPrice)
    local price = job:getPrice()
    -- Asking for the same or less than the current price is always taken.
    if counterPrice <= price then
        return TheContractorNegotiation.OUTCOME.ACCEPTED, counterPrice
    end

    local offeredPrice = job:getOfferedPrice()
    local tolerance = TheContractorNegotiation.getTolerance(job)
    local ceiling = math.floor(offeredPrice * (1 + tolerance))

    if counterPrice <= ceiling then
        return TheContractorNegotiation.OUTCOME.ACCEPTED, counterPrice
    end

    if counterPrice > offeredPrice * (1 + tolerance * TheContractorNegotiation.WALKAWAY_MULTIPLIER) then
        return TheContractorNegotiation.OUTCOME.REJECTED, price
    end

    return TheContractorNegotiation.OUTCOME.COUNTERED, math.max(price, ceiling)
end

-- Call after job.negotiationRounds has been incremented for this round.
function TheContractorNegotiation.degradeEagerness(job)
    local degrade = TheContractorNegotiation.BASE_EAGERNESS_DEGRADE +
        TheContractorNegotiation.EAGERNESS_DEGRADE_STEP * math.max(0, job.negotiationRounds - 1)
    job.eagerness = math.max(0, job.eagerness - degrade)
end
