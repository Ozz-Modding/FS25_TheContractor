-- Farm-scoped reputation score, keyed by farmId. Continuous score is the
-- source of truth; tiers are just named thresholds derived from it for UI
-- legibility/gating later (advertising, negotiation, etc. — not built here).
--
-- Floor at 0 (Q21-adjacent decision): reputation represents standing, not a
-- debt you can dig into further — a string of missed jobs (024) bottoms out
-- at "back to square one," not a permanent negative-reputation death spiral.
-- No ceiling is enforced; tier thresholds above the last one just don't
-- change the displayed tier once you're in it.
--
-- addReputation() is server-authoritative: only the server may apply a
-- delta (later tickets call it from server-side job/negotiation logic), and
-- it broadcasts the resulting absolute score via TCReputationChangedEvent
-- so clients don't need to replicate the clamping math themselves.

TheContractorReputation = {}
TheContractorReputation_mt = Class(TheContractorReputation)

-- Tier cutoffs (026). Ordered ascending; getReputationTier() picks the
-- highest one the score has reached. Gaps widen going up (per user
-- feedback): localContractor takes a handful of jobs, the top tiers are a
-- long-haul grind, each gap roughly 3-4x the last. Sized against the
-- completion reward (JobGeneration's reputationPerHa, ~8-10 per ha): about
-- 3 small jobs to localContractor, ~10 to established, ~30 to regional,
-- then larger fields carry the rest - roughly year 1/2/3/4-5 at the
-- generation rates JobGeneration sets.
--
-- maxPreferredFieldHa is the job size each tier unlocks: generation
-- (JobGeneration:pickField) strongly prefers fields up to this size, so a
-- new company gets small fields and larger ones open up with standing. nil
-- means no limit.
TheContractorReputation.TIERS = {
    { key = "unknownContractor",     minScore = 0,    maxPreferredFieldHa = 3 },
    { key = "localContractor",       minScore = 50,   maxPreferredFieldHa = 5 },
    { key = "establishedContractor", minScore = 200,  maxPreferredFieldHa = 8 },
    { key = "regionalContractor",    minScore = 750,  maxPreferredFieldHa = 15 },
    { key = "renownedContractor",    minScore = 2500, maxPreferredFieldHa = 30 },
    { key = "prestigiousContractor", minScore = 7500, maxPreferredFieldHa = nil },
}

function TheContractorReputation.new()
    local self = {}
    setmetatable(self, TheContractorReputation_mt)

    self.scores = {}

    return self
end

function TheContractorReputation:getReputationScore(farmId)
    return self.scores[farmId] or 0
end

function TheContractorReputation:getReputationTier(farmId)
    return self:getProgress(farmId).tier
end

-- Drives the Overview tab's rank/progress bar (see MenuContractor.lua).
-- Returns { score, tier, tierIndex, nextTier, progressPercentage } — nextTier is nil
-- once the top tier is reached, and progressPercentage is then 1.
function TheContractorReputation:getProgress(farmId)
    local score = self:getReputationScore(farmId)
    local tiers = TheContractorReputation.TIERS

    local tierIndex = 1
    for i, candidate in ipairs(tiers) do
        if score >= candidate.minScore then
            tierIndex = i
        end
    end

    local tier = tiers[tierIndex]
    local nextTier = tiers[tierIndex + 1]

    local progressPercentage = 1
    if nextTier ~= nil then
        progressPercentage = (score - tier.minScore) / (nextTier.minScore - tier.minScore)
    end

    return {
        score = score,
        tier = tier,
        tierIndex = tierIndex,
        nextTier = nextTier,
        progressPercentage = progressPercentage,
    }
end

-- Standing (026): reputation as a 0-1 curve, shared by everything that
-- scales with reputation (offer frequency, pay, negotiation room, required
-- skill) so they all move together with the tier the player can see. Each
-- tier step is an equal share of the curve, interpolated by progress
-- through the current tier: 0 at unknownContractor, 1 at
-- prestigiousContractor. A raw linear score ratio would leave most of the
-- game near 0, since the top cutoff is so far above the rest.
function TheContractorReputation:getStanding(farmId)
    local progress = self:getProgress(farmId)
    if progress.nextTier == nil then
        return 1
    end
    return (progress.tierIndex - 1 + progress.progressPercentage) / (#TheContractorReputation.TIERS - 1)
end

-- Server-authoritative entry point for every later consumer (011/012/014/
-- 022/024). Clamps at a floor of 0, applies locally, then broadcasts the
-- resulting absolute score to other clients.
function TheContractorReputation:addReputation(farmId, delta)
    if not g_currentMission:getIsServer() then
        return self:getReputationScore(farmId)
    end

    local newScore = math.max(0, self:getReputationScore(farmId) + delta)
    self:applyReputationScore(farmId, newScore)

    if g_server ~= nil then
        g_server:broadcastEvent(TCReputationChangedEvent.new(farmId, newScore))
    end

    return newScore
end

-- The actual state flip, run on whichever machine (server, or a client
-- receiving TCReputationChangedEvent) is applying the change.
function TheContractorReputation:applyReputationScore(farmId, score)
    self.scores[farmId] = score
    TCLog.info("TheContractor: farm %d reputation is now %d", farmId, score)
end

-- A farm deleted in multiplayer (TCFarmDeletion), on every machine.
function TheContractorReputation:forgetFarm(farmId)
    self.scores[farmId] = nil
end

function TheContractorReputation:loadFromXMLFile(xmlFile)
    if not g_currentMission:getIsServer() then return end

    self.scores = {}

    local i = 0
    while true do
        local key = string.format("%s.reputation.farm(%d)", TheContractor.SaveKey, i)
        if not hasXMLProperty(xmlFile, key) then
            break
        end

        local farmId = getXMLInt(xmlFile, key .. "#farmId")
        local score = getXMLInt(xmlFile, key .. "#score")
        self.scores[farmId] = score

        i = i + 1
    end
end

function TheContractorReputation:saveToXmlFile(xmlFile)
    if not g_currentMission:getIsServer() then return end

    local i = 0
    for farmId, score in pairs(self.scores) do
        local key = string.format("%s.reputation.farm(%d)", TheContractor.SaveKey, i)
        setXMLInt(xmlFile, key .. "#farmId", farmId)
        setXMLInt(xmlFile, key .. "#score", score)
        i = i + 1
    end
end

function TheContractorReputation:writeInitialClientState(streamId, connection)
    local farmCount = 0
    for _ in pairs(self.scores) do
        farmCount = farmCount + 1
    end
    streamWriteInt32(streamId, farmCount)

    for farmId, score in pairs(self.scores) do
        streamWriteInt32(streamId, farmId)
        streamWriteInt32(streamId, score)
    end
end

function TheContractorReputation:readInitialClientState(streamId, connection)
    local farmCount = streamReadInt32(streamId)
    for _ = 1, farmCount do
        local farmId = streamReadInt32(streamId)
        local score = streamReadInt32(streamId)
        self.scores[farmId] = score
    end
end

-- Called by Company:applyCompanyCreation on activation. Runs identically on
-- server and on clients receiving TCCreateCompanyEvent's broadcast, so no
-- separate network round-trip is needed here.
function TheContractorReputation:reset(farmId)
    self:applyReputationScore(farmId, 0)
end

-- Console commands (tcCompany - see TCConsole) -----------------------------------------

function TheContractorReputation.registerConsoleCommands()
    TCConsole.register("company", "rep", {
        args = "<amount>",
        description = "Add reputation, or remove it with a negative amount",
        run = function(farmId, args)
            local amount = tonumber(args[1])
            if amount == nil then
                return false
            end

            local score = g_currentMission.TheContractor.Reputation:addReputation(farmId, amount)
            return string.format("Applied %d reputation to farm %d (now %d)", amount, farmId, score)
        end,
    })
end
