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

-- Placeholder cutoffs — exact numbers are a 026 balance-pass concern.
-- Ordered ascending; getReputationTier() picks the highest one the score
-- has reached. Gaps widen sharply going up (per user feedback): reaching
-- localContractor should be easy (a handful of jobs), while the top tiers
-- are a long-haul grind — each successive gap is roughly 3-4x the last.
TheContractorReputation.TIERS = {
    { key = "unknownContractor",     minScore = 0 },
    { key = "localContractor",       minScore = 20 },
    { key = "establishedContractor", minScore = 100 },
    { key = "regionalContractor",    minScore = 400 },
    { key = "renownedContractor",    minScore = 1500 },
    { key = "prestigiousContractor", minScore = 5000 },
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
-- Returns { score, tier, nextTier, progressPercentage } — nextTier is nil
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
        nextTier = nextTier,
        progressPercentage = progressPercentage,
    }
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
    Logging.info("TheContractor: farm %d reputation is now %d", farmId, score)
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
